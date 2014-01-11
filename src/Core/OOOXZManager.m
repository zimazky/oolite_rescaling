/*

OOOXZManager.m

Responsible for installing and uninstalling OXZs

Oolite
Copyright (C) 2004-2013 Giles C Williams and contributors

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
MA 02110-1301, USA.

*/

#import "OOOXZManager.h"
#import "OOPListParsing.h"
#import "ResourceManager.h"
#import "OOCacheManager.h"
#import "Universe.h"
#import "GuiDisplayGen.h"
#import "PlayerEntity.h"
#import "OOCollectionExtractors.h"
#import "NSFileManagerOOExtensions.h"

#import "OOManifestProperties.h"

/* The URL for the manifest.plist array. This one is extremely
 * temporary, of course */
static NSString * const kOOOXZDataURL = @"http://compsoc.dur.ac.uk/~cim/oolite/dev/manifests.plist";
/* The filename to store the downloaded manifest.plist array */
static NSString * const kOOOXZManifestCache = @"Oolite-manifests.plist";
/* The filename to temporarily store the downloaded manifest.plist array or OXZ. Has an OXZ extension since we might want to read its manifest.plist out of it; the extension is irrelevant for now if it's a plist download */
static NSString * const kOOOXZTmpPath = @"Oolite-download.oxz";


static NSString * const kOOOXZErrorLog = @"oxz.manager.error";
static NSString * const kOOOXZDebugLog = @"oxz.manager.debug";


static OOOXZManager *sSingleton = nil;

// protocol was only formalised in 10.7
#if OOLITE_MAC_OS_X_10_7 
@interface OOOXZManager (OOPrivate) <NSURLConnectionDataDelegate> 
#else
@interface OOOXZManager (NSURLConnectionDataDelegate) 
#endif

- (NSString *) manifestPath;
- (NSString *) downloadPath;

- (BOOL) ensureInstallPath;

- (BOOL) beginDownload:(NSURLRequest *)request;
- (BOOL) processDownloadedManifests;
- (BOOL) processDownloadedOXZ;

- (void) setOXZList:(NSArray *)list;
- (void) setCurrentDownload:(NSURLConnection *)download;

- (BOOL) installOXZ:(NSUInteger)item;
- (BOOL) removeOXZ:(NSUInteger)item;
- (NSArray *) installOptions;
- (NSArray *) removalOptions;

/* Delegates for URL downloader */
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection;

@end


@implementation OOOXZManager

+ (OOOXZManager *)sharedManager
{
	// NOTE: assumes single-threaded first access.
	if (sSingleton == nil)  sSingleton = [[self alloc] init];
	return sSingleton;
}


- (id) init
{
	self = [super init];
	if (self != nil)
	{
		_downloadStatus = OXZ_DOWNLOAD_NONE;
		// if the file has not been downloaded, this will be nil
		[self setOXZList:OOArrayFromFile([self manifestPath])];
		OOLog(kOOOXZDebugLog,@"Initialised with %@",_oxzList);
		if (_oxzList != nil)
		{
			_interfaceState = OXZ_STATE_MAIN;
		}
		else
		{
			_interfaceState = OXZ_STATE_NODATA;
		}
		_changesMade = NO;
	}
	return self;
}


- (void)dealloc
{
	if (sSingleton == self)  sSingleton = nil;

	[self setCurrentDownload:nil];
	DESTROY(_oxzList);

	[super dealloc];
}


/* The install path for OXZs downloaded by
 * Oolite. Library/ApplicationSupport seems to be the most appropriate
 * location. */
- (NSString *) installPath
{
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES);
	NSString *appPath = [paths objectAtIndex:0];
	if (appPath != nil)
	{
		appPath = [appPath stringByAppendingPathComponent:@"Oolite"];
#if OOLITE_MAC_OS_X
		appPath = [appPath stringByAppendingPathComponent:@"Managed AddOns"];
#else
		/* GNUStep uses "ApplicationSupport" rather than "Application
		 * Support" so match convention by not putting a space in the
		 * path either */
		appPath = [appPath stringByAppendingPathComponent:@"ManagedAddOns"];
#endif
		return appPath;
	}
	return nil;
}


- (BOOL) ensureInstallPath
{
	BOOL				exists, directory;
	NSFileManager		*fmgr = [NSFileManager defaultManager];
	NSString			*path = [self installPath];

	exists = [fmgr fileExistsAtPath:path isDirectory:&directory];
	
	if (exists && !directory)
	{
		OOLog(kOOOXZErrorLog, @"Expected %@ to be a folder, but it is a file.", path);
		return NO;
	}
	if (!exists)
	{
		if (![fmgr oo_createDirectoryAtPath:path attributes:nil])
		{
			OOLog(kOOOXZErrorLog, @"Could not create folder %@.", path);
			return NO;
		}
	}
	
	return YES;
}


- (NSString *) manifestPath
{
	return [[[OOCacheManager sharedCache] cacheDirectoryPathCreatingIfNecessary:YES] stringByAppendingPathComponent:kOOOXZManifestCache];
}


/* Download mechanism could destroy a correct file if it failed
 * half-way and was downloaded on top of the old one. So this loads it
 * off to the side a bit */
- (NSString *) downloadPath
{
	return [[[OOCacheManager sharedCache] cacheDirectoryPathCreatingIfNecessary:YES] stringByAppendingPathComponent:kOOOXZTmpPath];
}




- (void) setOXZList:(NSArray *)list
{
	DESTROY(_oxzList);
	if (list != nil)
	{
		_oxzList = [list retain];
	}
}


- (void) setCurrentDownload:(NSURLConnection *)download
{
	if (_currentDownload != nil)
	{
		[_currentDownload cancel]; // releases via delegate
	}
	_currentDownload = [download retain];
}


- (BOOL) updateManifests
{
	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:kOOOXZDataURL]];
	if (_downloadStatus != OXZ_DOWNLOAD_NONE)
	{
		return NO;
	}
	_downloadStatus = OXZ_DOWNLOAD_STARTED;
	_interfaceState = OXZ_STATE_UPDATING;

	return [self beginDownload:request];
}


- (BOOL) beginDownload:(NSURLRequest *)request
{
	NSURLConnection *download = [[NSURLConnection alloc] initWithRequest:request delegate:self];
	if (download)
	{
		_downloadProgress = 0;
		_downloadExpected = 0;
		[self setCurrentDownload:download]; // retains it
		[download release];
		OOLog(kOOOXZDebugLog,@"Download request received, using %@ and downloading to %@",[request URL],[self downloadPath]);
		return YES;
	}
	else
	{
		OOLog(kOOOXZErrorLog,@"Unable to start downloading file at %@",[request URL]);
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
		return NO;
	}
}


- (BOOL) cancelUpdate
{
	if (!(_interfaceState == OXZ_STATE_UPDATING || _interfaceState == OXZ_STATE_INSTALLING) || _downloadStatus == OXZ_DOWNLOAD_NONE)
	{
		return NO;
	}
	OOLog(kOOOXZDebugLog,@"Trying to cancel file download");
	if (_currentDownload != nil)
	{
		[_currentDownload cancel];
	}
	else if (_downloadStatus == OXZ_DOWNLOAD_COMPLETE)
	{
		NSString *path = [self downloadPath];
		[[NSFileManager defaultManager] oo_removeItemAtPath:path];
	}
	_downloadStatus = OXZ_DOWNLOAD_NONE;
	_interfaceState = OXZ_STATE_MAIN;
	[self gui];
	return YES;
}


- (NSArray *) manifests
{
	return _oxzList;
}


- (BOOL) processDownloadedManifests
{
	if (_downloadStatus != OXZ_DOWNLOAD_COMPLETE)
	{
		return NO;
	}
	[self setOXZList:OOArrayFromFile([self downloadPath])];
	_interfaceState = OXZ_STATE_TASKDONE;
	if (_oxzList != nil)
	{
		[_oxzList writeToFile:[self manifestPath] atomically:YES];
		// and clean up the temp file
		[[NSFileManager defaultManager] oo_removeItemAtPath:[self downloadPath]];
		[self gui];
		return YES;
	}
	else
	{
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
		OOLog(kOOOXZErrorLog,@"Downloaded manifest was not a valid plist, has been left in %@",[self downloadPath]);
		// revert to the old one
		[self setOXZList:OOArrayFromFile([self manifestPath])];
		[self gui];
		return NO;
	}
}


- (BOOL) processDownloadedOXZ
{
	if (_downloadStatus != OXZ_DOWNLOAD_COMPLETE)
	{
		return NO;
	}
	_interfaceState = OXZ_STATE_TASKDONE;

	NSDictionary *downloadedManifest = OODictionaryFromFile([[self downloadPath] stringByAppendingPathComponent:@"manifest.plist"]);
	if (downloadedManifest == nil)
	{
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
		OOLog(kOOOXZErrorLog,@"Downloaded OXZ does not contain a manifest.plist, has been left in %@",[self downloadPath]);
		[self gui];
		return NO;
	}
	NSDictionary *expectedManifest = [_oxzList objectAtIndex:_item];
	if (expectedManifest == nil || (![[downloadedManifest oo_stringForKey:kOOManifestIdentifier] isEqualToString:[expectedManifest oo_stringForKey:kOOManifestIdentifier]]) || (![[downloadedManifest oo_stringForKey:kOOManifestVersion] isEqualToString:[expectedManifest oo_stringForKey:kOOManifestVersion]]))
	{
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
		OOLog(kOOOXZErrorLog,@"Downloaded OXZ does not have the same identifer and version as expected. This might be due to your manifests list being out of date - try updating it.");
		[self gui];
		return NO;
	}
	// this appears to be the OXZ we expected
	// filename is going to be identifier.oxz
	NSString *filename = [[downloadedManifest oo_stringForKey:kOOManifestIdentifier] stringByAppendingString:@".oxz"];

	if (![self ensureInstallPath])
	{
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
		OOLog(kOOOXZErrorLog,@"Unable to create installation folder.");
		[self gui];
		return NO;
	}

	// delete filename if it exists from OXZ folder
	NSString *destination = [[self installPath] stringByAppendingPathComponent:filename];
	[[NSFileManager defaultManager] oo_removeItemAtPath:destination];

	// move the temp file on to it
	if (![[NSFileManager defaultManager] oo_moveItemAtPath:[self downloadPath] toPath:destination])
	{
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
		OOLog(kOOOXZErrorLog,@"Downloaded OXZ could not be installed.");
		[self gui];
		return NO;
	}
	_changesMade = YES;
	[self gui];
	return YES;
}


// TODO: move these constants somewhere better and use an enum instead
#define OXZ_GUI_ROW_FIRSTRUN	1
#define OXZ_GUI_ROW_PROGRESS	1
#define OXZ_GUI_ROW_LISTHEAD	1
#define OXZ_GUI_ROW_LISTPREV	2
#define OXZ_GUI_ROW_LISTSTART	3
#define OXZ_GUI_NUM_LISTROWS	10
#define OXZ_GUI_ROW_LISTNEXT	13
#define OXZ_GUI_ROW_LISTDESC	15
#define OXZ_GUI_ROW_INSTALL		24
#define OXZ_GUI_ROW_REMOVE		25
#define OXZ_GUI_ROW_UPDATE		26
#define OXZ_GUI_ROW_EXIT		27


- (void) gui
{
	GuiDisplayGen	*gui = [UNIVERSE gui];
	OOGUIRow		startRow = OXZ_GUI_ROW_EXIT;

	[gui clearAndKeepBackground:YES];
	[gui setTitle:DESC(@"oolite-oxzmanager-title")];

	/* This switch will give warnings until all states are
	 * covered. Not a problem yet. */
	switch (_interfaceState)
	{
	case OXZ_STATE_NODATA:
		[gui addLongText:DESC(@"oolite-oxzmanager-firstrun") startingAtRow:OXZ_GUI_ROW_FIRSTRUN align:GUI_ALIGN_LEFT];
		[gui setText:DESC(@"oolite-oxzmanager-download-list") forRow:OXZ_GUI_ROW_UPDATE align:GUI_ALIGN_CENTER];
		[gui setKey:@"_UPDATE" forRow:OXZ_GUI_ROW_UPDATE];

		startRow = OXZ_GUI_ROW_UPDATE;
		break;
	case OXZ_STATE_MAIN:
		[gui addLongText:DESC(@"oolite-oxzmanager-intro") startingAtRow:OXZ_GUI_ROW_FIRSTRUN align:GUI_ALIGN_LEFT];
		// fall through
	case OXZ_STATE_PICK_INSTALL:
	case OXZ_STATE_PICK_REMOVE:
		[gui setText:DESC(@"oolite-oxzmanager-install") forRow:OXZ_GUI_ROW_INSTALL align:GUI_ALIGN_CENTER];
		[gui setKey:@"_INSTALL" forRow:OXZ_GUI_ROW_INSTALL];
		[gui setText:DESC(@"oolite-oxzmanager-remove") forRow:OXZ_GUI_ROW_REMOVE align:GUI_ALIGN_CENTER];
		[gui setKey:@"_REMOVE" forRow:OXZ_GUI_ROW_REMOVE];
		[gui setText:DESC(@"oolite-oxzmanager-update-list") forRow:OXZ_GUI_ROW_UPDATE align:GUI_ALIGN_CENTER];
		[gui setKey:@"_UPDATE" forRow:OXZ_GUI_ROW_UPDATE];

		startRow = OXZ_GUI_ROW_INSTALL;
		break;
	case OXZ_STATE_UPDATING:
	case OXZ_STATE_INSTALLING:
		[gui addLongText:[NSString stringWithFormat:DESC(@"oolite-oxzmanager-progress-@-of-@"),_downloadProgress,_downloadExpected] startingAtRow:OXZ_GUI_ROW_PROGRESS align:GUI_ALIGN_LEFT];
		// no options yet
		// TODO: cancel option
		break;
	case OXZ_STATE_TASKDONE:
		if (_downloadStatus == OXZ_DOWNLOAD_COMPLETE)
		{
			[gui addLongText:DESC(@"oolite-oxzmanager-progress-done") startingAtRow:OXZ_GUI_ROW_PROGRESS align:GUI_ALIGN_LEFT];
		}
		else
		{
			[gui addLongText:DESC(@"oolite-oxzmanager-progress-error") startingAtRow:OXZ_GUI_ROW_PROGRESS align:GUI_ALIGN_LEFT];
		}
		[gui setText:DESC(@"oolite-oxzmanager-acknowledge") forRow:OXZ_GUI_ROW_UPDATE align:GUI_ALIGN_CENTER];
		[gui setKey:@"_ACK" forRow:OXZ_GUI_ROW_UPDATE];
		startRow = OXZ_GUI_ROW_UPDATE;
		break;
	}

	if (_interfaceState == OXZ_STATE_PICK_INSTALL)
	{
		startRow = [self showInstallOptions];
	}
	else if (_interfaceState == OXZ_STATE_PICK_REMOVE)
	{
		startRow = [self showRemoveOptions];
	}

	[gui setText:DESC(@"oolite-oxzmanager-exit") forRow:OXZ_GUI_ROW_EXIT align:GUI_ALIGN_CENTER];
	[gui setKey:@"_EXIT" forRow:OXZ_GUI_ROW_EXIT];
	[gui setSelectableRange:NSMakeRange(startRow,2+(OXZ_GUI_ROW_EXIT-startRow))];
	if (startRow < OXZ_GUI_ROW_INSTALL)
	{
		[gui setSelectedRow:OXZ_GUI_ROW_INSTALL];
	}
	else
	{
		[gui setSelectedRow:startRow];
	}
	
}


- (void) processSelection
{
	GuiDisplayGen	*gui = [UNIVERSE gui];
	OOGUIRow selection = [gui selectedRow];

	if (selection == OXZ_GUI_ROW_EXIT)
	{
		[self cancelUpdate]; // doesn't hurt if no update in progress
		if (_changesMade)
		{
			// Rebuilds OXP search
			[ResourceManager reset];
			[UNIVERSE reinitAndShowDemo:YES strictChanged:YES];
			_changesMade = NO;
		}
		else
		{
			[PLAYER setGuiToIntroFirstGo:YES];
		}
		return;
	}
	else if (selection == OXZ_GUI_ROW_UPDATE)
	{
		if (_interfaceState == OXZ_STATE_TASKDONE)
		{
			_interfaceState = OXZ_STATE_MAIN;
			_downloadStatus = OXZ_DOWNLOAD_NONE;
		}
		else
		{
			[self updateManifests];
		}
	}
	else if (selection == OXZ_GUI_ROW_INSTALL)
	{
		_interfaceState = OXZ_STATE_PICK_INSTALL;
	}
	else if (selection == OXZ_GUI_ROW_REMOVE)
	{
		_interfaceState = OXZ_STATE_PICK_REMOVE;
	}
	else if (selection == OXZ_GUI_ROW_LISTPREV)
	{
		_offset -= OXZ_GUI_NUM_LISTROWS;
		[self showOptionsUpdate];
		return;
	}
	else if (selection == OXZ_GUI_ROW_LISTNEXT)
	{
		_offset += OXZ_GUI_NUM_LISTROWS;
		[self showOptionsUpdate];
		return;
	}
	else
	{
		NSUInteger item = _offset + selection - OXZ_GUI_ROW_LISTSTART;
		if (_interfaceState == OXZ_STATE_PICK_REMOVE)
		{
			[self removeOXZ:item];
		}
		else if (_interfaceState == OXZ_STATE_PICK_INSTALL)
		{
			OOLog(kOOOXZDebugLog,@"Trying to install index %d",item);
			[self installOXZ:item];
		}
	}

	[self gui]; // update GUI
}


- (BOOL) installOXZ:(NSUInteger)item
{
	if ([_oxzList count] <= item)
	{
		return NO;
	}
	_item = item;
	NSDictionary *manifest = [_oxzList objectAtIndex:item];
	NSString *url = [manifest objectForKey:kOOManifestDownloadURL];
	if (url == nil)
	{
		OOLog(kOOOXZErrorLog,@"Manifest does not have a download URL - cannot install");
		return NO;
	}
	NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
	if (_downloadStatus != OXZ_DOWNLOAD_NONE)
	{
		return NO;
	}
	_downloadStatus = OXZ_DOWNLOAD_STARTED;
	_interfaceState = OXZ_STATE_INSTALLING;

	return [self beginDownload:request];
}


- (NSArray *) installOptions
{
	NSUInteger start = _offset;
	if (start >= [_oxzList count])
	{
		start = 0;
	}
	NSUInteger end = start + OXZ_GUI_NUM_LISTROWS;
	if (end > [_oxzList count])
	{
		end = [_oxzList count];
	}
	return [_oxzList subarrayWithRange:NSMakeRange(start,end-start)];
}


- (OOGUIRow) showInstallOptions
{
	// shows the current installation options page
	OOGUIRow startRow = OXZ_STATE_PICK_INSTALL;
	NSArray *options = [self installOptions];
	GuiDisplayGen	*gui = [UNIVERSE gui];
	OOGUITabSettings tab_stops;
	tab_stops[0] = 0;
	tab_stops[1] = 100;
	tab_stops[2] = 320;
	tab_stops[3] = 400;
	[gui setTabStops:tab_stops];
	
	[gui setArray:[NSArray arrayWithObjects:DESC(@"oolite-oxzmanager-heading-category"),
						   DESC(@"oolite-oxzmanager-heading-title"), 
						   DESC(@"oolite-oxzmanager-heading-version"), 
						   DESC(@"oolite-oxzmanager-heading-installed"), 
								nil] forRow:OXZ_GUI_ROW_LISTHEAD];
	if (_offset > 0)
	{
		[gui setColor:[OOColor greenColor] forRow:OXZ_GUI_ROW_LISTPREV];
		[gui setArray:[NSArray arrayWithObjects:DESC(@"gui-back"), @"",@"",@" <-- ", nil] forRow:OXZ_GUI_ROW_LISTPREV];
		[gui setKey:@"_BACK" forRow:OXZ_GUI_ROW_LISTPREV];
		startRow = OXZ_GUI_ROW_LISTPREV;
	}
	else
	{
		startRow = OXZ_GUI_ROW_LISTSTART;
	}
	if (_offset + 10 < [_oxzList count])
	{
		[gui setColor:[OOColor greenColor] forRow:OXZ_GUI_ROW_LISTNEXT];
		[gui setArray:[NSArray arrayWithObjects:DESC(@"gui-next"), @"",@"",@" --> ", nil] forRow:OXZ_GUI_ROW_LISTNEXT];
		[gui setKey:@"_NEXT" forRow:OXZ_GUI_ROW_LISTNEXT];
	}

	// clear any previous longtext
	for (NSUInteger i = OXZ_GUI_ROW_LISTDESC; i < OXZ_GUI_ROW_INSTALL-1; i++)
	{
		[gui setText:@"" forRow:i align:GUI_ALIGN_LEFT];
		[gui setKey:GUI_KEY_SKIP forRow:i];
	}

	OOGUIRow row = OXZ_GUI_ROW_LISTSTART;
	NSDictionary *manifest = nil;
	foreach (manifest, options)
	{
		NSDictionary *installed = [ResourceManager manifestForIdentifier:[manifest oo_stringForKey:kOOManifestIdentifier]];
		NSString *installedVersion = [installed oo_stringForKey:kOOManifestVersion defaultValue:DESC(@"oolite-oxzmanager-version-none")];

		[gui setArray:[NSArray arrayWithObjects:
				 [manifest oo_stringForKey:kOOManifestCategory defaultValue:DESC(@"oolite-oxzmanager-missing-field")],
			 [manifest oo_stringForKey:kOOManifestTitle defaultValue:DESC(@"oolite-oxzmanager-missing-field")],
			 [manifest oo_stringForKey:kOOManifestVersion defaultValue:DESC(@"oolite-oxzmanager-missing-field")],
			 installedVersion,
		  nil] forRow:row];
		[gui setKey:[manifest oo_stringForKey:kOOManifestIdentifier] forRow:row];
		
		/* TODO: yellow for installable, orange for dependency issues, grey and unselectable for version issues, green and unselectable for already installed (manually or otherwise) at the current version, red and unselectable for already installed manually at a different version.
		[gui setColor:[self colorForManifest:manifest] forRow:row];
		*/
		if (row == [gui selectedRow])
		{
			[gui addLongText:[manifest oo_stringForKey:kOOManifestDescription] startingAtRow:OXZ_GUI_ROW_LISTDESC align:GUI_ALIGN_LEFT];
		}

		row++;
	}

	return startRow;
}


- (BOOL) removeOXZ:(NSUInteger)item
{
	// TODO
	return NO;
}


- (NSArray *) removeOptions
{
	// TODO
	return nil;
}


- (OOGUIRow) showRemoveOptions
{
	// shows the current removal options page

	// TODO
	return OXZ_STATE_PICK_INSTALL;
}


- (void) showOptionsUpdate
{
	if (_interfaceState == OXZ_STATE_PICK_INSTALL)
	{
		[self showInstallOptions];
	}
	else if (_interfaceState == OXZ_STATE_PICK_REMOVE)
	{
		[self showRemoveOptions];
	}
	// else nothing necessary
}


- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	_downloadStatus = OXZ_DOWNLOAD_RECEIVING;
	OOLog(kOOOXZDebugLog,@"Download receiving");
	_downloadExpected = [response expectedContentLength];
	_downloadProgress = 0;
	DESTROY(_fileWriter);
	[[NSFileManager defaultManager] createFileAtPath:[self downloadPath] contents:nil attributes:nil];
	_fileWriter = [[NSFileHandle fileHandleForWritingAtPath:[self downloadPath]] retain];
	if (_fileWriter == nil)
	{
		// file system is full or read-only or something
		OOLog(kOOOXZErrorLog,@"Unable to create download file");
		[self cancelUpdate];
	}
}


- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	OOLog(kOOOXZDebugLog,@"Downloaded %lu bytes",[data length]);
	[_fileWriter seekToEndOfFile];
	[_fileWriter writeData:data];
	_downloadProgress += [data length];
	[self gui]; // update GUI
}


- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	_downloadStatus = OXZ_DOWNLOAD_COMPLETE;
	OOLog(kOOOXZDebugLog,@"Download complete");
	[_fileWriter synchronizeFile];
	[_fileWriter closeFile];
	DESTROY(_fileWriter);
	DESTROY(_currentDownload);
	if (_interfaceState == OXZ_STATE_UPDATING)
	{
		if (![self processDownloadedManifests])
		{
			_downloadStatus = OXZ_DOWNLOAD_ERROR;
		}
	}
	else if (_interfaceState == OXZ_STATE_INSTALLING)
	{
		if (![self processDownloadedOXZ])
		{
			_downloadStatus = OXZ_DOWNLOAD_ERROR;
		}
	}
	else
	{
		OOLog(kOOOXZErrorLog,@"Error: download completed in unexpected state %d. This is an internal error - please report it.",_interfaceState);
		_downloadStatus = OXZ_DOWNLOAD_ERROR;
	}
}


- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	_downloadStatus = OXZ_DOWNLOAD_ERROR;
	OOLog(kOOOXZErrorLog,@"Error downloading file: %@",[error description]);
	[_fileWriter closeFile];
	DESTROY(_fileWriter);
	DESTROY(_currentDownload);
}




@end


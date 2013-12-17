//
//  GBASyncManager.m
//  GBA4iOS
//
//  Created by Riley Testut on 12/5/13.
//  Copyright (c) 2013 Riley Testut. All rights reserved.
//

#import "GBASyncManager_Private.h"
#import "GBASettingsViewController.h"
#import "GBAROM_Private.h"
#import "GBASyncingOverviewViewController.h"

#import "GBASyncAllFilesOperation.h"
#import "GBASyncInitialSyncOperation.h"
#import "GBASyncUploadOperation.h"
#import "GBASyncDownloadOperation.h"
#import "GBASyncOperation.h"

#import <DropboxSDK/DropboxSDK.h>

NSString * const GBASyncLocalPathKey = @"localPath";
NSString * const GBASyncDropboxPathKey = @"dropboxPath";
NSString * const GBASyncMetadataKey = @"metadata";
NSString * const GBASyncDestinationPathKey = @"destinationPath";

NSString * const GBASyncManagerFinishedSyncNotification = @"GBASyncManagerFinishedSyncNotification";

@interface GBASyncManager () <GBASyncOperationDelegate>

@property (strong, nonatomic) NSOperationQueue *multipleFilesOperationQueue;
@property (strong, nonatomic) NSOperationQueue *singleFileOperationQueue;
@property (strong, nonatomic) NSOperationQueue *fileManipulationOperationQueue;
@property (strong, nonatomic) DBRestClient *restClient;
@property (weak, nonatomic) RSTToastView *currentToastView;

@end

@implementation GBASyncManager

#pragma mark - Singleton Methods

+ (instancetype)sharedManager
{
    static GBASyncManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (id)init
{
    self = [super init];
    
    if (self == nil)
    {
        return nil;
    }
    
    // Stores DBMetadata, so it has to be archived
    _pendingUploads = [NSKeyedUnarchiver unarchiveObjectWithFile:[GBASyncManager pendingUploadsPath]];
    if (_pendingUploads == nil)
    {
        _pendingUploads = [NSMutableDictionary dictionary];
    }
    
    _pendingDownloads = [NSKeyedUnarchiver unarchiveObjectWithFile:[GBASyncManager pendingDownloadsPath]];
    if (_pendingDownloads == nil)
    {
        _pendingDownloads = [NSMutableDictionary dictionary];
    }
    
    _pendingDeletions = [NSMutableDictionary dictionaryWithContentsOfFile:[GBASyncManager pendingDeletionsPath]];
    if (_pendingDeletions == nil)
    {
        _pendingDeletions = [NSMutableDictionary dictionary];
    }
    
    _pendingMoves = [NSMutableDictionary dictionaryWithContentsOfFile:[GBASyncManager pendingMovesPath]];
    if (_pendingMoves == nil)
    {
        _pendingMoves = [NSMutableDictionary dictionary];
    }
    
    _deviceUploadHistory = [NSMutableDictionary dictionaryWithContentsOfFile:[GBASyncManager currentDeviceUploadHistoryPath]];
    if (_deviceUploadHistory == nil)
    {
        _deviceUploadHistory = [NSMutableDictionary dictionary];
    }
    
    _dropboxFiles = [NSKeyedUnarchiver unarchiveObjectWithFile:[GBASyncManager dropboxFilesPath]];
    if (_dropboxFiles == nil)
    {
        _dropboxFiles = [NSMutableDictionary dictionary];
    }
    
    _conflictedROMs = [NSSet setWithArray:[NSArray arrayWithContentsOfFile:[GBASyncManager conflictedROMsPath]]];
    _syncingDisabledROMs = [NSSet setWithArray:[NSArray arrayWithContentsOfFile:[GBASyncManager syncingDisabledROMsPath]]];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(romConflictedStateDidChange:) name:GBAROMConflictedStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(romSyncingDisabledStateDidChange:) name:GBAROMSyncingDisabledStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(dropboxLoggedOut:) name:GBADropboxLoggedOutNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updatedDeviceUploadHistory:) name:GBAUpdatedDeviceUploadHistoryNotification object:nil];
    
    _multipleFilesOperationQueue = ({
        NSOperationQueue *operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.name = @"com.GBA4iOS.sync_manager_multiple_files_operation_queue";
        [operationQueue setMaxConcurrentOperationCount:1];
        [operationQueue setSuspended:NO];
        operationQueue;
    });
    
    _singleFileOperationQueue = ({
        NSOperationQueue *operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.name = @"com.GBA4iOS.sync_manager_single_file_operation_queue";
        [operationQueue setMaxConcurrentOperationCount:1];
        [operationQueue setSuspended:NO];
        operationQueue;
    });
    
    _fileManipulationOperationQueue = ({
        NSOperationQueue *operationQueue = [[NSOperationQueue alloc] init];
        operationQueue.name = @"com.GBA4iOS.sync_manager_file_manipulation_operation_queue";
        [operationQueue setMaxConcurrentOperationCount:1];
        [operationQueue setSuspended:NO];
        operationQueue;
    });
    
    return self;
}

#pragma mark - Syncing

- (void)start
{
    [[RSTToastView appearance] setTintColor:GBA4iOS_PURPLE_COLOR];
    
    DBSession *session = [[DBSession alloc] initWithAppKey:@"obzx8requbc5bn5" appSecret:@"thdkvkp3hkbmpte" root:kDBRootAppFolder];
    [DBSession setSharedSession:session];
    
    self.shouldShowSyncingStatus = YES;
    
    if (![[DBSession sharedSession] isLinked])
    {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GBASettingsDropboxSyncKey];
    }
    else
    {
        [self synchronize];
    }
}

- (void)synchronize
{
    if (![[NSUserDefaults standardUserDefaults] boolForKey:GBASettingsDropboxSyncKey] || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    if (!self.performedInitialSync)
    {
        BOOL performingInitialSync = NO;
        
        for (NSOperation *operation in [self.multipleFilesOperationQueue operations])
        {
            if ([operation isKindOfClass:[GBASyncInitialSyncOperation class]])
            {
                performingInitialSync = YES;
                break;
            }
        }
        
        if (performingInitialSync)
        {
            return;
        }
        
        [self performInitialSync];
        
        return;
    }
    
    // Only queue normal syncs after a successful initial sync has been completed
    [self syncAllFiles];
}

- (void)performInitialSync
{
    GBASyncInitialSyncOperation *initialSyncOperation = [[GBASyncInitialSyncOperation alloc] init];
    initialSyncOperation.delegate = self;
    initialSyncOperation.completionBlock = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GBASyncManagerFinishedSyncNotification object:self];
    };
    [self.multipleFilesOperationQueue addOperation:initialSyncOperation];
}

- (void)syncAllFiles
{
    GBASyncAllFilesOperation *allFilesOperation = [[GBASyncAllFilesOperation alloc] init];
    allFilesOperation.delegate = self;
    allFilesOperation.completionBlock = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GBASyncManagerFinishedSyncNotification object:self];
    };
    [self.multipleFilesOperationQueue addOperation:allFilesOperation];
}

#pragma mark - Single File Operations

- (void)uploadFileAtPath:(NSString *)localPath toDropboxPath:(NSString *)dropboxPath completionBlock:(GBASyncCompletionBlock)completionBlock
{
    GBASyncUploadOperation *uploadOperation = [[GBASyncUploadOperation alloc] initWithLocalPath:localPath dropboxPath:dropboxPath];
    [self configureAndCacheUploadOperation:uploadOperation withCompletionBlock:completionBlock];
    
}

- (void)uploadFileAtPath:(NSString *)localPath withMetadata:(DBMetadata *)metadata completionBlock:(GBASyncCompletionBlock)completionBlock
{
    GBASyncUploadOperation *uploadOperation = [[GBASyncUploadOperation alloc] initWithLocalPath:localPath metadata:metadata];
    [self configureAndCacheUploadOperation:uploadOperation withCompletionBlock:completionBlock];
}

- (void)configureAndCacheUploadOperation:(GBASyncUploadOperation *)uploadOperation withCompletionBlock:(GBASyncCompletionBlock)completionBlock
{
    __weak GBASyncOperation *weakOperation = uploadOperation;
    uploadOperation.syncCompletionBlock = ^(NSString *localPath, DBMetadata *metadata, NSError *error) {
        NSString *message = nil;
        
        if (error)
        {
            message = NSLocalizedString(@"Upload Failed", @"");
        }
        else
        {
            message = NSLocalizedString(@"Upload Complete!", @"");
        }
        
        [self showFinishedToastViewWithMessage:message forSyncOperation:weakOperation];
        
        if (completionBlock)
        {
            completionBlock(localPath, metadata, error);
        }
    };
    uploadOperation.updatesDeviceUploadHistoryUponCompletion = YES;
    uploadOperation.delegate = self;
    [self.singleFileOperationQueue addOperation:uploadOperation];
    
    [self cacheUploadOperation:uploadOperation];
    
    if (uploadOperation.metadata)
    {
        [self.pendingDownloads removeObjectForKey:uploadOperation.metadata.path];
    }
    else
    {
        [self.pendingDownloads removeObjectForKey:uploadOperation.dropboxPath];
    }
    
    [NSKeyedArchiver archiveRootObject:self.pendingDownloads toFile:[GBASyncManager pendingDownloadsPath]];
}

- (void)downloadFileToPath:(NSString *)localPath fromDropboxPath:(NSString *)dropboxPath completionBlock:(GBASyncCompletionBlock)completionBlock
{
    GBASyncDownloadOperation *downloadOperation = [[GBASyncDownloadOperation alloc] initWithLocalPath:localPath dropboxPath:dropboxPath];
    [self configureAndCacheDownloadOperation:downloadOperation withCompletionBlock:completionBlock];
}

- (void)downloadFileToPath:(NSString *)localPath withMetadata:(DBMetadata *)metadata completionBlock:(GBASyncCompletionBlock)completionBlock
{
    GBASyncDownloadOperation *downloadOperation = [[GBASyncDownloadOperation alloc] initWithLocalPath:localPath metadata:metadata];
    [self configureAndCacheDownloadOperation:downloadOperation withCompletionBlock:completionBlock];
}

- (void)configureAndCacheDownloadOperation:(GBASyncDownloadOperation *)downloadOperation withCompletionBlock:(GBASyncCompletionBlock)completionBlock
{
    __weak GBASyncOperation *weakOperation = downloadOperation;
    downloadOperation.syncCompletionBlock = ^(NSString *localPath, DBMetadata *metadata, NSError *error) {
        NSString *message = nil;
        
        if (error)
        {
            message = NSLocalizedString(@"Download Failed", @"");
        }
        else
        {
            message = NSLocalizedString(@"Download Complete!", @"");
        }
        
        [self showFinishedToastViewWithMessage:message forSyncOperation:weakOperation];
        
        if (completionBlock)
        {
            completionBlock(localPath, metadata, error);
        }
    };
    downloadOperation.delegate = self;
    [self.singleFileOperationQueue addOperation:downloadOperation];
    
    [self cacheDownloadOperation:downloadOperation];
    
    [self.pendingUploads removeObjectForKey:downloadOperation.localPath];
    [NSKeyedArchiver archiveRootObject:self.pendingUploads toFile:[GBASyncManager pendingUploadsPath]];
}

- (void)showFinishedToastViewWithMessage:(NSString *)message forSyncOperation:(GBASyncOperation *)syncOperation
{
    rst_dispatch_sync_on_main_thread(^{
        RSTToastView *toastView = [RSTToastView toastViewWithMessage:message];
        
        if ([self syncOperation:syncOperation shouldShowToastView:toastView])
        {
            [toastView showForDuration:1.0];
        }
    });
}

#pragma mark - File Manipulation Operations

- (void)deleteFileAtDropboxPath:(NSString *)dropboxPath completionBlock:(GBASyncDeleteCompletionBlock)completionBlock
{
    GBASyncDeleteOperation *deleteOperation = [[GBASyncDeleteOperation alloc] initWithDropboxPath:dropboxPath];
    deleteOperation.syncCompletionBlock = completionBlock;
    deleteOperation.delegate = self;
    
    [self.fileManipulationOperationQueue addOperation:deleteOperation];
    
    [self cacheDeleteOperation:deleteOperation];
}

- (void)moveFileAtDropboxPath:(NSString *)dropboxPath toDestinationPath:(NSString *)destinationPath completionBlock:(GBASyncMoveCompletionBlock)completionBlock
{
    GBASyncMoveOperation *moveOperation = [[GBASyncMoveOperation alloc] initWithDropboxPath:dropboxPath destinationPath:destinationPath];
    moveOperation.syncCompletionBlock = completionBlock;
    moveOperation.delegate = self;
    
    [self.fileManipulationOperationQueue addOperation:moveOperation];
    
    NSString *localPath = [GBASyncManager localPathForDropboxPath:dropboxPath];
    NSString *newLocalPath = [GBASyncManager localPathForDropboxPath:destinationPath];
    
    if (self.pendingUploads[localPath])
    {
        NSMutableDictionary *dictionary = self.pendingUploads[localPath];
        dictionary[GBASyncLocalPathKey] = newLocalPath;
        dictionary[GBASyncDropboxPathKey] = destinationPath;
        
        [self.pendingUploads removeObjectForKey:localPath];
        [self.pendingUploads setObject:dictionary forKey:newLocalPath];
        [NSKeyedArchiver archiveRootObject:self.pendingUploads toFile:[GBASyncManager pendingUploadsPath]];
    }
    
    if (self.pendingDownloads[dropboxPath])
    {
        NSMutableDictionary *dictionary = self.pendingDownloads[dropboxPath];
        dictionary[GBASyncLocalPathKey] = newLocalPath;
        dictionary[GBASyncDropboxPathKey] = destinationPath;
        
        [self.pendingDownloads removeObjectForKey:dropboxPath];
        [self.pendingDownloads setObject:dictionary forKey:destinationPath];
        [NSKeyedArchiver archiveRootObject:self.pendingDownloads toFile:[GBASyncManager pendingDownloadsPath]];
    }
    
    if (self.pendingDeletions[dropboxPath])
    {
        NSMutableDictionary *dictionary = self.pendingDeletions[dropboxPath];
        dictionary[GBASyncDropboxPathKey] = destinationPath;
        
        [self.pendingDeletions removeObjectForKey:dropboxPath];
        [self.pendingDeletions setObject:dictionary forKey:destinationPath];
        [NSKeyedArchiver archiveRootObject:self.pendingDeletions toFile:[GBASyncManager pendingDeletionsPath]];
    }
    
    [self cacheMoveOperation:moveOperation];
}

#pragma mark - Preparing Sync Methods

- (void)prepareToUploadSaveFileForROM:(GBAROM *)rom
{
    if (rom == nil || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    NSString *uniqueName = [rom uniqueName];
    NSString *dropboxPath = [NSString stringWithFormat:@"/%@/Saves/%@", uniqueName, [uniqueName stringByAppendingPathExtension:@"sav"]];
    
    // Cache it for later
    GBASyncUploadOperation *uploadOperation = [[GBASyncUploadOperation alloc] initWithLocalPath:rom.saveFileFilepath dropboxPath:dropboxPath];
    [self cacheUploadOperation:uploadOperation];
}

- (void)prepareToUploadCheat:(GBACheat *)cheat forROM:(GBAROM *)rom
{
    if (rom == nil || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    NSString *uniqueName = [rom uniqueName];
    NSString *dropboxPath = [NSString stringWithFormat:@"/%@/Cheats/%@", uniqueName, [cheat.filepath lastPathComponent]];
    
    // Cache it for later
    GBASyncUploadOperation *uploadOperation = [[GBASyncUploadOperation alloc] initWithLocalPath:cheat.filepath dropboxPath:dropboxPath];
    [self cacheUploadOperation:uploadOperation];
}

- (void)prepareToDeleteCheat:(GBACheat *)cheat forROM:(GBAROM *)rom
{
    if (rom == nil || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    NSString *uniqueName = [rom uniqueName];
    NSString *dropboxPath = [NSString stringWithFormat:@"/%@/Cheats/%@", uniqueName, [cheat.filepath lastPathComponent]];
    
    GBASyncDeleteOperation *deleteOperation = [[GBASyncDeleteOperation alloc] initWithDropboxPath:dropboxPath];
    [self cacheDeleteOperation:deleteOperation];
}

- (void)prepareToUploadSaveStateAtPath:(NSString *)filepath forROM:(GBAROM *)rom
{
    if (rom == nil || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    NSString *uniqueName = [rom uniqueName];
    NSString *dropboxPath = [NSString stringWithFormat:@"/%@/Save States/%@", uniqueName, [filepath lastPathComponent]];
    
    GBASyncUploadOperation *uploadOperation = [[GBASyncUploadOperation alloc] initWithLocalPath:filepath dropboxPath:dropboxPath];
    [self cacheUploadOperation:uploadOperation];
}

- (void)prepareToDeleteSaveStateAtPath:(NSString *)filepath forROM:(GBAROM *)rom
{
    if (rom == nil || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    NSString *uniqueName = [rom uniqueName];
    NSString *dropboxPath = [NSString stringWithFormat:@"/%@/Save States/%@", uniqueName, [filepath lastPathComponent]];
    
    GBASyncDeleteOperation *deleteOperation = [[GBASyncDeleteOperation alloc] initWithDropboxPath:dropboxPath];
    [self cacheDeleteOperation:deleteOperation];
}

- (void)prepareToRenameSaveStateAtPath:(NSString *)filepath toNewName:(NSString *)filename forROM:(GBAROM *)rom
{
    if (rom == nil || ![[DBSession sharedSession] isLinked])
    {
        return;
    }
    
    NSString *uniqueName = [rom uniqueName];
    NSString *dropboxPath = [NSString stringWithFormat:@"/%@/Save States/%@", uniqueName, [filepath lastPathComponent]];
    NSString *destinationPath = [NSString stringWithFormat:@"/%@/Save States/%@", uniqueName, filename];
        
    GBASyncMoveOperation *moveOperation = [[GBASyncMoveOperation alloc] initWithDropboxPath:dropboxPath destinationPath:destinationPath];
    [self cacheMoveOperation:moveOperation];
    
    NSString *localPath = [GBASyncManager localPathForDropboxPath:dropboxPath];
    NSString *newLocalPath = [GBASyncManager localPathForDropboxPath:destinationPath];
    
    if (self.pendingUploads[localPath])
    {
        NSMutableDictionary *dictionary = self.pendingUploads[localPath];
        dictionary[GBASyncLocalPathKey] = newLocalPath;
        dictionary[GBASyncDropboxPathKey] = destinationPath;
        
        [self.pendingUploads removeObjectForKey:localPath];
        [self.pendingUploads setObject:dictionary forKey:newLocalPath];
        [NSKeyedArchiver archiveRootObject:self.pendingUploads toFile:[GBASyncManager pendingUploadsPath]];
    }
    
    if (self.pendingDownloads[dropboxPath])
    {
        NSMutableDictionary *dictionary = self.pendingDownloads[dropboxPath];
        dictionary[GBASyncLocalPathKey] = newLocalPath;
        dictionary[GBASyncDropboxPathKey] = destinationPath;
        
        [self.pendingDownloads removeObjectForKey:dropboxPath];
        [self.pendingDownloads setObject:dictionary forKey:destinationPath];
        [NSKeyedArchiver archiveRootObject:self.pendingDownloads toFile:[GBASyncManager pendingDownloadsPath]];
    }
    
    if (self.pendingDeletions[dropboxPath])
    {
        NSMutableDictionary *dictionary = self.pendingDeletions[dropboxPath];
        dictionary[GBASyncDropboxPathKey] = destinationPath;
        
        [self.pendingDeletions removeObjectForKey:dropboxPath];
        [self.pendingDeletions setObject:dictionary forKey:destinationPath];
        [NSKeyedArchiver archiveRootObject:self.pendingDeletions toFile:[GBASyncManager pendingDeletionsPath]];
    }
}

#pragma mark - Cache Operations

- (void)cacheDownloadOperation:(GBASyncDownloadOperation *)downloadOperation
{
    NSMutableDictionary *pendingDownloads = [[GBASyncManager sharedManager] pendingDownloads];
    pendingDownloads[downloadOperation.dropboxPath] = [downloadOperation dictionaryRepresentation];
    [NSKeyedArchiver archiveRootObject:pendingDownloads toFile:[GBASyncManager pendingDownloadsPath]];
}

- (void)cacheUploadOperation:(GBASyncUploadOperation *)uploadOperation
{
    NSMutableDictionary *pendingUploads = [[GBASyncManager sharedManager] pendingUploads];
    pendingUploads[uploadOperation.localPath] = [uploadOperation dictionaryRepresentation];
    [NSKeyedArchiver archiveRootObject:pendingUploads toFile:[GBASyncManager pendingUploadsPath]];
}

- (void)cacheDeleteOperation:(GBASyncDeleteOperation *)deleteOperation
{
    NSMutableDictionary *pendingDeletions = [[GBASyncManager sharedManager] pendingDeletions];
    pendingDeletions[deleteOperation.dropboxPath] = [deleteOperation dictionaryRepresentation];
    [pendingDeletions writeToFile:[GBASyncManager pendingDeletionsPath] atomically:YES];
}

- (void)cacheMoveOperation:(GBASyncMoveOperation *)moveOperation
{
    NSMutableDictionary *pendingMoves = [[GBASyncManager sharedManager] pendingMoves];
    pendingMoves[moveOperation.dropboxPath] = [moveOperation dictionaryRepresentation];
    [pendingMoves writeToFile:[GBASyncManager pendingMovesPath] atomically:YES];
}

#pragma mark - GBASyncOperationDelegate

- (BOOL)syncOperation:(GBASyncOperation *)syncOperation shouldShowToastView:(RSTToastView *)toastView
{
    GBASyncOperation *currentOperation = [self currentExecutingOperation];
    
    if (currentOperation == syncOperation)
    {
        self.currentToastView = toastView;
    }
    
    if (!self.shouldShowSyncingStatus)
    {
        return NO;
    }
    
    // Only show toast view if it is for the current executing operation
    if (syncOperation == [self currentExecutingOperation])
    {
        return YES;
    }
    
    return NO;
}

#pragma mark - Notifications

- (void)romConflictedStateDidChange:(NSNotification *)notification
{
    self.conflictedROMs = [NSMutableSet setWithArray:[NSArray arrayWithContentsOfFile:[GBASyncManager conflictedROMsPath]]];
    
    if (self.conflictedROMs == nil)
    {
        self.conflictedROMs = [NSMutableSet set];
    }
}

- (void)romSyncingDisabledStateDidChange:(NSNotification *)notification
{
    self.syncingDisabledROMs = [NSMutableSet setWithArray:[NSArray arrayWithContentsOfFile:[GBASyncManager syncingDisabledROMsPath]]];
    
    if (self.syncingDisabledROMs == nil)
    {
        self.syncingDisabledROMs = [NSMutableSet set];
    }
}

- (void)updatedDeviceUploadHistory:(NSNotification *)notification
{
    NSString *dropboxPath = [notification object];
    
    if ([[[dropboxPath lastPathComponent] stringByDeletingPathExtension] isEqualToString:[[UIDevice currentDevice] name]])
    {
        self.deviceUploadHistory = [NSMutableDictionary dictionaryWithContentsOfFile:[GBASyncManager currentDeviceUploadHistoryPath]];
        
        if (self.deviceUploadHistory == nil)
        {
            self.deviceUploadHistory = [NSMutableDictionary dictionary];
        }
    }
}

- (void)dropboxLoggedOut:(NSNotification *)notification
{
    self.dropboxFiles = [NSMutableDictionary dictionary];
    self.conflictedROMs = [NSSet set];
    self.syncingDisabledROMs = [NSSet set];
    self.deviceUploadHistory = [NSMutableDictionary dictionary];
    self.pendingUploads = [NSMutableDictionary dictionary];
    self.pendingDownloads = [NSMutableDictionary dictionary];
    self.pendingDeletions = [NSMutableDictionary dictionary];
    self.pendingMoves = [NSMutableDictionary dictionary];
}

#pragma mark - Helper Methods

- (BOOL)hasPendingDownloadForROM:(GBAROM *)rom
{
    NSDictionary *pendingDownloads = [self pendingDownloads];
        
    __block BOOL isDownloadingData = NO;
    
    [pendingDownloads enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *downloadOperationDictionary, BOOL *stop) {
        
        NSString *romName = [GBASyncManager romNameFromDropboxPath:downloadOperationDictionary[GBASyncDropboxPathKey]];
        
        if ([romName isEqualToString:rom.name])
        {
            isDownloadingData = YES;
        }
        
    }];
    
    return isDownloadingData;
}

+ (NSString *)uniqueROMNameFromDropboxPath:(NSString *)dropboxPath
{
    NSArray *components = [dropboxPath pathComponents];
    
    if (components.count <= 1)
    {
        return nil;
    }
    
    NSString *uniqueName = components[1];
    
    if ([uniqueName isEqualToString:@"Upload History"])
    {
        // Don't return, we use this to determine if this is a upload history upload
        //return nil;
    }
    
    return uniqueName;
}

+ (NSString *)romNameFromDropboxPath:(NSString *)dropboxPath
{
    NSString *uniqueName = [self uniqueROMNameFromDropboxPath:dropboxPath];
    
    if (uniqueName == nil)
    {
        return nil;
    }
    
    GBAROM *rom = [GBAROM romWithUniqueName:uniqueName];
    
    if (rom == nil)
    {
        return nil;
    }
    
    return rom.name;
}

- (GBASyncOperation *)currentExecutingOperation
{
    GBASyncOperation *currentOperation = nil;
    
    // Prefer single file operations over multiple file ones
    for (GBASyncOperation *syncOperation in [self.singleFileOperationQueue operations])
    {
        if ([syncOperation isExecuting])
        {
            currentOperation = syncOperation;
        }
    }
    
    if (currentOperation)
    {
        return currentOperation;
    }
        
    for (GBASyncOperation *syncOperation in [self.multipleFilesOperationQueue operations])
    {
        if ([syncOperation isExecuting])
        {
            currentOperation = syncOperation;
        }
    }
    
    return currentOperation;
}

- (BOOL)pendingMoveToOrFromDropboxPath:(NSString *)dropboxPath
{
    NSDictionary *pendingMoves = [[self pendingMoves] copy];
    BOOL pendingMoveFromPath = (pendingMoves[dropboxPath] != nil);
    
    __block BOOL pendingMoveToPath = NO;
    [pendingMoves enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *pendingMoveDictionary, BOOL *stop) {
        NSString *destinationDropboxPath = pendingMoveDictionary[GBASyncDestinationPathKey];
                
        if ([dropboxPath isEqualToString:destinationDropboxPath])
        {
            pendingMoveToPath = YES;
            *stop = YES;
        }
    }];
    
    return (pendingMoveFromPath || pendingMoveToPath);
}
 
#pragma mark - Filepaths

+ (NSString *)dropboxSyncDirectoryPath
{
    NSString *libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    NSString *dropboxDirectory = [libraryDirectory stringByAppendingPathComponent:@"Dropbox Sync"];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:dropboxDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    
    return dropboxDirectory;
}

+ (NSString *)dropboxFilesPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"dropboxFiles.plist"];
}

+ (NSString *)pendingUploadsPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"pendingUploads.plist"];
}

+ (NSString *)pendingDownloadsPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"pendingDownloads.plist"];
}

+ (NSString *)pendingDeletionsPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"pendingDeletions.plist"];
}

+ (NSString *)pendingMovesPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"pendingMoves.plist"];
}

+ (NSString *)cachedROMsPath
{
    NSString *libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    return [libraryDirectory stringByAppendingPathComponent:@"cachedROMs.plist"];
}


+ (NSString *)conflictedROMsPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"conflictedROMs.plist"];
}

+ (NSString *)syncingDisabledROMsPath
{
    return [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"syncingDisabledROMs.plist"];
}

+ (NSString *)currentDeviceUploadHistoryPath
{
    NSString *directory = [[GBASyncManager dropboxSyncDirectoryPath] stringByAppendingPathComponent:@"Upload History"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSString *deviceName = [[UIDevice currentDevice] name];
    return [directory stringByAppendingPathComponent:[deviceName stringByAppendingPathExtension:@"plist"]];
}

+ (NSString *)cheatsDirectoryForROM:(GBAROM *)rom
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    NSString *cheatsParentDirectory = [documentsDirectory stringByAppendingPathComponent:@"Cheats"];
    NSString *cheatsDirectory = [cheatsParentDirectory stringByAppendingPathComponent:rom.uniqueName];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:cheatsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    
    return cheatsDirectory;
}

+ (NSString *)saveStateDirectoryForROM:(GBAROM *)rom
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    NSString *saveStateParentDirectory = [documentsDirectory stringByAppendingPathComponent:@"Save States"];
    NSString *saveStateDirectory = [saveStateParentDirectory stringByAppendingPathComponent:rom.uniqueName];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:saveStateDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    
    return saveStateDirectory;
}

+ (NSString *)localPathForDropboxPath:(NSString *)dropboxPath
{
    NSArray *pathComponents = [dropboxPath pathComponents];
    
    if ([pathComponents count] < 2)
    {
        return nil;
    }
    
    if ([pathComponents count] < 4 && ![pathComponents[1] isEqualToString:@"Upload History"])
    {
        return nil;
    }
    
    NSString *directory = pathComponents[2];
    
    NSString *romName = [GBASyncManager romNameFromDropboxPath:dropboxPath];
    
    GBAROM *rom = [GBAROM romWithName:romName];
    
    NSString *localPath = nil;
    
    if ([directory isEqualToString:@"Saves"]) // ROM save files
    {
        localPath = rom.saveFileFilepath;
    }
    else if ([directory isEqualToString:@"Save States"]) // Save States
    {
        localPath = [[GBASyncManager saveStateDirectoryForROM:rom] stringByAppendingPathComponent:[dropboxPath lastPathComponent]];
    }
    else if ([directory isEqualToString:@"Cheats"]) // Cheats
    {
        localPath = [[GBASyncManager cheatsDirectoryForROM:rom] stringByAppendingPathComponent:[dropboxPath lastPathComponent]];
    }
    else if ([pathComponents[1] isEqualToString:@"Upload History"]) // Upload History
    {
        localPath = [[[GBASyncManager currentDeviceUploadHistoryPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:[dropboxPath lastPathComponent]];
    }
    
    return localPath;
}

#pragma mark - Getters/Setters

- (BOOL)isSyncing
{
    return ([self.multipleFilesOperationQueue operationCount] + [self.singleFileOperationQueue operationCount] > 0);
}

- (BOOL)performedInitialSync
{
    return ([[NSUserDefaults standardUserDefaults] objectForKey:@"initialSync"] != nil);
}

- (void)setShouldShowSyncingStatus:(BOOL)shouldShowSyncingStatus
{
    if (_shouldShowSyncingStatus == shouldShowSyncingStatus)
    {
        return;
    }
    
    _shouldShowSyncingStatus = shouldShowSyncingStatus;
    
    if (!shouldShowSyncingStatus)
    {
        [self.currentToastView hide];
    }
    else if ([self isSyncing])
    {
        [self.currentToastView show];
    }
    
}

@end
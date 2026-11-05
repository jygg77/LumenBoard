#import "LBRootListController.h"
#import "../Shared/LBPaths.h"
#import "LBTendiesValidator.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const LBManifestName = @"manifest.plist";
static const unsigned long long LBMaxImportBytes = 300ULL * 1024ULL * 1024ULL;

static NSString *LBPosterBoardRefreshStatus(NSDictionary *report) {
    BOOL preferencesWritten = [report[@"refreshPreferencesWritten"] boolValue];
    BOOL refreshCompleted = [report[@"posterBoardRefreshRequested"] boolValue];
    BOOL commandAttempted = [report[@"refreshCommandAttempted"] boolValue];

    if (refreshCompleted) {
        return @"A PosterBoard refresh command completed successfully; actual gallery reload remains unverified.";
    }
    if (!preferencesWritten) {
        return @"PosterBoard refresh flags could not be written or verified. A device restart may be needed to reload the published descriptors.";
    }
    if (!commandAttempted) {
        return @"PosterBoard refresh flags were written. LumenBoard does not terminate or signal system processes; a device restart may be needed to reload the published descriptors.";
    }
    return @"PosterBoard refresh flags were written, but the refresh command did not complete successfully. A device restart may be needed to reload the published descriptors.";
}

static NSString *LBSHA256ForFile(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    [stream open];
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024]; NSInteger count = 0;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    NSError *streamError = stream.streamError; [stream close];
    if (count < 0 || streamError) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}


static NSDictionary *LBReadManagedManifest(NSString *entry) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:entry ?: @""];
    if (!uuid || [uuid.UUIDString.lowercaseString isEqualToString:entry.lowercaseString] == NO) return nil;
    NSString *folder = [LBLibraryPath() stringByAppendingPathComponent:entry];
    struct stat st;
    if (lstat(folder.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return nil;
    NSString *manifestPath = [folder stringByAppendingPathComponent:LBManifestName];
    struct stat manifestStat;
    if (lstat(manifestPath.fileSystemRepresentation, &manifestStat) != 0 ||
        !S_ISREG(manifestStat.st_mode) || S_ISLNK(manifestStat.st_mode) ||
        manifestStat.st_size <= 0 || manifestStat.st_size > 1024 * 1024) return nil;
    id loaded = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    if (![loaded isKindOfClass:NSDictionary.class]) return nil;
    id identifier = loaded[@"identifier"];
    if (![identifier isKindOfClass:NSString.class] || [identifier caseInsensitiveCompare:entry] != NSOrderedSame) return nil;
    return (NSDictionary *)loaded;
}


static BOOL LBWriteManagedManifest(NSMutableDictionary *manifest, NSString *itemDirectory, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:manifest
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    NSString *path = [itemDirectory stringByAppendingPathComponent:LBManifestName];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    chmod(path.fileSystemRepresentation, 0600);
    chmod(itemDirectory.fileSystemRepresentation, 0700);
    return YES;
}

static BOOL LBValidRequestUUID(NSString *value) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value ?: @""];
    return uuid != nil && [uuid.UUIDString.lowercaseString isEqualToString:value.lowercaseString];
}

static NSDictionary *LBReadValidatedCompletion(NSString *requestID, NSString *expectedAction, NSError **error) {
    if (!LBValidRequestUUID(requestID)) {
        if (error) *error = [NSError errorWithDomain:@"LumenBoard" code:211 userInfo:@{NSLocalizedDescriptionKey:@"The daemon request identifier is not a canonical UUID."}];
        return nil;
    }
    NSString *completionPath = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
    struct stat st;
    if (lstat(completionPath.fileSystemRepresentation, &st) != 0) return nil;
    if (!S_ISREG(st.st_mode) || S_ISLNK(st.st_mode) || st.st_size <= 0 || st.st_size > 1024 * 1024) {
        if (error) *error = [NSError errorWithDomain:@"LumenBoard" code:210 userInfo:@{NSLocalizedDescriptionKey:@"The daemon completion record is not a safe regular file."}];
        return nil;
    }
    NSDictionary *completion = [NSDictionary dictionaryWithContentsOfFile:completionPath];
    NSString *completionAction = [completion isKindOfClass:NSDictionary.class] && [completion[@"action"] isKindOfClass:NSString.class] ?
        completion[@"action"] : nil;
    BOOL actionMatches = !expectedAction.length || [completionAction isEqualToString:expectedAction];
    if (![completion isKindOfClass:NSDictionary.class] ||
        ![completion[@"requestID"] isEqualToString:requestID] ||
        ![completion[@"finished"] boolValue] ||
        !actionMatches) {
        if (error) *error = [NSError errorWithDomain:@"LumenBoard" code:211 userInfo:@{NSLocalizedDescriptionKey:@"The daemon returned an invalid completion record."}];
        return nil;
    }
    return completion;
}

static BOOL LBAcknowledgeDaemonCompletion(NSString *requestID) {
    if (!LBValidRequestUUID(requestID)) return NO;
    NSString *path = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return errno == ENOENT;
    if (!S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)) return NO;
    return [NSFileManager.defaultManager removeItemAtPath:path error:nil] ||
        (lstat(path.fileSystemRepresentation, &st) != 0 && errno == ENOENT);
}

static BOOL LBFinalizeAndAcknowledgeManifestCompletion(NSMutableDictionary *manifest,
                                                       NSString *itemDirectory,
                                                       NSString *requestID,
                                                       NSError **error) {
    if (requestID.length) manifest[@"daemonRequestID"] = requestID;
    // Phase A: commit the terminal manifest while retaining daemonRequestID so
    // an interruption before completion deletion remains discoverable on refresh.
    if (!LBWriteManagedManifest(manifest, itemDirectory, error)) {
        return NO;
    }
    // Phase B: remove the completion plist only after Phase A succeeded, then
    // clear daemonRequestID in a follow-up cleanup write.
    if (LBAcknowledgeDaemonCompletion(requestID)) {
        [manifest removeObjectForKey:@"daemonRequestID"];
        LBWriteManagedManifest(manifest, itemDirectory, nil);
    }
    return YES;
}

static NSDictionary *LBQueueDaemonActionAndWait(NSString *identifier, NSString *action, NSMutableDictionary *manifest, NSString *itemDirectory, NSString **requestIDOut, NSError **error) {
    if (!LBEnsureDaemonDirectories(error)) return nil;
    NSString *requestID = NSUUID.UUID.UUIDString.lowercaseString;
    // Persist the correlation ID before the daemon can observe the request.
    // If this write fails, do not enqueue work that Preferences cannot reconcile.
    if (manifest && itemDirectory) {
        manifest[@"daemonRequestID"] = requestID;
        if (!LBWriteManagedManifest(manifest, itemDirectory, error)) {
            [manifest removeObjectForKey:@"daemonRequestID"];
            return nil;
        }
    }
    NSDictionary *request = @{
        @"requestID": requestID,
        @"action": action,
        @"identifier": identifier,
        @"created": [NSDate date]
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:request
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) {
        if (manifest && itemDirectory) {
            [manifest removeObjectForKey:@"daemonRequestID"];
            LBWriteManagedManifest(manifest, itemDirectory, nil);
        }
        return nil;
    }
    NSString *requestPath = [LBRequestsPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
    if (![data writeToFile:requestPath options:NSDataWritingAtomic error:error] ||
        chmod(requestPath.fileSystemRepresentation, 0600) != 0) {
        if (error && !*error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        [NSFileManager.defaultManager removeItemAtPath:requestPath error:nil];
        if (manifest && itemDirectory) {
            [manifest removeObjectForKey:@"daemonRequestID"];
            LBWriteManagedManifest(manifest, itemDirectory, nil);
        }
        return nil;
    }
    if (requestIDOut) *requestIDOut = requestID;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)LBDarwinReloadNotification(), NULL, NULL, true);

    NSString *completionPath = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:90.0];
    while ([deadline timeIntervalSinceNow] > 0) {
        struct stat st;
        if (lstat(completionPath.fileSystemRepresentation, &st) == 0) {
            NSError *validationError = nil;
            NSDictionary *completion = LBReadValidatedCompletion(requestID, action, &validationError);
            if (!completion) {
                if (error) *error = validationError;
                return nil;
            }
            // Imports keep the completion until their final manifest write succeeds.
            // Verification-only calls have no managed manifest to commit.
            if (!manifest || !itemDirectory) [NSFileManager.defaultManager removeItemAtPath:completionPath error:nil];
            if (![completion[@"success"] boolValue]) {
                NSString *message = [completion[@"error"] isKindOfClass:NSString.class] ? completion[@"error"] : @"The PosterBoard daemon rejected the import.";
                NSInteger code = [completion[@"errorCode"] respondsToSelector:@selector(integerValue)] ? [completion[@"errorCode"] integerValue] : 212;
                if (error) *error = [NSError errorWithDomain:@"LumenBoard.PosterBoard" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
            }
            return completion;
        }
        usleep(250000);
    }
    if (error) *error = [NSError errorWithDomain:@"LumenBoard.PosterBoard" code:213 userInfo:@{
        NSLocalizedDescriptionKey:@"PosterBoard registration is still queued. The source and extracted descriptors were preserved; use Refresh local library to check again."
    }];
    return @{@"requestID":requestID, @"success":@NO, @"timedOut":@YES};
}


static NSDictionary *LBQueueTendiesImportAndWait(NSString *identifier, NSMutableDictionary *manifest, NSString *itemDirectory, NSString **requestIDOut, NSError **error) {
    return LBQueueDaemonActionAndWait(identifier, @"import-tendies", manifest, itemDirectory, requestIDOut, error);
}

static NSDictionary *LBQueueTendiesVerificationAndWait(NSString *identifier, NSError **error) {
    NSDictionary *completion = LBQueueDaemonActionAndWait(identifier, @"verify-tendies-registration", nil, nil, NULL, error);
    if (![completion[@"success"] boolValue]) return nil;
    return [completion[@"result"] isKindOfClass:NSDictionary.class] ? completion[@"result"] : nil;
}

@implementation LumenBoardRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LumenBoard";
}

- (void)importMediaTapped {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
    configuration.selectionLimit = 1;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)importTendiesTapped {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.data"]] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)manageLibraryTapped {
    NSError *error = nil;
    if (!LBEnsureUserDirectories(&error)) {
        [self showMessage:@"Library error" message:error.localizedDescription ?: @"Could not access the local library."];
        return;
    }
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:LBLibraryPath() error:nil] ?: @[];
    for (NSString *entry in entries) {
        NSDictionary *manifest = LBReadManagedManifest(entry);
        if (manifest) {
            NSString *folder = [LBLibraryPath() stringByAppendingPathComponent:entry];
            NSString *name = [manifest[@"originalName"] isKindOfClass:NSString.class] ? manifest[@"originalName"] : entry;
            NSString *status = [manifest[@"status"] isKindOfClass:NSString.class] ? manifest[@"status"] : @"unknown";
            [items addObject:@{@"folder": folder, @"identifier": manifest[@"identifier"], @"name": name, @"status": status}];
        }
    }
    if (items.count == 0) {
        [self showMessage:@"Local library" message:@"No imported items."];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Manage local items" message:@"Select an item to remove it from LumenBoard's local library. This does not change PosterBoard." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *item in items) {
        NSString *label = [NSString stringWithFormat:@"%@ — %@", item[@"name"], item[@"status"]];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            NSError *removeError = nil;
            NSString *folder = item[@"folder"];
            NSString *standardFolder = folder.stringByStandardizingPath;
            NSString *root = LBLibraryPath().stringByStandardizingPath;
            if (![standardFolder hasPrefix:[root stringByAppendingString:@"/"]] || [standardFolder isEqualToString:root]) {
                [self showMessage:@"Removal refused" message:@"The selected item path failed validation."];
                return;
            }
            struct stat st;
            if (lstat(standardFolder.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                [self showMessage:@"Removal refused" message:@"The selected item is not a regular managed directory."];
                return;
            }
            if (![NSFileManager.defaultManager removeItemAtPath:standardFolder error:&removeError]) {
                [self showMessage:@"Removal failed" message:removeError.localizedDescription ?: @"Unknown error."];
            } else {
                [self showMessage:@"Removed" message:@"The source was removed from LumenBoard's local library. PosterBoard was not modified."];
            }
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds) - 1, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)refreshLibraryTapped {
    NSError *error = nil;
    if (!LBEnsureDaemonDirectories(&error)) {
        [self showMessage:@"Library error" message:error.localizedDescription ?: @"Could not access the local library and daemon queue."];
        return;
    }
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:LBLibraryPath() error:&error] ?: @[];
    NSUInteger registered = 0, registering = 0, failed = 0, stored = 0;
    for (NSString *entry in entries) {
        NSMutableDictionary *manifest = [LBReadManagedManifest(entry) mutableCopy];
        if (!manifest) continue;
        NSString *status = [manifest[@"status"] isKindOfClass:NSString.class] ? manifest[@"status"] : @"unknown";
        NSString *requestID = [manifest[@"daemonRequestID"] isKindOfClass:NSString.class] ? manifest[@"daemonRequestID"] : nil;
        NSUUID *requestUUID = requestID ? [[NSUUID alloc] initWithUUIDString:requestID] : nil;
        BOOL requestIDIsValid = requestUUID && [requestUUID.UUIDString.lowercaseString isEqualToString:requestID.lowercaseString];
        NSString *itemDirectory = [LBLibraryPath() stringByAppendingPathComponent:entry];
        NSString *expectedAction = ([manifest[@"type"] isEqualToString:@"image"] || [manifest[@"type"] isEqualToString:@"video"]) ?
            @"install-media" : @"import-tendies";
        if (([status isEqualToString:@"registering"] || [status isEqualToString:@"generating"]) && requestIDIsValid) {
            NSString *completionPath = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
            struct stat completionStat;
            NSDictionary *completion = nil;
            if (lstat(completionPath.fileSystemRepresentation, &completionStat) == 0 &&
                S_ISREG(completionStat.st_mode) && !S_ISLNK(completionStat.st_mode) &&
                completionStat.st_size > 0 && completionStat.st_size <= 1024 * 1024) {
                completion = LBReadValidatedCompletion(requestID, expectedAction, nil);
            }
            if ([completion[@"requestID"] isEqualToString:requestID] && [completion[@"finished"] boolValue]) {
                NSString *pendingStatus = status;
                if ([completion[@"success"] boolValue]) {
                    manifest[@"status"] = @"registered-unverified";
                    BOOL mediaInstall = [completion[@"action"] isEqualToString:@"install-media"] ||
                        [manifest[@"type"] isEqualToString:@"image"] || [manifest[@"type"] isEqualToString:@"video"];
                    manifest[@"installationState"] = mediaInstall ? @"installed" : @"descriptors-published";
                    manifest[@"registeredAt"] = [NSDate date];
                    manifest[@"installationReport"] = completion[@"result"] ?: @{};
                    manifest[@"installedDescriptorIdentifiers"] = completion[@"result"][@"installedDescriptorIdentifiers"] ?: @[];
                } else {
                    manifest[@"status"] = @"failed";
                    manifest[@"installationState"] = @"failed";
                    manifest[@"installationError"] = completion[@"error"] ?: @"PosterBoard descriptor registration failed.";
                }
                NSError *reconciliationWriteError = nil;
                if (LBFinalizeAndAcknowledgeManifestCompletion(manifest, itemDirectory, requestID, &reconciliationWriteError)) {
                    status = [manifest[@"status"] isKindOfClass:NSString.class] ? manifest[@"status"] : @"unknown";
                } else {
                    // Keep both the durable pending request ID and completion record.
                    // A later refresh can retry this manifest commit safely.
                    manifest[@"status"] = pendingStatus;
                    manifest[@"installationState"] = @"queued";
                    manifest[@"daemonRequestID"] = requestID;
                    status = [pendingStatus isEqualToString:@"generating"] ? @"generating" : @"registering";
                }
            }
        } else if (([status isEqualToString:@"registered-unverified"] ||
                    [status isEqualToString:@"imported"] ||
                    [status isEqualToString:@"failed"]) && requestIDIsValid) {
            // Cleanup-only recovery for the Phase A -> Phase B crash window (or when
            // the daemon already persisted the terminal manifest state): acknowledge
            // a valid matching completion or clear a already-acknowledged UUID without
            // re-running or overwriting the terminal manifest state.
            NSString *completionPath = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
            struct stat completionStat;
            BOOL completionAbsent = (lstat(completionPath.fileSystemRepresentation, &completionStat) != 0 && errno == ENOENT);
            NSDictionary *completion = completionAbsent ? nil : LBReadValidatedCompletion(requestID, expectedAction, nil);
            if (completionAbsent || (completion && LBAcknowledgeDaemonCompletion(requestID))) {
                [manifest removeObjectForKey:@"daemonRequestID"];
                LBWriteManagedManifest(manifest, itemDirectory, nil);
            }
        }
        if ([status isEqualToString:@"registered-unverified"] || [status isEqualToString:@"imported"]) registered++;
        else if ([status isEqualToString:@"registering"] || [status isEqualToString:@"generating"]) registering++;
        else if ([status isEqualToString:@"failed"] || [status isEqualToString:@"invalid"] || [status isEqualToString:@"unsupported"]) failed++;
        else stored++;
    }
    [self showMessage:@"LumenBoard library"
        message:[NSString stringWithFormat:@"Descriptor records registered (PosterBoard visibility and application not device-verified): %lu\nGeneration/registration pending: %lu\nFailed: %lu\nLocal-only or not yet imported: %lu",
            (unsigned long)registered, (unsigned long)registering, (unsigned long)failed, (unsigned long)stored]];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *result = results.firstObject;
    if (!result) return;
    NSItemProvider *provider = result.itemProvider;
    BOOL isMovie = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
    NSString *typeIdentifier = isMovie ? UTTypeMovie.identifier : UTTypeImage.identifier;
    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier completionHandler:^(NSURL *url, NSError *error) {
        if (!url || error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:@"Import failed" message:error.localizedDescription ?: @"The selected media could not be read."]; });
            return;
        }
        NSString *resolved = url.pathExtension.lowercaseString;
        NSSet *allowed = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"tif", @"tiff", @"gif", @"mov", @"mp4", @"m4v"]];
        if (![allowed containsObject:resolved]) {
            UTType *selectedType = [UTType typeWithIdentifier:typeIdentifier];
            NSString *preferredExtension = selectedType.preferredFilenameExtension.lowercaseString;
            if ([allowed containsObject:preferredExtension]) resolved = preferredExtension;
        }
        if (![allowed containsObject:resolved]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:@"Unsupported media format" message:@"The selected media has no supported filename extension. Nothing was imported."];
            });
            return;
        }
        // PHPicker's file-representation URL is temporary and must be copied
        // before this completion handler returns. Stage it privately here, then
        // move the slower library/manifest work to the utility queue.
        struct stat pickedStat;
        BOOL pickedIsRegular = url.isFileURL &&
            (lstat(url.path.fileSystemRepresentation, &pickedStat) == 0 &&
             S_ISREG(pickedStat.st_mode) && !S_ISLNK(pickedStat.st_mode));
        if (!pickedIsRegular || pickedStat.st_size <= 0 || (unsigned long long)pickedStat.st_size > LBMaxImportBytes) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:@"Import failed" message:@"The selected media is not a regular file or exceeds the 300 MiB limit."];
            });
            return;
        }
        NSString *temporaryName = [NSString stringWithFormat:@"LumenBoard-%@.%@", NSUUID.UUID.UUIDString.lowercaseString, resolved];
        NSURL *stagedURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:temporaryName]];
        NSError *stagingError = nil;
        if (![NSFileManager.defaultManager copyItemAtURL:url toURL:stagedURL error:&stagingError] ||
            chmod(stagedURL.path.fileSystemRepresentation, 0600) != 0) {
            [NSFileManager.defaultManager removeItemAtURL:stagedURL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:@"Import failed" message:stagingError.localizedDescription ?: @"Could not stage the selected media safely."];
            });
            return;
        }
        [self importURL:stagedURL forcedExtension:resolved type:isMovie ? @"video" : @"image" cleanupTemporarySource:YES];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) return;
    if (![url.pathExtension.lowercaseString isEqualToString:@"tendies"]) {
        [self showMessage:@"Unsupported file" message:@"Choose a .tendies archive. Other file types are not imported by this action."];
        return;
    }
    [self importURL:url forcedExtension:@"tendies" type:@"tendies-unvalidated" cleanupTemporarySource:NO];
}

- (void)importURL:(NSURL *)url forcedExtension:(NSString *)forcedExtension type:(NSString *)type cleanupTemporarySource:(BOOL)cleanupTemporarySource {
    NSURL *sourceURL = [url copy];
    NSString *sourceExtension = [forcedExtension copy];
    NSString *sourceType = [type copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL access = sourceURL.isFileURL && [sourceURL startAccessingSecurityScopedResource];
        NSError *error = nil;
        BOOL stored = NO;
        BOOL preserveItemDirectory = NO;
        NSString *itemDirectory = nil;
        NSMutableDictionary *manifest = nil;
        NSString *finalStatus = @"failed";
        NSString *userMessage = nil;
        @try {
            struct stat sourceStat;
            BOOL sourceIsRegular = sourceURL.isFileURL &&
                (lstat(sourceURL.path.fileSystemRepresentation, &sourceStat) == 0 &&
                 S_ISREG(sourceStat.st_mode) && !S_ISLNK(sourceStat.st_mode));
            NSDictionary *attributes = sourceIsRegular ?
                [NSFileManager.defaultManager attributesOfItemAtPath:sourceURL.path error:&error] : nil;
            unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
            NSString *selectedSourceSHA256 = nil;
            if (!sourceIsRegular || !attributes || size == 0 || size > LBMaxImportBytes) {
                if (!error) error = [NSError errorWithDomain:@"LumenBoard" code:201 userInfo:@{
                    NSLocalizedDescriptionKey:@"The selected file is not a regular file, is empty, or exceeds the 300 MiB import limit."
                }];
            } else if (!(selectedSourceSHA256 = LBSHA256ForFile(sourceURL.path)).length) {
                error = [NSError errorWithDomain:@"LumenBoard" code:206 userInfo:@{
                    NSLocalizedDescriptionKey:@"Could not calculate SHA-256 for the selected source before copying."
                }];
            } else if (LBEnsureUserDirectories(&error)) {
                NSString *identifier = NSUUID.UUID.UUIDString.lowercaseString;
                itemDirectory = [LBLibraryPath() stringByAppendingPathComponent:identifier];
                BOOL createdItemDirectory = [NSFileManager.defaultManager createDirectoryAtPath:itemDirectory
                    withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error];
                if (createdItemDirectory) {
                    NSString *destination = [itemDirectory stringByAppendingPathComponent:[@"source" stringByAppendingPathExtension:sourceExtension]];
                    BOOL sourceStored = NO;
                    if (cleanupTemporarySource) {
                        NSError *moveError = nil;
                        sourceStored = [NSFileManager.defaultManager moveItemAtURL:sourceURL
                            toURL:[NSURL fileURLWithPath:destination] error:&moveError];
                        if (!sourceStored) {
                            error = nil;
                            sourceStored = [NSFileManager.defaultManager copyItemAtURL:sourceURL
                                toURL:[NSURL fileURLWithPath:destination] error:&error];
                            if (!sourceStored && !error) error = moveError;
                        }
                    } else {
                        sourceStored = [NSFileManager.defaultManager copyItemAtURL:sourceURL
                            toURL:[NSURL fileURLWithPath:destination] error:&error];
                    }
                    if (sourceStored) {
                        preserveItemDirectory = YES;
                        NSString *sha256 = LBSHA256ForFile(destination);
                        manifest = [@{
                            @"schemaVersion":@3,
                            @"identifier":identifier,
                            @"originalName":sourceURL.lastPathComponent ?: @"Imported item",
                            @"type":sourceType,
                            @"sourceFilename":destination.lastPathComponent,
                            @"sourceBytes":@(size),
                            @"importedAt":[NSDate date],
                            @"status":@"copying",
                            @"validatorVersion":@"1.1.0",
                            @"installationState":[sourceType isEqualToString:@"tendies-unvalidated"] ? @"not-started" : @"not-applicable"
                        } mutableCopy];
                        if (!sha256.length || ![sha256 isEqualToString:selectedSourceSHA256]) {
                            error = [NSError errorWithDomain:@"LumenBoard" code:202 userInfo:@{
                                NSLocalizedDescriptionKey:sha256.length ?
                                    @"The source file changed while it was being copied (SHA-256 mismatch)." :
                                    @"Could not calculate SHA-256 for the stored source file."
                            }];
                        } else {
                            manifest[@"sha256"] = sha256;
                            BOOL duplicateHandled = NO;
                            if ([sourceType isEqualToString:@"tendies-unvalidated"]) {
                                NSArray<NSString *> *existingEntries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:LBLibraryPath() error:nil] ?: @[];
                                for (NSString *existingEntry in existingEntries) {
                                    if ([existingEntry isEqualToString:identifier]) continue;
                                    NSDictionary *existing = LBReadManagedManifest(existingEntry);
                                    NSString *existingStatus = [existing[@"status"] isKindOfClass:NSString.class] ? existing[@"status"] : @"";
                                    if ([existing[@"type"] isEqualToString:@"tendies-unvalidated"] &&
                                        [existing[@"sha256"] isKindOfClass:NSString.class] &&
                                        [existing[@"sha256"] caseInsensitiveCompare:sha256] == NSOrderedSame &&
                                        ([existingStatus isEqualToString:@"imported"] || [existingStatus isEqualToString:@"registered-unverified"] || [existingStatus isEqualToString:@"registering"])) {
                                        duplicateHandled = YES;
                                        preserveItemDirectory = NO;
                                        stored = YES;
                                        finalStatus = existingStatus;
                                        if ([existingStatus isEqualToString:@"registering"]) {
                                            userMessage = @"This exact .tendies archive is already being registered. No second registration request was created.";
                                        } else {
                                            NSError *verificationError = nil;
                                            NSDictionary *verification = LBQueueTendiesVerificationAndWait(existingEntry, &verificationError);
                                            NSString *storeState = [verification[@"descriptorStoreState"] isKindOfClass:NSString.class] ?
                                                verification[@"descriptorStoreState"] : @"unavailable";
                                            NSUInteger expected = [verification[@"expectedDescriptorCount"] unsignedIntegerValue];
                                            NSUInteger present = [verification[@"presentDescriptorCount"] unsignedIntegerValue];
                                            NSUInteger missing = [verification[@"missingDescriptorCount"] unsignedIntegerValue];
                                            NSUInteger invalid = [verification[@"invalidDescriptorCount"] unsignedIntegerValue];
                                            if ([storeState isEqualToString:@"complete"]) {
                                                userMessage = [NSString stringWithFormat:
                                                    @"The exact archive was already registered. Read-only verification found all %lu previously published descriptor directories and their required plist/CAML structure in PosterBoard's Collections store. This verifies filesystem registration only—not native gallery visibility, selectability, or wallpaper application. No duplicate registration was created.",
                                                    (unsigned long)expected];
                                            } else if (verification) {
                                                NSArray *invalidDescriptors = [verification[@"invalidDescriptors"] isKindOfClass:NSArray.class] ? verification[@"invalidDescriptors"] : @[];
                                                NSString *firstInvalidReason = [invalidDescriptors.firstObject[@"error"] isKindOfClass:NSString.class] ? invalidDescriptors.firstObject[@"error"] : @"";
                                                NSString *compatibilityDetail = [firstInvalidReason containsString:@"targets an ipad screen class"] || [firstInvalidReason containsString:@"targets an iphone screen class"] ?
                                                    [NSString stringWithFormat:@" Device compatibility: %@.", firstInvalidReason] : @"";
                                                userMessage = [NSString stringWithFormat:
                                                    @"The exact archive was previously registered, but its live descriptor-store check is %@: %lu of %lu records valid, %lu missing, %lu invalid or incompatible.%@ No duplicate registration or automatic repair was attempted. PosterBoard gallery visibility and wallpaper application remain unverified.",
                                                    storeState, (unsigned long)present, (unsigned long)expected,
                                                    (unsigned long)missing, (unsigned long)invalid, compatibilityDetail];
                                            } else {
                                                userMessage = [NSString stringWithFormat:
                                                    @"The exact archive has a previous registration record, but live verification could not be completed: %@. No duplicate registration was created. PosterBoard gallery visibility and wallpaper application remain unverified.",
                                                    verificationError.localizedDescription ?: @"the daemon returned no verification result."];
                                            }
                                        }
                                        break;
                                    }
                                }
                            }
                            if (!duplicateHandled && [sourceType isEqualToString:@"tendies-unvalidated"]) {
                                manifest[@"status"] = @"validating";
                                if (!LBWriteManagedManifest(manifest, itemDirectory, &error)) {
                                    // Do not enqueue a source that has no durable manifest.
                                } else {
                                    NSString *extractionPath = [itemDirectory stringByAppendingPathComponent:@"Extracted"];
                                    manifest[@"status"] = @"extracting";
                                    LBWriteManagedManifest(manifest, itemDirectory, nil);
                                    NSError *validationError = nil;
                                    NSDictionary *validation = [LBTendiesValidator validateArchiveAtPath:destination
                                        extractToPath:extractionPath error:&validationError];
                                    NSString *validationStatus = [validation[@"status"] isKindOfClass:NSString.class] ? validation[@"status"] : @"incomplete";
                                    manifest[@"validationReport"] = validation ?: @{};
                                    manifest[@"validationStatus"] = validationStatus;
                                    manifest[@"validationError"] = validationError.localizedDescription ?: @"";
                                    if ([validationStatus isEqualToString:@"extracted"]) {
                                        manifest[@"status"] = @"registering";
                                        manifest[@"installationState"] = @"queued";
                                        manifest[@"extractionPath"] = @"Extracted";
                                        manifest[@"validationStatus"] = @"valid";
                                        if (LBWriteManagedManifest(manifest, itemDirectory, &error)) {
                                            NSString *requestID = nil;
                                            NSError *daemonError = nil;
                                            NSDictionary *completion = LBQueueTendiesImportAndWait(identifier, manifest, itemDirectory, &requestID, &daemonError);
                                            if (requestID.length) manifest[@"daemonRequestID"] = requestID;
                                            if (completion && [completion[@"success"] boolValue]) {
                                                NSDictionary *installationReport = [completion[@"result"] isKindOfClass:NSDictionary.class] ? completion[@"result"] : @{};
                                                manifest[@"status"] = @"registered-unverified";
                                                manifest[@"installationState"] = @"descriptors-published";
                                                manifest[@"registeredAt"] = [NSDate date];
                                                manifest[@"installationReport"] = installationReport;
                                                manifest[@"installedDescriptorIdentifiers"] = installationReport[@"installedDescriptorIdentifiers"] ?: @[];
                                                finalStatus = @"registered-unverified";
                                                stored = YES;
                                                userMessage = [NSString stringWithFormat:
                                                    @"The descriptor records were published to the iOS 16 PosterBoard Collections store. %@ Native gallery recognition, wallpaper selection, and actual application remain unverified on this device.",
                                                    LBPosterBoardRefreshStatus(installationReport)];
                                                if ([installationReport[@"refreshWarning"] isKindOfClass:NSString.class]) {
                                                    userMessage = [userMessage stringByAppendingFormat:@"\n\nRefresh details: %@", installationReport[@"refreshWarning"]];
                                                }
                                            } else if ([completion[@"timedOut"] boolValue] || (!completion && requestID.length)) {
                                                // A timeout or malformed/unreadable completion after dispatch must not
                                                // destroy recovery capability: preserve the pending status and requestID.
                                                manifest[@"status"] = @"registering";
                                                manifest[@"installationState"] = @"queued";
                                                manifest[@"installationError"] = daemonError.localizedDescription ?: @"The daemon has not responded yet.";
                                                finalStatus = @"registering";
                                                stored = YES;
                                                error = daemonError;
                                            } else {
                                                manifest[@"status"] = @"failed";
                                                manifest[@"installationState"] = @"failed";
                                                manifest[@"installationError"] = daemonError.localizedDescription ?: @"PosterBoard registration failed.";
                                                finalStatus = @"failed";
                                                error = daemonError;
                                            }
                                            NSError *finalManifestError = nil;
                                            if ([completion[@"finished"] boolValue]) {
                                                if (!LBFinalizeAndAcknowledgeManifestCompletion(manifest, itemDirectory, requestID, &finalManifestError)) {
                                                    manifest[@"status"] = @"registering";
                                                    manifest[@"installationState"] = @"queued";
                                                    manifest[@"daemonRequestID"] = requestID;
                                                    finalStatus = @"registering";
                                                    stored = YES;
                                                    error = finalManifestError;
                                                }
                                            } else {
                                                LBWriteManagedManifest(manifest, itemDirectory, &finalManifestError);
                                            }
                                        } else {
                                            manifest[@"status"] = @"failed";
                                            manifest[@"installationState"] = @"not-queued";
                                            finalStatus = @"failed";
                                        }
                                    } else {
                                        manifest[@"status"] = @"failed";
                                        manifest[@"installationState"] = @"validation-failed";
                                        finalStatus = validationStatus;
                                        error = validationError ?: [NSError errorWithDomain:@"LumenBoard" code:203 userInfo:@{NSLocalizedDescriptionKey:@"The .tendies archive did not pass structural validation."}];
                                        LBWriteManagedManifest(manifest, itemDirectory, nil);
                                    }
                                }
                            } else if (!duplicateHandled) {
                                manifest[@"status"] = @"generating";
                                manifest[@"installationState"] = @"queued";
                                manifest[@"homeBlur"] = @NO;
                                if (LBWriteManagedManifest(manifest, itemDirectory, &error)) {
                                    NSString *requestID = nil;
                                    NSError *daemonError = nil;
                                    NSDictionary *completion = LBQueueDaemonActionAndWait(identifier, @"install-media", manifest, itemDirectory, &requestID, &daemonError);
                                    if (requestID.length) manifest[@"daemonRequestID"] = requestID;
                                    if (completion && [completion[@"success"] boolValue]) {
                                        NSDictionary *report = [completion[@"result"] isKindOfClass:NSDictionary.class] ? completion[@"result"] : @{};
                                        manifest[@"status"] = @"registered-unverified";
                                        manifest[@"installationState"] = @"installed";
                                        manifest[@"installationReport"] = report;
                                        manifest[@"installedDescriptorIdentifiers"] = report[@"installedDescriptorIdentifiers"] ?: @[];
                                        manifest[@"registeredAt"] = [NSDate date];
                                        finalStatus = @"registered-unverified";
                                        stored = YES;
                                        userMessage = [NSString stringWithFormat:
                                            @"The media was converted into a PosterBoard descriptor and published to the iOS 16 Collections store. %@ Native gallery recognition, wallpaper selection, and actual application still require device verification.",
                                            LBPosterBoardRefreshStatus(report)];
                                        if ([report[@"refreshWarning"] isKindOfClass:NSString.class]) {
                                            userMessage = [userMessage stringByAppendingFormat:@"\n\nRefresh details: %@", report[@"refreshWarning"]];
                                        }
                                    } else if ([completion[@"timedOut"] boolValue] || (!completion && requestID.length)) {
                                        manifest[@"status"] = @"generating";
                                        manifest[@"installationState"] = @"queued";
                                        manifest[@"installationError"] = daemonError.localizedDescription ?: @"The media generation request is still queued.";
                                        finalStatus = @"generating";
                                        stored = YES;
                                        error = daemonError;
                                    } else {
                                        manifest[@"status"] = @"failed";
                                        manifest[@"installationState"] = @"failed";
                                        manifest[@"installationError"] = daemonError.localizedDescription ?: @"Native media wallpaper generation failed.";
                                        finalStatus = @"failed";
                                        error = daemonError;
                                    }
                                    NSError *finalManifestError = nil;
                                    if ([completion[@"finished"] boolValue]) {
                                        if (!LBFinalizeAndAcknowledgeManifestCompletion(manifest, itemDirectory, requestID, &finalManifestError)) {
                                            manifest[@"status"] = @"generating";
                                            manifest[@"installationState"] = @"queued";
                                            manifest[@"daemonRequestID"] = requestID;
                                            finalStatus = @"generating";
                                            stored = YES;
                                            error = finalManifestError;
                                        }
                                    } else {
                                        LBWriteManagedManifest(manifest, itemDirectory, &finalManifestError);
                                    }
                                } else {
                                    manifest[@"status"] = @"failed";
                                    manifest[@"installationState"] = @"not-queued";
                                    finalStatus = @"failed";
                                }
                            }
                        }
                    } else if (!error) {
                        error = [NSError errorWithDomain:@"LumenBoard" code:204 userInfo:@{NSLocalizedDescriptionKey:@"Could not copy the selected source into the private library."}];
                    }
                    if (createdItemDirectory && !preserveItemDirectory) [NSFileManager.defaultManager removeItemAtPath:itemDirectory error:nil];
                }
            }
        } @catch (NSException *exception) {
            error = [NSError errorWithDomain:@"LumenBoard" code:205 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Import failed."}];
            if (manifest) {
                manifest[@"status"] = @"failed";
                manifest[@"installationState"] = @"failed";
                manifest[@"installationError"] = error.localizedDescription;
                if (itemDirectory) LBWriteManagedManifest(manifest, itemDirectory, nil);
            }
        } @finally {
            if (access) [sourceURL stopAccessingSecurityScopedResource];
            if (cleanupTemporarySource) [NSFileManager.defaultManager removeItemAtURL:sourceURL error:nil];
        }

        NSString *title = nil;
        NSString *message = nil;
        if ([sourceType isEqualToString:@"tendies-unvalidated"]) {
            if ([finalStatus isEqualToString:@"registered-unverified"]) {
                title = @"Descriptor records registered";
                message = userMessage ?: @"Descriptor records were published. PosterBoard recognition, gallery visibility, selection, and actual wallpaper application have not been verified on this device.";
            } else if ([finalStatus isEqualToString:@"registering"]) {
                title = @"Registration queued";
                message = @"The archive passed validation and extraction. PosterBoard registration is queued; open Refresh local library to check the daemon result.";
            } else {
                title = @".tendies import failed";
                message = error.localizedDescription ?: @"Validation or PosterBoard registration failed. The source was retained for inspection.";
            }
        } else if ([finalStatus isEqualToString:@"registered-unverified"]) {
            title = @"Wallpaper descriptor registered";
            message = userMessage ?: @"The native descriptor was published. Gallery visibility and wallpaper application remain unverified on this device.";
        } else if ([finalStatus isEqualToString:@"generating"]) {
            title = @"Wallpaper generation queued";
            message = @"The source is preserved in the LumenBoard library. Native descriptor generation is still queued; use Refresh local library to check the daemon result.";
        } else {
            title = stored ? @"Import complete" : @"Import failed";
            message = stored ? @"The source is stored in LumenBoard's local library." : (error.localizedDescription ?: @"Unknown import error.");
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self showMessage:title message:message]; });
    });
}

- (void)showMessage:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

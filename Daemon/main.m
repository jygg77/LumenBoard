#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <unistd.h>
#import <pwd.h>
#import <errno.h>
#import <spawn.h>
#import <sys/wait.h>
#import "../Shared/LBPaths.h"
#import "LBPosterBoardInstaller.h"
#import "LBPosterMediaBuilder.h"

extern char **environ;

static BOOL LBRestartPosterBoard(void) {
    NSString *killallPath = nil;
    for (NSString *base in @[@"/var/jb/usr/bin", @"/usr/bin", @"/bin"]) {
        NSString *candidate = [base stringByAppendingPathComponent:@"killall"];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) {
            killallPath = candidate;
            break;
        }
    }
    if (!killallPath) {
        killallPath = @"/usr/bin/killall";
    }
    pid_t pid = 0;
    const char *argv[] = { [killallPath fileSystemRepresentation], "-9", "PosterBoard", NULL };
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ);
    if (rc == 0 && pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    return NO;
}

static NSLock *LBRequestLock;

static BOOL LBValidUUID(NSString *value) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value ?: @""];
    return uuid != nil && [uuid.UUIDString.lowercaseString isEqualToString:value.lowercaseString];
}

static BOOL LBRegularFile(NSString *path, unsigned long long maximumBytes) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) &&
        !S_ISLNK(st.st_mode) && st.st_size > 0 &&
        (unsigned long long)st.st_size <= maximumBytes;
}

static NSString *LBSHA256(NSString *path) {
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:path];
    if (!stream) return nil;
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    NSInteger count = 0;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    NSError *readError = stream.streamError;
    [stream close];
    if (count < 0 || readError) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [result appendFormat:@"%02x", digest[index]];
    return result;
}

static BOOL LBEnsureMobileOwnership(NSString *path) {
    struct passwd *mobile = getpwnam("mobile");
    if (!mobile) return geteuid() != 0;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0 || S_ISLNK(st.st_mode)) return NO;
    if (st.st_uid == mobile->pw_uid && st.st_gid == mobile->pw_gid) return YES;
    // The service runs in Dopamine's user/foreground domain (mobile). It may
    // publish files it already owns, but must never assume it has root chown rights.
    if (geteuid() != 0) return NO;
    return chown(path.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid) == 0;
}

static BOOL LBWriteCompletion(NSString *requestID, NSDictionary *payload) {
    if (!LBValidUUID(requestID)) return NO;
    NSString *destination = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data.length == 0) return NO;
    NSString *temporary = [destination stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString.lowercaseString];
    if (![data writeToFile:temporary options:NSDataWritingAtomic error:nil]) return NO;
    if (!LBEnsureMobileOwnership(temporary)) {
        unlink(temporary.fileSystemRepresentation);
        return NO;
    }
    chmod(temporary.fileSystemRepresentation, 0600);
    if (rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
        unlink(temporary.fileSystemRepresentation);
        return NO;
    }
    chmod(destination.fileSystemRepresentation, 0600);
    return YES;
}

static NSDictionary *LBLoadManagedTendiesItem(NSString *identifier, NSError **error) {
    if (!LBValidUUID(identifier)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:100 userInfo:@{NSLocalizedDescriptionKey:@"Invalid managed item identifier."}];
        return nil;
    }
    NSString *itemRoot = [LBLibraryPath() stringByAppendingPathComponent:identifier];
    struct stat rootStat;
    if (lstat(itemRoot.fileSystemRepresentation, &rootStat) != 0 || !S_ISDIR(rootStat.st_mode) || S_ISLNK(rootStat.st_mode)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:101 userInfo:@{NSLocalizedDescriptionKey:@"Managed library item directory is missing or unsafe."}];
        return nil;
    }
    NSString *manifestPath = [itemRoot stringByAppendingPathComponent:@"manifest.plist"];
    if (!LBRegularFile(manifestPath, 1024 * 1024)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:102 userInfo:@{NSLocalizedDescriptionKey:@"Managed item manifest is missing or unsafe."}];
        return nil;
    }
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
    if (![manifest isKindOfClass:NSDictionary.class] ||
        ![manifest[@"identifier"] isKindOfClass:NSString.class] ||
        [manifest[@"identifier"] caseInsensitiveCompare:identifier] != NSOrderedSame ||
        ![manifest[@"type"] isEqual:@"tendies-unvalidated"]) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:103 userInfo:@{NSLocalizedDescriptionKey:@"Managed item manifest does not identify a supported .tendies source."}];
        return nil;
    }
    NSString *filename = [manifest[@"sourceFilename"] isKindOfClass:NSString.class] ? manifest[@"sourceFilename"] : nil;
    if (![filename isEqualToString:@"source.tendies"]) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:104 userInfo:@{NSLocalizedDescriptionKey:@"Managed .tendies filename is not the expected private source file."}];
        return nil;
    }
    NSString *sourcePath = [itemRoot stringByAppendingPathComponent:filename];
    if (!LBRegularFile(sourcePath, 300ULL * 1024ULL * 1024ULL)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:105 userInfo:@{NSLocalizedDescriptionKey:@"Managed .tendies source is missing, unsafe, or exceeds 300 MiB."}];
        return nil;
    }
    id hashValue = manifest[@"sha256"];
    NSString *expectedHash = [hashValue isKindOfClass:NSString.class] ? [(NSString *)hashValue lowercaseString] : nil;
    NSString *actualHash = LBSHA256(sourcePath);
    if (!expectedHash.length || !actualHash.length || ![expectedHash isEqualToString:actualHash]) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:106 userInfo:@{NSLocalizedDescriptionKey:@"The source archive SHA-256 does not match the stored import manifest."}];
        return nil;
    }
    return @{@"identifier":identifier, @"sourcePath":sourcePath, @"manifestPath":manifestPath, @"manifest":manifest, @"sha256":actualHash};
}

static NSDictionary *LBProcessImportRequest(NSDictionary *request, NSError **error) {
    NSString *identifier = [request[@"identifier"] isKindOfClass:NSString.class] ? request[@"identifier"] : nil;
    NSDictionary *item = LBLoadManagedTendiesItem(identifier, error);
    if (!item) return nil;

    NSDictionary *existingManifest = item[@"manifest"];
    // A previous daemon cycle may have completed installation but failed while
    // writing the completion record. Reuse its durable result instead of
    // publishing duplicate descriptors.
    BOOL previouslyPublished =
        ([existingManifest[@"status"] isEqualToString:@"registered-unverified"] &&
         [existingManifest[@"installationState"] isEqualToString:@"descriptors-published"]) ||
        ([existingManifest[@"status"] isEqualToString:@"imported"] &&
         [existingManifest[@"installationState"] isEqualToString:@"installed"]);
    if (previouslyPublished && [existingManifest[@"installationReport"] isKindOfClass:NSDictionary.class]) {
        return existingManifest[@"installationReport"];
    }

    NSString *container = [LBPosterBoardInstaller findPosterBoardContainer:error];
    if (!container) return nil;

    NSDictionary *installation = [LBPosterBoardInstaller installArchiveAtPath:item[@"sourcePath"]
        posterBoardContainer:container error:error];
    if (!installation) return nil;

    // "Published" is a filesystem registration result, not proof that PosterBoard
    // reloaded the store or that the wallpaper is visible/selectable/applied.
    NSMutableDictionary *report = [installation mutableCopy];
    BOOL restarted = LBRestartPosterBoard();
    report[@"refreshCommandAttempted"] = @YES;
    report[@"posterBoardRefreshRequested"] = @(restarted);
    if (restarted) {
        report[@"posterBoardRefreshRequiresDeviceRestart"] = @NO;
        report[@"refreshWarning"] = @"PosterBoard was restarted via killall -9 to immediately reload published descriptors.";
    }
    report[@"descriptorRegistrationState"] = @"published";
    report[@"posterBoardApplicationState"] = @"unverified";
    NSMutableDictionary *manifest = [item[@"manifest"] mutableCopy];
    manifest[@"status"] = @"registered-unverified";
    manifest[@"installationState"] = @"descriptors-published";
    manifest[@"registeredAt"] = [NSDate date];
    manifest[@"installedDescriptorIdentifiers"] = report[@"installedDescriptorIdentifiers"] ?: @[];
    manifest[@"installationReport"] = report;
    NSData *manifestData = [NSPropertyListSerialization dataWithPropertyList:manifest
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!manifestData || ![manifestData writeToFile:item[@"manifestPath"] options:NSDataWritingAtomic error:error]) {
        // The descriptors are already safely published. Do not remove them because
        // a local manifest write failure must not turn a completed system install into
        // a destructive rollback. The completion tells the UI to report the mismatch.
        NSMutableDictionary *result = [report mutableCopy];
        result[@"manifestUpdateWarning"] = @"PosterBoard descriptors were installed, but the local manifest could not be updated.";
        return result;
    }
    if (!LBEnsureMobileOwnership(item[@"manifestPath"])) {
        NSMutableDictionary *result = [report mutableCopy];
        result[@"manifestUpdateWarning"] = @"Descriptors were published, but the daemon could not verify mobile ownership of the updated manifest.";
        return result;
    }
    chmod([item[@"manifestPath"] fileSystemRepresentation], 0600);
    return report;
}


static NSDictionary *LBVerifyManagedTendiesRegistration(NSDictionary *request, NSError **error) {
    NSString *identifier = [request[@"identifier"] isKindOfClass:NSString.class] ? request[@"identifier"] : nil;
    NSDictionary *item = LBLoadManagedTendiesItem(identifier, error);
    if (!item) return nil;
    NSDictionary *manifest = item[@"manifest"];
    NSArray *installedIdentifiers = [manifest[@"installedDescriptorIdentifiers"] isKindOfClass:NSArray.class] ?
        manifest[@"installedDescriptorIdentifiers"] : nil;

    // Older .tendies imports persisted the complete installer report but did
    // not copy its descriptor UUID list to the manifest's top level. Recover
    // that already-durable list before declaring reconciliation impossible.
    // This is read-only with respect to PosterBoard: it never guesses UUIDs
    // from names, scans unrelated descriptors, or republishes the archive.
    if (installedIdentifiers.count == 0) {
        NSDictionary *legacyReport = [manifest[@"installationReport"] isKindOfClass:NSDictionary.class] ?
            manifest[@"installationReport"] : nil;
        NSArray *reportedIdentifiers = [legacyReport[@"installedDescriptorIdentifiers"] isKindOfClass:NSArray.class] ?
            legacyReport[@"installedDescriptorIdentifiers"] : nil;
        if (reportedIdentifiers.count > 0 && reportedIdentifiers.count <= 256) {
            installedIdentifiers = reportedIdentifiers;
        }
    }
    if (installedIdentifiers.count == 0 || installedIdentifiers.count > 256) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:120
            userInfo:@{NSLocalizedDescriptionKey:@"This managed archive has no recoverable, bounded list of published descriptor UUIDs in its manifest or saved installation report; no filesystem-wide guess or duplicate publication was attempted."}];
        return nil;
    }

    NSString *container = [LBPosterBoardInstaller findPosterBoardContainer:error];
    if (!container) return nil;
    NSDictionary *verification = [LBPosterBoardInstaller verifyRegisteredDescriptorIdentifiers:installedIdentifiers
        posterBoardContainer:container error:error];
    if (!verification) return nil;

    NSMutableDictionary *updatedManifest = [manifest mutableCopy];
    updatedManifest[@"lastRegistrationVerification"] = verification;
    updatedManifest[@"lastRegistrationVerificationAt"] = [NSDate date];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:updatedManifest
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:item[@"manifestPath"] options:NSDataWritingAtomic error:error]) return nil;
    if (!LBEnsureMobileOwnership(item[@"manifestPath"])) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:121
            userInfo:@{NSLocalizedDescriptionKey:@"Descriptor verification completed, but the updated manifest's mobile ownership could not be confirmed."}];
        return nil;
    }
    chmod([item[@"manifestPath"] fileSystemRepresentation], 0600);

    NSMutableDictionary *result = [verification mutableCopy];
    result[@"manifestUpdated"] = @YES;
    result[@"registeredArchiveSHA256"] = item[@"sha256"];
    return result;
}

static NSDictionary *LBProcessMediaInstallRequest(NSDictionary *request, NSError **error) {
    NSString *identifier = [request[@"identifier"] isKindOfClass:NSString.class] ? request[@"identifier"] : nil;
    if (!LBValidUUID(identifier)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:130 userInfo:@{NSLocalizedDescriptionKey:@"Invalid managed media identifier."}];
        return nil;
    }
    NSString *itemRoot = [LBLibraryPath() stringByAppendingPathComponent:identifier];
    struct stat itemRootStat;
    if (lstat(itemRoot.fileSystemRepresentation, &itemRootStat) != 0 ||
        !S_ISDIR(itemRootStat.st_mode) || S_ISLNK(itemRootStat.st_mode)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:135
            userInfo:@{NSLocalizedDescriptionKey:@"Managed media item directory is missing, not a directory, or is a symlink."}];
        return nil;
    }
    NSString *manifestPath = [itemRoot stringByAppendingPathComponent:@"manifest.plist"];
    if (!LBRegularFile(manifestPath, 1024 * 1024)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:131 userInfo:@{NSLocalizedDescriptionKey:@"Managed media manifest is missing or unsafe."}];
        return nil;
    }
    NSMutableDictionary *manifest = [[NSDictionary dictionaryWithContentsOfFile:manifestPath] mutableCopy];
    NSString *kind = [manifest[@"type"] isKindOfClass:NSString.class] ? manifest[@"type"] : nil;
    NSString *filename = [manifest[@"sourceFilename"] isKindOfClass:NSString.class] ? manifest[@"sourceFilename"] : nil;
    NSSet<NSString *> *allowedImageExtensions = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"tif", @"tiff", @"gif"]];
    NSSet<NSString *> *allowedVideoExtensions = [NSSet setWithArray:@[@"mov", @"mp4", @"m4v"]];
    NSSet<NSString *> *allowedExtensions = [kind isEqualToString:@"image"] ? allowedImageExtensions : allowedVideoExtensions;
    NSString *sourceExtension = filename.pathExtension.lowercaseString;
    BOOL canonicalSourceFilename = sourceExtension.length > 0 &&
        [filename isEqualToString:[@"source" stringByAppendingPathExtension:sourceExtension]] &&
        [allowedExtensions containsObject:sourceExtension];
    if (![manifest[@"identifier"] isEqualToString:identifier] ||
        (![kind isEqualToString:@"image"] && ![kind isEqualToString:@"video"]) ||
        !canonicalSourceFilename) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:132 userInfo:@{NSLocalizedDescriptionKey:@"Managed manifest does not describe a supported image or video source."}];
        return nil;
    }
    NSString *sourcePath = [itemRoot stringByAppendingPathComponent:filename];
    if (!LBRegularFile(sourcePath, 300ULL * 1024ULL * 1024ULL)) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:133 userInfo:@{NSLocalizedDescriptionKey:@"Managed media source is missing, unsafe, or exceeds 300 MiB."}];
        return nil;
    }
    NSString *expectedHash = [manifest[@"sha256"] isKindOfClass:NSString.class] ? [manifest[@"sha256"] lowercaseString] : nil;
    NSString *actualHash = LBSHA256(sourcePath);
    if (!expectedHash.length || !actualHash.length || ![expectedHash isEqualToString:actualHash]) {
        if (error) *error = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:134 userInfo:@{NSLocalizedDescriptionKey:@"The stored media SHA-256 does not match its import manifest."}];
        return nil;
    }
    if ([manifest[@"installationState"] isEqualToString:@"installed"] &&
        [manifest[@"installationReport"] isKindOfClass:NSDictionary.class]) return manifest[@"installationReport"];

    NSString *container = [LBPosterBoardInstaller findPosterBoardContainer:error];
    if (!container) return nil;
    NSString *descriptorRoot = [[container stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore/59/Extensions"]
        stringByAppendingPathComponent:[@"com.apple.WallpaperKit.CollectionsPoster" stringByAppendingPathComponent:@"descriptors"]];
    NSString *generatedRoot = [itemRoot stringByAppendingPathComponent:@"Generated"];
    [[NSFileManager defaultManager] removeItemAtPath:generatedRoot error:nil];
    NSString *title = [manifest[@"originalName"] isKindOfClass:NSString.class] ? [manifest[@"originalName"] stringByDeletingPathExtension] : @"LumenBoard";
    NSString *descriptor = [LBPosterMediaBuilder buildDescriptorForSource:sourcePath kind:kind title:title
        homeBlur:[manifest[@"homeBlur"] boolValue] outputRoot:generatedRoot error:error];
    if (!descriptor) return nil;
    NSDictionary *installed = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:generatedRoot descriptorRoot:descriptorRoot error:error];
    if (!installed) return nil;
    NSMutableDictionary *report = [installed mutableCopy];
    [report addEntriesFromDictionary:[LBPosterBoardInstaller requestPosterBoardRefreshForContainer:container]];
    BOOL restarted = LBRestartPosterBoard();
    report[@"refreshCommandAttempted"] = @YES;
    report[@"posterBoardRefreshRequested"] = @(restarted);
    if (restarted) {
        report[@"posterBoardRefreshRequiresDeviceRestart"] = @NO;
        report[@"refreshWarning"] = @"PosterBoard was restarted via killall -9 to immediately reload published descriptors.";
    }
    report[@"sourceKind"] = kind;
    report[@"sourceSHA256"] = actualHash;
    report[@"descriptorRegistrationState"] = @"published";
    report[@"posterBoardApplicationState"] = @"unverified";
    manifest[@"status"] = @"registered-unverified";
    manifest[@"installationState"] = @"installed";
    manifest[@"installedDescriptorIdentifiers"] = report[@"installedDescriptorIdentifiers"] ?: @[];
    manifest[@"installationReport"] = report;
    manifest[@"registeredAt"] = [NSDate date];
    NSData *manifestData = [NSPropertyListSerialization dataWithPropertyList:manifest format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!manifestData || ![manifestData writeToFile:manifestPath options:NSDataWritingAtomic error:error]) {
        // Descriptor publication is already committed. Preserve that success
        // boundary and surface the manifest problem as a warning, not a false
        // import failure or a destructive rollback.
        report[@"manifestUpdateWarning"] = @"Wallpaper descriptors were published, but the managed manifest could not be updated.";
        return report;
    }
    if (!LBEnsureMobileOwnership(manifestPath)) {
        report[@"manifestUpdateWarning"] = @"Wallpaper descriptors were published, but mobile ownership of the updated manifest could not be confirmed.";
        return report;
    }
    if (chmod(manifestPath.fileSystemRepresentation, 0600) != 0) {
        report[@"manifestUpdateWarning"] = [NSString stringWithFormat:@"Wallpaper descriptors were published, but manifest permissions could not be secured (errno %d).", errno];
        return report;
    }
    return report;
}

static NSDictionary *LBProcessRefreshRequest(__unused NSDictionary *request, NSError **error) {
    NSString *container = [LBPosterBoardInstaller findPosterBoardContainer:error];
    if (!container) return nil;
    NSDictionary *refresh = [LBPosterBoardInstaller requestPosterBoardRefreshForContainer:container];
    BOOL restarted = LBRestartPosterBoard();
    NSMutableDictionary *report = [refresh mutableCopy];
    report[@"refreshCommandAttempted"] = @YES;
    report[@"posterBoardRefreshRequested"] = @(restarted);
    return report;
}

static void LBProcessRequests(void) {
    [LBRequestLock lock];
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *directoryError = nil;
        if (!LBEnsureDaemonDirectories(&directoryError)) {
            NSLog(@"[LumenBoard] Cannot initialize IPC directories: %@", directoryError);
            return;
        }
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:LBRequestsPath() error:nil] ?: @[];
        for (NSString *entry in entries) @autoreleasepool {
            if (![entry.pathExtension.lowercaseString isEqualToString:@"plist"]) continue;
            NSString *requestID = entry.stringByDeletingPathExtension.lowercaseString;
            if (!LBValidUUID(requestID)) continue;
            NSString *path = [LBRequestsPath() stringByAppendingPathComponent:entry];
            if (!LBRegularFile(path, 1024 * 1024)) continue;

            NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![request isKindOfClass:NSDictionary.class] ||
                ![request[@"requestID"] isKindOfClass:NSString.class] ||
                [request[@"requestID"] caseInsensitiveCompare:requestID] != NSOrderedSame) {
                [fm removeItemAtPath:path error:nil];
                continue;
            }

            NSString *completionPath = [LBCompletedPath() stringByAppendingPathComponent:[requestID stringByAppendingPathExtension:@"plist"]];
            NSDictionary *priorCompletion = [NSDictionary dictionaryWithContentsOfFile:completionPath];
            if ([priorCompletion isKindOfClass:NSDictionary.class] &&
                [priorCompletion[@"requestID"] isEqualToString:requestID] &&
                [priorCompletion[@"finished"] boolValue]) {
                [fm removeItemAtPath:path error:nil];
                continue;
            }

            NSError *operationError = nil;
            NSDictionary *operationResult = nil;
            NSString *action = [request[@"action"] isKindOfClass:NSString.class] ? request[@"action"] : @"";
            if ([action isEqualToString:@"import-tendies"]) {
                operationResult = LBProcessImportRequest(request, &operationError);
            } else if ([action isEqualToString:@"verify-tendies-registration"]) {
                operationResult = LBVerifyManagedTendiesRegistration(request, &operationError);
            } else if ([action isEqualToString:@"install-media"]) {
                operationResult = LBProcessMediaInstallRequest(request, &operationError);
            } else if ([action isEqualToString:@"refresh-posterboard"]) {
                operationResult = LBProcessRefreshRequest(request, &operationError);
            } else {
                operationError = [NSError errorWithDomain:@"com.iuyghi.LumenBoard.Daemon" code:110 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported daemon action."}];
            }

            NSMutableDictionary *completion = [@{
                @"requestID":requestID,
                @"action":action,
                @"finished":@YES,
                @"success":@(operationResult != nil)
            } mutableCopy];
            if (operationResult) completion[@"result"] = operationResult;
            if (operationError) {
                completion[@"error"] = operationError.localizedDescription ?: @"Native import failed.";
                completion[@"errorCode"] = @(operationError.code);
            }
            if (!LBWriteCompletion(requestID, completion)) {
                NSLog(@"[LumenBoard] Failed to write completion for request %@", requestID);
                continue;
            }
            [fm removeItemAtPath:path error:nil];
        }
    } @finally {
        [LBRequestLock unlock];
    }
}

static void LBNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    @autoreleasepool { LBProcessRequests(); }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        LBRequestLock = [NSLock new];
        NSError *error = nil;
        if (!LBEnsureDaemonDirectories(&error)) {
            NSLog(@"[LumenBoard] Cannot initialize support directories: %@", error);
            return 1;
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            LBNotificationCallback, (__bridge CFStringRef)LBDarwinReloadNotification(), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        LBProcessRequests();
        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { LBProcessRequests(); }
        }];
        (void)timer;
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}

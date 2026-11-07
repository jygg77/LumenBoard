#import "LBPosterBoardInstaller.h"
#import "../Preferences/LBTendiesValidator.h"
#import <sqlite3.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <fcntl.h>
#import <stdlib.h>
#import <limits.h>
#import <unistd.h>
#import <errno.h>
#import <pwd.h>
#import <stdio.h>
#import <string.h>
#import <sys/sysctl.h>

static NSString * const LBIssueDomain = @"com.iuyghi.LumenBoard.PosterBoardInstaller";
static NSString * const LBCollectionsExtension = @"com.apple.WallpaperKit.CollectionsPoster";
static NSString * const LBCollectionsAppExtension = @"com.apple.Posters.CollectionsPosterApp";
static const NSInteger LBExpectedStructureVersion = 59;

static NSError *LBInstallError(NSInteger code, NSString *message);

static NSString *LBDeviceFamilyForMachineIdentifier(NSString *machineIdentifier) {
    if ([machineIdentifier hasPrefix:@"iPhone"]) return @"iphone";
    if ([machineIdentifier hasPrefix:@"iPad"]) return @"ipad";
    return nil;
}

static NSString *LBCurrentDeviceMachineIdentifier(void) {
    char machine[128] = {0};
    size_t size = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0 ||
        size == 0 || size > sizeof(machine)) return nil;
    machine[sizeof(machine) - 1] = '\0';
    return [NSString stringWithUTF8String:machine];
}

static BOOL LBValidateDeviceFamilyForLogicalScreenClass(NSString *logicalScreenClass,
                                                        NSString *machineIdentifier,
                                                        NSError **error) {
    NSString *deviceFamily = LBDeviceFamilyForMachineIdentifier(machineIdentifier);
    if (!deviceFamily) return YES; // Unknown host (including macOS XCTest) is not a device verdict.
    if (![logicalScreenClass isKindOfClass:NSString.class]) {
        if (error) *error = LBInstallError(36, @"Wallpaper logicalScreenClass is missing or is not a string.");
        return NO;
    }
    NSString *targetFamily = [[logicalScreenClass componentsSeparatedByString:@"~"] lastObject];
    if (![targetFamily isEqualToString:@"iphone"] && ![targetFamily isEqualToString:@"ipad"]) {
        if (error) *error = LBInstallError(36, [NSString stringWithFormat:
            @"Wallpaper logicalScreenClass %@ does not declare an iPhone or iPad target.", logicalScreenClass ?: @"(missing)"]);
        return NO;
    }
    // The logicalScreenClass suffix is descriptive metadata, not a reliable
    // cross-device compatibility verdict. PosterBoard can render descriptors
    // whose declared family differs from the host (confirmed with a real
    // iPhone 13 using an ~ipad descriptor). Do not block publication on this
    // mismatch; retain validation of the field's syntax above.
    return YES;
}

static NSError *LBInstallError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LBIssueDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"PosterBoard installation failed."}];
}

static BOOL LBIsRegularFile(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode);
}

static BOOL LBIsDirectory(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode);
}

static BOOL LBEnsureDirectoryTree(NSString *path, mode_t mode, NSError **error) {
    NSString *normalized = [path stringByStandardizingPath];
    if (![normalized hasPrefix:@"/"]) {
        if (error) *error = LBInstallError(9, @"PosterBoard destination must be an absolute path.");
        return NO;
    }
    NSMutableString *current = [NSMutableString string];
    for (NSString *component in [normalized componentsSeparatedByString:@"/"]) {
        if (!component.length) continue;
        [current appendFormat:@"/%@", component];
        NSString *candidate = [current copy];
        struct stat st;
        if (lstat(candidate.fileSystemRepresentation, &st) == 0) {
            if (S_ISLNK(st.st_mode) && [candidate isEqualToString:@"/var"]) {
                // On Apple platforms /var is a system alias for /private/var.
                // Resolve only this known platform alias; reject all other
                // symlink components so an attacker cannot redirect root writes.
                char resolved[PATH_MAX] = {0};
                if (!realpath(candidate.fileSystemRepresentation, resolved)) {
                    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                    return NO;
                }
                [current setString:[NSString stringWithUTF8String:resolved]];
                continue;
            }
            if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
                if (error) *error = LBInstallError(10, [NSString stringWithFormat:@"Refusing a non-directory or symlink at %@", candidate]);
                return NO;
            }
            continue;
        }
        if (errno != ENOENT || mkdir(candidate.fileSystemRepresentation, mode) != 0) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
    }
    return YES;
}

static BOOL LBSetMobileOwnership(NSString *root, NSError **error) {
    struct passwd *mobile = getpwnam("mobile");
    // XCTest hosts do not have an iOS mobile account. Production runs in
    // user/foreground as mobile; files created there should already be owned
    // by mobile. Only a root process may repair a mismatched owner/group.
    if (!mobile && geteuid() == 0) {
        if (error) *error = LBInstallError(11, @"The mobile user could not be resolved for PosterBoard descriptor ownership.");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
    NSString *relative = nil;
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:root];
    while ((relative = enumerator.nextObject)) [paths addObject:[root stringByAppendingPathComponent:relative]];
    // Change descendants before parents so the staged tree is readable when published.
    for (NSString *path in [paths reverseObjectEnumerator]) {
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || S_ISLNK(st.st_mode) ||
            (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))) {
            if (error) *error = LBInstallError(12, [NSString stringWithFormat:@"Unsafe object in staged descriptor: %@", path]);
            return NO;
        }
        mode_t mode = S_ISDIR(st.st_mode) ? 0755 : 0644;
        if (mobile && (st.st_uid != mobile->pw_uid || st.st_gid != mobile->pw_gid)) {
            if (geteuid() != 0 || chown(path.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid) != 0) {
                if (error) *error = LBInstallError(14, @"The daemon does not own the staged descriptor as mobile and cannot change ownership from the user/foreground launchd domain.");
                return NO;
            }
        }
        if (chmod(path.fileSystemRepresentation, mode) != 0) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
    }
    return YES;
}

static BOOL LBEnsureDirectory(NSString *path, mode_t mode, NSError **error) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) == 0) {
        if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) return YES;
        if (error) *error = LBInstallError(13, [NSString stringWithFormat:@"Refusing a non-directory or symlink at %@", path]);
        return NO;
    }
    if (errno != ENOENT || mkdir(path.fileSystemRepresentation, mode) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    return YES;
}

static BOOL LBWriteDataAtomically(NSData *data, NSString *path, NSError **error) {
    NSString *temporary = [path stringByAppendingFormat:@".lumenboard-%@", NSUUID.UUID.UUIDString.lowercaseString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL
#ifdef O_NOFOLLOW
                  | O_NOFOLLOW
#endif
                  , 0600);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    BOOL ok = YES;
    while (offset < data.length) {
        ssize_t count = write(fd, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (NSUInteger)count;
    }
    if (ok && fsync(fd) != 0) ok = NO;
    int savedErrno = errno;
    close(fd);
    if (!ok || rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        if (ok) savedErrno = errno;
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
        return NO;
    }
    chmod(path.fileSystemRepresentation, 0600);
    return YES;
}

static NSString *LBReadTrimmedString(NSString *path) {
    if (!LBIsRegularFile(path)) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0 || data.length > 128) return nil;
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL LBIsPositiveNumericIdentifier(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        long long number = [(NSNumber *)value longLongValue];
        return number > 0 && number <= 999999;
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSScanner *scanner = trimmed.length ? [NSScanner scannerWithString:trimmed] : nil;
        long long number = 0;
        return scanner && [scanner scanLongLong:&number] && scanner.isAtEnd && number > 0 && number <= 999999;
    }
    return NO;
}

static BOOL LBPathIsSafeRelative(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0 || [path hasPrefix:@"/"] || [path containsString:@"\\"]) return NO;
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    for (NSString *part in parts) if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) return NO;
    return YES;
}

@interface LBCAMLReferenceCollector : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *references;
@end

@implementation LBCAMLReferenceCollector
- (instancetype)init {
    self = [super init];
    if (self) _references = [NSMutableArray array];
    return self;
}

- (void)parser:(NSXMLParser *)parser
 didStartElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qualifiedName
      attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    NSString *source = attributeDict[@"src"];
    if (source) [self.references addObject:source];
}
@end

static BOOL LBValidateCAMLDocumentAtPath(NSString *path, NSString *layerPath, NSError **error) {
    NSURL *url = [NSURL fileURLWithPath:path];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithContentsOfURL:url];
    if (!parser) {
        if (error) *error = LBInstallError(33, [NSString stringWithFormat:@"Could not open CAML document: %@", path]);
        return NO;
    }
    LBCAMLReferenceCollector *collector = [[LBCAMLReferenceCollector alloc] init];
    parser.delegate = collector;
    parser.shouldResolveExternalEntities = NO;
    if (![parser parse]) {
        NSString *detail = parser.parserError.localizedDescription ?: @"invalid XML";
        if (error) *error = LBInstallError(33, [NSString stringWithFormat:@"Malformed CAML document %@: %@", path, detail]);
        return NO;
    }

    for (NSString *reference in collector.references) {
        // CAML stores asset URLs, not raw filesystem paths. Decode percent
        // escapes once before applying path-safety checks and resolving the
        // local asset (e.g. "cloud2%201.png" -> "cloud2 1.png").
        NSString *decodedReference = [reference stringByRemovingPercentEncoding];
        if (!decodedReference || !LBPathIsSafeRelative(decodedReference) ||
            [decodedReference rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            [decodedReference containsString:@":"]) {
            if (error) *error = LBInstallError(34, [NSString stringWithFormat:@"Unsafe CAML asset reference in %@: %@", path, reference]);
            return NO;
        }
        NSString *assetPath = [layerPath stringByAppendingPathComponent:decodedReference];
        if (!LBIsRegularFile(assetPath)) {
            if (error) *error = LBInstallError(35, [NSString stringWithFormat:@"CAML asset reference does not resolve to a regular file: %@ (%@)", reference, path]);
            return NO;
        }
    }
    return YES;
}

static BOOL LBValidateDescriptorTree(NSString *root, NSError **error) {
    if (!LBIsDirectory(root)) {
        if (error) *error = LBInstallError(20, @"A descriptor entry is not a regular directory.");
        return NO;
    }

    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        NSString *full = [root stringByAppendingPathComponent:relative];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st) != 0 || S_ISLNK(st.st_mode) ||
            (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))) {
            if (error) *error = LBInstallError(21, [NSString stringWithFormat:@"Unsafe descriptor entry: %@", relative]);
            return NO;
        }
    }

    NSString *descriptorIDPath = [root stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
    NSString *rolePath = [root stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"];
    NSString *providerInfoPath = [root stringByAppendingPathComponent:@"providerInfo.plist"];
    NSString *descriptorID = LBReadTrimmedString(descriptorIDPath);
    NSScanner *identifierScanner = descriptorID.length ? [NSScanner scannerWithString:descriptorID] : nil;
    long long parsedIdentifier = 0;
    BOOL numericDescriptorID = identifierScanner && [identifierScanner scanLongLong:&parsedIdentifier] &&
        identifierScanner.isAtEnd && parsedIdentifier > 0;
    if (!numericDescriptorID || !LBIsRegularFile(rolePath) || !LBIsRegularFile(providerInfoPath)) {
        if (error) *error = LBInstallError(22, @"Descriptor is missing its numeric root identifier, role identifier, or providerInfo.plist.");
        return NO;
    }
    NSData *providerInfo = [NSData dataWithContentsOfFile:providerInfoPath];
    if (!providerInfo || ![NSPropertyListSerialization propertyListWithData:providerInfo options:NSPropertyListImmutable format:nil error:nil]) {
        if (error) *error = LBInstallError(23, @"providerInfo.plist is not a readable property list.");
        return NO;
    }

    __block NSUInteger wallpaperCount = 0;
    __block BOOL userInfoFound = NO;
    __block BOOL wallpaperBundleFound = NO;
    __block NSString *referencedWallpaperBundle = nil;
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtPath:root];
    NSString *file = nil;
    while ((file = files.nextObject)) {
        NSString *full = [root stringByAppendingPathComponent:file];
        NSString *last = file.lastPathComponent;
        if ([last isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"]) {
            if (!LBIsRegularFile(full)) continue;
            NSData *data = [NSData dataWithContentsOfFile:full];
            id userInfoObject = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
            if (![userInfoObject isKindOfClass:NSDictionary.class]) {
                if (error) *error = LBInstallError(24, @"provider contents user-info is not a property-list dictionary.");
                return NO;
            }
            NSDictionary *userInfo = userInfoObject;
            NSString *representingName = [userInfo[@"wallpaperRepresentingFileName"] isKindOfClass:NSString.class] ? userInfo[@"wallpaperRepresentingFileName"] : nil;
            id representingID = userInfo[@"wallpaperRepresentingIdentifier"];
            if (!representingName.length ||
                !LBPathIsSafeRelative(representingName) ||
                [representingName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
                [representingName containsString:@":"] ||
                !([representingID isKindOfClass:NSString.class] || LBIsPositiveNumericIdentifier(representingID))) {
                if (error) *error = LBInstallError(24, @"provider contents user-info is missing a safe wallpaper filename or identifier.");
                return NO;
            }
            NSString *contentsRoot = full.stringByDeletingLastPathComponent;
            NSString *wallpaperPath = [contentsRoot stringByAppendingPathComponent:representingName];
            if (!LBIsDirectory(wallpaperPath)) {
                if (error) *error = LBInstallError(25, @"The wallpaper bundle referenced by provider user-info does not exist.");
                return NO;
            }
            userInfoFound = YES;
            wallpaperBundleFound = YES;
            referencedWallpaperBundle = wallpaperPath;
        }
        if ([last caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
            if (!LBIsRegularFile(full)) continue;
            NSData *data = [NSData dataWithContentsOfFile:full];
            id wallpaperObject = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
            if (![wallpaperObject isKindOfClass:NSDictionary.class]) {
                if (error) *error = LBInstallError(26, [NSString stringWithFormat:@"Wallpaper.plist root is not a dictionary: %@", file]);
                return NO;
            }
            NSDictionary *wallpaper = wallpaperObject;
            NSString *machineIdentifier = LBCurrentDeviceMachineIdentifier();
            if (machineIdentifier &&
                !LBValidateDeviceFamilyForLogicalScreenClass(wallpaper[@"logicalScreenClass"], machineIdentifier, error)) return NO;
            NSDictionary *assets = [wallpaper[@"assets"] isKindOfClass:NSDictionary.class] ? wallpaper[@"assets"] : nil;
            NSDictionary *lockAndHome = [assets[@"lockAndHome"] isKindOfClass:NSDictionary.class] ? assets[@"lockAndHome"] : nil;
            NSDictionary *defaults = [lockAndHome[@"default"] isKindOfClass:NSDictionary.class] ? lockAndHome[@"default"] : nil;
            NSString *backgroundName = [defaults[@"backgroundAnimationFileName"] isKindOfClass:NSString.class] ? defaults[@"backgroundAnimationFileName"] : nil;
            NSString *floatingName = [defaults[@"floatingAnimationFileNameKey"] isKindOfClass:NSString.class] ? defaults[@"floatingAnimationFileNameKey"] : nil;
            if (![wallpaper isKindOfClass:NSDictionary.class] ||
                !LBIsPositiveNumericIdentifier(wallpaper[@"identifier"]) ||
                ![wallpaper[@"name"] isKindOfClass:NSString.class] ||
                !assets ||
                (backgroundName && (!LBPathIsSafeRelative(backgroundName) || [backgroundName containsString:@":"])) ||
                (floatingName && (!LBPathIsSafeRelative(floatingName) || [floatingName containsString:@":"]))) {
                if (error) *error = LBInstallError(26, [NSString stringWithFormat:@"Invalid Wallpaper.plist or unsafe layer references at %@", file]);
                return NO;
            }
            NSString *wallpaperBundleRoot = full.stringByDeletingLastPathComponent;
            NSMutableArray<NSString *> *layersToValidate = [NSMutableArray array];
            if (backgroundName.length) {
                NSString *backgroundPath = [wallpaperBundleRoot stringByAppendingPathComponent:backgroundName];
                if (!LBIsDirectory(backgroundPath)) {
                    if (error) *error = LBInstallError(28, [NSString stringWithFormat:@"Wallpaper.plist references missing background bundle at %@", file]);
                    return NO;
                }
                [layersToValidate addObject:backgroundPath];
            }
            if (floatingName.length) {
                NSString *floatingPath = [wallpaperBundleRoot stringByAppendingPathComponent:floatingName];
                if (!LBIsDirectory(floatingPath)) {
                    if (error) *error = LBInstallError(28, [NSString stringWithFormat:@"Wallpaper.plist references missing floating bundle at %@", file]);
                    return NO;
                }
                [layersToValidate addObject:floatingPath];
            }
            NSString *foregroundName = [defaults[@"foregroundAnimationFileName"] isKindOfClass:NSString.class] ? defaults[@"foregroundAnimationFileName"] : nil;
            if (foregroundName.length) {
                if (!LBPathIsSafeRelative(foregroundName) || [foregroundName containsString:@":"]) {
                    if (error) *error = LBInstallError(26, [NSString stringWithFormat:@"Invalid foreground layer reference at %@", file]);
                    return NO;
                }
                NSString *foregroundPath = [wallpaperBundleRoot stringByAppendingPathComponent:foregroundName];
                if (!LBIsDirectory(foregroundPath)) {
                    if (error) *error = LBInstallError(28, [NSString stringWithFormat:@"Wallpaper.plist references missing foreground bundle at %@", file]);
                    return NO;
                }
                [layersToValidate addObject:foregroundPath];
            }
            for (NSString *layerPath in layersToValidate) {
                NSString *indexPath = [layerPath stringByAppendingPathComponent:@"index.xml"];
                NSString *rootDocumentPath = [layerPath stringByAppendingPathComponent:@"main.caml"];
                if (LBIsRegularFile(indexPath) || LBIsRegularFile(rootDocumentPath) || [layerPath.pathExtension.lowercaseString isEqualToString:@"ca"]) {
                    if (!LBIsRegularFile(indexPath) || !LBIsRegularFile(rootDocumentPath)) {
                        if (error) *error = LBInstallError(29, [NSString stringWithFormat:@"CAML layer is missing index.xml or main.caml: %@", layerPath]);
                        return NO;
                    }
                    if (!LBValidateCAMLDocumentAtPath(rootDocumentPath, layerPath, error)) return NO;
                    NSData *indexData = [NSData dataWithContentsOfFile:indexPath];
                    NSPropertyListFormat indexFormat = NSPropertyListOpenStepFormat;
                    id indexObject = indexData ?
                        [NSPropertyListSerialization propertyListWithData:indexData options:NSPropertyListImmutable format:&indexFormat error:nil] : nil;
                    id assetManifest = [indexObject isKindOfClass:NSDictionary.class] ? indexObject[@"assetManifest"] : nil;
                    BOOL assetManifestValid = !assetManifest || [assetManifest isEqual:@"assetManifest.caml"];
                    if (![indexObject isKindOfClass:NSDictionary.class] ||
                        ![indexObject[@"rootDocument"] isEqual:@"main.caml"] ||
                        !assetManifestValid) {
                        if (error) *error = LBInstallError(32, [NSString stringWithFormat:@"CAML index.xml is not a valid PosterBoard property list or does not reference main.caml: %@", layerPath]);
                        return NO;
                    }
                }
            }
            wallpaperCount++;
        }
    }
    NSString *referencedWallpaperPlist = referencedWallpaperBundle.length ?
        [referencedWallpaperBundle stringByAppendingPathComponent:@"Wallpaper.plist"] : nil;
    if (!wallpaperCount || !userInfoFound || !wallpaperBundleFound || !LBIsRegularFile(referencedWallpaperPlist)) {
        if (error) *error = LBInstallError(27, @"Descriptor requires a Wallpaper.plist inside the bundle referenced by provider user-info.");
        return NO;
    }
    return YES;
}

static BOOL LBValidatePublishedDescriptorIdentifierConsistency(NSString *root, NSError **error) {
    NSString *rootIDText = LBReadTrimmedString([root stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]);
    NSScanner *rootScanner = rootIDText.length ? [NSScanner scannerWithString:rootIDText] : nil;
    long long rootID = 0;
    if (!rootScanner || ![rootScanner scanLongLong:&rootID] || !rootScanner.isAtEnd || rootID <= 0) {
        if (error) *error = LBInstallError(68, @"Published descriptor has no valid numeric root identifier.");
        return NO;
    }

    NSUInteger wallpaperCount = 0;
    NSUInteger userInfoCount = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        NSString *name = relative.lastPathComponent;
        NSString *full = [root stringByAppendingPathComponent:relative];
        if ([name caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
            if (!LBIsRegularFile(full)) {
                if (error) *error = LBInstallError(68, [NSString stringWithFormat:@"Published Wallpaper.plist is not a regular file: %@", relative]);
                return NO;
            }
            NSData *data = [NSData dataWithContentsOfFile:full];
            id object = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
            NSDictionary *wallpaper = [object isKindOfClass:NSDictionary.class] ? object : nil;
            NSDictionary *assets = [wallpaper[@"assets"] isKindOfClass:NSDictionary.class] ? wallpaper[@"assets"] : nil;
            NSDictionary *lockAndHome = [assets[@"lockAndHome"] isKindOfClass:NSDictionary.class] ? assets[@"lockAndHome"] : nil;
            NSDictionary *defaults = [lockAndHome[@"default"] isKindOfClass:NSDictionary.class] ? lockAndHome[@"default"] : nil;
            id wallpaperID = wallpaper[@"identifier"];
            id defaultID = defaults ? defaults[@"identifier"] : nil;
            if (!LBIsPositiveNumericIdentifier(wallpaperID) ||
                [wallpaperID longLongValue] != rootID ||
                (defaultID && (!LBIsPositiveNumericIdentifier(defaultID) || [defaultID longLongValue] != rootID))) {
                if (error) *error = LBInstallError(68, [NSString stringWithFormat:
                    @"Published descriptor identifier mismatch in %@: root=%lld, wallpaper=%@, default-layer=%@.",
                    relative, rootID, wallpaperID ?: @"(missing)", defaultID ?: @"(missing)"]);
                return NO;
            }
            wallpaperCount++;
        } else if ([name isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"]) {
            if (!LBIsRegularFile(full)) continue;
            NSData *data = [NSData dataWithContentsOfFile:full];
            id object = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
            NSDictionary *userInfo = [object isKindOfClass:NSDictionary.class] ? object : nil;
            id representingID = userInfo[@"wallpaperRepresentingIdentifier"];
            long long parsedRepresentingID = 0;
            BOOL identifierMatches = NO;
            if ([representingID isKindOfClass:NSNumber.class]) {
                identifierMatches = LBIsPositiveNumericIdentifier(representingID) &&
                    [representingID longLongValue] == rootID;
            } else if ([representingID isKindOfClass:NSString.class]) {
                NSScanner *scanner = [NSScanner scannerWithString:representingID];
                identifierMatches = [scanner scanLongLong:&parsedRepresentingID] &&
                    scanner.isAtEnd && parsedRepresentingID > 0 && parsedRepresentingID == rootID;
            }
            if (!identifierMatches) {
                if (error) *error = LBInstallError(68, [NSString stringWithFormat:
                    @"Published provider user-info identifier does not match descriptor root ID %lld at %@.",
                    rootID, relative]);
                return NO;
            }
            userInfoCount++;
        }
    }
    if (wallpaperCount == 0 || userInfoCount == 0) {
        if (error) *error = LBInstallError(68, @"Published descriptor is missing a Wallpaper.plist or provider user-info identifier.");
        return NO;
    }
    return YES;
}

static BOOL LBUpdateSuggestionMetadata(NSString *root, NSString *oldID, NSString *newID, NSError **error) {
    NSString *suggestionPath = [root stringByAppendingPathComponent:@"com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist"];
    if (!LBIsRegularFile(suggestionPath)) return YES;

    NSData *data = [NSData dataWithContentsOfFile:suggestionPath];
    if (data.length < 32) return YES;
    if (memcmp(data.bytes, "bplist00", 8) != 0) return YES;

    NSString *oldDynamic = [NSString stringWithFormat:@"%@.DYNAMIC", oldID];
    NSString *newDynamic = [NSString stringWithFormat:@"%@.DYNAMIC", newID];
    NSData *targetData = nil;
    NSData *replacementData = nil;

    NSData *oldDynamicData = [oldDynamic dataUsingEncoding:NSUTF8StringEncoding];
    NSRange range = [data rangeOfData:oldDynamicData options:0 range:NSMakeRange(0, data.length)];
    if (range.location != NSNotFound) {
        targetData = oldDynamicData;
        replacementData = [newDynamic dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        NSData *oldIDData = [oldID dataUsingEncoding:NSUTF8StringEncoding];
        range = [data rangeOfData:oldIDData options:0 range:NSMakeRange(0, data.length)];
        if (range.location != NSNotFound) {
            targetData = oldIDData;
            replacementData = [newID dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    if (range.location == NSNotFound || !targetData || !replacementData) return YES;

    NSMutableData *mutableData = [data mutableCopy];
    if (targetData.length == replacementData.length) {
        [mutableData replaceBytesInRange:range withBytes:replacementData.bytes length:replacementData.length];
        return LBWriteDataAtomically(mutableData, suggestionPath, error);
    }

    NSInteger delta = (NSInteger)replacementData.length - (NSInteger)targetData.length;
    NSUInteger prefixIdx = range.location - 1;
    uint8_t *bytes = (uint8_t *)mutableData.mutableBytes;
    if ((bytes[prefixIdx] & 0xF0) == 0x50 && replacementData.length < 15) {
        bytes[prefixIdx] = (uint8_t)(0x50 | (replacementData.length & 0x0F));
    }
    [mutableData replaceBytesInRange:range withBytes:replacementData.bytes length:replacementData.length];

    NSUInteger originalLen = data.length;
    if (originalLen < 32) return YES;
    const uint8_t *origTrailer = (const uint8_t *)data.bytes + (originalLen - 32);
    uint8_t offsetIntSize = origTrailer[6];
    uint64_t numObjs = 0;
    for (int b = 0; b < 8; b++) numObjs = (numObjs << 8) | origTrailer[8 + b];
    uint64_t offTableOff = 0;
    for (int b = 0; b < 8; b++) offTableOff = (offTableOff << 8) | origTrailer[24 + b];

    if (offsetIntSize == 2) {
        uint64_t newOffTableOff = offTableOff + (uint64_t)delta;
        uint8_t *mutBytes = (uint8_t *)mutableData.mutableBytes;
        for (uint64_t i = 0; i < numObjs; i++) {
            NSUInteger pos = (NSUInteger)(newOffTableOff + i * 2);
            if (pos + 2 > mutableData.length) break;
            uint16_t off = (mutBytes[pos] << 8) | mutBytes[pos + 1];
            if (off > range.location) {
                off = (uint16_t)((NSInteger)off + delta);
                mutBytes[pos] = (uint8_t)(off >> 8);
                mutBytes[pos + 1] = (uint8_t)(off & 0xFF);
            }
        }
        NSUInteger trailerPos = mutableData.length - 8;
        for (int b = 7; b >= 0; b--) {
            mutBytes[trailerPos + (7 - b)] = (uint8_t)((newOffTableOff >> (b * 8)) & 0xFF);
        }
    }
    return LBWriteDataAtomically(mutableData, suggestionPath, error);
}

static BOOL LBRewriteDescriptorIdentifiers(NSString *root, NSInteger numericID, NSError **error) {
    NSString *descriptorID = [NSString stringWithFormat:@"%ld", (long)numericID];
    NSData *idData = [descriptorID dataUsingEncoding:NSUTF8StringEncoding];
    NSString *rootIDPath = [root stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
    NSString *oldIDText = LBReadTrimmedString(rootIDPath);
    if (!LBWriteDataAtomically(idData, rootIDPath, error)) return NO;
    if (oldIDText.length && ![oldIDText isEqualToString:descriptorID]) {
        if (!LBUpdateSuggestionMetadata(root, oldIDText, descriptorID, error)) return NO;
    }

    NSString *rolePath = [root stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"];
    if (!LBIsRegularFile(rolePath)) {
        NSData *roleData = [@"PRPosterRoleLockScreen" dataUsingEncoding:NSUTF8StringEncoding];
        if (roleData) LBWriteDataAtomically(roleData, rolePath, NULL);
    }

    NSString *providerInfoPath = [root stringByAppendingPathComponent:@"providerInfo.plist"];
    if (!LBIsRegularFile(providerInfoPath)) {
        NSData *provider = [NSKeyedArchiver archivedDataWithRootObject:@{@"kConfigurationLastUseDateKey": [NSDate date]} requiringSecureCoding:NO error:nil];
        if (provider) LBWriteDataAtomically(provider, providerInfoPath, NULL);
    }

    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:root];
    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        NSString *full = [root stringByAppendingPathComponent:relative];
        NSString *name = relative.lastPathComponent;
        if ([name isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"]) {
            NSData *data = [NSData dataWithContentsOfFile:full];
            NSMutableDictionary *userInfo = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
            if (![userInfo isKindOfClass:NSMutableDictionary.class]) {
                if (error) *error = LBInstallError(30, @"Cannot rewrite provider contents user-info.");
                return NO;
            }
            id existingIdentifier = userInfo[@"wallpaperRepresentingIdentifier"];
            userInfo[@"wallpaperRepresentingIdentifier"] =
                [existingIdentifier isKindOfClass:NSNumber.class] ? @(numericID) : descriptorID;
            NSData *rewritten = [NSPropertyListSerialization dataWithPropertyList:userInfo format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
            if (!rewritten || !LBWriteDataAtomically(rewritten, full, error)) return NO;
        } else if ([name caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
            NSData *data = [NSData dataWithContentsOfFile:full];
            NSMutableDictionary *wallpaper = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
            if (![wallpaper isKindOfClass:NSMutableDictionary.class]) {
                if (error) *error = LBInstallError(31, @"Cannot rewrite Wallpaper.plist.");
                return NO;
            }
            wallpaper[@"identifier"] = @(numericID);
            NSMutableDictionary *assets = [wallpaper[@"assets"] isKindOfClass:NSDictionary.class] ? [wallpaper[@"assets"] mutableCopy] : nil;
            NSMutableDictionary *lockAndHome = [assets[@"lockAndHome"] isKindOfClass:NSDictionary.class] ? [assets[@"lockAndHome"] mutableCopy] : nil;
            NSMutableDictionary *defaults = [lockAndHome[@"default"] isKindOfClass:NSDictionary.class] ? [lockAndHome[@"default"] mutableCopy] : nil;
            if (defaults) {
                defaults[@"identifier"] = @(numericID);
                lockAndHome[@"default"] = defaults;
                assets[@"lockAndHome"] = lockAndHome;
                wallpaper[@"assets"] = assets;
            }

            // Adapt logicalScreenClass for iPhone compatibility:
            // Descriptors targeting iPad (~ipad) or missing a valid screen class are rejected
            // by PosterBoard when running on iPhone. Adapt to 375w-812h@3x~iphone.
            NSString *currentScreenClass = [wallpaper[@"logicalScreenClass"] isKindOfClass:NSString.class] ? wallpaper[@"logicalScreenClass"] : nil;
            if (!currentScreenClass.length || [currentScreenClass containsString:@"~ipad"] || ![currentScreenClass containsString:@"~iphone"]) {
                wallpaper[@"logicalScreenClass"] = @"375w-812h@3x~iphone";
            }

            NSData *rewritten = [NSPropertyListSerialization dataWithPropertyList:wallpaper format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
            if (!rewritten || !LBWriteDataAtomically(rewritten, full, error)) return NO;
        }
    }

    NSString *v0 = [root stringByAppendingPathComponent:@"versions/0"];
    NSString *v1 = [root stringByAppendingPathComponent:@"versions/1"];
    if (LBIsDirectory(v0) && !LBIsDirectory(v1)) {
        [NSFileManager.defaultManager copyItemAtPath:v0 toPath:v1 error:nil];
    } else if (LBIsDirectory(v1) && !LBIsDirectory(v0)) {
        [NSFileManager.defaultManager copyItemAtPath:v1 toPath:v0 error:nil];
    }

    return YES;
}

static BOOL LBCollectDescriptorRoots(NSString *extractedPath, NSMutableArray<NSString *> *roots,
                                     BOOL *orderedGroupOut, NSError **error) {
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:extractedPath];
    NSString *relative = nil;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    BOOL orderedGroup = NO;
    if (orderedGroupOut) *orderedGroupOut = NO;
    while ((relative = enumerator.nextObject)) {
        NSString *full = [extractedPath stringByAppendingPathComponent:relative];
        if (!LBIsDirectory(full)) continue;
        NSString *name = relative.lastPathComponent.lowercaseString;
        // Nugget detects this marker by substring so archives can add the
        // ordered prefix or suffix while retaining a descriptive group name.
        BOOL isOrderedGroup = [name containsString:@"ordered-descriptor"];
        if ([name isEqualToString:@"descriptor"] || [name isEqualToString:@"descriptors"] || isOrderedGroup) {
            NSArray<NSString *> *parts = [relative.lowercaseString componentsSeparatedByString:@"/"];
            BOOL unsupportedVariant = NO;
            for (NSString *part in parts) {
                if ([part containsString:@"video"] || [part containsString:@"photos"] ||
                    [part containsString:@"mercury"] || [part isEqualToString:@"container"]) unsupportedVariant = YES;
            }
            if (unsupportedVariant) {
                if (error) *error = LBInstallError(40, @"This Tendies archive targets a non-Collections PosterBoard extension or a whole-container restore.");
                return NO;
            }
            [candidates addObject:full];
            orderedGroup = isOrderedGroup;
            [enumerator skipDescendants];
        }
    }
    if (orderedGroupOut) *orderedGroupOut = orderedGroup;
    if (candidates.count != 1) {
        if (error) *error = LBInstallError(41, @"Expected exactly one descriptor, descriptors, or ordered-descriptor(s) group for the iOS 16 Collections extension.");
        return NO;
    }
    NSArray<NSString *> *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:candidates.firstObject error:error];
    if (!children) return NO;
    if (orderedGroup) {
        children = [children sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [a compare:b options:NSLiteralSearch];
        }];
    }
    for (NSString *child in children) {
        if ([child hasPrefix:@"."] || [child isEqualToString:@"__MACOSX"]) continue;
        NSString *path = [candidates.firstObject stringByAppendingPathComponent:child];
        if (!LBIsDirectory(path)) continue;
        [roots addObject:path];
    }
    if (!roots.count) {
        if (error) *error = LBInstallError(43, @"The descriptor group contains no descriptor directories.");
        return NO;
    }
    return YES;
}

static NSNumber *LBParseExistingNumericIdentifier(id value) {
    long long parsed = 0;
    if ([value isKindOfClass:NSNumber.class]) {
        parsed = [value longLongValue];
    } else if ([value isKindOfClass:NSString.class]) {
        NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSScanner *scanner = text.length ? [NSScanner scannerWithString:text] : nil;
        if (!scanner || ![scanner scanLongLong:&parsed] || !scanner.isAtEnd) return nil;
    } else {
        return nil;
    }
    if (parsed <= 0 || parsed > 999999) return nil;
    return @(parsed);
}

static NSDictionary *LBReadExistingDescriptorPropertyList(NSString *path) {
    if (!LBIsRegularFile(path)) return nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    if (size == 0 || size > 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    id object = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil] : nil;
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static BOOL LBReadExistingDescriptorMetadataIdentifier(NSString *descriptorPath,
                                                        NSNumber **identifier,
                                                        NSError **error) {
    NSMutableSet<NSNumber *> *metadataIdentifiers = [NSMutableSet set];
    NSUInteger userInfoCount = 0;
    NSUInteger wallpaperCount = 0;
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:descriptorPath];
    if (!enumerator) {
        if (error) *error = LBInstallError(66, @"Could not inspect existing PosterBoard descriptor metadata.");
        return NO;
    }

    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        NSString *full = [descriptorPath stringByAppendingPathComponent:relative];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st) != 0 ||
            S_ISLNK(st.st_mode) || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))) {
            if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                @"Unsafe metadata entry in existing PosterBoard descriptor: %@", relative]);
            return NO;
        }
        if (!S_ISREG(st.st_mode)) continue;

        NSString *name = relative.lastPathComponent;
        if ([name isEqualToString:@"com.apple.posterkit.provider.contents.userInfo"]) {
            NSDictionary *userInfo = LBReadExistingDescriptorPropertyList(full);
            NSString *wallpaperName = [userInfo[@"wallpaperRepresentingFileName"] isKindOfClass:NSString.class]
                ? userInfo[@"wallpaperRepresentingFileName"] : nil;
            NSNumber *representingID = LBParseExistingNumericIdentifier(userInfo[@"wallpaperRepresentingIdentifier"]);
            if (!userInfo || !representingID || !wallpaperName.length ||
                !LBPathIsSafeRelative(wallpaperName) ||
                [wallpaperName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
                [wallpaperName containsString:@":"]) {
                if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                    @"Existing PosterBoard descriptor has missing or invalid provider user-info metadata: %@", relative]);
                return NO;
            }

            NSString *wallpaperBundle = [full.stringByDeletingLastPathComponent stringByAppendingPathComponent:wallpaperName];
            NSString *wallpaperPlistPath = [wallpaperBundle stringByAppendingPathComponent:@"Wallpaper.plist"];
            if (!LBIsDirectory(wallpaperBundle)) {
                if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                    @"Existing provider user-info references a missing wallpaper bundle: %@", relative]);
                return NO;
            }
            NSDictionary *wallpaper = LBReadExistingDescriptorPropertyList(wallpaperPlistPath);
            NSDictionary *assets = [wallpaper[@"assets"] isKindOfClass:NSDictionary.class] ? wallpaper[@"assets"] : nil;
            NSDictionary *lockAndHome = [assets[@"lockAndHome"] isKindOfClass:NSDictionary.class] ? assets[@"lockAndHome"] : nil;
            NSDictionary *defaults = [lockAndHome[@"default"] isKindOfClass:NSDictionary.class] ? lockAndHome[@"default"] : nil;
            NSNumber *wallpaperID = LBParseExistingNumericIdentifier(wallpaper[@"identifier"]);
            id rawDefaultID = defaults ? defaults[@"identifier"] : nil;
            NSNumber *defaultID = rawDefaultID ? LBParseExistingNumericIdentifier(rawDefaultID) : nil;
            if (!wallpaper || !wallpaperID ||
                (rawDefaultID && !defaultID) ||
                ![representingID isEqualToNumber:wallpaperID] ||
                (defaultID && ![representingID isEqualToNumber:defaultID])) {
                if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                    @"Existing provider user-info and Wallpaper.plist identifiers disagree: %@", relative]);
                return NO;
            }
            [metadataIdentifiers addObject:representingID];
            userInfoCount++;
        }

        if ([name caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
            NSDictionary *wallpaper = LBReadExistingDescriptorPropertyList(full);
            NSDictionary *assets = [wallpaper[@"assets"] isKindOfClass:NSDictionary.class] ? wallpaper[@"assets"] : nil;
            NSDictionary *lockAndHome = [assets[@"lockAndHome"] isKindOfClass:NSDictionary.class] ? assets[@"lockAndHome"] : nil;
            NSDictionary *defaults = [lockAndHome[@"default"] isKindOfClass:NSDictionary.class] ? lockAndHome[@"default"] : nil;
            NSNumber *wallpaperID = LBParseExistingNumericIdentifier(wallpaper[@"identifier"]);
            id rawDefaultID = defaults ? defaults[@"identifier"] : nil;
            NSNumber *defaultID = rawDefaultID ? LBParseExistingNumericIdentifier(rawDefaultID) : nil;
            if (!wallpaper || !wallpaperID ||
                (rawDefaultID && !defaultID) ||
                (defaultID && ![wallpaperID isEqualToNumber:defaultID])) {
                if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                    @"Existing Wallpaper.plist has missing or inconsistent numeric identifiers: %@", relative]);
                return NO;
            }
            [metadataIdentifiers addObject:wallpaperID];
            wallpaperCount++;
        }
    }

    if ((userInfoCount == 0 && wallpaperCount == 0) || metadataIdentifiers.count != 1) {
        if (error) *error = LBInstallError(66,
            @"Existing PosterBoard descriptor metadata is absent, ambiguous, or contains conflicting numeric identifiers.");
        return NO;
    }
    if (identifier) *identifier = metadataIdentifiers.anyObject;
    return YES;
}

static BOOL LBReadExistingNumericIdentifiers(NSString *descriptorRoot,
                                             NSMutableSet<NSNumber *> *used,
                                             NSError **error) {
    NSError *listingError = nil;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot
                                                                                       error:&listingError];
    if (!entries) {
        if (error) *error = LBInstallError(65, [NSString stringWithFormat:
            @"Could not enumerate the existing PosterBoard descriptor store: %@",
            listingError.localizedDescription ?: @"unknown filesystem error"]);
        return NO;
    }
    for (NSString *entry in entries) {
        NSString *path = [descriptorRoot stringByAppendingPathComponent:entry];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0) {
            if (errno == ENOENT) continue;
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }
        if (S_ISLNK(st.st_mode) || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))) {
            if (error) *error = LBInstallError(65, [NSString stringWithFormat:
                @"Unsafe existing entry in the PosterBoard descriptor store: %@", entry]);
            return NO;
        }
        if (!S_ISDIR(st.st_mode)) continue;

        NSString *rootIDPath = [path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
        struct stat rootIDStat;
        NSNumber *rootID = nil;
        if (lstat(rootIDPath.fileSystemRepresentation, &rootIDStat) == 0) {
            if (S_ISLNK(rootIDStat.st_mode) || !S_ISREG(rootIDStat.st_mode) || rootIDStat.st_size > 128) {
                if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                    @"Existing PosterBoard descriptor has an unsafe numeric identifier file: %@", entry]);
                return NO;
            }
            if (rootIDStat.st_size > 0) {
                rootID = LBParseExistingNumericIdentifier(LBReadTrimmedString(rootIDPath));
                if (!rootID) {
                    if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                        @"Existing PosterBoard descriptor has an invalid numeric root identifier: %@", entry]);
                    return NO;
                }
            }
        } else if (errno != ENOENT) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            return NO;
        }

        // Preserve the established root-identifier path for existing descriptors.
        // Internal metadata is consulted only when the root identifier is absent or empty.
        NSNumber *resolvedID = rootID;
        if (!resolvedID) {
            NSNumber *metadataID = nil;
            if (!LBReadExistingDescriptorMetadataIdentifier(path, &metadataID, error)) return NO;
            resolvedID = metadataID;
        }
        if ([used containsObject:resolvedID]) {
            if (error) *error = LBInstallError(66, [NSString stringWithFormat:
                @"Duplicate numeric wallpaper identifier %@ already exists in the PosterBoard descriptor store; refusing to allocate around an inconsistent store.",
                resolvedID]);
            return NO;
        }
        [used addObject:resolvedID];
    }
    return YES;
}

__attribute__((unused))
static BOOL LBRegisterDescriptorsInSQLiteDatabase(NSString *dbPath,
                                                 NSArray<NSString *> *uuids,
                                                 NSString *providerId,
                                                 NSError **error) {
    if (!uuids.count) return YES;
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
        if (error) *error = LBInstallError(70, [NSString stringWithFormat:@"Cannot open PosterBoard SQLite database: %s", db ? sqlite3_errmsg(db) : "unknown error"]);
        if (db) sqlite3_close(db);
        return NO;
    }

    sqlite3_busy_timeout(db, 5000);
    sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);

    sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS poster (UUID TEXT PRIMARY KEY, providerId TEXT);", NULL, NULL, NULL);
    sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS posterRoleMembership (posterUUID TEXT, roleId TEXT, roleSortKey INTEGER, PRIMARY KEY (posterUUID, roleId));", NULL, NULL, NULL);

    char *errMsg = NULL;
    rc = sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, &errMsg);
    if (rc != SQLITE_OK) {
        if (error) *error = LBInstallError(71, [NSString stringWithFormat:@"Cannot begin transaction on PosterBoard database: %s", errMsg ?: "unknown"]);
        if (errMsg) sqlite3_free(errMsg);
        sqlite3_close(db);
        return NO;
    }

    int nextSortKey = 1;
    sqlite3_stmt *sortStmt = NULL;
    const char *sortSql = "SELECT COALESCE(MAX(roleSortKey), 0) + 1 FROM posterRoleMembership WHERE roleId = 'PRPosterRoleLockScreen';";
    if (sqlite3_prepare_v2(db, sortSql, -1, &sortStmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(sortStmt) == SQLITE_ROW) {
            nextSortKey = sqlite3_column_int(sortStmt, 0);
        }
        sqlite3_finalize(sortStmt);
    }

    BOOL ok = YES;
    const char *posterSql = "INSERT OR REPLACE INTO poster (UUID, providerId) VALUES (?, ?);";
    const char *roleSql = "INSERT OR REPLACE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES (?, 'PRPosterRoleLockScreen', ?);";

    sqlite3_stmt *posterStmt = NULL;
    sqlite3_stmt *roleStmt = NULL;

    if (sqlite3_prepare_v2(db, posterSql, -1, &posterStmt, NULL) != SQLITE_OK ||
        sqlite3_prepare_v2(db, roleSql, -1, &roleStmt, NULL) != SQLITE_OK) {
        if (error) *error = LBInstallError(72, [NSString stringWithFormat:@"Cannot prepare SQL statements: %s", sqlite3_errmsg(db)]);
        ok = NO;
    }

    if (ok) {
        for (NSString *uuid in uuids) {
            sqlite3_reset(posterStmt);
            sqlite3_bind_text(posterStmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(posterStmt, 2, providerId.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(posterStmt) != SQLITE_DONE) {
                if (error) *error = LBInstallError(73, [NSString stringWithFormat:@"Failed inserting poster %@: %s", uuid, sqlite3_errmsg(db)]);
                ok = NO;
                break;
            }

            sqlite3_reset(roleStmt);
            sqlite3_bind_text(roleStmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(roleStmt, 2, nextSortKey++);
            if (sqlite3_step(roleStmt) != SQLITE_DONE) {
                if (error) *error = LBInstallError(74, [NSString stringWithFormat:@"Failed inserting posterRoleMembership %@: %s", uuid, sqlite3_errmsg(db)]);
                ok = NO;
                break;
            }
        }
    }

    if (posterStmt) sqlite3_finalize(posterStmt);
    if (roleStmt) sqlite3_finalize(roleStmt);

    if (ok) {
        rc = sqlite3_exec(db, "COMMIT;", NULL, NULL, &errMsg);
        if (rc != SQLITE_OK) {
            if (error) *error = LBInstallError(75, [NSString stringWithFormat:@"Cannot commit PosterBoard SQLite transaction: %s", errMsg ?: "unknown"]);
            if (errMsg) sqlite3_free(errMsg);
            sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
            ok = NO;
        }
    } else {
        sqlite3_exec(db, "ROLLBACK;", NULL, NULL, NULL);
    }

    sqlite3_close(db);

    if (ok) {
        struct passwd *mobile = getpwnam("mobile");
        if (mobile && geteuid() == 0) {
            chown(dbPath.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid);
            NSString *wal = [dbPath stringByAppendingString:@"-wal"];
            NSString *shm = [dbPath stringByAppendingString:@"-shm"];
            struct stat s;
            if (lstat(wal.fileSystemRepresentation, &s) == 0) chown(wal.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid);
            if (lstat(shm.fileSystemRepresentation, &s) == 0) chown(shm.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid);
        }
    }

    return ok;
}

__attribute__((unused))
static void LBRollbackDescriptorsInSQLiteDatabase(NSString *dbPath, NSArray<NSString *> *uuids) {
    if (!uuids.count) return;
    struct stat s;
    if (lstat(dbPath.fileSystemRepresentation, &s) != 0 || !S_ISREG(s.st_mode)) return;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
    sqlite3_stmt *delRole = NULL;
    sqlite3_stmt *delPoster = NULL;
    sqlite3_prepare_v2(db, "DELETE FROM posterRoleMembership WHERE posterUUID = ?;", -1, &delRole, NULL);
    sqlite3_prepare_v2(db, "DELETE FROM poster WHERE UUID = ?;", -1, &delPoster, NULL);
    for (NSString *uuid in uuids) {
        if (delRole) {
            sqlite3_reset(delRole);
            sqlite3_bind_text(delRole, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(delRole);
        }
        if (delPoster) {
            sqlite3_reset(delPoster);
            sqlite3_bind_text(delPoster, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(delPoster);
        }
    }
    if (delRole) sqlite3_finalize(delRole);
    if (delPoster) sqlite3_finalize(delPoster);
    sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
    sqlite3_close(db);
}

static void LBCleanupStaleDescriptors(NSString *descriptorRoot) {
    if (!descriptorRoot.length || !LBIsDirectory(descriptorRoot)) return;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot error:nil];
    if (!entries.count) return;

    NSMutableArray<NSString *> *validDescriptorPaths = [NSMutableArray array];
    for (NSString *entry in entries) {
        if ([entry hasPrefix:@".lumenboard-staging-"] || [entry isEqualToString:@"__MACOSX"] || [entry isEqualToString:@".DS_Store"]) {
            [NSFileManager.defaultManager removeItemAtPath:[descriptorRoot stringByAppendingPathComponent:entry] error:nil];
            continue;
        }
        NSString *path = [descriptorRoot stringByAppendingPathComponent:entry];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) continue;

        NSArray<NSString *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil];
        if (!contents || contents.count == 0) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *versionsPath = [path stringByAppendingPathComponent:@"versions"];
        NSString *wallpaperPlistPath = [path stringByAppendingPathComponent:@"Wallpaper.plist"];
        BOOL hasVersions = LBIsDirectory(versionsPath);
        BOOL hasWallpaperPlist = LBIsRegularFile(wallpaperPlistPath);
        if (!hasVersions && !hasWallpaperPlist) {
            BOOL hasNestedDescriptor = NO;
            for (NSString *c in contents) {
                NSString *sub = [path stringByAppendingPathComponent:c];
                if (LBIsDirectory(sub) && (LBIsDirectory([sub stringByAppendingPathComponent:@"versions"]) || LBIsRegularFile([sub stringByAppendingPathComponent:@"Wallpaper.plist"]))) {
                    hasNestedDescriptor = YES;
                    break;
                }
            }
            if (!hasNestedDescriptor) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                continue;
            }
        }
        [validDescriptorPaths addObject:path];
    }

    NSMutableSet<NSNumber *> *seenIDs = [NSMutableSet set];
    for (NSString *path in validDescriptorPaths) {
        NSString *rootIDPath = [path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
        struct stat rootIDStat;
        BOOL hasRootID = (lstat(rootIDPath.fileSystemRepresentation, &rootIDStat) == 0 && S_ISREG(rootIDStat.st_mode) && rootIDStat.st_size > 0);
        NSNumber *resolvedID = nil;
        if (hasRootID) {
            resolvedID = LBParseExistingNumericIdentifier(LBReadTrimmedString(rootIDPath));
        }

        if (!resolvedID) {
            NSNumber *metadataID = nil;
            if (LBReadExistingDescriptorMetadataIdentifier(path, &metadataID, nil) && metadataID) {
                resolvedID = metadataID;
            } else {
                NSDirectoryEnumerator *scan = [NSFileManager.defaultManager enumeratorAtPath:path];
                NSString *rel = nil;
                while ((rel = scan.nextObject)) {
                    if ([rel.lastPathComponent caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
                        NSString *wpPath = [path stringByAppendingPathComponent:rel];
                        NSDictionary *wp = LBReadExistingDescriptorPropertyList(wpPath);
                        NSNumber *parsed = LBParseExistingNumericIdentifier(wp[@"identifier"]);
                        if (parsed) {
                            resolvedID = parsed;
                            break;
                        }
                    }
                }
            }
        }

        if (!resolvedID || [seenIDs containsObject:resolvedID]) {
            NSInteger candidate = 10000 + arc4random_uniform(89999);
            while ([seenIDs containsObject:@(candidate)]) {
                candidate = 10000 + arc4random_uniform(89999);
            }
            resolvedID = @(candidate);
            LBRewriteDescriptorIdentifiers(path, candidate, nil);
        } else {
            NSString *idText = [NSString stringWithFormat:@"%@", resolvedID];
            [idText writeToFile:rootIDPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        [seenIDs addObject:resolvedID];

        // Self-heal versions: ensure both versions/0 and versions/1 exist for PosterBoard
        NSString *v0 = [path stringByAppendingPathComponent:@"versions/0"];
        NSString *v1 = [path stringByAppendingPathComponent:@"versions/1"];
        if (LBIsDirectory(v0) && !LBIsDirectory(v1)) {
            [NSFileManager.defaultManager copyItemAtPath:v0 toPath:v1 error:nil];
        } else if (LBIsDirectory(v1) && !LBIsDirectory(v0)) {
            [NSFileManager.defaultManager copyItemAtPath:v1 toPath:v0 error:nil];
        }

        // Self-heal logicalScreenClass: if any Wallpaper.plist declares ~ipad or missing screen class,
        // normalize to 375w-812h@3x~iphone so it is recognized by PosterBoard on iPhone.
        NSDirectoryEnumerator *scanWp = [NSFileManager.defaultManager enumeratorAtPath:path];
        NSString *relWp = nil;
        while ((relWp = scanWp.nextObject)) {
            if ([relWp.lastPathComponent caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
                NSString *wpFull = [path stringByAppendingPathComponent:relWp];
                NSData *wpRaw = [NSData dataWithContentsOfFile:wpFull];
                NSMutableDictionary *wpDict = wpRaw ? [NSPropertyListSerialization propertyListWithData:wpRaw options:NSPropertyListMutableContainers format:nil error:nil] : nil;
                if ([wpDict isKindOfClass:NSMutableDictionary.class]) {
                    NSString *sc = [wpDict[@"logicalScreenClass"] isKindOfClass:NSString.class] ? wpDict[@"logicalScreenClass"] : nil;
                    if (!sc.length || [sc containsString:@"~ipad"] || ![sc containsString:@"~iphone"]) {
                        wpDict[@"logicalScreenClass"] = @"375w-812h@3x~iphone";
                        NSData *rewrittenWp = [NSPropertyListSerialization dataWithPropertyList:wpDict format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                        if (rewrittenWp) [rewrittenWp writeToFile:wpFull atomically:YES];
                    }
                }
            }
        }

        NSString *rolePath = [path stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"];
        if (!LBIsRegularFile(rolePath)) {
            [@"PRPosterRoleLockScreen" writeToFile:rolePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSString *provInfoPath = [path stringByAppendingPathComponent:@"providerInfo.plist"];
        if (!LBIsRegularFile(provInfoPath)) {
            NSData *pData = [NSKeyedArchiver archivedDataWithRootObject:@{@"kConfigurationLastUseDateKey": [NSDate date]} requiringSecureCoding:NO error:nil];
            if (pData) [pData writeToFile:provInfoPath atomically:YES];
        }
        LBSetMobileOwnership(path, nil);
    }
}

static NSUInteger LBCountRegisteredDescriptorsInSQLite(NSString *dbPath, NSArray<NSString *> *uuids) {
    if (!uuids.count) return 0;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return 0;
    }
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT COUNT(*) FROM posterRoleMembership WHERE posterUUID = ? AND roleId = 'PRPosterRoleLockScreen';";
    NSUInteger count = 0;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        for (NSString *uuid in uuids) {
            sqlite3_reset(stmt);
            sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                if (sqlite3_column_int(stmt, 0) > 0) count++;
            }
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);
    return count;
}

static void LBCleanupStalePosterBoardDatabase(NSString *dbPath, NSString *storeRoot) {
    if (!dbPath.length || !storeRoot.length) return;
    struct stat st;
    if (lstat(dbPath.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 3000);
    sqlite3_stmt *stmt = NULL;
    const char *query = "SELECT posterUUID FROM posterRoleMembership WHERE roleId = 'PRPosterRoleLockScreen';";
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        NSMutableArray<NSString *> *staleUUIDs = [NSMutableArray array];
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *rawUUID = (const char *)sqlite3_column_text(stmt, 0);
            if (!rawUUID) continue;
            NSString *uuid = [NSString stringWithUTF8String:rawUUID];
            NSString *extDir = [storeRoot stringByAppendingPathComponent:@"Extensions"];
            BOOL configExists = NO;
            for (NSString *ext in [NSFileManager.defaultManager contentsOfDirectoryAtPath:extDir error:nil] ?: @[]) {
                NSString *configPath = [[[extDir stringByAppendingPathComponent:ext] stringByAppendingPathComponent:@"configurations"] stringByAppendingPathComponent:uuid];
                if (LBIsDirectory(configPath)) {
                    configExists = YES;
                    break;
                }
            }
            if (!configExists) {
                [staleUUIDs addObject:uuid];
            }
        }
        sqlite3_finalize(stmt);

        if (staleUUIDs.count > 0) {
            sqlite3_exec(db, "BEGIN IMMEDIATE;", NULL, NULL, NULL);
            sqlite3_stmt *delRole = NULL;
            sqlite3_stmt *delPoster = NULL;
            sqlite3_prepare_v2(db, "DELETE FROM posterRoleMembership WHERE posterUUID = ?;", -1, &delRole, NULL);
            sqlite3_prepare_v2(db, "DELETE FROM poster WHERE UUID = ?;", -1, &delPoster, NULL);
            for (NSString *uuid in staleUUIDs) {
                if (delRole) {
                    sqlite3_reset(delRole);
                    sqlite3_bind_text(delRole, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_step(delRole);
                }
                if (delPoster) {
                    sqlite3_reset(delPoster);
                    sqlite3_bind_text(delPoster, 1, uuid.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_step(delPoster);
                }
            }
            if (delRole) sqlite3_finalize(delRole);
            if (delPoster) sqlite3_finalize(delPoster);
            sqlite3_exec(db, "COMMIT;", NULL, NULL, NULL);
        }
    }
    sqlite3_close(db);
}

@implementation LBPosterBoardInstaller

// Private, deterministic compatibility seam used by the macOS XCTest suite.
+ (BOOL)validateLogicalScreenClass:(NSString *)logicalScreenClass
                machineIdentifier:(NSString *)machineIdentifier
                             error:(NSError **)error {
    return LBValidateDeviceFamilyForLogicalScreenClass(logicalScreenClass, machineIdentifier, error);
}

// Private validation seam used by the macOS XCTest suite.
+ (BOOL)validatePublishedDescriptorIdentifiersAtPath:(NSString *)path error:(NSError **)error {
    return LBValidatePublishedDescriptorIdentifierConsistency(path, error);
}

+ (NSString *)findPosterBoardContainer:(NSError **)error {
    NSArray<NSString *> *roots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Data/InternalDaemon",
        @"/var/mobile/Containers/Data/PluginKitPlugin"
    ];
    for (NSString *base in roots) {
        if (!LBIsDirectory(base)) continue;
        for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil] ?: @[]) {
            NSString *candidate = [base stringByAppendingPathComponent:entry];
            if (!LBIsDirectory(candidate)) continue;
            NSString *metadataPath = [candidate stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            if (!LBIsRegularFile(metadataPath)) continue;
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            if ([metadata[@"MCMMetadataIdentifier"] isEqual:@"com.apple.PosterBoard"]) return candidate;
        }
    }
    if (error) *error = LBInstallError(51, @"PosterBoard app data container was not found by MCMMetadataIdentifier.");
    return nil;
}

+ (NSDictionary *)verifyRegisteredDescriptorIdentifiers:(NSArray<NSString *> *)identifiers
                                             posterBoardContainer:(NSString *)containerPath
                                                             error:(NSError **)error {
    if (![identifiers isKindOfClass:NSArray.class] || identifiers.count == 0 || identifiers.count > 256) {
        if (error) *error = LBInstallError(55, @"No bounded list of previously registered descriptor identifiers was supplied.");
        return nil;
    }
    if (!LBIsDirectory(containerPath)) {
        if (error) *error = LBInstallError(56, @"The resolved PosterBoard container is not a regular directory.");
        return nil;
    }

    NSString *descriptorRoot = [[containerPath stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore/59/Extensions"]
        stringByAppendingPathComponent:[LBCollectionsExtension stringByAppendingPathComponent:@"descriptors"]];
    NSMutableArray<NSString *> *present = [NSMutableArray array];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *invalid = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (id value in identifiers) {
        if (![value isKindOfClass:NSString.class]) {
            if (error) *error = LBInstallError(57, @"A stored descriptor identifier is not a string.");
            return nil;
        }
        NSString *uuid = [(NSString *)value uppercaseString];
        NSUUID *parsed = [[NSUUID alloc] initWithUUIDString:uuid];
        if (!parsed || ![parsed.UUIDString isEqualToString:uuid] || [seen containsObject:uuid]) {
            if (error) *error = LBInstallError(58, @"The stored descriptor identifier list contains an invalid or duplicate UUID.");
            return nil;
        }
        [seen addObject:uuid];
        NSString *descriptorPath = [descriptorRoot stringByAppendingPathComponent:uuid];
        if (!LBIsDirectory(descriptorPath)) {
            NSString *dataStoreBase = [containerPath stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
            for (NSString *v in @[@"59", @"61"]) {
                for (NSString *ext in @[LBCollectionsExtension, LBCollectionsAppExtension]) {
                    NSString *altPath = [[[[dataStoreBase stringByAppendingPathComponent:v]
                        stringByAppendingPathComponent:@"Extensions"]
                        stringByAppendingPathComponent:ext]
                        stringByAppendingPathComponent:[NSString stringWithFormat:@"descriptors/%@", uuid]];
                    if (LBIsDirectory(altPath)) {
                        descriptorPath = altPath;
                        break;
                    }
                }
                if (LBIsDirectory(descriptorPath)) break;
            }
        }
        if (!LBIsDirectory(descriptorPath)) {
            [missing addObject:uuid];
            continue;
        }
        NSError *validationError = nil;
        if (!LBValidateDescriptorTree(descriptorPath, &validationError) ||
            !LBValidatePublishedDescriptorIdentifierConsistency(descriptorPath, &validationError)) {
            [invalid addObject:@{
                @"identifier": uuid,
                @"error": validationError.localizedDescription ?: @"Descriptor structure/identifier validation failed."
            }];
            continue;
        }
        [present addObject:uuid];
    }

    NSString *state = @"complete";
    if (invalid.count && present.count == 0) state = @"invalid";
    else if (invalid.count) state = @"partial-invalid";
    else if (missing.count && present.count) state = @"partial";
    else if (missing.count) state = @"missing";

    NSString *storeRoot = [containerPath stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore/59"];
    NSString *sqlitePath = [storeRoot stringByAppendingPathComponent:@"PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"];
    struct stat sStat;
    BOOL sqliteExists = (lstat(sqlitePath.fileSystemRepresentation, &sStat) == 0 && S_ISREG(sStat.st_mode) && !S_ISLNK(sStat.st_mode));
    NSUInteger sqliteFoundCount = 0;
    if (sqliteExists) {
        sqliteFoundCount = LBCountRegisteredDescriptorsInSQLite(sqlitePath, identifiers);
    }

    return @{
        @"descriptorStoreState": state,
        @"verificationScope": sqliteExists ? @"filesystem-and-sqlite-verified" : @"filesystem-registration-only",
        @"posterBoardApplicationState": @"unverified",
        @"expectedDescriptorCount": @(identifiers.count),
        @"presentDescriptorCount": @(present.count),
        @"missingDescriptorCount": @(missing.count),
        @"invalidDescriptorCount": @(invalid.count),
        @"presentDescriptorIdentifiers": present,
        @"missingDescriptorIdentifiers": missing,
        @"invalidDescriptors": invalid,
        @"descriptorStructureVersion": @(LBExpectedStructureVersion),
        @"extension": LBCollectionsExtension,
        @"sqliteDatabasePresent": @(sqliteExists),
        @"sqliteRegisteredCount": @(sqliteFoundCount)
    };
}

+ (NSDictionary *)installArchiveAtPath:(NSString *)archivePath posterBoardContainer:(NSString *)containerPath error:(NSError **)error {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    if (os.majorVersion != 16) {
        if (error) *error = LBInstallError(52, @"This importer currently targets PosterBoard descriptor structure 59 on iOS 16 only.");
        return nil;
    }
    if (!LBIsDirectory(containerPath)) {
        if (error) *error = LBInstallError(53, @"The resolved PosterBoard container is not a regular directory.");
        return nil;
    }
    NSString *applicationSupport = [containerPath stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *dataStoreBase = [applicationSupport stringByAppendingPathComponent:@"PRBPosterExtensionDataStore"];

    NSMutableArray<NSString *> *activeVersions = [NSMutableArray array];
    for (NSString *v in @[@"59", @"61"]) {
        NSString *vPath = [dataStoreBase stringByAppendingPathComponent:v];
        if (LBIsDirectory(vPath)) {
            [activeVersions addObject:v];
        }
    }
    if (activeVersions.count == 0) {
        [activeVersions addObject:@"59"];
    }

    for (NSString *v in activeVersions) {
        for (NSString *ext in @[LBCollectionsExtension, LBCollectionsAppExtension]) {
            NSString *descRoot = [[[[dataStoreBase stringByAppendingPathComponent:v]
                stringByAppendingPathComponent:@"Extensions"]
                stringByAppendingPathComponent:ext]
                stringByAppendingPathComponent:@"descriptors"];
            LBCleanupStaleDescriptors(descRoot);
        }
    }

    NSString *primaryVersion = activeVersions.firstObject;
    NSString *extensionRoot = [[[dataStoreBase stringByAppendingPathComponent:primaryVersion]
        stringByAppendingPathComponent:@"Extensions"]
        stringByAppendingPathComponent:LBCollectionsExtension];
    NSString *descriptorRoot = [extensionRoot stringByAppendingPathComponent:@"descriptors"];

    NSString *stage = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"LumenBoard-%@", NSUUID.UUID.UUIDString.lowercaseString]];
    NSError *validationError = nil;
    NSDictionary *validation = [LBTendiesValidator validateArchiveAtPath:archivePath extractToPath:stage error:&validationError];
    if (![validation[@"status"] isEqual:@"extracted"]) {
        if (error) *error = validationError ?: LBInstallError(54, @"The .tendies archive did not pass validation and extraction.");
        return nil;
    }
    NSDictionary *result = [self installExtractedDescriptorTreeAtPath:stage descriptorRoot:descriptorRoot error:error];
    [NSFileManager.defaultManager removeItemAtPath:stage error:nil];
    if (!result) return nil;

    NSArray<NSString *> *installedUUIDs = result[@"installedDescriptorIdentifiers"] ?: @[];
    for (NSString *v in activeVersions) {
        for (NSString *ext in @[LBCollectionsExtension, LBCollectionsAppExtension]) {
            NSString *targetDescRoot = [[[[dataStoreBase stringByAppendingPathComponent:v]
                stringByAppendingPathComponent:@"Extensions"]
                stringByAppendingPathComponent:ext]
                stringByAppendingPathComponent:@"descriptors"];
            if ([targetDescRoot isEqualToString:descriptorRoot]) continue;

            LBEnsureDirectoryTree(targetDescRoot, 0755, nil);
            for (NSString *uuid in installedUUIDs) {
                NSString *src = [descriptorRoot stringByAppendingPathComponent:uuid];
                NSString *dst = [targetDescRoot stringByAppendingPathComponent:uuid];
                if (!LBIsDirectory(src)) continue;
                if (LBIsDirectory(dst)) [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
                if ([NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:nil]) {
                    LBSetMobileOwnership(dst, nil);
                }
            }
        }
    }

    NSMutableDictionary *final = [result mutableCopy];
    [final addEntriesFromDictionary:[self requestPosterBoardRefreshForContainer:containerPath]];
    return final;
}

+ (NSDictionary *)installExtractedDescriptorTreeAtPath:(NSString *)extractedPath descriptorRoot:(NSString *)descriptorRoot error:(NSError **)error {
    if (!LBIsDirectory(extractedPath)) {
        if (error) *error = LBInstallError(60, @"The extracted descriptor tree is missing.");
        return nil;
    }
    NSMutableArray<NSString *> *sourceRoots = [NSMutableArray array];
    BOOL orderedGroup = NO;
    if (!LBCollectDescriptorRoots(extractedPath, sourceRoots, &orderedGroup, error)) return nil;
    for (NSString *source in sourceRoots) if (!LBValidateDescriptorTree(source, error)) return nil;

    NSString *extensionRoot = descriptorRoot.stringByDeletingLastPathComponent;
    if (!LBEnsureDirectoryTree(extensionRoot, 0755, error) || !LBEnsureDirectoryTree(descriptorRoot, 0755, error)) return nil;
    NSMutableSet<NSNumber *> *usedIDs = [NSMutableSet set];
    if (!LBReadExistingNumericIdentifiers(descriptorRoot, usedIDs, error)) return nil;

    NSString *stagingRoot = [extensionRoot stringByAppendingPathComponent:[NSString stringWithFormat:@".lumenboard-staging-%@", NSUUID.UUID.UUIDString.lowercaseString]];
    if (!LBEnsureDirectory(stagingRoot, 0700, error)) return nil;
    NSMutableArray<NSString *> *stagedPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *publishedPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *committedPaths = [NSMutableArray array];
    NSMutableArray<NSString *> *publishedIdentifiers = [NSMutableArray array];
    BOOL success = YES;
    NSError *localError = nil;

    for (NSString *source in sourceRoots) {
        NSString *newUUID = NSUUID.UUID.UUIDString.uppercaseString;
        NSString *staged = [stagingRoot stringByAppendingPathComponent:newUUID];
        NSString *destination = [descriptorRoot stringByAppendingPathComponent:newUUID];
        struct stat destinationStat;
        if (lstat(destination.fileSystemRepresentation, &destinationStat) == 0 || errno != ENOENT) {
            localError = LBInstallError(61, @"Generated descriptor UUID unexpectedly collides with an existing item.");
            success = NO;
            break;
        }
        if (![NSFileManager.defaultManager copyItemAtPath:source toPath:staged error:&localError]) { success = NO; break; }
        NSInteger identifier = 0;
        NSString *srcIDText = LBReadTrimmedString([source stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]);
        NSUInteger idLen = srcIDText.length > 0 ? srcIDText.length : 5;
        NSInteger minCandidate = (idLen == 4) ? 1000 : 10000;
        NSInteger maxCandidate = (idLen == 4) ? 9999 : 99999;
        NSInteger rangeCandidate = maxCandidate - minCandidate + 1;
        if (orderedGroup) {
            for (NSInteger candidate = maxCandidate; candidate >= minCandidate; candidate--) {
                if (![usedIDs containsObject:@(candidate)]) { identifier = candidate; break; }
            }
        } else {
            long long srcNumeric = [srcIDText longLongValue];
            for (NSUInteger attempt = 0; attempt < 1000; attempt++) {
                NSInteger candidate = minCandidate + arc4random_uniform((uint32_t)rangeCandidate);
                if (candidate != srcNumeric && ![usedIDs containsObject:@(candidate)]) {
                    identifier = candidate;
                    break;
                }
            }
            if (!identifier && srcNumeric >= minCandidate && srcNumeric <= maxCandidate && ![usedIDs containsObject:@(srcNumeric)]) {
                identifier = (NSInteger)srcNumeric;
            }
        }
        if (!identifier) {
            localError = LBInstallError(62, @"Could not allocate a collision-free PosterBoard wallpaper identifier.");
            success = NO;
            break;
        }
        [usedIDs addObject:@(identifier)];
        if (!LBRewriteDescriptorIdentifiers(staged, identifier, &localError) || !LBSetMobileOwnership(staged, &localError)) { success = NO; break; }
        [stagedPaths addObject:staged];
        [publishedPaths addObject:destination];
        [publishedIdentifiers addObject:newUUID];
    }

    if (success) {
        for (NSUInteger index = 0; index < stagedPaths.count; index++) {
            NSString *staged = stagedPaths[index];
            NSString *destination = publishedPaths[index];
            // Re-check immediately before publication and refuse to replace any
            // object created concurrently since the initial collision check.
            struct stat destinationStat;
            if (lstat(destination.fileSystemRepresentation, &destinationStat) == 0 || errno != ENOENT) {
                localError = LBInstallError(64, @"Destination UUID appeared during staging; refusing to overwrite it.");
                success = NO;
                break;
            }
            if (rename(staged.fileSystemRepresentation, destination.fileSystemRepresentation) != 0) {
                localError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
                success = NO;
                break;
            }
            chmod(destination.fileSystemRepresentation, 0775);
            [committedPaths addObject:destination];
        }
    }
    if (success) {
        // Verify the bytes at their final PosterBoard paths after publication.
        // A successful rename alone is not treated as a complete registration.
        for (NSString *path in committedPaths) {
            NSError *verificationError = nil;
            if (!LBValidateDescriptorTree(path, &verificationError) ||
                !LBValidatePublishedDescriptorIdentifierConsistency(path, &verificationError)) {
                localError = verificationError ?: LBInstallError(67, @"A published descriptor failed its post-publication structure or identifier verification.");
                success = NO;
                break;
            }
        }
    }

    BOOL sqliteUpdated = NO;
    NSString *storeRoot = descriptorRoot.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSString *sqlitePath = [storeRoot stringByAppendingPathComponent:@"PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"];
    struct stat sqliteStat;
    BOOL sqliteExists = (lstat(sqlitePath.fileSystemRepresentation, &sqliteStat) == 0 && S_ISREG(sqliteStat.st_mode) && !S_ISLNK(sqliteStat.st_mode));

    if (success && sqliteExists) {
        // In PosterBoard's architecture on iOS 16, descriptor blueprints live exclusively
        // in descriptors/ (for Add Wallpaper -> Collections) and MUST NOT be registered
        // in posterRoleMembership (which is strictly for active lockscreen configurations
        // in configurations/). Registering descriptors in posterRoleMembership causes
        // PosterBoard to fail when looking for missing configurations/ folders.
        // We prune any stale or accidentally registered descriptor UUIDs from SQLite.
        LBCleanupStalePosterBoardDatabase(sqlitePath, storeRoot);
        sqliteUpdated = YES;
    }

    if (!success) {
        // Roll back only directories this invocation actually published. Never
        // delete a colliding path that appeared concurrently.
        for (NSString *path in committedPaths.reverseObjectEnumerator) {
            if (LBIsDirectory(path)) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
        if (sqliteExists && sqliteUpdated) {
            LBRollbackDescriptorsInSQLiteDatabase(sqlitePath, publishedIdentifiers);
        }
        [NSFileManager.defaultManager removeItemAtPath:stagingRoot error:nil];
        if (error) *error = localError ?: LBInstallError(63, @"Descriptor publication failed and was rolled back.");
        return nil;
    }
    [NSFileManager.defaultManager removeItemAtPath:stagingRoot error:nil];
    NSMutableDictionary *resultReport = [@{
        @"installedDescriptorIdentifiers": publishedIdentifiers,
        @"installedDescriptorCount": @(publishedIdentifiers.count),
        @"descriptorStructureVersion": @(LBExpectedStructureVersion),
        @"extension": LBCollectionsExtension,
        @"descriptorStoreVerified": @YES,
        @"verificationScope": sqliteUpdated ? @"filesystem-and-sqlite-registered" : @"filesystem-registration-only",
        @"sqliteDatabaseUpdated": @(sqliteUpdated),
        @"posterBoardApplicationState": @"unverified"
    } mutableCopy];
    if (sqliteExists) {
        resultReport[@"sqliteDatabasePath"] = sqlitePath;
    }
    return resultReport;
}


+ (NSDictionary *)requestPosterBoardRefreshForContainer:(NSString *)containerPath {
    NSString *preferencesDirectory = [containerPath stringByAppendingPathComponent:@"Library/Preferences"];
    NSString *preferencesPath = [preferencesDirectory stringByAppendingPathComponent:@"com.apple.PosterBoard.unprotectedUserDefaults.plist"];
    int savedErrno = 0;
    NSString *failureReason = nil;
    BOOL written = NO;

    do {
        if (!LBIsDirectory(containerPath) || !LBIsDirectory(preferencesDirectory)) {
            savedErrno = ENOENT;
            failureReason = @"The PosterBoard container or Preferences directory is unavailable.";
            break;
        }
        struct passwd *mobile = getpwnam("mobile");
        if (!mobile && geteuid() == 0) {
            savedErrno = ENOENT;
            failureReason = @"The mobile account could not be resolved.";
            break;
        }
        if (mobile && geteuid() != 0 && geteuid() != mobile->pw_uid) {
            savedErrno = EPERM;
            failureReason = @"The refresh preference must be written by mobile or by a process able to set mobile ownership.";
            break;
        }

        NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
        struct stat originalStat;
        if (lstat(preferencesPath.fileSystemRepresentation, &originalStat) == 0) {
            if (!S_ISREG(originalStat.st_mode) || S_ISLNK(originalStat.st_mode)) {
                savedErrno = EINVAL;
                failureReason = @"The existing PosterBoard refresh preference is not a regular file.";
                break;
            }
            NSError *readError = nil;
            NSData *existingData = [NSData dataWithContentsOfFile:preferencesPath options:NSDataReadingMappedIfSafe error:&readError];
            if (!existingData) {
                savedErrno = EIO;
                failureReason = [NSString stringWithFormat:@"Could not read the existing PosterBoard preferences: %@",
                    readError.localizedDescription ?: @"unknown read error"];
                break;
            }
            NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
            NSError *parseError = nil;
            id existingObject = [NSPropertyListSerialization propertyListWithData:existingData
                options:NSPropertyListMutableContainersAndLeaves format:&format error:&parseError];
            if (![existingObject isKindOfClass:NSDictionary.class]) {
                savedErrno = EINVAL;
                failureReason = [NSString stringWithFormat:@"The existing PosterBoard preferences are not a valid property-list dictionary: %@",
                    parseError.localizedDescription ?: @"invalid property list"];
                break;
            }
            preferences = [existingObject mutableCopy];
        } else if (errno != ENOENT) {
            savedErrno = errno;
            failureReason = @"Could not inspect the existing PosterBoard refresh preference.";
            break;
        }

        preferences[@"PBF_LOCALE_DID_CHANGE"] = @NO;
        preferences[@"PBF_RESET_FILE_PROTECTIONS"] = @YES;
        NSMutableArray *persisted = [preferences[@"PersistedPosterContainerBundleIdentifiers"] isKindOfClass:NSArray.class] ?
            [preferences[@"PersistedPosterContainerBundleIdentifiers"] mutableCopy] : [NSMutableArray array];
        for (NSString *ext in @[LBCollectionsAppExtension, LBCollectionsExtension]) {
            if (![persisted containsObject:ext]) [persisted addObject:ext];
        }
        preferences[@"PersistedPosterContainerBundleIdentifiers"] = persisted;
        preferences[@"CompletedPosterBundleIdentifierMigrations"] = @[
            @"com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
            @"com.apple.Posters.WeatherPosterApp.WeatherPoster",
            @"com.apple.Posters.UnityPosterApp.Unity2025Poster",
            @"com.apple.Posters.UnityPosterApp.UnityPosterExtension",
            @"com.apple.Posters.UnityPosterApp.RhizomePoster",
            @"com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
        ];

        // Clear the cached snapshot index and purge stale entries across all store versions
        NSString *dataStoreBase = [containerPath stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
        for (NSString *v in @[@"59", @"61"]) {
            NSString *storeRoot = [dataStoreBase stringByAppendingPathComponent:v];
            if (!LBIsDirectory(storeRoot)) continue;
            NSString *galleryIndex = [storeRoot stringByAppendingPathComponent:@"PRPosterRoleLockScreen-gallery-index.json"];
            struct stat giStat;
            if (lstat(galleryIndex.fileSystemRepresentation, &giStat) == 0 && S_ISREG(giStat.st_mode)) {
                [NSFileManager.defaultManager removeItemAtPath:galleryIndex error:nil];
            }
            NSString *sqlitePath = [storeRoot stringByAppendingPathComponent:@"PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"];
            struct stat sqStat;
            if (lstat(sqlitePath.fileSystemRepresentation, &sqStat) == 0 && S_ISREG(sqStat.st_mode)) {
                LBCleanupStalePosterBoardDatabase(sqlitePath, storeRoot);
            }
            for (NSString *ext in @[LBCollectionsExtension, LBCollectionsAppExtension]) {
                NSString *descRoot = [[[storeRoot stringByAppendingPathComponent:@"Extensions"] stringByAppendingPathComponent:ext] stringByAppendingPathComponent:@"descriptors"];
                LBCleanupStaleDescriptors(descRoot);
            }
        }
        NSError *serializationError = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:preferences
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
        if (!data) {
            savedErrno = EINVAL;
            failureReason = [NSString stringWithFormat:@"Could not serialize PosterBoard preferences: %@",
                serializationError.localizedDescription ?: @"unknown serialization error"];
            break;
        }
        NSError *writeError = nil;
        if (!LBWriteDataAtomically(data, preferencesPath, &writeError)) {
            savedErrno = [writeError.domain isEqualToString:NSPOSIXErrorDomain] ? (int)writeError.code : EIO;
            failureReason = [NSString stringWithFormat:@"Could not write PosterBoard refresh preferences: %@",
                writeError.localizedDescription ?: @"unknown write error"];
            break;
        }

        struct stat writtenStat;
        if (lstat(preferencesPath.fileSystemRepresentation, &writtenStat) != 0 ||
            !S_ISREG(writtenStat.st_mode) || S_ISLNK(writtenStat.st_mode)) {
            savedErrno = errno ?: EINVAL;
            failureReason = @"The written PosterBoard preference is not a regular file.";
            break;
        }
        if (mobile && (writtenStat.st_uid != mobile->pw_uid || writtenStat.st_gid != mobile->pw_gid)) {
            if (geteuid() != 0 || chown(preferencesPath.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid) != 0) {
                savedErrno = errno ?: EPERM;
                failureReason = @"The PosterBoard preference could not be assigned to mobile:mobile.";
                break;
            }
        }
        if (chmod(preferencesPath.fileSystemRepresentation, 0644) != 0) {
            savedErrno = errno;
            failureReason = @"Could not set readable permissions on the PosterBoard preference.";
            break;
        }
        struct stat verifiedStat;
        if (lstat(preferencesPath.fileSystemRepresentation, &verifiedStat) != 0 ||
            !S_ISREG(verifiedStat.st_mode) || S_ISLNK(verifiedStat.st_mode) ||
            (mobile && (verifiedStat.st_uid != mobile->pw_uid || verifiedStat.st_gid != mobile->pw_gid))) {
            savedErrno = errno ?: EPERM;
            failureReason = @"PosterBoard preference ownership or file type could not be verified after writing.";
            break;
        }
        NSString *mobilePrefs = @"/var/mobile/Library/Preferences/com.apple.PosterBoard.unprotectedUserDefaults.plist";
        struct stat mobilePrefsDirStat;
        if (lstat("/var/mobile/Library/Preferences", &mobilePrefsDirStat) == 0 && S_ISDIR(mobilePrefsDirStat.st_mode) && !S_ISLNK(mobilePrefsDirStat.st_mode)) {
            LBWriteDataAtomically(data, mobilePrefs, NULL);
            if (mobile && (geteuid() == 0 || geteuid() == mobile->pw_uid)) {
                chown(mobilePrefs.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid);
            }
            chmod(mobilePrefs.fileSystemRepresentation, 0644);
        }
        written = YES;
    } while (0);

    NSMutableDictionary *result = [@{
        @"refreshPreferencesWritten": @(written),
        @"refreshPreferencesErrno": @(written ? 0 : (savedErrno ?: EIO)),
        @"refreshCommandAttempted": @NO,
        @"posterBoardRefreshRequested": @NO,
        @"posterBoardRefreshRequiresDeviceRestart": @(written)
    } mutableCopy];
    if (written) {
        result[@"refreshWarning"] = @"PosterBoard refresh flags were written and their file type/ownership were verified. LumenBoard does not terminate or signal system processes; a full device restart may be needed for PosterBoard to reload the store.";
    } else {
        result[@"refreshWarning"] = [NSString stringWithFormat:@"PosterBoard refresh preferences were not written or verified (errno %d: %@).",
            savedErrno ?: EIO, failureReason ?: @"unknown error"];
    }
    return result;
}

+ (BOOL)removeDescriptorIdentifiers:(NSArray<NSString *> *)identifiers
              posterBoardContainer:(NSString *)containerPath
                             error:(NSError **)error {
    (void)error;
    if (!identifiers.count || !LBIsDirectory(containerPath)) return YES;
    NSString *dataStoreBase = [containerPath stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore"];
    for (NSString *v in @[@"59", @"61"]) {
        NSString *vDir = [dataStoreBase stringByAppendingPathComponent:v];
        if (!LBIsDirectory(vDir)) continue;
        for (NSString *ext in @[LBCollectionsExtension, LBCollectionsAppExtension]) {
            NSString *descriptorRoot = [[[vDir stringByAppendingPathComponent:@"Extensions"]
                stringByAppendingPathComponent:ext]
                stringByAppendingPathComponent:@"descriptors"];
            for (NSString *uuid in identifiers) {
                if (![uuid isKindOfClass:NSString.class] || !uuid.length) continue;
                NSString *path = [descriptorRoot stringByAppendingPathComponent:uuid];
                if (LBIsDirectory(path)) {
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                }
            }
        }
    }
    [self requestPosterBoardRefreshForContainer:containerPath];
    return YES;
}

@end

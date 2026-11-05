#import <XCTest/XCTest.h>
#import "../../Daemon/LBPosterBoardInstaller.h"
#import <sqlite3.h>
#import <sys/stat.h>
#import <unistd.h>

@interface LBPosterBoardInstaller (DeviceFamilyTesting)
+ (BOOL)validateLogicalScreenClass:(NSString *)logicalScreenClass
                machineIdentifier:(NSString *)machineIdentifier
                             error:(NSError **)error;
+ (BOOL)validatePublishedDescriptorIdentifiersAtPath:(NSString *)path error:(NSError **)error;
@end

@interface LBPosterBoardInstallerTests : XCTestCase
@property(nonatomic, copy) NSString *temporaryRoot;


@end

@implementation LBPosterBoardInstallerTests

- (void)setUp {
    [super setUp];
    self.temporaryRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"LumenBoardInstallerTests-%@", NSUUID.UUID.UUIDString.lowercaseString]];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.temporaryRoot
        withIntermediateDirectories:NO attributes:nil error:&error], @"%@", error);
}

- (void)tearDown {
    if (self.temporaryRoot.length) [[NSFileManager defaultManager] removeItemAtPath:self.temporaryRoot error:nil];
    [super tearDown];
}

- (BOOL)writePlist:(id)object toPath:(NSString *)path {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:&error];
}

- (NSString *)makeDescriptorGroupWithNames:(NSArray<NSString *> *)names
                              missingFiles:(NSSet<NSString *> *)missingFiles {
    NSString *group = [self.temporaryRoot stringByAppendingPathComponent:@"input/descriptors"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:group withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSUInteger index = 0;
    for (NSString *name in names) {
        index++;
        NSString *root = [group stringByAppendingPathComponent:[NSString stringWithFormat:@"fixture-%lu", (unsigned long)index]];
        NSString *contents = [root stringByAppendingPathComponent:@"versions/1/contents"];
        NSString *wallpaperName = [NSString stringWithFormat:@"Fixture%lu.Custom.wallpaper", (unsigned long)index];
        NSString *wallpaper = [contents stringByAppendingPathComponent:wallpaperName];
        XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:wallpaper withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);

        if (![missingFiles containsObject:@"descriptor-id"]) {
            [@"12345" writeToFile:[root stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
                atomically:YES encoding:NSUTF8StringEncoding error:&error];
        }
        if (![missingFiles containsObject:@"role"]) {
            [@"PRPosterRoleLockScreen" writeToFile:[root stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"]
                atomically:YES encoding:NSUTF8StringEncoding error:&error];
        }
        if (![missingFiles containsObject:@"provider-info"]) {
            XCTAssertTrue([self writePlist:@{@"kConfigurationLastUseDateKey":[NSDate date]}
                toPath:[root stringByAppendingPathComponent:@"providerInfo.plist"]]);
        }
        if (![missingFiles containsObject:@"user-info"]) {
            NSDictionary *userInfo = @{
                @"wallpaperRepresentingFileName":wallpaperName,
                @"wallpaperRepresentingIdentifier":@"12345",
                @"posterEnvironmentOverrides":[@"{}" dataUsingEncoding:NSUTF8StringEncoding]
            };
            XCTAssertTrue([self writePlist:userInfo
                toPath:[contents stringByAppendingPathComponent:@"com.apple.posterkit.provider.contents.userInfo"]]);
        }
        if (![missingFiles containsObject:@"wallpaper-plist"]) {
            NSDictionary *wallpaperPlist = @{
                @"identifier":@12345,
                @"name":name,
                @"assets":@{
                    @"lockAndHome":@{
                        @"default":@{
                            @"identifier":@12345,
                            @"name":name,
                            @"type":@"LayeredAnimation",
                            @"backgroundAnimationFileName":@"PF_Background.ca",
                            @"floatingAnimationFileNameKey":@"PF_Floating.ca"
                        }
                    }
                }
            };
            XCTAssertTrue([self writePlist:wallpaperPlist
                toPath:[wallpaper stringByAppendingPathComponent:@"Wallpaper.plist"]]);
            for (NSString *layerName in @[@"PF_Background.ca", @"PF_Floating.ca"]) {
                NSString *layer = [wallpaper stringByAppendingPathComponent:layerName];
                XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:layer withIntermediateDirectories:NO attributes:nil error:&error], @"%@", error);
                [@"<caml/>" writeToFile:[layer stringByAppendingPathComponent:@"main.caml"] atomically:YES encoding:NSUTF8StringEncoding error:&error];
                NSDictionary *layerIndex = @{
                    @"assetManifest":@"assetManifest.caml",
                    @"documentHeight":@1,
                    @"documentResizesToView":@YES,
                    @"documentWidth":@1,
                    @"geometryFlipped":@NO,
                    @"rootDocument":@"main.caml",
                    @"scalesToFitInPlayer":@YES
                };
                XCTAssertTrue([self writePlist:layerIndex toPath:[layer stringByAppendingPathComponent:@"index.xml"]]);
            }
        }
        [@"fixture asset" writeToFile:[wallpaper stringByAppendingPathComponent:@"sample.asset"]
            atomically:YES encoding:NSUTF8StringEncoding error:&error];
    }
    return [self.temporaryRoot stringByAppendingPathComponent:@"input"];
}

- (NSDictionary *)install:(NSString *)input {
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    if (!result) XCTFail(@"Installer failed: %@", error);
    return result;
}

- (void)testInstallsOneDescriptorAndRewritesAllLinkedIdentifiers {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Synthetic wallpaper"] missingFiles:[NSSet set]];
    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"installedDescriptorCount"], @1);
    XCTAssertEqualObjects(result[@"descriptorStructureVersion"], @59);
    XCTAssertEqualObjects(result[@"extension"], @"com.apple.WallpaperKit.CollectionsPoster");

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *uuid = [result[@"installedDescriptorIdentifiers"] firstObject];
    XCTAssertNotNil([[NSUUID alloc] initWithUUIDString:uuid]);
    NSString *published = [descriptorRoot stringByAppendingPathComponent:uuid];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[published stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]]);

    NSString *rootID = [NSString stringWithContentsOfFile:[published stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
        encoding:NSUTF8StringEncoding error:nil];
    NSInteger numericID = rootID.integerValue;
    XCTAssertGreaterThanOrEqual(numericID, 10000);
    XCTAssertLessThanOrEqual(numericID, 99999);
    XCTAssertNotEqual(numericID, 12345);

    NSString *contents = [published stringByAppendingPathComponent:@"versions/1/contents"];
    NSString *userInfoPath = [contents stringByAppendingPathComponent:@"com.apple.posterkit.provider.contents.userInfo"];
    NSDictionary *userInfo = [NSDictionary dictionaryWithContentsOfFile:userInfoPath];
    XCTAssertEqualObjects(userInfo[@"wallpaperRepresentingIdentifier"], rootID);
    NSString *wallpaperName = userInfo[@"wallpaperRepresentingFileName"];
    NSString *wallpaperPath = [contents stringByAppendingPathComponent:wallpaperName];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[wallpaperPath stringByAppendingPathComponent:@"sample.asset"]]);
    NSDictionary *wallpaperPlist = [NSDictionary dictionaryWithContentsOfFile:[wallpaperPath stringByAppendingPathComponent:@"Wallpaper.plist"]];
    XCTAssertEqualObjects(wallpaperPlist[@"identifier"], @(numericID));
    XCTAssertEqualObjects(wallpaperPlist[@"assets"][@"lockAndHome"][@"default"][@"identifier"], @(numericID));
}

- (void)testPublishedDescriptorIsRevalidatedAtItsFinalPosterBoardPath {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Post-publication check"] missingFiles:[NSSet set]];
    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"descriptorStoreVerified"], @YES);
    XCTAssertEqualObjects(result[@"verificationScope"], @"filesystem-registration-only");
    XCTAssertEqualObjects(result[@"posterBoardApplicationState"], @"unverified");
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *uuid = [result[@"installedDescriptorIdentifiers"] firstObject];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[descriptorRoot stringByAppendingPathComponent:uuid]]);
}

- (void)testAcceptsExistingDescriptorWithValidRootIdentifierWithoutMetadataFallback {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Legacy root identifier"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *existing = [descriptorRoot stringByAppendingPathComponent:@"existing-descriptor"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:existing withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *rootIDPath = [existing stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"];
    XCTAssertTrue([@"12345" writeToFile:rootIDPath atomically:YES encoding:NSUTF8StringEncoding error:&error], @"%@", error);

    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNotNil(result, @"%@", error);
    XCTAssertNil(error);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:rootIDPath]);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot error:nil].count, 2u);
}

- (void)testRecoversMissingRootIdentifierFromConsistentDescriptorMetadata {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Metadata recovery"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *existing = [descriptorRoot stringByAppendingPathComponent:@"existing-descriptor"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:descriptorRoot withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *fixture = [[input stringByAppendingPathComponent:@"descriptors"] stringByAppendingPathComponent:@"fixture-1"];
    XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath:fixture toPath:existing error:&error], @"%@", error);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:[existing stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] error:&error], @"%@", error);

    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNotNil(result, @"%@", error);
    XCTAssertNil(error);
    XCTAssertEqual([result[@"installedDescriptorIdentifiers"] count], 1u);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:existing]);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot error:nil].count, 2u);
}

- (void)testRecoversMissingRootIdentifierWhenExistingDefaultLayerOmitsIdentifier {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Metadata recovery without default ID"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *existing = [descriptorRoot stringByAppendingPathComponent:@"existing-descriptor"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:descriptorRoot withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *fixture = [[input stringByAppendingPathComponent:@"descriptors"] stringByAppendingPathComponent:@"fixture-1"];
    XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath:fixture toPath:existing error:&error], @"%@", error);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:[existing stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] error:&error], @"%@", error);
    NSString *wallpaperPath = [[existing stringByAppendingPathComponent:@"versions/1/contents/Fixture1.Custom.wallpaper"] stringByAppendingPathComponent:@"Wallpaper.plist"];
    NSMutableDictionary *wallpaper = [[NSDictionary dictionaryWithContentsOfFile:wallpaperPath] mutableCopy];
    NSMutableDictionary *assets = [wallpaper[@"assets"] mutableCopy];
    NSMutableDictionary *lockAndHome = [assets[@"lockAndHome"] mutableCopy];
    NSMutableDictionary *defaultLayer = [lockAndHome[@"default"] mutableCopy];
    [defaultLayer removeObjectForKey:@"identifier"];
    lockAndHome[@"default"] = defaultLayer;
    assets[@"lockAndHome"] = lockAndHome;
    wallpaper[@"assets"] = assets;
    XCTAssertTrue([self writePlist:wallpaper toPath:wallpaperPath]);

    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNotNil(result, @"%@", error);
    XCTAssertNil(error);
    XCTAssertEqual([result[@"installedDescriptorIdentifiers"] count], 1u);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot error:nil].count, 2u);
}

- (void)testRefusesMetadataRecoveryWhenWallpaperIdentifiersDisagree {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Metadata mismatch"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *existing = [descriptorRoot stringByAppendingPathComponent:@"existing-descriptor"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:descriptorRoot withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *fixture = [[input stringByAppendingPathComponent:@"descriptors"] stringByAppendingPathComponent:@"fixture-1"];
    XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath:fixture toPath:existing error:&error], @"%@", error);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:[existing stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] error:&error], @"%@", error);
    NSString *wallpaperPath = [[existing stringByAppendingPathComponent:@"versions/1/contents/Fixture1.Custom.wallpaper"] stringByAppendingPathComponent:@"Wallpaper.plist"];
    NSMutableDictionary *wallpaper = [[NSDictionary dictionaryWithContentsOfFile:wallpaperPath] mutableCopy];
    wallpaper[@"identifier"] = @54321;
    XCTAssertTrue([self writePlist:wallpaper toPath:wallpaperPath]);

    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 66);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot error:nil].count, 1u);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:existing]);
}

- (void)testRefusesDuplicateIdentifiersAcrossExistingDescriptors {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Duplicate guard"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:descriptorRoot withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *fixture = [[input stringByAppendingPathComponent:@"descriptors"] stringByAppendingPathComponent:@"fixture-1"];
    for (NSString *name in @[@"existing-a", @"existing-b"]) {
        XCTAssertTrue([[NSFileManager defaultManager] copyItemAtPath:fixture
            toPath:[descriptorRoot stringByAppendingPathComponent:name] error:&error], @"%@", error);
    }

    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 66);
    XCTAssertEqual([NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorRoot error:nil].count, 2u);
}

- (void)testRefusesToPublishWhenExistingDescriptorHasNoNumericIdentifier {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Collision guard"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *existing = [descriptorRoot stringByAppendingPathComponent:@"existing-descriptor"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:existing withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 66);
    NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:descriptorRoot error:nil] ?: @[];
    XCTAssertEqual(entries.count, 1u);
    XCTAssertTrue([entries containsObject:@"existing-descriptor"]);
}

- (void)testRejectsMalformedIndexPropertyListBeforePublishing {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Malformed index"] missingFiles:[NSSet set]];
    NSString *indexPath = [[[[input stringByAppendingPathComponent:@"descriptors"]
        stringByAppendingPathComponent:@"fixture-1"] stringByAppendingPathComponent:@"versions/1/contents"]
        stringByAppendingPathComponent:@"Fixture1.Custom.wallpaper/PF_Background.ca/index.xml"];
    XCTAssertTrue([@"not a property list" writeToFile:indexPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 32);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testRejectsMalformedCAMLBeforePublishing {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Malformed CAML"] missingFiles:[NSSet set]];
    NSString *camlPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Background.ca/main.caml"];
    XCTAssertTrue([@"<caml><layer>" writeToFile:camlPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 33);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testResolvesPercentEncodedCAMLAssetFilename {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Percent-encoded CAML asset"] missingFiles:[NSSet set]];
    NSString *layer = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Background.ca"];
    NSString *assets = [layer stringByAppendingPathComponent:@"assets"];
    NSError *fileError = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:assets withIntermediateDirectories:YES attributes:nil error:&fileError], @"%@", fileError);
    XCTAssertTrue([@"fixture asset" writeToFile:[assets stringByAppendingPathComponent:@"cloud2 1.png"]
        atomically:YES encoding:NSUTF8StringEncoding error:&fileError], @"%@", fileError);
    NSString *camlPath = [layer stringByAppendingPathComponent:@"main.caml"];
    XCTAssertTrue([@"<caml><contents src=\"assets/cloud2%201.png\"/></caml>"
        writeToFile:camlPath atomically:YES encoding:NSUTF8StringEncoding error:&fileError], @"%@", fileError);

    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"installedDescriptorCount"], @1);
}

- (void)testRejectsPercentEncodedCAMLPathTraversal {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Encoded traversal"] missingFiles:[NSSet set]];
    NSString *camlPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Background.ca/main.caml"];
    XCTAssertTrue([@"<caml><contents src=\"%2e%2e/escape.png\"/></caml>"
        writeToFile:camlPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 34);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testRejectsMalformedPercentEscapeInCAMLAssetReference {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Malformed asset URL"] missingFiles:[NSSet set]];
    NSString *camlPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Background.ca/main.caml"];
    XCTAssertTrue([@"<caml><contents src=\"assets/bad%2.png\"/></caml>"
        writeToFile:camlPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 34);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testRejectsMissingCAMLAssetBeforePublishing {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Missing CAML asset"] missingFiles:[NSSet set]];
    NSString *camlPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Background.ca/main.caml"];
    XCTAssertTrue([@"<caml><contents src=\"assets/missing.jpg\"/></caml>" writeToFile:camlPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 35);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testNonDictionaryUserInfoIsRejectedWithoutThrowing {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Invalid user-info root"] missingFiles:[NSSet set]];
    NSString *userInfoPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/com.apple.posterkit.provider.contents.userInfo"];
    XCTAssertTrue([self writePlist:@"not a dictionary" toPath:userInfoPath]);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = nil;
    XCTAssertNoThrow(result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error]);
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 24);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testNonDictionaryWallpaperPlistIsRejectedWithoutThrowing {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Invalid wallpaper root"] missingFiles:[NSSet set]];
    NSString *wallpaperPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/Wallpaper.plist"];
    XCTAssertTrue([self writePlist:@"not a dictionary" toPath:wallpaperPath]);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = nil;
    XCTAssertNoThrow(result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error]);
    XCTAssertNil(result);
    XCTAssertEqual(error.code, 26);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:descriptorRoot]);
}

- (void)testMissingDefaultLayerIdentifierIsAddedDuringRewrite {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Missing layer identifier"] missingFiles:[NSSet set]];
    NSString *wallpaperPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/Wallpaper.plist"];
    NSMutableDictionary *wallpaper = [[NSDictionary dictionaryWithContentsOfFile:wallpaperPath] mutableCopy];
    NSMutableDictionary *assets = [wallpaper[@"assets"] mutableCopy];
    NSMutableDictionary *lockAndHome = [assets[@"lockAndHome"] mutableCopy];
    NSMutableDictionary *defaultLayer = [lockAndHome[@"default"] mutableCopy];
    [defaultLayer removeObjectForKey:@"identifier"];
    lockAndHome[@"default"] = defaultLayer;
    assets[@"lockAndHome"] = lockAndHome;
    wallpaper[@"assets"] = assets;
    XCTAssertTrue([self writePlist:wallpaper toPath:wallpaperPath]);

    NSDictionary *result = [self install:input];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *uuid = [result[@"installedDescriptorIdentifiers"] firstObject];
    NSString *published = [descriptorRoot stringByAppendingPathComponent:uuid];
    NSString *rootID = [NSString stringWithContentsOfFile:[published stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
        encoding:NSUTF8StringEncoding error:nil];
    NSString *publishedWallpaper = [published stringByAppendingPathComponent:@"versions/1/contents/Fixture1.Custom.wallpaper/Wallpaper.plist"];
    NSDictionary *rewritten = [NSDictionary dictionaryWithContentsOfFile:publishedWallpaper];
    XCTAssertEqualObjects(rewritten[@"assets"][@"lockAndHome"][@"default"][@"identifier"], @(rootID.integerValue));
}

- (void)testOrderedDescriptorsReceiveDescendingIDsInStableNameOrder {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"One", @"Two"] missingFiles:[NSSet set]];
    NSString *regularGroup = [input stringByAppendingPathComponent:@"descriptors"];
    NSString *orderedGroup = [input stringByAppendingPathComponent:@"collection-ordered-descriptors"];
    NSError *moveError = nil;
    XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:regularGroup toPath:orderedGroup error:&moveError], @"%@", moveError);

    NSDictionary *result = [self install:input];
    NSArray<NSString *> *identifiers = result[@"installedDescriptorIdentifiers"];
    XCTAssertEqual(identifiers.count, 2u);
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSMutableArray<NSNumber *> *numericIDs = [NSMutableArray array];
    NSMutableArray<NSString *> *wallpaperNames = [NSMutableArray array];
    NSUInteger descriptorIndex = 0;
    for (NSString *uuid in identifiers) {
        descriptorIndex++;
        NSString *path = [descriptorRoot stringByAppendingPathComponent:uuid];
        NSString *text = [NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
            encoding:NSUTF8StringEncoding error:nil];
        [numericIDs addObject:@(text.integerValue)];
        NSString *wallpaperName = [NSString stringWithFormat:@"Fixture%lu.Custom.wallpaper", (unsigned long)descriptorIndex];
        NSString *wallpaperPath = [[path stringByAppendingPathComponent:@"versions/1/contents"] stringByAppendingPathComponent:wallpaperName];
        wallpaperPath = [wallpaperPath stringByAppendingPathComponent:@"Wallpaper.plist"];
        NSDictionary *wallpaper = [NSDictionary dictionaryWithContentsOfFile:wallpaperPath];
        [wallpaperNames addObject:wallpaper[@"name"] ?: @""];
    }
    XCTAssertEqualObjects(wallpaperNames, (@[@"One", @"Two"]));
    XCTAssertGreaterThan(numericIDs[0].longLongValue, numericIDs[1].longLongValue);
}

- (void)testInstallsMultipleDescriptorsWithUniqueUUIDsAndNumericIDs {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"One", @"Two"] missingFiles:[NSSet set]];
    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"installedDescriptorCount"], @2);
    NSArray *ids = result[@"installedDescriptorIdentifiers"];
    XCTAssertEqual(ids.count, 2u);
    XCTAssertNotEqualObjects(ids[0], ids[1]);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSMutableSet *numericIDs = [NSMutableSet set];
    for (NSString *uuid in ids) {
        NSString *root = [descriptorRoot stringByAppendingPathComponent:uuid];
        NSString *text = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"] encoding:NSUTF8StringEncoding error:nil];
        [numericIDs addObject:text ?: @""];
    }
    XCTAssertEqual(numericIDs.count, 2u);
}

- (void)testRejectsMissingWallpaperWithoutPublishingAnything {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Missing wallpaper"] missingFiles:[NSSet setWithObject:@"wallpaper-plist"]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertNotNil(error);
    NSArray *published = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:descriptorRoot error:nil] ?: @[];
    XCTAssertEqual(published.count, 0u);
}

- (void)testRejectsMissingProviderInfoWithoutPublishingAnything {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Missing provider info"] missingFiles:[NSSet setWithObject:@"provider-info"]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertNotNil(error);
    NSArray *published = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:descriptorRoot error:nil] ?: @[];
    XCTAssertEqual(published.count, 0u);
}

- (void)testRejectsSymlinkInDescriptorWithoutPublishingAnything {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Symlink fixture"] missingFiles:[NSSet set]];
    NSString *descriptor = [input stringByAppendingPathComponent:@"descriptors/fixture-1"];
    NSString *target = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [@"outside" writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *linkPath = [descriptor stringByAppendingPathComponent:@"escape.link"];
    XCTAssertEqual(symlink(target.fileSystemRepresentation, linkPath.fileSystemRepresentation), 0);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertNotNil(error);
    NSArray *published = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:descriptorRoot error:nil] ?: @[];
    XCTAssertEqual(published.count, 0u);
    [[NSFileManager defaultManager] removeItemAtPath:target error:nil];
}


- (void)testRejectsSymlinkInPosterBoardDestinationParent {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Destination symlink"] missingFiles:[NSSet set]];
    NSString *realParent = [self.temporaryRoot stringByAppendingPathComponent:@"real-store"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:realParent withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *linkParent = [self.temporaryRoot stringByAppendingPathComponent:@"store-link"];
    XCTAssertEqual(symlink(realParent.fileSystemRepresentation, linkParent.fileSystemRepresentation), 0);

    NSString *descriptorRoot = [linkParent stringByAppendingPathComponent:@"descriptors"];
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input descriptorRoot:descriptorRoot error:&error];
    XCTAssertNil(result);
    XCTAssertNotNil(error);
    NSArray *published = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:realParent error:nil] ?: @[];
    XCTAssertEqual(published.count, 0u);
}

- (void)testRejectsMultipleDescriptorGroupsInsteadOfMixingExtensions {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Collections"] missingFiles:[NSSet set]];
    NSString *other = [input stringByAppendingPathComponent:@"descriptor"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:other withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:[self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/descriptors"] error:&error];
    XCTAssertNil(result);
    XCTAssertNotNil(error);
}


- (void)testReadOnlyVerificationFindsPublishedDescriptorAndReportsMissingRecord {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Verification fixture"] missingFiles:[NSSet set]];
    NSString *container = [self.temporaryRoot stringByAppendingPathComponent:@"MockPosterBoardContainer"];
    NSString *descriptorRoot = [[container stringByAppendingPathComponent:@"Library/Application Support/PRBPosterExtensionDataStore/59/Extensions"]
        stringByAppendingPathComponent:@"com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *installed = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNotNil(installed, @"%@", error);
    NSString *uuid = [installed[@"installedDescriptorIdentifiers"] firstObject];

    NSDictionary *complete = [LBPosterBoardInstaller verifyRegisteredDescriptorIdentifiers:@[uuid]
        posterBoardContainer:container error:&error];
    XCTAssertNotNil(complete, @"%@", error);
    XCTAssertEqualObjects(complete[@"descriptorStoreState"], @"complete");
    XCTAssertEqualObjects(complete[@"verificationScope"], @"filesystem-registration-only");
    XCTAssertEqualObjects(complete[@"posterBoardApplicationState"], @"unverified");
    XCTAssertEqualObjects(complete[@"expectedDescriptorCount"], @1);
    XCTAssertEqualObjects(complete[@"presentDescriptorCount"], @1);
    XCTAssertEqualObjects(complete[@"missingDescriptorCount"], @0);
    XCTAssertEqualObjects(complete[@"invalidDescriptorCount"], @0);

    NSString *published = [descriptorRoot stringByAppendingPathComponent:uuid];
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:published error:&error], @"%@", error);
    NSDictionary *missing = [LBPosterBoardInstaller verifyRegisteredDescriptorIdentifiers:@[uuid]
        posterBoardContainer:container error:&error];
    XCTAssertNotNil(missing, @"%@", error);
    XCTAssertEqualObjects(missing[@"descriptorStoreState"], @"missing");
    XCTAssertEqualObjects(missing[@"presentDescriptorCount"], @0);
    XCTAssertEqualObjects(missing[@"missingDescriptorCount"], @1);
}

- (void)testPublishedDescriptorIdentifierConsistencyIsEnforced {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Identifier consistency"] missingFiles:[NSSet set]];
    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSError *error = nil;
    NSDictionary *result = [LBPosterBoardInstaller installExtractedDescriptorTreeAtPath:input
        descriptorRoot:descriptorRoot error:&error];
    XCTAssertNotNil(result, @"%@", error);
    XCTAssertNil(error);
    NSString *uuid = [result[@"installedDescriptorIdentifiers"] firstObject];
    NSString *published = [descriptorRoot stringByAppendingPathComponent:uuid];
    XCTAssertTrue([LBPosterBoardInstaller validatePublishedDescriptorIdentifiersAtPath:published error:&error], @"%@", error);
    XCTAssertNil(error);

    NSString *wallpaperPath = nil;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:published];
    NSString *relative = nil;
    while ((relative = enumerator.nextObject)) {
        if ([relative.lastPathComponent caseInsensitiveCompare:@"Wallpaper.plist"] == NSOrderedSame) {
            wallpaperPath = [published stringByAppendingPathComponent:relative];
            break;
        }
    }
    XCTAssertNotNil(wallpaperPath);
    NSMutableDictionary *wallpaper = [[NSDictionary dictionaryWithContentsOfFile:wallpaperPath] mutableCopy];
    NSMutableDictionary *assets = [wallpaper[@"assets"] mutableCopy];
    NSMutableDictionary *lockAndHome = [assets[@"lockAndHome"] mutableCopy];
    NSMutableDictionary *defaults = [lockAndHome[@"default"] mutableCopy];
    defaults[@"identifier"] = @54321;
    lockAndHome[@"default"] = defaults;
    assets[@"lockAndHome"] = lockAndHome;
    wallpaper[@"assets"] = assets;
    XCTAssertTrue([self writePlist:wallpaper toPath:wallpaperPath]);

    error = nil;
    XCTAssertFalse([LBPosterBoardInstaller validatePublishedDescriptorIdentifiersAtPath:published error:&error]);
    XCTAssertEqual(error.code, 68);
    XCTAssertTrue([error.localizedDescription containsString:@"identifier mismatch"]);
}

- (void)testDeviceFamilyPreflightAllowsIPadWallpaperOnIPhone13 {
    NSError *error = nil;
    BOOL compatible = [LBPosterBoardInstaller validateLogicalScreenClass:@"810w-1080h@2x~ipad"
        machineIdentifier:@"iPhone14,5" error:&error];
    XCTAssertTrue(compatible, @"%@", error);
    XCTAssertNil(error);
}

- (void)testDeviceFamilyPreflightAllowsIPadWallpaperOnIPhoneX {
    NSError *error = nil;
    BOOL compatible = [LBPosterBoardInstaller validateLogicalScreenClass:@"810w-1080h@2x~ipad"
        machineIdentifier:@"iPhone10,6" error:&error];
    XCTAssertTrue(compatible, @"%@", error);
    XCTAssertNil(error);
}

- (void)testDeviceFamilyPreflightAllowsIPhoneWallpaperOnIPad {
    NSError *error = nil;
    BOOL compatible = [LBPosterBoardInstaller validateLogicalScreenClass:@"375w-812h@3x~iphone"
        machineIdentifier:@"iPad7,5" error:&error];
    XCTAssertTrue(compatible, @"%@", error);
    XCTAssertNil(error);
}

- (void)testDeviceFamilyPreflightDoesNotGuessForUnknownHost {
    NSError *error = nil;
    BOOL compatible = [LBPosterBoardInstaller validateLogicalScreenClass:@"810w-1080h@2x~ipad"
        machineIdentifier:@"arm64" error:&error];
    XCTAssertTrue(compatible);
    XCTAssertNil(error);
}

- (void)testRefreshFlagsAreWrittenWithoutTerminatingSystemProcesses {
    NSString *container = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoardContainer"];
    NSString *preferencesDirectory = [container stringByAppendingPathComponent:@"Library/Preferences"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:preferencesDirectory
        withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *preferencesPath = [preferencesDirectory stringByAppendingPathComponent:@"com.apple.PosterBoard.unprotectedUserDefaults.plist"];
    NSDictionary *original = @{@"existingPreference":@"preserve-this-value", @"PBF_LOCALE_DID_CHANGE":@YES};
    XCTAssertTrue([self writePlist:original toPath:preferencesPath]);

    NSDictionary *result = [LBPosterBoardInstaller requestPosterBoardRefreshForContainer:container];
    XCTAssertEqualObjects(result[@"refreshPreferencesWritten"], @YES);
    XCTAssertEqualObjects(result[@"refreshCommandAttempted"], @NO);
    XCTAssertEqualObjects(result[@"posterBoardRefreshRequested"], @NO);
    XCTAssertEqualObjects(result[@"posterBoardRefreshRequiresDeviceRestart"], @YES);
    XCTAssertNotNil(result[@"refreshWarning"]);

    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:preferencesPath];
    XCTAssertEqualObjects(preferences[@"existingPreference"], @"preserve-this-value");
    XCTAssertEqualObjects(preferences[@"PBF_LOCALE_DID_CHANGE"], @NO);
    XCTAssertEqualObjects(preferences[@"PBF_RESET_FILE_PROTECTIONS"], @YES);
}

- (void)testRefreshDoesNotReplaceMalformedExistingPreferences {
    NSString *container = [self.temporaryRoot stringByAppendingPathComponent:@"MalformedPosterBoardContainer"];
    NSString *preferencesDirectory = [container stringByAppendingPathComponent:@"Library/Preferences"];
    NSError *error = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:preferencesDirectory
        withIntermediateDirectories:YES attributes:nil error:&error], @"%@", error);
    NSString *preferencesPath = [preferencesDirectory stringByAppendingPathComponent:@"com.apple.PosterBoard.unprotectedUserDefaults.plist"];
    NSData *original = [@"not a property list" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([original writeToFile:preferencesPath options:NSDataWritingAtomic error:&error], @"%@", error);

    NSDictionary *result = [LBPosterBoardInstaller requestPosterBoardRefreshForContainer:container];
    XCTAssertEqualObjects(result[@"refreshPreferencesWritten"], @NO);
    XCTAssertEqualObjects(result[@"refreshCommandAttempted"], @NO);
    XCTAssertEqualObjects(result[@"posterBoardRefreshRequested"], @NO);
    XCTAssertEqualObjects(result[@"posterBoardRefreshRequiresDeviceRestart"], @NO);
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:preferencesPath], original);
}

- (void)testInstallsDescriptorAndRegistersInSQLiteWhenDatabaseExists {
    NSString *storeRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59"];
    NSError *dirError = nil;
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:storeRoot withIntermediateDirectories:YES attributes:nil error:&dirError]);
    NSString *dbPath = [storeRoot stringByAppendingPathComponent:@"PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"];

    sqlite3 *db = NULL;
    XCTAssertEqual(sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL), SQLITE_OK);
    sqlite3_exec(db, "CREATE TABLE poster (UUID TEXT PRIMARY KEY, providerId TEXT);", NULL, NULL, NULL);
    sqlite3_exec(db, "CREATE TABLE posterRoleMembership (posterUUID TEXT, roleId TEXT, roleSortKey INTEGER, PRIMARY KEY (posterUUID, roleId));", NULL, NULL, NULL);
    sqlite3_exec(db, "INSERT INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES ('EXISTING-UUID', 'PRPosterRoleLockScreen', 10);", NULL, NULL, NULL);
    sqlite3_close(db);

    NSString *input = [self makeDescriptorGroupWithNames:@[@"SQLite test wallpaper"] missingFiles:[NSSet set]];
    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"installedDescriptorCount"], @1);
    XCTAssertEqualObjects(result[@"sqliteDatabaseUpdated"], @YES);
    XCTAssertEqualObjects(result[@"verificationScope"], @"filesystem-and-sqlite-registered");

    NSString *uuid = [result[@"installedDescriptorIdentifiers"] firstObject];
    XCTAssertNotNil(uuid);

    XCTAssertEqual(sqlite3_open_v2(dbPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL), SQLITE_OK);
    sqlite3_stmt *stmt = NULL;
    XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT roleSortKey FROM posterRoleMembership WHERE posterUUID = ? AND roleId = 'PRPosterRoleLockScreen';", -1, &stmt, NULL), SQLITE_OK);
    sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_STATIC);
    XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW);
    int sortKey = sqlite3_column_int(stmt, 0);
    XCTAssertEqual(sortKey, 11);
    sqlite3_finalize(stmt);

    XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT providerId FROM poster WHERE UUID = ?;", -1, &stmt, NULL), SQLITE_OK);
    sqlite3_bind_text(stmt, 1, uuid.UTF8String, -1, SQLITE_STATIC);
    XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW);
    const char *provider = (const char *)sqlite3_column_text(stmt, 0);
    XCTAssertEqualObjects([NSString stringWithUTF8String:provider], @"com.apple.WallpaperKit.CollectionsPoster");
    sqlite3_finalize(stmt);
    sqlite3_close(db);
}

- (void)testInstallsDescriptorWithOmittedAssetManifestInFloatingLayer {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Omitted manifest wallpaper"] missingFiles:[NSSet set]];
    NSString *floatingIndex = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Floating.ca/index.xml"];
    NSDictionary *floatingDict = @{
        @"rootDocument": @"main.caml",
        @"documentHeight": @1,
        @"documentWidth": @1
    };
    XCTAssertTrue([self writePlist:floatingDict toPath:floatingIndex]);
    NSString *manifestPath = [input stringByAppendingPathComponent:@"descriptors/fixture-1/versions/1/contents/Fixture1.Custom.wallpaper/PF_Floating.ca/assetManifest.caml"];
    [[NSFileManager defaultManager] removeItemAtPath:manifestPath error:nil];

    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"installedDescriptorCount"], @1);
}

- (void)testRewritesSuggestionMetadataIdentifierInSyncWithPublishedDescriptor {
    NSString *input = [self makeDescriptorGroupWithNames:@[@"Suggestion metadata wallpaper"] missingFiles:[NSSet set]];
    NSString *descRoot = [input stringByAppendingPathComponent:@"descriptors/fixture-1"];
    NSString *suggestionPath = [descRoot stringByAppendingPathComponent:@"com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist"];

    NSDictionary *fakeKeyedArchive = @{
        @"$archiver": @"NSKeyedArchiver",
        @"$version": @100000,
        @"$objects": @[
            @"$null",
            @"12345.DYNAMIC",
            @"com.apple.WallpaperKit.CollectionsPoster"
        ],
        @"$top": @{@"root": @1}
    };
    XCTAssertTrue([self writePlist:fakeKeyedArchive toPath:suggestionPath]);

    NSDictionary *result = [self install:input];
    XCTAssertEqualObjects(result[@"installedDescriptorCount"], @1);

    NSString *descriptorRoot = [self.temporaryRoot stringByAppendingPathComponent:@"PosterBoard/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors"];
    NSString *uuid = [result[@"installedDescriptorIdentifiers"] firstObject];
    NSString *published = [descriptorRoot stringByAppendingPathComponent:uuid];
    NSString *publishedID = [NSString stringWithContentsOfFile:[published stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
        encoding:NSUTF8StringEncoding error:nil];
    XCTAssertNotNil(publishedID);

    NSString *publishedSuggestion = [published stringByAppendingPathComponent:@"com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist"];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:publishedSuggestion]);
    NSData *publishedData = [NSData dataWithContentsOfFile:publishedSuggestion];
    NSString *expectedToken = [NSString stringWithFormat:@"%@.DYNAMIC", publishedID];
    XCTAssertTrue([publishedData rangeOfData:[expectedToken dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, publishedData.length)].location != NSNotFound);
}
@end

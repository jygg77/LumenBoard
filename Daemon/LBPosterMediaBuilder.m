#import "LBPosterMediaBuilder.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <stdlib.h>

static const uint64_t LBMaxCumulativeVideoAssetBytes = 80ULL * 1024ULL * 1024ULL;

static NSError *LBMediaError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.iuyghi.LumenBoard.MediaBuilder" code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Media wallpaper generation failed."}];
}

static BOOL LBMediaWritePlist(id object, NSString *path, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

static BOOL LBMediaWriteText(NSString *value, NSString *path, NSError **error) {
    return [value writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error];
}

static BOOL LBMediaEnsureDirectory(NSString *path, NSError **error) {
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error];
}

static UIImage *LBMediaBlurredImage(UIImage *image, NSError **error) {
    CIImage *input = [[CIImage alloc] initWithImage:image];
    if (!input) { if (error) *error = LBMediaError(10, @"Could not create a Core Image source."); return nil; }
    CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [filter setValue:input forKey:kCIInputImageKey];
    [filter setValue:@28.0 forKey:kCIInputRadiusKey];
    CIImage *output = filter.outputImage;
    CGRect extent = input.extent;
    output = [output imageByCroppingToRect:extent];
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cg = [context createCGImage:output fromRect:extent];
    if (!cg) { if (error) *error = LBMediaError(11, @"Core Image could not render the blurred background."); return nil; }
    UIImage *result = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(cg);
    return result;
}

static BOOL LBMediaWriteJPEG(UIImage *image, NSString *path, CGFloat quality, NSError **error) {
    NSData *data = UIImageJPEGRepresentation(image, quality);
    if (!data.length) { if (error) *error = LBMediaError(12, @"Could not encode a wallpaper frame as JPEG."); return NO; }
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

@implementation LBPosterMediaBuilder

+ (BOOL)writeIndexAt:(NSString *)directory width:(NSInteger)width height:(NSInteger)height
    documentResizesToView:(BOOL)resizesToView scalesToFitInPlayer:(BOOL)scalesToFitInPlayer error:(NSError **)error {
    // Match the iOS 16 PosterForge writer: index.xml is a binary plist, despite
    // its filename. Do not substitute the XML-plist format used by other CAML
    // generators; PosterBoard consumes this file as a property list.
    NSDictionary *index = @{
        @"assetManifest":@"assetManifest.caml",
        @"documentHeight":@(height),
        @"documentResizesToView":@(resizesToView),
        @"documentWidth":@(width),
        @"geometryFlipped":@NO,
        @"rootDocument":@"main.caml",
        @"scalesToFitInPlayer":@(scalesToFitInPlayer),
        @"unitsInPixelsInPlayer":@YES
    };
    return LBMediaWritePlist(index, [directory stringByAppendingPathComponent:@"index.xml"], error);
}

+ (BOOL)writeEmptyLayerAt:(NSString *)directory error:(NSError **)error {
    // The reference iOS 16 writer uses a neutral 1x1 empty Floating layer.
    NSString *caml = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\"><CALayer bounds=\"0 0 1 1\" hidden=\"0\" name=\"_FLOATING\" position=\"0.5 0.5\"><sublayers/></CALayer></caml>";
    return LBMediaWriteText(caml, [directory stringByAppendingPathComponent:@"main.caml"], error) &&
        [self writeIndexAt:directory width:1 height:1 documentResizesToView:YES scalesToFitInPlayer:YES error:error];
}

+ (BOOL)buildAnimationAt:(NSString *)directory source:(NSString *)source kind:(NSString *)kind
                 blurred:(BOOL)blurred outputWidth:(NSInteger *)outputWidth outputHeight:(NSInteger *)outputHeight
                   error:(NSError **)error {
    NSString *assets = [directory stringByAppendingPathComponent:@"assets"];
    if (!LBMediaEnsureDirectory(assets, error)) return NO;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSInteger width = 0, height = 0;
    double duration = 1.0;

    if ([kind isEqualToString:@"video"]) {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:source] options:nil];
        duration = CMTimeGetSeconds(asset.duration);
        if (!isfinite(duration) || duration <= 0.0) {
            if (error) *error = LBMediaError(20, @"The selected video has no readable duration.");
            return NO;
        }
        NSInteger fps = 15;
        NSInteger maxFrames = 400;
        NSInteger frames = duration >= ((double)maxFrames / (double)fps)
            ? maxFrames
            : MAX(1, (NSInteger)ceil(duration * (double)fps));
        duration = (double)frames / (double)fps;
        AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(1290, 2796);
        uint64_t cumulativeBytes = 0;
        for (NSInteger index = 0; index < frames; index++) @autoreleasepool {
            CMTime time = CMTimeMakeWithSeconds((double)index / (double)fps, 600);
            NSError *frameError = nil;
            CGImageRef cg = [generator copyCGImageAtTime:time actualTime:NULL error:&frameError];
            if (!cg) { if (error) *error = frameError ?: LBMediaError(21, @"Could not decode a video frame."); return NO; }
            UIImage *frame = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
            width = (NSInteger)CGImageGetWidth(frame.CGImage);
            height = (NSInteger)CGImageGetHeight(frame.CGImage);
            if (blurred) {
                UIImage *blurredFrame = LBMediaBlurredImage(frame, error);
                if (!blurredFrame) return NO;
                frame = blurredFrame;
            }
            NSString *name = [NSString stringWithFormat:@"%ld.jpg", (long)index];
            NSString *framePath = [assets stringByAppendingPathComponent:name];
            if (!LBMediaWriteJPEG(frame, framePath, 0.82, error)) return NO;
            struct stat frameStat;
            if (lstat(framePath.fileSystemRepresentation, &frameStat) == 0) {
                cumulativeBytes += (uint64_t)frameStat.st_size;
                if (cumulativeBytes > LBMaxCumulativeVideoAssetBytes) {
                    if (error) *error = LBMediaError(25, [NSString stringWithFormat:@"Cumulative video asset size exceeded %llu MiB safety budget.", LBMaxCumulativeVideoAssetBytes / (1024ULL * 1024ULL)]);
                    return NO;
                }
            }
            [names addObject:name];
        }
    } else if ([kind isEqualToString:@"image"]) {
        UIImage *image = [UIImage imageWithContentsOfFile:source];
        if (!image.CGImage) { if (error) *error = LBMediaError(22, @"The selected image cannot be decoded."); return NO; }
        width = (NSInteger)CGImageGetWidth(image.CGImage);
        height = (NSInteger)CGImageGetHeight(image.CGImage);
        if (blurred) {
            image = LBMediaBlurredImage(image, error);
            if (!image) return NO;
        }
        if (!LBMediaWriteJPEG(image, [assets stringByAppendingPathComponent:@"0.jpg"], 0.94, error)) return NO;
        [names addObject:@"0.jpg"];
    } else {
        if (error) *error = LBMediaError(23, @"Only image and video sources are supported.");
        return NO;
    }

    if (width <= 0 || height <= 0 || names.count == 0) {
        if (error) *error = LBMediaError(24, @"The generated wallpaper has no valid image dimensions or frames.");
        return NO;
    }
    if (outputWidth) *outputWidth = width;
    if (outputHeight) *outputHeight = height;

    NSMutableString *values = [NSMutableString string];
    for (NSString *name in names) [values appendFormat:@"<CGImage src=\"assets/%@\"/>", name];
    NSString *animation = names.count > 1 ?
        [NSString stringWithFormat:@"<animations><animation type=\"CAKeyframeAnimation\" calculationMode=\"linear\" keyPath=\"contents\" beginTime=\"1e-100\" duration=\"%.4f\" removedOnCompletion=\"0\" repeatCount=\"inf\"><values>%@</values></animation></animations>", duration, values] : @"";
    NSString *caml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\"><CALayer bounds=\"0 0 %ld %ld\" contentsFormat=\"RGBA8\" name=\"_BACKGROUND\" position=\"%g %g\"><sublayers><CALayer bounds=\"0 0 %ld %ld\" contentsFormat=\"RGBA8\" position=\"%g %g\"><contents type=\"CGImage\" src=\"assets/0.jpg\"/>%@</CALayer></sublayers><states><LKState name=\"Locked\"><elements/></LKState><LKState name=\"Unlock\"><elements/></LKState><LKState name=\"Sleep\"><elements/></LKState></states></CALayer></caml>",
        (long)width, (long)height, width/2.0, height/2.0,
        (long)width, (long)height, width/2.0, height/2.0, animation];
    return LBMediaWriteText(caml, [directory stringByAppendingPathComponent:@"main.caml"], error) &&
        [self writeIndexAt:directory width:width height:height documentResizesToView:YES scalesToFitInPlayer:YES error:error];
}

+ (NSString *)buildDescriptorForSource:(NSString *)sourcePath kind:(NSString *)kind title:(NSString *)title
                              homeBlur:(BOOL)homeBlur outputRoot:(NSString *)outputRoot error:(NSError **)error {
    struct stat sourceStat;
    if (lstat(sourcePath.fileSystemRepresentation, &sourceStat) != 0 ||
        !S_ISREG(sourceStat.st_mode) || S_ISLNK(sourceStat.st_mode) || sourceStat.st_size <= 0) {
        if (error) *error = LBMediaError(30, @"Media source is missing, empty, or not a regular file.");
        return nil;
    }
    if (![kind isEqualToString:@"image"] && ![kind isEqualToString:@"video"]) {
        if (error) *error = LBMediaError(31, @"Unsupported media kind.");
        return nil;
    }
    NSString *uuid = NSUUID.UUID.UUIDString.uppercaseString;
    NSString *descriptor = [outputRoot stringByAppendingPathComponent:@"descriptors"];
    NSString *descriptorPath = [descriptor stringByAppendingPathComponent:uuid];
    NSString *content = [descriptorPath stringByAppendingPathComponent:@"versions/1/contents"];
    NSString *wallpaperName = [NSString stringWithFormat:@"%@.Custom.wallpaper", uuid];
    NSString *wallpaper = [content stringByAppendingPathComponent:wallpaperName];
    NSString *background = [wallpaper stringByAppendingPathComponent:@"PF_Background.ca"];
    NSString *floating = [wallpaper stringByAppendingPathComponent:@"PF_Floating.ca"];

    for (NSString *directory in @[background, floating]) if (!LBMediaEnsureDirectory(directory, error)) {
        [[NSFileManager defaultManager] removeItemAtPath:descriptorPath error:nil];
        return nil;
    }

    NSInteger wallpaperID = 10000 + arc4random_uniform(89999);
    BOOL ok =
        LBMediaWriteText([NSString stringWithFormat:@"%ld", (long)wallpaperID],
            [descriptorPath stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"], error) &&
        LBMediaWriteText(@"PRPosterRoleLockScreen",
            [descriptorPath stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"], error);

    NSData *providerInfo = [NSKeyedArchiver archivedDataWithRootObject:@{@"kConfigurationLastUseDateKey":NSDate.date}
        requiringSecureCoding:NO error:error];
    if (ok) ok = providerInfo && [providerInfo writeToFile:[descriptorPath stringByAppendingPathComponent:@"providerInfo.plist"]
        options:NSDataWritingAtomic error:error];

    NSDictionary *userInfo = @{
        @"posterEnvironmentOverrides":[@"{}" dataUsingEncoding:NSUTF8StringEncoding],
        @"wallpaperRepresentingFileName":wallpaperName,
        @"wallpaperRepresentingIdentifier":[NSString stringWithFormat:@"%ld", (long)wallpaperID]
    };
    if (ok) ok = LBMediaWritePlist(userInfo,
        [content stringByAppendingPathComponent:@"com.apple.posterkit.provider.contents.userInfo"], error);

    NSString *safeTitle = title.length ? title : @"LumenBoard";
    NSDictionary *wallpaperPlist = @{
        @"appearanceAware":@YES,
        @"assets":@{@"lockAndHome":@{@"default":@{
            @"backgroundAnimationFileName":@"PF_Background.ca",
            @"floatingAnimationFileNameKey":@"PF_Floating.ca",
            @"identifier":@(wallpaperID),
            @"name":safeTitle,
            @"type":@"LayeredAnimation"
        }}},
        @"contentVersion":@2.01,
        @"family":@"Marble",
        @"identifier":@(wallpaperID),
        @"logicalScreenClass":@"375w-812h@3x~iphone",
        @"name":safeTitle,
        @"preferredProminentColor":@{@"dark":@"#000000", @"default":@"#FFFFFF"},
        @"version":@1
    };
    if (ok) ok = LBMediaWritePlist(wallpaperPlist, [wallpaper stringByAppendingPathComponent:@"Wallpaper.plist"], error);

    BOOL useHomeBlur = homeBlur && [kind isEqualToString:@"image"];
    NSInteger backgroundWidth = 0, backgroundHeight = 0;
    if (ok) ok = [self buildAnimationAt:background source:sourcePath
        kind:kind blurred:useHomeBlur outputWidth:&backgroundWidth outputHeight:&backgroundHeight error:error];
    if (ok && useHomeBlur) {
        ok = [self buildAnimationAt:floating source:sourcePath kind:@"image" blurred:NO
            outputWidth:NULL outputHeight:NULL error:error];
    } else if (ok) {
        ok = [self writeEmptyLayerAt:floating error:error];
    }

    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:descriptorPath error:nil];
        return nil;
    }
    return descriptorPath;
}
@end

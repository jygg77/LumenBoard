#import <Preferences/PSListController.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NS_ASSUME_NONNULL_BEGIN

@interface LumenBoardRootListController : PSListController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
- (nullable NSDictionary *)sendDaemonRequestWithAction:(NSString *)action payload:(nullable NSDictionary *)payload error:(NSError * _Nullable * _Nullable)error;
- (void)inspectPosterBoardWallpapersTapped;
@end

NS_ASSUME_NONNULL_END

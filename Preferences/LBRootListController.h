#import <Preferences/PSListController.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LumenBoardRootListController : PSListController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
- (nullable NSDictionary *)sendDaemonRequestWithAction:(NSString *)action payload:(nullable NSDictionary *)payload error:(NSError **)error;
- (void)inspectPosterBoardWallpapersTapped;
@end

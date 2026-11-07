#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class LumenBoardRootListController;

@interface LBPosterBoardWallpapersController : UITableViewController

@property (nonatomic, copy, nullable) NSString *containerPath;
@property (nonatomic, weak, nullable) id rootController;

- (instancetype)initWithWallpapers:(NSArray<NSDictionary *> *)wallpapers containerPath:(nullable NSString *)containerPath;

@end

NS_ASSUME_NONNULL_END

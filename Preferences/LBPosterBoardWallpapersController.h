#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class LBRootListController;

@interface LBPosterBoardWallpapersController : UITableViewController

@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic, weak) id rootController;

- (instancetype)initWithWallpapers:(NSArray<NSDictionary *> *)wallpapers containerPath:(NSString *)containerPath;

@end

NS_ASSUME_NONNULL_END

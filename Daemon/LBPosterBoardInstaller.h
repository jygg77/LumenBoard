#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LBPosterBoardInstaller : NSObject

/// Installs descriptor-format .tendies contents into the iOS 16 Collections
/// descriptor store for a known PosterBoard data-container path.
/// The caller must have read/write access to the PosterBoard container (the
/// production daemon runs as mobile in Dopamine's user/foreground domain).
/// Container-format archives are rejected.
+ (nullable NSDictionary *)installArchiveAtPath:(NSString *)archivePath
                          posterBoardContainer:(NSString *)containerPath
                                          error:(NSError * _Nullable * _Nullable)error;

/// Installs an already safely extracted descriptor tree into a supplied store.
/// This entry point is also used by the macOS XCTest suite.
+ (nullable NSDictionary *)installExtractedDescriptorTreeAtPath:(NSString *)extractedPath
                                                   descriptorRoot:(NSString *)descriptorRoot
                                                             error:(NSError * _Nullable * _Nullable)error;

/// Read-only verification of previously published descriptor UUIDs in the live
/// PosterBoard Collections store. This verifies filesystem registration only;
/// it cannot prove native gallery visibility or wallpaper application.
+ (nullable NSDictionary *)verifyRegisteredDescriptorIdentifiers:(NSArray<NSString *> *)identifiers
                                             posterBoardContainer:(NSString *)containerPath
                                                             error:(NSError * _Nullable * _Nullable)error;

/// Writes PosterBoard refresh flags without terminating or signalling system processes.
/// A device restart may be needed before PosterBoard reloads the published descriptors.
+ (NSDictionary *)requestPosterBoardRefreshForContainer:(NSString *)containerPath;

/// Resolves the PosterBoard app data container using its MCM metadata identifier.
+ (nullable NSString *)findPosterBoardContainer:(NSError * _Nullable * _Nullable)error;

/// Removes published descriptor directories from PosterBoard and triggers a refresh.
+ (BOOL)removeDescriptorIdentifiers:(NSArray<NSString *> *)identifiers
              posterBoardContainer:(NSString *)containerPath
                             error:(NSError * _Nullable * _Nullable)error;

/// Lists all active configurations (Lock Screen switcher) and gallery descriptors resident in PosterBoard.
+ (NSArray<NSDictionary *> *)listAllPosterBoardWallpapersForContainer:(NSString *)containerPath;

/// Deletes a specific wallpaper directory (configuration or descriptor) from PosterBoard and reloads.
+ (BOOL)deletePosterBoardWallpaperAtPath:(NSString *)path
                                container:(NSString *)containerPath
                                    error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

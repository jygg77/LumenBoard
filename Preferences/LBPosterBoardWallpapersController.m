#import "LBPosterBoardWallpapersController.h"
#import "LBRootListController.h"

@interface LBPosterBoardWallpapersController ()
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *configurations;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *descriptors;
@end

@implementation LBPosterBoardWallpapersController

- (instancetype)initWithWallpapers:(NSArray<NSDictionary *> *)wallpapers containerPath:(NSString *)containerPath {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _containerPath = [containerPath copy];
        [self categorizeWallpapers:wallpapers];
    }
    return self;
}

- (void)categorizeWallpapers:(NSArray<NSDictionary *> *)wallpapers {
    _configurations = [NSMutableArray array];
    _descriptors = [NSMutableArray array];
    for (NSDictionary *wp in wallpapers) {
        if ([wp[@"type"] isEqualToString:@"configuration"]) {
            [_configurations addObject:wp];
        } else {
            [_descriptors addObject:wp];
        }
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sfondi PosterBoard";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadWallpapers)];
}

- (void)reloadWallpapers {
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *completion = nil;
        if ([self.rootController respondsToSelector:@selector(sendDaemonRequestWithAction:payload:error:)]) {
            completion = [self.rootController sendDaemonRequestWithAction:@"list-posterboard-wallpapers" payload:nil error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadWallpapers)];
            if (completion && [completion[@"success"] boolValue]) {
                NSArray *list = completion[@"result"][@"wallpapers"] ?: @[];
                [self categorizeWallpapers:list];
                [self.tableView reloadData];
            } else {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Errore ricarica" message:error.localizedDescription ?: @"Impossibile ricaricare la lista." preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
        });
    });
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        return [NSString stringWithFormat:@"Sfondi Blocco Schermo Attivi (%lu)", (unsigned long)self.configurations.count];
    } else {
        return [NSString stringWithFormat:@"Galleria / Collezioni (%lu)", (unsigned long)self.descriptors.count];
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"Gli sfondi attivi sono le schermate di blocco configurate nello switcher di iOS. Eliminandone uno qui, sparira immediatamente dallo switcher.";
    } else {
        return @"I descrittori sono i blueprint registrati nella galleria 'Aggiungi sfondo' (Collezioni).";
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.configurations.count;
    return self.descriptors.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"PosterBoardWallpaperCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.detailTextLabel.numberOfLines = 2;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSDictionary *item = (indexPath.section == 0) ? self.configurations[indexPath.row] : self.descriptors[indexPath.row];
    cell.textLabel.text = item[@"name"];
    if (indexPath.section == 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • Versione %@\nUUID: %@", item[@"friendlyProvider"], item[@"storeVersion"], item[@"uuid"]];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • ID: %@ • Schermo: %@\nUUID: %@", item[@"friendlyProvider"], item[@"numericID"], item[@"screenClass"], item[@"uuid"]];
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = (indexPath.section == 0) ? self.configurations[indexPath.row] : self.descriptors[indexPath.row];

    NSString *msg = [NSString stringWithFormat:@"Tipo: %@\nProvider: %@\nUUID: %@\nSchermo: %@\n\nPercorso su disco:\n%@",
                     item[@"typeLabel"], item[@"friendlyProvider"], item[@"uuid"], item[@"screenClass"], item[@"path"]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"name"] message:msg preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Elimina da PosterBoard" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self confirmDeleteWallpaperItem:item atIndexPath:indexPath];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSDictionary *item = (indexPath.section == 0) ? self.configurations[indexPath.row] : self.descriptors[indexPath.row];
        [self confirmDeleteWallpaperItem:item atIndexPath:indexPath];
    }
}

- (void)confirmDeleteWallpaperItem:(NSDictionary *)item atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Conferma eliminazione"
                                                                     message:[NSString stringWithFormat:@"Sei sicuro di voler eliminare definitivamente '%@' da PosterBoard?\n\nQuesta operazione rimuovera i file e riavviera PosterBoard.", item[@"name"]]
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Elimina adesso" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self executeDeleteWallpaperItem:item atIndexPath:indexPath];
    }]];

    [confirm addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)executeDeleteWallpaperItem:(NSDictionary *)item atIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Eliminazione..." message:@"Eliminazione dallo store e riavvio di PosterBoard in corso..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSDictionary *completion = nil;
            if ([self.rootController respondsToSelector:@selector(sendDaemonRequestWithAction:payload:error:)]) {
                completion = [self.rootController sendDaemonRequestWithAction:@"delete-posterboard-wallpaper"
                                                                      payload:@{ @"path": item[@"path"] ?: @"" }
                                                                        error:&error];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress dismissViewControllerAnimated:YES completion:^{
                    if (completion && [completion[@"success"] boolValue]) {
                        if (indexPath.section == 0) {
                            [self.configurations removeObjectAtIndex:indexPath.row];
                        } else {
                            [self.descriptors removeObjectAtIndex:indexPath.row];
                        }
                        [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];

                        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Eliminato" message:[NSString stringWithFormat:@"'%@' e stato eliminato con successo dallo store di PosterBoard ed il processo e stato riavviato.", item[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
                        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:done animated:YES completion:nil];
                    } else {
                        NSString *err = completion[@"error"] ?: (error.localizedDescription ?: @"Eliminazione fallita.");
                        UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"Errore eliminazione" message:err preferredStyle:UIAlertControllerStyleAlert];
                        [fail addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:fail animated:YES completion:nil];
                    }
                }];
            });
        });
    }];
}

@end

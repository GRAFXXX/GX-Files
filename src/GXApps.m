// Экран «Приложения LiveContainer»
#import "GXCore.h"
#include <sys/stat.h>

@interface GXAppsVC () <UISearchResultsUpdating>
@end

@implementation GXAppsVC {
    NSArray<GXLCApp *> *_apps, *_shown;
    NSMutableDictionary<NSString *, NSNumber *> *_sizes;
    UISearchController *_search;
}

- (instancetype)init { return [super initWithStyle:UITableViewStylePlain]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Приложения");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = 70;
    _sizes = [NSMutableDictionary dictionary];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = GXL(@"Название или bundle ID");
    self.navigationItem.searchController = _search;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.navigationController setToolbarHidden:YES animated:a]; }

- (void)refresh {
    _apps = [GXLCApp allApps:YES];
    [self updateSearchResultsForSearchController:_search];
    [self.refreshControl endRefreshing];
    for (GXLCApp *a in _apps) {
        if (_sizes[a.bundlePath]) continue;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            unsigned long long t = 0;
            NSMutableArray *paths = [NSMutableArray arrayWithObject:a.bundlePath];
            for (NSDictionary *c in a.containers) [paths addObject:c[@"path"]];
            for (NSString *p in paths) {
                NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:p] includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
                for (NSURL *u in en) { NSNumber *s; [u getResourceValue:&s forKey:NSURLTotalFileAllocatedSizeKey error:nil]; t += s.unsignedLongLongValue; }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ self->_sizes[a.bundlePath] = @(t); [self.tableView reloadData]; });
        });
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    _shown = q.length ? [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(GXLCApp *a, id b) {
        return [a.name localizedCaseInsensitiveContainsString:q] || [a.bundleId localizedCaseInsensitiveContainsString:q];
    }]] : _apps;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _shown.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (!GXInLiveContainer()) return GXL(@"GX Files запущен не в LiveContainer — список пуст.");
    return [NSString stringWithFormat:GXL(@"Приложений: %lu. Нажмите на приложение для действий."), (unsigned long)_apps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"a"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
    GXLCApp *a = _shown[ip.row];
    c.accessibilityIdentifier = a.bundlePath;
    UIImage *cached = [GXIcons cachedForPath:a.bundlePath side:50];
    c.imageView.image = cached ?: GXSymbolTile(@"app.fill", UIColor.systemPurpleColor, 50);
    if (!cached) [GXIcons iconForPath:a.bundlePath kind:GXKindApp side:50 completion:^(UIImage *img) {
        if (img && [c.accessibilityIdentifier isEqualToString:a.bundlePath]) { c.imageView.image = img; [c setNeedsLayout]; }
    }];
    c.textLabel.text = a.name;
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    NSNumber *sz = _sizes[a.bundlePath];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@%@%@", a.bundleId, a.version.length ? a.version : @"—", sz ? [NSString stringWithFormat:@" · %@", GXHuman(sz.unsignedLongLongValue)] : @"", a.isShared ? GXL(@" · общий") : @""];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    GXLCApp *a = _shown[ip.row];
    UIAlertController *s = [UIAlertController alertControllerWithTitle:a.name message:a.bundleId preferredStyle:UIAlertControllerStyleActionSheet];
    [s addAction:[UIAlertAction actionWithTitle:GXL(@"Запустить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [a launch]; }]];
    [s addAction:[UIAlertAction actionWithTitle:GXL(@"Открыть бандл (.app)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:a.bundlePath] animated:YES]; }]];
    for (NSDictionary *c in a.containers) {
        [s addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:GXL(@"Данные: %@"), c[@"name"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [FM() createDirectoryAtPath:c[@"path"] withIntermediateDirectories:YES attributes:nil error:nil];
            [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:c[@"path"]] animated:YES]; }]];
    }
    NSString *docs = [a.containers.firstObject[@"path"] stringByAppendingPathComponent:@"Documents"];
    if (GXIsDir(docs)) [s addAction:[UIAlertAction actionWithTitle:GXL(@"Documents приложения") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:docs] animated:YES]; }]];
    [s addAction:[UIAlertAction actionWithTitle:GXL(@"Инструменты приложения") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController pushViewController:[[GXIpaToolsVC alloc] initWithPath:a.bundlePath] animated:YES]; }]];
    [s addAction:[UIAlertAction actionWithTitle:@"Info.plist" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [GXOpener open:[a.bundlePath stringByAppendingPathComponent:@"Info.plist"] from:self]; }]];
    NSString *exe = [NSDictionary dictionaryWithContentsOfFile:[a.bundlePath stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleExecutable"];
    if (exe) [s addAction:[UIAlertAction actionWithTitle:GXL(@"Сведения о бинарнике") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        GXPresentNav(self, [[GXReportVC alloc] initWithTitle:exe text:GXMachOReport([a.bundlePath stringByAppendingPathComponent:exe])], YES); }]];
    [s addAction:[UIAlertAction actionWithTitle:GXL(@"Копировать bundle ID") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { UIPasteboard.generalPasteboard.string = a.bundleId; }]];
    [s addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    s.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
    [self presentViewController:s animated:YES completion:nil];
}
@end

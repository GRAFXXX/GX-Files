// Браузер папки, глубокий поиск, анализ места
#import "GXCore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <sys/stat.h>

#pragma mark - Элемент

@interface GXItem : NSObject
@property (nonatomic, copy) NSString *name, *path;
@property (nonatomic, copy) NSString *extra;
@property (nonatomic) BOOL isDir, isLink, brokenLink;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong) NSDate *mdate;
@property (nonatomic) GXKind kind;
@end

@implementation GXItem
+ (instancetype)itemAtPath:(NSString *)path {
    GXItem *it = [GXItem new];
    it.path = path;
    it.name = path.lastPathComponent;
    struct stat ls, st;
    if (lstat(path.fileSystemRepresentation, &ls) != 0) return nil;
    it.isLink = S_ISLNK(ls.st_mode);
    struct stat *use = &ls;
    if (it.isLink) { if (stat(path.fileSystemRepresentation, &st) == 0) use = &st; else it.brokenLink = YES; }
    it.isDir = S_ISDIR(use->st_mode);
    it.size = (unsigned long long)use->st_size;
    it.mdate = [NSDate dateWithTimeIntervalSince1970:use->st_mtimespec.tv_sec];
    it.kind = GXKindForName(it.name, it.isDir);
    if (it.kind == GXKindApp) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
        it.extra = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
    } else if (it.isDir && it.name.length == 36 && [it.name characterAtIndex:8] == '-') {
        GXLCApp *owner = [GXLCApp appOwningDataFolder:path];
        NSDictionary *ci = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"LCContainerInfo.plist"]];
        NSString *cn = [ci[@"name"] isKindOfClass:NSString.class] ? ci[@"name"] : nil;
        if (owner) it.extra = cn && ![cn isEqualToString:owner.name] ? [NSString stringWithFormat:@"%@ (%@)", owner.name, cn] : owner.name;
        else it.extra = cn;
    }
    return it;
}
@end

#pragma mark - Буфер

static NSMutableArray<NSString *> *gxClip;
static BOOL gxClipCut;
NSArray<NSString *> *GXClipboardPaths(void) { return gxClip.copy ?: @[]; }

#pragma mark - Браузер

typedef NS_ENUM(NSInteger, GXSort) { GXSortName, GXSortDate, GXSortSize, GXSortType };

@interface GXBrowserVC () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@end

@implementation GXBrowserVC {
    NSArray<GXItem *> *_all, *_items;
    NSString *_error;
    UISearchController *_search;
    UILabel *_pathLabel;
    CGFloat _iconSide;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStylePlain])) _path = path.length ? path : @"/";
    if (!gxClip) gxClip = [NSMutableArray array];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [_path isEqualToString:@"/"] ? @"/" : _path.lastPathComponent;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(pullRefresh) forControlEvents:UIControlEventValueChanged];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = GXL(@"Фильтр в этой папке");
    self.navigationItem.searchController = _search;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 28)];
    _pathLabel = [[UILabel alloc] initWithFrame:CGRectInset(header.bounds, 16, 0)];
    _pathLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _pathLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _pathLabel.textColor = UIColor.secondaryLabelColor;
    _pathLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    _pathLabel.text = _path;
    _pathLabel.userInteractionEnabled = YES;
    [_pathLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(copyCurrentPath)]];
    [header addSubview:_pathLabel];
    self.tableView.tableHeaderView = header;
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(dismissSelf)];
    [self buildNavItems];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [GXArcModel commitAllFrom:self]; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _iconSide = GXBigIcons() ? 52 : 38;
    self.tableView.rowHeight = GXBigIcons() ? 72 : 58;
    [self.navigationController setToolbarHidden:NO animated:animated];
    [self reload];
}

- (void)copyCurrentPath {
    UIPasteboard.generalPasteboard.string = _path;
    GXToast(self.view, GXL(@"Путь скопирован"));
}

#pragma mark Меню

- (void)buildNavItems {
    __weak typeof(self) ws = self;
    UIMenu *addMenu = [UIMenu menuWithTitle:@"" children:@[
        [UIAction actionWithTitle:GXL(@"Новая папка") image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws promptNew:YES]; }],
        [UIAction actionWithTitle:GXL(@"Новый файл") image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws promptNew:NO]; }],
        [UIAction actionWithTitle:GXL(@"Импорт из «Файлов»") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) { [ws importFiles]; }],
        [UIAction actionWithTitle:GXL(@"Из буфера обмена") image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *a) { [ws fromPasteboard]; }],
        [UIAction actionWithTitle:GXL(@"Скачать по ссылке") image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(UIAction *a) { [ws downloadURL]; }],
        [UIAction actionWithTitle:GXL(@"Символическая ссылка") image:[UIImage systemImageNamed:@"link.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws newSymlink]; }],
    ]];
    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle"] menu:addMenu];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self moreMenu]];
    self.navigationItem.rightBarButtonItems = @[more, add];
}

- (UIMenu *)moreMenu {
    __weak typeof(self) ws = self;
    GXSort cur = [GXDefaults() integerForKey:@"gxSort"];
    BOOL desc = [GXDefaults() boolForKey:@"gxSortDesc"];
    NSArray *names = @[GXL(@"Имя"), GXL(@"Дата"), GXL(@"Размер"), GXL(@"Тип")];
    NSMutableArray *sortActs = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        UIAction *a = [UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(UIAction *x) {
            if (cur == i) [GXDefaults() setBool:!desc forKey:@"gxSortDesc"];
            else { [GXDefaults() setInteger:i forKey:@"gxSort"]; [GXDefaults() setBool:(i == GXSortDate || i == GXSortSize) forKey:@"gxSortDesc"]; }
            [ws refreshAll];
        }];
        if (cur == i) { a.state = UIMenuElementStateOn; a.image = [UIImage systemImageNamed:desc ? @"chevron.down" : @"chevron.up"]; }
        [sortActs addObject:a];
    }
    UIMenu *sortMenu = [UIMenu menuWithTitle:GXL(@"Сортировка") image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil options:0 children:sortActs];
    UIAction *hidden = [UIAction actionWithTitle:GXL(@"Скрытые файлы") image:[UIImage systemImageNamed:@"eye"] identifier:nil handler:^(UIAction *x) {
        [GXDefaults() setBool:!GXShowHidden() forKey:@"gxShowHidden"]; [ws refreshAll]; }];
    hidden.state = GXShowHidden() ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *big = [UIAction actionWithTitle:GXL(@"Крупные значки") image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction *x) {
        [GXDefaults() setBool:!GXBigIcons() forKey:@"gxBigIcons"]; [ws viewWillAppear:NO]; [ws refreshAll]; }];
    big.state = GXBigIcons() ? UIMenuElementStateOn : UIMenuElementStateOff;
    NSString *p = _path;
    BOOL isFav = [GXFavorites() containsObject:p];
    UIAction *fav = [UIAction actionWithTitle:isFav ? GXL(@"Убрать из избранного") : GXL(@"В избранное") image:[UIImage systemImageNamed:isFav ? @"star.slash" : @"star"] identifier:nil handler:^(UIAction *x) {
        NSMutableArray *f = GXFavorites().mutableCopy;
        if ([f containsObject:p]) [f removeObject:p]; else [f addObject:p];
        GXSetFavorites(f);
        [ws refreshAll];
    }];
    UIMenu *view = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[sortMenu, hidden, big]];
    UIMenu *tools = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:GXL(@"Выбрать") image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *x) { [ws setEditing:YES animated:YES]; }],
        [UIAction actionWithTitle:GXL(@"Найти и заменить текст во всей папке") image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil handler:^(UIAction *x) {
            [ws.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:p] animated:YES]; }],
        [UIAction actionWithTitle:GXL(@"Поиск файлов по имени") image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *x) {
            [ws.navigationController pushViewController:[[GXSearchVC alloc] initWithRoot:p] animated:YES]; }],
        [UIAction actionWithTitle:GXL(@"Найти дубликаты") image:[UIImage systemImageNamed:@"square.on.square"] identifier:nil handler:^(UIAction *x) {
            [ws.navigationController pushViewController:[[GXDupVC alloc] initWithRoot:p] animated:YES]; }],
        [UIAction actionWithTitle:GXL(@"Анализ места") image:[UIImage systemImageNamed:@"chart.pie"] identifier:nil handler:^(UIAction *x) {
            [ws.navigationController pushViewController:[[GXUsageVC alloc] initWithPath:p] animated:YES]; }],
        [UIAction actionWithTitle:GXL(@"Wi‑Fi передача этой папки") image:[UIImage systemImageNamed:@"wifi"] identifier:nil handler:^(UIAction *x) {
            [ws.navigationController pushViewController:[[GXServerVC alloc] initWithRoot:p] animated:YES]; }],
    ]];
    UIMenu *misc = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
        [UIAction actionWithTitle:GXL(@"Перейти по пути…") image:[UIImage systemImageNamed:@"arrow.right.circle"] identifier:nil handler:^(UIAction *x) { [ws promptGoto]; }],
        [UIAction actionWithTitle:GXL(@"Копировать путь папки") image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *x) { [ws copyCurrentPath]; }],
        fav,
        [UIAction actionWithTitle:GXL(@"Свойства папки") image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *x) { [ws showInfo:p]; }],
    ]];
    return [UIMenu menuWithTitle:@"" children:@[view, tools, misc]];
}

- (void)refreshAll { [self buildNavItems]; [self reload]; }

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    if (editing) self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(endSelect)],
                                                             [[UIBarButtonItem alloc] initWithTitle:GXL(@"Все") style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)]];
    else [self buildNavItems];
    [self updateToolbar];
}
- (void)endSelect { [self setEditing:NO animated:YES]; }
- (void)selectAll {
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++)
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateToolbar];
}

#pragma mark Панель

- (NSArray<NSString *> *)selectedPaths {
    NSMutableArray *r = [NSMutableArray array];
    for (NSIndexPath *ip in self.tableView.indexPathsForSelectedRows) if (ip.row < (NSInteger)_items.count) [r addObject:_items[ip.row].path];
    return r;
}

- (void)updateToolbar {
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    if (self.editing) {
        BOOL any = self.tableView.indexPathsForSelectedRows.count > 0;
        __weak typeof(self) ws = self;
        UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(tbCopy)];
        UIBarButtonItem *cut = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"scissors"] style:UIBarButtonItemStylePlain target:self action:@selector(tbCut)];
        UIBarButtonItem *zip = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.zipper"] menu:[UIMenu menuWithTitle:GXL(@"Сжать") children:@[
            [UIAction actionWithTitle:@"ZIP" image:nil identifier:nil handler:^(UIAction *a) { [ws compress:[ws selectedPaths] format:@"zip"]; }],
            [UIAction actionWithTitle:@"TAR.GZ" image:nil identifier:nil handler:^(UIAction *a) { [ws compress:[ws selectedPaths] format:@"tar.gz"]; }],
            [UIAction actionWithTitle:@"TAR.XZ" image:nil identifier:nil handler:^(UIAction *a) { [ws compress:[ws selectedPaths] format:@"tar.xz"]; }],
            [UIAction actionWithTitle:@"7Z" image:nil identifier:nil handler:^(UIAction *a) { [ws compress:[ws selectedPaths] format:@"7z"]; }]]]];
        UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"] style:UIBarButtonItemStylePlain target:self action:@selector(tbShare:)];
        UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"] style:UIBarButtonItemStylePlain target:self action:@selector(tbDelete)];
        del.tintColor = UIColor.systemRedColor;
        NSMutableArray *moreActs = [NSMutableArray arrayWithArray:@[
            [UIAction actionWithTitle:GXL(@"Переименовать пакетно…") image:[UIImage systemImageNamed:@"character.cursor.ibeam"] identifier:nil handler:^(UIAction *a) {
                NSArray *sel = [ws selectedPaths]; [ws setEditing:NO animated:YES];
                if (sel.count) [ws.navigationController pushViewController:[[GXRenameVC alloc] initWithPaths:sel] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Сравнить (2 файла)") image:[UIImage systemImageNamed:@"arrow.left.arrow.right"] identifier:nil handler:^(UIAction *a) {
                NSArray *sel = [ws selectedPaths];
                if (sel.count != 2) { GXToast(ws.view, GXL(@"Отметьте ровно два файла")); return; }
                [ws setEditing:NO animated:YES];
                [ws.navigationController pushViewController:[[GXDiffVC alloc] initWithLeft:sel[0] right:sel[1]] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Найти и заменить в отмеченных папках/архивах") image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil handler:^(UIAction *a) {
                NSArray *sel = [ws selectedPaths];
                if (sel.count != 1) { GXToast(ws.view, GXL(@"Отметьте одну папку или архив")); return; }
                [ws setEditing:NO animated:YES];
                [ws.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:sel[0]] animated:YES]; }]]];
        if (GXPanelsVC.shared) {
            [moreActs addObject:[UIAction actionWithTitle:GXL(@"Копировать в другую панель") image:[UIImage systemImageNamed:@"rectangle.righthalf.inset.filled.arrow.right"] identifier:nil handler:^(UIAction *a) { [ws toOtherPanel:[ws selectedPaths] move:NO]; }]];
            [moreActs addObject:[UIAction actionWithTitle:GXL(@"Переместить в другую панель") image:[UIImage systemImageNamed:@"arrow.right.square"] identifier:nil handler:^(UIAction *a) { [ws toOtherPanel:[ws selectedPaths] move:YES]; }]];
        }
        UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"" children:moreActs]];
        for (UIBarButtonItem *b in @[copy, cut, zip, share, del, more]) b.enabled = any;
        self.toolbarItems = @[copy, flex, cut, flex, zip, flex, share, flex, more, flex, del];
        return;
    }
    UIBarButtonItem *home = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"house"] style:UIBarButtonItemStylePlain target:self action:@selector(goHome)];
    UIBarButtonItem *up = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(goUp)];
    UILabel *count = [UILabel new];
    count.font = [UIFont systemFontOfSize:12];
    count.textColor = UIColor.secondaryLabelColor;
    count.text = _error ? GXL(@"Нет доступа") : [NSString stringWithFormat:GXL(@"Объектов: %lu"), (unsigned long)_all.count];
    [count sizeToFit];
    UIBarButtonItem *countItem = [[UIBarButtonItem alloc] initWithCustomView:count];
    if (gxClip.count) {
        __weak typeof(self) ws = self;
        UIBarButtonItem *paste = [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%lu)", gxClipCut ? GXL(@"Переместить") : GXL(@"Вставить"), (unsigned long)gxClip.count]
                                                                  style:UIBarButtonItemStyleDone target:self action:@selector(paste)];
        UIBarButtonItem *pasteMenu = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.up.circle"] menu:[UIMenu menuWithTitle:@"" children:@[
            [UIAction actionWithTitle:GXL(@"Вставить как символические ссылки") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) { [ws pasteLinks]; }],
            [UIAction actionWithTitle:GXL(@"Очистить буфер") image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(UIAction *a) { [ws clearClip]; }]]]];
        self.toolbarItems = @[home, flex, pasteMenu, paste];
        return;
    }
    NSMutableArray *items = [NSMutableArray arrayWithObjects:home, up, flex, countItem, flex, nil];
    if (GXPanelsVC.shared) {
        UIBarButtonItem *sw = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:GXPanelsVC.shared.current ? @"2.square.fill" : @"1.square.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(switchPanel)];
        [items addObject:sw];
    }
    self.toolbarItems = items;
}

- (void)switchPanel { [GXPanelsVC.shared switchPanel]; }

- (void)toOtherPanel:(NSArray<NSString *> *)paths move:(BOOL)move {
    NSString *dst = GXPanelsVC.shared.otherPanelPath;
    if (!dst) { GXAlert(self, GXL(@"Другая панель"), GXL(@"Во второй панели не открыта папка. Переключитесь (кнопка 1/2 внизу) и откройте нужную папку.")); return; }
    if (!paths.count) return;
    [self setEditing:NO animated:YES];
    GXConfirm(self, move ? GXL(@"Переместить?") : GXL(@"Копировать?"), [NSString stringWithFormat:GXL(@"%lu объектов → %@"), (unsigned long)paths.count, dst], move ? GXL(@"Переместить") : GXL(@"Копировать"), NO, ^{
        [self runOp:move ? GXL(@"Перемещение…") : GXL(@"Копирование…") work:^NSString *{
            NSMutableString *errs = [NSMutableString string];
            for (NSString *src in paths) {
                if ([dst isEqualToString:src] || [dst hasPrefix:[src stringByAppendingString:@"/"]]) { [errs appendFormat:GXL(@"«%@»: нельзя в саму себя\n"), src.lastPathComponent]; continue; }
                NSString *to = GXUniquePath(dst, src.lastPathComponent);
                NSError *e;
                if (!(move ? [FM() moveItemAtPath:src toPath:to error:&e] : [FM() copyItemAtPath:src toPath:to error:&e])) [errs appendFormat:@"«%@»: %@\n", src.lastPathComponent, e.localizedDescription];
            }
            return errs;
        }];
    });
}

- (void)signAPK:(NSString *)p {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Подписать APK") message:GXL(@"Подпись v1 + v2 ключом GX Files") preferredStyle:UIAlertControllerStyleActionSheet];
    void (^run)(NSString *) = ^(NSString *out) {
        GXRunBG(self, GXL(@"Подписываю…"), ^NSString *{ return GXSignAPK(p, out, ^(double x) { [GXHUD setProgress:x]; }); },
                ^{ [self reload]; GXToast(self.view, [NSString stringWithFormat:GXL(@"Подписано: %@"), out.lastPathComponent]); [GXArcModel modelFor:out].modifiedSinceSign = NO; });
    };
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Подписать этот файл") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { run(p); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"В копию _signed.apk") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        run(GXUniquePath(p.stringByDeletingLastPathComponent, [p.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@"_signed.apk"])); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)buildFromFolder:(NSString *)folder apk:(BOOL)apk {
    NSString *dest = GXUniquePath(folder.stringByDeletingLastPathComponent, [folder.lastPathComponent stringByAppendingPathExtension:apk ? @"apk" : @"zip"]);
    GXRunBG(self, apk ? GXL(@"Собираю APK…") : GXL(@"Собираю ZIP…"), ^NSString *{
        NSString *e = GXZipCreateFromFolder(folder, dest, apk);
        if (!e && apk) e = GXSignAPK(dest, dest, nil);
        return e;
    }, ^{ [self reload]; GXToast(self.view, [NSString stringWithFormat:GXL(@"Готово: %@%@"), dest.lastPathComponent, apk ? GXL(@" (выровнен и подписан)") : @""]); });
}

- (void)goHome { [self.navigationController popToRootViewControllerAnimated:YES]; }
- (void)goUp {
    if ([_path isEqualToString:@"/"]) return;
    NSString *parent = _path.stringByDeletingLastPathComponent;
    NSArray *vcs = self.navigationController.viewControllers;
    NSUInteger i = [vcs indexOfObject:self];
    if (i > 0 && [vcs[i - 1] isKindOfClass:GXBrowserVC.class] && [((GXBrowserVC *)vcs[i - 1]).path isEqualToString:parent]) { [self.navigationController popViewControllerAnimated:YES]; return; }
    [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:parent] animated:YES];
}
- (void)clearClip { [gxClip removeAllObjects]; [self updateToolbar]; }
- (void)tbCopy { [self setClip:[self selectedPaths] cut:NO]; [self setEditing:NO animated:YES]; }
- (void)tbCut { [self setClip:[self selectedPaths] cut:YES]; [self setEditing:NO animated:YES]; }
- (void)tbShare:(UIBarButtonItem *)sender { [self share:[self selectedPaths] from:nil bar:sender]; }
- (void)tbDelete { [self confirmDelete:[self selectedPaths]]; }
- (void)tableView:(UITableView *)tv didDeselectRowAtIndexPath:(NSIndexPath *)ip { if (self.editing) [self updateToolbar]; }

#pragma mark Загрузка

- (void)pullRefresh { [self reload]; [self.refreshControl endRefreshing]; }

- (void)reload {
    NSError *err;
    NSArray *names = [FM() contentsOfDirectoryAtPath:_path error:&err];
    _error = nil;
    if (!names) {
        _error = err.localizedDescription ?: GXL(@"Нет доступа");
        _all = @[];
    } else {
        BOOL hidden = GXShowHidden();
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *n in names) {
            if (!hidden && [n hasPrefix:@"."]) continue;
            GXItem *it = [GXItem itemAtPath:[_path stringByAppendingPathComponent:n]];
            if (it) [arr addObject:it];
        }
        GXSort sort = [GXDefaults() integerForKey:@"gxSort"];
        BOOL desc = [GXDefaults() boolForKey:@"gxSortDesc"];
        [arr sortUsingComparator:^NSComparisonResult(GXItem *a, GXItem *b) {
            if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
            NSComparisonResult r = NSOrderedSame;
            switch (sort) {
                case GXSortDate: r = [a.mdate compare:b.mdate]; break;
                case GXSortSize: r = a.size < b.size ? NSOrderedAscending : a.size > b.size ? NSOrderedDescending : NSOrderedSame; break;
                case GXSortType: r = [a.name.pathExtension caseInsensitiveCompare:b.name.pathExtension]; break;
                default: r = [(a.extra ?: a.name) localizedStandardCompare:(b.extra ?: b.name)]; break;
            }
            if (r == NSOrderedSame) r = [a.name localizedStandardCompare:b.name];
            if (desc) r = -r;
            return r;
        }];
        _all = arr;
    }
    [self applyFilter];
}

- (void)applyFilter {
    NSString *q = _search.searchBar.text;
    if (q.length) _items = [_all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(GXItem *it, NSDictionary *b) {
        return [it.name localizedCaseInsensitiveContainsString:q] || (it.extra && [it.extra localizedCaseInsensitiveContainsString:q]);
    }]];
    else _items = _all;
    [self.tableView reloadData];
    [self updateToolbar];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self applyFilter]; }

#pragma mark Таблица

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (_error) return [NSString stringWithFormat:GXL(@"Не удалось открыть папку: %@"), _error];
    if (!_all.count) return GXL(@"Папка пуста");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    GXItem *it = _items[ip.row];
    c.accessibilityIdentifier = it.path;
    UIImage *cached = [GXIcons cachedForPath:it.path side:_iconSide];
    UIImage *placeholder = it.brokenLink ? GXSymbolTile(@"link.badge.plus", UIColor.systemRedColor, _iconSide) : GXSymbolTile(GXSymbolForKind(it.kind), GXColorForKind(it.kind), _iconSide);
    c.imageView.image = cached ?: placeholder;
    BOOL wantIcon = it.kind == GXKindApp || it.kind == GXKindAndroid || it.kind == GXKindIPA || it.kind == GXKindImage || it.kind == GXKindVideo ||
                    it.kind == GXKindPDF || it.kind == GXKindFont || (it.isDir && it.extra);
    if (!cached && wantIcon && !it.brokenLink) {
        NSString *p = it.path;
        [GXIcons iconForPath:p kind:it.kind side:_iconSide completion:^(UIImage *img) {
            if (img && [c.accessibilityIdentifier isEqualToString:p]) { c.imageView.image = img; [c setNeedsLayout]; }
        }];
    }
    c.textLabel.text = it.extra ? [NSString stringWithFormat:@"%@  ·  %@", it.extra, it.name] : it.name;
    c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    c.textLabel.font = [UIFont systemFontOfSize:16];
    NSString *date = it.mdate ? [GXDateFmt() stringFromDate:it.mdate] : @"";
    NSString *link = it.isLink ? @"↪︎ " : @"";
    c.detailTextLabel.text = it.isDir ? [NSString stringWithFormat:@"%@%@", link, date] : [NSString stringWithFormat:@"%@%@ · %@", link, GXHuman(it.size), date];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = it.isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editing) { [self updateToolbar]; return; }
    [tv deselectRowAtIndexPath:ip animated:YES];
    GXItem *it = _items[ip.row];
    if (it.isDir) { [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:it.path] animated:YES]; return; }
    [GXOpener open:it.path from:self];
}

#pragma mark Контекстное меню

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    if (self.editing) return nil;
    GXItem *it = _items[ip.row];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *open = [NSMutableArray array];
        [open addObject:[UIAction actionWithTitle:GXL(@"Открыть") image:[UIImage systemImageNamed:@"arrow.up.forward.app"] identifier:nil handler:^(UIAction *a) {
            if (it.isDir) [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:it.path] animated:YES];
            else [GXOpener open:it.path from:ws];
        }]];
        if (!it.isDir) [open addObject:[UIAction actionWithTitle:GXL(@"Открыть с помощью…") image:[UIImage systemImageNamed:@"square.grid.3x3"] identifier:nil handler:^(UIAction *a) {
            [GXOpener openWithMenu:it.path from:ws sourceView:[ws.tableView cellForRowAtIndexPath:ip]];
        }]];
        if (it.kind == GXKindApp) {
            GXLCApp *app = [GXLCApp appForBundlePath:it.path];
            if (app) {
                [open addObject:[UIAction actionWithTitle:GXL(@"Запустить в LiveContainer") image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *a) { [app launch]; }]];
                for (NSDictionary *c in app.containers) {
                    [open addObject:[UIAction actionWithTitle:[NSString stringWithFormat:GXL(@"Данные: %@"), c[@"name"]] image:[UIImage systemImageNamed:@"externaldrive"] identifier:nil handler:^(UIAction *a) {
                        [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:c[@"path"]] animated:YES];
                    }]];
                }
            }
        }
        if (it.isDir && it.extra) {
            GXLCApp *owner = [GXLCApp appOwningDataFolder:it.path];
            if (owner) [open addObject:[UIAction actionWithTitle:[NSString stringWithFormat:GXL(@"Бандл «%@»"), owner.name] image:[UIImage systemImageNamed:@"shippingbox"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:owner.bundlePath] animated:YES];
            }]];
        }
        NSMutableArray *edit = [NSMutableArray arrayWithArray:@[
            [UIAction actionWithTitle:GXL(@"Переименовать") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a) { [ws promptRename:it]; }],
            [UIAction actionWithTitle:GXL(@"Копировать") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) { [ws setClip:@[it.path] cut:NO]; }],
            [UIAction actionWithTitle:GXL(@"Вырезать") image:[UIImage systemImageNamed:@"scissors"] identifier:nil handler:^(UIAction *a) { [ws setClip:@[it.path] cut:YES]; }],
            [UIAction actionWithTitle:GXL(@"Дублировать") image:[UIImage systemImageNamed:@"plus.square.on.square"] identifier:nil handler:^(UIAction *a) { [ws gxDuplicate:it]; }],
            [UIAction actionWithTitle:GXL(@"Сжать в ZIP") image:[UIImage systemImageNamed:@"doc.zipper"] identifier:nil handler:^(UIAction *a) { [ws compress:@[it.path] format:@"zip"]; }],
        ]];
        if (!it.isDir && GXIsArchive(it.path)) [edit addObject:[UIAction actionWithTitle:GXL(@"Распаковать сюда") image:[UIImage systemImageNamed:@"arrow.down.doc"] identifier:nil handler:^(UIAction *a) { [ws extract:it]; }]];
        NSMutableArray *mt = [NSMutableArray array];
        if (!it.isDir && GXIsZipFamily(it.path)) {
            [mt addObject:[UIAction actionWithTitle:GXL(@"Редактировать без распаковки") image:[UIImage systemImageNamed:@"square.and.pencil"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXArchiveVC alloc] initWithArchive:it.path] animated:YES]; }]];
            [mt addObject:[UIAction actionWithTitle:GXL(@"Найти и заменить внутри") image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:it.path] animated:YES]; }]];
        }
        if ((!it.isDir && GXKindForName(it.name, NO) == GXKindIPA) || it.kind == GXKindApp)
            [mt addObject:[UIAction actionWithTitle:GXL(@"Инструменты приложения") image:[UIImage systemImageNamed:@"hammer.circle"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXIpaToolsVC alloc] initWithPath:it.path] animated:YES]; }]];
        if (!it.isDir) {
            [mt addObject:[UIAction actionWithTitle:GXL(@"В текстовом редакторе") image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil handler:^(UIAction *a) { [GXOpener openText:it.path from:ws readOnly:NO]; }]];
            [mt addObject:[UIAction actionWithTitle:GXL(@"В hex-редакторе") image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(UIAction *a) { [GXOpener openHex:it.path from:ws readOnly:NO]; }]];
        }
        if (it.isDir) [mt addObject:[UIAction actionWithTitle:GXL(@"Найти дубликаты") image:[UIImage systemImageNamed:@"square.on.square"] identifier:nil handler:^(UIAction *a) {
            [ws.navigationController pushViewController:[[GXDupVC alloc] initWithRoot:it.path] animated:YES]; }]];
        if (!it.isDir && GXIsAPKPath(it.path)) [mt addObject:[UIAction actionWithTitle:GXL(@"Подписать APK") image:[UIImage systemImageNamed:@"signature"] identifier:nil handler:^(UIAction *a) { [ws signAPK:it.path]; }]];
        if (it.isDir) {
            [mt addObject:[UIAction actionWithTitle:GXL(@"Найти и заменить в папке") image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:it.path] animated:YES]; }]];
            [mt addObject:[UIMenu menuWithTitle:GXL(@"Собрать из папки") image:[UIImage systemImageNamed:@"hammer"] identifier:nil options:0 children:@[
                [UIAction actionWithTitle:GXL(@"APK (выровнять и подписать)") image:nil identifier:nil handler:^(UIAction *a) { [ws buildFromFolder:it.path apk:YES]; }],
                [UIAction actionWithTitle:GXL(@"ZIP / IPA (без папки-корня)") image:nil identifier:nil handler:^(UIAction *a) { [ws buildFromFolder:it.path apk:NO]; }]]]];
        } else {
            NSString *cand = GXCompareCandidate();
            if (cand && ![cand isEqualToString:it.path] && [FM() fileExistsAtPath:cand])
                [mt addObject:[UIAction actionWithTitle:[NSString stringWithFormat:GXL(@"Сравнить с «%@»"), cand.lastPathComponent] image:[UIImage systemImageNamed:@"arrow.left.arrow.right"] identifier:nil handler:^(UIAction *a) {
                    GXSetCompareCandidate(nil);
                    [ws.navigationController pushViewController:[[GXDiffVC alloc] initWithLeft:cand right:it.path] animated:YES]; }]];
            [mt addObject:[UIAction actionWithTitle:GXL(@"Выбрать для сравнения") image:[UIImage systemImageNamed:@"arrow.left.arrow.right.square"] identifier:nil handler:^(UIAction *a) {
                GXSetCompareCandidate(it.path); GXToast(ws.view, GXL(@"Теперь долгое нажатие на второй файл → «Сравнить с…»")); }]];
        }
        if (GXPanelsVC.shared) {
            [mt addObject:[UIAction actionWithTitle:GXL(@"Копировать в другую панель") image:[UIImage systemImageNamed:@"rectangle.righthalf.inset.filled.arrow.right"] identifier:nil handler:^(UIAction *a) { [ws toOtherPanel:@[it.path] move:NO]; }]];
            [mt addObject:[UIAction actionWithTitle:GXL(@"Переместить в другую панель") image:[UIImage systemImageNamed:@"arrow.right.square"] identifier:nil handler:^(UIAction *a) { [ws toOtherPanel:@[it.path] move:YES]; }]];
        }
        NSMutableArray *share = [NSMutableArray arrayWithArray:@[
            [UIAction actionWithTitle:GXL(@"Поделиться…") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { [ws share:@[it.path] from:[ws.tableView cellForRowAtIndexPath:ip] bar:nil]; }],
            [UIAction actionWithTitle:GXL(@"Сохранить в «Файлы»…") image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws exportToFiles:@[it.path]]; }],
            [UIAction actionWithTitle:GXL(@"Копировать путь") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = it.path; GXToast(ws.view, GXL(@"Путь скопирован")); }],
        ]];
        if (it.isDir) {
            BOOL fav = [GXFavorites() containsObject:it.path];
            [share addObject:[UIAction actionWithTitle:fav ? GXL(@"Убрать из избранного") : GXL(@"В избранное") image:[UIImage systemImageNamed:fav ? @"star.slash" : @"star"] identifier:nil handler:^(UIAction *a) {
                NSMutableArray *f = GXFavorites().mutableCopy;
                if ([f containsObject:it.path]) [f removeObject:it.path]; else [f addObject:it.path];
                GXSetFavorites(f);
                GXToast(ws.view, fav ? GXL(@"Убрано из избранного") : GXL(@"Добавлено в избранное"));
            }]];
            [share addObject:[UIAction actionWithTitle:GXL(@"Анализ места") image:[UIImage systemImageNamed:@"chart.pie"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXUsageVC alloc] initWithPath:it.path] animated:YES]; }]];
        }
        [share addObject:[UIAction actionWithTitle:GXL(@"Свойства") image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) { [ws showInfo:it.path]; }]];
        UIAction *del = [UIAction actionWithTitle:GXL(@"Удалить") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { [ws confirmDelete:@[it.path]]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:it.extra ? [NSString stringWithFormat:@"%@ · %@", it.extra, it.name] : it.name children:@[
            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:open],
            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:edit],
            [UIMenu menuWithTitle:GXL(@"Инструменты") image:[UIImage systemImageNamed:@"wrench.and.screwdriver"] identifier:nil options:0 children:mt],
            [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:share], del]];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    GXItem *it = _items[ip.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:GXL(@"Удалить") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self confirmDelete:@[it.path]]; done(YES); }];
    UIContextualAction *ren = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:GXL(@"Имя") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self promptRename:it]; done(YES); }];
    ren.backgroundColor = UIColor.systemOrangeColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[del, ren]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    GXItem *it = _items[ip.row];
    UIContextualAction *cp = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:GXL(@"Копир.") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self setClip:@[it.path] cut:NO]; done(YES); }];
    cp.backgroundColor = UIColor.systemBlueColor;
    UIContextualAction *sh = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:GXL(@"Отпр.") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self share:@[it.path] from:v bar:nil]; done(YES); }];
    sh.backgroundColor = UIColor.systemGreenColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[cp, sh]];
}

#pragma mark Операции

- (void)showInfo:(NSString *)p { GXPresentNav(self, [[GXInfoVC alloc] initWithPath:p], NO); }

- (void)setClip:(NSArray<NSString *> *)paths cut:(BOOL)cut {
    if (!paths.count) return;
    gxClip = paths.mutableCopy;
    gxClipCut = cut;
    GXToast(self.view, [NSString stringWithFormat:GXL(@"%@: %lu. Откройте нужную папку и нажмите «%@»"), cut ? GXL(@"Вырезано") : GXL(@"Скопировано"), (unsigned long)paths.count, cut ? GXL(@"Переместить") : GXL(@"Вставить")]);
    [self updateToolbar];
}

- (void)runOp:(NSString *)title work:(NSString * (^)(void))work {
    GXRunBG(self, title, work, ^{ [self reload]; });
}

- (void)paste {
    NSArray *srcs = gxClip.copy;
    BOOL cut = gxClipCut;
    NSString *dir = _path;
    if (cut) [gxClip removeAllObjects];
    [self runOp:cut ? GXL(@"Перемещение…") : GXL(@"Копирование…") work:^NSString *{
        NSMutableString *errs = [NSMutableString string];
        for (NSString *src in srcs) {
            NSString *name = src.lastPathComponent;
            if ([dir isEqualToString:src] || [dir hasPrefix:[src stringByAppendingString:@"/"]]) { [errs appendFormat:GXL(@"«%@»: нельзя поместить папку в саму себя\n"), name]; continue; }
            if (cut && [src.stringByDeletingLastPathComponent isEqualToString:dir]) continue;
            NSString *dst = GXUniquePath(dir, name);
            NSError *e;
            BOOL ok = cut ? [FM() moveItemAtPath:src toPath:dst error:&e] : [FM() copyItemAtPath:src toPath:dst error:&e];
            if (!ok) [errs appendFormat:@"«%@»: %@\n", name, e.localizedDescription];
        }
        return errs;
    }];
}

- (void)pasteLinks {
    NSMutableString *errs = [NSMutableString string];
    for (NSString *src in gxClip) {
        NSError *e;
        if (![FM() createSymbolicLinkAtPath:GXUniquePath(_path, src.lastPathComponent) withDestinationPath:src error:&e]) [errs appendFormat:@"%@: %@\n", src.lastPathComponent, e.localizedDescription];
    }
    [gxClip removeAllObjects];
    [self reload];
    if (errs.length) GXAlert(self, GXL(@"Ошибки"), errs);
}

- (void)gxDuplicate:(GXItem *)it {
    NSString *dir = _path;
    [self runOp:GXL(@"Копирование…") work:^NSString *{
        NSError *e;
        return [FM() copyItemAtPath:it.path toPath:GXUniquePath(dir, it.name) error:&e] ? nil : e.localizedDescription;
    }];
}

- (void)compress:(NSArray<NSString *> *)paths format:(NSString *)fmt {
    if (!paths.count) return;
    [self setEditing:NO animated:YES];
    NSString *base = paths.count == 1 ? [paths[0] lastPathComponent] : GXL(@"Архив");
    if (paths.count == 1 && !GXIsDir(paths[0]) && [base pathExtension].length) base = base.stringByDeletingPathExtension;
    GXPrompt(self, GXL(@"Имя архива"), nil, [NSString stringWithFormat:@"%@.%@", base, fmt], nil, GXL(@"Сжать"), ^(NSString *name) {
        if (!name.length) return;
        NSString *dest = GXUniquePath(self->_path, name);
        [GXHUD showCancellableIn:self.view text:GXL(@"Сжатие…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *err = GXArchiveCreate(paths, dest, fmt, ^(double p) { [GXHUD setProgress:p]; });
            dispatch_async(dispatch_get_main_queue(), ^{
                [GXHUD hide];
                [self reload];
                if (err) GXAlert(self, GXL(@"Не удалось сжать"), err); else GXToast(self.view, [NSString stringWithFormat:GXL(@"Создан «%@»"), dest.lastPathComponent]);
            });
        });
    });
}

- (void)extract:(GXItem *)it {
    NSString *name = it.name;
    for (NSString *x in @[@".tar.gz", @".tar.xz", @".tar.bz2"]) if ([name.lowercaseString hasSuffix:x]) name = [name substringToIndex:name.length - x.length];
    if ([name isEqualToString:it.name]) name = name.stringByDeletingPathExtension;
    NSString *dest = GXUniquePath(_path, name);
    [GXHUD showCancellableIn:self.view text:GXL(@"Распаковка…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = GXArchiveExtractAll(it.path, dest, ^(double p) { [GXHUD setProgress:p]; });
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            [self reload];
            if (err) GXAlert(self, GXL(@"Распаковано с ошибками"), err); else GXToast(self.view, [NSString stringWithFormat:GXL(@"Распаковано в «%@»"), dest.lastPathComponent]);
        });
    });
}

- (void)confirmDelete:(NSArray<NSString *> *)paths {
    if (!paths.count) return;
    NSString *msg = paths.count == 1 ? [NSString stringWithFormat:GXL(@"«%@» будет удалён без возможности восстановления."), [paths[0] lastPathComponent]]
                                     : [NSString stringWithFormat:GXL(@"Объектов: %lu. Удаление необратимо."), (unsigned long)paths.count];
    GXConfirm(self, GXL(@"Удалить?"), msg, GXL(@"Удалить"), YES, ^{
        [self setEditing:NO animated:YES];
        [self runOp:GXL(@"Удаление…") work:^NSString *{
            NSMutableString *errs = [NSMutableString string];
            for (NSString *p in paths) {
                NSError *e;
                if (![FM() removeItemAtPath:p error:&e]) [errs appendFormat:@"«%@»: %@\n", p.lastPathComponent, e.localizedDescription];
            }
            return errs;
        }];
    });
}

- (void)promptRename:(GXItem *)it {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Переименовать") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = it.name;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Готово") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *n = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!n.length || [n isEqualToString:it.name]) return;
        if ([n containsString:@"/"]) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Имя не может содержать «/»")); return; }
        NSString *dst = [it.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:n];
        struct stat st;
        if (lstat(dst.fileSystemRepresentation, &st) == 0 && [n caseInsensitiveCompare:it.name] != NSOrderedSame) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Объект с таким именем уже существует")); return; }
        NSError *e;
        if (![FM() moveItemAtPath:it.path toPath:dst error:&e]) GXAlert(self, GXL(@"Не удалось переименовать"), e.localizedDescription);
        [self reload];
    }]];
    [self presentViewController:a animated:YES completion:^{
        UITextField *tf = a.textFields.firstObject;
        NSString *ext = it.name.pathExtension;
        NSUInteger len = (ext.length && !it.isDir) ? it.name.length - ext.length - 1 : it.name.length;
        UITextPosition *s = tf.beginningOfDocument;
        UITextPosition *e = [tf positionFromPosition:s offset:(NSInteger)len];
        if (s && e) tf.selectedTextRange = [tf textRangeFromPosition:s toPosition:e];
    }];
}

- (void)promptNew:(BOOL)folder {
    GXPrompt(self, folder ? GXL(@"Новая папка") : GXL(@"Новый файл"), nil, folder ? GXL(@"Новая папка") : GXL(@"новый.txt"), nil, GXL(@"Создать"), ^(NSString *n) {
        n = [n stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!n.length || [n containsString:@"/"]) return;
        NSString *p = GXUniquePath(self->_path, n);
        NSError *e;
        BOOL ok = folder ? [FM() createDirectoryAtPath:p withIntermediateDirectories:NO attributes:nil error:&e] : [[NSData data] writeToFile:p options:0 error:&e];
        if (!ok) { GXAlert(self, GXL(@"Не удалось создать"), e.localizedDescription); return; }
        [self reload];
        if (!folder) [GXOpener open:p from:self];
    });
}

- (void)newSymlink {
    GXPrompt(self, GXL(@"Символическая ссылка"), GXL(@"Куда должна вести ссылка (полный путь)"), UIPasteboard.generalPasteboard.string, GXL(@"/путь/к/цели"), GXL(@"Далее"), ^(NSString *target) {
        if (!target.length) return;
        GXPrompt(self, GXL(@"Имя ссылки"), nil, target.lastPathComponent, nil, GXL(@"Создать"), ^(NSString *name) {
            NSError *e;
            if (![FM() createSymbolicLinkAtPath:GXUniquePath(self->_path, name) withDestinationPath:target error:&e]) GXAlert(self, GXL(@"Не удалось"), e.localizedDescription);
            [self reload];
        });
    });
}

- (void)fromPasteboard {
    UIPasteboard *pb = UIPasteboard.generalPasteboard;
    if (pb.hasImages) {
        NSData *png = UIImagePNGRepresentation(pb.image);
        NSString *p = GXUniquePath(_path, GXL(@"Картинка из буфера.png"));
        if ([png writeToFile:p atomically:YES]) GXToast(self.view, GXL(@"Картинка сохранена"));
    } else if (pb.hasStrings) {
        NSString *p = GXUniquePath(_path, GXL(@"Текст из буфера.txt"));
        if ([pb.string writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) GXToast(self.view, GXL(@"Текст сохранён"));
    } else if (pb.hasURLs && pb.URL.isFileURL) {
        NSError *e;
        if (![FM() copyItemAtURL:pb.URL toURL:[NSURL fileURLWithPath:GXUniquePath(_path, pb.URL.lastPathComponent)] error:&e]) GXAlert(self, GXL(@"Ошибка"), e.localizedDescription);
    } else GXToast(self.view, GXL(@"В буфере нет текста или картинки"));
    [self reload];
}

- (void)downloadURL {
    GXPrompt(self, GXL(@"Скачать по ссылке"), GXL(@"Файл сохранится в эту папку"), UIPasteboard.generalPasteboard.hasURLs ? UIPasteboard.generalPasteboard.URL.absoluteString : nil, @"https://…", GXL(@"Скачать"), ^(NSString *s) {
        NSURL *u = [NSURL URLWithString:[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        if (!u.scheme) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Неверная ссылка")); return; }
        NSString *dir = self->_path;
        [GXHUD showCancellableIn:self.view text:GXL(@"Загрузка…")];
        NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:u completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *err) {
            NSString *name = resp.suggestedFilename.length ? resp.suggestedFilename : (u.lastPathComponent.length ? u.lastPathComponent : @"download");
            NSString *dest = GXUniquePath(dir, name);
            NSError *me = nil;
            if (loc) [FM() moveItemAtURL:loc toURL:[NSURL fileURLWithPath:dest] error:&me];
            dispatch_async(dispatch_get_main_queue(), ^{
                [GXHUD hide];
                [self reload];
                if (err || me) GXAlert(self, GXL(@"Не удалось скачать"), (err ?: me).localizedDescription);
                else GXToast(self.view, [NSString stringWithFormat:GXL(@"Скачано: %@"), dest.lastPathComponent]);
            });
        }];
        [task resume];
        // прогресс и отмена
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *tm) {
            if (task.state != NSURLSessionTaskStateRunning) { [tm invalidate]; return; }
            if ([GXHUD cancelled]) { [task cancel]; [tm invalidate]; return; }
            int64_t total = task.countOfBytesExpectedToReceive, got = task.countOfBytesReceived;
            [GXHUD setText:total > 0 ? [NSString stringWithFormat:GXL(@"%@ из %@"), GXHuman((unsigned long long)got), GXHuman((unsigned long long)total)] : GXHuman((unsigned long long)got)];
            [GXHUD setProgress:total > 0 ? (double)got / total : -1];
        }];
        (void)t;
    });
}

- (void)promptGoto {
    GXPrompt(self, GXL(@"Перейти по пути"), GXL(@"Например /var/mobile/Containers/Shared/AppGroup"), _path, nil, GXL(@"Перейти"), ^(NSString *v) {
        NSString *p = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].stringByExpandingTildeInPath.stringByStandardizingPath;
        if (!p.length) return;
        BOOL isDir = NO;
        if ([FM() fileExistsAtPath:p isDirectory:&isDir] && !isDir) { [GXOpener open:p from:self]; return; }
        [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:p] animated:YES];
    });
}

- (void)share:(NSArray<NSString *> *)paths from:(UIView *)v bar:(UIBarButtonItem *)bar {
    if (!paths.count) return;
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in paths) [urls addObject:[NSURL fileURLWithPath:p]];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    if (bar) avc.popoverPresentationController.barButtonItem = bar;
    else { avc.popoverPresentationController.sourceView = v ?: self.view; avc.popoverPresentationController.sourceRect = (v ?: self.view).bounds; }
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)exportToFiles:(NSArray<NSString *> *)paths {
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *p in paths) [urls addObject:[NSURL fileURLWithPath:p]];
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForExportingURLs:urls asCopy:YES];
    [self presentViewController:dp animated:YES completion:nil];
}

- (void)importFiles {
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem, UTTypeFolder] asCopy:YES];
    dp.allowsMultipleSelection = YES;
    dp.delegate = self;
    [self presentViewController:dp animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *dir = _path;
    [self runOp:GXL(@"Импорт…") work:^NSString *{
        NSMutableString *errs = [NSMutableString string];
        for (NSURL *u in urls) {
            BOOL scoped = [u startAccessingSecurityScopedResource];
            NSError *e;
            if (![FM() copyItemAtURL:u toURL:[NSURL fileURLWithPath:GXUniquePath(dir, u.lastPathComponent)] error:&e]) [errs appendFormat:@"«%@»: %@\n", u.lastPathComponent, e.localizedDescription];
            if (scoped) [u stopAccessingSecurityScopedResource];
        }
        return errs;
    }];
}
@end

#pragma mark - Глубокий поиск

@interface GXSearchVC () <UISearchBarDelegate>
@end

@implementation GXSearchVC {
    NSString *_root;
    NSMutableArray<NSString *> *_results;
    UISearchBar *_bar;
    NSInteger _gen;
    BOOL _running;
    unsigned long long _scanned;
}
- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super initWithStyle:UITableViewStylePlain])) { _root = root; _results = [NSMutableArray array]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Поиск");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    _bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 100)];
    _bar.delegate = self;
    _bar.placeholder = GXL(@"Имя файла (или текст внутри)");
    _bar.scopeButtonTitles = @[GXL(@"По имени"), GXL(@"В содержимом")];
    _bar.showsScopeBar = YES;
    _bar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [_bar sizeToFit];
    self.tableView.tableHeaderView = _bar;
    self.tableView.rowHeight = 56;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [_bar becomeFirstResponder]; }
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; if (self.isMovingFromParentViewController) _gen++; }
- (void)close { _gen++; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)sb { [sb resignFirstResponder]; [self start]; }
- (void)searchBar:(UISearchBar *)sb selectedScopeButtonIndexDidChange:(NSInteger)i { if (sb.text.length) [self start]; }

- (void)start {
    NSString *q = _bar.text;
    if (!q.length) return;
    NSInteger gen = ++_gen;
    BOOL content = _bar.selectedScopeButtonIndex == 1;
    [_results removeAllObjects];
    _running = YES;
    _scanned = 0;
    [self.tableView reloadData];
    NSString *root = _root;
    BOOL hidden = GXShowHidden();
    NSData *needle = [q dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLFileSizeKey]
                                                   options:hidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
        NSMutableArray *batch = [NSMutableArray array];
        CFAbsoluteTime last = CFAbsoluteTimeGetCurrent();
        unsigned long long scanned = 0;
        for (NSURL *u in en) {
            if (gen != self->_gen) return;
            scanned++;
            NSString *name = u.lastPathComponent;
            BOOL hit = NO;
            if (!content) hit = [name localizedCaseInsensitiveContainsString:q];
            else {
                NSNumber *isd, *sz;
                [u getResourceValue:&isd forKey:NSURLIsDirectoryKey error:nil];
                [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                if (!isd.boolValue && sz.unsignedLongLongValue < 8 * 1024 * 1024 && sz.unsignedLongLongValue > 0) {
                    NSData *d = [NSData dataWithContentsOfURL:u options:NSDataReadingMappedIfSafe error:nil];
                    hit = d && [d rangeOfData:needle options:0 range:NSMakeRange(0, d.length)].location != NSNotFound;
                }
            }
            if (hit) [batch addObject:u.path];
            if (batch.count && (CFAbsoluteTimeGetCurrent() - last > 0.25 || batch.count > 200)) {
                NSArray *b = batch.copy;
                [batch removeAllObjects];
                last = CFAbsoluteTimeGetCurrent();
                unsigned long long sc = scanned;
                dispatch_async(dispatch_get_main_queue(), ^{ if (gen == self->_gen) { [self->_results addObjectsFromArray:b]; self->_scanned = sc; [self.tableView reloadData]; } });
            }
            if (self->_results.count + batch.count > 5000) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_gen) return;
            [self->_results addObjectsFromArray:batch];
            self->_running = NO;
            self->_scanned = scanned;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _results.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (!_bar.text.length) return [NSString stringWithFormat:GXL(@"Где: %@"), _root];
    return [NSString stringWithFormat:GXL(@"%@ · найдено %lu · просмотрено %llu"), _running ? GXL(@"Ищу…") : GXL(@"Готово"), (unsigned long)_results.count, _scanned];
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"s"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
    NSString *p = _results[ip.row];
    BOOL dir = GXIsDir(p);
    GXKind k = GXKindForName(p.lastPathComponent, dir);
    c.imageView.image = GXSymbolTile(GXSymbolForKind(k), GXColorForKind(k), 34);
    c.textLabel.text = p.lastPathComponent;
    NSString *rel = [p hasPrefix:_root] ? [p substringFromIndex:_root.length] : p;
    c.detailTextLabel.text = rel.stringByDeletingLastPathComponent.length ? rel.stringByDeletingLastPathComponent : @"/";
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *p = _results[ip.row];
    if (GXIsDir(p)) [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:p] animated:YES];
    else [GXOpener open:p from:self];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    NSString *p = _results[ip.row];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        return [UIMenu menuWithTitle:p children:@[
            [UIAction actionWithTitle:GXL(@"Показать в папке") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:p.stringByDeletingLastPathComponent] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Копировать путь") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = p; }]]];
    }];
}
@end

#pragma mark - Анализ места

@implementation GXUsageVC {
    NSString *_path;
    NSMutableArray<NSMutableDictionary *> *_rows;
    unsigned long long _total;
    NSInteger _pending;
    BOOL _stop;
}
- (instancetype)initWithPath:(NSString *)path { if ((self = [super initWithStyle:UITableViewStylePlain])) { _path = path; _rows = [NSMutableArray array]; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:GXL(@"Место: %@"), _path.lastPathComponent.length ? _path.lastPathComponent : @"/"];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = 62;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    NSArray *names = [FM() contentsOfDirectoryAtPath:_path error:nil];
    for (NSString *n in names) [_rows addObject:[@{@"name": n, @"size": @(0), @"done": @NO} mutableCopy]];
    _pending = _rows.count;
    for (NSMutableDictionary *r in _rows) {
        NSString *p = [_path stringByAppendingPathComponent:r[@"name"]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            unsigned long long sz = 0;
            struct stat st;
            if (lstat(p.fileSystemRepresentation, &st) == 0) {
                if (S_ISDIR(st.st_mode)) {
                    NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:p] includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
                    for (NSURL *u in en) {
                        if (self->_stop) return;
                        NSNumber *s;
                        [u getResourceValue:&s forKey:NSURLTotalFileAllocatedSizeKey error:nil];
                        sz += s.unsignedLongLongValue;
                    }
                } else sz = (unsigned long long)st.st_blocks * 512;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                r[@"size"] = @(sz);
                r[@"done"] = @YES;
                r[@"dir"] = @(S_ISDIR(st.st_mode));
                self->_pending--;
                [self resort];
            });
        });
    }
    [self resort];
}
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; if (self.isMovingFromParentViewController) _stop = YES; }
- (void)close { _stop = YES; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)resort {
    _total = 0;
    for (NSDictionary *r in _rows) _total += [r[@"size"] unsignedLongLongValue];
    [_rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"size"] compare:a[@"size"]]; }];
    [self.tableView reloadData];
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:GXL(@"Всего: %@%@"), GXHuman(_total), _pending > 0 ? [NSString stringWithFormat:GXL(@" · считаю (%ld)…"), (long)_pending] : @""];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"u"];
    UIProgressView *pv;
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"u"];
        pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        pv.tag = 7;
        pv.frame = CGRectMake(62, 56, tv.bounds.size.width - 80, 3);
        pv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [c.contentView addSubview:pv];
    }
    pv = [c.contentView viewWithTag:7];
    NSDictionary *r = _rows[ip.row];
    NSString *p = [_path stringByAppendingPathComponent:r[@"name"]];
    BOOL dir = [r[@"dir"] boolValue];
    GXKind k = GXKindForName(r[@"name"], dir);
    c.imageView.image = GXSymbolTile(GXSymbolForKind(k), GXColorForKind(k), 34);
    GXLCApp *owner = dir ? ([GXLCApp appOwningDataFolder:p] ?: [GXLCApp appForBundlePath:p]) : nil;
    c.textLabel.text = owner ? [NSString stringWithFormat:@"%@ · %@", owner.name, r[@"name"]] : r[@"name"];
    c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    unsigned long long sz = [r[@"size"] unsignedLongLongValue];
    c.detailTextLabel.text = [r[@"done"] boolValue] ? [NSString stringWithFormat:@"%@ · %.1f%%", GXHuman(sz), _total ? 100.0 * sz / _total : 0] : GXL(@"считаю…");
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    pv.progress = _total ? (float)sz / _total : 0;
    c.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *r = _rows[ip.row];
    NSString *p = [_path stringByAppendingPathComponent:r[@"name"]];
    if ([r[@"dir"] boolValue]) [self.navigationController pushViewController:[[GXUsageVC alloc] initWithPath:p] animated:YES];
    else [GXOpener open:p from:self];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    NSString *p = [_path stringByAppendingPathComponent:_rows[ip.row][@"name"]];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        UIAction *del = [UIAction actionWithTitle:GXL(@"Удалить") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
            GXConfirm(ws, GXL(@"Удалить?"), p.lastPathComponent, GXL(@"Удалить"), YES, ^{
                NSError *e;
                if (![FM() removeItemAtPath:p error:&e]) GXAlert(ws, GXL(@"Ошибка"), e.localizedDescription);
                else {
                    GXUsageVC *s2 = ws;
                    if (s2) { [s2->_rows removeObjectAtIndex:ip.row]; [s2 resort]; }
                }
            });
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:p.lastPathComponent children:@[
            [UIAction actionWithTitle:GXL(@"Открыть в браузере") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
                [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:GXIsDir(p) ? p : p.stringByDeletingLastPathComponent] animated:YES]; }],
            del]];
    }];
}
@end

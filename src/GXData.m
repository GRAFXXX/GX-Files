// SQLite, Assets.car, свойства файла, отчёты Mach-O / ELF, mobileprovision
#import "GXCore.h"
#import <objc/message.h>
#include <sqlite3.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pwd.h>
#include <grp.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

#pragma mark - SQLite

@interface GXSQLTableVC : UITableViewController
- (instancetype)initWithDB:(sqlite3 *)db table:(NSString *)table;
@end

@interface GXSQLConsoleVC : UIViewController
- (instancetype)initWithDB:(sqlite3 *)db;
@end

static NSString *GXSQLValue(sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
        case SQLITE_NULL: return @"NULL";
        case SQLITE_INTEGER: return [NSString stringWithFormat:@"%lld", sqlite3_column_int64(st, i)];
        case SQLITE_FLOAT: return [NSString stringWithFormat:@"%g", sqlite3_column_double(st, i)];
        case SQLITE_BLOB: {
            int n = sqlite3_column_bytes(st, i);
            NSData *d = [NSData dataWithBytes:sqlite3_column_blob(st, i) length:(NSUInteger)n];
            if (n >= 8 && !memcmp(d.bytes, "bplist00", 8)) return [NSString stringWithFormat:@"<bplist %@>", GXHuman((unsigned long long)n)];
            return [NSString stringWithFormat:@"<BLOB %@> %@", GXHuman((unsigned long long)n), GXHexString(d, 16)];
        }
        default: {
            const unsigned char *t = sqlite3_column_text(st, i);
            return t ? @((const char *)t) ?: @"" : @"";
        }
    }
}

@implementation GXSQLiteVC {
    NSString *_path;
    sqlite3 *_db;
    NSArray<NSArray *> *_tables; // [name, type, count]
    NSString *_error;
}
- (instancetype)initWithPath:(NSString *)path { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _path = path; return self; }
- (void)dealloc { if (_db) sqlite3_close(_db); }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"terminal"] style:UIBarButtonItemStylePlain target:self action:@selector(console)];
    if (sqlite3_open_v2(_path.fileSystemRepresentation, &_db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (_db) sqlite3_close(_db);
        _db = NULL;
        if (sqlite3_open_v2(_path.fileSystemRepresentation, &_db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            _error = _db ? @(sqlite3_errmsg(_db)) : GXL(@"не открыть базу");
        }
    }
    [self load];
}
- (void)load {
    if (!_db) return;
    NSMutableArray *t = [NSMutableArray array];
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') ORDER BY name", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            NSString *n = @((const char *)sqlite3_column_text(st, 0) ?: "");
            NSString *ty = @((const char *)sqlite3_column_text(st, 1) ?: "");
            [t addObject:@[n, ty, @(-1)]];
        }
        sqlite3_finalize(st);
    } else _error = @(sqlite3_errmsg(_db));
    for (NSUInteger i = 0; i < t.count; i++) {
        NSString *q = [NSString stringWithFormat:@"SELECT COUNT(*) FROM \"%@\"", [t[i][0] stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
        if (sqlite3_prepare_v2(_db, q.UTF8String, -1, &st, NULL) == SQLITE_OK) {
            if (sqlite3_step(st) == SQLITE_ROW) t[i] = @[t[i][0], t[i][1], @(sqlite3_column_int64(st, 0))];
            sqlite3_finalize(st);
        }
    }
    _tables = t;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _tables.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return _error ? [NSString stringWithFormat:GXL(@"Ошибка: %@"), _error] : GXL(@"SQL-консоль — кнопка справа сверху. Изменения записываются сразу.");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"t"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"t"];
    NSArray *t = _tables[ip.row];
    c.textLabel.text = t[0];
    c.detailTextLabel.text = [t[2] longLongValue] >= 0 ? [NSString stringWithFormat:@"%@ · %@", t[1], t[2]] : t[1];
    c.imageView.image = GXSymbolTile([t[1] isEqualToString:@"view"] ? @"eye" : @"tablecells", UIColor.systemCyanColor, 26);
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self.navigationController pushViewController:[[GXSQLTableVC alloc] initWithDB:_db table:_tables[ip.row][0]] animated:YES];
}
- (void)console { if (_db) [self.navigationController pushViewController:[[GXSQLConsoleVC alloc] initWithDB:_db] animated:YES]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

@implementation GXSQLTableVC {
    sqlite3 *_db;
    NSString *_table;
    NSArray<NSString *> *_cols;
    NSMutableArray<NSArray<NSString *> *> *_rows;
    BOOL _more;
}
- (instancetype)initWithDB:(sqlite3 *)db table:(NSString *)table {
    if ((self = [super initWithStyle:UITableViewStylePlain])) { _db = db; _table = table; _rows = [NSMutableArray array]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _table;
    self.tableView.estimatedRowHeight = 60;
    [self loadMore];
}
- (void)loadMore {
    NSString *q = [NSString stringWithFormat:@"SELECT * FROM \"%@\" LIMIT 200 OFFSET %lu", [_table stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""], (unsigned long)_rows.count];
    sqlite3_stmt *st;
    if (sqlite3_prepare_v2(_db, q.UTF8String, -1, &st, NULL) != SQLITE_OK) { GXAlert(self, GXL(@"Ошибка"), @(sqlite3_errmsg(_db))); return; }
    int n = sqlite3_column_count(st);
    if (!_cols) {
        NSMutableArray *c = [NSMutableArray array];
        for (int i = 0; i < n; i++) [c addObject:@(sqlite3_column_name(st, i) ?: "?")];
        _cols = c;
    }
    int got = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
        NSMutableArray *r = [NSMutableArray array];
        for (int i = 0; i < n; i++) [r addObject:GXSQLValue(st, i)];
        [_rows addObject:r];
        got++;
    }
    sqlite3_finalize(st);
    _more = got == 200;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count + (_more ? 1 : 0); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"r"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"];
    if ((NSUInteger)ip.row == _rows.count) {
        c.textLabel.text = GXL(@"Загрузить ещё 200…");
        c.textLabel.textColor = self.view.tintColor;
        c.detailTextLabel.text = nil;
        return c;
    }
    c.textLabel.textColor = UIColor.labelColor;
    NSArray *r = _rows[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"#%ld  %@", (long)ip.row + 1, r.firstObject ?: @""];
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 1; i < r.count && i < 8; i++) {
        NSString *v = r[i];
        if (v.length > 60) v = [[v substringToIndex:60] stringByAppendingString:@"…"];
        [parts addObject:[NSString stringWithFormat:@"%@: %@", _cols[i], v]];
    }
    c.detailTextLabel.text = [parts componentsJoinedByString:@"\n"];
    c.detailTextLabel.numberOfLines = 6;
    c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if ((NSUInteger)ip.row == _rows.count) { [self loadMore]; return; }
    NSMutableString *s = [NSMutableString string];
    NSArray *r = _rows[ip.row];
    for (NSUInteger i = 0; i < r.count; i++) [s appendFormat:@"%@:\n%@\n\n", _cols[i], r[i]];
    [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:[NSString stringWithFormat:GXL(@"Строка %ld"), (long)ip.row + 1] text:s] animated:YES];
}
@end

@implementation GXSQLConsoleVC {
    sqlite3 *_db;
    UITextView *_input, *_output;
}
- (instancetype)initWithDB:(sqlite3 *)db { if ((self = [super init])) _db = db; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SQL";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _input = [UITextView new];
    _output = [UITextView new];
    for (UITextView *t in @[_input, _output]) {
        t.translatesAutoresizingMaskIntoConstraints = NO;
        t.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        t.autocorrectionType = UITextAutocorrectionTypeNo;
        t.autocapitalizationType = UITextAutocapitalizationTypeNone;
        t.layer.cornerRadius = 8;
        [self.view addSubview:t];
    }
    _input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _input.text = @"SELECT name FROM sqlite_master;";
    _output.editable = NO;
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_input.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [_input.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_input.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [_input.heightAnchor constraintEqualToConstant:120],
        [_output.topAnchor constraintEqualToAnchor:_input.bottomAnchor constant:8],
        [_output.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [_output.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [_output.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"play.fill"] style:UIBarButtonItemStyleDone target:self action:@selector(run)];
}
- (void)run {
    [_input resignFirstResponder];
    NSMutableString *out = [NSMutableString string];
    const char *sql = _input.text.UTF8String;
    const char *tail = sql;
    int stmts = 0;
    while (tail && *tail) {
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(_db, tail, -1, &st, &tail) != SQLITE_OK) { [out appendFormat:GXL(@"Ошибка: %s\n"), sqlite3_errmsg(_db)]; break; }
        if (!st) break;
        stmts++;
        int n = sqlite3_column_count(st);
        if (n) {
            NSMutableArray *h = [NSMutableArray array];
            for (int i = 0; i < n; i++) [h addObject:@(sqlite3_column_name(st, i) ?: "?")];
            [out appendFormat:@"%@\n%@\n", [h componentsJoinedByString:@" | "], [@"" stringByPaddingToLength:40 withString:@"─" startingAtIndex:0]];
        }
        int rows = 0, rc;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            if (rows < 1000) {
                NSMutableArray *r = [NSMutableArray array];
                for (int i = 0; i < n; i++) [r addObject:GXSQLValue(st, i)];
                [out appendFormat:@"%@\n", [r componentsJoinedByString:@" | "]];
            }
            rows++;
        }
        if (rc != SQLITE_DONE) [out appendFormat:GXL(@"Ошибка: %s\n"), sqlite3_errmsg(_db)];
        else if (n) [out appendFormat:GXL(@"(%d строк%@)\n\n"), rows, rows > 1000 ? GXL(@", показано 1000") : @""];
        else [out appendFormat:GXL(@"OK, изменено строк: %d\n\n"), sqlite3_changes(_db)];
        sqlite3_finalize(st);
    }
    _output.text = out.length ? out : (stmts ? GXL(@"Готово") : GXL(@"Пустой запрос"));
}
@end

#pragma mark - Assets.car

@implementation GXCarVC {
    NSString *_path;
    id _catalog;
    NSArray<NSString *> *_names;
    NSCache *_thumbs;
}
- (instancetype)initWithPath:(NSString *)path {
    UICollectionViewFlowLayout *l = [UICollectionViewFlowLayout new];
    l.itemSize = CGSizeMake(100, 124);
    l.minimumInteritemSpacing = 8;
    l.minimumLineSpacing = 12;
    l.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);
    if ((self = [super initWithCollectionViewLayout:l])) { _path = path; _thumbs = [NSCache new]; }
    return self;
}
- (CGImageRef)imageNamed:(NSString *)n {
    SEL s = NSSelectorFromString(@"imageWithName:scaleFactor:");
    if (![_catalog respondsToSelector:s]) return NULL;
    id named = ((id (*)(id, SEL, id, CGFloat))objc_msgSend)(_catalog, s, n, UIScreen.mainScreen.scale);
    if (!named) named = ((id (*)(id, SEL, id, CGFloat))objc_msgSend)(_catalog, s, n, 1.0);
    SEL img = NSSelectorFromString(@"image");
    if (!named || ![named respondsToSelector:img]) return NULL;
    return ((CGImageRef (*)(id, SEL))objc_msgSend)(named, img);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    [self.collectionView registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"c"];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Экспорт всех") style:UIBarButtonItemStylePlain target:self action:@selector(exportAll)];
    dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY);
    Class C = NSClassFromString(@"CUICatalog");
    SEL init = NSSelectorFromString(@"initWithURL:error:");
    if (C && [C instancesRespondToSelector:init]) {
        NSError *err = nil;
        _catalog = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([C alloc], init, [NSURL fileURLWithPath:_path], &err);
    }
    SEL all = NSSelectorFromString(@"allImageNames");
    if (_catalog && [_catalog respondsToSelector:all]) {
        NSArray *n = ((id (*)(id, SEL))objc_msgSend)(_catalog, all);
        _names = [[[NSSet setWithArray:n ?: @[]] allObjects] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    }
    if (!_names.count) {
        UILabel *l = [UILabel new];
        l.text = _catalog ? GXL(@"В каталоге нет изображений") : GXL(@"Не удалось открыть Assets.car (CoreUI недоступен)");
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 0;
        l.textColor = UIColor.secondaryLabelColor;
        self.collectionView.backgroundView = l;
    }
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return _names.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:ip];
    UIImageView *iv = [c.contentView viewWithTag:1];
    UILabel *l = [c.contentView viewWithTag:2];
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:CGRectMake(10, 4, 80, 80)];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.tag = 1;
        iv.backgroundColor = UIColor.secondarySystemBackgroundColor;
        iv.layer.cornerRadius = 10;
        iv.clipsToBounds = YES;
        l = [[UILabel alloc] initWithFrame:CGRectMake(0, 88, 100, 32)];
        l.tag = 2;
        l.font = [UIFont systemFontOfSize:10];
        l.numberOfLines = 2;
        l.textAlignment = NSTextAlignmentCenter;
        [c.contentView addSubview:iv];
        [c.contentView addSubview:l];
    }
    NSString *n = _names[ip.item];
    l.text = n;
    UIImage *t = [_thumbs objectForKey:n];
    if (!t) {
        CGImageRef cg = [self imageNamed:n];
        t = cg ? [UIImage imageWithCGImage:cg] : GXSymbolTile(@"questionmark.square", UIColor.systemGrayColor, 40);
        [_thumbs setObject:t forKey:n];
    }
    iv.image = t;
    return c;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    NSString *n = _names[ip.item];
    CGImageRef cg = [self imageNamed:n];
    if (!cg) { GXToast(self.view, GXL(@"Это не растровое изображение")); return; }
    UIImage *img = [UIImage imageWithCGImage:cg];
    NSString *tmp = [GXTempDir() stringByAppendingPathComponent:[n stringByAppendingPathExtension:@"png"]];
    [UIImagePNGRepresentation(img) writeToFile:tmp atomically:YES];
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:tmp]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = [cv cellForItemAtIndexPath:ip];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)exportAll {
    NSString *dest = GXUniquePath(_path.stringByDeletingLastPathComponent, [_path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:GXL(@" (картинки)")]);
    [FM() createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    NSUInteger n = 0;
    for (NSString *name in _names) {
        CGImageRef cg = [self imageNamed:name];
        if (!cg) continue;
        NSString *safe = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        if ([UIImagePNGRepresentation([UIImage imageWithCGImage:cg]) writeToFile:[dest stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"png"]] atomically:YES]) n++;
    }
    GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено %lu картинок в «%@»"), (unsigned long)n, dest.lastPathComponent]);
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - Mach-O / ELF / provision

static uint32_t sw32(uint32_t v, BOOL s) { return s ? __builtin_bswap32(v) : v; }

static NSString *GXCPU(cpu_type_t t, cpu_subtype_t st) {
    switch (t) {
        case CPU_TYPE_ARM64: return (st & 0xff) == 2 ? @"arm64e" : @"arm64";
        case CPU_TYPE_ARM: return @"armv7";
        case CPU_TYPE_X86_64: return @"x86_64";
        case CPU_TYPE_X86: return @"i386";
        case CPU_TYPE_ARM64_32: return @"arm64_32";
        default: return [NSString stringWithFormat:@"cpu %d", t];
    }
}

static NSString *GXFileType(uint32_t t) {
    switch (t) {
        case MH_EXECUTE: return GXL(@"исполняемый файл");
        case MH_DYLIB: return GXL(@"динамическая библиотека");
        case MH_BUNDLE: return @"bundle";
        case MH_OBJECT: return GXL(@"объектный файл");
        case MH_DYLINKER: return @"dyld";
        case MH_DSYM: return @"dSYM";
        default: return [NSString stringWithFormat:GXL(@"тип %u"), t];
    }
}

static NSString *GXPlatform(uint32_t p) {
    switch (p) { case 1: return @"macOS"; case 2: return @"iOS"; case 3: return @"tvOS"; case 4: return @"watchOS"; case 6: return @"Mac Catalyst";
        case 7: return @"iOS Simulator"; case 11: return @"visionOS"; default: return [NSString stringWithFormat:GXL(@"платформа %u"), p]; }
}

static NSString *GXVer(uint32_t v) { return [NSString stringWithFormat:@"%u.%u.%u", v >> 16, (v >> 8) & 0xff, v & 0xff]; }

static NSData *GXEntitlementsFromSlice(NSData *d, uint64_t base, uint64_t size) {
    const uint8_t *b = d.bytes;
    if (base + sizeof(struct mach_header_64) > d.length) return nil;
    const struct mach_header_64 *h = (const void *)(b + base);
    BOOL is64 = h->magic == MH_MAGIC_64;
    uint64_t off = base + (is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
    for (uint32_t i = 0; i < h->ncmds; i++) {
        if (off + 8 > d.length) break;
        const struct load_command *lc = (const void *)(b + off);
        if (lc->cmd == LC_CODE_SIGNATURE && off + sizeof(struct linkedit_data_command) <= d.length) {
            const struct linkedit_data_command *cs = (const void *)lc;
            uint64_t sb = base + cs->dataoff;
            if (sb + 12 > d.length) return nil;
            uint32_t count = __builtin_bswap32(*(const uint32_t *)(b + sb + 8));
            for (uint32_t k = 0; k < count && k < 64; k++) {
                uint64_t idx = sb + 12 + k * 8;
                if (idx + 8 > d.length) break;
                uint32_t type = __builtin_bswap32(*(const uint32_t *)(b + idx));
                uint32_t boff = __builtin_bswap32(*(const uint32_t *)(b + idx + 4));
                if (type != 5) continue; // CSSLOT_ENTITLEMENTS
                uint64_t bp = sb + boff;
                if (bp + 8 > d.length) return nil;
                uint32_t magic = __builtin_bswap32(*(const uint32_t *)(b + bp));
                uint32_t len = __builtin_bswap32(*(const uint32_t *)(b + bp + 4));
                if (magic != 0xfade7171 || len < 8 || bp + len > d.length) return nil;
                return [d subdataWithRange:NSMakeRange((NSUInteger)bp + 8, len - 8)];
            }
        }
        if (lc->cmdsize < 8) break;
        off += lc->cmdsize;
    }
    (void)size;
    return nil;
}

static void GXDescribeSlice(NSData *d, uint64_t base, NSMutableString *s) {
    const uint8_t *b = d.bytes;
    if (base + 28 > d.length) { [s appendString:GXL(@"  (обрезан)\n")]; return; }
    uint32_t magic = *(const uint32_t *)(b + base);
    BOOL swap = magic == MH_CIGAM || magic == MH_CIGAM_64;
    BOOL is64 = magic == MH_MAGIC_64 || magic == MH_CIGAM_64;
    const struct mach_header *h = (const void *)(b + base);
    uint32_t ncmds = sw32(h->ncmds, swap), ftype = sw32(h->filetype, swap), flags = sw32(h->flags, swap);
    [s appendFormat:GXL(@"Архитектура: %@\nТип: %@\nКоманд загрузки: %u\nФлаги: 0x%x%@%@\n"), GXCPU((cpu_type_t)sw32((uint32_t)h->cputype, swap), (cpu_subtype_t)sw32((uint32_t)h->cpusubtype, swap)),
        GXFileType(ftype), ncmds, flags, (flags & MH_PIE) ? @" PIE" : @"", (flags & MH_TWOLEVEL) ? @" TWOLEVEL" : @""];
    uint64_t off = base + (is64 ? sizeof(struct mach_header_64) : sizeof(struct mach_header));
    NSMutableArray *dylibs = [NSMutableArray array], *rpaths = [NSMutableArray array];
    for (uint32_t i = 0; i < ncmds && i < 4096; i++) {
        if (off + 8 > d.length) break;
        const struct load_command *lc = (const void *)(b + off);
        uint32_t cmd = sw32(lc->cmd, swap), size = sw32(lc->cmdsize, swap);
        if (size < 8 || off + size > d.length) break;
        switch (cmd) {
            case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_ID_DYLIB: {
                const struct dylib_command *dc = (const void *)lc;
                uint32_t no = sw32(dc->dylib.name.offset, swap);
                if (no < size) {
                    NSString *name = [[NSString alloc] initWithBytes:b + off + no length:strnlen((const char *)b + off + no, size - no) encoding:NSUTF8StringEncoding] ?: @"?";
                    if (cmd == LC_ID_DYLIB) [s appendFormat:@"Install name: %@\n", name];
                    else [dylibs addObject:[NSString stringWithFormat:@"%@%@", name, cmd == LC_LOAD_WEAK_DYLIB ? @" (weak)" : cmd == LC_REEXPORT_DYLIB ? @" (reexport)" : @""]];
                }
                break;
            }
            case LC_RPATH: {
                const struct rpath_command *rc = (const void *)lc;
                uint32_t po = sw32(rc->path.offset, swap);
                if (po < size) [rpaths addObject:[[NSString alloc] initWithBytes:b + off + po length:strnlen((const char *)b + off + po, size - po) encoding:NSUTF8StringEncoding] ?: @"?"];
                break;
            }
            case LC_UUID: {
                const struct uuid_command *u = (const void *)lc;
                [s appendFormat:@"UUID: %@\n", [[NSUUID alloc] initWithUUIDBytes:u->uuid].UUIDString];
                break;
            }
            case LC_BUILD_VERSION: {
                const struct build_version_command *bv = (const void *)lc;
                [s appendFormat:GXL(@"Платформа: %@, мин. %@, SDK %@\n"), GXPlatform(sw32(bv->platform, swap)), GXVer(sw32(bv->minos, swap)), GXVer(sw32(bv->sdk, swap))];
                break;
            }
            case LC_VERSION_MIN_IPHONEOS: {
                const struct version_min_command *vm = (const void *)lc;
                [s appendFormat:GXL(@"Мин. iOS: %@, SDK %@\n"), GXVer(sw32(vm->version, swap)), GXVer(sw32(vm->sdk, swap))];
                break;
            }
            case LC_ENCRYPTION_INFO: case LC_ENCRYPTION_INFO_64: {
                const struct encryption_info_command *e = (const void *)lc;
                uint32_t id = sw32(e->cryptid, swap);
                [s appendFormat:GXL(@"Шифрование FairPlay: %@\n"), id ? GXL(@"ДА (cryptid=1, файл зашифрован App Store)") : GXL(@"нет (cryptid=0)")];
                break;
            }
            case LC_CODE_SIGNATURE: [s appendString:GXL(@"Подпись кода: есть\n")]; break;
            case LC_MAIN: [s appendString:GXL(@"Точка входа: LC_MAIN\n")]; break;
        }
        off += size;
    }
    if (dylibs.count) [s appendFormat:GXL(@"\nСвязанные библиотеки (%lu):\n  %@\n"), (unsigned long)dylibs.count, [dylibs componentsJoinedByString:@"\n  "]];
    if (rpaths.count) [s appendFormat:@"\nRPATH:\n  %@\n", [rpaths componentsJoinedByString:@"\n  "]];
}

NSString *GXMachOReport(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:nil];
    if (d.length < 8) return GXL(@"Файл слишком мал");
    NSMutableString *s = [NSMutableString stringWithFormat:GXL(@"%@\nРазмер: %@\n\n"), path.lastPathComponent, GXHuman(d.length)];
    uint32_t magic = *(const uint32_t *)d.bytes;
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        BOOL f64 = magic == FAT_CIGAM_64;
        uint32_t n = __builtin_bswap32(((const struct fat_header *)d.bytes)->nfat_arch);
        [s appendFormat:GXL(@"Универсальный (fat) бинарник, срезов: %u\n"), n];
        for (uint32_t i = 0; i < n && i < 16; i++) {
            uint64_t off, size;
            if (f64) {
                const struct fat_arch_64 *a = (const void *)((const uint8_t *)d.bytes + sizeof(struct fat_header) + i * sizeof(struct fat_arch_64));
                if ((const uint8_t *)(a + 1) > (const uint8_t *)d.bytes + d.length) break;
                off = __builtin_bswap64(a->offset); size = __builtin_bswap64(a->size);
            } else {
                const struct fat_arch *a = (const void *)((const uint8_t *)d.bytes + sizeof(struct fat_header) + i * sizeof(struct fat_arch));
                if ((const uint8_t *)(a + 1) > (const uint8_t *)d.bytes + d.length) break;
                off = __builtin_bswap32(a->offset); size = __builtin_bswap32(a->size);
            }
            [s appendFormat:GXL(@"\n━━ Срез %u (смещение 0x%llx, %@) ━━\n"), i + 1, off, GXHuman(size)];
            GXDescribeSlice(d, off, s);
        }
    } else if (magic == MH_MAGIC || magic == MH_MAGIC_64 || magic == MH_CIGAM || magic == MH_CIGAM_64) {
        GXDescribeSlice(d, 0, s);
    } else return GXL(@"Это не Mach-O");
    NSString *ent = GXEntitlementsXML(path);
    [s appendFormat:@"\nEntitlements:\n%@\n", ent ?: GXL(@"(нет)")];
    return s;
}

NSString *GXEntitlementsXML(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:nil];
    if (d.length < 8) return nil;
    uint32_t magic = *(const uint32_t *)d.bytes;
    NSData *e = nil;
    if (magic == FAT_CIGAM) {
        uint32_t n = __builtin_bswap32(((const struct fat_header *)d.bytes)->nfat_arch);
        for (uint32_t i = 0; i < n && !e && i < 16; i++) {
            const struct fat_arch *a = (const void *)((const uint8_t *)d.bytes + sizeof(struct fat_header) + i * sizeof(struct fat_arch));
            if ((const uint8_t *)(a + 1) > (const uint8_t *)d.bytes + d.length) break;
            e = GXEntitlementsFromSlice(d, __builtin_bswap32(a->offset), __builtin_bswap32(a->size));
        }
    } else if (magic == MH_MAGIC_64 || magic == MH_MAGIC) e = GXEntitlementsFromSlice(d, 0, d.length);
    return e ? [[NSString alloc] initWithData:e encoding:NSUTF8StringEncoding] : nil;
}

NSString *GXELFReport(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedAlways error:nil];
    const uint8_t *b = d.bytes;
    if (d.length < 64 || memcmp(b, "\x7f" "ELF", 4)) return GXL(@"Это не ELF");
    NSMutableString *s = [NSMutableString stringWithFormat:GXL(@"%@\nРазмер: %@\n\n"), path.lastPathComponent, GXHuman(d.length)];
    BOOL is64 = b[4] == 2;
    if (b[5] != 1) { [s appendString:GXL(@"Big-endian ELF — подробный разбор не поддерживается\n")]; return s; }
    uint16_t type = *(const uint16_t *)(b + 16), machine = *(const uint16_t *)(b + 18);
    NSString *m = machine == 183 ? @"AArch64 (arm64-v8a)" : machine == 40 ? @"ARM 32-bit (armeabi-v7a)" : machine == 62 ? @"x86_64" : machine == 3 ? @"x86" : [NSString stringWithFormat:GXL(@"машина %u"), machine];
    [s appendFormat:GXL(@"Класс: %@\nАрхитектура: %@\nТип: %@\n"), is64 ? @"ELF64" : @"ELF32", m, type == 3 ? GXL(@"разделяемая библиотека (.so)") : type == 2 ? GXL(@"исполняемый") : [NSString stringWithFormat:@"%u", type]];
    if (machine == 183) [s appendString:GXL(@"64-битный ARM — то же семейство CPU, что у iPhone.\n")];
    else if (machine == 40) [s appendString:GXL(@"32-битный ARM: iPhone такой код выполнить не может.\n")];
    if (!is64) return s;
    uint64_t phoff = *(const uint64_t *)(b + 32);
    uint16_t phentsize = *(const uint16_t *)(b + 54), phnum = *(const uint16_t *)(b + 56);
    uint64_t dynoff = 0, dynsz = 0;
    NSMutableArray *loads = [NSMutableArray array];
    uint64_t maxAlign = 0;
    for (uint16_t i = 0; i < phnum; i++) {
        uint64_t p = phoff + (uint64_t)i * phentsize;
        if (p + 56 > d.length) break;
        uint32_t ptype = *(const uint32_t *)(b + p);
        if (ptype == 2) { dynoff = *(const uint64_t *)(b + p + 8); dynsz = *(const uint64_t *)(b + p + 32); }
        if (ptype == 1) {
            uint64_t al = *(const uint64_t *)(b + p + 48);
            maxAlign = MAX(maxAlign, al);
            [loads addObject:@(al)];
        }
    }
    [s appendFormat:GXL(@"Сегментов LOAD: %lu, макс. выравнивание: 0x%llx%@\n"), (unsigned long)loads.count, maxAlign,
        maxAlign >= 0x4000 ? GXL(@" (совместимо со страницами 16 КБ)") : GXL(@" (страницы 4 КБ)")];
    // DT_NEEDED / DT_SONAME через DT_STRTAB: найдём секцию .dynstr по заголовкам секций
    uint64_t shoff = *(const uint64_t *)(b + 40);
    uint16_t shentsize = *(const uint16_t *)(b + 58), shnum = *(const uint16_t *)(b + 60);
    uint64_t strOff = 0, strSize = 0;
    for (uint16_t i = 0; i < shnum; i++) {
        uint64_t sh = shoff + (uint64_t)i * shentsize;
        if (sh + 64 > d.length) break;
        uint32_t stype = *(const uint32_t *)(b + sh + 4);
        if (stype == 6) { // SHT_DYNAMIC → sh_link = индекс dynstr
            uint32_t link = *(const uint32_t *)(b + sh + 40);
            uint64_t ls = shoff + (uint64_t)link * shentsize;
            if (ls + 64 <= d.length) { strOff = *(const uint64_t *)(b + ls + 24); strSize = *(const uint64_t *)(b + ls + 32); }
            if (!dynoff) { dynoff = *(const uint64_t *)(b + sh + 24); dynsz = *(const uint64_t *)(b + sh + 32); }
        }
    }
    NSMutableArray *needed = [NSMutableArray array];
    NSString *soname = nil;
    if (dynoff && strOff && strOff + strSize <= d.length) {
        for (uint64_t p = dynoff; p + 16 <= dynoff + dynsz && p + 16 <= d.length; p += 16) {
            int64_t tag = *(const int64_t *)(b + p);
            uint64_t val = *(const uint64_t *)(b + p + 8);
            if (tag == 0) break;
            if ((tag == 1 || tag == 14) && val < strSize) {
                NSString *str = [[NSString alloc] initWithBytes:b + strOff + val length:strnlen((const char *)b + strOff + val, (size_t)(strSize - val)) encoding:NSUTF8StringEncoding];
                if (tag == 1) [needed addObject:str ?: @"?"]; else soname = str;
            }
        }
    }
    if (soname) [s appendFormat:@"SONAME: %@\n", soname];
    if (needed.count) [s appendFormat:GXL(@"\nЗависимости (%lu):\n  %@\n"), (unsigned long)needed.count, [needed componentsJoinedByString:@"\n  "]];
    return s;
}

NSData *GXProvisionPlist(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, d.length)];
    NSRange b = [d rangeOfData:[@"</plist>" dataUsingEncoding:NSUTF8StringEncoding] options:NSDataSearchBackwards range:NSMakeRange(0, d.length)];
    if (a.location == NSNotFound || b.location == NSNotFound || b.location < a.location) return nil;
    return [d subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)];
}

#pragma mark - Свойства

@implementation GXInfoVC { NSString *_path; NSMutableArray<NSArray *> *_rows; }
- (instancetype)initWithPath:(NSString *)path { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _path = path; return self; }

static NSString *GXPerm(mode_t m) {
    char s[11];
    s[0] = S_ISDIR(m) ? 'd' : S_ISLNK(m) ? 'l' : '-';
    const char *rwx = "rwxrwxrwx";
    for (int i = 0; i < 9; i++) s[i + 1] = (m & (1 << (8 - i))) ? rwx[i] : '-';
    s[10] = 0;
    return [NSString stringWithFormat:@"%s (%03o)", s, m & 0777];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Свойства");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [self load];
}

- (void)load {
    _rows = [NSMutableArray array];
    struct stat ls, st;
    if (lstat(_path.fileSystemRepresentation, &ls) != 0) { [_rows addObject:@[GXL(@"Ошибка"), GXL(@"Объект не найден")]]; return; }
    BOOL link = S_ISLNK(ls.st_mode);
    BOOL ok = stat(_path.fileSystemRepresentation, &st) == 0;
    BOOL dir = ok && S_ISDIR(st.st_mode);
    GXKind k = GXKindForPath(_path, dir);
    [_rows addObject:@[GXL(@"Имя"), _path.lastPathComponent]];
    [_rows addObject:@[GXL(@"Путь"), _path]];
    [_rows addObject:@[GXL(@"Тип"), link ? [NSString stringWithFormat:GXL(@"Ссылка → %@"), GXKindTitle(k)] : GXKindTitle(k)]];
    if (link) [_rows addObject:@[GXL(@"Ведёт на"), [FM() destinationOfSymbolicLinkAtPath:_path error:nil] ?: @"?"]];
    [_rows addObject:@[GXL(@"Размер"), dir ? GXL(@"Считаю…") : [NSString stringWithFormat:GXL(@"%@ (%lld байт)"), GXHuman((unsigned long long)st.st_size), (long long)st.st_size]]];
    NSDictionary *attrs = [FM() attributesOfItemAtPath:_path error:nil];
    if (attrs.fileCreationDate) [_rows addObject:@[GXL(@"Создан"), [GXDateFmt() stringFromDate:attrs.fileCreationDate]]];
    [_rows addObject:@[GXL(@"Изменён"), [GXDateFmt() stringFromDate:[NSDate dateWithTimeIntervalSince1970:ls.st_mtimespec.tv_sec]]]];
    [_rows addObject:@[GXL(@"Права"), GXPerm(ls.st_mode)]];
    struct passwd *pw = getpwuid(ls.st_uid);
    struct group *gr = getgrgid(ls.st_gid);
    [_rows addObject:@[GXL(@"Владелец"), [NSString stringWithFormat:@"%s (%u) : %s (%u)", pw ? pw->pw_name : "?", ls.st_uid, gr ? gr->gr_name : "?", ls.st_gid]]];
    [_rows addObject:@[GXL(@"Доступ"), [NSString stringWithFormat:GXL(@"чтение %@ · запись %@"), [FM() isReadableFileAtPath:_path] ? GXL(@"да") : GXL(@"нет"), [FM() isWritableFileAtPath:_path] ? GXL(@"да") : GXL(@"нет")]]];
    if (k == GXKindApp) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[_path stringByAppendingPathComponent:@"Info.plist"]];
        if (info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"]) [_rows addObject:@[GXL(@"Приложение"), info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"]]];
        if (info[@"CFBundleIdentifier"]) [_rows addObject:@[@"Bundle ID", info[@"CFBundleIdentifier"]]];
        if (info[@"CFBundleShortVersionString"]) [_rows addObject:@[GXL(@"Версия"), [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"] ?: @"?"]]];
        if (info[@"MinimumOSVersion"]) [_rows addObject:@[GXL(@"Мин. iOS"), info[@"MinimumOSVersion"]]];
    }
    if (!dir) [_rows addObject:@[GXL(@"Контрольные суммы"), GXL(@"Нажмите, чтобы посчитать MD5 / SHA-1 / SHA-256"), @"hash"]];
    [_rows addObject:@[GXL(@"Изменить права (chmod)"), GXL(@"Например 755 или 644"), @"chmod"]];
    if (dir) {
        NSString *p = _path;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            unsigned long long total = 0, files = 0, dirs = 0;
            NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:p] includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey, NSURLIsDirectoryKey] options:0 errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
            for (NSURL *u in en) {
                NSNumber *isd, *sz;
                [u getResourceValue:&isd forKey:NSURLIsDirectoryKey error:nil];
                if (isd.boolValue) { dirs++; continue; }
                [u getResourceValue:&sz forKey:NSURLTotalFileAllocatedSizeKey error:nil];
                total += sz.unsignedLongLongValue;
                files++;
            }
            NSString *txt = [NSString stringWithFormat:GXL(@"%@ · файлов %llu, папок %llu"), GXHuman(total), files, dirs];
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSUInteger i = 0; i < self->_rows.count; i++) if ([self->_rows[i][0] isEqualToString:GXL(@"Размер")]) self->_rows[i] = @[GXL(@"Размер"), txt];
                [self.tableView reloadData];
            });
        });
    }
    [self.tableView reloadData];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return GXL(@"Нажмите на строку, чтобы скопировать значение."); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"i"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"i"];
    NSArray *r = _rows[ip.row];
    BOOL action = r.count > 2;
    c.textLabel.text = r[0];
    c.textLabel.font = action ? [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:13];
    c.textLabel.textColor = action ? self.view.tintColor : UIColor.secondaryLabelColor;
    c.detailTextLabel.text = r[1];
    c.detailTextLabel.font = action ? [UIFont systemFontOfSize:13] : [UIFont systemFontOfSize:16];
    c.detailTextLabel.textColor = action ? UIColor.secondaryLabelColor : UIColor.labelColor;
    c.detailTextLabel.numberOfLines = 0;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *r = _rows[ip.row];
    if (r.count > 2 && [r[2] isEqualToString:@"hash"]) {
        NSString *p = _path;
        NSUInteger row = ip.row;
        _rows[row] = @[GXL(@"Контрольные суммы"), GXL(@"Считаю…"), @"busy"];
        [tv reloadData];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *t = [NSString stringWithFormat:@"MD5: %@\nSHA-1: %@\nSHA-256: %@", GXHashFile(p, @"md5"), GXHashFile(p, @"sha1"), GXHashFile(p, @"sha256")];
            dispatch_async(dispatch_get_main_queue(), ^{ self->_rows[row] = @[GXL(@"Контрольные суммы"), t]; [self.tableView reloadData]; });
        });
        return;
    }
    if (r.count > 2 && [r[2] isEqualToString:@"chmod"]) {
        struct stat st;
        lstat(_path.fileSystemRepresentation, &st);
        GXPrompt(self, GXL(@"Права доступа"), GXL(@"Восьмеричное значение"), [NSString stringWithFormat:@"%03o", st.st_mode & 0777], nil, GXL(@"Применить"), ^(NSString *v) {
            unsigned long m = strtoul(v.UTF8String, NULL, 8);
            if (chmod(self->_path.fileSystemRepresentation, (mode_t)(m & 07777)) != 0) GXAlert(self, GXL(@"Не удалось"), @(strerror(errno)));
            [self load];
        });
        return;
    }
    if (r.count > 2) return;
    UIPasteboard.generalPasteboard.string = r[1];
    GXToast(self.view, GXL(@"Скопировано"));
}
@end

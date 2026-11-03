// APK/XAPK/APKM/APKS и IPA: сведения о пакете
#import "GXCore.h"
#include <sys/stat.h>
#include <fcntl.h>
#include "core/gx_zip.h"
#include "core/gx_apk.h"

#pragma mark - Экран APK

@interface GXApkVC ()
@end

@implementation GXApkVC {
    NSString *_path;
    BOOL _bundle;
    gx_apk_info _info;
    BOOL _hasInfo;
    UIImage *_icon;
    NSArray<NSString *> *_parts;     // состав бандла
    NSString *_baseTemp;             // путь к базовому APK (для бандла)
    uint64_t _baseOff, _baseSize;
    NSString *_basePath;
    BOOL _splitRequired;
    NSArray<NSArray *> *_sections;   // [[title, rows:[[title, detail, action]]]]
    NSString *_xapkName;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _path = path;
        _bundle = ![path.pathExtension.lowercaseString isEqualToString:@"apk"];
    }
    return self;
}

- (void)dealloc { if (_hasInfo) gx_apk_free(&_info); }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    [GXHUD showIn:self.view text:GXL(@"Анализ пакета…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self analyze];
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            [self buildHeader];
            [self buildSections];
        });
    });
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)analyze {
    if (!_bundle) {
        _basePath = _path;
        _hasInfo = gx_apk_analyze(_path.fileSystemRepresentation, 0, 0, &_info) != 0;
        _icon = [GXIcons apkIcon:_path base:0 size:0];
    } else {
        gxz z;
        if (!gxz_open(&z, _path.fileSystemRepresentation, 0, 0)) { memset(&_info, 0, sizeof _info); snprintf(_info.error, sizeof _info.error, "%s", z.err); return; }
        NSMutableArray *parts = [NSMutableArray array];
        long base = -1;
        uint64_t best = 0;
        NSMutableArray<NSNumber *> *apkIdx = [NSMutableArray array];
        for (size_t i = 0; i < z.n; i++) {
            NSString *n = @(z.e[i].name);
            NSString *b = n.lastPathComponent.lowercaseString;
            if ([b hasSuffix:@".apk"] || [b hasSuffix:@".obb"]) [parts addObject:[NSString stringWithFormat:@"%@ · %@", n, GXHuman(z.e[i].usize)]];
            if (![b hasSuffix:@".apk"]) continue;
            [apkIdx addObject:@(i)];
            if ([b isEqualToString:@"base.apk"] || [b isEqualToString:@"base-master.apk"]) { base = (long)i; best = UINT64_MAX; }
            else if (best != UINT64_MAX && ![b hasPrefix:@"config."] && ![b hasPrefix:@"split_"] && z.e[i].usize > best) { best = z.e[i].usize; base = (long)i; }
        }
        _parts = parts;
        // manifest.json у XAPK
        long mj = gxz_find(&z, "manifest.json");
        if (mj >= 0) {
            uint8_t *d; size_t n;
            if (gxz_read(&z, &z.e[mj], 4 << 20, &d, &n)) {
                id j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:d length:n freeWhenDone:YES] options:0 error:nil];
                if ([j isKindOfClass:NSDictionary.class] && [j[@"name"] isKindOfClass:NSString.class]) _xapkName = j[@"name"];
            }
        }
        // анализируем каждый APK (stored — через смещение, deflate — через временный файл)
        BOOL first = YES;
        for (NSNumber *ix in apkIdx) {
            const gxz_entry *e = &z.e[ix.longValue];
            NSString *apath = _path;
            uint64_t off = 0, size = 0;
            if (e->method == 0) { if (!gxz_data_offset(&z, e, &off)) continue; size = e->csize; }
            else {
                apath = [GXTempDir() stringByAppendingPathComponent:@(e->name).lastPathComponent];
                int fd = open(apath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (fd < 0) continue;
                BOOL ok = gxz_extract_fd(&z, e, fd, NULL);
                close(fd);
                if (!ok) continue;
            }
            gx_apk_info part;
            if (!gx_apk_analyze(apath.fileSystemRepresentation, off, size, &part)) continue;
            if (ix.longValue == base || (first && base < 0)) {
                if (_hasInfo) { gx_apk_info tmp = _info; _info = part; gx_apk_merge_split(&_info, &tmp); gx_apk_free(&tmp); }
                else _info = part;
                _hasInfo = YES;
                _basePath = apath; _baseOff = off; _baseSize = size;
            } else {
                if (_hasInfo) { gx_apk_merge_split(&_info, &part); gx_apk_free(&part); }
                else { _info = part; _hasInfo = YES; }
            }
            first = NO;
        }
        gxz_close(&z);
        if (_basePath) {
            _icon = [GXIcons apkIcon:_basePath base:_baseOff size:_baseSize];
            if (!_icon) {
                gxz z2;
                if (gxz_open(&z2, _path.fileSystemRepresentation, 0, 0)) {
                    long ic = gxz_find(&z2, "icon.png");
                    uint8_t *d; size_t n;
                    if (ic >= 0 && gxz_read(&z2, &z2.e[ic], 8 << 20, &d, &n)) _icon = [UIImage imageWithData:[NSData dataWithBytesNoCopy:d length:n freeWhenDone:YES]];
                    gxz_close(&z2);
                }
            }
        }
    }
    if (_basePath) {
        char *t = gx_apk_manifest_text(_basePath.fileSystemRepresentation, _baseOff, _baseSize);
        if (t) {
            _splitRequired = strstr(t, "isSplitRequired=\"true\"") || strstr(t, "com.android.vending.splits.required");
            free(t);
        }
    }
}

- (void)buildHeader {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 14, 84, 84)];
    iv.center = CGPointMake(h.bounds.size.width / 2, 56);
    iv.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    iv.image = _icon ? GXSquareImage(_icon, 84, 19) : GXSymbolTile(@"shippingbox.fill", UIColor.systemGreenColor, 84);
    [h addSubview:iv];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 102, h.bounds.size.width - 32, 24)];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    t.text = _info.label[0] ? @(_info.label) : (_xapkName ?: _path.lastPathComponent.stringByDeletingPathExtension);
    [h addSubview:t];
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, 126, h.bounds.size.width - 32, 18)];
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    s.textAlignment = NSTextAlignmentCenter;
    s.font = [UIFont systemFontOfSize:13];
    s.textColor = UIColor.secondaryLabelColor;
    s.text = _info.package[0] ? @(_info.package) : (_info.error[0] ? @(_info.error) : @"");
    [h addSubview:s];
    self.tableView.tableHeaderView = h;
}

- (NSString *)abiText {
    NSMutableArray *a = [NSMutableArray array];
    if (_info.abi_arm64) [a addObject:@"arm64-v8a ✅"];
    if (_info.abi_v7a) [a addObject:@"armeabi-v7a"];
    if (_info.abi_armeabi) [a addObject:@"armeabi"];
    if (_info.abi_x86_64) [a addObject:@"x86_64"];
    if (_info.abi_x86) [a addObject:@"x86"];
    return a.count ? [a componentsJoinedByString:@", "] : GXL(@"нет нативного кода (только Java/Kotlin)");
}

- (void)buildSections {
    NSMutableArray *secs = [NSMutableArray array];
    NSMutableArray *pkg = [NSMutableArray array];
    struct stat st;
    stat(_path.fileSystemRepresentation, &st);
    if (_info.version_name[0] || _info.version_code) [pkg addObject:@[GXL(@"Версия"), [NSString stringWithFormat:@"%s (%d)", _info.version_name, _info.version_code], @""]];
    if (_info.min_sdk) [pkg addObject:@[@"Android SDK", [NSString stringWithFormat:GXL(@"мин. %d · целевой %d"), _info.min_sdk, _info.target_sdk], @""]];
    [pkg addObject:@[GXL(@"Размер"), [NSString stringWithFormat:GXL(@"%@ · распаковано %@ · файлов %llu"), GXHuman((unsigned long long)st.st_size), GXHuman(_info.unpacked_bytes), _info.entries], @""]];
    if (_info.main_activity[0]) [pkg addObject:@[GXL(@"Главная activity"), @(_info.main_activity), @""]];
    if (_parts.count) [pkg addObject:@[[NSString stringWithFormat:GXL(@"Состав пакета (%lu)"), (unsigned long)_parts.count], [_parts componentsJoinedByString:@"\n"], @""]];
    [secs addObject:@[GXL(@"Пакет"), pkg]];

    NSMutableArray *code = [NSMutableArray array];
    const char *eng = gx_apk_engine(&_info);
    [code addObject:@[GXL(@"Движок"), eng ? @(eng) : (_info.dex_count ? GXL(@"Java/Kotlin (без игрового движка)") : GXL(@"не определён")), @""]];
    [code addObject:@[GXL(@"Архитектуры (ABI)"), [self abiText], @""]];
    [code addObject:@[GXL(@"Код DEX"), [NSString stringWithFormat:GXL(@"%d файлов · %@"), _info.dex_count, GXHuman(_info.dex_bytes)], @""]];
    if (_info.lib_count) [code addObject:@[[NSString stringWithFormat:GXL(@"Нативные библиотеки (%d)"), _info.lib_count], GXL(@"Нажмите для списка"), @"libs"]];
    if (_info.nperm) [code addObject:@[[NSString stringWithFormat:GXL(@"Разрешения (%d)"), _info.nperm], GXL(@"Нажмите для списка"), @"perms"]];
    [secs addObject:@[GXL(@"Код"), code]];

    NSMutableArray *acts = [NSMutableArray array];
    if (_basePath) [acts addObject:@[@"AndroidManifest.xml", GXL(@"Расшифрованный манифест"), @"manifest"]];
    BOOL v1 = NO, v2 = NO;
    if (!_bundle) GXAPKSigInfo(_path, &v1, &v2);
    [acts addObject:@[GXL(@"Редактировать без распаковки"), GXL(@"Файлы внутри APK: править, заменять, добавлять, удалять"), @"archive"]];
    [acts addObject:@[GXL(@"Найти и заменить внутри"), GXL(@"Текст или hex во всех файлах пакета"), @"find"]];
    if (!_bundle) [acts addObject:@[GXL(@"Подписать APK"), [NSString stringWithFormat:GXL(@"Сейчас: v1 %@ · v2 %@"), v1 ? GXL(@"есть") : GXL(@"нет"), v2 ? GXL(@"есть") : GXL(@"нет")], @"sign"]];
    if (_bundle) [acts addObject:@[GXL(@"Распаковать APK из пакета"), GXL(@"base.apk и split-файлы — рядом"), @"unpack"]];
    if (_icon) [acts addObject:@[GXL(@"Сохранить иконку"), GXL(@"PNG рядом с файлом"), @"icon"]];
    [acts addObject:@[GXL(@"Поделиться"), GXL(@"Отправить файл"), @"share"]];
    [secs addObject:@[GXL(@"Действия"), acts]];
    _sections = secs;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sections[s][0]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [_sections[s][1] count]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"x"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"x"];
    NSArray *r = _sections[ip.section][1][ip.row];
    NSString *act = r[2];
    c.textLabel.text = r[0];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = r[1];
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL tappable = act.length && ![act isEqualToString:@"verdict"];
    c.textLabel.font = [act isEqualToString:@"verdict"] ? [UIFont systemFontOfSize:17 weight:UIFontWeightBold] : tappable ? [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:13];
    c.textLabel.textColor = tappable ? self.view.tintColor : [act isEqualToString:@"verdict"] ? r[4] : UIColor.secondaryLabelColor;
    if (!tappable && ![act isEqualToString:@"verdict"] && r.count < 4) { c.detailTextLabel.textColor = UIColor.labelColor; c.detailTextLabel.font = [UIFont systemFontOfSize:15]; }
    else c.detailTextLabel.font = [UIFont systemFontOfSize:13];
    c.imageView.image = r.count >= 5 ? GXSymbolTile(r[3], r[4], 30) : nil;
    c.selectionStyle = tappable ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *act = _sections[ip.section][1][ip.row][2];
    if ([act isEqualToString:@"libs"]) {
        NSMutableString *s = [NSMutableString string];
        for (int i = 0; i < _info.lib_count; i++) [s appendFormat:@"%s  ·  %@\n", _info.libs[i], GXHuman(_info.lib_sizes[i])];
        [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:GXL(@"Библиотеки") text:s] animated:YES];
    } else if ([act isEqualToString:@"perms"]) {
        NSMutableString *s = [NSMutableString string];
        for (int i = 0; i < _info.nperm; i++) [s appendFormat:@"%s\n", _info.perms[i]];
        [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:GXL(@"Разрешения") text:s] animated:YES];
    } else if ([act isEqualToString:@"manifest"]) {
        char *t = gx_apk_manifest_text(_basePath.fileSystemRepresentation, _baseOff, _baseSize);
        if (!t) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось прочитать манифест")); return; }
        GXTextEditorVC *ed = [[GXTextEditorVC alloc] initWithText:@(t) title:@"AndroidManifest.xml"];
        free(t);
        ed.highlightExt = @"xml";
        [self.navigationController pushViewController:ed animated:YES];
    } else if ([act isEqualToString:@"find"]) {
        [self.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:_path] animated:YES];
    } else if ([act isEqualToString:@"sign"]) {
        NSString *p = _path;
        GXRunBG(self, GXL(@"Подписываю…"), ^NSString *{ return GXSignAPK(p, p, ^(double x) { [GXHUD setProgress:x]; }); },
                ^{ GXToast(self.view, GXL(@"APK подписан (v1 + v2)")); [self buildSections]; });
    } else if ([act isEqualToString:@"archive"]) {
        [self.navigationController pushViewController:[[GXArchiveVC alloc] initWithArchive:_path] animated:YES];
    } else if ([act isEqualToString:@"unpack"]) {
        NSString *dest = GXUniquePath(_path.stringByDeletingLastPathComponent, [_path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@" (APK)"]);
        NSString *p = _path;
        GXRunBG(self, GXL(@"Распаковка…"), ^NSString *{
            gxz z;
            if (!gxz_open(&z, p.fileSystemRepresentation, 0, 0)) return @(z.err);
            NSMutableArray *names = [NSMutableArray array];
            for (size_t i = 0; i < z.n; i++) {
                NSString *n = @(z.e[i].name).lowercaseString;
                if ([n hasSuffix:@".apk"] || [n hasSuffix:@".obb"]) [names addObject:@(z.e[i].name)];
            }
            gxz_close(&z);
            return GXZipExtractEntries(p, names, dest, YES);
        }, ^{ GXToast(self.view, [NSString stringWithFormat:GXL(@"Готово: «%@»"), dest.lastPathComponent]); });
    } else if ([act isEqualToString:@"icon"]) {
        NSString *dest = GXUniquePath(_path.stringByDeletingLastPathComponent, [_path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@" icon.png"]);
        if ([UIImagePNGRepresentation(_icon) writeToFile:dest atomically:YES]) GXToast(self.view, GXL(@"Иконка сохранена"));
    } else if ([act isEqualToString:@"share"]) {
        UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:_path]] applicationActivities:nil];
        a.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
    }
}

@end

#pragma mark - IPA

@implementation GXIpaVC {
    NSString *_path;
    NSDictionary *_info;
    UIImage *_icon;
    NSString *_appDir;
    NSArray<NSArray *> *_rows;
    unsigned long long _unpacked;
    NSUInteger _entries;
}
- (instancetype)initWithPath:(NSString *)path { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _path = path; return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    gxz z;
    if (gxz_open(&z, _path.fileSystemRepresentation, 0, 0)) {
        _entries = z.n;
        for (size_t i = 0; i < z.n; i++) {
            _unpacked += z.e[i].usize;
            NSArray *c = @(z.e[i].name).pathComponents;
            if (!_info && c.count == 3 && [c[0] isEqualToString:@"Payload"] && [c[1] hasSuffix:@".app"] && [c[2] isEqualToString:@"Info.plist"]) {
                uint8_t *d; size_t n;
                if (gxz_read(&z, &z.e[i], 8 << 20, &d, &n))
                    _info = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytesNoCopy:d length:n freeWhenDone:YES] options:0 format:nil error:nil];
                _appDir = c[1];
            }
        }
        gxz_close(&z);
    }
    _icon = [GXIcons ipaIcon:_path];
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 130)];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 12, 80, 80)];
    iv.center = CGPointMake(h.bounds.size.width / 2, 52);
    iv.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    iv.image = _icon ? GXSquareImage(_icon, 80, 18) : GXSymbolTile(@"app.badge.fill", UIColor.systemBlueColor, 80);
    [h addSubview:iv];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 98, h.bounds.size.width - 32, 26)];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    t.textAlignment = NSTextAlignmentCenter;
    t.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    t.text = _info[@"CFBundleDisplayName"] ?: _info[@"CFBundleName"] ?: _path.lastPathComponent;
    [h addSubview:t];
    self.tableView.tableHeaderView = h;
    NSMutableArray *r = [NSMutableArray array];
    if (_info[@"CFBundleIdentifier"]) [r addObject:@[@"Bundle ID", _info[@"CFBundleIdentifier"], @""]];
    if (_info[@"CFBundleShortVersionString"]) [r addObject:@[GXL(@"Версия"), [NSString stringWithFormat:@"%@ (%@)", _info[@"CFBundleShortVersionString"], _info[@"CFBundleVersion"] ?: @"?"], @""]];
    if (_info[@"MinimumOSVersion"]) [r addObject:@[GXL(@"Мин. iOS"), _info[@"MinimumOSVersion"], @""]];
    struct stat st;
    stat(_path.fileSystemRepresentation, &st);
    [r addObject:@[GXL(@"Размер"), [NSString stringWithFormat:GXL(@"%@ · распаковано %@ · файлов %lu"), GXHuman((unsigned long long)st.st_size), GXHuman(_unpacked), (unsigned long)_entries], @""]];
    if (_info[@"CFBundleExecutable"]) [r addObject:@[GXL(@"Исполняемый файл"), _info[@"CFBundleExecutable"], @""]];
    if (!_info) [r addObject:@[GXL(@"Внимание"), GXL(@"Не найден Payload/*.app/Info.plist — это не похоже на IPA"), @""]];
    [r addObject:@[GXL(@"Установить в LiveContainer"), GXL(@"Поделиться → LiveContainer (откроется установка)"), @"share"]];
    [r addObject:@[GXL(@"Распаковать .app рядом"), GXL(@"Папка Payload с бандлом"), @"unpack"]];
    [r addObject:@[GXL(@"Инструменты приложения"), GXL(@"Название, bundle ID, иконка, ограничения устройств, расширения, внедрение dylib"), @"tools"]];
    [r addObject:@[GXL(@"Редактировать без распаковки"), GXL(@"Info.plist, ресурсы, любые файлы внутри IPA"), @"archive"]];
    [r addObject:@[GXL(@"Найти и заменить внутри"), GXL(@"Текст или hex во всех файлах IPA"), @"find"]];
    if (_info) [r addObject:@[@"Info.plist", GXL(@"Просмотр всех ключей"), @"plist"]];
    _rows = r;
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"x"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"x"];
    NSArray *r = _rows[ip.row];
    BOOL act = [r[2] length] > 0;
    c.textLabel.text = r[0];
    c.textLabel.textColor = act ? self.view.tintColor : UIColor.secondaryLabelColor;
    c.textLabel.font = act ? [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:13];
    c.detailTextLabel.text = r[1];
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.textColor = act ? UIColor.secondaryLabelColor : UIColor.labelColor;
    c.detailTextLabel.font = act ? [UIFont systemFontOfSize:13] : [UIFont systemFontOfSize:15];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *a = _rows[ip.row][2];
    if ([a isEqualToString:@"share"]) {
        UIActivityViewController *v = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:_path]] applicationActivities:nil];
        v.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
        [self presentViewController:v animated:YES completion:nil];
    } else if ([a isEqualToString:@"unpack"]) {
        NSString *dest = GXUniquePath(_path.stringByDeletingLastPathComponent, _path.lastPathComponent.stringByDeletingPathExtension);
        NSString *p = _path;
        [GXHUD showCancellableIn:self.view text:GXL(@"Распаковка…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *err = GXArchiveExtractAll(p, dest, ^(double x) { [GXHUD setProgress:x]; });
            dispatch_async(dispatch_get_main_queue(), ^{
                [GXHUD hide];
                if (err) GXAlert(self, GXL(@"Ошибки распаковки"), err); else GXToast(self.view, [NSString stringWithFormat:GXL(@"Распаковано в «%@»"), dest.lastPathComponent]);
            });
        });
    } else if ([a isEqualToString:@"find"]) {
        [self.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:_path] animated:YES];
    } else if ([a isEqualToString:@"tools"]) {
        [self.navigationController pushViewController:[[GXIpaToolsVC alloc] initWithPath:_path] animated:YES];
    } else if ([a isEqualToString:@"archive"]) {
        [self.navigationController pushViewController:[[GXArchiveVC alloc] initWithArchive:_path] animated:YES];
    } else if ([a isEqualToString:@"plist"]) {
        NSData *d = [NSPropertyListSerialization dataWithPropertyList:_info format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        GXTextEditorVC *ed = [[GXTextEditorVC alloc] initWithText:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"" title:@"Info.plist"];
        ed.highlightExt = @"xml";
        [self.navigationController pushViewController:ed animated:YES];
    }
}
@end

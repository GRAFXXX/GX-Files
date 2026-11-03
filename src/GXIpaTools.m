// Инструменты IPA и .app: имя, bundle ID, версия, иконка, ограничения, расширения, внедрение dylib, entitlements
#import "GXCore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "core/gx_zip.h"
#include "core/gx_macho.h"

@interface GXIpaToolsVC () <UIDocumentPickerDelegate>
@end

@implementation GXIpaToolsVC {
    NSString *_path;      // .ipa или .app
    BOOL _isIPA;
    NSString *_app;       // "Payload/X.app/" для IPA, "" для .app на диске
    NSMutableDictionary *_info;
    NSPropertyListFormat _fmt;
    NSArray<NSArray *> *_sections;
    NSString *_pickFor;   // @"icon" / @"dylib"
    BOOL _encrypted;
}

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _path = path;
        _isIPA = !GXIsDir(path);
    }
    return self;
}

#pragma mark Доступ к файлам приложения

- (NSString *)findApp {
    if (!_isIPA) return @"";
    gxz z;
    if (!gxz_open(&z, _path.fileSystemRepresentation, 0, 0)) return nil;
    NSString *r = nil;
    for (size_t i = 0; i < z.n && !r; i++) {
        NSArray *c = [@(z.e[i].name) componentsSeparatedByString:@"/"];
        if (c.count >= 3 && [c[0] isEqualToString:@"Payload"] && [c[1] hasSuffix:@".app"]) r = [NSString stringWithFormat:@"Payload/%@/", c[1]];
    }
    gxz_close(&z);
    return r;
}

- (NSData *)read:(NSString *)rel {
    if (!_isIPA) return [NSData dataWithContentsOfFile:[_path stringByAppendingPathComponent:rel]];
    gxz z;
    if (!gxz_open(&z, _path.fileSystemRepresentation, 0, 0)) return nil;
    NSData *d = nil;
    long i = gxz_find(&z, [_app stringByAppendingString:rel].UTF8String);
    uint8_t *b; size_t n;
    if (i >= 0 && gxz_read(&z, &z.e[i], 1u << 30, &b, &n)) d = [NSData dataWithBytesNoCopy:b length:n freeWhenDone:YES];
    gxz_close(&z);
    return d;
}

- (NSArray<NSString *> *)entriesUnder:(NSString *)rel {
    NSMutableArray *r = [NSMutableArray array];
    if (!_isIPA) {
        NSString *full = [_path stringByAppendingPathComponent:rel];
        if ([FM() fileExistsAtPath:full]) [r addObject:rel];
        return r;
    }
    NSString *pre = [_app stringByAppendingString:rel];
    gxz z;
    if (!gxz_open(&z, _path.fileSystemRepresentation, 0, 0)) return r;
    for (size_t i = 0; i < z.n; i++) {
        NSString *n = @(z.e[i].name);
        if ([n isEqualToString:pre] || [n hasPrefix:[pre stringByAppendingString:@"/"]] || [n isEqualToString:[pre stringByAppendingString:@"/"]]) [r addObject:n];
    }
    gxz_close(&z);
    return r;
}

// changes: rel → NSData (записать) или NSNull (удалить файл/папку)
- (void)write:(NSDictionary<NSString *, id> *)changes title:(NSString *)title done:(void (^)(void))done {
    if (!_isIPA) {
        NSMutableString *errs = [NSMutableString string];
        for (NSString *rel in changes) {
            NSString *full = [_path stringByAppendingPathComponent:rel];
            NSError *e;
            if (changes[rel] == [NSNull null]) { [FM() removeItemAtPath:full error:nil]; continue; }
            [FM() createDirectoryAtPath:full.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![changes[rel] writeToFile:full options:NSDataWritingAtomic error:&e]) [errs appendFormat:@"%@: %@\n", rel, e.localizedDescription];
        }
        if (errs.length) GXAlert(self, GXL(@"Ошибки"), errs);
        [self load];
        if (done) done();
        return;
    }
    NSMutableArray *ops = [NSMutableArray array];
    for (NSString *rel in changes) {
        if (changes[rel] == [NSNull null]) { for (NSString *n in [self entriesUnder:rel]) [ops addObject:@{@"name": n, @"del": @YES}]; }
        else [ops addObject:@{@"name": [_app stringByAppendingString:rel], @"data": changes[rel]}];
    }
    if (!ops.count) { GXToast(self.view, GXL(@"Нечего менять")); return; }
    [[GXArcModel modelFor:_path] apply:ops from:self title:title done:^(BOOL ok) {
        if (!ok) return;
        [self load];
        GXToast(self.view, GXL(@"Сохранено в IPA"));
        if (done) done();
    }];
}

- (NSData *)plistData:(id)obj {
    return [NSPropertyListSerialization dataWithPropertyList:obj format:_fmt == NSPropertyListBinaryFormat_v1_0 ? NSPropertyListBinaryFormat_v1_0 : NSPropertyListXMLFormat_v1_0 options:0 error:nil];
}

- (void)saveInfo:(NSString *)title { [self write:@{@"Info.plist": [self plistData:_info]} title:title done:nil]; }

#pragma mark Экран

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Инструменты приложения");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    _app = [self findApp];
    [self load];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSString *)exeName { return [_info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? _info[@"CFBundleExecutable"] : nil; }

- (void)load {
    if (!_app) { _sections = @[@[GXL(@"Ошибка"), @[@[GXL(@"Не найден Payload/*.app"), @"", @""]]]]; [self.tableView reloadData]; return; }
    NSData *d = [self read:@"Info.plist"];
    NSPropertyListFormat f = NSPropertyListXMLFormat_v1_0;
    id pl = d ? [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainersAndLeaves format:&f error:nil] : nil;
    _info = [pl isKindOfClass:NSDictionary.class] ? pl : [NSMutableDictionary dictionary];
    _fmt = f;
    NSString *(^s)(NSString *) = ^NSString *(NSString *k) { id v = self->_info[k]; return [v isKindOfClass:NSString.class] ? v : (v ? [v description] : @"—"); };
    NSMutableArray *secs = [NSMutableArray array];
    [secs addObject:@[@"Info.plist", @[
        @[GXL(@"Название"), s(@"CFBundleDisplayName").length > 1 ? s(@"CFBundleDisplayName") : s(@"CFBundleName"), @"name"],
        @[@"Bundle ID", s(@"CFBundleIdentifier"), @"bid"],
        @[GXL(@"Версия"), [NSString stringWithFormat:@"%@ (%@)", s(@"CFBundleShortVersionString"), s(@"CFBundleVersion")], @"ver"],
        @[GXL(@"Минимальная iOS"), s(@"MinimumOSVersion"), @"minos"],
        @[GXL(@"Открыть Info.plist целиком"), GXL(@"Все ключи — в редакторе"), @"plist"]]]];
    BOOL share = [_info[@"UIFileSharingEnabled"] boolValue];
    [secs addObject:@[GXL(@"Изменения"), @[
        @[GXL(@"Сменить иконку…"), GXL(@"Картинка из «Файлов» или из буфера GX Files"), @"icon"],
        @[GXL(@"Убрать ограничения устройств"), GXL(@"UISupportedDevices, UIRequiredDeviceCapabilities → только arm64, отключить проверку iPad/iPhone"), @"devices"],
        @[share ? GXL(@"Общий доступ к файлам: включён") : GXL(@"Включить доступ к файлам"), GXL(@"Папка приложения появится в «Файлах» (UIFileSharingEnabled)"), @"sharing"],
        @[GXL(@"Удалить расширения и Watch"), GXL(@"PlugIns, Extensions, Watch — меньше размер, меньше проблем при установке"), @"plugins"],
        @[GXL(@"Удалить URL-схемы и запросы схем"), @"CFBundleURLTypes / LSApplicationQueriesSchemes", @"schemes"]]]];
    NSString *exe = [self exeName];
    [secs addObject:@[GXL(@"Исполняемый файл"), @[
        @[GXL(@"Внедрить dylib / твик…"), GXL(@"Скопировать в Frameworks и добавить LC_LOAD_DYLIB (@rpath)"), @"inject"],
        @[GXL(@"Библиотеки и команды загрузки"), GXL(@"Список; смахните влево, чтобы удалить"), @"dylibs"],
        @[@"Entitlements", GXL(@"Права из подписи исполняемого файла"), @"ents"],
        @[GXL(@"Сведения Mach-O"), exe ?: @"—", @"macho"]]]];
    if (_isIPA) [secs addObject:@[GXL(@"Файл"), @[
        @[GXL(@"Сделать копию IPA"), GXL(@"Перед рискованными правками"), @"dup"],
        @[GXL(@"Открыть содержимое"), GXL(@"Редактирование файлов внутри"), @"browse"]]]];
    _sections = secs;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _sections[s][0]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [_sections[s][1] count]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if ([_sections[s][0] isEqualToString:GXL(@"Исполняемый файл")])
        return GXL(@"Внедрение работает для приложений без шифрования App Store. Твикам, которым нужен CydiaSubstrate/ElleKit, он тоже нужен в Frameworks. LiveContainer умеет подключать твики сам (папка Tweaks) — там бинарник менять не нужно. LiveContainer переподписывает приложение при установке.");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"t"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"t"];
    NSArray *r = _sections[ip.section][1][ip.row];
    c.textLabel.text = r[0];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    c.textLabel.textColor = self.view.tintColor;
    c.detailTextLabel.text = r[1];
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}

- (void)editKey:(NSString *)key title:(NSString *)title extraKey:(NSString *)k2 {
    GXPrompt(self, title, nil, [_info[key] isKindOfClass:NSString.class] ? _info[key] : @"", nil, GXL(@"Сохранить"), ^(NSString *v) {
        v = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!v.length) return;
        self->_info[key] = v;
        if (k2) self->_info[k2] = v;
        [self saveInfo:GXL(@"Сохраняю Info.plist…")];
    });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *a = _sections[ip.section][1][ip.row][2];
    if ([a isEqualToString:@"name"]) [self editKey:@"CFBundleDisplayName" title:GXL(@"Название приложения") extraKey:@"CFBundleName"];
    else if ([a isEqualToString:@"bid"]) [self editKey:@"CFBundleIdentifier" title:@"Bundle ID" extraKey:nil];
    else if ([a isEqualToString:@"minos"]) [self editKey:@"MinimumOSVersion" title:GXL(@"Минимальная версия iOS") extraKey:nil];
    else if ([a isEqualToString:@"ver"]) {
        GXPrompt(self, GXL(@"Версия"), GXL(@"Формат: 1.2.3 (45)"), [NSString stringWithFormat:@"%@ (%@)", _info[@"CFBundleShortVersionString"] ?: @"1.0", _info[@"CFBundleVersion"] ?: @"1"], nil, GXL(@"Сохранить"), ^(NSString *v) {
            NSArray *p = [v componentsSeparatedByString:@"("];
            NSString *ver = [p[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (ver.length) self->_info[@"CFBundleShortVersionString"] = ver;
            if (p.count > 1) self->_info[@"CFBundleVersion"] = [[p[1] stringByReplacingOccurrencesOfString:@")" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            [self saveInfo:GXL(@"Сохраняю Info.plist…")];
        });
    } else if ([a isEqualToString:@"plist"]) {
        if (_isIPA) {
            GXArcModel *m = [GXArcModel modelFor:_path];
            if (!m.entries.count) [m reload];
            GXArcEntry *e = [m entryNamed:[_app stringByAppendingString:@"Info.plist"]];
            if (e) [m openEntry:e from:self];
        } else [GXOpener open:[_path stringByAppendingPathComponent:@"Info.plist"] from:self];
    } else if ([a isEqualToString:@"devices"]) {
        [_info removeObjectForKey:@"UISupportedDevices"];
        _info[@"UIRequiredDeviceCapabilities"] = @[@"arm64"];
        _info[@"UIDeviceFamily"] = @[@1, @2];
        [_info removeObjectForKey:@"UIRequiresFullScreen"];
        [_info removeObjectForKey:@"LSRequiresIPhoneOS"];
        _info[@"LSRequiresIPhoneOS"] = @YES;
        [self saveInfo:GXL(@"Убираю ограничения…")];
    } else if ([a isEqualToString:@"sharing"]) {
        _info[@"UIFileSharingEnabled"] = @YES;
        _info[@"LSSupportsOpeningDocumentsInPlace"] = @YES;
        [self saveInfo:GXL(@"Включаю доступ к файлам…")];
    } else if ([a isEqualToString:@"schemes"]) {
        [_info removeObjectForKey:@"CFBundleURLTypes"];
        [_info removeObjectForKey:@"LSApplicationQueriesSchemes"];
        [self saveInfo:GXL(@"Сохраняю…")];
    } else if ([a isEqualToString:@"plugins"]) {
        GXConfirm(self, GXL(@"Удалить расширения?"), GXL(@"Будут удалены папки PlugIns, Extensions и Watch внутри приложения. Виджеты, клавиатуры и часы перестанут работать."), GXL(@"Удалить"), YES, ^{
            [self write:@{@"PlugIns": [NSNull null], @"Extensions": [NSNull null], @"Watch": [NSNull null], @"com.apple.WatchPlaceholder": [NSNull null]} title:GXL(@"Удаляю расширения…") done:nil];
        });
    } else if ([a isEqualToString:@"icon"]) [self pickIcon];
    else if ([a isEqualToString:@"inject"]) [self pickDylib];
    else if ([a isEqualToString:@"dylibs"]) [self showDylibs];
    else if ([a isEqualToString:@"ents"] || [a isEqualToString:@"macho"]) {
        NSString *exe = [self exeName];
        if (!exe) { GXAlert(self, GXL(@"Ошибка"), GXL(@"В Info.plist нет CFBundleExecutable")); return; }
        BOOL ents = [a isEqualToString:@"ents"];
        GXRunBG(self, GXL(@"Читаю бинарник…"), ^NSString *{
            NSData *d = [self read:exe];
            if (!d) return GXL(@"Исполняемый файл не найден");
            NSString *tmp = [GXTempDir() stringByAppendingPathComponent:exe];
            [d writeToFile:tmp atomically:NO];
            NSString *text = ents ? (GXEntitlementsXML(tmp) ?: GXL(@"Entitlements в подписи не найдены (приложение не подписано или подписано без них)")) : GXMachOReport(tmp);
            dispatch_async(dispatch_get_main_queue(), ^{
                GXReportVC *r = [[GXReportVC alloc] initWithTitle:ents ? @"Entitlements" : exe text:text];
                [self.navigationController pushViewController:r animated:YES];
            });
            return nil;
        }, nil);
    } else if ([a isEqualToString:@"dup"]) {
        NSString *dst = GXUniquePath(_path.stringByDeletingLastPathComponent, [_path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:GXL(@" копия.ipa")]);
        NSString *src = _path;
        GXRunBG(self, GXL(@"Копирую…"), ^NSString *{ NSError *e; return [FM() copyItemAtPath:src toPath:dst error:&e] ? nil : e.localizedDescription; },
                ^{ GXToast(self.view, [NSString stringWithFormat:GXL(@"Копия: %@"), dst.lastPathComponent]); });
    } else if ([a isEqualToString:@"browse"]) {
        [self.navigationController pushViewController:[[GXArchiveVC alloc] initWithArchive:_path] animated:YES];
    }
}

#pragma mark Иконка

- (void)pickIcon {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Новая иконка") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Выбрать в «Файлах»") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self->_pickFor = @"icon";
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
        dp.delegate = self;
        [self presentViewController:dp animated:YES completion:nil];
    }]];
    NSString *clip = GXClipboardPaths().firstObject;
    if (clip && GXKindForPath(clip, NO) == GXKindImage)
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:GXL(@"Из буфера: %@"), clip.lastPathComponent] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self applyIcon:[UIImage imageWithContentsOfFile:clip]]; }]];
    if (UIPasteboard.generalPasteboard.hasImages)
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Картинка из буфера обмена iOS") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self applyIcon:UIPasteboard.generalPasteboard.image]; }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 100, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

static NSData *GXIconPNG(UIImage *img, CGFloat px) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.scale = 1;
    f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(px, px) format:f];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, px, px));
        CGSize s = img.size;
        CGFloat k = MAX(px / s.width, px / s.height);
        [img drawInRect:CGRectMake((px - s.width * k) / 2, (px - s.height * k) / 2, s.width * k, s.height * k)];
    }];
    return UIImagePNGRepresentation(out);
}

- (void)applyIcon:(UIImage *)img {
    if (!img) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось прочитать картинку")); return; }
    NSDictionary *files = @{@"GXIcon60x60@2x.png": @120, @"GXIcon60x60@3x.png": @180, @"GXIcon76x76~ipad.png": @76, @"GXIcon76x76@2x~ipad.png": @152,
                            @"GXIcon83.5x83.5@2x~ipad.png": @167, @"iTunesArtwork": @512, @"iTunesArtwork@2x": @1024};
    NSMutableDictionary *ch = [NSMutableDictionary dictionary];
    for (NSString *n in files) ch[n] = GXIconPNG(img, [files[n] doubleValue]);
    _info[@"CFBundleIcons"] = @{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @[@"GXIcon60x60"]}};
    _info[@"CFBundleIcons~ipad"] = @{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @[@"GXIcon60x60", @"GXIcon76x76", @"GXIcon83.5x83.5"]}};
    [_info removeObjectForKey:@"CFBundleIconFile"];
    [_info removeObjectForKey:@"CFBundleIconFiles"];
    ch[@"Info.plist"] = [self plistData:_info];
    // кэш иконки LiveContainer, если он есть в бандле
    if (!_isIPA) { ch[@"LCAppIconLight.png"] = [NSNull null]; ch[@"LCAppIconDark.png"] = [NSNull null]; }
    [self write:ch title:GXL(@"Меняю иконку…") done:^{ [GXIcons clearCache]; }];
}

#pragma mark dylib

- (void)pickDylib {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Внедрить dylib") message:GXL(@"Выберите .dylib (или .framework-бинарник)") preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Выбрать в «Файлах»") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        self->_pickFor = @"dylib";
        UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
        dp.allowsMultipleSelection = YES;
        dp.delegate = self;
        [self presentViewController:dp animated:YES completion:nil];
    }]];
    NSMutableArray *clip = [NSMutableArray array];
    for (NSString *p in GXClipboardPaths()) if ([p.pathExtension.lowercaseString isEqualToString:@"dylib"]) [clip addObject:p];
    if (clip.count) [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:GXL(@"Из буфера GX Files (%lu)"), (unsigned long)clip.count] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self inject:clip]; }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 100, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *paths = [NSMutableArray array];
    NSString *tmp = GXTempDir();
    for (NSURL *u in urls) {
        BOOL sc = [u startAccessingSecurityScopedResource];
        NSString *l = [tmp stringByAppendingPathComponent:u.lastPathComponent];
        [FM() copyItemAtURL:u toURL:[NSURL fileURLWithPath:l] error:nil];
        if (sc) [u stopAccessingSecurityScopedResource];
        [paths addObject:l];
    }
    if ([_pickFor isEqualToString:@"icon"]) [self applyIcon:[UIImage imageWithContentsOfFile:paths.firstObject]];
    else [self inject:paths];
}

- (void)inject:(NSArray<NSString *> *)dylibs {
    NSString *exe = [self exeName];
    if (!exe) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Нет CFBundleExecutable")); return; }
    [GXHUD showIn:self.view text:GXL(@"Внедряю…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *bin = [[self read:exe] mutableCopy];
        NSString *err = nil;
        NSMutableDictionary *ch = [NSMutableDictionary dictionary];
        if (!bin) err = GXL(@"Исполняемый файл не найден");
        char e[256] = "";
        if (!err && !gx_macho_add_rpath(bin.mutableBytes, bin.length, "@executable_path/Frameworks", e, sizeof e)) err = @(e);
        for (NSString *p in dylibs) {
            if (err) break;
            NSString *name = p.lastPathComponent;
            NSString *lc = [@"@rpath/" stringByAppendingString:name];
            if (!gx_macho_add_dylib(bin.mutableBytes, bin.length, lc.UTF8String, 0, e, sizeof e)) { err = @(e); break; }
            NSData *d = [NSData dataWithContentsOfFile:p];
            if (!d) { err = [NSString stringWithFormat:GXL(@"%@: не прочитать"), name]; break; }
            ch[[@"Frameworks" stringByAppendingPathComponent:name]] = d;
        }
        if (!err) ch[exe] = bin;
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err) { GXAlert(self, GXL(@"Не удалось внедрить"), err); return; }
            [self write:ch title:GXL(@"Записываю…") done:^{ GXAlert(self, GXL(@"Готово"), [NSString stringWithFormat:GXL(@"Внедрено: %@\nТеперь установите приложение заново (LiveContainer переподпишет)."), [dylibs valueForKey:@"lastPathComponent"]]); }];
        });
    });
}

- (void)showDylibs {
    NSString *exe = [self exeName];
    NSData *d = exe ? [self read:exe] : nil;
    if (!d) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Исполняемый файл не найден")); return; }
    char *l = gx_macho_list_dylibs(d.bytes, d.length);
    NSArray *lines = [[@(l) ?: @"" componentsSeparatedByString:@"\n"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    free(l);
    GXDylibListVC *v = [GXDylibListVC new];
    v.items = lines.mutableCopy;
    __weak typeof(self) ws = self;
    v.onRemove = ^(NSString *item) {
        NSString *path = [[item componentsSeparatedByString:@" ("] firstObject];
        NSMutableData *bin = [[ws read:exe] mutableCopy];
        int n = gx_macho_remove_dylib(bin.mutableBytes, bin.length, path.UTF8String);
        if (!n) { GXAlert(ws, GXL(@"Не найдено"), path); return; }
        [ws write:@{exe: bin} title:GXL(@"Удаляю команду загрузки…") done:nil];
    };
    [self.navigationController pushViewController:v animated:YES];
}
@end

@implementation GXDylibListVC
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = GXL(@"Библиотеки"); }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return GXL(@"Смахните влево, чтобы удалить команду загрузки (сам файл библиотеки останется). Не удаляйте системные библиотеки — приложение не запустится."); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"d"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
    c.textLabel.text = _items[ip.row];
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    c.textLabel.numberOfLines = 0;
    BOOL sys = [_items[ip.row] hasPrefix:@"/System/"] || [_items[ip.row] hasPrefix:@"/usr/lib/"];
    c.textLabel.textColor = sys ? UIColor.secondaryLabelColor : UIColor.labelColor;
    return c;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *item = _items[ip.row];
    UIContextualAction *d = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:GXL(@"Удалить") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        GXConfirm(self, GXL(@"Удалить команду загрузки?"), item, GXL(@"Удалить"), YES, ^{
            [self->_items removeObject:item];
            [tv reloadData];
            if (self.onRemove) self.onRemove(item);
        });
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[d]];
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UIPasteboard.generalPasteboard.string = _items[ip.row];
    GXToast(self.view, GXL(@"Скопировано"));
}
@end

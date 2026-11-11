// Сборщик IPA: C-исходник (шаблоны приложений с UIKit через рантайм) → исполняемый файл
// встроенным TinyCC → Payload/App.app (Info.plist, иконки) → подпись сертификатом .p12 +
// provisioning (или без подписи — для Feather/SideStore/AltStore) → .ipa.
#import "GXCore.h"
#import <PhotosUI/PhotosUI.h>

static NSString *SafeName(NSString *s, NSString *fallback) {
    NSMutableString *m = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) [m appendFormat:@"%C", c];
    }
    if (!m.length) return fallback;
    if ([m characterAtIndex:0] >= '0' && [m characterAtIndex:0] <= '9') [m insertString:@"App" atIndex:0];
    return m;
}

// Иконка: своя картинка (обрезается по центру в квадрат) или градиент с первой буквой названия
static NSData *IconPNG(UIImage *src, NSString *title, CGFloat px) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.scale = 1; f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(px, px) format:f];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect box = CGRectMake(0, 0, px, px);
        if (src) {
            CGSize s = src.size; CGFloat k = MAX(px / s.width, px / s.height);
            CGSize d = CGSizeMake(s.width * k, s.height * k);
            [UIColor.whiteColor setFill]; UIRectFill(box);
            [src drawInRect:CGRectMake((px - d.width) / 2, (px - d.height) / 2, d.width, d.height)];
            return;
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        NSArray *cols = @[(__bridge id)[UIColor colorWithRed:0.55 green:0.35 blue:1.0 alpha:1].CGColor,
                          (__bridge id)[UIColor colorWithRed:0.15 green:0.45 blue:0.95 alpha:1].CGColor];
        CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)cols, NULL);
        CGContextDrawLinearGradient(ctx.CGContext, g, CGPointZero, CGPointMake(px, px), 0);
        CGGradientRelease(g); CGColorSpaceRelease(cs);
        NSString *letter = title.length ? [[title substringToIndex:[title rangeOfComposedCharacterSequenceAtIndex:0].length] uppercaseString] : @"A";
        NSDictionary *at = @{NSFontAttributeName: [UIFont systemFontOfSize:px * 0.55 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.whiteColor};
        CGSize ts = [letter sizeWithAttributes:at];
        [letter drawAtPoint:CGPointMake((px - ts.width) / 2, (px - ts.height) / 2) withAttributes:at];
    }];
    return UIImagePNGRepresentation(img);
}

// Собрать IPA. opts: name, bundle, version, sign (NSNumber), icon (UIImage, необязательно).
// Возвращает nil и путь в *outPath, либо текст ошибки. Вызывать НЕ на главном потоке.
NSString *_Nullable GXBuildIPA(NSString *src, NSDictionary *opts, NSArray<NSString *> *libs, NSMutableString *log, NSString *_Nullable *_Nullable outPath) {
    NSString *name = [opts[@"name"] length] ? opts[@"name"] : @"MyApp";
    NSString *exe = SafeName(name, @"App");
    NSString *bid = [opts[@"bundle"] length] ? opts[@"bundle"] : [@"com.gxfiles." stringByAppendingString:exe.lowercaseString];
    NSString *ver = [opts[@"version"] length] ? opts[@"version"] : @"1.0";
    BOOL sign = [opts[@"sign"] boolValue];

    NSString *work = GXTempDir();
    NSString *app = [[work stringByAppendingPathComponent:@"Payload"] stringByAppendingPathComponent:[exe stringByAppendingPathExtension:@"app"]];
    [FM() createDirectoryAtPath:app withIntermediateDirectories:YES attributes:nil error:nil];

    // 1. исполняемый файл (UIKit/Foundation/рантайм нужны любому приложению)
    NSMutableArray *all = [NSMutableArray arrayWithArray:@[@"libobjc", @"Foundation", @"UIKit"]];
    for (NSString *l in libs) if (![all containsObject:l]) [all addObject:l];
    [log appendString:GXL(@"Компиляция приложения…\n")];
    NSString *exePath = [app stringByAppendingPathComponent:exe];
    NSString *err = GXCompileExecutable(src, exePath, all, log);
    if (err) { [FM() removeItemAtPath:work error:nil]; return err; }
    [FM() setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:exePath error:nil];

    // 2. иконки
    UIImage *icon = [opts[@"icon"] isKindOfClass:UIImage.class] ? opts[@"icon"] : nil;
    NSDictionary *icons = @{@"AppIcon60x60@2x.png": @120, @"AppIcon60x60@3x.png": @180,
                            @"AppIcon76x76@2x~ipad.png": @152, @"AppIcon83.5x83.5@2x~ipad.png": @167};
    for (NSString *f in icons) [IconPNG(icon, name, [icons[f] doubleValue]) writeToFile:[app stringByAppendingPathComponent:f] atomically:YES];

    // 3. Info.plist
    NSDictionary *info = @{
        @"CFBundleDevelopmentRegion": @"en",
        @"CFBundleDisplayName": name, @"CFBundleName": name,
        @"CFBundleExecutable": exe, @"CFBundleIdentifier": bid,
        @"CFBundleInfoDictionaryVersion": @"6.0", @"CFBundlePackageType": @"APPL",
        @"CFBundleShortVersionString": ver, @"CFBundleVersion": ver,
        @"CFBundleSupportedPlatforms": @[@"iPhoneOS"],
        @"DTPlatformName": @"iphoneos", @"DTPlatformVersion": @"16.5", @"DTSDKName": @"iphoneos16.5",
        @"LSRequiresIPhoneOS": @YES, @"MinimumOSVersion": @"14.0",
        @"UIDeviceFamily": @[@1, @2], @"UIRequiredDeviceCapabilities": @[@"arm64"],
        @"UILaunchScreen": @{},                       // без него iOS запускает в «режиме совместимости» с полосами
        @"UIRequiresFullScreen": @YES,
        @"UISupportedInterfaceOrientations": @[@"UIInterfaceOrientationPortrait"],
        @"UISupportedInterfaceOrientations~ipad": @[@"UIInterfaceOrientationPortrait"],
        @"CFBundleIcons": @{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @[@"AppIcon60x60"]}},
        @"CFBundleIcons~ipad": @{@"CFBundlePrimaryIcon": @{@"CFBundleIconFiles": @[@"AppIcon60x60", @"AppIcon76x76", @"AppIcon83.5x83.5"]}},
        @"GXBuiltWith": @"GX Files",
    };
    NSData *pl = [NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    [pl writeToFile:[app stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    [@"APPL????" writeToFile:[app stringByAppendingPathComponent:@"PkgInfo"] atomically:YES encoding:NSASCIIStringEncoding error:nil];

    // 4. подпись
    if (sign) {
        NSString *used = nil;
        err = GXSignAppBundle(app, bid, &used, log);
        if (err) { [FM() removeItemAtPath:work error:nil]; return err; }
        if (used) bid = used;
    } else {
        [log appendString:GXL(@"Без подписи — поставь IPA через Feather, SideStore или AltStore, они подпишут его твоим сертификатом.\n")];
    }

    // 5. упаковка
    NSString *dir = src.stringByDeletingLastPathComponent;
    NSString *ipa = [dir stringByAppendingPathComponent:[exe stringByAppendingPathExtension:@"ipa"]];
    [FM() removeItemAtPath:ipa error:nil];
    err = GXZipCreateFromFolder(work, ipa, NO);
    [FM() removeItemAtPath:work error:nil];
    if (err) return err;
    [log appendFormat:GXL(@"✓ %@ — %@, %@ %@\n"), ipa.lastPathComponent, GXHuman([[FM() attributesOfItemAtPath:ipa error:nil] fileSize]), bid, ver];
    if (outPath) *outPath = ipa;
    return nil;
}

#pragma mark - Экран сборки

@interface GXIpaBuildVC () <UITextFieldDelegate, PHPickerViewControllerDelegate>
@end

@implementation GXIpaBuildVC {
    NSString *_src;
    NSArray<NSString *> *_libs;
    UITextField *_name, *_bundle, *_version;
    UISwitch *_sign;
    UIImage *_icon;
}

- (instancetype)initWithSource:(NSString *)src libs:(NSArray<NSString *> *)libs {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _src = src.copy; _libs = libs.copy; self.title = GXL(@"Собрать IPA"); }
    return self;
}
- (NSString *)cfgKey { return [@"ipaCfg." stringByAppendingString:_src.lastPathComponent]; }

- (UITextField *)field:(NSString *)text placeholder:(NSString *)ph {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    f.text = text; f.placeholder = ph; f.textAlignment = NSTextAlignmentRight;
    f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing; f.delegate = self; f.returnKeyType = UIReturnKeyDone;
    return f;
}
- (BOOL)textFieldShouldReturn:(UITextField *)t { [t resignFirstResponder]; return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    NSDictionary *c = [GXDefaults() dictionaryForKey:[self cfgKey]] ?: @{};
    NSString *base = SafeName(_src.lastPathComponent.stringByDeletingPathExtension, @"MyApp");
    _name = [self field:c[@"name"] ?: base placeholder:@"MyApp"];
    _bundle = [self field:c[@"bundle"] ?: [@"com.gxfiles." stringByAppendingString:base.lowercaseString] placeholder:@"com.example.app"];
    _version = [self field:c[@"version"] ?: @"1.0" placeholder:@"1.0"];
    _version.keyboardType = UIKeyboardTypeDecimalPad;
    _sign = [UISwitch new];
    _sign.on = GXSignCanSignApps() && (c[@"sign"] ? [c[@"sign"] boolValue] : YES);
    _sign.enabled = GXSignCanSignApps();
    NSDictionary *prof = GXSignProfileSummary();
    if (prof && ![prof[@"pattern"] containsString:@"*"] && !c[@"bundle"]) _bundle.text = prof[@"pattern"];   // профиль на конкретный ID
}
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; [self saveCfg]; }
- (void)saveCfg {
    [GXDefaults() setObject:@{@"name": _name.text ?: @"", @"bundle": _bundle.text ?: @"", @"version": _version.text ?: @"", @"sign": @(_sign.on)} forKey:[self cfgKey]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 3 : s == 1 ? (_icon ? 2 : 1) : 1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[GXL(@"Приложение"), GXL(@"Иконка"), GXL(@"Подпись"), @""][s];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return [NSString stringWithFormat:GXL(@"Исходник: %@. Это должен быть код приложения с main() — шаблоны: меню компилятора → «Шаблоны приложений»."), _src.lastPathComponent];
    if (s == 1) return GXL(@"Без своей картинки иконка рисуется сама — градиент и первая буква названия.");
    if (s == 2) {
        NSDictionary *p = GXSignProfileSummary();
        if (!GXSignHasIdentity()) return GXL(@"Сертификат не загружен. Добавь .p12 и .mobileprovision в «Подпись сертификатом» — или собери без подписи и поставь через Feather/SideStore/AltStore.");
        if (!p) return GXL(@"Для подписи приложения нужен ещё provisioning-профиль (.mobileprovision) — добавь его в «Подпись сертификатом». Без подписи IPA можно поставить через Feather/SideStore/AltStore.");
        NSMutableString *t = [NSMutableString stringWithFormat:GXL(@"Профиль «%@»: App ID %@.%@"), p[@"name"], p[@"team"], p[@"pattern"]];
        if (p[@"devices"]) [t appendFormat:GXL(@", устройств: %@"), p[@"devices"]];
        if (p[@"expires"]) { NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle; [t appendFormat:GXL(@", действует до %@"), [f stringFromDate:p[@"expires"]]]; }
        [t appendString:GXL(@". Подписанный IPA ставится только на устройства из этого профиля.")];
        return t;
    }
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == 0) {
        c.textLabel.text = @[GXL(@"Название"), @"Bundle ID", GXL(@"Версия")][ip.row];
        c.accessoryView = @[_name, _bundle, _version][ip.row];
    } else if (ip.section == 1) {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        if (ip.row == 0) {
            c.textLabel.text = _icon ? GXL(@"Заменить картинку…") : GXL(@"Выбрать картинку…");
            c.textLabel.textColor = tv.tintColor;
            UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage imageWithData:IconPNG(_icon, _name.text, 120)]];
            iv.frame = CGRectMake(0, 0, 40, 40); iv.layer.cornerRadius = 9; iv.clipsToBounds = YES;
            c.accessoryView = iv;
        } else {
            c.textLabel.text = GXL(@"Сбросить (авто-иконка)");
            c.textLabel.textColor = UIColor.systemRedColor;
        }
    } else if (ip.section == 2) {
        c.textLabel.text = GXL(@"Подписать моим сертификатом");
        c.accessoryView = _sign;
    } else {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.textLabel.text = GXL(@"Собрать IPA");
        c.textLabel.textAlignment = NSTextAlignmentCenter;
        c.textLabel.font = [UIFont boldSystemFontOfSize:17];
        c.textLabel.textColor = tv.tintColor;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self.view endEditing:YES];
    if (ip.section == 1 && ip.row == 0) {
        PHPickerConfiguration *cfg = [PHPickerConfiguration new];
        cfg.filter = PHPickerFilter.imagesFilter; cfg.selectionLimit = 1;
        PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
    } else if (ip.section == 1) {
        _icon = nil; [tv reloadData];
    } else if (ip.section == 3) {
        [self build];
    }
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *ip = results.firstObject.itemProvider;
    if (![ip canLoadObjectOfClass:UIImage.class]) return;
    [ip loadObjectOfClass:UIImage.class completionHandler:^(id obj, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ if ([obj isKindOfClass:UIImage.class]) { self->_icon = obj; [self.tableView reloadData]; } });
    }];
}

- (void)build {
    [self saveCfg];
    NSDictionary *opts = @{@"name": _name.text ?: @"", @"bundle": _bundle.text ?: @"", @"version": _version.text ?: @"",
                           @"sign": @(_sign.on && _sign.enabled), @"icon": _icon ?: [NSNull null]};
    NSString *src = _src; NSArray *libs = _libs;
    NSMutableString *log = [NSMutableString string];
    [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Сборка IPA…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *ipa = nil;
        NSString *err = GXBuildIPA(src, opts, libs, log, &ipa);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err) {
                [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:GXL(@"Ошибка сборки") text:[NSString stringWithFormat:@"%@\n%@", log, err]] animated:YES];
                return;
            }
            [self done:ipa log:log];
        });
    });
}
- (void)done:(NSString *)ipa log:(NSString *)log {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"IPA готов") message:log preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Поделиться / открыть в…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:ipa]] applicationActivities:nil];
        av.popoverPresentationController.sourceView = self.view;
        av.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
        [self presentViewController:av animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Показать в папке") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:ipa.stringByDeletingLastPathComponent] animated:YES];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}
@end

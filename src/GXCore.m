#import "GXCore.h"
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>

#pragma mark - Помощники

NSFileManager *FM(void) { return NSFileManager.defaultManager; }

NSString *GXHuman(unsigned long long b) {
    return [NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleFile];
}

NSDateFormatter *GXDateFmt(void) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"ru_RU"];
        f.dateStyle = NSDateFormatterShortStyle;
        f.timeStyle = NSDateFormatterShortStyle;
    });
    return f;
}

NSString *GXUniquePath(NSString *dir, NSString *name) {
    NSString *p = [dir stringByAppendingPathComponent:name];
    struct stat st;
    if (lstat(p.fileSystemRepresentation, &st) != 0) return p;
    NSString *ext = name.pathExtension;
    NSString *base = ext.length ? name.stringByDeletingPathExtension : name;
    for (int i = 2; i < 100000; i++) {
        NSString *n = ext.length ? [NSString stringWithFormat:@"%@ %d.%@", base, i, ext] : [NSString stringWithFormat:@"%@ %d", base, i];
        p = [dir stringByAppendingPathComponent:n];
        if (lstat(p.fileSystemRepresentation, &st) != 0) return p;
    }
    return p;
}

NSString *GXTempDir(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *d = [[caches stringByAppendingPathComponent:@"GXTemp"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

UIViewController *GXTopVC(UIViewController *vc) {
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
    return vc;
}

void GXAlert(UIViewController *vc, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [GXTopVC(vc) presentViewController:a animated:YES completion:nil];
}

void GXConfirm(UIViewController *vc, NSString *title, NSString *msg, NSString *action, BOOL destructive, void (^block)(void)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:action style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *x) { block(); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [GXTopVC(vc) presentViewController:a animated:YES completion:nil];
}

void GXPrompt(UIViewController *vc, NSString *title, NSString *msg, NSString *text, NSString *placeholder, NSString *ok, void (^block)(NSString *)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = text;
        tf.placeholder = placeholder;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        block(a.textFields.firstObject.text ?: @"");
    }]];
    [GXTopVC(vc) presentViewController:a animated:YES completion:nil];
}

void GXPresentNav(UIViewController *from, UIViewController *vc, BOOL fullScreen) {
    UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:vc];
    if (fullScreen) n.modalPresentationStyle = UIModalPresentationFullScreen;
    if (!vc.navigationItem.leftBarButtonItem && !fullScreen) {}
    [GXTopVC(from) presentViewController:n animated:YES completion:nil];
}

void GXToast(UIView *anyView, NSString *text) {
    UIWindow *w = anyView.window ?: UIApplication.sharedApplication.windows.firstObject;
    if (!w) return;
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    l.layer.cornerRadius = 14;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 3;
    CGSize s = [l sizeThatFits:CGSizeMake(w.bounds.size.width - 80, 100)];
    l.frame = CGRectMake(0, 0, MIN(s.width + 32, w.bounds.size.width - 40), s.height + 16);
    l.center = CGPointMake(w.bounds.size.width / 2, w.bounds.size.height - w.safeAreaInsets.bottom - 100);
    l.alpha = 0;
    [w addSubview:l];
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL ff) { [l removeFromSuperview]; }];
    }];
}

UIImage *GXSquareImage(UIImage *img, CGFloat side, CGFloat radius) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
    f.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, side, side);
        if (radius > 0) [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius] addClip];
        CGSize is = img.size;
        if (is.width <= 0 || is.height <= 0) return;
        CGFloat k = radius > 0 ? MAX(side / is.width, side / is.height) : MIN(side / is.width, side / is.height);
        CGSize ds = CGSizeMake(is.width * k, is.height * k);
        [img drawInRect:CGRectMake((side - ds.width) / 2, (side - ds.height) / 2, ds.width, ds.height)];
    }];
}

UIImage *GXSymbolTile(NSString *symbol, UIColor *color, CGFloat side) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@|%.0f|%ld", symbol, color, side, (long)UITraitCollection.currentTraitCollection.userInterfaceStyle];
    UIImage *c = [cache objectForKey:key];
    if (c) return c;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:side * 0.62 weight:UIImageSymbolWeightRegular];
    UIImage *sym = [[UIImage systemImageNamed:symbol withConfiguration:cfg] ?: [UIImage systemImageNamed:@"doc.fill" withConfiguration:cfg]
                    imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGSize s = sym.size;
        CGFloat k = MIN(1, MIN(side / s.width, side / s.height));
        CGSize d = CGSizeMake(s.width * k, s.height * k);
        [sym drawInRect:CGRectMake((side - d.width) / 2, (side - d.height) / 2, d.width, d.height)];
    }];
    [cache setObject:img forKey:key];
    return img;
}

NSString *GXHexString(NSData *d, NSUInteger max) {
    NSMutableString *s = [NSMutableString string];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < MIN(d.length, max); i++) [s appendFormat:@"%02x", b[i]];
    if (d.length > max) [s appendString:@"…"];
    return s;
}

#pragma mark - HUD

@implementation GXHUD
static UIView *gxHud;
static UILabel *gxHudLabel;
static UIProgressView *gxHudProgress;
static volatile BOOL gxHudCancelled;

+ (void)showIn:(UIView *)v text:(NSString *)t { [self show:v text:t cancel:NO]; }
+ (void)showCancellableIn:(UIView *)v text:(NSString *)t { [self show:v text:t cancel:YES]; }
+ (void)show:(UIView *)v text:(NSString *)t cancel:(BOOL)cancel {
    [self hide];
    gxHudCancelled = NO;
    UIWindow *w = v.window ?: UIApplication.sharedApplication.windows.firstObject;
    if (!w) return;
    UIView *bg = [[UIView alloc] initWithFrame:w.bounds];
    bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CGFloat h = cancel ? 170 : 130;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, h)];
    box.backgroundColor = UIColor.secondarySystemBackgroundColor;
    box.layer.cornerRadius = 18;
    box.center = bg.center;
    box.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    sp.center = CGPointMake(110, 42);
    [sp startAnimating];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 70, 200, 34)];
    l.text = t;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:14];
    l.numberOfLines = 2;
    l.adjustsFontSizeToFitWidth = YES;
    UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    pv.frame = CGRectMake(20, 110, 180, 4);
    pv.hidden = YES;
    [box addSubview:sp];
    [box addSubview:l];
    [box addSubview:pv];
    if (cancel) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:GXL(@"Отмена") forState:UIControlStateNormal];
        b.frame = CGRectMake(20, 124, 180, 36);
        [b addTarget:self action:@selector(cancelTap) forControlEvents:UIControlEventTouchUpInside];
        [box addSubview:b];
    }
    [bg addSubview:box];
    [w addSubview:bg];
    gxHud = bg;
    gxHudLabel = l;
    gxHudProgress = pv;
}
+ (void)cancelTap { gxHudCancelled = YES; gxHudLabel.text = GXL(@"Отмена…"); }
+ (BOOL)cancelled { return gxHudCancelled; }
+ (void)setText:(NSString *)t {
    dispatch_async(dispatch_get_main_queue(), ^{ gxHudLabel.text = t; });
}
+ (void)setProgress:(double)p {
    dispatch_async(dispatch_get_main_queue(), ^{
        gxHudProgress.hidden = p < 0;
        if (p >= 0) gxHudProgress.progress = (float)p;
    });
}
+ (void)hide { [gxHud removeFromSuperview]; gxHud = nil; gxHudLabel = nil; gxHudProgress = nil; }
@end

void GXRunBG(UIViewController *vc, NSString *title, NSString *(^work)(void), void (^done)(void)) {
    [GXHUD showIn:vc.view text:title];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = work();
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (done) done();
            if (err.length) GXAlert(vc, GXL(@"Ошибка"), err);
        });
    });
}

#pragma mark - Пути

static id GXCallClass(Class c, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (!c || ![c respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, s);
}

NSString *GXEnv(const char *name) {
    const char *v = getenv(name);
    return (v && *v) ? [NSString stringWithUTF8String:v] : nil;
}

BOOL GXInLiveContainer(void) { return GXEnv("LC_HOME_PATH") != nil; }
NSString *GXLCHome(void) { return GXEnv("LC_HOME_PATH"); }

NSString *GXLCAppGroup(void) {
    id p = GXCallClass(NSUserDefaults.class, @"lcAppGroupPath");
    return [p isKindOfClass:NSString.class] && [p length] ? p : nil;
}

NSString *GXLCBundlePath(void) {
    id b = GXCallClass(NSUserDefaults.class, @"lcMainBundle");
    if ([b isKindOfClass:NSBundle.class]) return [(NSBundle *)b bundlePath];
    return nil;
}

NSString *GXLCScheme(void) {
    id s = GXCallClass(NSUserDefaults.class, @"lcAppUrlScheme");
    return [s isKindOfClass:NSString.class] && [s length] ? s : @"livecontainer";
}

NSString *GXDocsDir(void) {
    NSString *h = GXLCHome();
    return [(h ?: NSHomeDirectory()) stringByAppendingPathComponent:@"Documents"];
}

static NSMutableDictionary<NSString *, NSURL *> *gxOpened;   // путь → URL с открытым доступом
NSArray<NSDictionary *> *GXLinkedFolders(void) {
    @synchronized (NSUserDefaults.class) {
        if (!gxOpened) gxOpened = [NSMutableDictionary dictionary];
        NSArray *saved = [GXDefaults() arrayForKey:@"gxLinked"] ?: @[];
        NSMutableArray *out = [NSMutableArray array], *keep = [NSMutableArray array];
        BOOL changed = NO;
        for (NSDictionary *e in saved) {
            NSData *bm = e[@"bm"];
            if (![bm isKindOfClass:NSData.class]) { changed = YES; continue; }
            BOOL stale = NO; NSError *err = nil;
            NSURL *u = [NSURL URLByResolvingBookmarkData:bm options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:&err];
            if (!u) { [keep addObject:e]; [out addObject:@{@"name": e[@"name"] ?: @"?", @"path": @"", @"broken": @YES}]; continue; }
            NSString *path = u.path;
            if (!gxOpened[path] && [u startAccessingSecurityScopedResource]) gxOpened[path] = u;
            NSMutableDictionary *ne = [e mutableCopy];
            if (stale) {
                NSData *fresh = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
                if (fresh) { ne[@"bm"] = fresh; changed = YES; }
            }
            [keep addObject:ne];
            [out addObject:@{@"name": e[@"name"] ?: u.lastPathComponent, @"path": path}];
        }
        if (changed) [GXDefaults() setObject:keep forKey:@"gxLinked"];
        return out;
    }
}

NSString *GXAddLinkedFolder(NSURL *url) {
    BOOL ok = [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSData *bm = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&err];
    if (!bm) { if (ok) [url stopAccessingSecurityScopedResource]; return err.localizedDescription ?: GXL(@"Не удалось подключить папку"); }
    @synchronized (NSUserDefaults.class) {
        if (!gxOpened) gxOpened = [NSMutableDictionary dictionary];
        if (ok) gxOpened[url.path] = url;
        NSMutableArray *a = [[GXDefaults() arrayForKey:@"gxLinked"] ?: @[] mutableCopy];
        [a addObject:@{@"name": url.lastPathComponent ?: @"?", @"bm": bm}];
        [GXDefaults() setObject:a forKey:@"gxLinked"];
    }
    return nil;
}

void GXRemoveLinkedFolder(NSString *path) {
    @synchronized (NSUserDefaults.class) {
        NSMutableArray *a = [NSMutableArray array];
        for (NSDictionary *e in [GXDefaults() arrayForKey:@"gxLinked"] ?: @[]) {
            BOOL stale = NO;
            NSURL *u = [e[@"bm"] isKindOfClass:NSData.class] ? [NSURL URLByResolvingBookmarkData:e[@"bm"] options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
            if ((u && [u.path isEqualToString:path]) || (!u && !path.length)) { [gxOpened[path] stopAccessingSecurityScopedResource]; [gxOpened removeObjectForKey:path]; continue; }
            [a addObject:e];
        }
        [GXDefaults() setObject:a forKey:@"gxLinked"];
    }
}

BOOL GXIsDir(NSString *p) {
    BOOL d = NO;
    return p && [FM() fileExistsAtPath:p isDirectory:&d] && d;
}

NSArray<NSDictionary *> *GXRootSections(void) {
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *(^section)(NSString *) = ^NSMutableArray *(NSString *title) {
        NSMutableArray *rows = [NSMutableArray array];
        [sections addObject:@{@"title": title, @"rows": rows}];
        return rows;
    };
    void (^add)(NSMutableArray *, NSString *, NSString *, NSString *, NSString *, UIColor *) =
        ^(NSMutableArray *rows, NSString *t, NSString *sub, NSString *p, NSString *icon, UIColor *c) {
            if (!p.length || [seen containsObject:p]) return;
            [seen addObject:p];
            [rows addObject:@{@"title": t, @"subtitle": sub, @"path": p, @"icon": icon, @"color": c}];
        };
    void (^action)(NSMutableArray *, NSString *, NSString *, NSString *, NSString *, UIColor *) =
        ^(NSMutableArray *rows, NSString *t, NSString *sub, NSString *act, NSString *icon, UIColor *c) {
            [rows addObject:@{@"title": t, @"subtitle": sub, @"action": act, @"icon": icon, @"color": c}];
        };

    NSString *lcHome = GXLCHome();
    NSString *group = GXLCAppGroup();
    if (lcHome) {
        NSMutableArray *lc = section(@"LiveContainer");
        add(lc, GXL(@"Общая папка"), GXL(@"То, что видно в «Файлах» как LiveContainer"), [lcHome stringByAppendingPathComponent:@"Documents"], @"folder.fill.badge.person.crop", UIColor.systemBlueColor);
        add(lc, GXL(@"Скрытый контейнер"), GXL(@"Весь контейнер: Documents, Library, tmp, SystemData"), lcHome, @"lock.shield.fill", UIColor.systemOrangeColor);
        action(lc, GXL(@"Приложения"), GXL(@"Иконки, запуск, бандлы и данные каждого приложения"), @"apps", @"square.grid.2x2.fill", UIColor.systemPurpleColor);
        NSString *data = [lcHome stringByAppendingPathComponent:@"Documents/Data/Application"];
        if (GXIsDir(data)) add(lc, GXL(@"Данные приложений"), GXL(@"Контейнеры гостевых приложений"), data, @"externaldrive.fill", UIColor.systemTealColor);
        if (group) {
            add(lc, GXL(@"App Group (скрытый)"), GXL(@"Общий контейнер группы SideStore/AltStore"), group, @"person.3.fill", UIColor.systemPinkColor);
            NSString *gData = [group stringByAppendingPathComponent:@"LiveContainer/Data/Application"];
            if (GXIsDir(gData)) add(lc, GXL(@"Общие данные (App Group)"), @"LiveContainer/Data/Application", gData, @"externaldrive", UIColor.systemTealColor);
        }
        NSString *tweaks = GXEnv("LC_GLOBAL_TWEAKS_FOLDER");
        if (tweaks && GXIsDir(tweaks)) add(lc, GXL(@"Твики"), GXL(@"Глобальная папка твиков"), tweaks, @"wand.and.stars", UIColor.systemIndigoColor);
    } else {
        // обычная установка (Feather, SideStore, AltStore, TrollStore…)
        NSMutableArray *mine = section(@"GX Files");
        [FM() createDirectoryAtPath:GXDocsDir() withIntermediateDirectories:YES attributes:nil error:nil];
        add(mine, GXL(@"Мои файлы"), GXL(@"Видно в «Файлах» → «На iPhone» → GX Files"), GXDocsDir(), @"folder.fill", UIColor.systemBlueColor);
    }

    NSMutableArray *linked = section(GXL(@"Подключённые папки"));
    NSArray *lf = @[];
    @try { lf = GXLinkedFolders(); } @catch (NSException *e) { NSLog(@"GX Files: linked folders: %@", e); }
    for (NSDictionary *f in lf) {
        if ([f[@"broken"] boolValue]) { [linked addObject:@{@"title": f[@"name"], @"subtitle": GXL(@"Папка недоступна — смахните влево, чтобы убрать"), @"action": @"none", @"icon": @"exclamationmark.triangle.fill", @"color": UIColor.systemYellowColor, @"linked": @""}]; continue; }
        if (!f[@"path"] || [seen containsObject:f[@"path"]]) continue;
        [seen addObject:f[@"path"]];
        [linked addObject:@{@"title": f[@"name"], @"subtitle": f[@"path"], @"path": f[@"path"], @"icon": @"folder.badge.plus", @"color": UIColor.systemCyanColor, @"linked": f[@"path"]}];
    }
    action(linked, GXL(@"Подключить папку…"), GXL(@"Любая папка из «Файлов»: iCloud Drive, «На iPhone», флешка, другие приложения"), @"addfolder", @"plus.circle.fill", UIColor.systemGreenColor);

    NSMutableArray *sys = section(GXL(@"Система"));
    add(sys, lcHome ? GXL(@"Данные GX Files") : GXL(@"Домашняя папка"), GXL(@"Собственный контейнер этого приложения"), NSHomeDirectory(), @"house.fill", UIColor.systemGreenColor);
    NSString *lcBundle = GXLCBundlePath();
    add(sys, lcBundle ? GXL(@"Бандл LiveContainer.app") : GXL(@"Бандл приложения"), GXL(@"Только чтение"), lcBundle ?: NSBundle.mainBundle.bundlePath, @"shippingbox.fill", UIColor.systemBrownColor);
    add(sys, GXL(@"Корень /"), GXL(@"Только то, что разрешает песочница"), @"/", @"internaldrive.fill", UIColor.systemGrayColor);

    NSMutableArray *tools = section(GXL(@"Инструменты"));
    action(tools, GXL(@"ИИ-помощник"), GXL(@"Любой ИИ по API или локальный — меняет файлы в выбранной папке по твоей просьбе"), @"ai", @"sparkles", UIColor.systemPurpleColor);
    action(tools, GXL(@"Передача по Wi‑Fi"), GXL(@"Скачивайте и загружайте файлы с компьютера через браузер"), @"wifi", @"wifi", UIColor.systemBlueColor);
    action(tools, GXL(@"GitHub"), GXL(@"Свои и публичные репозитории: скачать, изменить, отправить коммит"), @"github", @"chevron.left.forwardslash.chevron.right", UIColor.labelColor);
    action(tools, GXL(@"Сетевые диски (WebDAV)"), GXL(@"Компьютер, NAS, Nextcloud, Яндекс Диск — скачать и загрузить"), @"webdav", @"externaldrive.connected.to.line.below.fill", UIColor.systemCyanColor);
    action(tools, GXL(@"Компилятор C → dylib"), GXL(@"Свой код → arm64 dylib прямо на iPhone (TinyCC)"), @"compiler", @"hammer.fill", UIColor.systemTealColor);
    action(tools, GXL(@"Найти и заменить текст"), GXL(@"Во всех файлах и внутри APK/IPA/ZIP — без открытия"), @"findreplace", @"text.magnifyingglass", UIColor.systemOrangeColor);
    action(tools, GXL(@"Поиск файлов по имени"), GXL(@"По всему контейнеру"), @"search", @"magnifyingglass", UIColor.systemOrangeColor);
    action(tools, GXL(@"Анализ места"), GXL(@"Что занимает память"), @"usage", @"chart.pie.fill", UIColor.systemRedColor);
    action(tools, GXL(@"Скачать по ссылке"), GXL(@"Файл из интернета — в общую папку"), @"download", @"arrow.down.circle.fill", UIColor.systemIndigoColor);
    action(tools, GXL(@"Ключ подписи APK"), GXL(@"Сертификат, которым GX Files подписывает APK"), @"signinfo", @"signature", UIColor.systemIndigoColor);
    action(tools, GXL(@"Настройки"), GXL(@"Вид, скрытые файлы, кэш"), @"settings", @"gearshape.fill", UIColor.systemGrayColor);
    return sections;
}

#pragma mark - Приложения LiveContainer

@implementation GXLCApp {
    UIImage *_icon;
    BOOL _iconLoaded;
}

static NSArray<GXLCApp *> *gxApps;

+ (NSArray<GXLCApp *> *)allApps:(BOOL)reload {
    @synchronized(self) {
        if (gxApps && !reload) return gxApps;
        NSMutableArray *r = [NSMutableArray array];
        NSString *home = GXLCHome(), *group = GXLCAppGroup();
        NSMutableArray *dirs = [NSMutableArray array];
        if (home) [dirs addObject:@[[home stringByAppendingPathComponent:@"Documents/Applications"], [home stringByAppendingPathComponent:@"Documents/Data/Application"], @NO]];
        if (group) [dirs addObject:@[[group stringByAppendingPathComponent:@"LiveContainer/Applications"], [group stringByAppendingPathComponent:@"LiveContainer/Data/Application"], @YES]];
        for (NSArray *d in dirs) {
            for (NSString *n in [FM() contentsOfDirectoryAtPath:d[0] error:nil]) {
                if (![n.pathExtension isEqualToString:@"app"]) continue;
                NSString *bp = [d[0] stringByAppendingPathComponent:n];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bp stringByAppendingPathComponent:@"Info.plist"]];
                NSDictionary *lc = [NSDictionary dictionaryWithContentsOfFile:[bp stringByAppendingPathComponent:@"LCAppInfo.plist"]] ?: info;
                GXLCApp *a = [GXLCApp new];
                a.bundlePath = bp;
                a.bundleId = info[@"CFBundleIdentifier"] ?: n.stringByDeletingPathExtension;
                a.name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: n.stringByDeletingPathExtension;
                a.version = info[@"CFBundleShortVersionString"] ?: info[@"CFBundleVersion"] ?: @"";
                a.isShared = [d[2] boolValue];
                NSMutableArray *cs = [NSMutableArray array];
                NSArray *containers = [lc[@"LCContainers"] isKindOfClass:NSArray.class] ? lc[@"LCContainers"] : @[];
                for (NSDictionary *c in containers) {
                    if (![c isKindOfClass:NSDictionary.class] || ![c[@"folderName"] isKindOfClass:NSString.class]) continue;
                    BOOL shared = [c[@"isShared"] boolValue] || a.isShared;
                    NSString *base = shared && group ? [group stringByAppendingPathComponent:@"LiveContainer/Data/Application"] : d[1];
                    [cs addObject:@{@"name": c[@"name"] ?: c[@"folderName"], @"path": [base stringByAppendingPathComponent:c[@"folderName"]], @"folder": c[@"folderName"]}];
                }
                NSString *uuid = lc[@"LCDataUUID"];
                if ([uuid isKindOfClass:NSString.class] && uuid.length) {
                    BOOL dup = NO;
                    for (NSDictionary *c in cs) if ([c[@"folder"] isEqualToString:uuid]) dup = YES;
                    if (!dup) [cs insertObject:@{@"name": GXL(@"Основной"), @"path": [d[1] stringByAppendingPathComponent:uuid], @"folder": uuid} atIndex:0];
                }
                a.containers = cs;
                [r addObject:a];
            }
        }
        [r sortUsingComparator:^NSComparisonResult(GXLCApp *x, GXLCApp *y) { return [x.name localizedStandardCompare:y.name]; }];
        gxApps = r;
        return r;
    }
}

+ (GXLCApp *)appWithBundleId:(NSString *)bid {
    for (GXLCApp *a in [self allApps:NO]) if ([a.bundleId isEqualToString:bid]) return a;
    for (GXLCApp *a in [self allApps:YES]) if ([a.bundleId isEqualToString:bid]) return a;
    return nil;
}

+ (GXLCApp *)appForBundlePath:(NSString *)path {
    for (GXLCApp *a in [self allApps:NO]) if ([a.bundlePath isEqualToString:path]) return a;
    return nil;
}

+ (GXLCApp *)appOwningDataFolder:(NSString *)path {
    NSString *folder = path.lastPathComponent;
    for (GXLCApp *a in [self allApps:NO])
        for (NSDictionary *c in a.containers) if ([c[@"folder"] isEqualToString:folder]) return a;
    return nil;
}

- (UIImage *)icon {
    if (!_iconLoaded) { _icon = [GXIcons appBundleIcon:self.bundlePath]; _iconLoaded = YES; }
    return _icon;
}

- (void)launch {
    NSString *url = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@", GXLCScheme(),
                     [self.bundlePath.lastPathComponent stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSURL *u = [NSURL URLWithString:url];
    if (u) [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
}
@end

#pragma mark - Типы файлов

GXKind GXKindForName(NSString *name, BOOL isDir) {
    NSString *e = name.pathExtension.lowercaseString;
    if (isDir) return [e isEqualToString:@"app"] || [e isEqualToString:@"appex"] ? GXKindApp : GXKindFolder;
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        void (^put)(GXKind, NSArray *) = ^(GXKind k, NSArray *exts) { for (NSString *x in exts) m[x] = @(k); };
        put(GXKindText, @[@"txt", @"md", @"log", @"ini", @"cfg", @"conf", @"csv", @"tsv", @"rtf", @"tex", @"srt", @"ass", @"ssa", @"vtt",
                         @"properties", @"env", @"gitignore", @"gitattributes", @"license", @"readme", @"nfo", @"diz", @"lst", @"rst", @"adoc"]);
        put(GXKindCode, @[@"html", @"htm", @"xhtml", @"css", @"scss", @"less", @"js", @"mjs", @"cjs", @"ts", @"tsx", @"jsx", @"xml", @"svg", @"yml",
                         @"yaml", @"toml", @"sh", @"bash", @"zsh", @"py", @"rb", @"pl", @"php", @"c", @"h", @"m", @"mm", @"cpp", @"cc", @"cxx",
                         @"hpp", @"hh", @"swift", @"java", @"kt", @"kts", @"gradle", @"go", @"rs", @"lua", @"sql", @"cs", @"vb", @"dart",
                         @"r", @"hlsl", @"glsl", @"shader", @"cginc", @"metal", @"xcconfig", @"cmake", @"makefile", @"mk", @"bat", @"ps1",
                         @"smali", @"gd", @"tscn", @"tres", @"vue", @"asm", @"s", @"cfg", @"lst", @"json5", @"jsonc", @"ipynb", @"xaml", @"storyboard", @"xib", @"pbxproj"]);
        put(GXKindPlist, @[@"plist", @"entitlements", @"xcent", @"loctable", @"mobileconfig"]);
        put(GXKindStrings, @[@"strings", @"stringsdict"]);
        put(GXKindJSON, @[@"json", @"geojson", @"har", @"webmanifest"]);
        put(GXKindImage, @[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"heif", @"webp", @"bmp", @"tiff", @"tif", @"ico", @"icns", @"tga", @"dng", @"avif", @"btx", @"dds", @"shtx", @"shtxfs", @"shtxff"]);
        put(GXKindVideo, @[@"mp4", @"mov", @"m4v", @"mkv", @"webm", @"avi", @"3gp", @"mts", @"flv", @"wmv"]);
        put(GXKindAudio, @[@"mp3", @"m4a", @"aac", @"wav", @"flac", @"ogg", @"caf", @"aiff", @"aif", @"opus", @"m4r", @"amr", @"wma", @"mid", @"midi"]);
        put(GXKindArchive, @[@"zip", @"rar", @"7z", @"tar", @"gz", @"tgz", @"bz2", @"tbz", @"tbz2", @"xz", @"txz", @"lzma", @"zst", @"deb",
                            @"cpio", @"iso", @"jar", @"aar", @"cab", @"lha", @"lzh", @"ar", @"pkg", @"xar", @"z", @"cbz", @"cbr", @"epub",
                            @"docx", @"xlsx", @"pptx", @"odt", @"ods", @"obb", @"pak"]);
        put(GXKindPDF, @[@"pdf"]);
        put(GXKindAndroid, @[@"apk", @"xapk", @"apkm", @"apks", @"apkx"]);
        put(GXKindIPA, @[@"ipa", @"tipa"]);
        put(GXKindSQLite, @[@"sqlite", @"sqlite3", @"db", @"sqlitedb", @"db3", @"realm-sqlite", @"store"]);
        put(GXKindFont, @[@"ttf", @"otf", @"ttc", @"woff", @"woff2"]);
        put(GXKindMachO, @[@"dylib", @"bundle", @"o", @"a"]);
        put(GXKindELF, @[@"so", @"elf"]);
        put(GXKindProvision, @[@"mobileprovision", @"provisionprofile"]);
        put(GXKindCar, @[@"car"]);
        put(GXKindBinary, @[@"bin", @"dat", @"dex", @"nib", @"assets", @"resource", @"ress", @"bundle", @"unity3d", @"bytes", @"sav", @"save", @"pb", @"bplist", @"img", @"raw"]);
        map = m;
    });
    NSNumber *k = map[e];
    if (k) return k.integerValue;
    NSString *lower = name.lowercaseString;
    if ([lower isEqualToString:@"makefile"] || [lower isEqualToString:@"dockerfile"] || [lower isEqualToString:@"podfile"] ||
        [lower isEqualToString:@"license"] || [lower isEqualToString:@"readme"]) return GXKindText;
    if ([lower hasSuffix:@".tar.gz"] || [lower hasSuffix:@".tar.xz"] || [lower hasSuffix:@".tar.bz2"]) return GXKindArchive;
    return e.length ? GXKindOther : GXKindBinary;
}

GXKind GXKindForPath(NSString *path, BOOL isDir) {
    GXKind k = GXKindForName(path.lastPathComponent, isDir);
    if (isDir || (k != GXKindOther && k != GXKindBinary && k != GXKindSQLite && k != GXKindMachO && k != GXKindArchive)) return k;
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return k;
    uint8_t h[20] = {0};
    ssize_t n = read(fd, h, sizeof h);
    close(fd);
    if (n < 4) return k == GXKindBinary ? GXKindText : k;
    uint32_t m = (uint32_t)h[0] | (uint32_t)h[1] << 8 | (uint32_t)h[2] << 16 | (uint32_t)h[3] << 24;
    if (n >= 16 && !memcmp(h, "SQLite format 3", 15)) return GXKindSQLite;
    if (m == 0xfeedfacf || m == 0xfeedface || m == 0xcffaedfe || m == 0xcefaedfe) return GXKindMachO;
    if (m == 0xbebafeca || m == 0xbfbafeca) { // fat — у Java class больший номер версии
        uint32_t narch = (uint32_t)h[4] << 24 | (uint32_t)h[5] << 16 | (uint32_t)h[6] << 8 | h[7];
        if (narch > 0 && narch < 20) return GXKindMachO;
    }
    if (!memcmp(h, "\x7f" "ELF", 4)) return GXKindELF;
    if (k == GXKindMachO || k == GXKindSQLite) return k;
    if (!memcmp(h, "PK\x03\x04", 4)) return k == GXKindArchive ? k : GXKindArchive;
    if (!memcmp(h, "bplist", 6)) return GXKindPlist;
    if (!memcmp(h, "\x89PNG", 4) || (h[0] == 0xFF && h[1] == 0xD8) || !memcmp(h, "GIF8", 4) || (!memcmp(h, "RIFF", 4) && n >= 12 && !memcmp(h + 8, "WEBP", 4))) return GXKindImage;
    if (!memcmp(h, "\xFC\xAA\x55\xA7", 4) || (!memcmp(h, "GX3", 4) && n >= 8 && !memcmp(h + 4, "\xFC\xAA\x55\xA7", 4)) || !memcmp(h, "SHTX", 4) || !memcmp(h, "DDS ", 4)) return GXKindImage;
    if (!memcmp(h, "%PDF", 4)) return GXKindPDF;
    if (!memcmp(h, "<?xml", 5)) {
        // xml-plist?
        char buf[512] = {0};
        int fd2 = open(path.fileSystemRepresentation, O_RDONLY);
        if (fd2 >= 0) { read(fd2, buf, sizeof buf - 1); close(fd2); }
        return strstr(buf, "<!DOCTYPE plist") || strstr(buf, "<plist") ? GXKindPlist : GXKindCode;
    }
    if (h[0] == '{' || h[0] == '[') return GXKindJSON;
    if (k == GXKindArchive) return k;
    // похоже на текст?
    BOOL text = YES;
    for (ssize_t i = 0; i < n; i++) if (h[i] == 0 || (h[i] < 9) || (h[i] > 13 && h[i] < 32 && h[i] != 27)) { text = NO; break; }
    if (text) return GXKindText;
    return k;
}

NSString *GXSymbolForKind(GXKind k) {
    switch (k) {
        case GXKindFolder: return @"folder.fill";
        case GXKindApp: return @"app.fill";
        case GXKindText: return @"doc.text.fill";
        case GXKindCode: return @"chevron.left.forwardslash.chevron.right";
        case GXKindPlist: return @"list.bullet.rectangle.fill";
        case GXKindJSON: return @"curlybraces";
        case GXKindStrings: return @"character.book.closed.fill";
        case GXKindImage: return @"photo.fill";
        case GXKindVideo: return @"film.fill";
        case GXKindAudio: return @"music.note";
        case GXKindArchive: return @"doc.zipper";
        case GXKindPDF: return @"doc.richtext.fill";
        case GXKindBinary: return @"01.square.fill";
        case GXKindMachO: return @"cpu.fill";
        case GXKindELF: return @"cpu";
        case GXKindAndroid: return @"shippingbox.fill";
        case GXKindIPA: return @"app.badge.fill";
        case GXKindSQLite: return @"cylinder.split.1x2.fill";
        case GXKindFont: return @"textformat";
        case GXKindProvision: return @"checkmark.seal.fill";
        case GXKindCar: return @"photo.stack.fill";
        default: return @"doc.fill";
    }
}

UIColor *GXColorForKind(GXKind k) {
    switch (k) {
        case GXKindFolder: return UIColor.systemBlueColor;
        case GXKindApp: return UIColor.systemPurpleColor;
        case GXKindText: return UIColor.systemGrayColor;
        case GXKindCode: return UIColor.systemTealColor;
        case GXKindPlist: return UIColor.systemOrangeColor;
        case GXKindJSON: return UIColor.systemYellowColor;
        case GXKindStrings: return UIColor.systemIndigoColor;
        case GXKindImage: return UIColor.systemGreenColor;
        case GXKindVideo: return UIColor.systemPinkColor;
        case GXKindAudio: return UIColor.systemRedColor;
        case GXKindArchive: return UIColor.systemBrownColor;
        case GXKindPDF: return UIColor.systemRedColor;
        case GXKindMachO: case GXKindELF: return UIColor.systemPurpleColor;
        case GXKindAndroid: return UIColor.systemGreenColor;
        case GXKindIPA: return UIColor.systemBlueColor;
        case GXKindSQLite: return UIColor.systemCyanColor;
        case GXKindFont: return UIColor.labelColor;
        case GXKindProvision: return UIColor.systemMintColor;
        case GXKindCar: return UIColor.systemOrangeColor;
        default: return UIColor.secondaryLabelColor;
    }
}

NSString *GXKindTitle(GXKind k) {
    switch (k) {
        case GXKindFolder: return GXL(@"Папка");
        case GXKindApp: return GXL(@"Бандл приложения");
        case GXKindText: return GXL(@"Текст");
        case GXKindCode: return GXL(@"Код / разметка");
        case GXKindPlist: return @"Property List";
        case GXKindJSON: return @"JSON";
        case GXKindStrings: return GXL(@"Строки локализации");
        case GXKindImage: return GXL(@"Изображение");
        case GXKindVideo: return GXL(@"Видео");
        case GXKindAudio: return GXL(@"Аудио");
        case GXKindArchive: return GXL(@"Архив");
        case GXKindPDF: return @"PDF";
        case GXKindBinary: return GXL(@"Двоичный файл");
        case GXKindMachO: return GXL(@"Mach-O (iOS бинарник)");
        case GXKindELF: return GXL(@"ELF (Android/Linux библиотека)");
        case GXKindAndroid: return GXL(@"Android-пакет");
        case GXKindIPA: return GXL(@"iOS-приложение (IPA)");
        case GXKindSQLite: return GXL(@"База SQLite");
        case GXKindFont: return GXL(@"Шрифт");
        case GXKindProvision: return GXL(@"Профиль подписи");
        case GXKindCar: return GXL(@"Каталог ассетов (Assets.car)");
        default: return GXL(@"Файл");
    }
}

BOOL GXIsZipFamily(NSString *path) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"zip", @"ipa", @"tipa", @"apk", @"xapk", @"apkm", @"apks", @"apkx", @"jar", @"aar", @"cbz", @"epub",
                                  @"docx", @"xlsx", @"pptx", @"odt", @"ods", @"obb"]];
    });
    if ([s containsObject:path.pathExtension.lowercaseString]) {
        if ([path.pathExtension.lowercaseString isEqualToString:@"obb"]) {
            int fd = open(path.fileSystemRepresentation, O_RDONLY);
            char h[4] = {0};
            if (fd >= 0) { read(fd, h, 4); close(fd); }
            return !memcmp(h, "PK\x03\x04", 4);
        }
        return YES;
    }
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    char h[4] = {0};
    if (fd >= 0) { read(fd, h, 4); close(fd); }
    return !memcmp(h, "PK\x03\x04", 4);
}

BOOL GXIsArchive(NSString *path) {
    GXKind k = GXKindForName(path.lastPathComponent, NO);
    return k == GXKindArchive || k == GXKindAndroid || k == GXKindIPA;
}

#pragma mark - Настройки

NSUserDefaults *GXDefaults(void) { return NSUserDefaults.standardUserDefaults; }
NSArray<NSString *> *GXFavorites(void) { return [GXDefaults() stringArrayForKey:@"gxFavorites"] ?: @[]; }
void GXSetFavorites(NSArray *a) { [GXDefaults() setObject:a forKey:@"gxFavorites"]; }
NSArray<NSString *> *GXRecents(void) { return [GXDefaults() stringArrayForKey:@"gxRecents"] ?: @[]; }
void GXAddRecent(NSString *path) {
    if ([path containsString:@"/GXTemp/"]) return;
    NSMutableArray *r = GXRecents().mutableCopy;
    [r removeObject:path];
    [r insertObject:path atIndex:0];
    while (r.count > 15) [r removeLastObject];
    [GXDefaults() setObject:r forKey:@"gxRecents"];
}
static BOOL GXBool(NSString *key, BOOL def) {
    if (![GXDefaults() objectForKey:key]) return def;
    return [GXDefaults() boolForKey:key];
}
BOOL GXShowHidden(void) { return GXBool(@"gxShowHidden", YES); }
BOOL GXBigIcons(void) { return GXBool(@"gxBigIcons", NO); }
BOOL GXThumbnails(void) { return GXBool(@"gxThumbnails", YES); }

#pragma mark - Хэши

NSString *GXHashFile(NSString *path, NSString *algo) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    const size_t CH = 1 << 20;
    uint8_t *buf = malloc(CH);
    CC_MD5_CTX md5; CC_SHA1_CTX sha1; CC_SHA256_CTX sha256;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5_Init(&md5);
    CC_SHA1_Init(&sha1);
    CC_SHA256_Init(&sha256);
    ssize_t n;
    while ((n = read(fd, buf, CH)) > 0) {
        if ([algo isEqualToString:@"md5"]) CC_MD5_Update(&md5, buf, (CC_LONG)n);
        else if ([algo isEqualToString:@"sha1"]) CC_SHA1_Update(&sha1, buf, (CC_LONG)n);
        else CC_SHA256_Update(&sha256, buf, (CC_LONG)n);
    }
    close(fd);
    free(buf);
    uint8_t out[CC_SHA256_DIGEST_LENGTH];
    NSUInteger len;
    if ([algo isEqualToString:@"md5"]) { CC_MD5_Final(out, &md5); len = CC_MD5_DIGEST_LENGTH; }
    else if ([algo isEqualToString:@"sha1"]) { CC_SHA1_Final(out, &sha1); len = CC_SHA1_DIGEST_LENGTH; }
    else { CC_SHA256_Final(out, &sha256); len = CC_SHA256_DIGEST_LENGTH; }
#pragma clang diagnostic pop
    return GXHexString([NSData dataWithBytes:out length:len], 64);
}

#pragma mark - @available без compiler-rt

int32_t __isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor, uint32_t subminor) {
    NSOperatingSystemVersion v = {(NSInteger)major, (NSInteger)minor, (NSInteger)subminor};
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:v];
}
int32_t __isOSVersionAtLeast(int32_t major, int32_t minor, int32_t subminor) {
    NSOperatingSystemVersion v = {major, minor, subminor};
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:v];
}

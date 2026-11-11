// Компилятор C → arm64 dylib прямо на iPhone (встроенный TinyCC, LGPL) + подпись ad-hoc
#import "GXCore.h"
#include "../tcc/src/libtcc.h"
#include "core/gx_bin.h"

static NSString *GXTccRes(void) { return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"tcc"]; }

static NSString *GXCompilerHome(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"GX Compiler"];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

// Группы библиотек для экрана выбора. libSystem подключается всегда и в списке не нужна.
static NSArray<NSDictionary *> *GXLibGroups(void) {
    return @[
        @{@"name": GXL(@"Основные"), @"libs": @[@"libobjc", @"Foundation", @"CoreFoundation", @"UIKit", @"CoreGraphics", @"QuartzCore"]},
        @{@"name": GXL(@"Сеть и безопасность"), @"libs": @[@"Security", @"CFNetwork", @"Network", @"SystemConfiguration", @"AuthenticationServices", @"LocalAuthentication", @"libresolv"]},
        @{@"name": GXL(@"Медиа и звук"), @"libs": @[@"AVFoundation", @"AVKit", @"CoreMedia", @"CoreVideo", @"CoreAudio", @"AudioToolbox", @"MediaPlayer", @"VideoToolbox", @"Speech", @"SoundAnalysis"]},
        @{@"name": GXL(@"Графика и 3D"), @"libs": @[@"CoreImage", @"ImageIO", @"CoreText", @"PDFKit", @"Metal", @"MetalKit", @"ModelIO", @"SpriteKit", @"SceneKit", @"Accelerate", @"ARKit", @"RealityKit"]},
        @{@"name": GXL(@"ИИ (Core ML)"), @"libs": @[@"CoreML", @"Vision", @"NaturalLanguage"]},
        @{@"name": GXL(@"Датчики и устройство"), @"libs": @[@"CoreLocation", @"CoreMotion", @"CoreTelephony", @"CoreBluetooth", @"ExternalAccessory", @"CoreNFC", @"NearbyInteraction", @"DeviceCheck", @"WatchConnectivity", @"libMobileGestalt"]},
        @{@"name": GXL(@"Данные и облако"), @"libs": @[@"CoreData", @"CloudKit", @"Contacts", @"ContactsUI", @"EventKit", @"EventKitUI", @"Photos", @"PhotosUI", @"HealthKit", @"HomeKit", @"FileProvider", @"CoreSpotlight"]},
        @{@"name": GXL(@"Интерфейс и сервисы"), @"libs": @[@"MapKit", @"WebKit", @"SafariServices", @"StoreKit", @"PassKit", @"UserNotifications", @"PushKit", @"MessageUI", @"Social", @"MultipeerConnectivity", @"GameController", @"GameKit", @"Intents", @"LinkPresentation", @"QuickLook", @"QuickLookThumbnailing", @"ReplayKit", @"BackgroundTasks", @"OSLog", @"UniformTypeIdentifiers", @"MobileCoreServices"]},
        @{@"name": GXL(@"Системные библиотеки"), @"libs": @[@"libz", @"libsqlite3", @"libc++", @"libc++abi", @"libcompression", @"libbz2", @"libiconv", @"libxml2", @"libxslt", @"libcharset", @"libarchive", @"libnetwork", @"libenergytrace"]},
    ];
}
static NSArray<NSString *> *GXAllLibs(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *g in GXLibGroups()) [a addObjectsFromArray:g[@"libs"]];
    return a;
}
static NSArray<NSString *> *GXEnabledLibs(void) {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:@"GXCompilerLibs"];
    return a ?: @[@"libobjc", @"Foundation", @"CoreFoundation", @"UIKit"];
}

static void gxTccError(void *opaque, const char *msg) {
    NSMutableString *log = (__bridge NSMutableString *)opaque;
    NSString *m = [NSString stringWithUTF8String:msg] ?: [NSString stringWithCString:msg encoding:NSISOLatin1StringEncoding] ?: @"?";
    @synchronized (log) { [log appendFormat:@"%@\n", m]; }
}

static dispatch_queue_t GXTccQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("gx.tcc", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Скомпилировать src → out встроенным TinyCC (dylib или исполняемый файл), без подписи.
// Вызывать на очереди GXTccQueue(). nil — успех, иначе текст ошибки; вывод компилятора — в log.
static NSString *GXTccBuild(NSString *src, NSString *out, NSArray<NSString *> *libs, BOOL exe, NSMutableString *log) {
    NSString *res = GXTccRes();
    if (![FM() fileExistsAtPath:[res stringByAppendingPathComponent:@"include/tccdefs.h"]]) return GXL(@"В приложении нет файлов компилятора (tcc/)");
    TCCState *s = tcc_new();
    if (!s) return GXL(@"Не удалось запустить компилятор");
    tcc_set_error_func(s, (__bridge void *)log, gxTccError);
    tcc_set_lib_path(s, res.fileSystemRepresentation);
    NSString *name = [[out.lastPathComponent stringByReplacingOccurrencesOfString:@" " withString:@"_"] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
    NSString *opts = exe ? @"-nostdinc -nostdlib -Wall" : [NSString stringWithFormat:@"-nostdinc -nostdlib -Wall -install_name @rpath/%@", name];
    tcc_set_options(s, opts.UTF8String);
    tcc_set_output_type(s, exe ? TCC_OUTPUT_EXE : TCC_OUTPUT_DLL);
    tcc_add_sysinclude_path(s, [res stringByAppendingPathComponent:@"include"].fileSystemRepresentation);
    tcc_add_sysinclude_path(s, [res stringByAppendingPathComponent:@"sdk/include"].fileSystemRepresentation);
    tcc_add_include_path(s, [res stringByAppendingPathComponent:@"gx"].fileSystemRepresentation);
    tcc_add_include_path(s, src.stringByDeletingLastPathComponent.fileSystemRepresentation);
    // Внимание: __IPHONE_OS_VERSION_MIN_REQUIRED не задаём — с ним Availability.h раскрывает
    // __AVAILABILITY_INTERNAL__IPHONE_* (они есть только для clang с __has_attribute(availability))
    tcc_define_symbol(s, "GX_FILES", "1");
    if (exe) tcc_define_symbol(s, "GX_APP", "1");
    int ok = tcc_add_file(s, src.fileSystemRepresentation) >= 0;
    NSMutableArray *all = [NSMutableArray arrayWithObject:@"libSystem"];
    for (NSString *l in libs) if (![all containsObject:l]) [all addObject:l];
    for (NSString *l in all) {
        if (!ok) break;
        NSString *tbd = [[res stringByAppendingPathComponent:@"sdk/lib"] stringByAppendingPathComponent:[l stringByAppendingPathExtension:@"tbd"]];
        if (tcc_add_file(s, tbd.fileSystemRepresentation) < 0) { [log appendFormat:GXL(@"не найдена библиотека %@\n"), l]; ok = 0; }
    }
    [FM() removeItemAtPath:out error:nil];
    if (ok) ok = tcc_output_file(s, out.fileSystemRepresentation) >= 0;
    tcc_delete(s);
    if (!ok) return GXL(@"Ошибки компиляции");
    if ([[FM() attributesOfItemAtPath:out error:nil] fileSize] < 32) return GXL(@"Компилятор не создал файл");
    return nil;
}

// Исполняемый файл приложения (для сборки IPA), без подписи
NSString *GXCompileExecutable(NSString *src, NSString *out, NSArray<NSString *> *libs, NSMutableString *log) {
    __block NSString *err = nil;
    dispatch_sync(GXTccQueue(), ^{ err = GXTccBuild(src, out, libs, YES, log); });
    return err;
}

// Собрать src → out (dylib для iOS arm64), подписать. nil — успех, иначе текст ошибки. log — вывод компилятора
NSString *GXCompileDylib(NSString *src, NSString *out, NSArray<NSString *> *libs, NSMutableString *log) {
    __block NSString *err = nil;
    dispatch_sync(GXTccQueue(), ^{
        err = GXTccBuild(src, out, libs, NO, log);
        if (err) return;
        NSString *name = [[out.lastPathComponent stringByReplacingOccurrencesOfString:@" " withString:@"_"] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        // подпись и проверка результата
        NSData *d = [NSData dataWithContentsOfFile:out];
        if (GXSignEnabled()) {
            // настоящий сертификат — файл уже лежит в out (без подписи)
            NSString *se = GXSignFileWithCert(out, name.stringByDeletingPathExtension, log);
            if (se) { err = se; return; }
            NSData *sd = [NSData dataWithContentsOfFile:out];
            gx_bin b; gx_bin_open(&b, sd.bytes, sd.length, 0);
            BOOL good = b.fmt == 1 && b.arm64; size_t nfn = b.nfn; gx_bin_close(&b);
            if (!good) { err = GXL(@"Получился неверный Mach-O"); return; }
            [log appendFormat:GXL(@"✓ %@ — %@, функций: %zu\n"), name, GXHuman(sd.length), nfn];
            return;
        }
        char e[256] = {0}; size_t ol = 0; int signedN = 0;
        uint8_t *sg = gx_adhoc_sign(d.bytes, d.length, name.stringByDeletingPathExtension.UTF8String, 2, &ol, &signedN, e, sizeof e);
        if (!sg) { err = [NSString stringWithFormat:GXL(@"Подпись: %s"), e]; return; }
        NSData *sd = [NSData dataWithBytesNoCopy:sg length:ol freeWhenDone:YES];
        gx_bin b;
        gx_bin_open(&b, sd.bytes, sd.length, 0);
        BOOL good = b.fmt == 1 && b.arm64;
        size_t nfn = b.nfn;
        gx_bin_close(&b);
        if (!good) { err = GXL(@"Получился неверный Mach-O"); return; }
        if (![sd writeToFile:out atomically:YES]) { err = GXL(@"Не удалось записать dylib"); return; }
        [log appendFormat:GXL(@"✓ %@ — %@, функций: %zu, подписано ad-hoc\n"), name, GXHuman(sd.length), nfn];
    });
    return err;
}

#pragma mark - Экран

@interface GXCompilerVC () <UITextViewDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UITextView *editor, *console;
@property (nonatomic) BOOL dirty;
@property (nonatomic, strong) NSDictionary *lang;           // язык файла (GXRunner.m)
@property (nonatomic, strong, nullable) GXRunJob *job;      // идущий запуск
@end

@implementation GXCompilerVC

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        if (!path) {
            NSString *last = [GXDefaults() stringForKey:@"gxCompilerLast"];
            if (last.length && [FM() fileExistsAtPath:last] && GXCodeLanguageForPath(last)) path = last;   // последний открытый файл
        }
        if (!path) {
            path = [GXCompilerHome() stringByAppendingPathComponent:@"tweak.c"];
            if (![FM() fileExistsAtPath:path]) [[self templateText:@"01_hello"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        _path = path.copy;
        _lang = GXCodeLanguageForPath(path) ?: GXCodeLanguageForID(@"tcc");
        [GXDefaults() setObject:_path forKey:@"gxCompilerLast"];
    }
    return self;
}

- (NSString *)templateText:(NSString *)name {
    NSString *p = [[[GXTccRes() stringByAppendingPathComponent:@"gx/templates"] stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"c"];
    return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] ?: GXL(@"#include <gxkit.h>\n\n__attribute__((constructor))\nstatic void init(void) {\n    gx_log(\"привет\");\n}\n");
}

- (NSString *)outPath { return [self.path.stringByDeletingPathExtension stringByAppendingPathExtension:@"dylib"]; }
- (int)kind { return [self.lang[@"kind"] intValue]; }

// Кнопки справа: собрать/запустить (или стоп, пока идёт запуск) и меню
- (void)setupBar {
    UIBarButtonItem *run;
    if (self.job) run = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"stop.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(stopRun)];
    else run = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:self.kind == 0 ? @"hammer.fill" : @"play.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(build)];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self menu]];
    self.navigationItem.rightBarButtonItems = @[run, more];
}

- (NSString *)introText {
    switch (self.kind) {
        case 0: return [NSString stringWithFormat:GXL(@"Нажми 🔨 чтобы собрать %@\nКомпилятор: TinyCC %s (C99/C11, без Objective-C — используй gxkit.h)\n"), self.outPath.lastPathComponent, "0.9.28"];
        case 1: return [NSString stringWithFormat:GXL(@"Нажми ▶︎ чтобы запустить. %@ выполняется прямо на iPhone (JavaScriptCore), интернет не нужен.\nВвод для readline() — в меню «Ввод (stdin)».\n"), self.lang[@"name"]];
        case 2: return GXL(@"Нажми ▶︎ чтобы запустить. Lua 5.4 работает прямо на iPhone, интернет не нужен.\nВвод для io.read() — в меню «Ввод (stdin)».\n");
        default: return [NSString stringWithFormat:GXL(@"Нажми ▶︎ чтобы скомпилировать и запустить %@.\nКод выполняется на сервере Compiler Explorer (godbolt.org) — нужен интернет. Ввод — в меню «Ввод (stdin)», компилятор — в меню «Компилятор».\n"), self.lang[@"name"]];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.path.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    [self setupBar];

    _editor = [UITextView new];
    _editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _editor.autocorrectionType = UITextAutocorrectionTypeNo;
    _editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _editor.spellCheckingType = UITextSpellCheckingTypeNo;
    _editor.smartQuotesType = UITextSmartQuotesTypeNo;
    _editor.smartDashesType = UITextSmartDashesTypeNo;
    _editor.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    _editor.keyboardType = UIKeyboardTypeASCIICapable;
    _editor.delegate = self;
    _editor.alwaysBounceVertical = YES;
    _editor.text = [NSString stringWithContentsOfFile:self.path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    _editor.inputAccessoryView = [self keyBar];
    if (@available(iOS 16.0, *)) _editor.findInteractionEnabled = YES;

    _console = [UITextView new];
    _console.editable = NO;
    _console.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _console.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _console.textColor = UIColor.secondaryLabelColor;
    _console.text = [self introText];

    for (UIView *v in @[_editor, _console]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_editor.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_editor.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_editor.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_console.topAnchor constraintEqualToAnchor:_editor.bottomAnchor],
        [_console.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_console.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_console.heightAnchor constraintEqualToConstant:150],
        [_console.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; [self save]; }
- (void)close { [self.job cancel]; self.job = nil; [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)textViewDidChange:(UITextView *)tv { self.dirty = YES; }

- (void)save {
    if (!self.dirty) return;
    [self.editor.text writeToFile:self.path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    self.dirty = NO;
}

// Панель над клавиатурой с символами, которых нет на основной раскладке iPhone
- (UIView *)keyBar {
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    sv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    sv.showsHorizontalScrollIndicator = NO;
    NSArray *keys = @[@"⇥", @"{", @"}", @"(", @")", @";", @"\"", @"*", @"&", @"[", @"]", @"#", @"<", @">", @"=", @"!", @"|", @"->", @"_", @"/", @"\\", @"%", @"⌨︎"];
    CGFloat x = 6;
    for (NSString *k in keys) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:k forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightMedium];
        b.backgroundColor = UIColor.tertiarySystemBackgroundColor;
        b.layer.cornerRadius = 6;
        CGFloat w = MAX(36, [k sizeWithAttributes:@{NSFontAttributeName: b.titleLabel.font}].width + 16);
        b.frame = CGRectMake(x, 5, w, 34);
        [b addTarget:self action:@selector(keyTap:) forControlEvents:UIControlEventTouchUpInside];
        [sv addSubview:b];
        x += w + 6;
    }
    sv.contentSize = CGSizeMake(x, 44);
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    return sv;
}
- (void)keyTap:(UIButton *)b {
    NSString *k = [b titleForState:UIControlStateNormal];
    if ([k isEqualToString:@"⌨︎"]) { [self.editor resignFirstResponder]; return; }
    [self.editor insertText:[k isEqualToString:@"⇥"] ? @"    " : k];
}

- (UIMenu *)menu {
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *img, void (^b)(void)) { return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:img] identifier:nil handler:^(UIAction *x) { b(); }]; };
    NSMutableArray *items = [NSMutableArray array];
    if (self.kind == 0) {
        NSArray *tpl = @[@[GXL(@"Привет: алерт при загрузке"), @"01_hello"], @[GXL(@"Хук метода Objective-C"), @"02_hook_method"], @[GXL(@"Хук C-функции (как fishhook)"), @"03_hook_function"],
                         @[GXL(@"Подмена результата метода (YES)"), @"04_return_value"], @[GXL(@"Библиотека с функциями"), @"05_library"]];
        NSMutableArray *ta = [NSMutableArray array];
        for (NSArray *t in tpl) [ta addObject:act(t[0], @"doc.text", ^{ [ws useTemplate:t[1]]; })];
        [items addObject:[UIMenu menuWithTitle:GXL(@"Шаблоны") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil options:0 children:ta]];
        NSArray *atpl = @[@[GXL(@"Приложение «Привет» (счётчик)"), @"app_01_hello"], @[GXL(@"Мини-игра «Поймай кружок»"), @"app_02_game"], @[GXL(@"Приложение «Заметка»"), @"app_03_notes"]];
        NSMutableArray *aa = [NSMutableArray array];
        for (NSArray *t in atpl) [aa addObject:act(t[0], @"app", ^{ [ws useTemplate:t[1]]; })];
        [items addObject:[UIMenu menuWithTitle:GXL(@"Шаблоны приложений (IPA)") image:[UIImage systemImageNamed:@"apps.iphone"] identifier:nil options:0 children:aa]];
        [items addObject:act(GXL(@"Собрать IPA…"), @"shippingbox.and.arrow.backward", ^{ [ws buildIPA]; })];
        [items addObject:act(GXL(@"Запустить как программу (онлайн, gcc)"), @"play.circle", ^{ [ws runAs:GXCodeLanguageForID(@"c")]; })];
        [items addObject:act(GXL(@"Библиотеки для линковки…"), @"shippingbox", ^{ [ws chooseLibs]; })];
        [items addObject:act(GXL(@"Подпись сертификатом…"), @"signature", ^{ [ws.navigationController pushViewController:[GXSignVC new] animated:YES]; })];
    } else {
        [items addObject:act(GXL(@"Шаблон «Привет»"), @"doc.text", ^{ [ws useLangTemplate]; })];
        if (self.kind == 3) {
            [items addObject:act(GXL(@"Компилятор…"), @"cpu", ^{ [ws.navigationController pushViewController:[[GXCEPickerVC alloc] initWithLanguage:ws.lang] animated:YES]; })];
            [items addObject:act(GXL(@"Флаги компилятора…"), @"slider.horizontal.3", ^{ [ws editFlags]; })];
        }
    }
    [items addObject:act(GXL(@"Ввод (stdin)…"), @"keyboard", ^{ [ws.navigationController pushViewController:[GXStdinVC new] animated:YES]; })];
    [items addObject:act(GXL(@"Новый файл…"), @"doc.badge.plus", ^{ [ws newFile]; })];
    [items addObject:act(GXL(@"Папка с исходниками"), @"folder", ^{ [ws openFolder]; })];
    if (self.kind == 0) {
        [items addObject:act(GXL(@"Справка по gxkit.h"), @"questionmark.circle", ^{ [ws help]; })];
        [items addObject:act(GXL(@"Лицензия TinyCC (LGPL)"), @"doc.plaintext", ^{ [ws license]; })];
    } else if (self.kind == 2) {
        [items addObject:act(GXL(@"Лицензия Lua (MIT)"), @"doc.plaintext", ^{ [ws luaLicense]; })];
    }
    return [UIMenu menuWithChildren:items];
}

- (void)buildIPA {
    [self save];
    NSString *t = self.editor.text ?: @"";
    if ([t rangeOfString:@"\\bmain\\s*\\(" options:NSRegularExpressionSearch].location == NSNotFound) {
        GXConfirm(self, GXL(@"Нет функции main()"), GXL(@"Для IPA нужен код приложения с main(), а это похоже на твик. Подставить шаблон приложения?"), GXL(@"Подставить"), NO, ^{
            self.editor.text = [self templateText:@"app_01_hello"]; self.dirty = YES; [self save];
            [self.navigationController pushViewController:[[GXIpaBuildVC alloc] initWithSource:self.path libs:GXEnabledLibs()] animated:YES];
        });
        return;
    }
    [self.navigationController pushViewController:[[GXIpaBuildVC alloc] initWithSource:self.path libs:GXEnabledLibs()] animated:YES];
}

- (void)useLangTemplate {
    NSString *t = GXCodeTemplate(self.lang);
    GXConfirm(self, GXL(@"Заменить код шаблоном?"), GXL(@"Текущий текст в редакторе будет заменён."), GXL(@"Заменить"), YES, ^{
        self.editor.text = t; self.dirty = YES; [self save];
    });
}

- (void)editFlags {
    NSString *ce = self.lang[@"id"];
    GXPrompt(self, GXL(@"Флаги компилятора"), GXL(@"Например -O2 -std=c++20 -Wall. Пусто — по умолчанию."), GXCEArgs(ce), @"-O2", GXL(@"Сохранить"), ^(NSString *v) {
        GXCESetArgs(ce, v);
    });
}

- (void)luaLicense {
    NSString *t = [NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"LICENSE-Lua" ofType:@"txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    t = [GXL(@"Встроенный интерпретатор — Lua 5.4 (https://www.lua.org), лицензия MIT.\n\n") stringByAppendingString:t];
    [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:@"Lua" text:t] animated:YES];
}

// Запуск (JS/Lua на устройстве или онлайн через Compiler Explorer)
- (void)runAs:(NSDictionary *)lang {
    self.dirty = YES;
    [self save];
    [self.editor resignFirstResponder];
    self.console.textColor = UIColor.secondaryLabelColor;
    self.console.text = [lang[@"kind"] intValue] == 3 ? GXL(@"Компиляция и запуск на сервере…\n") : GXL(@"Выполнение…\n");
    __weak typeof(self) ws = self;
    self.job = GXRunCode(lang, self.editor.text ?: @"", self.path.lastPathComponent, GXRunnerStdin(), ^(NSAttributedString *out, BOOL ok) {
        GXCompilerVC *me = ws; if (!me) return;
        me.job = nil;
        [me setupBar];
        me.console.attributedText = out;
        [me.console scrollRangeToVisible:NSMakeRange(0, 0)];
        if (!ok) [me jumpToFirstError:out.string];
    });
    [self setupBar];
}

- (void)stopRun {
    [self.job cancel];
    self.job = nil;
    [self setupBar];
    self.console.textColor = UIColor.systemOrangeColor;
    self.console.text = GXL(@"Остановлено\n");
}

- (void)useTemplate:(NSString *)name {
    NSString *t = [self templateText:name];
    GXConfirm(self, GXL(@"Заменить код шаблоном?"), GXL(@"Текущий текст в редакторе будет заменён."), GXL(@"Заменить"), YES, ^{
        self.editor.text = t; self.dirty = YES; [self save];
    });
}

- (void)newFile {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Новый файл") message:GXL(@"Выбери язык") preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"C (приложение → IPA)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        GXPrompt(self, GXL(@"Новое приложение"), GXL(@"Имя .c файла в папке GX Compiler"), @"my_app.c", nil, GXL(@"Создать"), ^(NSString *v) {
            NSString *n = v.length ? v : @"my_app.c";
            if (![n.pathExtension.lowercaseString isEqualToString:@"c"]) n = [n stringByAppendingPathExtension:@"c"];
            NSString *p = GXUniquePath(GXCompilerHome(), n);
            [[self templateText:@"app_01_hello"] writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [self save];
            [self switchToPath:p];
        });
    }]];
    for (NSDictionary *l in GXCodeLanguages()) {
        if (![l[@"ext"] count]) continue;   // «C (программа)» — запускается из .c через меню
        NSString *title = l[@"name"];
        int k = [l[@"kind"] intValue];
        if (k == 1 || k == 2) title = [title stringByAppendingString:GXL(@" · офлайн")];
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self newFileForLang:l]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)newFileForLang:(NSDictionary *)lang {
    BOOL tcc = [lang[@"kind"] intValue] == 0;
    NSString *ext = GXCodeLanguageExt(lang);
    NSString *def = tcc ? @"my_tweak.c" : [@"main" stringByAppendingPathExtension:ext];
    GXPrompt(self, [NSString stringWithFormat:GXL(@"Новый файл · %@"), lang[@"name"]], GXL(@"Имя файла в папке GX Compiler"), def, nil, GXL(@"Создать"), ^(NSString *v) {
        NSString *n = v.length ? v : def;
        if (![lang[@"ext"] containsObject:n.pathExtension.lowercaseString]) n = [n stringByAppendingPathExtension:ext];
        NSString *p = GXUniquePath(GXCompilerHome(), n);
        NSString *text = tcc ? [self templateText:@"01_hello"] : GXCodeTemplate(lang);
        [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self save];
        [self switchToPath:p];
    });
}

- (void)switchToPath:(NSString *)p {
    [self.job cancel]; self.job = nil;
    self.path = p; self.title = p.lastPathComponent;
    self.lang = GXCodeLanguageForPath(p) ?: GXCodeLanguageForID(@"tcc");
    [GXDefaults() setObject:p forKey:@"gxCompilerLast"];
    self.editor.text = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.dirty = NO;
    self.console.textColor = UIColor.secondaryLabelColor;
    self.console.text = [self introText];
    [self setupBar];
}

- (void)openFolder {
    [self save];
    [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:self.path.stringByDeletingLastPathComponent] animated:YES];
}

- (void)chooseLibs {
    [self.navigationController pushViewController:[GXLibsVC new] animated:YES];
}

- (void)help {
    NSString *t = GXL(@"Компилятор собирает C → arm64 dylib прямо на iPhone. Это C-компилятор (TinyCC), а не Objective-C, поэтому писать [view setAlpha:0.5] нельзя. Но все классы iOS (UIKit, Foundation, AVFoundation и 90+ других фреймворков) доступны — ты вызываешь их через Objective-C рантайм макросами GX_MSG. gxkit.h — не замена UIKit, а мостик из C в любой класс iOS.\n\n"
    "Фреймворки для линковки включаются в меню «Библиотеки». У базовых C-фреймворков есть заголовки (CoreGraphics, CommonCrypto, CoreFoundation) — обычный #include. Остальные (UIKit, AVFoundation, Security…) вызывай через GX_MSG или объяви нужные прототипы сам.\n\n"
    "gxkit.h — помощники для твиков на C:\n\n"
    "GX_CLS(\"UIView\") — класс\nGX_SEL(\"setAlpha:\") — селектор\n"
    "GX_MSG0(тип, объект, \"селектор\")\nGX_MSG1(тип, объект, \"сел:\", тип1, арг1) … до GX_MSG5\n"
    "  пример: GX_MSG1(void, view, \"setAlpha:\", CGFloat, 0.5);\n\n"
    "gx_str(\"текст\") — NSString, gx_cstr(nsstr) — char*\n"
    "gx_num_i/gx_num_d/gx_num_b — NSNumber; gx_int/gx_double/gx_bool — обратно\n"
    "gx_alloc(\"UIView\") — alloc+init; gx_prop(obj,\"имя\") / gx_setprop(obj,\"имя\",знач) — свойства по имени (KVC)\n"
    "gx_log(\"формат %d\", x) — в системный лог (NSLog)\n"
    "gx_alert(\"заголовок\", \"текст\") — алерт (на главном потоке)\n"
    "gx_main(fn, ctx), gx_main_after(сек, fn, ctx) — выполнить на главном потоке\n"
    "gx_top_vc() — верхний экран приложения\n\n"
    "gx_hook_method(\"Класс\", \"селектор:\", 0, (IMP)моя, (IMP*)&оригинал) — хук метода (1 — метод класса +)\n"
    "gx_rebind(\"функция\", моя, (void**)&оригинал) — хук C-функции через импорт\n"
    "gx_image_base(\"UnityFramework\") — адрес загрузки библиотеки в памяти\n\n"
    "Готовый .dylib появляется рядом с .c. Внедрить в приложение: Инструменты приложения → «Внедрить dylib».");
    [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:@"gxkit.h" text:t] animated:YES];
}

- (void)license {
    NSString *t = [NSString stringWithContentsOfFile:[GXTccRes() stringByAppendingPathComponent:@"LICENSE-TinyCC.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    t = [GXL(@"Встроенный компилятор — TinyCC (https://github.com/TinyCC/tinycc), лицензия GNU LGPL 2.1. Исходники и изменения GX Files — в папке tcc/ проекта.\n\n") stringByAppendingString:t];
    [self.navigationController pushViewController:[[GXReportVC alloc] initWithTitle:@"TinyCC" text:t] animated:YES];
}

- (void)build {
    if (self.kind != 0) { [self runAs:self.lang]; return; }
    self.dirty = YES;
    [self save];
    [self.editor resignFirstResponder];
    NSString *src = self.path, *out = self.outPath;
    NSArray *libs = GXEnabledLibs();
    NSMutableString *log = [NSMutableString string];
    self.console.text = GXL(@"Сборка…\n");
    self.console.textColor = UIColor.secondaryLabelColor;
    [GXHUD showIn:self.view text:GXL(@"Компиляция…")];
    NSDate *t0 = [NSDate date];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = GXCompileDylib(src, out, libs, log);
        double ms = -[t0 timeIntervalSinceNow] * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            NSString *text = log.length ? log : @"";
            if (err) {
                self.console.textColor = UIColor.systemRedColor;
                self.console.text = [NSString stringWithFormat:GXL(@"%@%@ (%.0f мс)"), text, err, ms];
                [self jumpToFirstError:text];
                return;
            }
            self.console.textColor = UIColor.systemGreenColor;
            self.console.text = [NSString stringWithFormat:GXL(@"%@Готово за %.0f мс → %@"), text, ms, out.lastPathComponent];
            [self builtOK:out];
        });
    });
}

// Перейти к строке первой ошибки: «файл:строка: error: …»
- (void)jumpToFirstError:(NSString *)log {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@":(\\d+):" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:log options:0 range:NSMakeRange(0, log.length)];
    if (!m) return;
    NSInteger line = [[log substringWithRange:[m rangeAtIndex:1]] integerValue];
    NSString *t = self.editor.text;
    __block NSInteger cur = 1; __block NSRange r = NSMakeRange(NSNotFound, 0);
    [t enumerateSubstringsInRange:NSMakeRange(0, t.length) options:NSStringEnumerationByLines usingBlock:^(NSString *s, NSRange sr, NSRange er, BOOL *stop) {
        if (cur == line) { r = sr; *stop = YES; }
        cur++;
    }];
    if (r.location == NSNotFound) return;
    [self.editor becomeFirstResponder];
    self.editor.selectedRange = r;
    [self.editor scrollRangeToVisible:r];
}

- (void)builtOK:(NSString *)out {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"dylib готов") message:[NSString stringWithFormat:GXL(@"%@\nПодписан ad-hoc. Внедрить в приложение: Инструменты приложения → «Внедрить dylib»."), out.lastPathComponent] preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Открыть в редакторе dylib") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        GXPresentNav(self, [[GXBinEditorVC alloc] initWithPath:out], YES);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Поделиться…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:out]] applicationActivities:nil];
        av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
        [self presentViewController:av animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Показать в папке") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self openFolder]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Экран выбора библиотек

@interface GXLibsVC () <UISearchResultsUpdating>
@end

@implementation GXLibsVC {
    NSArray<NSDictionary *> *_groups;     // показываемые группы (с учётом поиска)
}
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = GXL(@"Библиотеки"); return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    _groups = GXLibGroups();
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self; sc.obscuresBackgroundDuringPresentation = NO;
    sc.searchBar.placeholder = GXL(@"Найти фреймворк");
    self.navigationItem.searchController = sc; self.navigationItem.hidesSearchBarWhenScrolling = NO;
    __weak typeof(self) ws = self;
    UIAction *none = [UIAction actionWithTitle:GXL(@"Снять все") image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(UIAction *x) {
        [NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"GXCompilerLibs"]; [ws.tableView reloadData]; }];
    UIAction *base = [UIAction actionWithTitle:GXL(@"Только основные") image:[UIImage systemImageNamed:@"star"] identifier:nil handler:^(UIAction *x) {
        [NSUserDefaults.standardUserDefaults setObject:@[@"libobjc", @"Foundation", @"CoreFoundation", @"UIKit"] forKey:@"GXCompilerLibs"]; [ws.tableView reloadData]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[base, none]]];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = [sc.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!q.length) { _groups = GXLibGroups(); [self.tableView reloadData]; return; }
    NSMutableArray *g = [NSMutableArray array];
    for (NSDictionary *grp in GXLibGroups()) {
        NSArray *f = [grp[@"libs"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", q]];
        if (f.count) [g addObject:@{@"name": grp[@"name"], @"libs": f}];
    }
    _groups = g; [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return MAX((NSInteger)_groups.count, 1); }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _groups.count ? (NSInteger)[_groups[s][@"libs"] count] : 1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _groups.count ? _groups[s][@"name"] : nil; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (!_groups.count || s != (NSInteger)_groups.count - 1) return nil;
    return GXL(@"Отмеченные подключаются к dylib. libSystem (libc, Objective-C рантайм) подключается всегда. Заголовки есть у базовых C-фреймворков (CoreGraphics, CommonCrypto, CoreFoundation); остальные (UIKit, AVFoundation и др.) вызывай через gxkit.h — макросы GX_MSG.");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (!_groups.count) { c.textLabel.text = GXL(@"Ничего не найдено"); c.textLabel.textColor = UIColor.secondaryLabelColor; c.selectionStyle = UITableViewCellSelectionStyleNone; return c; }
    NSString *l = _groups[ip.section][@"libs"][ip.row];
    c.textLabel.text = l;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    c.accessoryType = [GXEnabledLibs() containsObject:l] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_groups.count) return;
    NSString *l = _groups[ip.section][@"libs"][ip.row];
    NSMutableArray *m = [GXEnabledLibs() mutableCopy];
    if ([m containsObject:l]) [m removeObject:l]; else [m addObject:l];
    [NSUserDefaults.standardUserDefaults setObject:m forKey:@"GXCompilerLibs"];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}
@end

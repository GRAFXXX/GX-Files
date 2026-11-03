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

static NSArray<NSString *> *GXAllLibs(void) {
    return @[@"libobjc", @"Foundation", @"CoreFoundation", @"UIKit", @"CoreGraphics", @"QuartzCore", @"libz", @"libsqlite3"];
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

// Собрать src → out (dylib для iOS arm64), подписать. nil — успех, иначе текст ошибки. log — вывод компилятора
NSString *GXCompileDylib(NSString *src, NSString *out, NSArray<NSString *> *libs, NSMutableString *log) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("gx.tcc", DISPATCH_QUEUE_SERIAL); });
    __block NSString *err = nil;
    dispatch_sync(q, ^{
        NSString *res = GXTccRes();
        if (![FM() fileExistsAtPath:[res stringByAppendingPathComponent:@"include/tccdefs.h"]]) { err = GXL(@"В приложении нет файлов компилятора (tcc/)"); return; }
        TCCState *s = tcc_new();
        if (!s) { err = GXL(@"Не удалось запустить компилятор"); return; }
        tcc_set_error_func(s, (__bridge void *)log, gxTccError);
        tcc_set_lib_path(s, res.fileSystemRepresentation);
        NSString *name = [[out.lastPathComponent stringByReplacingOccurrencesOfString:@" " withString:@"_"] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        NSString *opts = [NSString stringWithFormat:@"-nostdinc -nostdlib -Wall -install_name @rpath/%@", name];
        tcc_set_options(s, opts.UTF8String);
        tcc_set_output_type(s, TCC_OUTPUT_DLL);
        tcc_add_sysinclude_path(s, [res stringByAppendingPathComponent:@"include"].fileSystemRepresentation);
        tcc_add_sysinclude_path(s, [res stringByAppendingPathComponent:@"sdk/include"].fileSystemRepresentation);
        tcc_add_include_path(s, [res stringByAppendingPathComponent:@"gx"].fileSystemRepresentation);
        tcc_add_include_path(s, src.stringByDeletingLastPathComponent.fileSystemRepresentation);
        // Внимание: __IPHONE_OS_VERSION_MIN_REQUIRED не задаём — с ним Availability.h раскрывает
        // __AVAILABILITY_INTERNAL__IPHONE_* (они есть только для clang с __has_attribute(availability))
        tcc_define_symbol(s, "GX_FILES", "1");
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
        if (!ok) { err = GXL(@"Ошибки компиляции"); return; }
        // подпись и проверка результата
        NSData *d = [NSData dataWithContentsOfFile:out];
        if (d.length < 32) { err = GXL(@"Компилятор не создал файл"); return; }
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
@end

@implementation GXCompilerVC

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        if (!path) {
            path = [GXCompilerHome() stringByAppendingPathComponent:@"tweak.c"];
            if (![FM() fileExistsAtPath:path]) [[self templateText:@"01_hello"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        _path = path.copy;
    }
    return self;
}

- (NSString *)templateText:(NSString *)name {
    NSString *p = [[[GXTccRes() stringByAppendingPathComponent:@"gx/templates"] stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"c"];
    return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] ?: GXL(@"#include <gxkit.h>\n\n__attribute__((constructor))\nstatic void init(void) {\n    gx_log(\"привет\");\n}\n");
}

- (NSString *)outPath { return [self.path.stringByDeletingPathExtension stringByAppendingPathExtension:@"dylib"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.path.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    UIBarButtonItem *run = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"hammer.fill"] style:UIBarButtonItemStylePlain target:self action:@selector(build)];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self menu]];
    self.navigationItem.rightBarButtonItems = @[run, more];

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
    _console.text = [NSString stringWithFormat:GXL(@"Нажми 🔨 чтобы собрать %@\nКомпилятор: TinyCC %s (C99/C11, без Objective-C — используй gxkit.h)\n"), self.outPath.lastPathComponent, "0.9.28"];

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
- (void)close { [self save]; [self dismissViewControllerAnimated:YES completion:nil]; }
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
    NSArray *tpl = @[@[GXL(@"Привет: алерт при загрузке"), @"01_hello"], @[GXL(@"Хук метода Objective-C"), @"02_hook_method"], @[GXL(@"Хук C-функции (как fishhook)"), @"03_hook_function"],
                     @[GXL(@"Подмена результата метода (YES)"), @"04_return_value"], @[GXL(@"Библиотека с функциями"), @"05_library"]];
    NSMutableArray *ta = [NSMutableArray array];
    for (NSArray *t in tpl) [ta addObject:act(t[0], @"doc.text", ^{ [ws useTemplate:t[1]]; })];
    return [UIMenu menuWithChildren:@[
        [UIMenu menuWithTitle:GXL(@"Шаблоны") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil options:0 children:ta],
        act(GXL(@"Библиотеки для линковки…"), @"shippingbox", ^{ [ws chooseLibs]; }),
        act(GXL(@"Новый файл…"), @"doc.badge.plus", ^{ [ws newFile]; }),
        act(GXL(@"Папка с исходниками"), @"folder", ^{ [ws openFolder]; }),
        act(GXL(@"Справка по gxkit.h"), @"questionmark.circle", ^{ [ws help]; }),
        act(GXL(@"Лицензия TinyCC (LGPL)"), @"doc.plaintext", ^{ [ws license]; }),
    ]];
}

- (void)useTemplate:(NSString *)name {
    NSString *t = [self templateText:name];
    GXConfirm(self, GXL(@"Заменить код шаблоном?"), GXL(@"Текущий текст в редакторе будет заменён."), GXL(@"Заменить"), YES, ^{
        self.editor.text = t; self.dirty = YES; [self save];
    });
}

- (void)newFile {
    GXPrompt(self, GXL(@"Новый файл"), GXL(@"Имя .c файла в папке GX Compiler"), @"my_tweak.c", nil, GXL(@"Создать"), ^(NSString *v) {
        NSString *n = v.length ? v : @"my_tweak.c";
        if (![n.pathExtension.lowercaseString isEqualToString:@"c"]) n = [n stringByAppendingPathExtension:@"c"];
        NSString *p = GXUniquePath(GXCompilerHome(), n);
        [[self templateText:@"01_hello"] writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self save];
        self.path = p; self.title = p.lastPathComponent;
        self.editor.text = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        self.console.text = [NSString stringWithFormat:GXL(@"Новый файл: %@\n"), p.lastPathComponent];
    });
}

- (void)openFolder {
    [self save];
    [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:self.path.stringByDeletingLastPathComponent] animated:YES];
}

- (void)chooseLibs {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Библиотеки") message:GXL(@"Отмеченные подключаются к dylib (libSystem — всегда). Нажми, чтобы включить/выключить.") preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *en = GXEnabledLibs();
    for (NSString *l in GXAllLibs()) {
        BOOL on = [en containsObject:l];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ %@", on ? @"✓" : @"   ", l] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSMutableArray *m = [GXEnabledLibs() mutableCopy];
            if (on) [m removeObject:l]; else [m addObject:l];
            [NSUserDefaults.standardUserDefaults setObject:m forKey:@"GXCompilerLibs"];
            [self chooseLibs];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Готово") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)help {
    NSString *t = GXL(@"gxkit.h — помощники для твиков на C:\n\n"
    "GX_CLS(\"UIView\") — класс\nGX_SEL(\"setAlpha:\") — селектор\n"
    "GX_MSG0(тип, объект, \"селектор\")\nGX_MSG1(тип, объект, \"сел:\", тип1, арг1) … до GX_MSG5\n"
    "  пример: GX_MSG1(void, view, \"setAlpha:\", CGFloat, 0.5);\n\n"
    "gx_str(\"текст\") — NSString, gx_cstr(nsstr) — char*\n"
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

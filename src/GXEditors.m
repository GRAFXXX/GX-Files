// Текстовый редактор с подсветкой, просмотрщик больших текстов, hex-редактор, отчёт
#import "GXCore.h"
#include <sys/stat.h>
#include <fcntl.h>

#pragma mark - Подсветка синтаксиса

static NSArray *GXHighlightRules(NSString *ext) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    ext = ext.lowercaseString;
    NSString *lang;
    if ([@[@"json", @"geojson", @"json5", @"jsonc", @"har", @"webmanifest", @"ipynb"] containsObject:ext]) lang = @"json";
    else if ([@[@"xml", @"plist", @"html", @"htm", @"xhtml", @"svg", @"xib", @"storyboard", @"entitlements", @"xaml", @"vue"] containsObject:ext]) lang = @"xml";
    else if ([@[@"strings"] containsObject:ext]) lang = @"strings";
    else if ([@[@"py", @"sh", @"bash", @"zsh", @"rb", @"pl", @"yml", @"yaml", @"toml", @"ini", @"cfg", @"conf", @"properties", @"env", @"gd", @"r", @"ps1", @"cmake", @"makefile", @"mk"] containsObject:ext]) lang = @"hash";
    else if ([@[@"lua", @"sql"] containsObject:ext]) lang = @"dash";
    else if ([@[@"c", @"h", @"m", @"mm", @"cpp", @"cc", @"cxx", @"hpp", @"hh", @"swift", @"java", @"kt", @"kts", @"gradle", @"go", @"rs",
                @"js", @"mjs", @"cjs", @"ts", @"tsx", @"jsx", @"cs", @"dart", @"css", @"scss", @"less", @"php", @"hlsl", @"glsl", @"shader",
                @"cginc", @"metal", @"smali", @"xcconfig", @"pbxproj"] containsObject:ext]) lang = @"c";
    else return nil;
    if (cache[lang]) return cache[lang];
    UIColor *str = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0.99 green:0.42 blue:0.36 alpha:1] : [UIColor colorWithRed:0.77 green:0.10 blue:0.09 alpha:1]; }];
    UIColor *num = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0.82 green:0.75 blue:0.50 alpha:1] : [UIColor colorWithRed:0.11 green:0.0 blue:0.81 alpha:1]; }];
    UIColor *kw = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithRed:0.99 green:0.37 blue:0.64 alpha:1] : [UIColor colorWithRed:0.61 green:0.14 blue:0.58 alpha:1]; }];
    UIColor *com = UIColor.systemGrayColor;
    UIColor *tag = UIColor.systemTealColor;
    UIColor *attr = UIColor.systemOrangeColor;
    NSMutableArray *r = [NSMutableArray array];
    void (^add)(NSString *, UIColor *, NSRegularExpressionOptions) = ^(NSString *p, UIColor *c, NSRegularExpressionOptions o) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p options:o error:nil];
        if (re) [r addObject:@[re, c]];
    };
    if ([lang isEqualToString:@"json"]) {
        add(@"\\b-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?\\b", num, 0);
        add(@"\\b(true|false|null)\\b", kw, 0);
        add(@"\"(?:[^\"\\\\\\n]|\\\\.)*\"", str, 0);
        add(@"\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*:)", attr, 0);
    } else if ([lang isEqualToString:@"xml"]) {
        add(@"</?[A-Za-z_][\\w:.-]*|/?>", tag, 0);
        add(@"\\b[\\w:.-]+(?==)", attr, 0);
        add(@"\"[^\"]*\"|'[^']*'", str, 0);
        add(@"<!--[\\s\\S]*?-->", com, 0);
        add(@"<!\\[CDATA\\[[\\s\\S]*?\\]\\]>", com, 0);
    } else if ([lang isEqualToString:@"strings"]) {
        add(@"\"(?:[^\"\\\\\\n]|\\\\.)*\"", str, 0);
        add(@"^\\s*\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*=)", attr, NSRegularExpressionAnchorsMatchLines);
        add(@"/\\*[\\s\\S]*?\\*/|//[^\\n]*", com, 0);
    } else {
        NSString *kws = @"\\b(if|else|for|while|do|switch|case|default|break|continue|return|func|function|def|class|struct|enum|interface|protocol|"
                         "extension|import|from|export|let|var|val|const|static|public|private|protected|internal|final|override|void|int|long|float|"
                         "double|char|bool|BOOL|id|self|super|this|nil|null|NULL|None|true|false|True|False|YES|NO|new|delete|try|catch|throw|throws|"
                         "async|await|in|is|as|and|or|not|elif|lambda|yield|with|pass|local|then|end|fun|object|package|namespace|using|template|"
                         "typename|typedef|unsigned|signed|inline|extern|virtual|guard|where|select|insert|update|create|table|values|into|set|"
                         "@interface|@implementation|@end|@property|@synthesize|#include|#import|#define|#if|#ifdef|#ifndef|#endif|#pragma)\\b";
        add(@"\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b", num, 0);
        add(kws, kw, [lang isEqualToString:@"dash"] ? NSRegularExpressionCaseInsensitive : 0);
        add(@"#(include|import|define|if|ifdef|ifndef|endif|pragma|else|elif|undef)\\b[^\\n]*", kw, 0);
        add(@"\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'|`[^`]*`", str, 0);
        if ([lang isEqualToString:@"hash"]) add(@"(^|\\s)#[^\\n]*", com, NSRegularExpressionAnchorsMatchLines);
        else if ([lang isEqualToString:@"dash"]) add(@"--[^\\n]*", com, 0);
        else add(@"/\\*[\\s\\S]*?\\*/|//[^\\n]*", com, 0);
    }
    cache[lang] = r;
    return r;
}

#pragma mark - Текстовый редактор

@interface GXTextEditorVC () <UITextViewDelegate>
@end

@implementation GXTextEditorVC {
    NSString *_path;
    NSString *_initialText;
    UITextView *_tv;
    NSStringEncoding _enc;
    BOOL _bom;
    BOOL _dirty;
    NSLayoutConstraint *_bottom;
    NSArray *_rules;
    NSTimer *_hlTimer;
    BOOL _wrap;
    BOOL _binaryMode;
}

- (instancetype)initWithPath:(NSString *)path { if ((self = [super init])) { _path = path; _enc = NSUTF8StringEncoding; } return self; }
- (instancetype)initWithText:(NSString *)text title:(NSString *)title {
    if ((self = [super init])) { _initialText = text; self.title = title; _readOnly = YES; _enc = NSUTF8StringEncoding; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (_path) self.title = _path.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _wrap = ![GXDefaults() boolForKey:@"gxNoWrap"];
    if (@available(iOS 16.0, *)) _tv = [UITextView textViewUsingTextLayoutManager:NO];
    else _tv = [UITextView new];
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat fs = [GXDefaults() floatForKey:@"gxFontSize"] ?: 13;
    _tv.font = [UIFont monospacedSystemFontOfSize:fs weight:UIFontWeightRegular];
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv.smartQuotesType = UITextSmartQuotesTypeNo;
    _tv.smartDashesType = UITextSmartDashesTypeNo;
    _tv.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    _tv.spellCheckingType = UITextSpellCheckingTypeNo;
    _tv.alwaysBounceVertical = YES;
    _tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tv.delegate = self;
    if (_saveHandler) _readOnly = NO;
    _tv.editable = !_readOnly;
    _tv.textContainerInset = UIEdgeInsetsMake(8, 4, 8, 4);
    if (@available(iOS 16.0, *)) _tv.findInteractionEnabled = YES;
    [self.view addSubview:_tv];
    _bottom = [_tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [_tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor], _bottom]];
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Закрыть") style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    [self buildItems];
    if (!_readOnly) _tv.inputAccessoryView = [self accessoryBar];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(kb:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [self applyWrap];
    [self load];
}

- (void)buildItems {
    __weak typeof(self) ws = self;
    NSMutableArray *acts = [NSMutableArray array];
    [acts addObject:[UIAction actionWithTitle:GXL(@"Найти и заменить") image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *a) { [ws find]; }]];
    [acts addObject:[UIAction actionWithTitle:GXL(@"Перейти к строке…") image:[UIImage systemImageNamed:@"arrow.down.to.line"] identifier:nil handler:^(UIAction *a) { [ws gotoLine]; }]];
    NSString *ext = (_path ?: self.title).pathExtension.lowercaseString;
    if ([@[@"json", @"geojson", @"har", @"webmanifest", @"ipynb"] containsObject:ext] && !_readOnly) {
        [acts addObject:[UIAction actionWithTitle:GXL(@"Форматировать JSON") image:[UIImage systemImageNamed:@"text.alignleft"] identifier:nil handler:^(UIAction *a) { [ws formatJSON:YES]; }]];
        [acts addObject:[UIAction actionWithTitle:GXL(@"Сжать JSON") image:[UIImage systemImageNamed:@"arrow.right.and.line.vertical.and.arrow.left"] identifier:nil handler:^(UIAction *a) { [ws formatJSON:NO]; }]];
    }
    UIMenu *view = [UIMenu menuWithTitle:GXL(@"Вид") image:[UIImage systemImageNamed:@"textformat.size"] identifier:nil options:0 children:@[
        [UIAction actionWithTitle:GXL(@"Шрифт крупнее") image:[UIImage systemImageNamed:@"plus.magnifyingglass"] identifier:nil handler:^(UIAction *a) { [ws font:1]; }],
        [UIAction actionWithTitle:GXL(@"Шрифт мельче") image:[UIImage systemImageNamed:@"minus.magnifyingglass"] identifier:nil handler:^(UIAction *a) { [ws font:-1]; }],
        [UIAction actionWithTitle:_wrap ? GXL(@"Без переноса строк") : GXL(@"С переносом строк") image:[UIImage systemImageNamed:@"arrow.uturn.down"] identifier:nil handler:^(UIAction *a) { [ws toggleWrap]; }],
    ]];
    [acts addObject:view];
    if (_path) {
        NSMutableArray *encs = [NSMutableArray array];
        NSArray *list = @[@[@"UTF-8", @(NSUTF8StringEncoding)], @[@"UTF-16", @(NSUTF16StringEncoding)], @[@"Windows-1251", @(NSWindowsCP1251StringEncoding)],
                          @[@"KOI8-R", @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingKOI8_R))], @[@"DOS-866", @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSRussian))],
                          @[@"Latin-1", @(NSISOLatin1StringEncoding)], @[@"Shift-JIS", @(NSShiftJISStringEncoding)]];
        for (NSArray *e in list) {
            UIAction *a = [UIAction actionWithTitle:e[0] image:nil identifier:nil handler:^(UIAction *x) { [ws reloadWithEncoding:[e[1] unsignedIntegerValue]]; }];
            if (_enc == [e[1] unsignedIntegerValue]) a.state = UIMenuElementStateOn;
            [encs addObject:a];
        }
        [acts addObject:[UIMenu menuWithTitle:GXL(@"Кодировка") image:[UIImage systemImageNamed:@"character"] identifier:nil options:0 children:encs]];
        [acts addObject:[UIAction actionWithTitle:GXL(@"Открыть с помощью… (картинка, plist, hex…)") image:[UIImage systemImageNamed:@"square.grid.3x3"] identifier:nil handler:^(UIAction *a) {
            [GXOpener openWithMenu:self->_path from:ws sourceView:nil]; }]];
        [acts addObject:[UIAction actionWithTitle:GXL(@"Hex-вид") image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(UIAction *a) {
            GXHexVC *h = [[GXHexVC alloc] initWithPath:self->_path];
            h.readOnly = self.readOnly;
            [ws.navigationController pushViewController:h animated:YES];
        }]];
    }
    [acts addObject:[UIAction actionWithTitle:GXL(@"Статистика") image:[UIImage systemImageNamed:@"chart.bar"] identifier:nil handler:^(UIAction *a) { [ws stats]; }]];
    [acts addObject:[UIAction actionWithTitle:GXL(@"Скопировать всё") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = ws ? self->_tv.text : @""; GXToast(ws.view, GXL(@"Скопировано")); }]];
    [acts addObject:[UIAction actionWithTitle:GXL(@"Поделиться") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { [ws share]; }]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"" children:acts]];
    if (_readOnly) { self.navigationItem.rightBarButtonItems = @[more]; return; }
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Сохранить") style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    save.enabled = _dirty;
    self.navigationItem.rightBarButtonItems = @[save, more];
}

- (UIView *)accessoryBar {
    UIInputView *bar = [[UIInputView alloc] initWithFrame:CGRectMake(0, 0, 320, 44) inputViewStyle:UIInputViewStyleKeyboard];
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:bar.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.showsHorizontalScrollIndicator = NO;
    NSArray *keys = @[@"⇥", @"↶", @"↷", @"{", @"}", @"(", @")", @"[", @"]", @"<", @">", @"\"", @"'", @"=", @";", @":", @"/", @"\\", @"#", @"$", @"_", @"-", @"+", @"*", @"|", @"&", @"!", @"?", @"%", @"@", @"⌄"];
    CGFloat x = 6;
    for (NSString *k in keys) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:k forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightMedium];
        b.backgroundColor = UIColor.tertiarySystemBackgroundColor;
        b.layer.cornerRadius = 6;
        b.frame = CGRectMake(x, 5, 38, 34);
        [b addTarget:self action:@selector(key:) forControlEvents:UIControlEventTouchUpInside];
        [sv addSubview:b];
        x += 42;
    }
    sv.contentSize = CGSizeMake(x + 6, 44);
    [bar addSubview:sv];
    return bar;
}

- (void)key:(UIButton *)b {
    NSString *k = [b titleForState:UIControlStateNormal];
    if ([k isEqualToString:@"⇥"]) [_tv insertText:@"    "];
    else if ([k isEqualToString:@"↶"]) [_tv.undoManager undo];
    else if ([k isEqualToString:@"↷"]) [_tv.undoManager redo];
    else if ([k isEqualToString:@"⌄"]) [_tv resignFirstResponder];
    else [_tv insertText:k];
}

- (void)kb:(NSNotification *)n {
    CGRect r = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:r fromView:nil];
    _bottom.constant = -MAX(0, CGRectGetMaxY(self.view.bounds) - local.origin.y);
    [self.view layoutIfNeeded];
}

- (void)applyWrap {
    if (_wrap) {
        _tv.textContainer.widthTracksTextView = YES;
        _tv.textContainer.lineBreakMode = NSLineBreakByWordWrapping;
    } else {
        _tv.textContainer.widthTracksTextView = NO;
        _tv.textContainer.size = CGSizeMake(100000, CGFLOAT_MAX);
        _tv.textContainer.lineBreakMode = NSLineBreakByClipping;
    }
}

- (void)toggleWrap {
    _wrap = !_wrap;
    [GXDefaults() setBool:!_wrap forKey:@"gxNoWrap"];
    [self applyWrap];
    [_tv setNeedsLayout];
    [self buildItems];
}

- (void)font:(int)d {
    CGFloat fs = MAX(8, MIN(30, _tv.font.pointSize + d));
    [GXDefaults() setFloat:fs forKey:@"gxFontSize"];
    _tv.font = [UIFont monospacedSystemFontOfSize:fs weight:UIFontWeightRegular];
    [self highlight];
}

- (NSString *)decode:(NSData *)d encoding:(NSStringEncoding)forced {
    const uint8_t *b = d.bytes;
    _bom = NO;
    if (forced) {
        _enc = forced;
        return [[NSString alloc] initWithData:d encoding:forced] ?: @"";
    }
    if (d.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
        _enc = NSUTF8StringEncoding; _bom = YES;
        return [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(3, d.length - 3)] encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (d.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
        _enc = NSUTF16StringEncoding; _bom = YES;
        return [[NSString alloc] initWithData:d encoding:NSUTF16StringEncoding] ?: @"";
    }
    // двоичный файл (есть нулевые байты, нет UTF-16 BOM): Latin-1 — каждый байт = один символ, сохранение без потерь
    BOOL hasNul = memchr(b, 0, MIN(d.length, (NSUInteger)65536)) != NULL;
    if (hasNul && d.length >= 4 && d.length % 2 == 0) {
        NSUInteger n = MIN(d.length, (NSUInteger)4096), zo = 0, ze = 0;
        for (NSUInteger i = 0; i + 1 < n; i += 2) { if (!b[i + 1]) zo++; if (!b[i]) ze++; }
        NSUInteger half = n / 2;
        if (zo * 10 >= half * 9 || ze * 10 >= half * 9) {
            NSStringEncoding e16 = zo >= ze ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding;
            NSString *t = [[NSString alloc] initWithData:d encoding:e16];
            if (t) { _enc = e16; return t; }
        }
    }
    if (hasNul || (d.length >= 4 && (!memcmp(b, "\x89PNG", 4) || (b[0] == 0xFF && b[1] == 0xD8)))) {
        NSString *u = hasNul ? nil : [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (u) { _enc = NSUTF8StringEncoding; return u; }
        _enc = NSISOLatin1StringEncoding;
        _binaryMode = YES;
        return [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) { _enc = NSUTF8StringEncoding; return s; }
    // UTF-16 без BOM (часто у .strings)
    if (d.length >= 4 && d.length % 2 == 0 && (b[1] == 0 || b[0] == 0)) {
        s = [[NSString alloc] initWithData:d encoding:b[1] == 0 ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding];
        if (s) { _enc = b[1] == 0 ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding; return s; }
    }
    s = [[NSString alloc] initWithData:d encoding:NSWindowsCP1251StringEncoding];
    if (s) { _enc = NSWindowsCP1251StringEncoding; return s; }
    _enc = NSISOLatin1StringEncoding;
    return [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding] ?: @"";
}

- (void)load { [self reloadWithEncoding:0]; }

- (void)reloadWithEncoding:(NSStringEncoding)enc {
    if (_initialText) { _tv.text = _initialText; [self highlightNow]; return; }
    NSError *err;
    NSData *d = [NSData dataWithContentsOfFile:_path options:NSDataReadingMappedIfSafe error:&err];
    if (!d) { _tv.text = [NSString stringWithFormat:GXL(@"Не удалось открыть:\n%@"), err.localizedDescription]; _tv.editable = NO; return; }
    _binaryMode = NO;
    _tv.text = [self decode:d encoding:enc];
    if (_binaryMode) {
        self.title = [NSString stringWithFormat:GXL(@"%@ (двоичный)"), _path.lastPathComponent];
        dispatch_async(dispatch_get_main_queue(), ^{ GXToast(self.view, GXL(@"Двоичный файл открыт как текст (Latin-1, байт = символ). Меняйте строки той же длины, иначе файл может сломаться.")); });
    }
    _dirty = NO;
    [self buildItems];
    [self highlightNow];
}

- (void)highlightNow {
    NSString *ext = _highlightExt ?: (_path ?: self.title).pathExtension;
    _rules = GXHighlightRules(ext);
    [self highlight];
    NSString *pf = _initialFind ?: [GXDefaults() stringForKey:@"gxPendingFind"];
    [GXDefaults() removeObjectForKey:@"gxPendingFind"];
    _initialFind = nil;
    if (pf.length) {
        NSRange r = [_tv.text rangeOfString:pf options:_initialFindCase ? 0 : NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_tv.selectedRange = r;
                [self->_tv scrollRangeToVisible:r];
                [self->_tv becomeFirstResponder];
            });
        }
    }
}

- (void)highlight {
    NSTextStorage *ts = _tv.textStorage;
    NSRange all = NSMakeRange(0, ts.length);
    UIFont *font = _tv.font;
    if (!_rules || ts.length > 400000) {
        [ts beginEditing];
        [ts setAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor} range:all];
        [ts endEditing];
        return;
    }
    NSString *s = ts.string;
    NSRange sel = _tv.selectedRange;
    [ts beginEditing];
    [ts setAttributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor} range:all];
    for (NSArray *rule in _rules) {
        NSRegularExpression *re = rule[0];
        UIColor *c = rule[1];
        [re enumerateMatchesInString:s options:0 range:all usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
            [ts addAttribute:NSForegroundColorAttributeName value:c range:m.range];
        }];
    }
    [ts endEditing];
    _tv.selectedRange = sel;
}

- (void)textViewDidChange:(UITextView *)textView {
    if (!_dirty) { _dirty = YES; [self buildItems]; }
    self.modalInPresentation = YES;
    [_hlTimer invalidate];
    if (_rules) _hlTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(highlight) userInfo:nil repeats:NO];
}

- (BOOL)textView:(UITextView *)tv shouldChangeTextInRange:(NSRange)r replacementText:(NSString *)text {
    // автоотступ при переносе строки
    if ([text isEqualToString:@"\n"]) {
        NSString *s = tv.text;
        NSRange line = [s lineRangeForRange:NSMakeRange(r.location, 0)];
        NSString *cur = [s substringWithRange:NSMakeRange(line.location, r.location - line.location)];
        NSMutableString *indent = [NSMutableString string];
        for (NSUInteger i = 0; i < cur.length; i++) {
            unichar c = [cur characterAtIndex:i];
            if (c == ' ' || c == '\t') [indent appendFormat:@"%C", c]; else break;
        }
        NSString *trim = [cur stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([trim hasSuffix:@"{"] || [trim hasSuffix:@"["] || [trim hasSuffix:@"("] || [trim hasSuffix:@":"]) [indent appendString:@"    "];
        if (indent.length) {
            [tv insertText:[@"\n" stringByAppendingString:indent]];
            return NO;
        }
    }
    return YES;
}

- (void)find {
    if (@available(iOS 16.0, *)) {
        [_tv.findInteraction presentFindNavigatorShowingReplace:!_readOnly];
        return;
    }
    GXPrompt(self, GXL(@"Найти"), nil, nil, GXL(@"Текст"), GXL(@"Далее"), ^(NSString *q) {
        if (!q.length) return;
        NSString *s = self->_tv.text;
        NSUInteger from = NSMaxRange(self->_tv.selectedRange);
        NSRange r = [s rangeOfString:q options:NSCaseInsensitiveSearch range:NSMakeRange(from, s.length - from)];
        if (r.location == NSNotFound) r = [s rangeOfString:q options:NSCaseInsensitiveSearch];
        if (r.location == NSNotFound) { GXToast(self.view, GXL(@"Не найдено")); return; }
        self->_tv.selectedRange = r;
        [self->_tv scrollRangeToVisible:r];
        [self->_tv becomeFirstResponder];
    });
}

- (void)gotoLine {
    GXPrompt(self, GXL(@"Перейти к строке"), nil, nil, GXL(@"Номер строки"), GXL(@"Перейти"), ^(NSString *v) {
        NSInteger line = v.integerValue;
        if (line < 1) return;
        NSString *s = self->_tv.text;
        __block NSInteger n = 1;
        __block NSUInteger loc = 0;
        if (line > 1) [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired
                                         usingBlock:^(NSString *x, NSRange r, NSRange er, BOOL *stop) {
            if (n == line) { loc = r.location; *stop = YES; return; }
            n++;
            loc = NSMaxRange(er);
        }];
        NSRange r = NSMakeRange(MIN(loc, s.length), 0);
        self->_tv.selectedRange = r;
        [self->_tv scrollRangeToVisible:r];
    });
}

- (void)formatJSON:(BOOL)pretty {
    NSError *err;
    id obj = [NSJSONSerialization JSONObjectWithData:[_tv.text dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:&err];
    if (!obj) { GXAlert(self, GXL(@"Некорректный JSON"), err.localizedDescription); return; }
    NSJSONWritingOptions o = NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes;
    if (pretty) o |= NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:o error:&err];
    if (!d) return;
    _tv.text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    [self textViewDidChange:_tv];
    [self highlight];
}

- (void)stats {
    NSString *s = _tv.text;
    __block NSUInteger lines = 0, words = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByLines | NSStringEnumerationSubstringNotRequired usingBlock:^(NSString *x, NSRange r, NSRange e, BOOL *st) { lines++; }];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired usingBlock:^(NSString *x, NSRange r, NSRange e, BOOL *st) { words++; }];
    NSString *enc = [NSString localizedNameOfStringEncoding:_enc];
    GXAlert(self, GXL(@"Статистика"), [NSString stringWithFormat:GXL(@"Строк: %lu\nСлов: %lu\nСимволов: %lu\nКодировка: %@%@"), (unsigned long)lines, (unsigned long)words, (unsigned long)s.length, enc, _bom ? @" + BOM" : @""]);
}

- (void)share {
    NSArray *items = _path ? @[[NSURL fileURLWithPath:_path]] : @[_tv.text ?: @""];
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)save {
    if (_saveHandler) {
        NSString *err = _saveHandler(_tv.text);
        if (err) { GXAlert(self, GXL(@"Не удалось сохранить"), err); return; }
        _dirty = NO;
        self.modalInPresentation = NO;
        [self buildItems];
        GXToast(self.view, GXL(@"Сохранено"));
        return;
    }
    if (_readOnly || !_path) return;
    NSMutableData *out = [NSMutableData data];
    NSStringEncoding enc = _enc;
    if (_bom && enc == NSUTF8StringEncoding) [out appendBytes:"\xEF\xBB\xBF" length:3];
    NSData *body = [_tv.text dataUsingEncoding:enc allowLossyConversion:YES];
    if (!body) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Текст нельзя записать в выбранной кодировке")); return; }
    [out appendData:body];
    NSError *err;
    if (![out writeToFile:_path options:NSDataWritingAtomic error:&err]) { GXAlert(self, GXL(@"Не удалось сохранить"), err.localizedDescription); return; }
    _dirty = NO;
    self.modalInPresentation = NO;
    [self buildItems];
    GXToast(self.view, GXL(@"Сохранено"));
}

- (void)close {
    if (!_dirty) { [self dismissViewControllerAnimated:YES completion:nil]; return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Есть несохранённые изменения") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Сохранить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self save]; if (!self->_dirty) [self dismissViewControllerAnimated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Не сохранять") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self dismissViewControllerAnimated:YES completion:nil]; }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Большой текст (постранично)

@implementation GXBigTextVC {
    NSString *_path;
    unsigned long long _size;
    unsigned long long _page;
    UITextView *_tv;
    UILabel *_info;
    NSString *_lastQuery;
}
static const unsigned long long kPage = 256 * 1024;

- (instancetype)initWithPath:(NSString *)path { if ((self = [super init])) _path = path; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _size = [[FM() attributesOfItemAtPath:_path error:nil] fileSize];
    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.editable = NO;
    _tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self.view addSubview:_tv];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"] style:UIBarButtonItemStylePlain target:self action:@selector(search)];
    _info = [UILabel new];
    _info.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _info.textColor = UIColor.secondaryLabelColor;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"backward.end"] style:UIBarButtonItemStylePlain target:self action:@selector(first)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain target:self action:@selector(prev)],
        flex, [[UIBarButtonItem alloc] initWithCustomView:_info], flex,
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"percent"] style:UIBarButtonItemStylePlain target:self action:@selector(jump)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"] style:UIBarButtonItemStylePlain target:self action:@selector(next)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"forward.end"] style:UIBarButtonItemStylePlain target:self action:@selector(last)]];
    [self.navigationController setToolbarHidden:NO];
    [self show:0 highlight:nil];
}

- (unsigned long long)pages { return MAX(1, (_size + kPage - 1) / kPage); }

- (void)show:(unsigned long long)page highlight:(NSString *)q {
    _page = MIN(page, [self pages] - 1);
    int fd = open(_path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) { _tv.text = GXL(@"Не удалось открыть файл"); return; }
    unsigned long long off = _page * kPage;
    NSMutableData *d = [NSMutableData dataWithLength:kPage + 8];
    ssize_t n = pread(fd, d.mutableBytes, kPage + 8, (off_t)off);
    close(fd);
    if (n < 0) n = 0;
    uint8_t *b = d.mutableBytes;
    // выравнивание по UTF-8
    size_t start = 0;
    while (start < 4 && start < (size_t)n && (b[start] & 0xC0) == 0x80 && off > 0) start++;
    size_t end = MIN((size_t)n, (size_t)kPage);
    while (end < (size_t)n && (b[end] & 0xC0) == 0x80) end++;
    NSData *chunk = [d subdataWithRange:NSMakeRange(start, end > start ? end - start : 0)];
    NSString *s = [[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding]
               ?: [[NSString alloc] initWithData:chunk encoding:NSWindowsCP1251StringEncoding]
               ?: [[NSString alloc] initWithData:chunk encoding:NSISOLatin1StringEncoding];
    _tv.text = s ?: @"";
    _info.text = [NSString stringWithFormat:@"%llu / %llu · %@", _page + 1, [self pages], GXHuman(_size)];
    [_info sizeToFit];
    if (q.length) {
        NSRange r = [_tv.text rangeOfString:q options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) {
            _tv.selectedRange = r;
            dispatch_async(dispatch_get_main_queue(), ^{ [self->_tv scrollRangeToVisible:r]; [self->_tv becomeFirstResponder]; });
        }
    } else [_tv setContentOffset:CGPointZero animated:NO];
}

- (void)first { [self show:0 highlight:nil]; }
- (void)last { [self show:[self pages] - 1 highlight:nil]; }
- (void)prev { if (_page > 0) [self show:_page - 1 highlight:nil]; }
- (void)next { if (_page + 1 < [self pages]) [self show:_page + 1 highlight:nil]; }
- (void)jump {
    GXPrompt(self, GXL(@"Перейти"), GXL(@"Процент от начала файла (0–100)"), nil, @"50", GXL(@"Перейти"), ^(NSString *v) {
        double p = MAX(0, MIN(100, v.doubleValue));
        [self show:(unsigned long long)(p / 100.0 * ([self pages] - 1) + 0.5) highlight:nil];
    });
}
- (void)search {
    GXPrompt(self, GXL(@"Найти дальше"), GXL(@"Поиск по всему файлу (UTF-8), начиная со следующей страницы"), _lastQuery, GXL(@"Текст"), GXL(@"Найти"), ^(NSString *q) {
        if (!q.length) return;
        self->_lastQuery = q;
        NSData *needle = [q dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = self->_path;
        unsigned long long startPage = self->_page + 1;
        [GXHUD showCancellableIn:self.view text:GXL(@"Ищу…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            long long foundPage = -1;
            int fd = open(path.fileSystemRepresentation, O_RDONLY);
            if (fd >= 0) {
                size_t L = 4 << 20;
                uint8_t *buf = malloc(L + needle.length);
                unsigned long long off = startPage * kPage;
                while (![GXHUD cancelled]) {
                    ssize_t n = pread(fd, buf, L + needle.length, (off_t)off);
                    if (n <= 0) break;
                    void *hit = memmem(buf, (size_t)n, needle.bytes, needle.length);
                    if (hit) { foundPage = (long long)((off + ((uint8_t *)hit - buf)) / kPage); break; }
                    off += L;
                    [GXHUD setProgress:(double)off / MAX(1.0, (double)self->_size)];
                }
                free(buf);
                close(fd);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [GXHUD hide];
                if (foundPage < 0) GXToast(self.view, GXL(@"Дальше не найдено"));
                else [self show:(unsigned long long)foundPage highlight:q];
            });
        });
    });
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - Hex-редактор

@implementation GXHexVC {
    NSString *_path;
    unsigned long long _size;
    NSUInteger _perRow;
    NSMutableDictionary<NSNumber *, NSData *> *_pages;
    int _fd;
}
static const NSUInteger kHexPage = 64 * 1024;

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStylePlain])) { _path = path; _pages = [NSMutableDictionary dictionary]; _fd = -1; }
    return self;
}
- (void)dealloc { if (_fd >= 0) close(_fd); }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _path.lastPathComponent;
    _size = [[FM() attributesOfItemAtPath:_path error:nil] fileSize];
    _fd = open(_path.fileSystemRepresentation, O_RDONLY);
    self.tableView.rowHeight = 20;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.right.to.line"] style:UIBarButtonItemStylePlain target:self action:@selector(gotoOffset)];
    [self computePerRow];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)c {
    [super viewWillTransitionToSize:size withTransitionCoordinator:c];
    [c animateAlongsideTransition:nil completion:^(id x) { [self computePerRow]; }];
}

- (void)computePerRow {
    CGFloat w = self.view.bounds.size.width - 24;
    CGFloat cw = [@"0" sizeWithAttributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]}].width;
    // смещение 9 + на байт 3 + 1 (ascii)
    NSInteger n = (NSInteger)((w / cw - 10) / 4);
    _perRow = n >= 16 ? 16 : n >= 8 ? 8 : 4;
    [self.tableView reloadData];
}

- (NSData *)pageAt:(NSUInteger)p {
    NSData *d = _pages[@(p)];
    if (d) return d;
    if (_pages.count > 64) [_pages removeAllObjects];
    NSMutableData *m = [NSMutableData dataWithLength:kHexPage];
    ssize_t n = _fd >= 0 ? pread(_fd, m.mutableBytes, kHexPage, (off_t)p * kHexPage) : 0;
    m.length = n > 0 ? (NSUInteger)n : 0;
    _pages[@(p)] = m;
    return m;
}

- (int)byteAt:(unsigned long long)off {
    if (off >= _size) return -1;
    NSData *d = [self pageAt:(NSUInteger)(off / kHexPage)];
    NSUInteger i = (NSUInteger)(off % kHexPage);
    return i < d.length ? ((const uint8_t *)d.bytes)[i] : -1;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)((_size + _perRow - 1) / _perRow); }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"h"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"h"];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    }
    unsigned long long off = (unsigned long long)ip.row * _perRow;
    NSMutableString *s = [NSMutableString stringWithFormat:@"%08llx ", off];
    char ascii[17] = {0};
    for (NSUInteger i = 0; i < _perRow; i++) {
        int b = [self byteAt:off + i];
        if (b < 0) { [s appendString:@"   "]; ascii[i] = ' '; continue; }
        [s appendFormat:@"%02x ", b];
        ascii[i] = (b >= 32 && b < 127) ? (char)b : '.';
    }
    [s appendFormat:@" %s", ascii];
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:s];
    [a addAttribute:NSForegroundColorAttributeName value:UIColor.secondaryLabelColor range:NSMakeRange(0, 8)];
    [a addAttribute:NSForegroundColorAttributeName value:UIColor.systemTealColor range:NSMakeRange(s.length - _perRow, _perRow)];
    c.textLabel.attributedText = a;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_readOnly) return;
    unsigned long long off = (unsigned long long)ip.row * _perRow;
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < _perRow; i++) { int b = [self byteAt:off + i]; if (b >= 0) [cur appendFormat:@"%02x ", b]; }
    GXPrompt(self, [NSString stringWithFormat:GXL(@"Изменить байты 0x%llx"), off], GXL(@"Введите hex-байты (пробелы игнорируются). Длина файла не меняется."),
             [cur stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], nil, GXL(@"Записать"), ^(NSString *v) {
        NSString *hex = [[v componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsJoinedByString:@""];
        if (hex.length % 2) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Нечётное количество hex-цифр")); return; }
        NSMutableData *d = [NSMutableData data];
        for (NSUInteger i = 0; i < hex.length; i += 2) {
            unsigned x;
            NSScanner *sc = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
            if (![sc scanHexInt:&x]) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Неверные hex-цифры")); return; }
            uint8_t b = (uint8_t)x;
            [d appendBytes:&b length:1];
        }
        if (off + d.length > self->_size) d.length = (NSUInteger)(self->_size - off);
        int wfd = open(self->_path.fileSystemRepresentation, O_WRONLY);
        if (wfd < 0 || pwrite(wfd, d.bytes, d.length, (off_t)off) != (ssize_t)d.length) GXAlert(self, GXL(@"Не удалось записать"), GXL(@"Нет доступа на запись"));
        if (wfd >= 0) close(wfd);
        [self->_pages removeAllObjects];
        [self.tableView reloadData];
    });
}

- (void)gotoOffset {
    GXPrompt(self, GXL(@"Перейти к смещению"), GXL(@"Hex (0x1A2B) или десятичное"), nil, @"0x0", GXL(@"Перейти"), ^(NSString *v) {
        unsigned long long off = 0;
        NSScanner *sc = [NSScanner scannerWithString:v];
        if ([v hasPrefix:@"0x"] || [v hasPrefix:@"0X"]) [sc scanHexLongLong:&off]; else [sc scanUnsignedLongLong:&off];
        NSInteger row = (NSInteger)(MIN(off, self->_size ? self->_size - 1 : 0) / self->_perRow);
        if ([self.tableView numberOfRowsInSection:0] > row)
            [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    });
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - Отчёт

@implementation GXReportVC { NSString *_text; }
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text { if ((self = [super init])) { self.title = title; _text = text; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    tv.text = _text;
    tv.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    [self.view addSubview:tv];
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)];
}
- (void)share:(UIBarButtonItem *)b {
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[_text] applicationActivities:nil];
    a.popoverPresentationController.barButtonItem = b;
    [self presentViewController:a animated:YES completion:nil];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

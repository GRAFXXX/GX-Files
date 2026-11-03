// Поиск и замена текста по всей папке или внутри архива (apk/ipa/zip) — без открытия файлов
#import "GXCore.h"
#include <sys/stat.h>
#include <fnmatch.h>
#include "core/gx_zip.h"

#pragma mark - Движок

typedef NS_ENUM(NSInteger, GXFindMode) { GXFindText, GXFindRegex, GXFindHex };

@interface GXFindSpec : NSObject
@property (nonatomic, copy) NSString *query, *replacement, *masks;
@property (nonatomic) GXFindMode mode;
@property (nonatomic) BOOL caseSensitive, wholeWord, intoArchives, binary;
@property (nonatomic) unsigned long long maxSize;
@property (nonatomic, strong) NSRegularExpression *re;
@property (nonatomic, strong) NSData *needle, *hexRepl;
@property (nonatomic, strong) NSArray<NSString *> *globs;
- (NSString *)prepare;
@end

@interface GXFindHit : NSObject
@property (nonatomic) NSUInteger line, offset;
@property (nonatomic, copy) NSString *snippet;
@end
@implementation GXFindHit
@end

@interface GXFindFile : NSObject
@property (nonatomic, copy) NSString *display, *path;       // path — файл на диске либо архив
@property (nonatomic, copy, nullable) NSString *entry;      // запись внутри архива
@property (nonatomic, strong) NSArray<GXFindHit *> *hits;
@property (nonatomic) NSUInteger total;
@property (nonatomic) BOOL selected, done;
@end
@implementation GXFindFile
@end

static NSData *GXHexData(NSString *s) {
    NSString *h = [[s componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \n\t,:-"]] componentsJoinedByString:@""];
    if ([h hasPrefix:@"0x"]) h = [h substringFromIndex:2];
    if (h.length % 2) return nil;
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i < h.length; i += 2) {
        unsigned v;
        if (![[NSScanner scannerWithString:[h substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v]) return nil;
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
    }
    return d;
}

@implementation GXFindSpec
- (NSString *)prepare {
    if (!_query.length) return GXL(@"Введите, что искать");
    _maxSize = 64ull << 20;
    if (_mode == GXFindHex) {
        _needle = GXHexData(_query);
        if (!_needle.length) return GXL(@"Неверная hex-строка (пример: 7f 45 4c 46)");
        if (_replacement.length) { _hexRepl = GXHexData(_replacement); if (!_hexRepl) return GXL(@"Неверная hex-строка замены"); }
        else _hexRepl = [NSData data];
    } else {
        NSString *pat = _mode == GXFindRegex ? _query : [NSRegularExpression escapedPatternForString:_query];
        if (_wholeWord) pat = [NSString stringWithFormat:@"\\b%@\\b", pat];
        NSError *e;
        _re = [NSRegularExpression regularExpressionWithPattern:pat options:(_caseSensitive ? 0 : NSRegularExpressionCaseInsensitive) | NSRegularExpressionAnchorsMatchLines error:&e];
        if (!_re) return [NSString stringWithFormat:GXL(@"Ошибка в регулярном выражении: %@"), e.localizedDescription];
        _needle = [_query dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSMutableArray *g = [NSMutableArray array];
    for (NSString *m in [_masks componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";, "]])
        if (m.length) [g addObject:m.lowercaseString];
    _globs = g;
    return nil;
}

- (NSString *)renamed:(NSString *)name {
    if (!name.length || !_re) return nil;
    if (![_re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)]) return nil;
    NSString *tmpl = _mode == GXFindRegex ? (_replacement ?: @"") : [NSRegularExpression escapedTemplateForString:_replacement ?: @""];
    NSString *r = [_re stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:tmpl];
    return [r isEqualToString:name] ? nil : r;
}

- (BOOL)nameMatches:(NSString *)name {
    if (!_globs.count) return YES;
    NSString *n = name.lastPathComponent.lowercaseString;
    for (NSString *g in _globs) if (fnmatch(g.UTF8String, n.UTF8String, 0) == 0) return YES;
    return NO;
}

static BOOL GXLooksBinary(NSData *d) {
    const uint8_t *b = d.bytes;
    NSUInteger n = MIN(d.length, 8192u);
    if (n >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) return NO;
    for (NSUInteger i = 0; i < n; i++) if (b[i] == 0) return YES;
    return NO;
}

static NSString *GXDecode(NSData *d, NSStringEncoding *enc) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) { *enc = NSUTF8StringEncoding; return s; }
    const uint8_t *b = d.bytes;
    if (d.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
        s = [[NSString alloc] initWithData:d encoding:NSUTF16StringEncoding];
        if (s) { *enc = NSUTF16StringEncoding; return s; }
    }
    return nil;
}

// Найти совпадения. hits ограничены maxHits, total — сколько всего.
- (NSArray<GXFindHit *> *)find:(NSData *)d total:(NSUInteger *)total maxHits:(NSUInteger)maxHits {
    NSMutableArray *hits = [NSMutableArray array];
    *total = 0;
    if (!d.length) return hits;
    BOOL bin = GXLooksBinary(d);
    if (_mode == GXFindHex || (bin && _binary && _mode == GXFindText && _caseSensitive)) {
        if (bin && !_binary && _mode != GXFindHex) return hits;
        const uint8_t *b = d.bytes, *p = b, *end = b + d.length;
        while (p < end) {
            const uint8_t *h = memmem(p, (size_t)(end - p), _needle.bytes, _needle.length);
            if (!h) break;
            (*total)++;
            if (hits.count < maxHits) {
                GXFindHit *x = [GXFindHit new];
                x.offset = (NSUInteger)(h - b);
                NSUInteger s = x.offset > 8 ? x.offset - 8 : 0, e = MIN(d.length, x.offset + _needle.length + 8);
                x.snippet = [NSString stringWithFormat:@"0x%lx: %@", (unsigned long)x.offset, GXHexString([d subdataWithRange:NSMakeRange(s, e - s)], 64)];
                [hits addObject:x];
            }
            p = h + MAX(_needle.length, 1u);
        }
        return hits;
    }
    if (bin && !_binary) return hits;
    NSStringEncoding enc;
    NSString *s = GXDecode(d, &enc);
    if (!s) return hits;
    __block NSUInteger line = 1, scanned = 0;
    [_re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        (*total)++;
        if (hits.count >= maxHits) return;
        // номер строки — считаем переводы строк от последней позиции
        for (NSUInteger i = scanned; i < m.range.location; i++) if ([s characterAtIndex:i] == '\n') line++;
        scanned = m.range.location;
        NSRange lr = [s lineRangeForRange:NSMakeRange(m.range.location, 0)];
        NSString *ln = [[s substringWithRange:lr] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ln.length > 160) {
            NSUInteger rel = m.range.location - lr.location;
            NSUInteger st = rel > 60 ? rel - 60 : 0;
            ln = [[s substringWithRange:NSMakeRange(lr.location + st, MIN(160u, lr.length - st))] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        GXFindHit *x = [GXFindHit new];
        x.line = line;
        x.offset = m.range.location;
        x.snippet = ln;
        [hits addObject:x];
    }];
    return hits;
}

// Заменить; nil — нечего менять
- (NSData *)replace:(NSData *)d count:(NSUInteger *)count {
    *count = 0;
    if (!d.length) return nil;
    BOOL bin = GXLooksBinary(d);
    if (_mode == GXFindHex || (bin && _binary && _mode == GXFindText && _caseSensitive)) {
        if (bin && !_binary && _mode != GXFindHex) return nil;
        NSData *rep = _mode == GXFindHex ? _hexRepl : [_replacement ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableData *out = [NSMutableData dataWithCapacity:d.length];
        const uint8_t *b = d.bytes, *p = b, *end = b + d.length;
        while (p < end) {
            const uint8_t *h = memmem(p, (size_t)(end - p), _needle.bytes, _needle.length);
            if (!h) break;
            [out appendBytes:p length:(NSUInteger)(h - p)];
            [out appendData:rep];
            (*count)++;
            p = h + _needle.length;
        }
        if (!*count) return nil;
        [out appendBytes:p length:(NSUInteger)(end - p)];
        return out;
    }
    if (bin && !_binary) return nil;
    NSStringEncoding enc;
    NSString *s = GXDecode(d, &enc);
    if (!s) return nil;
    NSString *tmpl = _mode == GXFindRegex ? (_replacement ?: @"") : [NSRegularExpression escapedTemplateForString:_replacement ?: @""];
    NSMutableString *m = s.mutableCopy;
    *count = [_re replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:tmpl];
    if (!*count) return nil;
    NSData *out = [m dataUsingEncoding:enc];
    if (enc == NSUTF16StringEncoding) {
        // сохранить порядок байт исходника
        const uint8_t *b = d.bytes;
        BOOL be = b[0] == 0xFE;
        NSMutableData *o = [NSMutableData dataWithBytes:be ? "\xFE\xFF" : "\xFF\xFE" length:2];
        [o appendData:[m dataUsingEncoding:be ? NSUTF16BigEndianStringEncoding : NSUTF16LittleEndianStringEncoding]];
        if ([m hasPrefix:@"﻿"]) [o replaceBytesInRange:NSMakeRange(2, 2) withBytes:NULL length:0];
        out = o;
    }
    return out;
}
@end

#pragma mark - Экран

@interface GXFindVC () <UITextFieldDelegate>
@end

@implementation GXFindVC {
    NSString *_root;
    BOOL _rootIsArchive;
    UITextField *_q, *_r, *_mask;
    UISegmentedControl *_mode, *_target;
    UISwitch *_case, *_word, *_arch, *_bin;
    NSMutableArray<GXFindFile *> *_files;
    NSInteger _gen;
    BOOL _running;
    unsigned long long _scanned, _totalHits;
    UIProgressView *_bar;
    UILabel *_status;
}

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _root = root;
        BOOL d = GXIsDir(root);
        _rootIsArchive = !d && GXIsZipFamily(root);
        _files = [NSMutableArray array];
    }
    return self;
}

static UISwitch *GXSw(BOOL on) { UISwitch *s = [UISwitch new]; s.on = on; return s; }

- (UIView *)row:(NSString *)title control:(UIView *)ctl {
    UIStackView *h = [[UIStackView alloc] init];
    h.axis = UILayoutConstraintAxisHorizontal;
    h.alignment = UIStackViewAlignmentCenter;
    UILabel *l = [UILabel new];
    l.text = title;
    l.font = [UIFont systemFontOfSize:15];
    [h addArrangedSubview:l];
    [h addArrangedSubview:ctl];
    return h;
}

- (UITextField *)field:(NSString *)ph {
    UITextField *t = [UITextField new];
    t.placeholder = ph;
    t.borderStyle = UITextBorderStyleRoundedRect;
    t.autocorrectionType = UITextAutocorrectionTypeNo;
    t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    t.spellCheckingType = UITextSpellCheckingTypeNo;
    t.smartQuotesType = UITextSmartQuotesTypeNo;
    t.clearButtonMode = UITextFieldViewModeWhileEditing;
    t.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    t.delegate = self;
    t.returnKeyType = UIReturnKeySearch;
    return t;
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; [self search]; return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Найти и заменить");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    NSUserDefaults *d = GXDefaults();
    _q = [self field:GXL(@"Что искать")];
    _q.text = [d stringForKey:@"gxFindQ"];
    _r = [self field:GXL(@"Заменить на (пусто — удалить)")];
    _r.text = [d stringForKey:@"gxFindR"];
    _mask = [self field:GXL(@"Маска файлов: *.xml; *.smali (пусто — все)")];
    _mask.text = [d stringForKey:@"gxFindMask"];
    _target = [[UISegmentedControl alloc] initWithItems:@[GXL(@"В содержимом"), GXL(@"В именах файлов и папок")]];
    _target.selectedSegmentIndex = [d integerForKey:@"gxFindTarget"];
    _mode = [[UISegmentedControl alloc] initWithItems:@[GXL(@"Текст"), @"Regex", @"Hex"]];
    _mode.selectedSegmentIndex = [d integerForKey:@"gxFindMode"];
    _case = GXSw([d boolForKey:@"gxFindCase"]);
    _word = GXSw([d boolForKey:@"gxFindWord"]);
    _arch = GXSw(![d objectForKey:@"gxFindArch"] || [d boolForKey:@"gxFindArch"]);
    _bin = GXSw([d boolForKey:@"gxFindBin"]);
    UIStackView *v = [[UIStackView alloc] init];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 8;
    v.layoutMargins = UIEdgeInsetsMake(12, 16, 8, 16);
    v.layoutMarginsRelativeArrangement = YES;
    UILabel *where = [UILabel new];
    where.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    where.textColor = UIColor.secondaryLabelColor;
    where.lineBreakMode = NSLineBreakByTruncatingHead;
    where.text = [NSString stringWithFormat:@"%@ %@", _rootIsArchive ? GXL(@"В архиве:") : GXL(@"В папке:"), _root];
    for (UIView *x in @[where, _target, _q, _r, _mode, _mask]) [v addArrangedSubview:x];
    [v addArrangedSubview:[self row:GXL(@"Учитывать регистр") control:_case]];
    [v addArrangedSubview:[self row:GXL(@"Слово целиком") control:_word]];
    if (!_rootIsArchive) [v addArrangedSubview:[self row:GXL(@"Заходить в архивы (apk, ipa, zip)") control:_arch]];
    [v addArrangedSubview:[self row:GXL(@"Двоичные файлы (точное совпадение)") control:_bin]];
    UIStackView *btns = [[UIStackView alloc] init];
    btns.axis = UILayoutConstraintAxisHorizontal;
    btns.spacing = 10;
    btns.distribution = UIStackViewDistributionFillEqually;
    UIButton *find = [UIButton buttonWithType:UIButtonTypeSystem];
    [find setTitle:GXL(@"Найти") forState:UIControlStateNormal];
    UIButton *rep = [UIButton buttonWithType:UIButtonTypeSystem];
    [rep setTitle:GXL(@"Заменить в отмеченных") forState:UIControlStateNormal];
    for (UIButton *b in @[find, rep]) {
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        b.backgroundColor = b == find ? self.view.tintColor : UIColor.systemOrangeColor;
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.layer.cornerRadius = 10;
        [b.heightAnchor constraintEqualToConstant:42].active = YES;
        [btns addArrangedSubview:b];
    }
    [find addTarget:self action:@selector(search) forControlEvents:UIControlEventTouchUpInside];
    [rep addTarget:self action:@selector(replaceSelected) forControlEvents:UIControlEventTouchUpInside];
    [v addArrangedSubview:btns];
    _bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    _bar.hidden = YES;
    _status = [UILabel new];
    _status.font = [UIFont systemFontOfSize:13];
    _status.textColor = UIColor.secondaryLabelColor;
    _status.numberOfLines = 0;
    [v addArrangedSubview:_bar];
    [v addArrangedSubview:_status];
    CGFloat w = self.view.bounds.size.width;
    CGSize sz = [v systemLayoutSizeFittingSize:CGSizeMake(w, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    v.frame = CGRectMake(0, 0, w, sz.height);
    self.tableView.tableHeaderView = v;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Все") style:UIBarButtonItemStylePlain target:self action:@selector(toggleAll)];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *h = self.tableView.tableHeaderView;
    CGFloat w = self.tableView.bounds.size.width;
    CGSize sz = [h systemLayoutSizeFittingSize:CGSizeMake(w, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(h.frame.size.height - sz.height) > 1 || fabs(h.frame.size.width - w) > 1) {
        h.frame = CGRectMake(0, 0, w, sz.height);
        self.tableView.tableHeaderView = h;
    }
}

- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.navigationController setToolbarHidden:YES animated:a]; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [GXDefaults() removeObjectForKey:@"gxPendingFind"]; [GXArcModel commitAllFrom:self]; }
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; if (self.isMovingFromParentViewController) _gen++; }
- (void)close { _gen++; [self dismissViewControllerAnimated:YES completion:nil]; }

- (GXFindSpec *)spec:(NSString **)err {
    GXFindSpec *s = [GXFindSpec new];
    s.query = _q.text;
    s.replacement = _r.text;
    s.masks = _mask.text;
    s.mode = _mode.selectedSegmentIndex;
    s.caseSensitive = _case.on;
    s.wholeWord = _word.on;
    s.intoArchives = _arch.on;
    s.binary = _bin.on;
    NSUserDefaults *d = GXDefaults();
    [d setObject:_q.text forKey:@"gxFindQ"];
    [d setObject:_r.text forKey:@"gxFindR"];
    [d setObject:_mask.text forKey:@"gxFindMask"];
    [d setInteger:_mode.selectedSegmentIndex forKey:@"gxFindMode"];
    [d setInteger:_target.selectedSegmentIndex forKey:@"gxFindTarget"];
    [d setBool:_case.on forKey:@"gxFindCase"];
    [d setBool:_word.on forKey:@"gxFindWord"];
    [d setBool:_arch.on forKey:@"gxFindArch"];
    [d setBool:_bin.on forKey:@"gxFindBin"];
    *err = [s prepare];
    if (!*err && _target.selectedSegmentIndex == 1 && s.mode == GXFindHex) *err = GXL(@"Для имён используйте режим «Текст» или «Regex»");
    return s;
}

- (void)toggleAll {
    BOOL any = NO;
    for (GXFindFile *f in _files) if (!f.selected) any = YES;
    for (GXFindFile *f in _files) f.selected = any;
    [self.tableView reloadData];
}

#pragma mark Поиск

// перебор всего, что подходит: блок получает (данные, файл/архив, запись)
static void GXScanArchive(NSString *path, GXFindSpec *spec, NSInteger gen, NSInteger *genRef, void (^each)(NSData *, NSString *, NSString *)) {
    gxz z;
    if (!gxz_open(&z, path.fileSystemRepresentation, 0, 0)) return;
    for (size_t i = 0; i < z.n && gen == *genRef; i++) {
        gxz_entry *e = &z.e[i];
        if (e->name_len && e->name[e->name_len - 1] == '/') continue;
        NSString *name = [NSString stringWithUTF8String:e->name];
        if (!name || ![spec nameMatches:name] || e->usize > spec.maxSize || e->usize == 0) continue;
        uint8_t *d; size_t n;
        if (!gxz_read(&z, e, (size_t)spec.maxSize, &d, &n)) continue;
        @autoreleasepool { each([NSData dataWithBytesNoCopy:d length:n freeWhenDone:YES], path, name); }
    }
    gxz_close(&z);
}

- (void)search {
    [self.view endEditing:YES];
    NSString *err;
    GXFindSpec *spec = [self spec:&err];
    if (err) { GXAlert(self, GXL(@"Поиск"), err); return; }
    if (_target.selectedSegmentIndex == 1) { [self searchNames:spec]; return; }
    NSInteger gen = ++_gen;
    [_files removeAllObjects];
    _scanned = _totalHits = 0;
    _running = YES;
    _bar.hidden = NO;
    _bar.progress = 0;
    [self.tableView reloadData];
    [self status];
    NSString *root = _root;
    BOOL arch = _rootIsArchive;
    BOOL hidden = GXShowHidden();
    __block NSInteger *genRef = &_gen;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *batch = [NSMutableArray array];
        __block CFAbsoluteTime last = CFAbsoluteTimeGetCurrent();
        __block unsigned long long scanned = 0;
        void (^flush)(BOOL) = ^(BOOL force) {
            if (!force && CFAbsoluteTimeGetCurrent() - last < 0.3) return;
            last = CFAbsoluteTimeGetCurrent();
            NSArray *b = batch.copy;
            [batch removeAllObjects];
            unsigned long long sc = scanned;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != self->_gen) return;
                [self->_files addObjectsFromArray:b];
                for (GXFindFile *f in b) self->_totalHits += f.total;
                self->_scanned = sc;
                [self.tableView reloadData];
                [self status];
            });
        };
        void (^check)(NSData *, NSString *, NSString *) = ^(NSData *d, NSString *path, NSString *entry) {
            scanned++;
            NSUInteger total = 0;
            NSArray *hits = [spec find:d total:&total maxHits:30];
            if (total) {
                GXFindFile *f = [GXFindFile new];
                f.path = path;
                f.entry = entry;
                NSString *rel = [path hasPrefix:root] ? [path substringFromIndex:root.length] : path;
                if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
                f.display = entry ? (rel.length ? [NSString stringWithFormat:@"%@ ▸ %@", rel, entry] : entry) : rel;
                f.hits = hits;
                f.total = total;
                f.selected = YES;
                [batch addObject:f];
            }
            flush(NO);
        };
        if (arch) GXScanArchive(root, spec, gen, genRef, check);
        else {
            NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                       options:hidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
            for (NSURL *u in en) {
                if (gen != self->_gen) return;
                NSNumber *reg, *sz;
                [u getResourceValue:&reg forKey:NSURLIsRegularFileKey error:nil];
                if (!reg.boolValue) continue;
                [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
                NSString *p = u.path;
                if (spec.intoArchives && GXIsZipFamily(p) && GXKindForName(p.lastPathComponent, NO) != GXKindOther) {
                    GXScanArchive(p, spec, gen, genRef, check);
                    continue;
                }
                if (![spec nameMatches:p] || sz.unsignedLongLongValue > spec.maxSize || !sz.unsignedLongLongValue) continue;
                @autoreleasepool {
                    NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil];
                    if (d) check(d, p, nil);
                }
            }
        }
        flush(YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_gen) return;
            self->_running = NO;
            self->_bar.hidden = YES;
            [self status];
        });
    });
}

- (void)status {
    _status.text = _running ? [NSString stringWithFormat:GXL(@"Ищу… просмотрено %llu, найдено в %lu (совпадений %llu)"), _scanned, (unsigned long)_files.count, _totalHits]
                 : _files.count ? [NSString stringWithFormat:GXL(@"Готово: %llu совпадений в %lu файлах (просмотрено %llu). Снимите галочки с файлов, где менять не нужно."), _totalHits, (unsigned long)_files.count, _scanned]
                 : _scanned ? [NSString stringWithFormat:GXL(@"Ничего не найдено (просмотрено %llu)"), _scanned] : @"";
    if (_running) [_bar setProgress:fmodf((float)_scanned / 200.0f, 1.0f) animated:NO];
}

#pragma mark Замена

- (void)replaceSelected {
    [self.view endEditing:YES];
    NSMutableArray<GXFindFile *> *sel = [NSMutableArray array];
    for (GXFindFile *f in _files) if (f.selected && !f.done) [sel addObject:f];
    if (!sel.count) { GXAlert(self, GXL(@"Замена"), GXL(@"Сначала найдите и отметьте файлы")); return; }
    NSString *err;
    GXFindSpec *spec = [self spec:&err];
    if (err) { GXAlert(self, GXL(@"Замена"), err); return; }
    NSUInteger n = 0;
    for (GXFindFile *f in sel) n += f.total;
    if (_target.selectedSegmentIndex == 1) {
        NSString *m2 = [NSString stringWithFormat:GXL(@"«%@» → «%@»\nБудет переименовано объектов: %lu (папки — вместе со всем содержимым). Архивы меняются без распаковки."), _q.text, _r.text, (unsigned long)sel.count];
        GXConfirm(self, GXL(@"Переименовать?"), m2, GXL(@"Переименовать"), YES, ^{ [self doRename:sel spec:spec]; });
        return;
    }
    NSString *msg = [NSString stringWithFormat:GXL(@"«%@» → «%@»\n%lu совпадений в %lu файлах. Файлы изменятся сразу, архивы — без распаковки."), _q.text, _r.text, (unsigned long)n, (unsigned long)sel.count];
    GXConfirm(self, GXL(@"Заменить?"), msg, GXL(@"Заменить"), YES, ^{ [self doReplace:sel spec:spec]; });
}

#pragma mark Имена

static GXFindFile *GXNameHit(NSString *display, NSString *path, NSString *entry, NSString *oldName, NSString *newName, BOOL dir) {
    GXFindFile *f = [GXFindFile new];
    f.display = display;
    f.path = path;
    f.entry = entry;
    GXFindHit *h = [GXFindHit new];
    h.snippet = [NSString stringWithFormat:@"%@%@  →  %@", dir ? @"📁 " : @"", oldName, newName];
    f.hits = @[h];
    f.total = 1;
    f.selected = YES;
    return f;
}

// уникальные префиксы путей в архиве, чьё последнее звено переименовывается
static void GXArchiveNameHits(NSString *arc, NSString *root, GXFindSpec *spec, NSMutableArray *out) {
    gxz z;
    if (!gxz_open(&z, arc.fileSystemRepresentation, 0, 0)) return;
    NSMutableSet *seen = [NSMutableSet set];
    NSString *rel = [arc hasPrefix:root] ? [arc substringFromIndex:root.length] : arc.lastPathComponent;
    if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
    for (size_t i = 0; i < z.n; i++) {
        NSString *name = [NSString stringWithUTF8String:z.e[i].name];
        if (!name) continue;
        BOOL dirEntry = [name hasSuffix:@"/"];
        NSArray *comps = [(dirEntry ? [name substringToIndex:name.length - 1] : name) componentsSeparatedByString:@"/"];
        NSMutableString *prefix = [NSMutableString string];
        for (NSUInteger k = 0; k < comps.count; k++) {
            if (k) [prefix appendString:@"/"];
            [prefix appendString:comps[k]];
            if ([seen containsObject:prefix]) continue;
            [seen addObject:prefix.copy];
            BOOL isDir = k + 1 < comps.count || dirEntry;
            if (!isDir && ![spec nameMatches:comps[k]]) continue;
            NSString *nn = [spec renamed:comps[k]];
            if (!nn) continue;
            NSString *disp = rel.length ? [NSString stringWithFormat:@"%@ ▸ %@", rel, prefix] : prefix.copy;
            [out addObject:GXNameHit(disp, arc, prefix.copy, comps[k], nn, isDir)];
        }
    }
    gxz_close(&z);
}

- (void)searchNames:(GXFindSpec *)spec {
    NSInteger gen = ++_gen;
    [_files removeAllObjects];
    _scanned = _totalHits = 0;
    _running = YES;
    [self.tableView reloadData];
    [self status];
    NSString *root = _root;
    BOOL arch = _rootIsArchive, hidden = GXShowHidden();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *out = [NSMutableArray array];
        unsigned long long scanned = 0;
        if (arch) GXArchiveNameHits(root, root, spec, out);
        else {
            NSDirectoryEnumerator *en = [FM() enumeratorAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                       options:hidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *e) { return YES; }];
            for (NSURL *u in en) {
                if (gen != self->_gen) return;
                scanned++;
                NSNumber *isd;
                [u getResourceValue:&isd forKey:NSURLIsDirectoryKey error:nil];
                NSString *p = u.path, *n = p.lastPathComponent;
                if (!isd.boolValue && spec.intoArchives && GXIsZipFamily(p)) GXArchiveNameHits(p, root, spec, out);
                if (!isd.boolValue && ![spec nameMatches:n]) continue;
                NSString *nn = [spec renamed:n];
                if (!nn) continue;
                NSString *rel = [p substringFromIndex:MIN(p.length, root.length + 1)];
                [out addObject:GXNameHit(rel, p, nil, n, nn, isd.boolValue)];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != self->_gen) return;
            [self->_files setArray:out];
            self->_totalHits = out.count;
            self->_scanned = scanned ?: out.count;
            self->_running = NO;
            self->_bar.hidden = YES;
            [self.tableView reloadData];
            [self status];
        });
    });
}

- (void)doRename:(NSArray<GXFindFile *> *)sel spec:(GXFindSpec *)spec {
    [GXHUD showIn:self.view text:GXL(@"Переименовываю…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *errs = [NSMutableString string];
        NSUInteger done = 0;
        NSMutableDictionary<NSString *, NSMutableSet *> *byArc = [NSMutableDictionary dictionary];
        NSMutableArray *plain = [NSMutableArray array];
        for (GXFindFile *f in sel) {
            if (f.entry) { NSMutableSet *st = byArc[f.path]; if (!st) byArc[f.path] = st = [NSMutableSet set]; [st addObject:f.entry]; }
            else [plain addObject:f];
        }
        // на диске: сначала самые глубокие, чтобы пути родителей оставались верными
        [plain sortUsingComparator:^NSComparisonResult(GXFindFile *a, GXFindFile *b) {
            NSUInteger da = a.path.pathComponents.count, db = b.path.pathComponents.count;
            return da > db ? NSOrderedAscending : da < db ? NSOrderedDescending : NSOrderedSame;
        }];
        for (GXFindFile *f in plain) {
            NSString *nn = [spec renamed:f.path.lastPathComponent];
            if (!nn.length || [nn containsString:@"/"]) { [errs appendFormat:GXL(@"%@: недопустимое имя\n"), f.display]; continue; }
            NSString *dst = [f.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:nn];
            if ([FM() fileExistsAtPath:dst] && [nn caseInsensitiveCompare:f.path.lastPathComponent] != NSOrderedSame) { [errs appendFormat:GXL(@"%@: «%@» уже существует\n"), f.display, nn]; continue; }
            NSError *e;
            if ([FM() moveItemAtPath:f.path toPath:dst error:&e]) { done++; f.done = YES; }
            else [errs appendFormat:@"%@: %@\n", f.display, e.localizedDescription];
        }
        for (NSString *arc in byArc) {
            NSSet *sel2 = byArc[arc];
            gxz z;
            if (!gxz_open(&z, arc.fileSystemRepresentation, 0, 0)) { [errs appendFormat:@"%@: %s\n", arc.lastPathComponent, z.err]; continue; }
            NSMutableArray *ops = [NSMutableArray array];
            NSMutableSet *newNames = [NSMutableSet set];
            for (size_t i = 0; i < z.n; i++) {
                NSString *name = [NSString stringWithUTF8String:z.e[i].name];
                if (!name) continue;
                BOOL dirEntry = [name hasSuffix:@"/"];
                NSMutableArray *comps = [[(dirEntry ? [name substringToIndex:name.length - 1] : name) componentsSeparatedByString:@"/"] mutableCopy];
                NSMutableString *prefix = [NSMutableString string];
                BOOL changed = NO;
                for (NSUInteger k = 0; k < comps.count; k++) {
                    NSString *orig = [[name componentsSeparatedByString:@"/"] objectAtIndex:k];
                    if (k) [prefix appendString:@"/"];
                    [prefix appendString:orig];
                    if (![sel2 containsObject:prefix]) continue;
                    NSString *nn = [spec renamed:orig];
                    if (nn.length && ![nn containsString:@"/"]) { comps[k] = nn; changed = YES; }
                }
                NSString *newName = [comps componentsJoinedByString:@"/"];
                if (dirEntry) newName = [newName stringByAppendingString:@"/"];
                [newNames addObject:newName];
                if (changed) [ops addObject:@{@"name": name, @"newName": newName}];
            }
            NSUInteger total = z.n;
            gxz_close(&z);
            if (newNames.count < total) { [errs appendFormat:GXL(@"%@: после переименования совпадут имена — отменено\n"), arc.lastPathComponent]; continue; }
            if (!ops.count) continue;
            [GXHUD setText:[NSString stringWithFormat:GXL(@"Пишу %@…"), arc.lastPathComponent]];
            NSString *e = GXZipApply(arc, ops, ^(double p) { [GXHUD setProgress:p]; });
            if (e) { [errs appendFormat:@"%@: %@\n", arc.lastPathComponent, e]; continue; }
            for (GXFindFile *f in sel) if ([f.path isEqualToString:arc] && f.entry) f.done = YES;
            done += sel2.count;
            GXArcModel *m = [GXArcModel modelFor:arc];
            if (GXIsAPKPath(arc)) m.modifiedSinceSign = YES;
            [m reload];
            dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:GXArcChangedNotification object:m]; });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            [self.tableView reloadData];
            NSString *msg = [NSString stringWithFormat:GXL(@"Переименовано: %lu%@%@"), (unsigned long)done, errs.length ? GXL(@"\n\nОшибки:\n") : @"", errs];
            GXAlert(self, GXL(@"Готово"), msg);
        });
    });
}

- (void)doReplace:(NSArray<GXFindFile *> *)sel spec:(GXFindSpec *)spec {
    [GXHUD showIn:self.view text:GXL(@"Заменяю…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *errs = [NSMutableString string];
        NSUInteger replaced = 0, files = 0;
        NSMutableDictionary<NSString *, NSMutableArray<GXFindFile *> *> *byArchive = [NSMutableDictionary dictionary];
        NSMutableArray *apks = [NSMutableArray array];
        for (GXFindFile *f in sel) {
            if (f.entry) { NSMutableArray *l = byArchive[f.path]; if (!l) byArchive[f.path] = l = [NSMutableArray array]; [l addObject:f]; continue; }
            NSData *d = [NSData dataWithContentsOfFile:f.path];
            NSUInteger c = 0;
            NSData *o = d ? [spec replace:d count:&c] : nil;
            if (!o) continue;
            NSError *e;
            if (![o writeToFile:f.path options:NSDataWritingAtomic error:&e]) { [errs appendFormat:@"%@: %@\n", f.display, e.localizedDescription]; continue; }
            replaced += c; files++; f.done = YES;
        }
        for (NSString *arc in byArchive) {
            gxz z;
            if (!gxz_open(&z, arc.fileSystemRepresentation, 0, 0)) { [errs appendFormat:@"%@: %s\n", arc.lastPathComponent, z.err]; continue; }
            NSMutableArray *ops = [NSMutableArray array];
            NSMutableArray *done = [NSMutableArray array];
            NSUInteger cnt = 0;
            for (GXFindFile *f in byArchive[arc]) {
                long i = gxz_find(&z, f.entry.UTF8String);
                if (i < 0) continue;
                uint8_t *d; size_t n;
                if (!gxz_read(&z, &z.e[i], (size_t)spec.maxSize, &d, &n)) continue;
                NSUInteger c = 0;
                NSData *o = [spec replace:[NSData dataWithBytesNoCopy:d length:n freeWhenDone:YES] count:&c];
                if (!o) continue;
                [ops addObject:@{@"name": f.entry, @"data": o}];
                [done addObject:f];
                cnt += c;
            }
            gxz_close(&z);
            if (!ops.count) continue;
            [GXHUD setText:[NSString stringWithFormat:GXL(@"Пишу %@…"), arc.lastPathComponent]];
            NSString *e = GXZipApply(arc, ops, ^(double p) { [GXHUD setProgress:p]; });
            if (e) { [errs appendFormat:@"%@: %@\n", arc.lastPathComponent, e]; continue; }
            for (GXFindFile *f in done) f.done = YES;
            replaced += cnt; files += done.count;
            if (GXIsAPKPath(arc)) { [apks addObject:arc]; [GXArcModel modelFor:arc].modifiedSinceSign = YES; }
            GXArcModel *m = [GXArcModel modelFor:arc];
            [m reload];
            dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:GXArcChangedNotification object:m]; });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            [self.tableView reloadData];
            NSMutableString *msg = [NSMutableString stringWithFormat:GXL(@"Заменено %lu совпадений в %lu файлах."), (unsigned long)replaced, (unsigned long)files];
            if (apks.count) [msg appendFormat:GXL(@"\n\nИзменены APK (%lu) — их подпись снята. Подписать сейчас ключом GX Files?"), (unsigned long)apks.count];
            if (errs.length) [msg appendFormat:GXL(@"\n\nОшибки:\n%@"), errs];
            UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Готово") message:msg preferredStyle:UIAlertControllerStyleAlert];
            if (apks.count) [a addAction:[UIAlertAction actionWithTitle:GXL(@"Подписать") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self signAll:apks]; }]];
            [a addAction:[UIAlertAction actionWithTitle:apks.count ? GXL(@"Не сейчас") : @"OK" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

- (void)signAll:(NSArray<NSString *> *)apks {
    GXRunBG(self, GXL(@"Подписываю…"), ^NSString *{
        NSMutableString *e = [NSMutableString string];
        for (NSString *p in apks) {
            NSString *x = GXSignAPK(p, p, nil);
            if (x) [e appendFormat:@"%@: %@\n", p.lastPathComponent, x];
            else [GXArcModel modelFor:p].modifiedSinceSign = NO;
        }
        return e.length ? e : nil;
    }, ^{ GXToast(self.view, GXL(@"Подписано")); });
}

#pragma mark Таблица

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _files.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 1 + (NSInteger)_files[s].hits.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    GXFindFile *f = _files[ip.section];
    if (ip.row == 0) {
        UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
        c.textLabel.text = f.display.lastPathComponent;
        c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        c.textLabel.textColor = f.done ? UIColor.systemGreenColor : UIColor.labelColor;
        c.detailTextLabel.text = [NSString stringWithFormat:GXL(@"%@%@ · %lu совп."), f.done ? GXL(@"✓ заменено · ") : @"", f.display, (unsigned long)f.total];
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingHead;
        c.imageView.image = GXSymbolTile(f.selected ? @"checkmark.circle.fill" : @"circle", f.selected ? UIColor.systemOrangeColor : UIColor.tertiaryLabelColor, 26);
        c.accessoryType = UITableViewCellAccessoryNone;
        return c;
    }
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"h"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"h"];
    GXFindHit *h = f.hits[ip.row - 1];
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    c.textLabel.numberOfLines = 3;
    c.textLabel.text = h.snippet;
    c.detailTextLabel.text = h.line ? [NSString stringWithFormat:GXL(@"строка %lu"), (unsigned long)h.line] : nil;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.indentationLevel = 2;
    c.imageView.image = nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    GXFindFile *f = _files[s];
    return f.total > f.hits.count ? [NSString stringWithFormat:GXL(@"…и ещё %lu"), (unsigned long)(f.total - f.hits.count)] : nil;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    GXFindFile *f = _files[ip.section];
    if (ip.row == 0) { f.selected = !f.selected; [tv reloadSections:[NSIndexSet indexSetWithIndex:ip.section] withRowAnimation:UITableViewRowAnimationNone]; return; }
    [self openFile:f];
}

- (void)openFile:(GXFindFile *)f {
    if (_target.selectedSegmentIndex == 1) {
        if (f.entry) [self.navigationController pushViewController:[[GXArchiveVC alloc] initWithArchive:f.path] animated:YES];
        else [self.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:f.path.stringByDeletingLastPathComponent] animated:YES];
        return;
    }
    if (f.entry) {
        GXArcModel *m = [GXArcModel modelFor:f.path];
        if (!m.entries.count) [m reload];
        GXArcEntry *e = [m entryNamed:f.entry];
        if (!e) { GXAlert(self, GXL(@"Не найдено"), f.entry); return; }
        [GXDefaults() setObject:_mode.selectedSegmentIndex == GXFindHex ? nil : _q.text forKey:@"gxPendingFind"];
        [m openEntry:e from:self];
        return;
    }
    [GXDefaults() setObject:_mode.selectedSegmentIndex == GXFindHex ? nil : _q.text forKey:@"gxPendingFind"];
    [GXOpener open:f.path from:self];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    GXFindFile *f = _files[ip.section];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:[UIAction actionWithTitle:GXL(@"Открыть файл") image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(UIAction *x) { [ws openFile:f]; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Заменить только здесь") image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *x) {
            GXFindVC *me = ws;
            if (!me) return;
            NSString *err;
            GXFindSpec *sp = [me spec:&err];
            if (err) { GXAlert(me, GXL(@"Замена"), err); return; }
            [me doReplace:@[f] spec:sp];
        }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Показать в папке") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *x) {
            if (f.entry) [ws.navigationController pushViewController:[[GXArchiveVC alloc] initWithArchive:f.path] animated:YES];
            else [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:f.path.stringByDeletingLastPathComponent] animated:YES];
        }]];
        return [UIMenu menuWithTitle:f.display children:a];
    }];
}
@end

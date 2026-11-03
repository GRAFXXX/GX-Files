// Пакетное переименование, сравнение файлов, две панели
#import "GXCore.h"

#pragma mark - Пакетное переименование

@interface GXRenameVC () <UITextFieldDelegate>
@end

@implementation GXRenameVC {
    NSArray<NSString *> *_paths;
    NSArray<NSString *> *_newNames;
    UITextField *_pattern, *_find, *_repl, *_start;
    UISegmentedControl *_case;
    UISwitch *_regex;
    NSString *_problem;
}

- (instancetype)initWithPaths:(NSArray<NSString *> *)paths {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]))
        _paths = [paths sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) { return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent]; }];
    return self;
}

- (UITextField *)tf:(NSString *)ph text:(NSString *)t {
    UITextField *f = [UITextField new];
    f.placeholder = ph;
    f.text = t;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    [f addTarget:self action:@selector(recompute) forControlEvents:UIControlEventEditingChanged];
    return f;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:GXL(@"Переименовать (%lu)"), (unsigned long)_paths.count];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Применить") style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
    _pattern = [self tf:GXL(@"Шаблон") text:@"{name}{ext}"];
    _find = [self tf:GXL(@"Найти в имени (необязательно)") text:@""];
    _repl = [self tf:GXL(@"Заменить на") text:@""];
    _start = [self tf:GXL(@"Начать нумерацию с") text:@"1"];
    _start.keyboardType = UIKeyboardTypeNumberPad;
    _regex = [UISwitch new];
    [_regex addTarget:self action:@selector(recompute) forControlEvents:UIControlEventValueChanged];
    _case = [[UISegmentedControl alloc] initWithItems:@[GXL(@"Как есть"), GXL(@"нижний"), GXL(@"ВЕРХНИЙ")]];
    _case.selectedSegmentIndex = 0;
    [_case addTarget:self action:@selector(recompute) forControlEvents:UIControlEventValueChanged];
    UIStackView *v = [UIStackView new];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 8;
    v.layoutMargins = UIEdgeInsetsMake(12, 16, 8, 16);
    v.layoutMarginsRelativeArrangement = YES;
    UILabel *help = [UILabel new];
    help.numberOfLines = 0;
    help.font = [UIFont systemFontOfSize:12];
    help.textColor = UIColor.secondaryLabelColor;
    help.text = GXL(@"Шаблон: {name} — имя без расширения, {ext} — расширение с точкой, {n} — номер, {n:3} — номер с нулями (001), {date} — дата изменения (ГГГГ-ММ-ДД), {parent} — имя папки.");
    UIStackView *rx = [UIStackView new];
    UILabel *rl = [UILabel new];
    rl.text = GXL(@"Регулярное выражение");
    [rx addArrangedSubview:rl];
    [rx addArrangedSubview:_regex];
    for (UIView *x in @[_pattern, help, _find, _repl, rx, _start, _case]) [v addArrangedSubview:x];
    CGSize sz = [v systemLayoutSizeFittingSize:CGSizeMake(self.view.bounds.size.width, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    v.frame = CGRectMake(0, 0, self.view.bounds.size.width, sz.height);
    self.tableView.tableHeaderView = v;
    [self recompute];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *h = self.tableView.tableHeaderView;
    CGFloat w = self.tableView.bounds.size.width;
    CGSize sz = [h systemLayoutSizeFittingSize:CGSizeMake(w, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(h.frame.size.height - sz.height) > 1 || fabs(h.frame.size.width - w) > 1) { h.frame = CGRectMake(0, 0, w, sz.height); self.tableView.tableHeaderView = h; }
}

- (void)recompute {
    NSMutableArray *out = [NSMutableArray array];
    NSInteger n = _start.text.integerValue;
    NSRegularExpression *re = nil;
    _problem = nil;
    if (_find.text.length) {
        NSString *pat = _regex.on ? _find.text : [NSRegularExpression escapedPatternForString:_find.text];
        re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
        if (!re) _problem = GXL(@"Ошибка в регулярном выражении");
    }
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd";
    NSRegularExpression *num = [NSRegularExpression regularExpressionWithPattern:@"\\{n(?::(\\d+))?\\}" options:0 error:nil];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *p in _paths) {
        NSString *file = p.lastPathComponent;
        BOOL dir = GXIsDir(p);
        NSString *ext = dir ? @"" : file.pathExtension;
        NSString *base = ext.length ? file.stringByDeletingPathExtension : file;
        NSString *dot = ext.length ? [@"." stringByAppendingString:ext] : @"";
        NSMutableString *r = [_pattern.text.length ? _pattern.text : @"{name}{ext}" mutableCopy];
        [r replaceOccurrencesOfString:@"{name}" withString:base options:0 range:NSMakeRange(0, r.length)];
        [r replaceOccurrencesOfString:@"{ext}" withString:dot options:0 range:NSMakeRange(0, r.length)];
        [r replaceOccurrencesOfString:@"{parent}" withString:p.stringByDeletingLastPathComponent.lastPathComponent options:0 range:NSMakeRange(0, r.length)];
        NSDate *md = [[FM() attributesOfItemAtPath:p error:nil] fileModificationDate] ?: [NSDate date];
        [r replaceOccurrencesOfString:@"{date}" withString:[df stringFromDate:md] options:0 range:NSMakeRange(0, r.length)];
        for (NSTextCheckingResult *m in [[num matchesInString:r options:0 range:NSMakeRange(0, r.length)] reverseObjectEnumerator]) {
            NSInteger w = [m rangeAtIndex:1].location != NSNotFound ? [[r substringWithRange:[m rangeAtIndex:1]] integerValue] : 0;
            NSString *s = [NSString stringWithFormat:@"%0*ld", (int)MIN(w, 12), (long)n];
            [r replaceCharactersInRange:m.range withString:s];
        }
        NSString *res = r;
        if (re) res = [re stringByReplacingMatchesInString:res options:0 range:NSMakeRange(0, res.length)
                                              withTemplate:_regex.on ? _repl.text : [NSRegularExpression escapedTemplateForString:_repl.text]];
        if (_case.selectedSegmentIndex == 1) res = res.lowercaseString;
        if (_case.selectedSegmentIndex == 2) res = res.uppercaseString;
        if (!res.length || [res containsString:@"/"]) _problem = GXL(@"Пустое имя или «/» в имени");
        if ([seen containsObject:res]) _problem = [NSString stringWithFormat:GXL(@"Имя «%@» получается несколько раз"), res];
        [seen addObject:res];
        [out addObject:res];
        n++;
    }
    _newNames = out;
    self.navigationItem.rightBarButtonItem.enabled = !_problem;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _paths.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _problem ?: GXL(@"Предпросмотр"); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"r"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"];
    NSString *old = _paths[ip.row].lastPathComponent, *nw = _newNames[ip.row];
    c.textLabel.text = nw;
    c.textLabel.textColor = [old isEqualToString:nw] ? UIColor.secondaryLabelColor : UIColor.labelColor;
    c.detailTextLabel.text = old;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (void)apply {
    [self.view endEditing:YES];
    if (_problem) return;
    NSMutableString *errs = [NSMutableString string];
    // два прохода через временные имена, чтобы обмены не конфликтовали
    NSMutableArray *tmp = [NSMutableArray array];
    for (NSUInteger i = 0; i < _paths.count; i++) {
        NSString *p = _paths[i];
        if ([p.lastPathComponent isEqualToString:_newNames[i]]) { [tmp addObject:[NSNull null]]; continue; }
        NSString *t = [p.stringByDeletingLastPathComponent stringByAppendingPathComponent:[NSString stringWithFormat:@".gxren-%lu-%@", (unsigned long)i, NSUUID.UUID.UUIDString]];
        NSError *e;
        if ([FM() moveItemAtPath:p toPath:t error:&e]) [tmp addObject:t];
        else { [tmp addObject:[NSNull null]]; [errs appendFormat:@"%@: %@\n", p.lastPathComponent, e.localizedDescription]; }
    }
    NSUInteger done = 0;
    for (NSUInteger i = 0; i < _paths.count; i++) {
        if (tmp[i] == [NSNull null]) continue;
        NSString *dst = [_paths[i].stringByDeletingLastPathComponent stringByAppendingPathComponent:_newNames[i]];
        if ([FM() fileExistsAtPath:dst]) dst = GXUniquePath(dst.stringByDeletingLastPathComponent, dst.lastPathComponent);
        NSError *e;
        if ([FM() moveItemAtPath:tmp[i] toPath:dst error:&e]) done++;
        else { [FM() moveItemAtPath:tmp[i] toPath:_paths[i] error:nil]; [errs appendFormat:@"%@: %@\n", _newNames[i], e.localizedDescription]; }
    }
    if (errs.length) GXAlert(self, [NSString stringWithFormat:GXL(@"Переименовано %lu, есть ошибки"), (unsigned long)done], errs);
    else { GXToast(self.view, [NSString stringWithFormat:GXL(@"Переименовано: %lu"), (unsigned long)done]); [self.navigationController popViewControllerAnimated:YES]; }
}
@end

#pragma mark - Сравнение

static NSString *gxCompare;
void GXSetCompareCandidate(NSString *p) { gxCompare = p; }
NSString *GXCompareCandidate(void) { return gxCompare; }

@implementation GXDiffVC {
    NSString *_a, *_b;
    NSMutableArray<NSArray *> *_rows;   // [тип(0 = общая, 1 = удалена, 2 = добавлена), текст, номерA, номерB]
    NSUInteger _added, _removed;
    NSArray<NSNumber *> *_changeRows;
    NSInteger _cursor;
}

- (instancetype)initWithLeft:(NSString *)a right:(NSString *)b {
    if ((self = [super initWithStyle:UITableViewStylePlain])) { _a = a; _b = b; _rows = [NSMutableArray array]; _cursor = -1; }
    return self;
}

static NSArray<NSString *> *GXLines(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:d encoding:NSWindowsCP1251StringEncoding] ?: @"";
    NSMutableArray *r = [NSMutableArray array];
    [s enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) { [r addObject:line]; }];
    return r;
}

// Майерс O((N+M)·D)
- (void)diff:(NSArray<NSString *> *)A with:(NSArray<NSString *> *)B {
    NSInteger n = (NSInteger)A.count, m = (NSInteger)B.count, max = n + m;
    NSMutableArray<NSData *> *trace = [NSMutableArray array];
    NSMutableData *vd = [NSMutableData dataWithLength:sizeof(NSInteger) * (size_t)(2 * max + 4)];
    NSInteger *v = vd.mutableBytes;
    NSInteger off = max + 1;
    NSInteger dFound = -1;
    for (NSInteger d = 0; d <= max && dFound < 0; d++) {
        [trace addObject:[NSData dataWithBytes:v + off - d - 1 length:sizeof(NSInteger) * (size_t)(2 * d + 3)]];
        if (d > 1500) break;   // слишком разные — показываем как замену целиком
        for (NSInteger k = -d; k <= d; k += 2) {
            NSInteger x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
            NSInteger y = x - k;
            while (x < n && y < m && [A[x] isEqualToString:B[y]]) { x++; y++; }
            v[off + k] = x;
            if (x >= n && y >= m) { dFound = d; break; }
        }
    }
    if (dFound < 0) {
        for (NSInteger i = 0; i < n; i++) [_rows addObject:@[@1, A[i], @(i + 1), @0]];
        for (NSInteger j = 0; j < m; j++) [_rows addObject:@[@2, B[j], @0, @(j + 1)]];
        _removed = n; _added = m;
        return;
    }
    NSMutableArray *rev = [NSMutableArray array];
    NSInteger x = n, y = m;
    for (NSInteger d = dFound; d >= 0; d--) {
        const NSInteger *pv = trace[d].bytes;
        NSInteger k = x - y;
        NSInteger pk = (k == -d || (k != d && pv[k - 1 + d + 1] < pv[k + 1 + d + 1])) ? k + 1 : k - 1;
        NSInteger px = d ? pv[pk + d + 1] : 0, py = px - pk;
        while (x > px && y > py) { x--; y--; [rev addObject:@[@0, A[x], @(x + 1), @(y + 1)]]; }
        if (d > 0) {
            if (x == px) { y--; [rev addObject:@[@2, B[y], @0, @(y + 1)]]; _added++; }
            else { x--; [rev addObject:@[@1, A[x], @(x + 1), @0]]; _removed++; }
        }
    }
    for (id r in rev.reverseObjectEnumerator) [_rows addObject:r];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Сравнение");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 20;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"] style:UIBarButtonItemStylePlain target:self action:@selector(nextChange)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.up"] style:UIBarButtonItemStylePlain target:self action:@selector(prevChange)]];
    [GXHUD showIn:self.view text:GXL(@"Сравниваю…")];
    NSString *a = _a, *b = _b;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *A = GXLines(a), *B = GXLines(b);
        [self diff:A with:B];
        NSMutableArray *ch = [NSMutableArray array];
        for (NSUInteger i = 0; i < self->_rows.count; i++) if ([self->_rows[i][0] intValue] && (i == 0 || ![self->_rows[i - 1][0] intValue])) [ch addObject:@(i)];
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            self->_changeRows = ch;
            [self.tableView reloadData];
        });
    });
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)jump:(NSInteger)d {
    if (!_changeRows.count) { GXToast(self.view, GXL(@"Файлы одинаковые")); return; }
    _cursor = (_cursor + d + (NSInteger)_changeRows.count) % (NSInteger)_changeRows.count;
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_changeRows[_cursor].integerValue inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}
- (void)nextChange { [self jump:1]; }
- (void)prevChange { [self jump:-1]; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"− %@ (%lu)\n+ %@ (%lu)", _a.lastPathComponent, (unsigned long)_removed, _b.lastPathComponent, (unsigned long)_added];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"d"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        c.textLabel.numberOfLines = 0;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSArray *r = _rows[ip.row];
    int t = [r[0] intValue];
    NSString *num = t == 2 ? [NSString stringWithFormat:@"%5@", r[3]] : [NSString stringWithFormat:@"%5@", r[2]];
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@ %@", num, t == 1 ? @"−" : t == 2 ? @"+" : @" ", r[1]];
    c.backgroundColor = t == 1 ? [UIColor.systemRedColor colorWithAlphaComponent:0.18] : t == 2 ? [UIColor.systemGreenColor colorWithAlphaComponent:0.18] : UIColor.systemBackgroundColor;
    return c;
}
@end

#pragma mark - Две панели

@implementation GXPanelsVC {
    UINavigationController *_navs[2];
}
static __weak GXPanelsVC *gxPanels;
+ (instancetype)shared { return gxPanels; }

- (instancetype)init {
    if ((self = [super init])) {
        for (int i = 0; i < 2; i++) {
            _navs[i] = [[UINavigationController alloc] initWithRootViewController:[GXRootsVC new]];
            _navs[i].navigationBar.prefersLargeTitles = YES;
        }
        gxPanels = self;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self show:0 animated:NO];
}

- (UINavigationController *)currentNav { return _navs[_current]; }

- (void)show:(NSInteger)i animated:(BOOL)animated {
    UINavigationController *old = _navs[_current], *nw = _navs[i];
    if (old.parentViewController == self && old != nw) {
        [old willMoveToParentViewController:nil];
        [old.view removeFromSuperview];
        [old removeFromParentViewController];
    }
    _current = i;
    if (nw.parentViewController != self) {
        [self addChildViewController:nw];
        nw.view.frame = self.view.bounds;
        nw.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:nw.view];
        [nw didMoveToParentViewController:self];
    }
    if (animated) [UIView transitionWithView:self.view duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
    if (animated) GXToast(self.view, [NSString stringWithFormat:GXL(@"Панель %ld"), (long)i + 1]);
}

- (void)switchPanel { [self show:1 - _current animated:YES]; }

- (NSString *)otherPanelPath {
    UIViewController *top = _navs[1 - _current].topViewController;
    for (UIViewController *vc in _navs[1 - _current].viewControllers.reverseObjectEnumerator)
        if ([vc isKindOfClass:GXBrowserVC.class]) return ((GXBrowserVC *)vc).path;
    (void)top;
    return nil;
}

- (UIViewController *)childViewControllerForStatusBarStyle { return _navs[_current]; }
@end

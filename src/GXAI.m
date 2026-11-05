// ИИ-помощник для файлов: любая модель по API — OpenAI-совместимые (OpenAI, Gemini, OpenRouter,
// DeepSeek, Groq, Mistral, xAI), Anthropic и локальные (Ollama, LM Studio на компьютере в сети).
// Модель работает с файлами только внутри выбранной папки через инструменты; каждое изменение
// сохраняет резервную копию, и все изменения чата можно отменить.
#import "GXCore.h"
#import "GXAIEngine.h"

#pragma mark - Ячейка сообщения

@interface GXAIBubbleCell : UITableViewCell
- (void)configure:(NSDictionary *)item;
@end

@implementation GXAIBubbleCell {
    UIView *_bubble; UILabel *_label;
    NSLayoutConstraint *_left, *_right, *_center;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _bubble = [UIView new]; _bubble.translatesAutoresizingMaskIntoConstraints = NO;
        _bubble.layer.cornerRadius = 16; _bubble.layer.cornerCurve = kCACornerCurveContinuous;
        _label = [UILabel new]; _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.numberOfLines = 0;
        [self.contentView addSubview:_bubble]; [_bubble addSubview:_label];
        UIView *cv = self.contentView;
        [NSLayoutConstraint activateConstraints:@[
            [_bubble.topAnchor constraintEqualToAnchor:cv.topAnchor constant:4],
            [_bubble.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-4],
            [_bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:cv.leadingAnchor constant:12],
            [_bubble.trailingAnchor constraintLessThanOrEqualToAnchor:cv.trailingAnchor constant:-12],
            [_bubble.widthAnchor constraintLessThanOrEqualToAnchor:cv.widthAnchor multiplier:0.86],
            [_label.topAnchor constraintEqualToAnchor:_bubble.topAnchor constant:9],
            [_label.bottomAnchor constraintEqualToAnchor:_bubble.bottomAnchor constant:-9],
            [_label.leadingAnchor constraintEqualToAnchor:_bubble.leadingAnchor constant:13],
            [_label.trailingAnchor constraintEqualToAnchor:_bubble.trailingAnchor constant:-13],
        ]];
        _left = [_bubble.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:12];
        _right = [_bubble.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-12];
        _center = [_bubble.centerXAnchor constraintEqualToAnchor:cv.centerXAnchor];
    }
    return self;
}
- (void)configure:(NSDictionary *)it {
    NSString *k = it[@"kind"];
    _left.active = _right.active = _center.active = NO;
    _label.textAlignment = NSTextAlignmentNatural;
    _label.attributedText = nil;
    _label.font = [UIFont systemFontOfSize:16];
    if ([k isEqualToString:@"user"]) {
        _right.active = YES;
        _bubble.backgroundColor = UIColor.systemBlueColor; _label.textColor = UIColor.whiteColor;
        _label.text = it[@"text"];
    } else if ([k isEqualToString:@"ai"]) {
        _left.active = YES;
        _bubble.backgroundColor = UIColor.secondarySystemBackgroundColor; _label.textColor = UIColor.labelColor;
        _label.text = it[@"text"];
    } else if ([k isEqualToString:@"err"]) {
        _left.active = YES;
        _bubble.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.14]; _label.textColor = UIColor.systemRedColor;
        _label.font = [UIFont systemFontOfSize:14];
        _label.text = it[@"text"];
    } else if ([k isEqualToString:@"tool"]) {
        _left.active = YES;
        _bubble.backgroundColor = UIColor.clearColor;
        UIColor *col = [it[@"bad"] boolValue] ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
        NSMutableAttributedString *s = [NSMutableAttributedString new];
        UIImage *img = [[UIImage systemImageNamed:it[@"icon"] ?: @"wrench"] imageWithTintColor:col renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (img) {
            NSTextAttachment *at = [NSTextAttachment new]; at.image = img;
            at.bounds = CGRectMake(0, -2, 15, 15 * img.size.height / MAX(img.size.width, 1));
            [s appendAttributedString:[NSAttributedString attributedStringWithAttachment:at]];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:@"  "]];
        }
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:it[@"text"] ?: @"" attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: col}]];
        _label.attributedText = s;
    } else {   // info
        _center.active = YES;
        _bubble.backgroundColor = UIColor.clearColor;
        _label.textColor = UIColor.secondaryLabelColor; _label.font = [UIFont systemFontOfSize:13];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.text = it[@"text"];
    }
}
@end

#pragma mark - Чат

static NSString *GXAIToolIcon(NSString *n) {
    NSDictionary *m = @{@"list_dir": @"folder", @"read_file": @"doc.text", @"write_file": @"square.and.pencil", @"edit_file": @"pencil",
                        @"make_dir": @"folder.badge.plus", @"move": @"arrow.right.doc.on.clipboard", @"copy": @"doc.on.doc",
                        @"delete": @"trash", @"search": @"magnifyingglass", @"file_info": @"info.circle"};
    return m[n] ?: @"wrench";
}

@interface GXAISettingsVC : UITableViewController
@end

@interface GXAIChatVC () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>
@end

@implementation GXAIChatVC {
    NSString *_root; GXAITools *_tools;
    NSMutableArray<NSDictionary *> *_turns;     // для модели
    NSMutableArray<NSDictionary *> *_items;     // для экрана
    UITableView *_tv; UIView *_bar; UITextView *_input; UILabel *_ph; UIButton *_send; NSLayoutConstraint *_inputH;
    BOOL _busy, _cancel, _allowAll; int _steps;
    NSURLSessionDataTask *_task;
}
- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _root = root.copy;
        _tools = [[GXAITools alloc] initWithRoot:root];
        _turns = [NSMutableArray array]; _items = [NSMutableArray array];
        self.title = root.lastPathComponent.length ? root.lastPathComponent : root;
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}
- (void)dealloc { [_task cancel]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    _tv.dataSource = self; _tv.delegate = self;
    _tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tv.rowHeight = UITableViewAutomaticDimension; _tv.estimatedRowHeight = 60;
    _tv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tv.contentInset = UIEdgeInsetsMake(8, 0, 8, 0);
    [_tv registerClass:GXAIBubbleCell.class forCellReuseIdentifier:@"b"];
    [self.view addSubview:_tv];

    _bar = [UIView new]; _bar.translatesAutoresizingMaskIntoConstraints = NO;
    _bar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:_bar];
    _input = [UITextView new]; _input.translatesAutoresizingMaskIntoConstraints = NO;
    _input.font = [UIFont systemFontOfSize:16];
    _input.backgroundColor = UIColor.systemBackgroundColor;
    _input.layer.cornerRadius = 18; _input.layer.cornerCurve = kCACornerCurveContinuous;
    _input.textContainerInset = UIEdgeInsetsMake(9, 10, 9, 10);
    _input.delegate = self; _input.scrollEnabled = NO;
    [_bar addSubview:_input];
    _ph = [UILabel new]; _ph.translatesAutoresizingMaskIntoConstraints = NO;
    _ph.text = GXL(@"Что сделать с файлами?"); _ph.textColor = UIColor.placeholderTextColor; _ph.font = _input.font;
    [_input addSubview:_ph];
    _send = [UIButton buttonWithType:UIButtonTypeSystem]; _send.translatesAutoresizingMaskIntoConstraints = NO;
    [_send addTarget:self action:@selector(sendTap) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:_send];
    _inputH = [_input.heightAnchor constraintEqualToConstant:38];
    [NSLayoutConstraint activateConstraints:@[
        [_tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tv.bottomAnchor constraintEqualToAnchor:_bar.topAnchor],
        [_bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bar.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [_input.leadingAnchor constraintEqualToAnchor:_bar.safeAreaLayoutGuide.leadingAnchor constant:12],
        [_input.topAnchor constraintEqualToAnchor:_bar.topAnchor constant:8],
        [_input.bottomAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:-8],
        [_send.leadingAnchor constraintEqualToAnchor:_input.trailingAnchor constant:8],
        [_send.trailingAnchor constraintEqualToAnchor:_bar.safeAreaLayoutGuide.trailingAnchor constant:-10],
        [_send.bottomAnchor constraintEqualToAnchor:_input.bottomAnchor constant:-1],
        [_send.widthAnchor constraintEqualToConstant:36], [_send.heightAnchor constraintEqualToConstant:36],
        [_ph.leadingAnchor constraintEqualToAnchor:_input.leadingAnchor constant:15],
        [_ph.centerYAnchor constraintEqualToAnchor:_input.topAnchor constant:19],
        _inputH,
    ]];
    [self updateSend];
    [self buildMenu];
    NSDictionary *p = GXAIActive();
    [self addItem:@{@"kind": @"info", @"text": [NSString stringWithFormat:GXL(@"Папка: %@\nОпиши, что сделать — ИИ сам посмотрит файлы и внесёт изменения. Всё, что он меняет, сохраняется в резервную копию, изменения чата можно отменить в меню «…».%@"),
                                                 _root, p ? [NSString stringWithFormat:GXL(@"\nМодель: %@ · %@"), p[@"name"], p[@"model"]] : GXL(@"\n\nСначала подключи модель: «…» → «Модели ИИ».")]}];
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.navigationController setToolbarHidden:YES animated:a]; [self buildMenu]; }

- (void)buildMenu {
    __weak typeof(self) ws = self;
    NSMutableArray *models = [NSMutableArray array];
    NSDictionary *act = GXAIActive();
    for (NSDictionary *p in GXAIProviders()) {
        UIAction *x = [UIAction actionWithTitle:p[@"name"] image:nil identifier:nil handler:^(UIAction *y) { [GXDefaults() setObject:p[@"id"] forKey:@"gxAIActive"]; [ws buildMenu]; }];
        x.subtitle = p[@"model"];
        x.state = [p[@"id"] isEqualToString:act[@"id"]] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [models addObject:x];
    }
    [models addObject:[UIAction actionWithTitle:GXL(@"Модели ИИ…") image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(UIAction *y) {
        [ws.navigationController pushViewController:[GXAISettingsVC new] animated:YES]; }]];
    UIAction *ask = [UIAction actionWithTitle:GXL(@"Спрашивать перед изменениями") image:[UIImage systemImageNamed:@"hand.raised"] identifier:nil handler:^(UIAction *y) {
        [GXDefaults() setBool:!GXAIAskFirst() forKey:@"gxAIConfirm"]; [ws buildMenu]; }];
    ask.state = GXAIAskFirst() ? UIMenuElementStateOn : UIMenuElementStateOff;
    NSUInteger nch = _tools.journal.count;
    UIAction *undo = [UIAction actionWithTitle:[NSString stringWithFormat:GXL(@"Отменить изменения чата (%lu)"), (unsigned long)nch] image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *y) { [ws undoAll]; }];
    if (!nch) undo.attributes = UIMenuElementAttributesDisabled;
    UIAction *fresh = [UIAction actionWithTitle:GXL(@"Новый чат") image:[UIImage systemImageNamed:@"square.and.pencil"] identifier:nil handler:^(UIAction *y) { [ws newChat]; }];
    UIAction *open = [UIAction actionWithTitle:GXL(@"Открыть папку") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *y) {
        [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:ws.rootPath] animated:YES]; }];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[
        [UIMenu menuWithTitle:GXL(@"Модель") image:[UIImage systemImageNamed:@"cpu"] identifier:nil options:0 children:models],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ask, undo]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[fresh, open]],
    ]]];
}
- (NSString *)rootPath { return _root; }

#pragma mark ввод

- (void)textViewDidChange:(UITextView *)tv {
    _ph.hidden = tv.text.length > 0;
    CGFloat h = [tv sizeThatFits:CGSizeMake(tv.bounds.size.width, CGFLOAT_MAX)].height;
    h = MAX(38, MIN(h, 140));
    tv.scrollEnabled = h >= 140;
    if (fabs(_inputH.constant - h) > 0.5) { _inputH.constant = h; [self.view layoutIfNeeded]; }
    [self updateSend];
}
- (void)updateSend {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightRegular];
    [_send setImage:[UIImage systemImageNamed:_busy ? @"stop.circle.fill" : @"arrow.up.circle.fill" withConfiguration:cfg] forState:UIControlStateNormal];
    _send.tintColor = _busy ? UIColor.systemRedColor : UIColor.systemBlueColor;
    _send.enabled = _busy || [_input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}
- (void)sendTap {
    if (_busy) { [self stop]; return; }
    NSString *t = [_input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
    NSDictionary *p = GXAIActive();
    if (!p) { GXAlert(self, GXL(@"Нет модели"), GXL(@"Подключи модель ИИ: «…» → «Модели ИИ».")); return; }
    if (![p[@"model"] length]) { GXAlert(self, GXL(@"Не указана модель"), GXL(@"Открой «Модели ИИ» и выбери модель для этого подключения.")); return; }
    _input.text = @""; [self textViewDidChange:_input];
    [_turns addObject:@{@"role": @"user", @"text": t}];
    [self addItem:@{@"kind": @"user", @"text": t}];
    _steps = 0; _cancel = NO;
    [self step];
}

#pragma mark цикл агента

- (NSString *)systemPrompt {
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"You are a file assistant inside GX Files, a file manager app on iPhone (iOS). You read and modify files ONLY inside the working folder, using the provided tools. Paths are relative to the working folder ('.' is the folder itself).\n"];
    [s appendFormat:@"Working folder: %@\nToday: %@\n", _root, [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithFullDate]];
    NSString *lc = GXLCHome();
    if (lc.length && ([_root isEqualToString:lc] || [_root hasPrefix:[lc stringByAppendingString:@"/"]] || [lc hasPrefix:[_root stringByAppendingString:@"/"]]))
        [s appendString:@"This is LiveContainer storage. Typically: 'Applications/' holds installed .app bundles (Info.plist, binaries, resources); 'Data/Application/<UUID>/' holds each app's data container (Documents, Library/Preferences/*.plist, caches); 'Tweaks/' holds tweaks. Find the right app by reading Info.plist / LCAppInfo.plist or by searching.\n"];
    [s appendString:@"Rules:\n"
     "- Explore first (list_dir, search, read_file); never guess file contents.\n"
     "- For small changes use edit_file with an exact fragment copied from read_file; use write_file for new files or full rewrites.\n"
     "- Binary .plist files are shown and written as XML automatically and stay binary on disk.\n"
     "- Don't delete or move anything unless the user asked or it is clearly necessary. Deleted files go to a backup the user can restore.\n"
     "- The user may deny an action — then adapt or ask.\n"
     "- Be efficient: don't re-read files you already have unless they changed.\n"
     "- When done, briefly say what you changed (list the files). Reply in the user's language."];
    return s;
}

- (void)setBusy:(BOOL)b {
    _busy = b;
    [self updateSend];
    if (b) { if (![_items.lastObject[@"typing"] boolValue]) [self addItem:@{@"kind": @"info", @"text": GXL(@"Думаю…"), @"typing": @YES}]; }
    else [self removeTyping];
}
- (void)removeTyping {
    if ([_items.lastObject[@"typing"] boolValue]) {
        [_items removeLastObject];
        [_tv deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)_items.count inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
    }
}
- (void)step {
    if (_cancel) { [self setBusy:NO]; return; }
    if (++_steps > 40) { [self setBusy:NO]; [self addItem:@{@"kind": @"info", @"text": GXL(@"Остановлено: слишком много шагов подряд. Напиши «продолжай», чтобы продолжить.")}]; return; }
    [self setBusy:YES];
    __weak typeof(self) ws = self;
    _task = [GXAIClient send:GXAIActive() system:[self systemPrompt] turns:_turns tools:GXAITools.specs done:^(NSDictionary *turn, NSString *err) {
        GXAIChatVC *me = ws; if (!me) return;
        me->_task = nil;
        [me removeTyping];
        if (err) {
            [me setBusy:NO];
            [me addItem:@{@"kind": [err isEqualToString:@"cancelled"] ? @"info" : @"err", @"text": [err isEqualToString:@"cancelled"] ? GXL(@"Остановлено") : err}];
            return;
        }
        [me->_turns addObject:turn];
        NSString *tx = [turn[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (tx.length) [me addItem:@{@"kind": @"ai", @"text": tx}];
        NSArray *calls = turn[@"calls"];
        if (!calls.count) { [me setBusy:NO]; return; }
        [me runCalls:calls index:0 results:[NSMutableArray array]];
    }];
}
- (void)runCalls:(NSArray *)calls index:(NSUInteger)i results:(NSMutableArray *)results {
    if (i >= calls.count || _cancel) {
        for (NSUInteger k = results.count; k < calls.count; k++)
            [results addObject:@{@"id": calls[k][@"id"], @"name": calls[k][@"name"], @"content": @"Cancelled by the user.", @"error": @YES}];
        [_turns addObject:@{@"role": @"tool", @"results": results}];
        [self buildMenu];
        if (_cancel) { [self setBusy:NO]; [self addItem:@{@"kind": @"info", @"text": GXL(@"Остановлено")}]; return; }
        [self step];
        return;
    }
    NSDictionary *c = calls[i];
    NSString *name = c[@"name"]; NSDictionary *args = [c[@"args"] isKindOfClass:NSDictionary.class] ? c[@"args"] : @{};
    __weak typeof(self) ws = self;
    void (^exec)(void) = ^{
        GXAITools *tools = self->_tools;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL bad = NO; NSString *sum = nil;
            NSString *res = [tools run:name args:args isError:&bad summary:&sum];
            if (res.length > 40000) res = [[res substringToIndex:40000] stringByAppendingString:@"\n[… output truncated]"];
            dispatch_async(dispatch_get_main_queue(), ^{
                GXAIChatVC *me = ws; if (!me) return;
                [me removeTyping];
                [me addItem:@{@"kind": @"tool", @"icon": GXAIToolIcon(name), @"text": sum ?: name, @"bad": @(bad)}];
                [results addObject:@{@"id": c[@"id"], @"name": name, @"content": res ?: @"", @"error": @(bad)}];
                if (me->_busy) [me addItem:@{@"kind": @"info", @"text": GXL(@"Думаю…"), @"typing": @YES}];
                [me runCalls:calls index:i + 1 results:results];
            });
        });
    };
    if (![GXAITools mutating:name] || !GXAIAskFirst() || _allowAll) { exec(); return; }
    // подтверждение изменения
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"ИИ хочет изменить файлы") message:[_tools describe:name args:args] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Разрешить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { exec(); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Разрешать всё в этом чате") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        GXAIChatVC *me = ws; if (me) me->_allowAll = YES; exec(); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Запретить") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        GXAIChatVC *me = ws; if (!me) return;
        [me addItem:@{@"kind": @"tool", @"icon": @"hand.raised", @"text": GXL(@"Запрещено пользователем"), @"bad": @YES}];
        [results addObject:@{@"id": c[@"id"], @"name": name, @"content": @"The user denied this action.", @"error": @YES}];
        [me runCalls:calls index:i + 1 results:results];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)stop {
    _cancel = YES;
    [_task cancel];
}
- (void)undoAll {
    if (_busy) { GXToast(self.view, GXL(@"Дождись окончания или останови ИИ")); return; }
    NSUInteger n = _tools.journal.count;
    GXConfirm(self, GXL(@"Отменить изменения?"), [NSString stringWithFormat:GXL(@"Будут отменены все изменения файлов, сделанные ИИ в этом чате (%lu)."), (unsigned long)n], GXL(@"Отменить"), YES, ^{
        NSString *r = [self->_tools undoAll];
        [self addItem:@{@"kind": @"info", @"text": r}];
        [self->_turns addObject:@{@"role": @"user", @"text": @"[System note: the user has undone all file changes you made in this chat. Files are back to their original state.]"}];
        [self->_turns addObject:@{@"role": @"assistant", @"text": @"OK.", @"calls": @[]}];
        [self buildMenu];
    });
}
- (void)newChat {
    if (_busy) [self stop];
    [_turns removeAllObjects]; [_items removeAllObjects]; _allowAll = NO;
    [_tv reloadData];
    [self addItem:@{@"kind": @"info", @"text": [NSString stringWithFormat:GXL(@"Новый чат · папка %@"), self.title]}];
}

#pragma mark таблица

- (void)addItem:(NSDictionary *)it {
    [_items addObject:it];
    NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)_items.count - 1 inSection:0];
    [_tv insertRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ((NSInteger)self->_items.count > ip.row) [self->_tv scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)self->_items.count - 1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:YES];
    });
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_items.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    GXAIBubbleCell *c = [tv dequeueReusableCellWithIdentifier:@"b" forIndexPath:ip];
    [c configure:_items[ip.row]];
    return c;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    NSString *t = _items[ip.row][@"text"];
    if (!t.length) return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        return [UIMenu menuWithChildren:@[[UIAction actionWithTitle:GXL(@"Копировать") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = t; }]]];
    }];
}
@end

#pragma mark - Выбор модели из списка

@interface GXAIModelListVC : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) void (^picked)(NSString *m);
- (instancetype)initWithModels:(NSArray<NSString *> *)m;
@end
@implementation GXAIModelListVC { NSArray *_all, *_shown; }
- (instancetype)initWithModels:(NSArray *)m { if ((self = [super initWithStyle:UITableViewStylePlain])) { _all = _shown = m; self.title = GXL(@"Модели"); } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self; sc.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = sc; self.navigationItem.hidesSearchBarWhenScrolling = NO;
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    _shown = q.length ? [_all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", q]] : _all;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_shown.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"m"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"m"];
    c.textLabel.text = _shown[ip.row]; c.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.picked) self.picked(_shown[ip.row]);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - Редактор подключения

@interface GXAIProviderEditVC : UITableViewController
- (instancetype)initWithProvider:(NSDictionary *)p isNew:(BOOL)isNew;
@end

@implementation GXAIProviderEditVC {
    NSMutableDictionary *_p; BOOL _new;
    UITextField *_name, *_base, *_key, *_model; UISegmentedControl *_kind;
}
- (instancetype)initWithProvider:(NSDictionary *)p isNew:(BOOL)isNew {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _p = [p mutableCopy]; _new = isNew;
        if (!_p[@"id"]) _p[@"id"] = NSUUID.UUID.UUIDString;
        self.title = isNew ? GXL(@"Новое подключение") : GXL(@"Подключение");
    }
    return self;
}
- (UITextField *)field:(NSString *)ph text:(NSString *)t {
    UITextField *f = [UITextField new];
    f.placeholder = ph; f.text = t; f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.autocorrectionType = UITextAutocorrectionTypeNo; f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL local = [_p[@"local"] boolValue];
    _name = [self field:GXL(@"Название") text:_p[@"name"]];
    _base = [self field:@"https://…/v1" text:_p[@"base"]]; _base.keyboardType = UIKeyboardTypeURL;
    _key = [self field:local ? GXL(@"Обычно не нужен") : @"sk-…" text:_new ? @"" : GXAIKey(_p[@"id"])]; _key.secureTextEntry = YES;
    _model = [self field:GXL(@"Название модели") text:_p[@"model"]];
    _kind = [[UISegmentedControl alloc] initWithItems:@[GXL(@"OpenAI-совместимый"), @"Anthropic"]];
    _kind.selectedSegmentIndex = [_p[@"kind"] isEqualToString:@"anthropic"] ? 1 : 0;
    _kind.translatesAutoresizingMaskIntoConstraints = NO;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];
}
- (NSDictionary *)current {
    return @{@"id": _p[@"id"], @"name": _name.text.length ? _name.text : @"AI", @"kind": _kind.selectedSegmentIndex == 1 ? @"anthropic" : @"openai",
             @"base": _base.text ?: @"", @"model": [_model.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"", @"local": _p[@"local"] ?: @NO};
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : s == 1 ? 2 : s == 2 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return @[GXL(@"Подключение"), GXL(@"Доступ"), GXL(@"Модель"), @""][s]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return [_p[@"local"] boolValue]
        ? GXL(@"Локальный ИИ: запусти Ollama или LM Studio на компьютере в той же Wi‑Fi сети и укажи IP компьютера. Ollama нужно разрешить подключения из сети (переменная OLLAMA_HOST=0.0.0.0), в LM Studio — включить «Serve on Local Network». При первом подключении iOS спросит доступ к локальной сети — разреши.")
        : GXL(@"Ключ хранится только в Связке ключей этого iPhone и отправляется только по адресу API выше.");
    if (s == 2) return GXL(@"Нажми «Выбрать из списка», чтобы загрузить доступные модели. Модель должна поддерживать вызов инструментов (tools / function calling).");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UIView *v = nil;
    if (ip.section == 0) v = ip.row == 0 ? _name : _kind;
    else if (ip.section == 1) v = ip.row == 0 ? _base : _key;
    else if (ip.section == 2) {
        if (ip.row == 0) v = _model;
        else {
            c.textLabel.text = GXL(@"Выбрать из списка…"); c.textLabel.textColor = c.tintColor;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
            c.imageView.image = [UIImage systemImageNamed:@"list.bullet"];
            return c;
        }
    } else {
        c.textLabel.text = GXL(@"Проверить подключение"); c.textLabel.textColor = c.tintColor;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.imageView.image = [UIImage systemImageNamed:@"bolt.horizontal.circle"];
        return c;
    }
    [c.contentView addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
        [v.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
        [c.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:46],
    ]];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self.view endEditing:YES];
    if (ip.section == 2 && ip.row == 1) {
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Загружаю список моделей…")];
        [GXAIClient models:[self current] key:_key.text done:^(NSArray<NSString *> *list, NSString *err) {
            [GXHUD hide];
            if (err) { GXAlert(self, GXL(@"Не удалось загрузить список"), [err stringByAppendingString:GXL(@"\n\nМожно вписать название модели вручную.")]); return; }
            if (!list.count) { GXAlert(self, GXL(@"Список пуст"), GXL(@"Сервис не вернул моделей. Впиши название вручную.")); return; }
            GXAIModelListVC *m = [[GXAIModelListVC alloc] initWithModels:list];
            __weak typeof(self) ws = self;
            m.picked = ^(NSString *x) { GXAIProviderEditVC *me = ws; me->_model.text = x; };
            [self.navigationController pushViewController:m animated:YES];
        }];
    } else if (ip.section == 3) [self test];
}
- (void)test {
    NSDictionary *p = [self current];
    if (![p[@"model"] length]) { GXAlert(self, GXL(@"Не указана модель"), GXL(@"Выбери модель из списка или впиши название.")); return; }
    NSMutableDictionary *tp = [p mutableCopy]; tp[@"key"] = self->_key.text ?: @"";
    [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Проверяю…")];
    [GXAIClient send:tp system:@"You are a test. Answer with one word." turns:@[@{@"role": @"user", @"text": @"Say OK"}] tools:GXAITools.specs done:^(NSDictionary *turn, NSString *err) {
        [GXHUD hide];
        if (err) { GXAlert(self, GXL(@"Не работает"), err); return; }
        GXAlert(self, GXL(@"Работает"), [NSString stringWithFormat:GXL(@"Модель ответила: %@"), [turn[@"text"] length] ? GXCut(turn[@"text"], 200) : GXL(@"(вызов инструмента)")]);
    }];
}
- (void)save {
    NSDictionary *p = [self current];
    if (![NSURL URLWithString:p[@"base"]].host.length) { GXAlert(self, GXL(@"Неверный адрес"), GXL(@"Укажи адрес API, например https://api.openai.com/v1")); return; }
    if (![p[@"model"] length]) { GXAlert(self, GXL(@"Не указана модель"), GXL(@"Выбери модель из списка или впиши название.")); return; }
    GXAISetKey(p[@"id"], _key.text);
    NSMutableArray *all = [GXAIProviders() mutableCopy];
    NSUInteger idx = [all indexOfObjectPassingTest:^BOOL(NSDictionary *x, NSUInteger i, BOOL *stop) { return [x[@"id"] isEqualToString:p[@"id"]]; }];
    if (idx == NSNotFound) [all addObject:p]; else all[idx] = p;
    GXAISaveProviders(all);
    if (_new || !GXAIActive()) [GXDefaults() setObject:p[@"id"] forKey:@"gxAIActive"];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - Настройки моделей

@implementation GXAISettingsVC
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = GXL(@"Модели ИИ"); return self; }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.tableView reloadData]; }
- (unsigned long long)backupSize {
    unsigned long long t = 0;
    NSDirectoryEnumerator *en = [FM() enumeratorAtPath:GXAIBackupRoot()];
    for (NSString *x in en) { (void)x; t += en.fileAttributes.fileSize; }
    return t;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? (NSInteger)GXAIProviders().count + 1 : 2; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 0 ? GXL(@"Подключения") : GXL(@"Безопасность"); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 0 ? GXL(@"Подходит любой сервис с API в формате OpenAI или Anthropic, а также локальные модели (Ollama, LM Studio) на компьютере в твоей сети. Отмеченное подключение используется в чатах.")
                  : GXL(@"Перед каждым изменением ИИ спрашивает разрешения. Изменённые и удалённые файлы сохраняются в резервные копии — их можно вернуть кнопкой «Отменить изменения чата».");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    NSArray *ps = GXAIProviders();
    if (ip.section == 0) {
        if (ip.row < (NSInteger)ps.count) {
            NSDictionary *p = ps[ip.row];
            c.textLabel.text = p[@"name"];
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", [p[@"model"] length] ? p[@"model"] : GXL(@"модель не выбрана"), [NSURL URLWithString:p[@"base"]].host ?: @""];
            c.imageView.image = [UIImage systemImageNamed:[p[@"local"] boolValue] ? @"desktopcomputer" : @"cloud"];
            c.accessoryType = [p[@"id"] isEqualToString:GXAIActive()[@"id"]] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        } else {
            c.textLabel.text = GXL(@"Добавить подключение…"); c.textLabel.textColor = c.tintColor;
            c.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        }
        return c;
    }
    if (ip.row == 0) {
        c.textLabel.text = GXL(@"Спрашивать перед изменениями");
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new]; sw.on = GXAIAskFirst();
        [sw addTarget:self action:@selector(toggleAsk:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
    } else {
        c.textLabel.text = GXL(@"Удалить резервные копии");
        c.detailTextLabel.text = GXHuman([self backupSize]);
        c.textLabel.textColor = UIColor.systemRedColor;
    }
    return c;
}
- (void)toggleAsk:(UISwitch *)sw { [GXDefaults() setBool:sw.on forKey:@"gxAIConfirm"]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *ps = GXAIProviders();
    if (ip.section == 0) {
        if (ip.row < (NSInteger)ps.count) { [GXDefaults() setObject:ps[ip.row][@"id"] forKey:@"gxAIActive"]; [tv reloadData]; return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Какой ИИ подключить?") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *pr in GXAIPresets())
            [a addAction:[UIAlertAction actionWithTitle:pr[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                [self.navigationController pushViewController:[[GXAIProviderEditVC alloc] initWithProvider:pr isNew:YES] animated:YES]; }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (ip.row == 1) GXConfirm(self, GXL(@"Удалить резервные копии?"), GXL(@"Отменить прошлые изменения ИИ будет уже нельзя."), GXL(@"Удалить"), YES, ^{
        [FM() removeItemAtPath:GXAIBackupRoot() error:nil]; [tv reloadData]; });
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    NSArray *ps = GXAIProviders();
    if (ip.section != 0 || ip.row >= (NSInteger)ps.count) return nil;
    NSDictionary *p = ps[ip.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        UIAction *del = [UIAction actionWithTitle:GXL(@"Удалить") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *x) { [self removeProvider:p]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:GXL(@"Изменить") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *x) {
                [self.navigationController pushViewController:[[GXAIProviderEditVC alloc] initWithProvider:p isNew:NO] animated:YES]; }], del]];
    }];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSArray *ps = GXAIProviders();
    if (ip.section != 0 || ip.row >= (NSInteger)ps.count) return nil;
    NSDictionary *p = ps[ip.row];
    UIContextualAction *ed = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:GXL(@"Изменить") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self.navigationController pushViewController:[[GXAIProviderEditVC alloc] initWithProvider:p isNew:NO] animated:YES]; done(YES); }];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:GXL(@"Удалить") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self removeProvider:p]; done(YES); }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, ed]];
}
- (void)removeProvider:(NSDictionary *)p {
    NSMutableArray *all = [GXAIProviders() mutableCopy];
    [all removeObjectsInArray:[all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", p[@"id"]]]];
    GXAISaveProviders(all);
    GXAISetKey(p[@"id"], nil);
    [self.tableView reloadData];
}
@end

#pragma mark - Выбор папки

@implementation GXAIStartVC {
    NSArray<NSDictionary *> *_rows;   // @{title, subtitle, path, icon, color}
}
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = GXL(@"ИИ-помощник"); return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(settings)];
}
- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *s in GXRootSections()) for (NSDictionary *r in s[@"rows"]) if ([r[@"path"] length] && GXIsDir(r[@"path"])) [rows addObject:r];
    _rows = rows;
    [self.tableView reloadData];
}
- (void)settings { [self.navigationController pushViewController:[GXAISettingsVC new] animated:YES]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 1 : s == 1 ? (NSInteger)_rows.count : 1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 1 ? GXL(@"С какой папкой работать") : nil; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return GXL(@"ИИ видит и меняет файлы только внутри выбранной папки. Любую папку можно открыть и из файлового менеджера: «…» → «ИИ-помощник для этой папки».");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (ip.section == 0) {
        NSDictionary *p = GXAIActive();
        c.textLabel.text = p ? p[@"name"] : GXL(@"Подключить модель ИИ…");
        c.detailTextLabel.text = p ? ([p[@"model"] length] ? p[@"model"] : GXL(@"модель не выбрана")) : GXL(@"OpenAI, Claude, Gemini, DeepSeek, Ollama и другие");
        c.imageView.image = GXSymbolTile(@"sparkles", UIColor.systemPurpleColor, 32);
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (ip.section == 1) {
        NSDictionary *r = _rows[ip.row];
        c.textLabel.text = r[@"title"];
        c.detailTextLabel.text = r[@"path"]; c.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingHead;
        c.imageView.image = GXSymbolTile(r[@"icon"] ?: @"folder.fill", r[@"color"] ?: UIColor.systemBlueColor, 32);
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    c.textLabel.text = GXL(@"Указать путь к папке…");
    c.imageView.image = GXSymbolTile(@"arrow.right.circle.fill", UIColor.systemGrayColor, 32);
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self settings]; return; }
    if (ip.section == 1) { [self.navigationController pushViewController:[[GXAIChatVC alloc] initWithRoot:_rows[ip.row][@"path"]] animated:YES]; return; }
    GXPrompt(self, GXL(@"Путь к папке"), nil, GXLCHome() ?: GXDocsDir(), @"/var/mobile/…", GXL(@"Открыть"), ^(NSString *v) {
        NSString *p = [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].stringByExpandingTildeInPath;
        if (!GXIsDir(p)) { GXAlert(self, GXL(@"Папка не найдена"), GXL(@"Нет такой папки или к ней нет доступа.")); return; }
        [self.navigationController pushViewController:[[GXAIChatVC alloc] initWithRoot:p] animated:YES];
    });
}
@end

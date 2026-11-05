// GX Files — делегат приложения
#import "GXCore.h"

#pragma mark - Клавиатура

// Во всём приложении: касание вне поля ввода или прокрутка прячут клавиатуру.
// Касания не перехватываются (кнопки, строки таблиц работают как обычно).
@interface GXKeyboardHider : NSObject <UIGestureRecognizerDelegate>
+ (void)installOn:(UIWindow *)w;
@end

// текущий первый ответчик (поле, в котором сейчас клавиатура)
static __weak UIResponder *gxFirstResponder;
@interface UIResponder (GXFirst)
- (void)gx_captureFirst:(id)sender;
@end
@implementation UIResponder (GXFirst)
- (void)gx_captureFirst:(id)sender { gxFirstResponder = self; }
@end

@implementation GXKeyboardHider {
    BOOL _shown;
    __weak UIResponder *_target;   // поле, которое редактировалось в момент касания
}
+ (instancetype)shared {
    static GXKeyboardHider *h; static dispatch_once_t once;
    dispatch_once(&once, ^{
        h = [GXKeyboardHider new];
        [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardWillShowNotification object:nil queue:nil usingBlock:^(NSNotification *n) { h->_shown = YES; }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidHideNotification object:nil queue:nil usingBlock:^(NSNotification *n) { h->_shown = NO; }];
    });
    return h;
}
+ (void)installOn:(UIWindow *)w {
    GXKeyboardHider *h = [self shared];
    for (UIGestureRecognizer *g in w.gestureRecognizers) if (g.delegate == h) return;   // уже стоит
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:h action:@selector(hide:)];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:h action:@selector(drag:)];
    for (UIGestureRecognizer *g in @[tap, pan]) {
        g.cancelsTouchesInView = NO; g.delaysTouchesBegan = NO; g.delaysTouchesEnded = NO;
        g.delegate = h;
        [w addGestureRecognizer:g];
    }
}
// касание по полю ввода, кнопке/переключателю или внутри алерта — не трогаем
- (BOOL)keep:(UIView *)v {
    for (UIView *x = v; x; x = x.superview) {
        if (x.isFirstResponder) return YES;
        if ([x isKindOfClass:UITextField.class] || [x isKindOfClass:UITextView.class] || [x isKindOfClass:UISearchBar.class]) {
            if (![x isKindOfClass:UITextView.class] || ((UITextView *)x).isEditable || ((UITextView *)x).isSelectable) return YES;
        }
        if ([x isKindOfClass:UIControl.class] || [x isKindOfClass:UINavigationBar.class] || [x isKindOfClass:UIToolbar.class]) return YES;
    }
    for (UIResponder *r = v; r; r = r.nextResponder) if ([r isKindOfClass:UIAlertController.class]) return YES;
    return NO;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if (!_shown || [self keep:t.view]) return NO;
    gxFirstResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(gx_captureFirst:) to:nil from:nil forEvent:nil];
    _target = gxFirstResponder;
    return _target != nil;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
- (void)resignTarget { UIResponder *r = _target; if (r.isFirstResponder) [r resignFirstResponder]; _target = nil; }
- (void)hide:(UITapGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateEnded) [self resignTarget]; }
- (void)drag:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:g.view];
    if (fabs(t.y) > 12 && fabs(t.y) > fabs(t.x) * 1.5) [self resignTarget];   // вертикальная прокрутка
}
@end

#pragma mark - Приложение

@interface GXAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation GXAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    // старые временные файлы
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{ [FM() removeItemAtPath:[caches stringByAppendingPathComponent:@"GXTemp"] error:nil]; });
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [GXPanelsVC new];
    self.window.tintColor = [UIColor colorWithRed:0.35 green:0.45 blue:1.0 alpha:1.0];
    [self.window makeKeyAndVisible];
    [GXKeyboardHider installOn:self.window];
    [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        UIWindow *w = n.object;
        if ([w isKindOfClass:UIWindow.class] && w.windowLevel == UIWindowLevelNormal) [GXKeyboardHider installOn:w];
    }];
    return YES;
}

// Файлы, открытые в GX Files из других приложений («Открыть в…»)
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    if (!url.isFileURL) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    // Файл из «Файлов» открыт на месте — работаем с оригиналом, без копии во «Входящие»
    if ([options[UIApplicationOpenURLOptionsOpenInPlaceKey] boolValue] && [FM() isReadableFileAtPath:url.path]) {
        static NSMutableArray<NSURL *> *keep;            // доступ к файлу держим до конца работы приложения
        if (!keep) keep = [NSMutableArray array];
        if (scoped) [keep addObject:url];
        UINavigationController *nav = [GXPanelsVC.shared currentNav];
        [nav popToRootViewControllerAnimated:NO];
        [GXOpener open:url.path from:nav.topViewController];
        return YES;
    }
    NSString *inbox = [GXDocsDir() stringByAppendingPathComponent:@"Входящие"]; // noi18n
    [FM() createDirectoryAtPath:inbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = GXUniquePath(inbox, url.lastPathComponent);
    [FM() copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    UINavigationController *nav = [GXPanelsVC.shared currentNav];
    [nav popToRootViewControllerAnimated:NO];
    [nav pushViewController:[[GXBrowserVC alloc] initWithPath:inbox] animated:NO];
    [GXOpener open:dest from:nav.topViewController];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(GXAppDelegate.class));
    }
}

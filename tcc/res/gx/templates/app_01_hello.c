// Приложение «Привет»: заголовок, счётчик и кнопка. Собирается в IPA: меню → «Собрать IPA…»
// Нужные библиотеки: Foundation и UIKit (меню «Библиотеки для линковки»).
#include <gxkit.h>

extern int UIApplicationMain(int argc, char *argv[], id principalClassName, id delegateClassName);

static id g_window, g_countLabel;
static int g_count = 0;

static id rgba(double r, double g, double b, double a) {
    return GX_MSG4(id, GX_CLS("UIColor"), "colorWithRed:green:blue:alpha:", CGFloat, r, CGFloat, g, CGFloat, b, CGFloat, a);
}
static id make_label(const char *text, double size, int bold) {
    id l = gx_alloc("UILabel");
    GX_MSG1(void, l, "setText:", id, gx_str(text));
    GX_MSG1(void, l, "setTextAlignment:", long, 1);                       // по центру
    GX_MSG1(void, l, "setTextColor:", id, rgba(1, 1, 1, 1));
    GX_MSG1(void, l, "setFont:", id, bold ? GX_MSG1(id, GX_CLS("UIFont"), "boldSystemFontOfSize:", CGFloat, size)
                                          : GX_MSG1(id, GX_CLS("UIFont"), "systemFontOfSize:", CGFloat, size));
    GX_MSG1(void, l, "setNumberOfLines:", long, 0);
    return l;
}

/* нажатие кнопки — метод экрана GXMainVC */
static void vc_tap(id self, SEL _c, id sender) {
    g_count++;
    char buf[64]; snprintf(buf, sizeof buf, "Нажатий: %d", g_count);
    GX_MSG1(void, g_countLabel, "setText:", id, gx_str(buf));
    id h = GX_MSG1(id, GX_MSG0(id, GX_CLS("UIImpactFeedbackGenerator"), "alloc"), "initWithStyle:", long, 1);
    GX_MSG0(void, h, "impactOccurred");
}

/* -viewDidLoad экрана: собираем интерфейс */
static void vc_viewDidLoad(id self, SEL _c) {
    struct objc_super sup = { self, objc_getClass("UIViewController") };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel_registerName("viewDidLoad"));

    id view = GX_MSG0(id, self, "view");
    GX_MSG1(void, view, "setBackgroundColor:", id, rgba(0.18, 0.12, 0.40, 1));
    CGRect b = GX_MSG0(CGRect, view, "bounds");
    double w = b.size.width, h = b.size.height;

    id title = make_label("Привет! 👋", 40, 1);
    GX_MSG1(void, title, "setFrame:", CGRect, CGRectMake(20, h * 0.22, w - 40, 60));
    GX_MSG1(void, view, "addSubview:", id, title);

    id sub = make_label("Это приложение написано на C\nи собрано прямо на iPhone в GX Files", 16, 0);
    GX_MSG1(void, sub, "setAlpha:", CGFloat, 0.75);
    GX_MSG1(void, sub, "setFrame:", CGRect, CGRectMake(20, h * 0.22 + 64, w - 40, 50));
    GX_MSG1(void, view, "addSubview:", id, sub);

    g_countLabel = make_label("Нажатий: 0", 22, 0);
    GX_MSG1(void, g_countLabel, "setFrame:", CGRect, CGRectMake(20, h * 0.5, w - 40, 30));
    GX_MSG1(void, view, "addSubview:", id, g_countLabel);

    id btn = GX_MSG1(id, GX_CLS("UIButton"), "buttonWithType:", long, 1);
    GX_MSG1(void, btn, "setFrame:", CGRect, CGRectMake(w / 2 - 110, h * 0.5 + 50, 220, 56));
    GX_MSG1(void, btn, "setBackgroundColor:", id, rgba(0.55, 0.40, 1.0, 1));
    GX_MSG2(void, btn, "setTitle:forState:", id, gx_str("Нажми меня"), unsigned long, 0);
    GX_MSG2(void, btn, "setTitleColor:forState:", id, rgba(1, 1, 1, 1), unsigned long, 0);
    GX_MSG1(void, GX_MSG0(id, btn, "titleLabel"), "setFont:", id, GX_MSG1(id, GX_CLS("UIFont"), "boldSystemFontOfSize:", CGFloat, 20));
    GX_MSG1(void, GX_MSG0(id, btn, "layer"), "setCornerRadius:", CGFloat, 16);
    GX_MSG3(void, btn, "addTarget:action:forControlEvents:", id, self, SEL, sel_registerName("tap:"), unsigned long, 64);
    GX_MSG1(void, view, "addSubview:", id, btn);
}

/* делегат приложения: создаём окно с нашим экраном */
static BOOL app_didFinish(id self, SEL _c, id app, id options) {
    CGRect b = GX_MSG0(CGRect, GX_MSG0(id, GX_CLS("UIScreen"), "mainScreen"), "bounds");
    g_window = GX_MSG1(id, GX_MSG0(id, GX_CLS("UIWindow"), "alloc"), "initWithFrame:", CGRect, b);
    GX_MSG1(void, g_window, "setRootViewController:", id, gx_alloc("GXMainVC"));
    GX_MSG0(void, g_window, "makeKeyAndVisible");
    return 1;
}
static id app_window(id self, SEL _c) { return g_window; }

int main(int argc, char *argv[]) {
    Class vc = objc_allocateClassPair(objc_getClass("UIViewController"), "GXMainVC", 0);
    class_addMethod(vc, sel_registerName("viewDidLoad"), (IMP)vc_viewDidLoad, "v@:");
    class_addMethod(vc, sel_registerName("tap:"), (IMP)vc_tap, "v@:@");
    objc_registerClassPair(vc);

    Class d = objc_allocateClassPair(objc_getClass("UIResponder"), "GXAppDelegate", 0);
    class_addMethod(d, sel_registerName("application:didFinishLaunchingWithOptions:"), (IMP)app_didFinish, "c@:@@");
    class_addMethod(d, sel_registerName("window"), (IMP)app_window, "@@:");
    Protocol *p = objc_getProtocol("UIApplicationDelegate");
    if (p) class_addProtocol(d, p);
    objc_registerClassPair(d);

    return UIApplicationMain(argc, argv, 0, gx_str("GXAppDelegate"));
}

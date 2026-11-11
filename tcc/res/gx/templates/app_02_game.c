// Мини-игра «Поймай кружок»: тапай по кружку, пока он не убежал. Собирается в IPA.
// Нужные библиотеки: Foundation и UIKit (меню «Библиотеки для линковки»).
#include <gxkit.h>

extern int UIApplicationMain(int argc, char *argv[], id principalClassName, id delegateClassName);

#define DOT 84.0

static id g_window, g_view, g_dot, g_scoreLabel, g_timer;
static int g_score = 0, g_miss = 0, g_hit = 0;

static id rgba(double r, double g, double b, double a) {
    return GX_MSG4(id, GX_CLS("UIColor"), "colorWithRed:green:blue:alpha:", CGFloat, r, CGFloat, g, CGFloat, b, CGFloat, a);
}
static void update_score(void) {
    char buf[96]; snprintf(buf, sizeof buf, "Очки: %d   Промахи: %d", g_score, g_miss);
    GX_MSG1(void, g_scoreLabel, "setText:", id, gx_str(buf));
}
/* переставить кружок в случайное место и перекрасить */
static void move_dot(void) {
    CGRect b = GX_MSG0(CGRect, g_view, "bounds");
    double x = 20 + arc4random_uniform((uint32_t)(b.size.width - DOT - 40));
    double y = 140 + arc4random_uniform((uint32_t)(b.size.height - DOT - 220));
    GX_MSG2(void, GX_CLS("UIView"), "beginAnimations:context:", id, 0, void *, 0);
    GX_MSG1(void, GX_CLS("UIView"), "setAnimationDuration:", double, 0.15);
    GX_MSG1(void, g_dot, "setFrame:", CGRect, CGRectMake(x, y, DOT, DOT));
    GX_MSG0(void, GX_CLS("UIView"), "commitAnimations");
    id col = GX_MSG4(id, GX_CLS("UIColor"), "colorWithHue:saturation:brightness:alpha:",
                     CGFloat, arc4random_uniform(1000) / 1000.0, CGFloat, 0.7, CGFloat, 1.0, CGFloat, 1.0);
    GX_MSG1(void, g_dot, "setBackgroundColor:", id, col);
}

/* попадание */
static void vc_hit(id self, SEL _c, id sender) {
    g_score++; g_hit = 1;
    update_score();
    move_dot();
    id h = GX_MSG1(id, GX_MSG0(id, GX_CLS("UIImpactFeedbackGenerator"), "alloc"), "initWithStyle:", long, 2);
    GX_MSG0(void, h, "impactOccurred");
}
/* таймер: если не поймал — промах, кружок убегает */
static void vc_tick(id self, SEL _c, id timer) {
    if (!g_hit) { g_miss++; update_score(); }
    g_hit = 0;
    move_dot();
}

static void vc_viewDidLoad(id self, SEL _c) {
    struct objc_super sup = { self, objc_getClass("UIViewController") };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel_registerName("viewDidLoad"));

    g_view = GX_MSG0(id, self, "view");
    GX_MSG1(void, g_view, "setBackgroundColor:", id, rgba(0.07, 0.08, 0.12, 1));
    CGRect b = GX_MSG0(CGRect, g_view, "bounds");

    id title = gx_alloc("UILabel");
    GX_MSG1(void, title, "setText:", id, gx_str("Поймай кружок"));
    GX_MSG1(void, title, "setTextColor:", id, rgba(1, 1, 1, 1));
    GX_MSG1(void, title, "setTextAlignment:", long, 1);
    GX_MSG1(void, title, "setFont:", id, GX_MSG1(id, GX_CLS("UIFont"), "boldSystemFontOfSize:", CGFloat, 28));
    GX_MSG1(void, title, "setFrame:", CGRect, CGRectMake(0, 60, b.size.width, 36));
    GX_MSG1(void, g_view, "addSubview:", id, title);

    g_scoreLabel = gx_alloc("UILabel");
    GX_MSG1(void, g_scoreLabel, "setTextColor:", id, rgba(1, 1, 1, 0.8));
    GX_MSG1(void, g_scoreLabel, "setTextAlignment:", long, 1);
    GX_MSG1(void, g_scoreLabel, "setFont:", id, GX_MSG2(id, GX_CLS("UIFont"), "monospacedDigitSystemFontOfSize:weight:", CGFloat, 18, CGFloat, 0));
    GX_MSG1(void, g_scoreLabel, "setFrame:", CGRect, CGRectMake(0, 100, b.size.width, 24));
    GX_MSG1(void, g_view, "addSubview:", id, g_scoreLabel);
    update_score();

    g_dot = GX_MSG1(id, GX_CLS("UIButton"), "buttonWithType:", long, 0);
    GX_MSG1(void, GX_MSG0(id, g_dot, "layer"), "setCornerRadius:", CGFloat, DOT / 2);
    GX_MSG3(void, g_dot, "addTarget:action:forControlEvents:", id, self, SEL, sel_registerName("hit:"), unsigned long, 1 /* TouchDown */);
    GX_MSG1(void, g_view, "addSubview:", id, g_dot);

    GX_MSG1(void, g_dot, "setFrame:", CGRect, CGRectMake(b.size.width / 2 - DOT / 2, b.size.height / 2 - DOT / 2, DOT, DOT));
    move_dot();
    g_timer = GX_MSG5(id, GX_CLS("NSTimer"), "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
                      double, 0.9, id, self, SEL, sel_registerName("tick:"), id, 0, BOOL, 1);
}

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
    class_addMethod(vc, sel_registerName("hit:"), (IMP)vc_hit, "v@:@");
    class_addMethod(vc, sel_registerName("tick:"), (IMP)vc_tick, "v@:@");
    objc_registerClassPair(vc);

    Class d = objc_allocateClassPair(objc_getClass("UIResponder"), "GXAppDelegate", 0);
    class_addMethod(d, sel_registerName("application:didFinishLaunchingWithOptions:"), (IMP)app_didFinish, "c@:@@");
    class_addMethod(d, sel_registerName("window"), (IMP)app_window, "@@:");
    Protocol *p = objc_getProtocol("UIApplicationDelegate");
    if (p) class_addProtocol(d, p);
    objc_registerClassPair(d);

    return UIApplicationMain(argc, argv, 0, gx_str("GXAppDelegate"));
}

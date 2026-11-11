// Приложение «Заметка»: большое поле текста, которое сохраняется само (NSUserDefaults). Собирается в IPA.
// Нужные библиотеки: Foundation и UIKit (меню «Библиотеки для линковки»).
#include <gxkit.h>

extern int UIApplicationMain(int argc, char *argv[], id principalClassName, id delegateClassName);

static id g_window, g_text, g_status;

static id rgba(double r, double g, double b, double a) {
    return GX_MSG4(id, GX_CLS("UIColor"), "colorWithRed:green:blue:alpha:", CGFloat, r, CGFloat, g, CGFloat, b, CGFloat, a);
}
static id defaults(void) { return GX_MSG0(id, GX_CLS("NSUserDefaults"), "standardUserDefaults"); }

/* UITextViewDelegate: текст изменился — сохраняем */
static void vc_textViewDidChange(id self, SEL _c, id tv) {
    id text = GX_MSG0(id, tv, "text");
    GX_MSG2(void, defaults(), "setObject:forKey:", id, text, id, gx_str("note"));
    long n = GX_MSG0(long, text, "length");
    char buf[64]; snprintf(buf, sizeof buf, "Сохранено · символов: %ld", n);
    GX_MSG1(void, g_status, "setText:", id, gx_str(buf));
}
/* кнопка «Готово» — убрать клавиатуру */
static void vc_done(id self, SEL _c, id sender) { GX_MSG0(BOOL, g_text, "resignFirstResponder"); }

static void vc_viewDidLoad(id self, SEL _c) {
    struct objc_super sup = { self, objc_getClass("UIViewController") };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel_registerName("viewDidLoad"));

    id view = GX_MSG0(id, self, "view");
    GX_MSG1(void, view, "setBackgroundColor:", id, rgba(0.98, 0.96, 0.88, 1));
    CGRect b = GX_MSG0(CGRect, view, "bounds");

    id title = gx_alloc("UILabel");
    GX_MSG1(void, title, "setText:", id, gx_str("📝 Заметка"));
    GX_MSG1(void, title, "setFont:", id, GX_MSG1(id, GX_CLS("UIFont"), "boldSystemFontOfSize:", CGFloat, 30));
    GX_MSG1(void, title, "setTextColor:", id, rgba(0.2, 0.15, 0.05, 1));
    GX_MSG1(void, title, "setFrame:", CGRect, CGRectMake(20, 56, b.size.width - 120, 40));
    GX_MSG1(void, view, "addSubview:", id, title);

    id done = GX_MSG1(id, GX_CLS("UIButton"), "buttonWithType:", long, 1);
    GX_MSG2(void, done, "setTitle:forState:", id, gx_str("Готово"), unsigned long, 0);
    GX_MSG1(void, done, "setFrame:", CGRect, CGRectMake(b.size.width - 100, 60, 80, 32));
    GX_MSG3(void, done, "addTarget:action:forControlEvents:", id, self, SEL, sel_registerName("done:"), unsigned long, 64);
    GX_MSG1(void, view, "addSubview:", id, done);

    g_status = gx_alloc("UILabel");
    GX_MSG1(void, g_status, "setFont:", id, GX_MSG1(id, GX_CLS("UIFont"), "systemFontOfSize:", CGFloat, 13));
    GX_MSG1(void, g_status, "setTextColor:", id, rgba(0.4, 0.35, 0.25, 1));
    GX_MSG1(void, g_status, "setText:", id, gx_str("Пиши — всё сохраняется само"));
    GX_MSG1(void, g_status, "setFrame:", CGRect, CGRectMake(20, 98, b.size.width - 40, 18));
    GX_MSG1(void, view, "addSubview:", id, g_status);

    g_text = gx_alloc("UITextView");
    GX_MSG1(void, g_text, "setFrame:", CGRect, CGRectMake(14, 124, b.size.width - 28, b.size.height * 0.5));
    GX_MSG1(void, g_text, "setFont:", id, GX_MSG1(id, GX_CLS("UIFont"), "systemFontOfSize:", CGFloat, 18));
    GX_MSG1(void, g_text, "setBackgroundColor:", id, rgba(1, 1, 1, 0.6));
    GX_MSG1(void, GX_MSG0(id, g_text, "layer"), "setCornerRadius:", CGFloat, 12);
    id saved = GX_MSG1(id, defaults(), "stringForKey:", id, gx_str("note"));
    GX_MSG1(void, g_text, "setText:", id, saved ? saved : gx_str(""));
    GX_MSG1(void, g_text, "setDelegate:", id, self);
    GX_MSG1(void, view, "addSubview:", id, g_text);
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
    class_addMethod(vc, sel_registerName("textViewDidChange:"), (IMP)vc_textViewDidChange, "v@:@");
    class_addMethod(vc, sel_registerName("done:"), (IMP)vc_done, "v@:@");
    Protocol *tp = objc_getProtocol("UITextViewDelegate");
    if (tp) class_addProtocol(vc, tp);
    objc_registerClassPair(vc);

    Class d = objc_allocateClassPair(objc_getClass("UIResponder"), "GXAppDelegate", 0);
    class_addMethod(d, sel_registerName("application:didFinishLaunchingWithOptions:"), (IMP)app_didFinish, "c@:@@");
    class_addMethod(d, sel_registerName("window"), (IMP)app_window, "@@:");
    Protocol *p = objc_getProtocol("UIApplicationDelegate");
    if (p) class_addProtocol(d, p);
    objc_registerClassPair(d);

    return UIApplicationMain(argc, argv, 0, gx_str("GXAppDelegate"));
}

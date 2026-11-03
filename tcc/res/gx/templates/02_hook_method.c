// Хук метода Objective-C: логируем каждый показанный экран
#include <gxkit.h>

static void (*orig_viewDidAppear)(id self, SEL _cmd, BOOL animated);

static void my_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    gx_log("экран: %s", gx_classname(self));
    orig_viewDidAppear(self, _cmd, animated);   // вызвать оригинал
}

__attribute__((constructor))
static void init(void) {
    gx_hook_method("UIViewController", "viewDidAppear:", 0,
                   (IMP)my_viewDidAppear, (IMP *)&orig_viewDidAppear);
}

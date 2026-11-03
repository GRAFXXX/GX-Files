// Подмена возвращаемого значения метода: например, BOOL-проверка всегда YES
#include <gxkit.h>

static BOOL always_yes(id self, SEL _cmd) { return 1; }

__attribute__((constructor))
static void init(void) {
    // замени класс и селектор на свои (их видно в «Классы Objective-C» редактора dylib)
    gx_hook_method("SomeClass", "isPremium", 0, (IMP)always_yes, 0);
}

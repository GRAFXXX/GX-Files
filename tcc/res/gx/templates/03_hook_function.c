// Хук C-функции через импорт (как fishhook): подменяем getenv и логируем запросы
#include <gxkit.h>

static char *(*orig_getenv)(const char *name);

static char *my_getenv(const char *name) {
    char *v = orig_getenv(name);
    gx_log("getenv(%s) = %s", name, v ? v : "(нет)");
    return v;
}

__attribute__((constructor))
static void init(void) {
    gx_rebind("getenv", (void *)my_getenv, (void **)&orig_getenv);
}

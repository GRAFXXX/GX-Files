// Простой dylib: выполняется при загрузке в приложение (конструктор)
#include <gxkit.h>

static void show(void *ctx) {
    gx_alert("GX Files", "Привет! dylib загружен и работает.");
}

__attribute__((constructor))
static void init(void) {
    gx_log("dylib загружен в процесс %d", getpid());
    gx_main_after(2.0, show, 0);   // показать алерт через 2 секунды, когда появится окно
}

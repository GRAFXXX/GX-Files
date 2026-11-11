// Встроенный интерпретатор Lua 5.4 (офлайн). Вывод print/io.write уходит в колбэк,
// io.read читает из переданного stdin, есть лимит времени и кнопка «стоп».
#pragma once
#include <stddef.h>

typedef void (*gx_lua_out_fn)(void *ctx, const char *s, size_t n, int is_err);

// Выполнить code. stdin_text — ввод программы (может быть NULL), timeout — секунд (0 — без лимита),
// cancel — указатель на флаг остановки (может быть NULL). Возвращает 0 при успехе;
// иначе 1 и текст ошибки в err (сообщение Lua с номером строки).
int gx_lua_run(const char *code, const char *chunkname, const char *stdin_text,
               gx_lua_out_fn out, void *ctx, double timeout, volatile int *cancel,
               char *err, size_t errlen);

const char *gx_lua_version(void);

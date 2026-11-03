// Лёгкий «декомпилятор»: ARM64 → приблизительный псевдокод на C/Objective-C для одной функции
#pragma once
#include "gx_bin.h"

typedef struct { const char *name; uint64_t slot; uint32_t off; } gx_pivar;
// Имя функции по адресу (с деманглингом) — даёт вызывающая сторона. NULL — нет имени
typedef const char *(*gx_namer)(void *ctx, uint64_t addr, char *buf, size_t n);

// fname — имя функции; objc — 1 для методов -[Class sel] (x0 = self, x1 = _cmd)
// proto — прототип для заголовка (может быть NULL); retkind: 0 неизвестно, 1 void, 2 float/double, 3 значение
// self_iv — ivars класса метода (для self->_ivar), all_iv — все ivar-слоты (OBJC_IVAR_$)
// Возвращает malloc-строку
char *gx_pseudo(const gx_bin *b, uint64_t start, uint64_t end, const char *fname, int objc, const char *proto, int retkind,
                const gx_pivar *self_iv, int nself, const gx_pivar *all_iv, int nall,
                gx_namer namer, void *ctx);

// Правка команд загрузки Mach-O в памяти (thin и fat): список, добавление и удаление LC_LOAD_DYLIB
#pragma once
#include <stdint.h>
#include <stddef.h>

// Список библиотек (через '\n', malloc) первого 64-битного среза
char *gx_macho_list_dylibs(const uint8_t *d, size_t len);
// Добавить LC_LOAD_DYLIB (weak — LC_LOAD_WEAK_DYLIB) во все срезы. 1 = ок
int gx_macho_add_dylib(uint8_t *d, size_t len, const char *path, int weak, char *err, size_t errlen);
// Удалить команды, ссылающиеся на path, во всех срезах. Возвращает число удалённых
int gx_macho_remove_dylib(uint8_t *d, size_t len, const char *path);
// Добавить LC_RPATH, если такого ещё нет. 1 = ок (или уже есть)
int gx_macho_add_rpath(uint8_t *d, size_t len, const char *rpath, char *err, size_t errlen);

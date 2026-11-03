// Поиск встроенных картинок (PNG, JPEG, GIF, WebP) в любом бинарном файле
#pragma once
#include <stdint.h>
#include <stddef.h>

enum { GX_IMG_PNG = 1, GX_IMG_JPEG = 2, GX_IMG_GIF = 3, GX_IMG_WEBP = 4 };
typedef struct { size_t off, len; int type; } gx_imghit;

// Найти все картинки целиком (с проверкой структуры). Возвращает количество, *out — malloc
size_t gx_find_images(const uint8_t *d, size_t len, size_t minlen, gx_imghit **out);
const char *gx_img_typename(int type);

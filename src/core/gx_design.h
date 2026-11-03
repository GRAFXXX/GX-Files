// «Дизайн» внутри бинарника: цвета RGBA (4 float, которые код грузит в векторный регистр) и встроенные шрифты TTF/OTF
#pragma once
#include "gx_bin.h"

typedef struct { uint64_t addr; size_t off; int refs; float rgba[4]; } gx_color;
// Цвета, на которые ссылается код (ldr qN литерал / ADRP+LDR qN). Отсортированы по адресу. malloc
size_t gx_find_colors(const gx_bin *b, gx_color **out);

typedef struct { size_t off, len; int otf; char name[96]; } gx_font;
// Встроенные шрифты TrueType/OpenType с проверкой таблиц. malloc
size_t gx_find_fonts(const uint8_t *d, size_t len, gx_font **out);

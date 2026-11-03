// Текстуры .btx (Spike Chunsoft / Danganronpa и др.): LZ-сжатие FC AA 55 A7 / GX3, внутри SHTX / SHTXFS / SHTXFf / DDS(DXT1/3/5, RGBA)
#pragma once
#include <stdint.h>
#include <stddef.h>

// Распаковка Spike LZ (если сжато). Возвращает 1 и malloc-буфер; 0 — если не сжато/ошибка (тогда out = NULL)
int gx_spike_decompress(const uint8_t *in, size_t len, uint8_t **out, size_t *outlen);
// Упаковка в контейнер FC AA 55 A7 (только литералы — читается любым распаковщиком). malloc
uint8_t *gx_spike_pack(const uint8_t *in, size_t len, size_t *outlen);

// Декодировать DDS в RGBA8. 1 = ок
int gx_dds_decode(const uint8_t *d, size_t len, int *w, int *h, uint8_t **rgba, char *fmt, size_t fmtlen);

typedef struct {
    int width, height;
    uint8_t *rgba;           // malloc, width*height*4
    char kind[96];           // описание: «SHTXFS 8-bit, LZ» и т.п.
    int compressed;          // был ли LZ
    int inner;               // 1 SHTX4, 2 SHTXFS, 3 SHTXFf, 4 DDS, 5 картинка (PNG/JPEG внутри), 0 неизвестно
    size_t inner_off;        // смещение внутренних данных (для PNG/JPEG)
    uint8_t *raw; size_t raw_len;   // распакованные данные (malloc)
} gx_btx;

// 1 = распознано и декодировано в rgba (для inner==5 rgba = NULL: картинку декодирует система по raw+inner_off)
int gx_btx_decode(const uint8_t *d, size_t len, gx_btx *out, char *err, size_t errlen);
void gx_btx_free(gx_btx *b);
// Пересобрать .btx того же типа из RGBA (SHTXFf — 32 бит; SHTXFS — по исходной палитре; DDS — несжатый RGBA). malloc
uint8_t *gx_btx_encode(const gx_btx *orig, const uint8_t *rgba, int w, int h, size_t *outlen, char *err, size_t errlen);

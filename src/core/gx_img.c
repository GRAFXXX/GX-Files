#include "gx_img.h"
#include <stdlib.h>
#include <string.h>

static uint32_t BE32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint32_t LE32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

const char *gx_img_typename(int t) { return t == GX_IMG_PNG ? "PNG" : t == GX_IMG_JPEG ? "JPEG" : t == GX_IMG_GIF ? "GIF" : t == GX_IMG_WEBP ? "WebP" : "?"; }

// PNG: подпись + цепочка чанков до IEND
static size_t png_len(const uint8_t *d, size_t n) {
    if (n < 8 + 25 || memcmp(d, "\x89PNG\r\n\x1a\n", 8)) return 0;
    size_t p = 8;
    int first = 1;
    while (p + 12 <= n) {
        uint32_t cl = BE32(d + p);
        const uint8_t *ty = d + p + 4;
        if (cl > 0x7FFFFFFF || (size_t)cl > n - p - 12) return 0;
        for (int i = 0; i < 4; i++) { uint8_t c = ty[i] | 0x20; if (c < 'a' || c > 'z') return 0; }
        if (first && memcmp(ty, "IHDR", 4)) return 0;
        first = 0;
        p += 12 + cl;
        if (!memcmp(ty, "IEND", 4)) return p;
    }
    return 0;
}

// JPEG: маркеры до SOS, затем энтропийные данные до EOI
static size_t jpeg_len(const uint8_t *d, size_t n) {
    if (n < 4 || d[0] != 0xFF || d[1] != 0xD8 || d[2] != 0xFF) return 0;
    size_t p = 2;
    int segs = 0, sof = 0;
    while (p + 4 <= n) {
        if (d[p] != 0xFF) return 0;
        uint8_t m = d[p + 1];
        if (m == 0xFF) { p++; continue; }                 // заполнитель
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { p += 2; continue; }
        if (m == 0xD9) return segs ? p + 2 : 0;
        size_t sl = (size_t)d[p + 2] << 8 | d[p + 3];
        if (sl < 2 || p + 2 + sl > n) return 0;
        if ((m >= 0xC0 && m <= 0xC3) || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF)) sof = 1;
        segs++;
        p += 2 + sl;
        if (m == 0xDA) {                                   // данные скана
            if (!sof) return 0;
            while (p + 1 < n) {
                if (d[p] == 0xFF) {
                    uint8_t x = d[p + 1];
                    if (x == 0x00 || (x >= 0xD0 && x <= 0xD7) || x == 0xFF) { p += (x == 0xFF) ? 1 : 2; continue; }
                    break;                                 // следующий маркер (EOI или ещё один скан)
                }
                p++;
            }
        }
    }
    return 0;
}

static int skip_subblocks(const uint8_t *d, size_t n, size_t *p) {
    while (*p < n) {
        uint8_t bl = d[(*p)++];
        if (!bl) return 1;
        if (*p + bl > n) return 0;
        *p += bl;
    }
    return 0;
}

// GIF: заголовок, палитра, блоки до 0x3B
static size_t gif_len(const uint8_t *d, size_t n) {
    if (n < 14 || (memcmp(d, "GIF87a", 6) && memcmp(d, "GIF89a", 6))) return 0;
    size_t p = 13;
    if (d[10] & 0x80) p += 3u * (1u << ((d[10] & 7) + 1));
    int frames = 0;
    while (p < n) {
        uint8_t b = d[p++];
        if (b == 0x3B) return frames ? p : 0;
        if (b == 0x21) { if (p >= n) return 0; p++; if (!skip_subblocks(d, n, &p)) return 0; }
        else if (b == 0x2C) {
            if (p + 9 > n) return 0;
            uint8_t fl = d[p + 8];
            p += 9;
            if (fl & 0x80) p += 3u * (1u << ((fl & 7) + 1));
            if (p >= n) return 0;
            p++;                                           // минимальный размер кода LZW
            if (!skip_subblocks(d, n, &p)) return 0;
            frames++;
        } else return 0;
    }
    return 0;
}

static size_t webp_len(const uint8_t *d, size_t n) {
    if (n < 20 || memcmp(d, "RIFF", 4) || memcmp(d + 8, "WEBP", 4)) return 0;
    uint32_t sz = LE32(d + 4);
    if (sz < 12 || (size_t)sz + 8 > n) return 0;
    if (memcmp(d + 12, "VP8 ", 4) && memcmp(d + 12, "VP8L", 4) && memcmp(d + 12, "VP8X", 4)) return 0;
    return (size_t)sz + 8 + (sz & 1);
}

size_t gx_find_images(const uint8_t *d, size_t len, size_t minlen, gx_imghit **out) {
    gx_imghit *a = NULL; size_t n = 0, cap = 0;
    for (size_t i = 0; i + 4 <= len; i++) {
        size_t l = 0; int t = 0;
        uint8_t c = d[i];
        if (c == 0x89 && d[i + 1] == 'P') { l = png_len(d + i, len - i); t = GX_IMG_PNG; }
        else if (c == 0xFF && d[i + 1] == 0xD8) { l = jpeg_len(d + i, len - i); t = GX_IMG_JPEG; }
        else if (c == 'G' && d[i + 1] == 'I') { l = gif_len(d + i, len - i); t = GX_IMG_GIF; }
        else if (c == 'R' && d[i + 1] == 'I') { l = webp_len(d + i, len - i); t = GX_IMG_WEBP; }
        if (!l || l < minlen) continue;
        if (n == cap) { cap = cap ? cap * 2 : 32; a = realloc(a, sizeof *a * cap); }
        a[n++] = (gx_imghit){i, l, t};
        i += l - 1;                                        // картинки не пересекаются
    }
    *out = a;
    return n;
}

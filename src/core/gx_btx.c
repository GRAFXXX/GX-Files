#include "gx_tr.h"
#include "gx_btx.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }

int gx_spike_decompress(const uint8_t *in, size_t len, uint8_t **out, size_t *outlen) {
    *out = NULL; *outlen = 0;
    size_t p = 0;
    if (len >= 4 && !memcmp(in, "GX3\0", 4)) p = 4;
    if (len < p + 12 || memcmp(in + p, "\xFC\xAA\x55\xA7", 4)) return 0;
    uint32_t usize = le32(in + p + 4), csize = le32(in + p + 8);
    if (usize == 0 || usize > (512u << 20)) return 0;
    size_t i = p + 12, end = csize >= 12 && p + csize <= len ? p + csize : len;
    uint8_t *o = malloc(usize);
    size_t op = 0, prev = 1;
    while (op < usize && i < end) {
        uint8_t f = in[i++];
        if (f & 0x80) {
            if (i >= end) break;
            size_t cnt = ((f >> 5) & 3) + 4, off = ((size_t)(f & 0x1F) << 8) | in[i++];
            prev = off;
            if (!off || off > op) goto bad;
            for (size_t k = 0; k < cnt && op < usize; k++, op++) o[op] = o[op - off];
        } else if ((f & 0x60) == 0x60) {
            size_t cnt = f & 0x1F;
            if (!prev || prev > op) goto bad;
            for (size_t k = 0; k < cnt && op < usize; k++, op++) o[op] = o[op - prev];
        } else if (f & 0x40) {
            size_t cnt;
            if (!(f & 0x10)) cnt = (f & 0x0F) + 4;
            else { if (i >= end) break; cnt = (((size_t)(f & 0x0F) << 8) | in[i++]) + 4; }
            if (i >= end) break;
            uint8_t b = in[i++];
            for (size_t k = 0; k < cnt && op < usize; k++) o[op++] = b;
        } else {
            size_t cnt;
            if (!(f & 0x20)) cnt = f & 0x1F;
            else { if (i >= end) break; cnt = ((size_t)(f & 0x1F) << 8) | in[i++]; }
            for (size_t k = 0; k < cnt && op < usize && i < end; k++) o[op++] = in[i++];
        }
    }
    if (op < usize) memset(o + op, 0, usize - op);
    *out = o; *outlen = usize;
    return 1;
bad:
    free(o);
    return 0;
}

uint8_t *gx_spike_pack(const uint8_t *in, size_t len, size_t *outlen) {
    size_t cap = 12 + len + len / 8191 * 2 + 4;
    uint8_t *o = malloc(cap);
    memcpy(o, "\xFC\xAA\x55\xA7", 4);
    put32(o + 4, (uint32_t)len);
    size_t p = 12, i = 0;
    while (i < len) {
        size_t n = len - i < 8191 ? len - i : 8191;
        if (n < 32) o[p++] = (uint8_t)n;
        else { o[p++] = (uint8_t)(0x20 | (n >> 8)); o[p++] = (uint8_t)(n & 0xFF); }
        memcpy(o + p, in + i, n);
        p += n; i += n;
    }
    put32(o + 8, (uint32_t)p);
    *outlen = p;
    return o;
}

#pragma mark - DXT

static void rgb565(uint16_t c, uint8_t *o) { o[0] = (uint8_t)(((c >> 11) & 31) * 255 / 31); o[1] = (uint8_t)(((c >> 5) & 63) * 255 / 63); o[2] = (uint8_t)((c & 31) * 255 / 31); }

static void bc1_block(const uint8_t *b, uint8_t pal[4][4], int dxt1) {
    uint16_t c0 = le16(b), c1 = le16(b + 2);
    rgb565(c0, pal[0]); rgb565(c1, pal[1]);
    pal[0][3] = pal[1][3] = 255;
    if (c0 > c1 || !dxt1) {
        for (int k = 0; k < 3; k++) { pal[2][k] = (uint8_t)((2 * pal[0][k] + pal[1][k]) / 3); pal[3][k] = (uint8_t)((pal[0][k] + 2 * pal[1][k]) / 3); }
        pal[2][3] = pal[3][3] = 255;
    } else {
        for (int k = 0; k < 3; k++) { pal[2][k] = (uint8_t)((pal[0][k] + pal[1][k]) / 2); pal[3][k] = 0; }
        pal[2][3] = 255; pal[3][3] = 0;
    }
}

static void decode_bc(const uint8_t *src, size_t len, int w, int h, int type, uint8_t *rgba) {
    int bw = (w + 3) / 4, bh = (h + 3) / 4, bs = type == 1 ? 8 : 16;
    for (int by = 0; by < bh; by++) for (int bx = 0; bx < bw; bx++) {
        size_t off = ((size_t)by * bw + bx) * bs;
        if (off + bs > len) return;
        const uint8_t *b = src + off;
        uint8_t alpha[16];
        for (int i = 0; i < 16; i++) alpha[i] = 255;
        const uint8_t *cb = b;
        if (type == 2) { for (int i = 0; i < 16; i++) { int nib = (b[i / 2] >> ((i & 1) * 4)) & 15; alpha[i] = (uint8_t)(nib * 17); } cb = b + 8; }
        if (type == 3) {
            uint8_t a[8]; a[0] = b[0]; a[1] = b[1];
            if (a[0] > a[1]) for (int i = 1; i < 7; i++) a[i + 1] = (uint8_t)(((7 - i) * a[0] + i * a[1]) / 7);
            else { for (int i = 1; i < 5; i++) a[i + 1] = (uint8_t)(((5 - i) * a[0] + i * a[1]) / 5); a[6] = 0; a[7] = 255; }
            uint64_t bits = 0;
            for (int i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
            for (int i = 0; i < 16; i++) alpha[i] = a[(bits >> (3 * i)) & 7];
            cb = b + 8;
        }
        uint8_t pal[4][4];
        bc1_block(cb, pal, type == 1);
        uint32_t idx = le32(cb + 4);
        for (int i = 0; i < 16; i++) {
            int x = bx * 4 + (i & 3), y = by * 4 + (i >> 2);
            if (x >= w || y >= h) continue;
            uint8_t *px = rgba + ((size_t)y * w + x) * 4;
            const uint8_t *c = pal[(idx >> (2 * i)) & 3];
            px[0] = c[0]; px[1] = c[1]; px[2] = c[2];
            px[3] = type == 1 ? c[3] : alpha[i];
        }
    }
}

static int shift_of(uint32_t m) { int s = 0; if (!m) return 0; while (!(m & 1)) { m >>= 1; s++; } return s; }
static uint8_t chan(uint32_t v, uint32_t m) { if (!m) return 255; uint32_t x = (v & m) >> shift_of(m), max = m >> shift_of(m); return (uint8_t)(x * 255 / (max ? max : 1)); }

int gx_dds_decode(const uint8_t *d, size_t len, int *w, int *h, uint8_t **rgba, char *fmt, size_t fmtlen) {
    if (len < 128 || memcmp(d, "DDS ", 4)) return 0;
    *h = (int)le32(d + 12); *w = (int)le32(d + 16);
    if (*w <= 0 || *h <= 0 || *w > 16384 || *h > 16384) return 0;
    uint32_t pfflags = le32(d + 80), four = le32(d + 84), bpp = le32(d + 88);
    size_t data = 128;
    *rgba = calloc((size_t)*w * *h, 4);
    if (pfflags & 4) {
        int t = !memcmp(d + 84, "DXT1", 4) ? 1 : !memcmp(d + 84, "DXT3", 4) || !memcmp(d + 84, "DXT2", 4) ? 2 : !memcmp(d + 84, "DXT5", 4) || !memcmp(d + 84, "DXT4", 4) ? 3 : 0;
        if (!t) { snprintf(fmt, fmtlen, GXT("DDS FourCC %.4s (не поддерживается)"), (const char *)(d + 84)); free(*rgba); *rgba = NULL; return 0; }
        decode_bc(d + data, len - data, *w, *h, t, *rgba);
        snprintf(fmt, fmtlen, "DDS %.4s", (const char *)(d + 84));
        (void)four;
        return 1;
    }
    if (bpp == 32 || bpp == 24 || bpp == 16) {
        uint32_t rm = le32(d + 92), gm = le32(d + 96), bm = le32(d + 100), am = (pfflags & 1) ? le32(d + 104) : 0;
        size_t B = bpp / 8;
        for (size_t i = 0; i < (size_t)*w * *h; i++) {
            if (data + (i + 1) * B > len) break;
            const uint8_t *p = d + data + i * B;
            uint32_t v = B == 4 ? le32(p) : B == 3 ? (uint32_t)p[0] | p[1] << 8 | p[2] << 16 : le16(p);
            uint8_t *o = *rgba + i * 4;
            o[0] = chan(v, rm); o[1] = chan(v, gm); o[2] = chan(v, bm); o[3] = am ? chan(v, am) : 255;
        }
        snprintf(fmt, fmtlen, GXT("DDS %u-бит несжатый"), bpp);
        return 1;
    }
    free(*rgba); *rgba = NULL;
    snprintf(fmt, fmtlen, GXT("DDS: неизвестный формат пикселей"));
    return 0;
}

#pragma mark - BTX

void gx_btx_free(gx_btx *b) { free(b->rgba); free(b->raw); memset(b, 0, sizeof *b); }

int gx_btx_decode(const uint8_t *d, size_t len, gx_btx *b, char *err, size_t errlen) {
    memset(b, 0, sizeof *b);
    uint8_t *raw = NULL; size_t rl = 0;
    if (gx_spike_decompress(d, len, &raw, &rl)) {
        b->compressed = 1;
        // бывает двойное сжатие
        uint8_t *r2; size_t l2;
        if (gx_spike_decompress(raw, rl, &r2, &l2)) { free(raw); raw = r2; rl = l2; }
    } else { raw = malloc(len ? len : 1); memcpy(raw, d, len); rl = len; }
    b->raw = raw; b->raw_len = rl;
    const char *lz = b->compressed ? ", LZ" : "";
    const uint8_t *p = raw;
    size_t n = rl;
    if (n >= 4 && !memcmp(p, "DDS1", 4)) { p += 4; n -= 4; }
    if (n >= 128 && !memcmp(p, "DDS ", 4)) {
        char f[64];
        if (gx_dds_decode(p, n, &b->width, &b->height, &b->rgba, f, sizeof f)) { b->inner = 4; snprintf(b->kind, sizeof b->kind, "%s%s", f, lz); return 1; }
        snprintf(err, errlen, "%s", f); return 0;
    }
    if (n >= 12 && !memcmp(p, "SHTXF", 5)) {
        int w = le16(p + 6), h = le16(p + 8);
        size_t px = (size_t)w * h;
        if (!w || !h || w > 16384 || h > 16384) { snprintf(err, errlen, GXT("SHTX: неверный размер")); return 0; }
        b->width = w; b->height = h;
        b->rgba = calloc(px, 4);
        if (p[5] == 'f') {   // 32 бит BGRA
            for (size_t i = 0; i < px && 12 + i * 4 + 4 <= n; i++) {
                const uint8_t *s = p + 12 + i * 4; uint8_t *o = b->rgba + i * 4;
                o[0] = s[2]; o[1] = s[1]; o[2] = s[0]; o[3] = s[3];
            }
            b->inner = 3; snprintf(b->kind, sizeof b->kind, GXT("SHTXFf 32-бит%s"), lz);
        } else {             // 8 бит с палитрой RGBA
            const uint8_t *pal = p + 12, *ix = p + 12 + 1024;
            for (size_t i = 0; i < px && 12 + 1024 + i < n; i++) memcpy(b->rgba + i * 4, pal + ix[i] * 4, 4);
            b->inner = 2; snprintf(b->kind, sizeof b->kind, GXT("SHTXFS 8-бит, палитра%s"), lz);
        }
        return 1;
    }
    if (n >= 0x50 && !memcmp(p, "SHTX", 4)) {
        int w = le16(p + 4), h = le16(p + 6);
        size_t px = (size_t)w * h;
        if (!w || !h || w > 16384 || h > 16384) { snprintf(err, errlen, GXT("SHTX: неверный размер")); return 0; }
        b->width = w; b->height = h;
        b->rgba = calloc(px, 4);
        const uint8_t *pal = p + 0x10, *ix = p + 0x50;
        size_t avail = n - 0x50;
        int byte_per_px = avail >= px;
        for (size_t i = 0; i < px; i++) {
            int v;
            if (byte_per_px) v = ix[i] & 15;
            else { if (i / 2 >= avail) break; v = (ix[i / 2] >> ((i & 1) * 4)) & 15; }
            memcpy(b->rgba + i * 4, pal + v * 4, 4);
        }
        b->inner = 1; snprintf(b->kind, sizeof b->kind, GXT("SHTX 4-бит, 16 цветов%s"), lz);
        return 1;
    }
    // встроенная обычная картинка
    for (size_t i = 0; i + 8 <= n; i++) {
        if (!memcmp(p + i, "\x89PNG\r\n\x1a\n", 8) || (p[i] == 0xFF && p[i + 1] == 0xD8 && p[i + 2] == 0xFF) || !memcmp(p + i, "\xABKTX", 4)) {
            b->inner = 5; b->inner_off = (size_t)(p + i - raw);
            snprintf(b->kind, sizeof b->kind, GXT("картинка внутри (смещение %zu)%s"), b->inner_off, lz);
            return 1;
        }
        if (i > 4096) break;
    }
    if (n >= 4 && !memcmp(p, "GXT\0", 4)) snprintf(err, errlen, GXT("внутри GXT (текстура PS Vita, swizzle) — пока не поддерживается"));
    else snprintf(err, errlen, GXT("неизвестное содержимое (первые байты %02X %02X %02X %02X)%s"), n > 0 ? p[0] : 0, n > 1 ? p[1] : 0, n > 2 ? p[2] : 0, n > 3 ? p[3] : 0, b->compressed ? GXT(" после распаковки") : "");
    return 0;
}

uint8_t *gx_btx_encode(const gx_btx *o, const uint8_t *rgba, int w, int h, size_t *outlen, char *err, size_t errlen) {
    size_t px = (size_t)w * h, n = 0;
    uint8_t *buf = NULL;
    if (o->inner == 3 || o->inner == 1) {
        n = 12 + px * 4;
        buf = calloc(n, 1);
        memcpy(buf, "SHTXFf", 6);
        put16(buf + 6, (uint16_t)w); put16(buf + 8, (uint16_t)h);
        // байты 10-11 из оригинала, если был SHTXF
        if (o->inner == 3 && o->raw_len >= 12) { buf[10] = o->raw[10]; buf[11] = o->raw[11]; }
        for (size_t i = 0; i < px; i++) { const uint8_t *s = rgba + i * 4; uint8_t *d = buf + 12 + i * 4; d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = s[3]; }
    } else if (o->inner == 2) {
        n = 12 + 1024 + px;
        buf = calloc(n, 1);
        memcpy(buf, o->raw, 12 + 1024);
        put16(buf + 6, (uint16_t)w); put16(buf + 8, (uint16_t)h);
        const uint8_t *pal = o->raw + 12;
        for (size_t i = 0; i < px; i++) {
            const uint8_t *s = rgba + i * 4;
            int best = 0; long bd = 0x7fffffff;
            for (int k = 0; k < 256; k++) {
                const uint8_t *c = pal + k * 4;
                long d = (long)(c[0] - s[0]) * (c[0] - s[0]) + (long)(c[1] - s[1]) * (c[1] - s[1]) + (long)(c[2] - s[2]) * (c[2] - s[2]) + (long)(c[3] - s[3]) * (c[3] - s[3]);
                if (d < bd) { bd = d; best = k; if (!d) break; }
            }
            buf[12 + 1024 + i] = (uint8_t)best;
        }
    } else if (o->inner == 4) {
        int dds1 = o->raw_len >= 4 && !memcmp(o->raw, "DDS1", 4);
        n = (dds1 ? 4 : 0) + 128 + px * 4;
        buf = calloc(n, 1);
        uint8_t *d = buf;
        if (dds1) { memcpy(d, "DDS1", 4); d += 4; }
        memcpy(d, "DDS ", 4);
        put32(d + 4, 124); put32(d + 8, 0x1 | 0x2 | 0x4 | 0x1000 | 0x8); put32(d + 12, (uint32_t)h); put32(d + 16, (uint32_t)w);
        put32(d + 20, (uint32_t)w * 4); put32(d + 76, 32); put32(d + 80, 0x41); put32(d + 88, 32);
        put32(d + 92, 0x00FF0000); put32(d + 96, 0x0000FF00); put32(d + 100, 0x000000FF); put32(d + 104, 0xFF000000); put32(d + 108, 0x1000);
        for (size_t i = 0; i < px; i++) { const uint8_t *s = rgba + i * 4; uint8_t *q = d + 128 + i * 4; q[0] = s[2]; q[1] = s[1]; q[2] = s[0]; q[3] = s[3]; }
    } else { snprintf(err, errlen, GXT("этот тип .btx пока нельзя пересобрать")); return NULL; }
    if (!o->compressed) { *outlen = n; return buf; }
    uint8_t *packed = gx_spike_pack(buf, n, outlen);
    free(buf);
    return packed;
}

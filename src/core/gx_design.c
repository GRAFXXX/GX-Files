#include "gx_design.h"
#include "gx_a64.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static uint32_t L32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t B32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t B16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

static int cmp_u64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

static int is_color(const uint8_t *p) {
    float f[4]; memcpy(f, p, 16);
    int nonzero = 0;
    for (int i = 0; i < 4; i++) {
        if (!isfinite(f[i]) || f[i] < 0.0f || f[i] > 1.0f) return 0;
        if (f[i] != 0.0f) nonzero++;
        // «круглые» числа вроде 1e-30 — не цвет
        if (f[i] != 0.0f && f[i] < 0.001f) return 0;
    }
    return nonzero > 0;
}

size_t gx_find_colors(const gx_bin *b, gx_color **out) {
    *out = NULL;
    if (!b->arm64) return 0;
    uint64_t *t = NULL; size_t nt = 0, cap = 0;
    for (int si = 0; si < b->ns; si++) {
        const gx_sect *s = &b->s[si];
        if (!s->exec || s->kind == GX_SK_ZERO || s->off + s->size > b->len) continue;
        uint64_t val[32]; int64_t age[32];
        for (int r = 0; r < 32; r++) age[r] = -1000;
        for (uint64_t o = 0; o + 4 <= s->size; o += 4) {
            uint32_t ins = L32(b->d + s->off + o);
            uint64_t pc = s->addr + o, a = 0;
            int64_t ix = (int64_t)(o / 4);
            int rd, rn; uint64_t imm;
            if (gx_a64_is_adrp(ins, pc, &rd, &a)) { val[rd] = a; age[rd] = ix; continue; }
            if (gx_a64_is_addimm(ins, &rd, &rn, &imm)) {
                if (rn != 31 && ix - age[rn] < 48) { val[rd] = val[rn] + imm; age[rd] = ix; }
                else if (rd != 31) age[rd] = -1000;
                continue;
            }
            a = 0;
            if ((ins & 0xFF000000u) == 0x9C000000u) {                        // ldr qN, литерал
                int64_t d = (int64_t)((ins >> 5) & 0x7FFFF);
                if (d & 0x40000) d -= 0x80000;
                a = pc + (uint64_t)(d * 4);
            } else if ((ins & 0xFFC00000u) == 0x3DC00000u) {                 // ldr qN, [xM, #imm]
                rn = (ins >> 5) & 31;
                if (rn != 31 && ix - age[rn] < 48) a = val[rn] + ((uint64_t)((ins >> 10) & 0xFFF) << 4);
            } else if ((ins & 0x7FC00000u) == 0x2D400000u || (ins & 0x7FC00000u) == 0x6D400000u) {
                // ldp sN/dN — пара float (часто две половины цвета) — пропускаем
            }
            if (a) {
                if (nt == cap) { cap = cap ? cap * 2 : 256; t = realloc(t, cap * 8); }
                t[nt++] = a;
            } else if ((ins & 0x1F000000u) != 0x10000000u) {
                // запись в регистр-приёмник сбрасывает отслеживание (приблизительно)
                if (!((ins & 0x3A000000u) == 0x38000000u && !((ins >> 22) & 3))) age[ins & 31] = -1000;
            }
        }
    }
    // таблицы цветов в данных (static ImVec4 colors[] = {...}): ≥3 подряд идущих RGBA, refs = 0
    for (int si = 0; si < b->ns; si++) {
        const gx_sect *s = &b->s[si];
        if (s->exec || s->kind == GX_SK_ZERO || s->off + s->size > b->len || s->size < 48) continue;
        if (strstr(s->name, "cstring") || strstr(s->name, "objc") || strstr(s->name, "LINKEDIT")) continue;
        for (uint64_t o = 0; o + 48 <= s->size; o += 4) {
            size_t k = 0;
            while (o + (k + 1) * 16 <= s->size && is_color(b->d + s->off + o + k * 16)) k++;
            if (k < 3) continue;
            for (size_t q = 0; q < k; q++) {
                if (nt == cap) { cap = cap ? cap * 2 : 256; t = realloc(t, cap * 8); }
                t[nt++] = (s->addr + o + q * 16) | (1ull << 63);   // метка «из таблицы»
            }
            o += k * 16 - 4;
        }
    }
    if (!nt) { free(t); return 0; }
    for (size_t i = 0; i < nt; i++) t[i] = (t[i] << 1) | (t[i] >> 63);    // сортируем по адресу, метка — младший бит
    qsort(t, nt, 8, cmp_u64);
    gx_color *c = NULL; size_t nc = 0, ccap = 0;
    for (size_t i = 0; i < nt; ) {
        uint64_t addr = t[i] >> 1;
        size_t j = i; int refs = 0;
        while (j < nt && (t[j] >> 1) == addr) { if (!(t[j] & 1)) refs++; j++; }
        int64_t off = gx_bin_a2o(b, addr);
        if (off >= 0 && (size_t)off + 16 <= b->len && is_color(b->d + off)) {
            if (nc == ccap) { ccap = ccap ? ccap * 2 : 64; c = realloc(c, sizeof *c * ccap); }
            gx_color *x = &c[nc++];
            x->addr = addr; x->off = (size_t)off; x->refs = refs;
            memcpy(x->rgba, b->d + off, 16);
        }
        i = j;
    }
    free(t);
    *out = c;
    return nc;
}

// имя шрифта из таблицы 'name' (nameID 4 — полное, иначе 1 — семейство)
static void font_name(const uint8_t *f, size_t len, size_t noff, size_t nlen, char *out, size_t on) {
    out[0] = 0;
    if (noff + 6 > len || noff + nlen > len) return;
    const uint8_t *t = f + noff;
    uint16_t count = B16(t + 2), so = B16(t + 4);
    int best = -1, bestpri = 99;
    for (int i = 0; i < count && 6 + (size_t)(i + 1) * 12 <= nlen; i++) {
        const uint8_t *r = t + 6 + i * 12;
        uint16_t pid = B16(r), nid = B16(r + 6);
        int pri = (nid == 4 ? 0 : nid == 1 ? 2 : 50) + (pid == 3 ? 0 : pid == 1 ? 1 : 5);
        if ((nid == 4 || nid == 1) && pri < bestpri) { bestpri = pri; best = i; }
    }
    if (best < 0) return;
    const uint8_t *r = t + 6 + best * 12;
    uint16_t pid = B16(r), l = B16(r + 8), o = B16(r + 10);
    if ((size_t)so + o + l > nlen) return;
    const uint8_t *s = t + so + o;
    size_t k = 0;
    if (pid == 3 || pid == 0) { for (size_t i = 0; i + 1 < l && k + 1 < on; i += 2) { uint16_t ch = B16(s + i); out[k++] = ch < 128 && ch >= 32 ? (char)ch : '?'; } }
    else for (size_t i = 0; i < l && k + 1 < on; i++) out[k++] = s[i] >= 32 && s[i] < 127 ? (char)s[i] : '?';
    out[k] = 0;
}

static size_t font_len(const uint8_t *f, size_t n, int *otf, char *name, size_t nn) {
    if (n < 12) return 0;
    uint32_t tag = B32(f);
    if (tag != 0x00010000u && tag != 0x4F54544Fu /* OTTO */ && tag != 0x74727565u /* true */) return 0;
    uint16_t nt = B16(f + 4);
    if (nt < 4 || nt > 64 || 12 + (size_t)nt * 16 > n) return 0;
    // searchRange = 16 * (наибольшая степень 2 ≤ nt)
    uint16_t sr = B16(f + 6), p2 = 1; while ((p2 << 1) <= nt) p2 <<= 1;
    if (sr != p2 * 16) return 0;
    size_t end = 12 + (size_t)nt * 16;
    int has_head = 0, has_cmap = 0, glyf = 0, cff = 0;
    size_t noff = 0, nlen = 0;
    uint32_t prev = 0;
    for (int i = 0; i < nt; i++) {
        const uint8_t *r = f + 12 + i * 16;
        uint32_t tg = B32(r), off = B32(r + 8), len = B32(r + 12);
        for (int k = 0; k < 4; k++) { uint8_t c = r[k]; if (c < 32 || c > 126) return 0; }
        if (i && tg <= prev) return 0;                      // теги отсортированы
        prev = tg;
        if ((size_t)off > n || (size_t)len > n - off) return 0;
        if (off + (size_t)len > end) end = off + (size_t)len;
        if (tg == 0x68656164) has_head = 1;                 // head
        if (tg == 0x636D6170) has_cmap = 1;                 // cmap
        if (tg == 0x676C7966) glyf = 1;                     // glyf
        if (tg == 0x43464620) cff = 1;                      // CFF
        if (tg == 0x6E616D65) { noff = off; nlen = len; }   // name
    }
    if (!has_head || !has_cmap || !(glyf || cff)) return 0;
    *otf = cff;
    if (noff) font_name(f, n, noff, nlen, name, nn);
    return (end + 3) & ~(size_t)3;
}

size_t gx_find_fonts(const uint8_t *d, size_t len, gx_font **out) {
    gx_font *a = NULL; size_t n = 0, cap = 0;
    for (size_t i = 0; i + 12 <= len; i += 4) {             // шрифты выровнены минимум на 4
        uint8_t c = d[i];
        if (c != 0x00 && c != 'O' && c != 't') continue;
        int otf = 0; char nm[96] = {0};
        size_t l = font_len(d + i, len - i, &otf, nm, sizeof nm);
        if (!l || l < 1024) continue;
        if (l > len - i) l = len - i;
        if (n == cap) { cap = cap ? cap * 2 : 8; a = realloc(a, sizeof *a * cap); }
        a[n].off = i; a[n].len = l; a[n].otf = otf;
        snprintf(a[n].name, sizeof a[n].name, "%s", nm[0] ? nm : (otf ? "OpenType" : "TrueType"));
        n++;
        i += (l & ~(size_t)3) - 4;
    }
    *out = a;
    return n;
}

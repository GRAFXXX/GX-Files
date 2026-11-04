#include "gx_emu.h"
#include "gx_a64.h"
#include "gx_tr.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 4096u
#define HANDLE_BASE 0xFEED000000000000ull
#define HANDLE_STEP 0x10000ull                     // окно 64 КБ на импортированный символ (данные — нули)

// ---------- память: таблица страниц (открытая адресация) ----------
typedef struct { uint64_t key; uint8_t *data; } pslot;
typedef struct { pslot *t; size_t cap, n; } ptab;

static uint8_t *pt_get(ptab *p, uint64_t pg) {
    if (!p->cap) return NULL;
    size_t i = (size_t)((pg * 0x9E3779B97F4A7C15ull) >> 20) & (p->cap - 1);
    while (p->t[i].data) { if (p->t[i].key == pg) return p->t[i].data; i = (i + 1) & (p->cap - 1); }
    return NULL;
}
static void pt_put(ptab *p, uint64_t pg, uint8_t *d) {
    if ((p->n + 1) * 2 > p->cap) {
        size_t nc = p->cap ? p->cap * 2 : 64; pslot *nt = calloc(nc, sizeof *nt);
        for (size_t k = 0; k < p->cap; k++) if (p->t[k].data) {
            size_t i = (size_t)((p->t[k].key * 0x9E3779B97F4A7C15ull) >> 20) & (nc - 1);
            while (nt[i].data) i = (i + 1) & (nc - 1);
            nt[i] = p->t[k];
        }
        free(p->t); p->t = nt; p->cap = nc;
    }
    size_t i = (size_t)((pg * 0x9E3779B97F4A7C15ull) >> 20) & (p->cap - 1);
    while (p->t[i].data) i = (i + 1) & (p->cap - 1);
    p->t[i].key = pg; p->t[i].data = d; p->n++;
}

// байт по адресу: слой записи → файл → заполняемая нулями часть сегмента → стек
static int mapped(const gx_emu *e, uint64_t a) {
    if (a >= GX_EMU_STACK_TOP - GX_EMU_STACK_SIZE && a < GX_EMU_STACK_TOP) return 1;
    if (a >= HANDLE_BASE && a < HANDLE_BASE + (uint64_t)e->nhandles * HANDLE_STEP) return 1;
    const gx_bin *b = e->b;
    for (int i = 0; i < b->nseg; i++) if (a >= b->seg[i].vm && a < b->seg[i].vm + b->seg[i].vmsize) return 1;
    return 0;
}
static int rd_byte(gx_emu *e, uint64_t a, uint8_t *out) {
    uint8_t *pg = pt_get(e->pages, a / PAGE);
    if (pg) { *out = pg[a % PAGE]; return 1; }
    if (!mapped(e, a)) return 0;
    int64_t o = gx_bin_a2o(e->b, a);
    *out = o >= 0 ? e->b->d[o] : 0;
    return 1;
}
int gx_emu_read(gx_emu *e, uint64_t a, void *out, size_t n) {
    for (size_t i = 0; i < n; i++) if (!rd_byte(e, a + i, (uint8_t *)out + i)) return 0;
    return 1;
}
int gx_emu_write(gx_emu *e, uint64_t a, const void *in, size_t n) {
    for (size_t i = 0; i < n; i++) {
        uint64_t x = a + i, pgno = x / PAGE;
        uint8_t *pg = pt_get(e->pages, pgno);
        if (!pg) {
            if (!mapped(e, x)) return 0;
            pg = malloc(PAGE);
            for (uint32_t k = 0; k < PAGE; k++) { uint8_t v = 0; uint64_t ad = pgno * PAGE + k; if (mapped(e, ad)) { int64_t o = gx_bin_a2o(e->b, ad); v = o >= 0 ? e->b->d[o] : 0; } pg[k] = v; }
            pt_put(e->pages, pgno, pg);
        }
        pg[x % PAGE] = ((const uint8_t *)in)[i];
    }
    return 1;
}

static void logmem(gx_emu *e, uint64_t a, uint64_t v, int size, int w) {
    if (e->nmem < 8) e->mem[e->nmem++] = (gx_emu_mem){a, v, (uint8_t)size, (uint8_t)w};
}

static int fault(gx_emu *e, uint64_t a, int w) {
    snprintf(e->reason, sizeof e->reason, GXT("%s по недоступному адресу 0x%llx"), w ? GXT("Запись") : GXT("Чтение"), (unsigned long long)a);
    return GX_EMU_STOPPED;
}

// 8-байтовые указатели в данных могут быть закодированы (chained fixups) — расшифровываем
static int load64(gx_emu *e, uint64_t a, uint64_t *v) {
    if (!pt_get(e->pages, a / PAGE) && !pt_get(e->pages, (a + 7) / PAGE)) {
        uint64_t t = 0; const char *nm = NULL; uint32_t nl = 0;
        int k = gx_bin_ptr_at(e->b, a, &t, &nm, &nl);
        if (k == 1) { *v = t; return 1; }
        if (k == 2 && nm) {
            for (int i = 0; i < e->nhandles; i++) if (e->handles[i] == nm) { *v = HANDLE_BASE + (uint64_t)i * HANDLE_STEP; return 1; }
            if (e->nhandles < 256) { e->handles[e->nhandles] = nm; *v = HANDLE_BASE + (uint64_t)e->nhandles++ * HANDLE_STEP; return 1; }
        }
    }
    return gx_emu_read(e, a, v, 8);
}

static int ld(gx_emu *e, uint64_t a, int size, uint64_t *v) {
    *v = 0;
    int ok = size == 8 ? load64(e, a, v) : gx_emu_read(e, a, v, (size_t)size);
    if (ok) logmem(e, a, *v, size, 0);
    return ok;
}
static int st(gx_emu *e, uint64_t a, int size, uint64_t v) {
    if (!gx_emu_write(e, a, &v, (size_t)size)) return 0;
    logmem(e, a, v, size, 1);
    return 1;
}

// ---------- создание ----------
gx_emu *gx_emu_new(const gx_bin *b, uint64_t entry) {
    gx_emu *e = calloc(1, sizeof *e);
    e->b = b; e->pages = calloc(1, sizeof(ptab));
    e->pc = entry;
    e->x[31] = GX_EMU_STACK_TOP - 256;
    e->x[30] = GX_EMU_RET_MAGIC;
    e->x[29] = 0;
    return e;
}
void gx_emu_free(gx_emu *e) {
    if (!e) return;
    ptab *p = e->pages;
    for (size_t i = 0; i < p->cap; i++) free(p->t[i].data);
    free(p->t); free(p); free(e);
}

// ---------- помощники ----------
static uint64_t X(gx_emu *e, int r, int sf) { uint64_t v = r == 31 ? 0 : e->x[r]; return sf ? v : (uint32_t)v; }
static uint64_t XS(gx_emu *e, int r, int sf) { uint64_t v = e->x[r]; return sf ? v : (uint32_t)v; }     // r==31 → SP
static void W(gx_emu *e, int r, uint64_t v, int sf) { if (r != 31) e->x[r] = sf ? v : (uint32_t)v; }
static void WS(gx_emu *e, int r, uint64_t v, int sf) { e->x[r] = sf ? v : (uint32_t)v; }               // r==31 → SP

static uint64_t sx(uint64_t v, int bits) { return bits >= 64 ? v : (uint64_t)((int64_t)(v << (64 - bits)) >> (64 - bits)); }

static int cond(uint32_t f, int c) {
    int n = !!(f & 8), z = !!(f & 4), cy = !!(f & 2), v = !!(f & 1), r;
    switch (c >> 1) {
        case 0: r = z; break; case 1: r = cy; break; case 2: r = n; break; case 3: r = v; break;
        case 4: r = cy && !z; break; case 5: r = n == v; break; case 6: r = n == v && !z; break; default: r = 1;
    }
    if ((c & 1) && c != 15) r = !r;
    return r;
}

static uint64_t addc(uint64_t a, uint64_t b, int carry, int sf, uint32_t *flags) {
    uint64_t r;
    if (sf) {
        r = a + b + (uint64_t)carry;
        if (flags) {
            unsigned __int128 u = (unsigned __int128)a + b + (unsigned)carry;
            __int128 s = (__int128)(int64_t)a + (int64_t)b + carry;
            *flags = ((r >> 63) ? 8 : 0) | (r == 0 ? 4 : 0) | ((u >> 64) ? 2 : 0) | (s != (int64_t)r ? 1 : 0);
        }
    } else {
        uint32_t a32 = (uint32_t)a, b32 = (uint32_t)b;
        uint32_t r32 = a32 + b32 + (uint32_t)carry; r = r32;
        if (flags) {
            uint64_t u = (uint64_t)a32 + b32 + (unsigned)carry;
            int64_t s = (int64_t)(int32_t)a32 + (int32_t)b32 + carry;
            *flags = ((r32 >> 31) ? 8 : 0) | (r32 == 0 ? 4 : 0) | ((u >> 32) ? 2 : 0) | (s != (int32_t)r32 ? 1 : 0);
        }
    }
    return r;
}

static uint64_t shiftv(uint64_t v, int type, int amt, int sf) {
    int w = sf ? 64 : 32; amt %= w;
    uint64_t m = sf ? ~0ull : 0xFFFFFFFFull; v &= m;
    if (!amt) return v;
    switch (type) {
        case 0: return (v << amt) & m;
        case 1: return v >> amt;
        case 2: return (uint64_t)(sf ? (int64_t)v >> amt : (uint32_t)((int32_t)v >> amt));
        default: return ((v >> amt) | (v << (w - amt))) & m;
    }
}

static uint64_t extendv(uint64_t v, int opt, int sh) {
    switch (opt) {
        case 0: v = (uint8_t)v; break; case 1: v = (uint16_t)v; break; case 2: v = (uint32_t)v; break; case 3: break;
        case 4: v = sx(v, 8); break; case 5: v = sx(v, 16); break; case 6: v = sx(v, 32); break; default: break;
    }
    return v << sh;
}

static uint64_t ror64(uint64_t v, int r, int w) { uint64_t m = w == 64 ? ~0ull : ((1ull << w) - 1); v &= m; r %= w; return r ? ((v >> r) | (v << (w - r))) & m : v; }

static int bitmasks(int n, int imms, int immr, int sf, uint64_t *wmask, uint64_t *tmask) {
    uint32_t lv = (uint32_t)((n << 6) | (~imms & 0x3F));
    if (!lv) return 0;
    int len = 31 - __builtin_clz(lv);
    if (len < 1) return 0;
    int esize = 1 << len, levels = esize - 1;
    int S = imms & levels, R = immr & levels, d = (S - R) & levels;
    uint64_t welem = S + 1 >= 64 ? ~0ull : ((1ull << (S + 1)) - 1);
    uint64_t telem = d + 1 >= 64 ? ~0ull : ((1ull << (d + 1)) - 1);
    welem = ror64(welem, R, esize);
    uint64_t wm = 0, tm = 0;
    for (int i = 0; i < 64; i += esize) { wm |= welem << i; tm |= telem << i; if (esize == 64) break; }
    if (!sf) { wm &= 0xFFFFFFFFull; tm &= 0xFFFFFFFFull; }
    *wmask = wm; if (tmask) *tmask = tm;
    return 1;
}

static int unsupported(gx_emu *e, uint32_t ins) {
    char d[96]; uint64_t t;
    gx_a64_dis(ins, e->pc, d, sizeof d, &t);
    snprintf(e->reason, sizeof e->reason, GXT("Эмулятор не поддерживает инструкцию: %s"), d);
    return GX_EMU_STOPPED;
}

// переход: внутрь кода — продолжаем; на импорт / за пределы кода — внешний вызов
static int is_code(const gx_emu *e, uint64_t a) {
    int s = gx_bin_sect_of_addr(e->b, a);
    return s >= 0 && e->b->s[s].exec;
}
static const char *ext_name(gx_emu *e, uint64_t a) {
    if (a >= HANDLE_BASE && a < HANDLE_BASE + 256 * HANDLE_STEP) { int i = (int)((a - HANDLE_BASE) / HANDLE_STEP); return i < e->nhandles ? e->handles[i] : NULL; }
    const gx_name *n = gx_bin_import_at(e->b, a);
    return n ? n->name : NULL;
}
static int branch_to(gx_emu *e, uint64_t target, int link, uint64_t ret) {
    if (link) e->x[30] = ret;
    if (target == GX_EMU_RET_MAGIC) { e->pc = target; snprintf(e->reason, sizeof e->reason, "%s", GXT("Функция вернула результат")); return GX_EMU_RETURNED; }
    const char *nm = ext_name(e, target);
    if (nm || !is_code(e, target)) {
        char name[96];
        if (nm) snprintf(name, sizeof name, "%.80s", nm); else snprintf(name, sizeof name, "0x%llx", (unsigned long long)target);
        if (e->skip_ext && link) {
            e->x[0] = 0; e->v[0].d[0] = e->v[0].d[1] = 0;
            e->pc = ret;
            snprintf(e->reason, sizeof e->reason, GXT("Вызов %s пропущен (x0 = 0)"), name);
            return GX_EMU_OK;
        }
        e->pc = target;
        snprintf(e->reason, sizeof e->reason, GXT("Вызов внешней функции %s — остановлено"), name);
        return GX_EMU_EXTCALL;
    }
    e->pc = target;
    return GX_EMU_OK;
}

// ---------- плавающая точка ----------
static double fget(gx_emu *e, int r, int dbl) { return dbl ? e->v[r].f[0] : (double)e->v[r].s[0]; }
static void fset(gx_emu *e, int r, double v, int dbl) {
    memset(&e->v[r], 0, sizeof e->v[r]);
    if (dbl) e->v[r].f[0] = v; else e->v[r].s[0] = (float)v;
}
static uint32_t fcmp_flags(double a, double b) {
    if (isnan(a) || isnan(b)) return 3;
    if (a == b) return 6;
    return a < b ? 8 : 2;
}
static double vfp_imm(uint32_t imm8, int dbl) {
    int sign = imm8 >> 7, exp = (imm8 >> 4) & 7, frac = imm8 & 15;
    int e = (exp & 4) ? exp - 7 : exp + 1;      // 3-битная экспонента: -3..4
    double v = (1.0 + frac / 16.0) * ldexp(1.0, e);
    (void)dbl;
    return sign ? -v : v;
}
static int64_t f2i(double v, int rmode, int sf, int unsig) {
    double r;
    switch (rmode) { case 0: r = nearbyint(v); break; case 1: r = ceil(v); break; case 2: r = floor(v); break; case 4: r = round(v); break; default: r = trunc(v); }
    if (isnan(r)) return 0;
    if (unsig) {
        double mx = sf ? 18446744073709551615.0 : 4294967295.0;
        if (r <= 0) return 0; if (r >= mx) return (int64_t)(sf ? ~0ull : 0xFFFFFFFFull);
        return (int64_t)(uint64_t)r;
    }
    double mx = sf ? 9223372036854775807.0 : 2147483647.0, mn = sf ? -9223372036854775808.0 : -2147483648.0;
    if (r >= mx) return sf ? INT64_MAX : INT32_MAX;
    if (r <= mn) return sf ? INT64_MIN : INT32_MIN;
    return (int64_t)r;
}


// ---------- NEON (ходовое подмножество) ----------
static uint64_t vel(const gx_vreg *r, int esz, int i) {
    switch (esz) { case 1: return r->b[i]; case 2: { uint16_t v; memcpy(&v, r->b + i * 2, 2); return v; }
                   case 4: return r->w[i]; default: return r->d[i]; }
}
static void vset(gx_vreg *r, int esz, int i, uint64_t v) {
    switch (esz) { case 1: r->b[i] = (uint8_t)v; break; case 2: { uint16_t x = (uint16_t)v; memcpy(r->b + i * 2, &x, 2); break; }
                   case 4: r->w[i] = (uint32_t)v; break; default: r->d[i] = v; }
}
static int imm5_size(int imm5, int *idx) {
    for (int k = 0; k < 4; k++) if (imm5 & (1 << k)) { *idx = imm5 >> (k + 1); return 1 << k; }
    return 0;
}
static int neon(gx_emu *e, uint32_t ins) {
    int rd = ins & 31, rn = (ins >> 5) & 31, rm = (ins >> 16) & 31, Q = (ins >> 30) & 1, n16 = Q ? 16 : 8;
    gx_vreg a = e->v[rn], b = e->v[rm], r; memset(&r, 0, sizeof r);
    int idx, esz;
    if ((ins & 0xFFE0FC00) == 0x4E001C00) {                                         // INS Vd.T[i], Xn
        if (!(esz = imm5_size((ins >> 16) & 31, &idx))) return 0;
        vset(&e->v[rd], esz, idx, X(e, rn, 1)); return 1;
    }
    if ((ins & 0xBFE0FC00) == 0x0E003C00 || (ins & 0xBFE0FC00) == 0x0E002C00) {      // UMOV / SMOV
        if (!(esz = imm5_size((ins >> 16) & 31, &idx))) return 0;
        uint64_t v = vel(&a, esz, idx);
        if (((ins >> 12) & 1) == 0) v = sx(v, esz * 8);                              // SMOV
        W(e, rd, v, Q); return 1;
    }
    if ((ins & 0xBFE0FC00) == 0x0E000C00) {                                         // DUP Vd.T, Xn
        if (!(esz = imm5_size((ins >> 16) & 31, &idx))) return 0;
        for (int i = 0; i < n16 / esz; i++) vset(&r, esz, i, X(e, rn, 1));
        e->v[rd] = r; return 1;
    }
    if ((ins & 0xBFE0FC00) == 0x0E000400 || (ins & 0xFFE0FC00) == 0x5E000400) {      // DUP Vd.T, Vn.T[i] / скалярный DUP
        if (!(esz = imm5_size((ins >> 16) & 31, &idx))) return 0;
        uint64_t v = vel(&a, esz, idx);
        int cnt = (ins & 0x10000000) ? 1 : n16 / esz;
        for (int i = 0; i < cnt; i++) vset(&r, esz, i, v);
        e->v[rd] = r; return 1;
    }
    if ((ins & 0xFFE08400) == 0x6E000400) {                                         // INS Vd.T[i], Vn.T[j]
        if (!(esz = imm5_size((ins >> 16) & 31, &idx))) return 0;
        int j = ((ins >> 11) & 15) / esz;
        vset(&e->v[rd], esz, idx, vel(&a, esz, j)); return 1;
    }
    if ((ins & 0xBFFFFC00) == 0x0E205800) {                                         // CNT .8b/.16b
        for (int i = 0; i < n16; i++) r.b[i] = (uint8_t)__builtin_popcount(a.b[i]);
        e->v[rd] = r; return 1;
    }
    if ((ins & 0xBF3FFC00) == 0x2E303800 || (ins & 0xBF3FFC00) == 0x0E31B800) {      // UADDLV / ADDV
        esz = 1 << ((ins >> 22) & 3); uint64_t sum = 0;
        for (int i = 0; i < n16 / esz; i++) sum += vel(&a, esz, i);
        int osz = (ins & 0x20000000) ? esz * 2 : esz;
        if (osz < 8) sum &= (1ull << (osz * 8)) - 1;
        r.d[0] = sum; e->v[rd] = r; return 1;
    }
    if ((ins & 0xBF20FC00) == 0x0E208400 || (ins & 0xBF20FC00) == 0x2E208400 || (ins & 0xBF20FC00) == 0x0E209C00) { // ADD / SUB / MUL
        esz = 1 << ((ins >> 22) & 3); int sub = (ins >> 29) & 1, mul = (ins & 0xBF20FC00) == 0x0E209C00;
        for (int i = 0; i < n16 / esz; i++) { uint64_t x = vel(&a, esz, i), y = vel(&b, esz, i); vset(&r, esz, i, mul ? x * y : sub ? x - y : x + y); }
        e->v[rd] = r; return 1;
    }
    if ((ins & 0xFF20FC00) == 0x5E208400 || (ins & 0xFF20FC00) == 0x7E208400) {      // скалярный ADD/SUB d
        r.d[0] = (ins >> 29) & 1 ? a.d[0] - b.d[0] : a.d[0] + b.d[0]; e->v[rd] = r; return 1;
    }
    if ((ins & 0xBF20FC00) == 0x0E201C00 || (ins & 0xBF20FC00) == 0x2E201C00) {      // AND BIC ORR ORN / EOR BSL BIT BIF
        int opc = (ins >> 22) & 3, U = (ins >> 29) & 1; gx_vreg dd = e->v[rd];
        for (int i = 0; i < 2; i++) {
            uint64_t x = a.d[i], y = b.d[i], d0 = dd.d[i], v;
            if (!U) v = opc == 0 ? x & y : opc == 1 ? x & ~y : opc == 2 ? x | y : x | ~y;
            else v = opc == 0 ? x ^ y : opc == 1 ? (d0 & x) | (~d0 & y) : opc == 2 ? (d0 & ~y) | (x & y) : (d0 & y) | (x & ~y);
            r.d[i] = v;
        }
        if (!Q) r.d[1] = 0;
        e->v[rd] = r; return 1;
    }
    if ((ins & 0x9F80FC00) == 0x0F00A400 && ((ins >> 19) & 15)) {                   // SSHLL / USHLL (SXTL / UXTL)
        int immh = (ins >> 19) & 15, ihb = (ins >> 16) & 127, U = (ins >> 29) & 1;
        esz = immh >= 4 ? 4 : immh >= 2 ? 2 : 1;
        int sh = ihb - esz * 8, half = Q ? 8 / esz : 0;
        for (int i = 0; i < 8 / esz; i++) { uint64_t v = vel(&a, esz, i + half); if (!U) v = sx(v, esz * 8); vset(&r, esz * 2, i, v << sh); }
        e->v[rd] = r; return 1;
    }
    if (((ins & 0xBF80FC00) == 0x0F005400 || (ins & 0xBF80FC00) == 0x2F000400 || (ins & 0xBF80FC00) == 0x0F000400 ||
         (ins & 0xFF80FC00) == 0x5F005400 || (ins & 0xFF80FC00) == 0x7F000400 || (ins & 0xFF80FC00) == 0x5F000400) && ((ins >> 19) & 15)) {
        int immh = (ins >> 19) & 15, ihb = (ins >> 16) & 127, U = (ins >> 29) & 1, shl = ((ins >> 11) & 31) == 10;
        int scalar = (ins >> 28) & 1;
        esz = immh >= 8 ? 8 : immh >= 4 ? 4 : immh >= 2 ? 2 : 1;
        int cnt = scalar ? 1 : n16 / esz;
        for (int i = 0; i < cnt; i++) {
            uint64_t v = vel(&a, esz, i);
            if (shl) v <<= (ihb - esz * 8);
            else { int sh = esz * 16 - ihb; if (U) v = sh >= 64 ? 0 : v >> sh; else v = (uint64_t)((int64_t)sx(v, esz * 8) >> (sh >= 64 ? 63 : sh)); }
            vset(&r, esz, i, v);
        }
        e->v[rd] = r; return 1;
    }
    {   // плавающая точка: векторная и скалярная (SIMD)
        int dbl = (ins >> 22) & 1;
        int cnt = dbl ? (Q ? 2 : 1) : (Q ? 4 : 2);
        #define FE(v, i) (dbl ? (v).f[i] : (double)(v).s[i])
        #define FSET(v, i, x) do { if (dbl) (v).f[i] = (x); else (v).s[i] = (float)(x); } while (0)
        uint32_t m3 = ins & 0xBFA0FC00, ms = ins & 0xFFA0FC00, mc = ins & 0xFFBFFC00, mv = ins & 0xBFBFFC00;
        if (m3 == 0x0E20D400 || m3 == 0x0EA0D400 || m3 == 0x2E20DC00 || m3 == 0x2E20FC00 || m3 == 0x2EA0D400) {
            for (int i = 0; i < cnt; i++) {
                double x = FE(a, i), y = FE(b, i), v;
                v = m3 == 0x0E20D400 ? x + y : m3 == 0x0EA0D400 ? x - y : m3 == 0x2E20DC00 ? x * y : m3 == 0x2E20FC00 ? x / y : fabs(x - y);
                FSET(r, i, v);
            }
            e->v[rd] = r; return 1;
        }
        if (ms == 0x7EA0D400) { FSET(r, 0, fabs(FE(a, 0) - FE(b, 0))); e->v[rd] = r; return 1; }          // FABD скалярный
        if (mc == 0x7E30D800) { FSET(r, 0, FE(a, 0) + FE(a, 1)); e->v[rd] = r; return 1; }               // FADDP скалярный
        if (mv == 0x2E20D400) {                                                                           // FADDP вектор
            gx_vreg t; memset(&t, 0, sizeof t);
            for (int i = 0; i < cnt; i++) { gx_vreg *src = i < cnt / 2 ? &a : &b; int j = (i % (cnt / 2)) * 2; FSET(t, i, FE(*src, j) + FE(*src, j + 1)); }
            e->v[rd] = t; return 1;
        }
        if (mc == 0x5E21D800 || mc == 0x7E21D800 || mv == 0x0E21D800 || mv == 0x2E21D800) {             // SCVTF / UCVTF (SIMD)
            int U = (ins >> 29) & 1, n = (ins >> 28) & 1 ? 1 : cnt;
            for (int i = 0; i < n; i++) { uint64_t v = dbl ? a.d[i] : a.w[i]; double x = U ? (double)v : dbl ? (double)(int64_t)v : (double)(int32_t)(uint32_t)v; FSET(r, i, x); }
            e->v[rd] = r; return 1;
        }
        if (mc == 0x5EA1B800 || mc == 0x7EA1B800 || mv == 0x0EA1B800 || mv == 0x2EA1B800) {             // FCVTZS / FCVTZU (SIMD)
            int U = (ins >> 29) & 1, n = (ins >> 28) & 1 ? 1 : cnt;
            for (int i = 0; i < n; i++) { int64_t v = f2i(FE(a, i), 3, dbl, U); if (dbl) r.d[i] = (uint64_t)v; else r.w[i] = (uint32_t)v; }
            e->v[rd] = r; return 1;
        }
        #undef FE
        #undef FSET
    }
    return 0;
}

// ---------- загрузка / сохранение ----------
// V=0: size 0..3 → 1,2,4,8 байт; opc: 0 STR, 1 LDR, 2 LDRS→64, 3 LDRS→32. V=1: размер из size/opc, 16 для Q.
static int ldst(gx_emu *e, int V, int size, int opc, int rt, uint64_t addr) {
    if (!V) {
        int bytes = 1 << size;
        if (opc == 0) return st(e, addr, bytes, X(e, rt, 1)) ? GX_EMU_OK : fault(e, addr, 1);
        if (size == 3 && opc >= 2) return GX_EMU_OK;                 // PRFM
        uint64_t v; if (!ld(e, addr, bytes, &v)) return fault(e, addr, 0);
        if (opc == 1) W(e, rt, v, 1);
        else if (opc == 2) W(e, rt, sx(v, bytes * 8), 1);
        else W(e, rt, (uint32_t)sx(v, bytes * 8), 1);
        return GX_EMU_OK;
    }
    int q = (opc & 2) && size == 0;
    int bytes = q ? 16 : 1 << size;
    if (opc & 1) {
        gx_vreg r; memset(&r, 0, sizeof r);
        if (bytes == 16) { uint64_t lo, hi; if (!ld(e, addr, 8, &lo) || !ld(e, addr + 8, 8, &hi)) return fault(e, addr, 0); r.d[0] = lo; r.d[1] = hi; }
        else { uint64_t v; if (!ld(e, addr, bytes, &v)) return fault(e, addr, 0); r.d[0] = v; }
        e->v[rt] = r;
    } else {
        if (bytes == 16) { if (!st(e, addr, 8, e->v[rt].d[0]) || !st(e, addr + 8, 8, e->v[rt].d[1])) return fault(e, addr, 1); }
        else if (!st(e, addr, bytes, e->v[rt].d[0])) return fault(e, addr, 1);
    }
    return GX_EMU_OK;
}

// ---------- шаг ----------
int gx_emu_step(gx_emu *e) {
    e->nmem = 0; e->reason[0] = 0;
    if (e->pc == GX_EMU_RET_MAGIC) { snprintf(e->reason, sizeof e->reason, "%s", GXT("Функция вернула результат")); return GX_EMU_RETURNED; }
    const char *xn = ext_name(e, e->pc);
    if (xn || !is_code(e, e->pc)) { snprintf(e->reason, sizeof e->reason, GXT("Адрес 0x%llx вне кода функции — остановлено"), (unsigned long long)e->pc); return GX_EMU_STOPPED; }
    uint32_t ins;
    if (!gx_emu_read(e, e->pc, &ins, 4)) return fault(e, e->pc, 0);
    uint64_t pc = e->pc, next = pc + 4;
    e->steps++;
    int sf = ins >> 31, rd = ins & 31, rn = (ins >> 5) & 31, rm = (ins >> 16) & 31;

    // --- переходы и система ---
    if ((ins & 0x7C000000) == 0x14000000) {                                     // B / BL
        int64_t off = (int64_t)sx(ins & 0x3FFFFFF, 26) * 4;
        return branch_to(e, pc + (uint64_t)off, ins >> 31, next);
    }
    if ((ins & 0xFF000010) == 0x54000000) {                                     // B.cond
        int64_t off = (int64_t)sx((ins >> 5) & 0x7FFFF, 19) * 4;
        if (cond(e->nzcv, ins & 15)) return branch_to(e, pc + (uint64_t)off, 0, next);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x7E000000) == 0x34000000) {                                     // CBZ / CBNZ
        int64_t off = (int64_t)sx((ins >> 5) & 0x7FFFF, 19) * 4;
        int zero = X(e, rd, sf) == 0, nz = (ins >> 24) & 1;
        if (zero != nz) return branch_to(e, pc + (uint64_t)off, 0, next);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x7E000000) == 0x36000000) {                                     // TBZ / TBNZ
        int bit = (int)(((ins >> 31) << 5) | ((ins >> 19) & 31));
        int64_t off = (int64_t)sx((ins >> 5) & 0x3FFF, 14) * 4;
        int set = (e->x[rd == 31 ? 0 : rd] >> bit) & 1; if (rd == 31) set = 0;
        if (set == (int)((ins >> 24) & 1)) return branch_to(e, pc + (uint64_t)off, 0, next);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0xFFFFFC1F) == 0xD61F0000 || (ins & 0xFFFFFC1F) == 0xD63F0000 || (ins & 0xFFFFFC1F) == 0xD65F0000 ||
        ins == 0xD65F0BFF || ins == 0xD65F0FFF ||
        (ins & 0xFEDFF800) == 0xD61F0800) {  // BR, BLR, RET (+ PAC)
        int link = (ins >> 21) & 1;
        int r = (ins == 0xD65F0BFF || ins == 0xD65F0FFF) ? 30 : rn;
        uint64_t t = e->x[r == 31 ? 30 : r];
        if (r == 31) t = 0;
        return branch_to(e, t, link, next);
    }
    if ((ins & 0xFFFFF01F) == 0xD503201F || (ins & 0xFFFFF09F) == 0xD503309F || ins == 0xD50330DF ||
        (ins & 0xFFFFF0FF) == 0xD503309F) { e->pc = next; return GX_EMU_OK; }   // NOP, PAC/BTI-подсказки, барьеры
    if ((ins & 0xFFE0001F) == 0xD4000001) { snprintf(e->reason, sizeof e->reason, "%s", GXT("Системный вызов (svc) — остановлено")); return GX_EMU_STOPPED; }
    if ((ins & 0xFFE0001F) == 0xD4200000) { snprintf(e->reason, sizeof e->reason, "%s", GXT("Точка останова (brk) — обычно проверка на ошибку")); return GX_EMU_STOPPED; }
    if ((ins & 0xFFFFC000) == 0xDAC10000) { e->pc = next; return GX_EMU_OK; }   // PAC*/AUT* — подписи нет, значение не меняется
    if (ins == 0xD503237F || (ins & 0xFFFFFFE0) == 0xDAC143E0 || (ins & 0xFFFFFFE0) == 0xDAC147E0) { e->pc = next; return GX_EMU_OK; } // XPACI/XPACLRI

    // --- обработка данных с непосредственными значениями ---
    if ((ins & 0x1F000000) == 0x10000000) {                                     // ADR / ADRP
        int64_t imm = (int64_t)sx(((ins >> 5) & 0x7FFFF) << 2 | ((ins >> 29) & 3), 21);
        uint64_t v = (ins >> 31) ? (pc & ~0xFFFull) + (uint64_t)(imm << 12) : pc + (uint64_t)imm;
        W(e, rd, v, 1); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1F800000) == 0x11000000) {                                     // ADD/SUB imm
        uint64_t imm = (ins >> 10) & 0xFFF; if ((ins >> 22) & 1) imm <<= 12;
        int op = (ins >> 30) & 1, S = (ins >> 29) & 1; uint32_t fl;
        uint64_t a = XS(e, rn, sf);
        uint64_t r = op ? addc(a, ~imm, 1, sf, &fl) : addc(a, imm, 0, sf, &fl);
        if (S) { e->nzcv = fl; W(e, rd, r, sf); } else WS(e, rd, r, sf);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1F800000) == 0x12000000) {                                     // логические imm
        uint64_t m; if (!bitmasks((ins >> 22) & 1, (ins >> 10) & 63, (ins >> 16) & 63, sf, &m, NULL)) return unsupported(e, ins);
        int opc = (ins >> 29) & 3; uint64_t a = X(e, rn, sf), r;
        r = opc == 0 ? a & m : opc == 1 ? a | m : opc == 2 ? a ^ m : a & m;
        if (!sf) r = (uint32_t)r;
        if (opc == 3) { e->nzcv = ((sf ? r >> 63 : r >> 31) & 1 ? 8 : 0) | (r == 0 ? 4 : 0); W(e, rd, r, sf); }
        else WS(e, rd, r, sf);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1F800000) == 0x12800000) {                                     // MOVN / MOVZ / MOVK
        int opc = (ins >> 29) & 3, hw = (ins >> 21) & 3; uint64_t imm = (uint64_t)((ins >> 5) & 0xFFFF) << (hw * 16);
        if (opc == 0) W(e, rd, ~imm, sf);
        else if (opc == 2) W(e, rd, imm, sf);
        else if (opc == 3) { uint64_t v = X(e, rd, 1) & ~((uint64_t)0xFFFF << (hw * 16)); W(e, rd, v | imm, sf); }
        else return unsupported(e, ins);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1F800000) == 0x13000000) {                                     // SBFM / BFM / UBFM
        int opc = (ins >> 29) & 3, immr = (ins >> 16) & 63, imms = (ins >> 10) & 63, w = sf ? 64 : 32;
        uint64_t wm, tm; if (!bitmasks((ins >> 22) & 1, imms, immr, sf, &wm, &tm)) return unsupported(e, ins);
        uint64_t src = X(e, rn, sf), bot = ror64(src, immr, w) & wm, r;
        if (opc == 1) { uint64_t dst = X(e, rd, sf); r = (dst & ~wm) | bot; r = (dst & ~tm) | (r & tm); }
        else if (opc == 2) r = bot & tm;
        else if (opc == 0) { uint64_t top = ((src >> imms) & 1) ? (sf ? ~0ull : 0xFFFFFFFFull) : 0; r = (top & ~tm) | (bot & tm); }
        else return unsupported(e, ins);
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x7FA00000) == 0x13800000) {                                     // EXTR
        int lsb = (ins >> 10) & 63, w = sf ? 64 : 32;
        uint64_t hi = X(e, rn, sf), lo = X(e, rm, sf), r;
        r = lsb ? ((lo >> lsb) | (hi << (w - lsb))) : lo;
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }

    // --- обработка данных с регистрами ---
    if ((ins & 0x1F000000) == 0x0A000000) {                                     // логические shifted
        int opc = (ins >> 29) & 3, N = (ins >> 21) & 1;
        uint64_t b = shiftv(X(e, rm, sf), (ins >> 22) & 3, (ins >> 10) & 63, sf); if (N) b = ~b;
        uint64_t a = X(e, rn, sf), r = opc == 0 ? a & b : opc == 1 ? a | b : opc == 2 ? a ^ b : a & b;
        if (!sf) r = (uint32_t)r;
        if (opc == 3) e->nzcv = ((sf ? r >> 63 : r >> 31) & 1 ? 8 : 0) | (r == 0 ? 4 : 0);
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1F200000) == 0x0B000000 || (ins & 0x1F200000) == 0x0B200000) { // ADD/SUB shifted / extended
        int ext = (ins >> 21) & 1, op = (ins >> 30) & 1, S = (ins >> 29) & 1; uint32_t fl;
        uint64_t a, b;
        if (ext) { a = XS(e, rn, sf); b = extendv(X(e, rm, 1), (ins >> 13) & 7, (ins >> 10) & 7); }
        else { a = X(e, rn, sf); b = shiftv(X(e, rm, sf), (ins >> 22) & 3, (ins >> 10) & 63, sf); }
        if (!sf) b = (uint32_t)b;
        uint64_t r = op ? addc(a, ~b, 1, sf, &fl) : addc(a, b, 0, sf, &fl);
        if (S) { e->nzcv = fl; W(e, rd, r, sf); } else if (ext) WS(e, rd, r, sf); else W(e, rd, r, sf);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1FE0FC00) == 0x1A000000) {                                     // ADC / SBC
        int op = (ins >> 30) & 1, S = (ins >> 29) & 1; uint32_t fl;
        uint64_t b = X(e, rm, sf); if (op) b = ~b;
        uint64_t r = addc(X(e, rn, sf), b, (e->nzcv >> 1) & 1, sf, &fl);
        if (S) e->nzcv = fl;
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1FE00410) == 0x1A400000) {                                     // CCMP / CCMN
        if (cond(e->nzcv, (ins >> 12) & 15)) {
            uint64_t b = ((ins >> 11) & 1) ? (uint64_t)((ins >> 16) & 31) : X(e, rm, sf); uint32_t fl;
            if ((ins >> 30) & 1) addc(X(e, rn, sf), ~b, 1, sf, &fl); else addc(X(e, rn, sf), b, 0, sf, &fl);
            e->nzcv = fl;
        } else e->nzcv = ins & 15;
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1FE00800) == 0x1A800000) {                                     // CSEL / CSINC / CSINV / CSNEG
        int op = (ins >> 30) & 1, o2 = (ins >> 10) & 1;
        uint64_t r;
        if (cond(e->nzcv, (ins >> 12) & 15)) r = X(e, rn, sf);
        else { r = X(e, rm, sf); if (op) r = o2 ? (uint64_t)(-(int64_t)r) : ~r; else if (o2) r = r + 1; }
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x5FE00000) == 0x1AC00000) {                                     // 2 источника
        int opc = (ins >> 10) & 63; uint64_t a = X(e, rn, sf), b = X(e, rm, sf), r;
        switch (opc) {
            case 2: r = b ? a / b : 0; break;
            case 3: if (!b) r = 0; else if (sf) r = ((int64_t)a == INT64_MIN && (int64_t)b == -1) ? a : (uint64_t)((int64_t)a / (int64_t)b);
                    else r = ((int32_t)a == INT32_MIN && (int32_t)b == -1) ? a : (uint64_t)(uint32_t)((int32_t)a / (int32_t)b); break;
            case 8: case 9: case 10: case 11: r = shiftv(a, opc - 8, (int)(b % (sf ? 64 : 32)), sf); break;
            default: return unsupported(e, ins);
        }
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x5FFF0000) == 0x5AC00000) {                                     // 1 источник
        int opc = (ins >> 10) & 63; uint64_t a = X(e, rn, sf), r = 0; int w = sf ? 64 : 32;
        switch (opc) {
            case 0: for (int i = 0; i < w; i++) if ((a >> i) & 1) r |= 1ull << (w - 1 - i); break;
            case 1: for (int i = 0; i < w; i += 16) r |= (uint64_t)__builtin_bswap16((uint16_t)(a >> i)) << i; break;
            case 2: if (sf) r = (uint64_t)__builtin_bswap32((uint32_t)a) | (uint64_t)__builtin_bswap32((uint32_t)(a >> 32)) << 32; else r = __builtin_bswap32((uint32_t)a); break;
            case 3: r = __builtin_bswap64(a); break;
            case 4: r = a ? (uint64_t)(sf ? __builtin_clzll(a) : __builtin_clz((uint32_t)a)) : (uint64_t)w; break;
            case 5: { int64_t s = sf ? (int64_t)a : (int64_t)(int32_t)a; uint64_t t = (uint64_t)(s ^ (s >> 63)); t = sf ? t : (uint32_t)t;
                      r = t ? (uint64_t)((sf ? __builtin_clzll(t) : __builtin_clz((uint32_t)t)) - 1) : (uint64_t)(w - 1); break; }
            default: return unsupported(e, ins);
        }
        W(e, rd, r, sf); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x1F000000) == 0x1B000000) {                                     // 3 источника
        int op31 = (ins >> 21) & 7, o0 = (ins >> 15) & 1, ra = (ins >> 10) & 31; uint64_t r;
        uint64_t a = X(e, rn, 1), b = X(e, rm, 1), c = X(e, ra, 1);
        switch (op31) {
            case 0: r = o0 ? c - a * b : c + a * b; W(e, rd, r, sf); break;
            case 1: { int64_t p = (int64_t)(int32_t)a * (int32_t)b; W(e, rd, o0 ? c - (uint64_t)p : c + (uint64_t)p, 1); break; }
            case 5: { uint64_t p = (uint64_t)(uint32_t)a * (uint32_t)b; W(e, rd, o0 ? c - p : c + p, 1); break; }
            case 2: W(e, rd, (uint64_t)(((__int128)(int64_t)a * (int64_t)b) >> 64), 1); break;
            case 6: W(e, rd, (uint64_t)(((unsigned __int128)a * b) >> 64), 1); break;
            default: return unsupported(e, ins);
        }
        e->pc = next; return GX_EMU_OK;
    }

    // --- загрузка и сохранение ---
    if ((ins & 0x3B000000) == 0x18000000) {                                     // LDR literal
        int opc = ins >> 30, V = (ins >> 26) & 1;
        uint64_t a = pc + (uint64_t)((int64_t)sx((ins >> 5) & 0x7FFFF, 19) * 4);
        int r;
        if (V) r = ldst(e, 1, opc == 0 ? 2 : opc == 1 ? 3 : 0, opc == 2 ? 3 : 1, rd, a);
        else if (opc == 3) r = GX_EMU_OK;
        else r = ldst(e, 0, opc == 0 ? 2 : 3, opc == 2 ? 2 : 1, rd, a);
        if (r) return r;
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x3A000000) == 0x28000000) {                                     // LDP / STP
        int opc = ins >> 30, V = (ins >> 26) & 1, idx = (ins >> 23) & 3, L = (ins >> 22) & 1, rt2 = (ins >> 10) & 31;
        int size, sgn = 0;
        if (V) size = opc == 0 ? 4 : opc == 1 ? 8 : 16; else { size = opc == 2 ? 8 : 4; sgn = opc == 1; }
        int64_t off = (int64_t)sx((ins >> 15) & 0x7F, 7) * size;
        uint64_t base = XS(e, rn, 1), a = idx == 1 ? base : base + (uint64_t)off;
        int r = 0;
        for (int k = 0; k < 2 && !r; k++) {
            int rt = k ? rt2 : rd; uint64_t ad = a + (uint64_t)(k * size);
            if (V) r = ldst(e, 1, size == 16 ? 0 : size == 8 ? 3 : 2, (size == 16 ? 2 : 0) | L, rt, ad);
            else r = ldst(e, 0, size == 8 ? 3 : 2, L ? (sgn ? 2 : 1) : 0, rt, ad);
        }
        if (r) return r;
        if (idx == 1 || idx == 3) WS(e, rn, base + (uint64_t)off, 1);
        e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0x3B000000) == 0x39000000 || (ins & 0x3B200000) == 0x38000000 || (ins & 0x3B200C00) == 0x38200800) {
        int size = ins >> 30, V = (ins >> 26) & 1, opc = (ins >> 22) & 3;
        int scale = V && (opc & 2) && size == 0 ? 4 : size;
        uint64_t base = XS(e, rn, 1), a; int wb = 0; uint64_t nb = 0;
        if ((ins & 0x3B000000) == 0x39000000) a = base + ((uint64_t)((ins >> 10) & 0xFFF) << scale);
        else if ((ins & 0x3B200C00) == 0x38200800) {
            int opt = (ins >> 13) & 7, S = (ins >> 12) & 1;
            a = base + extendv(X(e, rm, 1), opt, S ? scale : 0);
        } else {
            int64_t imm = (int64_t)sx((ins >> 12) & 0x1FF, 9); int mode = (ins >> 10) & 3;
            if (mode == 1) { a = base; wb = 1; nb = base + (uint64_t)imm; }
            else if (mode == 3) { a = base + (uint64_t)imm; wb = 1; nb = a; }
            else a = base + (uint64_t)imm;
        }
        int r = ldst(e, V, size, opc, rd, a);
        if (r) return r;
        if (wb) WS(e, rn, nb, 1);
        e->pc = next; return GX_EMU_OK;
    }

    // --- плавающая точка (скалярная) ---
    if ((ins & 0xFFFFFFE0) == 0x2F00E400 || (ins & 0xFFFFFFE0) == 0x6F00E400) { memset(&e->v[rd], 0, sizeof e->v[rd]); e->pc = next; return GX_EMU_OK; } // MOVI #0
    if ((ins & 0x5F200000) == 0x1E200000 && ((ins >> 22) & 3) < 2) {
        int dbl = (ins >> 22) & 1;
        if ((ins & 0x7F20FC00) == 0x1E200000) {                                // FP <-> целые
            int rmode = (ins >> 19) & 3, opcode = (ins >> 16) & 7;
            if (rmode == 0 && (opcode == 2 || opcode == 3)) {                  // SCVTF / UCVTF
                uint64_t v = X(e, rn, sf);
                double d = opcode == 2 ? (sf ? (double)(int64_t)v : (double)(int32_t)v) : (sf ? (double)v : (double)(uint32_t)v);
                fset(e, rd, d, dbl);
            } else if (opcode <= 1 || opcode == 4 || opcode == 5) {           // FCVT[NPMZA]{S,U}
                int mode = opcode >= 4 ? 4 : rmode == 0 ? 0 : rmode == 1 ? 1 : rmode == 2 ? 2 : 3;
                W(e, rd, (uint64_t)f2i(fget(e, rn, dbl), mode, sf, opcode & 1), sf);
            } else if (rmode == 0 && opcode == 6) W(e, rd, dbl ? e->v[rn].d[0] : e->v[rn].w[0], sf);      // FMOV gp ← fp
            else if (rmode == 0 && opcode == 7) { uint64_t v = X(e, rn, sf); memset(&e->v[rd], 0, sizeof e->v[rd]); e->v[rd].d[0] = v; } // FMOV fp ← gp
            else return unsupported(e, ins);
            e->pc = next; return GX_EMU_OK;
        }
        if ((ins & 0xFF201FE0) == 0x1E201000) { fset(e, rd, vfp_imm((ins >> 13) & 0xFF, dbl), dbl); e->pc = next; return GX_EMU_OK; } // FMOV imm
        if ((ins & 0xFF207C00) == 0x1E204000) {                                 // 1 источник
            int op = (ins >> 15) & 63; double a = fget(e, rn, dbl);
            switch (op) {
                case 0: if (dbl) e->v[rd] = (gx_vreg){.d = {e->v[rn].d[0], 0}}; else { gx_vreg t = {0}; t.w[0] = e->v[rn].w[0]; e->v[rd] = t; } break;
                case 1: fset(e, rd, fabs(a), dbl); break;
                case 2: fset(e, rd, -a, dbl); break;
                case 3: fset(e, rd, sqrt(a), dbl); break;
                case 4: fset(e, rd, a, 0); break;   // FCVT → single
                case 5: fset(e, rd, a, 1); break;   // FCVT → double
                case 8: case 9: case 10: case 11: case 12: case 14: { double r = op == 9 ? ceil(a) : op == 10 ? floor(a) : op == 11 ? trunc(a) : op == 12 ? round(a) : nearbyint(a); fset(e, rd, r, dbl); break; }
                default: return unsupported(e, ins);
            }
            e->pc = next; return GX_EMU_OK;
        }
        if ((ins & 0xFF200C00) == 0x1E200800) {                                 // 2 источника
            double a = fget(e, rn, dbl), b = fget(e, rm, dbl), r;
            switch ((ins >> 12) & 15) {
                case 0: r = a * b; break; case 1: r = a / b; break; case 2: r = a + b; break; case 3: r = a - b; break;
                case 4: case 6: r = fmax(a, b); break; case 5: case 7: r = fmin(a, b); break; case 8: r = -(a * b); break;
                default: return unsupported(e, ins);
            }
            if (!dbl) r = (float)r;
            fset(e, rd, r, dbl); e->pc = next; return GX_EMU_OK;
        }
        if ((ins & 0xFF20FC07) == 0x1E202000) {                                 // FCMP / FCMPE
            double a = fget(e, rn, dbl), b = ((ins >> 3) & 1) ? 0.0 : fget(e, rm, dbl);
            e->nzcv = fcmp_flags(a, b); e->pc = next; return GX_EMU_OK;
        }
        if ((ins & 0xFF200C00) == 0x1E200C00) {                                 // FCSEL
            int c = cond(e->nzcv, (ins >> 12) & 15);
            gx_vreg src = e->v[c ? rn : rm], t; memset(&t, 0, sizeof t);
            if (dbl) t.d[0] = src.d[0]; else t.w[0] = src.w[0];
            e->v[rd] = t; e->pc = next; return GX_EMU_OK;
        }
        if ((ins & 0xFF200C10) == 0x1E200400) {                                 // FCCMP
            if (cond(e->nzcv, (ins >> 12) & 15)) e->nzcv = fcmp_flags(fget(e, rn, dbl), fget(e, rm, dbl));
            else e->nzcv = ins & 15;
            e->pc = next; return GX_EMU_OK;
        }
    }
    if ((ins & 0xFF000000) == 0x1F000000 && ((ins >> 22) & 3) < 2) {            // FMADD / FMSUB / FNMADD / FNMSUB
        int dbl = (ins >> 22) & 1, ra = (ins >> 10) & 31, o1 = (ins >> 21) & 1, o0 = (ins >> 15) & 1;
        double a = fget(e, rn, dbl), b = fget(e, rm, dbl), c = fget(e, ra, dbl), r;
        // 00 FMADD c+ab, 01 FMSUB c−ab, 10 FNMADD −c−ab, 11 FNMSUB −c+ab
        r = (o1 ? -c : c) + (o0 != o1 ? -(a * b) : a * b);
        if (!dbl) r = (float)r;
        fset(e, rd, r, dbl); e->pc = next; return GX_EMU_OK;
    }
    if ((ins & 0xFFE0FC00) == 0x0EA01C00 || (ins & 0xFFE0FC00) == 0x4EA01C00) {  // MOV v (ORR v,v,v)
        gx_vreg t = e->v[rn]; if (!((ins >> 30) & 1)) t.d[1] = 0; e->v[rd] = t; e->pc = next; return GX_EMU_OK;
    }
    if (neon(e, ins)) { e->pc = next; return GX_EMU_OK; }
    return unsupported(e, ins);
}

void gx_emu_return_from_call(gx_emu *e, uint64_t x0) {
    e->x[0] = x0; e->v[0].d[0] = e->v[0].d[1] = 0; e->pc = e->x[30]; e->nmem = 0;
    snprintf(e->reason, sizeof e->reason, GXT("Вызов пропущен, x0 = 0x%llx"), (unsigned long long)x0);
}

int gx_emu_run(gx_emu *e, uint64_t max) {
    for (uint64_t i = 0; i < max; i++) {
        int r = gx_emu_step(e);
        if (r != GX_EMU_OK) return r;
    }
    snprintf(e->reason, sizeof e->reason, GXT("Остановлено после %llu шагов (возможно, бесконечный цикл)"), (unsigned long long)max);
    return GX_EMU_STOPPED;
}

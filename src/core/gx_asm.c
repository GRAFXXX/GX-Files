#include "gx_tr.h"
// Мини-ассемблер ARM64 (основные инструкции, синтаксис как у llvm-mc / дизассемблера GX Files)
#include "gx_asm.h"
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int kind;      // 0 нет, 1 GP-регистр, 2 FP-регистр, 3 число, 4 память, 5 сдвиг/расширение, 6 условие, 7 float-число
    int n, sf, sp, zr;      // регистр: номер, 64-бит, это sp/wsp, это xzr/wzr
    char ft;                // тип FP: b h s d q
    int64_t imm; double f; int has_hash;
    // память
    int base, idxreg, idxsf, mode;   // mode: 0 [xn{,#imm}], 1 pre [..]!, 2 post [xn], #imm, 3 регистр-индекс
    int ext, amt, has_amt;           // сдвиг/расширение: 0 lsl 1 lsr 2 asr 3 ror 4 uxtb 5 uxth 6 uxtw 7 uxtx 8 sxtb 9 sxth 10 sxtw 11 sxtx
    int cond;
} op_t;

static const char *CCN[16] = {"eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le", "al", "nv"};

static int parse_cond(const char *s) {
    if (!strcmp(s, "cs")) return 2;
    if (!strcmp(s, "cc")) return 3;
    for (int i = 0; i < 16; i++) if (!strcmp(s, CCN[i])) return i;
    return -1;
}

static int parse_reg(const char *s, op_t *o) {
    memset(o, 0, sizeof *o);
    if (!strcmp(s, "sp")) { o->kind = 1; o->n = 31; o->sf = 1; o->sp = 1; return 1; }
    if (!strcmp(s, "wsp")) { o->kind = 1; o->n = 31; o->sf = 0; o->sp = 1; return 1; }
    if (!strcmp(s, "xzr")) { o->kind = 1; o->n = 31; o->sf = 1; o->zr = 1; return 1; }
    if (!strcmp(s, "wzr")) { o->kind = 1; o->n = 31; o->sf = 0; o->zr = 1; return 1; }
    if (!strcmp(s, "lr")) { o->kind = 1; o->n = 30; o->sf = 1; return 1; }
    if (!strcmp(s, "fp")) { o->kind = 1; o->n = 29; o->sf = 1; return 1; }
    char c = s[0];
    if (!strchr("xwbhsdqv", c) || !isdigit((unsigned char)s[1])) return 0;
    char *e; long n = strtol(s + 1, &e, 10);
    if (*e || n < 0 || n > 31) return 0;
    if (c == 'x' || c == 'w') { if (n == 31) return 0; o->kind = 1; o->n = (int)n; o->sf = c == 'x'; return 1; }
    o->kind = 2; o->n = (int)n; o->ft = c == 'v' ? 'q' : c;
    return 1;
}

static int parse_num(const char *s, int64_t *v, double *f, int *isfloat) {
    while (*s == ' ') s++;
    if (*s == '#') s++;
    char *e;
    *isfloat = 0;
    if (!*s) return 0;
    int neg = 0;
    const char *p = s;
    if (*p == '-' || *p == '+') { neg = *p == '-'; p++; }
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        unsigned long long u = strtoull(p, &e, 16);
        if (*e) return 0;
        *v = neg ? -(int64_t)u : (int64_t)u; *f = (double)*v;
        return 1;
    }
    if (strpbrk(p, ".eE")) {
        double d = strtod(s, &e);
        if (*e) return 0;
        *f = d; *isfloat = 1; *v = (int64_t)d;
        return 1;
    }
    unsigned long long u = strtoull(p, &e, 10);
    if (*e) return 0;
    *v = neg ? -(int64_t)u : (int64_t)u; *f = (double)*v;
    return 1;
}

static int parse_shift(const char *s, op_t *o) {
    static const char *nm[12] = {"lsl", "lsr", "asr", "ror", "uxtb", "uxth", "uxtw", "uxtx", "sxtb", "sxth", "sxtw", "sxtx"};
    char w[8] = {0}; int i = 0;
    while (s[i] && s[i] != ' ' && s[i] != '#' && i < 7) { w[i] = s[i]; i++; }
    for (int k = 0; k < 12; k++) if (!strcmp(w, nm[k])) {
        memset(o, 0, sizeof *o);
        o->kind = 5; o->ext = k;
        const char *r = s + i;
        while (*r == ' ') r++;
        if (*r) {
            int64_t v; double f; int fl;
            if (!parse_num(r, &v, &f, &fl) || fl || v < 0 || v > 63) return -1;
            o->amt = (int)v; o->has_amt = 1;
        }
        return 1;
    }
    return 0;
}

// разбить строку операндов по запятым верхнего уровня (без учёта запятых внутри [])
static int split_ops(char *s, char **parts, int max) {
    int n = 0, depth = 0;
    char *start = s;
    for (char *p = s; ; p++) {
        if (*p == '[') depth++;
        else if (*p == ']') depth--;
        if ((*p == ',' && depth == 0) || !*p) {
            char end = *p;
            *p = 0;
            while (*start == ' ' || *start == '\t') start++;
            char *t = start + strlen(start);
            while (t > start && (t[-1] == ' ' || t[-1] == '\t')) *--t = 0;
            if (n < max) parts[n++] = start;
            if (!end) break;
            start = p + 1;
        }
    }
    if (n == 1 && !parts[0][0]) n = 0;
    return n;
}

static int parse_mem(char *s, op_t *o, char *err, size_t el) {
    memset(o, 0, sizeof *o);
    o->kind = 4;
    char *close = strchr(s, ']');
    if (s[0] != '[' || !close) { snprintf(err, el, GXT("ожидалось [регистр...]")); return 0; }
    *close = 0;
    char *after = close + 1;
    while (*after == ' ') after++;
    char *in[4]; int k = split_ops(s + 1, in, 4);
    if (k < 1) { snprintf(err, el, GXT("пустой адрес")); return 0; }
    op_t r;
    if (!parse_reg(in[0], &r) || r.kind != 1 || !r.sf) { snprintf(err, el, GXT("база адреса должна быть x-регистром или sp")); return 0; }
    o->base = r.n;
    if (k >= 2) {
        op_t r2;
        if (parse_reg(in[1], &r2)) {
            if (r2.kind != 1 || r2.sp) { snprintf(err, el, GXT("индекс должен быть x/w-регистром")); return 0; }
            o->mode = 3; o->idxreg = r2.n; o->idxsf = r2.sf;
            o->ext = r2.sf ? 7 : 6;   // по умолчанию lsl (uxtx) для x, uxtw для w
            if (k >= 3) {
                op_t sh; int q = parse_shift(in[2], &sh);
                if (q <= 0) { snprintf(err, el, GXT("неверный сдвиг индекса: %s"), in[2]); return 0; }
                o->ext = sh.ext == 0 ? 7 : sh.ext; o->amt = sh.amt; o->has_amt = sh.has_amt;
                if (sh.ext == 0 && !sh.has_amt) { snprintf(err, el, GXT("lsl требует #число")); return 0; }
            }
        } else {
            int64_t v; double f; int fl;
            if (!parse_num(in[1], &v, &f, &fl) || fl) { snprintf(err, el, GXT("неверное смещение: %s"), in[1]); return 0; }
            o->imm = v;
        }
    }
    if (*after == '!') { if (o->mode == 3) { snprintf(err, el, GXT("! с регистром-индексом нельзя")); return 0; } o->mode = 1; }
    else if (*after == ',') {
        int64_t v; double f; int fl;
        if (o->mode == 3 || k >= 2 || !parse_num(after + 1, &v, &f, &fl) || fl) { snprintf(err, el, GXT("неверная пост-индексация")); return 0; }
        o->mode = 2; o->imm = v;
    } else if (*after) { snprintf(err, el, GXT("лишнее после ]: %s"), after); return 0; }
    return 1;
}

static int parse_op(char *s, op_t *o, char *err, size_t el) {
    memset(o, 0, sizeof *o);
    if (!*s) return 0;
    if (s[0] == '[') return parse_mem(s, o, err, el);
    if (parse_reg(s, o)) return 1;
    int q = parse_shift(s, o);
    if (q == 1) return 1;
    if (q < 0) { snprintf(err, el, GXT("неверный сдвиг: %s"), s); return 0; }
    int c = parse_cond(s);
    if (c >= 0) { o->kind = 6; o->cond = c; return 1; }
    int64_t v; double f; int fl;
    if (parse_num(s, &v, &f, &fl)) { o->kind = fl ? 7 : 3; o->imm = v; o->f = f; o->has_hash = s[0] == '#'; return 1; }
    snprintf(err, el, GXT("непонятный операнд: %s"), s);
    return 0;
}

// адрес назначения: абсолютное число или .+N / .-N
static int parse_target(const char *s, uint64_t pc, uint64_t *t) {
    while (*s == ' ') s++;
    if (*s == '.') {
        int64_t v; double f; int fl;
        if (!s[1]) { *t = pc; return 1; }
        if ((s[1] == '+' || s[1] == '-') && parse_num(s + 1, &v, &f, &fl) && !fl) { *t = pc + (uint64_t)v; return 1; }
        return 0;
    }
    int64_t v; double f; int fl;
    if (!parse_num(s, &v, &f, &fl) || fl) return 0;
    *t = (uint64_t)v;
    return 1;
}

// кодирование логической маски (immediate для and/orr/eor)
static int enc_bitmask(uint64_t v, int sf, uint32_t *N, uint32_t *immr, uint32_t *imms) {
    if (!sf) { if (v >> 32) return 0; v |= v << 32; }
    if (v == 0 || v == ~0ull) return 0;
    for (int size = 2; size <= 64; size <<= 1) {
        uint64_t mask = size == 64 ? ~0ull : (1ull << size) - 1;
        uint64_t e = v & mask;
        int ok = 1;
        for (int i = size; i < 64; i += size) if (((v >> i) & mask) != e) { ok = 0; break; }
        if (!ok) continue;
        if (e == 0 || e == mask) return 0;
        for (int r = 0; r < size; r++) {
            uint64_t rot = r ? (((e << r) | (e >> (size - r))) & mask) : e;   // ROL на r
            if ((rot & (rot + 1)) == 0) {   // вида 0..0111
                int k = 0; while (k < 64 && (rot >> k & 1)) k++;
                if (k == 0 || k >= size) continue;
                *N = size == 64;
                *immr = (uint32_t)r & (uint32_t)(size - 1);
                *imms = ((~(uint32_t)(size - 1) << 1) & 0x3Fu) | (uint32_t)(k - 1);
                if (size == 64) *imms = (uint32_t)(k - 1);
                if (!sf && *N) return 0;
                return 1;
            }
        }
        return 0;
    }
    return 0;
}

static double fpimm_val(int imm8) {
    int s = (imm8 >> 7) & 1, bcd = (imm8 >> 4) & 7, f = imm8 & 15;
    int e = bcd < 4 ? bcd + 1 : bcd - 7;
    double v = (16.0 + f) / 16.0 * ldexp(1.0, e);
    return s ? -v : v;
}
static int enc_fpimm(double v) { for (int i = 0; i < 256; i++) if (fpimm_val(i) == v) return i; return -1; }

static uint32_t movw(int sf, int opc, int hw, uint32_t imm, int rd) { return 0x12800000u | (uint32_t)sf << 31 | (uint32_t)opc << 29 | (uint32_t)hw << 21 | (imm & 0xFFFF) << 5 | (uint32_t)rd; }

#define ERR(...) do { snprintf(err, el, __VA_ARGS__); return 0; } while (0)
#define NEED(c, ...) do { if (!(c)) ERR(__VA_ARGS__); } while (0)

static int is_gp(const op_t *o) { return o->kind == 1; }
static int is_fp(const op_t *o) { return o->kind == 2; }
static int is_imm(const op_t *o) { return o->kind == 3; }
static uint32_t ftype(char t) { return t == 's' ? 0 : t == 'd' ? 1 : t == 'h' ? 3 : 0; }

static int enc_branch(uint64_t pc, uint64_t t, int bits, int64_t *off, char *err, size_t el) {
    int64_t d = (int64_t)(t - pc);
    if (d & 3) ERR(GXT("адрес перехода не кратен 4"));
    d >>= 2;
    if (d < -(1LL << (bits - 1)) || d >= (1LL << (bits - 1))) ERR(GXT("переход слишком далеко"));
    *off = d & ((1LL << bits) - 1);
    return 1;
}

// загрузки/сохранения одного регистра
static int enc_ldst(const char *m, op_t *rt, op_t *mem, char *opsrc, uint64_t pc, uint32_t *out, char *err, size_t el) {
    int size, V = 0, opc;
    int unscaled = !strncmp(m, "ldur", 4) || !strncmp(m, "stur", 4);
    char base[8];
    snprintf(base, sizeof base, "%s", m);
    if (unscaled) { base[2] = 'r'; memmove(base + 3, base + 4, strlen(base + 4) + 1); }   // ldurb → ldrb
    int load = base[0] == 'l';
    const char *suf = base + 3;   // после ldr/str
    if (is_fp(rt)) {
        NEED(!*suf, GXT("%s с FP-регистром — используй ldr/str"), m);
        V = 1;
        switch (rt->ft) { case 'b': size = 0; opc = load; break; case 'h': size = 1; opc = load; break; case 's': size = 2; opc = load; break; case 'd': size = 3; opc = load; break; default: size = 0; opc = load ? 3 : 2; }
    } else {
        NEED(is_gp(rt) && !rt->sp, GXT("%s: нужен регистр"), m);
        if (!*suf) { size = rt->sf ? 3 : 2; opc = load; }
        else if (!strcmp(suf, "b")) { NEED(!rt->sf, GXT("%s использует w-регистр"), m); size = 0; opc = load; }
        else if (!strcmp(suf, "h")) { NEED(!rt->sf, GXT("%s использует w-регистр"), m); size = 1; opc = load; }
        else if (!strcmp(suf, "sb")) { NEED(load, GXT("нет такой инструкции")); size = 0; opc = rt->sf ? 2 : 3; }
        else if (!strcmp(suf, "sh")) { NEED(load, GXT("нет такой инструкции")); size = 1; opc = rt->sf ? 2 : 3; }
        else if (!strcmp(suf, "sw")) { NEED(load && rt->sf, "ldrsw xN, ..."); size = 2; opc = 2; }
        else ERR(GXT("неизвестная инструкция %s"), m);
    }
    int scale = V && size == 0 && (opc & 2) ? 4 : size;
    if (mem->kind != 4) {
        // литерал: ldr xN, адрес
        uint64_t t;
        NEED(load && !unscaled && (!*suf || !strcmp(suf, "sw")) && parse_target(opsrc, pc, &t), GXT("ожидался адрес в [...]"));
        int64_t d; if (!enc_branch(pc, t, 19, &d, err, el)) return 0;
        int lopc = V ? (rt->ft == 's' ? 0 : rt->ft == 'd' ? 1 : rt->ft == 'q' ? 2 : -1) : (!strcmp(suf, "sw") ? 2 : rt->sf ? 1 : 0);
        NEED(lopc >= 0, GXT("литерал для этого регистра не поддерживается"));
        *out = 0x18000000u | (uint32_t)lopc << 30 | (uint32_t)V << 26 | (uint32_t)d << 5 | (uint32_t)rt->n;
        return 1;
    }
    uint32_t hdr = (uint32_t)size << 30 | (uint32_t)V << 26 | (uint32_t)opc << 22 | (uint32_t)mem->base << 5 | (uint32_t)rt->n;
    if (mem->mode == 3) {
        NEED(!unscaled, GXT("ldur/stur не бывает с регистром-индексом"));
        int opt = mem->ext == 7 ? 3 : mem->ext == 6 ? 2 : mem->ext == 10 ? 6 : mem->ext == 11 ? 7 : -1;
        NEED(opt >= 0, GXT("индекс: lsl, uxtw, sxtw или sxtx"));
        NEED((opt & 1) == mem->idxsf, GXT("тип расширения не подходит к регистру индекса"));
        int S = 0;
        if (mem->has_amt) { NEED(mem->amt == 0 || mem->amt == scale, GXT("сдвиг индекса должен быть 0 или %d"), scale); S = mem->amt == scale; }
        *out = 0x38200800u | hdr | (uint32_t)mem->idxreg << 16 | (uint32_t)opt << 13 | (uint32_t)S << 12;
        return 1;
    }
    int64_t imm = mem->imm;
    if (mem->mode == 1 || mem->mode == 2) {
        NEED(!unscaled, GXT("ldur/stur без пред/пост-индексации"));
        NEED(imm >= -256 && imm <= 255, GXT("смещение -256…255"));
        *out = 0x38000000u | hdr | ((uint32_t)imm & 0x1FF) << 12 | (mem->mode == 1 ? 3u : 1u) << 10;
        return 1;
    }
    int64_t sc = 1LL << scale;
    if (!unscaled && imm >= 0 && imm % sc == 0 && imm / sc <= 0xFFF) {
        *out = 0x39000000u | hdr | (uint32_t)(imm / sc) << 10;
        return 1;
    }
    NEED(imm >= -256 && imm <= 255, GXT("смещение вне диапазона"));
    *out = 0x38000000u | hdr | ((uint32_t)imm & 0x1FF) << 12;
    return 1;
}

static int enc_one(char *line, uint64_t pc, uint32_t *out, char *err, size_t el) {
    // мнемоника
    char m[24] = {0};
    char *p = line;
    while (*p == ' ' || *p == '\t') p++;
    int i = 0;
    while (*p && *p != ' ' && *p != '\t' && i < 23) m[i++] = (char)tolower((unsigned char)*p++);
    while (*p == ' ' || *p == '\t') p++;
    // операнды в нижнем регистре (кроме чисел — им всё равно)
    for (char *q = p; *q; q++) *q = (char)tolower((unsigned char)*q);
    char raw[256]; snprintf(raw, sizeof raw, "%s", p);
    char *parts[6]; int np = split_ops(p, parts, 6);
    char joined[160];
    for (int j = 0; j + 1 < np; j++)   // «[x0], #8» — пост-индексация была разрезана по запятой
        if (parts[j][0] == '[' && parts[j][strlen(parts[j]) - 1] == ']' && (parts[j + 1][0] == '#' || parts[j + 1][0] == '-' || isdigit((unsigned char)parts[j + 1][0]))) {
            snprintf(joined, sizeof joined, "%s, %s", parts[j], parts[j + 1]);
            parts[j] = joined;
            for (int q = j + 1; q + 1 < np; q++) parts[q] = parts[q + 1];
            np--;
            break;
        }
    op_t o[6]; memset(o, 0, sizeof o);
    char rawp[6][128] = {{0}};
    {
        char tmp[256]; snprintf(tmp, sizeof tmp, "%s", raw);
        char *rp[6]; int k = split_ops(tmp, rp, 6);
        for (int j = 0; j < k && j < 6; j++) snprintf(rawp[j], sizeof rawp[j], "%s", rp[j]);
    }
    int isbr = !strcmp(m, "b") || !strcmp(m, "bl") || !strncmp(m, "b.", 2) || !strcmp(m, "cbz") || !strcmp(m, "cbnz") || !strcmp(m, "tbz") || !strcmp(m, "tbnz") || !strcmp(m, "adr") || !strcmp(m, "adrp");
    for (int j = 0; j < np; j++) {
        int last = j == np - 1;
        if (isbr && last) continue;                                       // адрес перехода — разбираем отдельно
        if ((!strncmp(m, "ldr", 3) || !strcmp(m, "ldrsw")) && j == 1 && parts[j][0] != '[') continue;   // литерал
        if (!parse_op(parts[j], &o[j], err, el)) return 0;
    }

    if (!strcmp(m, ".word") || !strcmp(m, ".inst") || !strcmp(m, ".long")) {
        NEED(np == 1 && is_imm(&o[0]) && o[0].imm >= -0x80000000LL && o[0].imm <= 0xFFFFFFFFLL, ".word 0xXXXXXXXX");
        *out = (uint32_t)o[0].imm; return 1;
    }
    if (!strcmp(m, "nop")) { NEED(!np, GXT("nop без операндов")); *out = 0xD503201F; return 1; }
    if (!strcmp(m, "ret")) {
        if (!np) { *out = 0xD65F03C0; return 1; }
        NEED(np == 1 && is_gp(&o[0]) && o[0].sf, "ret xN"); *out = 0xD65F0000u | (uint32_t)o[0].n << 5; return 1;
    }
    if (!strcmp(m, "br") || !strcmp(m, "blr")) {
        NEED(np == 1 && is_gp(&o[0]) && o[0].sf && !o[0].sp, "%s xN", m);
        *out = (m[1] == 'r' ? 0xD61F0000u : 0xD63F0000u) | (uint32_t)o[0].n << 5; return 1;
    }
    if (!strcmp(m, "svc") || !strcmp(m, "brk") || !strcmp(m, "hvc")) {
        NEED(np == 1 && is_imm(&o[0]) && o[0].imm >= 0 && o[0].imm <= 0xFFFF, "%s #0…65535", m);
        *out = (m[0] == 'b' ? 0xD4200000u : m[0] == 'h' ? 0xD4000002u : 0xD4000001u) | (uint32_t)o[0].imm << 5; return 1;
    }
    if (isbr) {
        uint64_t t; int64_t d;
        NEED(np >= 1 && parse_target(rawp[np - 1], pc, &t), GXT("нужен адрес: 0x… или .+N"));
        if (!strcmp(m, "b") || !strcmp(m, "bl")) { NEED(np == 1, GXT("%s адрес"), m); if (!enc_branch(pc, t, 26, &d, err, el)) return 0; *out = (m[1] ? 0x94000000u : 0x14000000u) | (uint32_t)d; return 1; }
        if (!strncmp(m, "b.", 2)) { int c = parse_cond(m + 2); NEED(c >= 0 && np == 1, GXT("b.<условие> адрес")); if (!enc_branch(pc, t, 19, &d, err, el)) return 0; *out = 0x54000000u | (uint32_t)d << 5 | (uint32_t)c; return 1; }
        if (!strcmp(m, "cbz") || !strcmp(m, "cbnz")) { NEED(np == 2 && is_gp(&o[0]) && !o[0].sp, GXT("%s reg, адрес"), m); if (!enc_branch(pc, t, 19, &d, err, el)) return 0; *out = (m[2] == 'n' ? 0x35000000u : 0x34000000u) | (uint32_t)o[0].sf << 31 | (uint32_t)d << 5 | (uint32_t)o[0].n; return 1; }
        if (!strcmp(m, "tbz") || !strcmp(m, "tbnz")) {
            NEED(np == 3 && is_gp(&o[0]) && is_imm(&o[1]), GXT("%s reg, #бит, адрес"), m);
            NEED(o[1].imm >= 0 && o[1].imm < (o[0].sf ? 64 : 32), GXT("номер бита вне диапазона"));
            if (!enc_branch(pc, t, 14, &d, err, el)) return 0;
            uint32_t b = (uint32_t)o[1].imm;
            *out = (m[2] == 'n' ? 0x37000000u : 0x36000000u) | (b >> 5) << 31 | (b & 31) << 19 | (uint32_t)d << 5 | (uint32_t)o[0].n; return 1;
        }
        // adr / adrp
        NEED(np == 2 && is_gp(&o[0]) && o[0].sf && !o[0].sp, GXT("%s xN, адрес"), m);
        int64_t delta;
        if (m[3] == 'p') { delta = (int64_t)((t & ~0xFFFull) - (pc & ~0xFFFull)) >> 12; NEED(delta >= -(1LL << 20) && delta < (1LL << 20), GXT("adrp: слишком далеко")); }
        else { delta = (int64_t)(t - pc); NEED(delta >= -(1LL << 20) && delta < (1LL << 20), GXT("adr: ±1 МБ")); }
        uint32_t u = (uint32_t)delta & 0x1FFFFF;
        *out = (m[3] == 'p' ? 0x90000000u : 0x10000000u) | (u & 3) << 29 | (u >> 2) << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // MOV
    if (!strcmp(m, "mov")) {
        NEED(np == 2, GXT("mov приёмник, источник"));
        if (is_fp(&o[0]) || is_fp(&o[1])) { strcpy(m, "fmov"); }
        else {
            NEED(is_gp(&o[0]), GXT("mov: приёмник — регистр"));
            if (is_gp(&o[1])) {
                NEED(o[0].sf == o[1].sf, GXT("разные размеры регистров"));
                if (o[0].sp || o[1].sp) { *out = 0x11000000u | (uint32_t)o[0].sf << 31 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n; return 1; }
                *out = 0x2A0003E0u | (uint32_t)o[0].sf << 31 | (uint32_t)o[1].n << 16 | (uint32_t)o[0].n; return 1;
            }
            NEED(is_imm(&o[1]), GXT("mov: число или регистр"));
            int sf = o[0].sf;
            uint64_t v = (uint64_t)o[1].imm;
            if (!sf) { NEED(o[1].imm >= -0x80000000LL && o[1].imm <= 0xFFFFFFFFLL, GXT("число не влезает в 32 бита")); v &= 0xFFFFFFFF; }
            for (int hw = 0; hw < (sf ? 4 : 2); hw++) {
                uint64_t mk = 0xFFFFull << (16 * hw);
                if (!(v & ~mk) && !o[0].sp) { *out = movw(sf, 2, hw, (uint32_t)(v >> (16 * hw)), o[0].n); return 1; }
            }
            uint64_t nv = sf ? ~v : (~v & 0xFFFFFFFF);
            for (int hw = 0; hw < (sf ? 4 : 2); hw++) {
                uint64_t mk = 0xFFFFull << (16 * hw);
                if (!(nv & ~mk) && !o[0].sp) { *out = movw(sf, 0, hw, (uint32_t)(nv >> (16 * hw)), o[0].n); return 1; }
            }
            uint32_t N, r, s;
            if (enc_bitmask(v, sf, &N, &r, &s)) { *out = 0x320003E0u | (uint32_t)sf << 31 | N << 22 | r << 16 | s << 10 | (uint32_t)o[0].n; return 1; }
            ERR(GXT("число нельзя загрузить одной инструкцией — используй movz + movk"));
        }
    }
    if (!strcmp(m, "movz") || !strcmp(m, "movk") || !strcmp(m, "movn")) {
        NEED((np == 2 || np == 3) && is_gp(&o[0]) && !o[0].sp && is_imm(&o[1]), "%s reg, #imm16{, lsl #N}", m);
        int hw = 0;
        if (np == 3) { NEED(o[2].kind == 5 && o[2].ext == 0 && o[2].amt % 16 == 0 && o[2].amt / 16 < (o[0].sf ? 4 : 2), GXT("сдвиг: lsl #0/16/32/48")); hw = o[2].amt / 16; }
        NEED(o[1].imm >= 0 && o[1].imm <= 0xFFFF, "imm16: 0…65535");
        *out = movw(o[0].sf, m[3] == 'z' ? 2 : m[3] == 'k' ? 3 : 0, hw, (uint32_t)o[1].imm, o[0].n);
        return 1;
    }
    // ADD/SUB/CMP/CMN/NEG
    int addsub = !strcmp(m, "add") || !strcmp(m, "adds") || !strcmp(m, "sub") || !strcmp(m, "subs");
    if (!strcmp(m, "cmp") || !strcmp(m, "cmn")) {   // → subs/adds zr, ...
        NEED(np >= 2, GXT("%s reg, операнд"), m);
        for (int j = np; j > 0; j--) o[j] = o[j - 1];
        np++;
        memset(&o[0], 0, sizeof o[0]); o[0].kind = 1; o[0].n = 31; o[0].sf = o[1].sf; o[0].zr = 1;
        strcpy(m, m[2] == 'p' ? "subs" : "adds");
        addsub = 1;
    }
    if (!strcmp(m, "neg") || !strcmp(m, "negs")) {
        NEED(np >= 2, "%s rd, rm", m);
        for (int j = np; j > 1; j--) o[j] = o[j - 1];
        np++;
        memset(&o[1], 0, sizeof o[1]); o[1].kind = 1; o[1].n = 31; o[1].sf = o[0].sf; o[1].zr = 1;
        strcpy(m, m[3] == 's' ? "subs" : "sub");
        addsub = 1;
    }
    if (addsub) {
        int op = m[0] == 's', S = m[3] == 's';
        NEED(np >= 3 && is_gp(&o[0]) && is_gp(&o[1]), GXT("%s rd, rn, операнд"), m);
        int sf = o[0].sf;
        NEED(o[1].sf == sf, GXT("разные размеры регистров"));
        if (is_imm(&o[2])) {
            int64_t v = o[2].imm; int sh = 0;
            if (np == 4) { NEED(o[3].kind == 5 && o[3].ext == 0 && (o[3].amt == 0 || o[3].amt == 12), GXT("сдвиг: lsl #12")); sh = o[3].amt == 12; }
            if (v < 0 && !sh) { op ^= 1; v = -v; }    // add x0, x1, #-8 → sub
            if (!sh && v > 0xFFF && !(v & 0xFFF) && v <= 0xFFF000) { sh = 1; v >>= 12; }
            NEED(v >= 0 && v <= 0xFFF, GXT("число 0…4095 (или кратное 4096 до 0xFFF000)"));
            NEED(!(o[0].zr && !S) && !o[1].zr, GXT("здесь нельзя xzr"));
            *out = 0x11000000u | (uint32_t)sf << 31 | (uint32_t)op << 30 | (uint32_t)S << 29 | (uint32_t)sh << 22 | (uint32_t)v << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
            return 1;
        }
        NEED(is_gp(&o[2]), GXT("%s: третий операнд — регистр или число"), m);
        int ext = -1, amt = 0;
        if (np == 4) { NEED(o[3].kind == 5, GXT("четвёртый операнд — сдвиг")); amt = o[3].amt; if (o[3].ext >= 4) ext = o[3].ext; else { NEED(o[3].ext < 3 && amt < (sf ? 64 : 32), GXT("сдвиг: lsl/lsr/asr #N")); } }
        if (ext < 0 && (o[0].sp || o[1].sp) && !(np == 4 && o[3].ext < 4 && o[3].amt)) ext = sf ? 7 : 6;   // с sp — расширенная форма (uxtx)
        if (ext >= 0) {
            static const int optmap[12] = {-1, -1, -1, -1, 0, 1, 2, 3, 4, 5, 6, 7};
            int opt = optmap[ext];
            NEED(amt <= 4, GXT("сдвиг расширения 0…4"));
            *out = 0x0B200000u | (uint32_t)sf << 31 | (uint32_t)op << 30 | (uint32_t)S << 29 | (uint32_t)o[2].n << 16 | (uint32_t)opt << 13 | (uint32_t)amt << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
            return 1;
        }
        NEED(!o[0].sp && !o[1].sp && !o[2].sp && o[2].sf == sf, GXT("регистры не подходят"));
        int shift = np == 4 ? o[3].ext : 0;
        *out = 0x0B000000u | (uint32_t)sf << 31 | (uint32_t)op << 30 | (uint32_t)S << 29 | (uint32_t)shift << 22 | (uint32_t)o[2].n << 16 | (uint32_t)amt << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // логические
    static const char *lg[8] = {"and", "orr", "eor", "ands", "bic", "orn", "eon", "bics"};
    int lgi = -1;
    if (!strcmp(m, "tst")) { for (int j = np; j > 0; j--) o[j] = o[j - 1]; np++; memset(&o[0], 0, sizeof o[0]); o[0].kind = 1; o[0].n = 31; o[0].sf = o[1].sf; o[0].zr = 1; lgi = 3; }
    else if (!strcmp(m, "mvn")) { NEED(np >= 2, "mvn rd, rm"); for (int j = np; j > 1; j--) o[j] = o[j - 1]; np++; memset(&o[1], 0, sizeof o[1]); o[1].kind = 1; o[1].n = 31; o[1].sf = o[0].sf; o[1].zr = 1; lgi = 5; }
    else for (int j = 0; j < 8; j++) if (!strcmp(m, lg[j])) lgi = j;
    if (lgi >= 0) {
        NEED(np >= 3 && is_gp(&o[0]) && is_gp(&o[1]), GXT("%s rd, rn, операнд"), m);
        int sf = o[0].sf, opc = lgi & 3, Nn = lgi >> 2;
        if (is_imm(&o[2])) {
            NEED(!Nn, GXT("%s не бывает с числом"), m);
            uint32_t N, r, s;
            uint64_t v = (uint64_t)o[2].imm;
            if (!sf) v &= 0xFFFFFFFF;
            NEED(enc_bitmask(v, sf, &N, &r, &s), GXT("число нельзя закодировать как логическую маску"));
            *out = 0x12000000u | (uint32_t)sf << 31 | (uint32_t)opc << 29 | N << 22 | r << 16 | s << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
            return 1;
        }
        NEED(is_gp(&o[2]) && !o[2].sp && o[2].sf == sf, GXT("регистры не подходят"));
        int shift = 0, amt = 0;
        if (np == 4) { NEED(o[3].kind == 5 && o[3].ext <= 3, GXT("сдвиг: lsl/lsr/asr/ror")); shift = o[3].ext; amt = o[3].amt; }
        *out = 0x0A000000u | (uint32_t)sf << 31 | (uint32_t)opc << 29 | (uint32_t)shift << 22 | (uint32_t)Nn << 21 | (uint32_t)o[2].n << 16 | (uint32_t)amt << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // сдвиги
    if (!strcmp(m, "lsl") || !strcmp(m, "lsr") || !strcmp(m, "asr") || !strcmp(m, "ror")) {
        NEED(np == 3 && is_gp(&o[0]) && is_gp(&o[1]), "%s rd, rn, #N|rm", m);
        int sf = o[0].sf, size = sf ? 64 : 32;
        if (is_gp(&o[2])) {
            int opc = m[0] == 'l' ? (m[2] == 'l' ? 8 : 9) : m[0] == 'a' ? 10 : 11;
            *out = 0x1AC00000u | (uint32_t)sf << 31 | (uint32_t)o[2].n << 16 | (uint32_t)opc << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
            return 1;
        }
        NEED(is_imm(&o[2]) && o[2].imm >= 0 && o[2].imm < size, GXT("сдвиг 0…%d"), size - 1);
        uint32_t s = (uint32_t)o[2].imm, N = (uint32_t)sf;
        if (m[0] == 'r') { *out = 0x13800000u | (uint32_t)sf << 31 | N << 22 | (uint32_t)o[1].n << 16 | s << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n; return 1; }
        uint32_t immr, imms, opc;
        if (m[2] == 'l') { opc = 2; immr = (uint32_t)((size - (int)s) % size); imms = (uint32_t)(size - 1 - (int)s); }
        else { opc = m[0] == 'a' ? 0 : 2; immr = s; imms = (uint32_t)size - 1; }
        *out = 0x13000000u | (uint32_t)sf << 31 | opc << 29 | N << 22 | immr << 16 | imms << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "uxtb") || !strcmp(m, "uxth") || !strcmp(m, "sxtb") || !strcmp(m, "sxth") || !strcmp(m, "sxtw")) {
        NEED(np == 2 && is_gp(&o[0]) && is_gp(&o[1]) && !o[1].sf, "%s rd, wn", m);
        int sgn = m[0] == 's', sf = o[0].sf;
        NEED(sgn || !sf, GXT("%s: приёмник — w-регистр"), m);
        NEED(m[3] != 'w' || sf, GXT("sxtw: приёмник — x-регистр"));
        uint32_t imms = m[3] == 'b' ? 7 : m[3] == 'h' ? 15 : 31;
        *out = 0x13000000u | (uint32_t)sf << 31 | (sgn ? 0u : 2u) << 29 | (uint32_t)sf << 22 | imms << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // умножение и деление
    if (!strcmp(m, "mul") || !strcmp(m, "mneg") || !strcmp(m, "madd") || !strcmp(m, "msub") || !strcmp(m, "sdiv") || !strcmp(m, "udiv")
        || !strcmp(m, "smull") || !strcmp(m, "umull") || !strcmp(m, "smulh") || !strcmp(m, "umulh")) {
        NEED(np >= 3 && is_gp(&o[0]) && is_gp(&o[1]) && is_gp(&o[2]), "%s rd, rn, rm", m);
        int sf = o[0].sf;
        if (m[1] == 'd') { *out = 0x1AC00000u | (uint32_t)sf << 31 | (uint32_t)o[2].n << 16 | (m[0] == 'u' ? 2u : 3u) << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n; return 1; }
        int op31 = 0, o0 = 0, ra = 31;
        if (!strcmp(m, "madd") || !strcmp(m, "msub")) { NEED(np == 4 && is_gp(&o[3]), "%s rd, rn, rm, ra", m); ra = o[3].n; o0 = m[1] == 's'; }
        else if (!strcmp(m, "mneg")) o0 = 1;
        else if (!strcmp(m, "smull") || !strcmp(m, "umull")) { NEED(sf && !o[1].sf && !o[2].sf, "%s xd, wn, wm", m); op31 = m[0] == 's' ? 1 : 5; }
        else if (!strcmp(m, "smulh") || !strcmp(m, "umulh")) { NEED(sf, "%s xd, xn, xm", m); op31 = m[0] == 's' ? 2 : 6; }
        *out = 0x1B000000u | (uint32_t)sf << 31 | (uint32_t)op31 << 21 | (uint32_t)o[2].n << 16 | (uint32_t)o0 << 15 | (uint32_t)ra << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // условный выбор
    if (!strcmp(m, "csel") || !strcmp(m, "csinc") || !strcmp(m, "csinv") || !strcmp(m, "csneg")) {
        NEED(np == 4 && is_gp(&o[0]) && is_gp(&o[1]) && is_gp(&o[2]) && o[3].kind == 6, GXT("%s rd, rn, rm, условие"), m);
        int op = m[2] == 'i' && m[4] == 'v' ? 1 : m[2] == 'n' ? 1 : 0, o2 = !strcmp(m, "csinc") || !strcmp(m, "csneg");
        *out = 0x1A800000u | (uint32_t)o[0].sf << 31 | (uint32_t)op << 30 | (uint32_t)o[2].n << 16 | (uint32_t)o[3].cond << 12 | (uint32_t)o2 << 10 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "cset") || !strcmp(m, "csetm")) {
        NEED(np == 2 && is_gp(&o[0]) && o[1].kind == 6 && o[1].cond < 14, GXT("%s rd, условие"), m);
        *out = 0x1A9F03E0u | (uint32_t)o[0].sf << 31 | (m[4] == 'm' ? 1u : 0u) << 30 | (uint32_t)(o[1].cond ^ 1) << 12 | (m[4] == 'm' ? 0u : 1u) << 10 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "cinc") || !strcmp(m, "cneg")) {
        NEED(np == 3 && is_gp(&o[0]) && is_gp(&o[1]) && o[2].kind == 6 && o[2].cond < 14, GXT("%s rd, rn, условие"), m);
        *out = 0x1A800400u | (uint32_t)o[0].sf << 31 | (m[1] == 'n' ? 1u : 0u) << 30 | (uint32_t)o[1].n << 16 | (uint32_t)(o[2].cond ^ 1) << 12 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // пары регистров
    if (!strcmp(m, "ldp") || !strcmp(m, "stp") || !strcmp(m, "ldpsw")) {
        NEED(np == 3 && o[2].kind == 4 && o[2].mode != 3, "%s r1, r2, [xn{, #imm}]", m);
        NEED(o[0].kind == o[1].kind && (is_gp(&o[0]) || is_fp(&o[0])), GXT("регистры пары должны быть одного вида"));
        int V = is_fp(&o[0]), opc, sc;
        if (V) { NEED(o[0].ft == o[1].ft, GXT("одинаковые типы регистров")); opc = o[0].ft == 's' ? 0 : o[0].ft == 'd' ? 1 : o[0].ft == 'q' ? 2 : -1; NEED(opc >= 0, GXT("ldp/stp: s, d или q")); sc = 4 << opc; }
        else { NEED(o[0].sf == o[1].sf && !o[0].sp && !o[1].sp, GXT("регистры одного размера")); opc = !strcmp(m, "ldpsw") ? 1 : o[0].sf ? 2 : 0; sc = opc == 2 ? 8 : 4; }
        int64_t imm = o[2].imm;
        NEED(imm % sc == 0 && imm / sc >= -64 && imm / sc <= 63, GXT("смещение кратно %d в диапазоне %d…%d"), sc, -64 * sc, 63 * sc);
        int type = o[2].mode == 1 ? 3 : o[2].mode == 2 ? 1 : 2;
        *out = 0x28000000u | (uint32_t)opc << 30 | (uint32_t)V << 26 | (uint32_t)type << 23 | (m[0] == 'l' ? 1u : 0u) << 22 | ((uint32_t)(imm / sc) & 0x7F) << 15 | (uint32_t)o[1].n << 10 | (uint32_t)o[2].base << 5 | (uint32_t)o[0].n;
        return 1;
    }
    // загрузки/сохранения
    if (!strncmp(m, "ldr", 3) || !strncmp(m, "str", 3) || !strncmp(m, "ldur", 4) || !strncmp(m, "stur", 4)) {
        NEED(np == 2, GXT("%s reg, [адрес]"), m);
        return enc_ldst(m, &o[0], &o[1], rawp[1], pc, out, err, el);
    }
    // плавающая точка
    if (!strcmp(m, "fmov")) {
        NEED(np == 2, GXT("fmov приёмник, источник"));
        if (is_fp(&o[0]) && (o[1].kind == 7 || is_imm(&o[1]))) {
            NEED(o[0].ft == 's' || o[0].ft == 'd', GXT("fmov: s или d"));
            double v = o[1].kind == 7 ? o[1].f : (double)o[1].imm;
            if (v == 0.0) { *out = (o[0].ft == 'd' ? 0x9E6703E0u : 0x1E2703E0u) | (uint32_t)o[0].n; return 1; }   // fmov sN, wzr
            int k = enc_fpimm(v);
            NEED(k >= 0, GXT("fmov умеет только простые дроби (0.5, 1, 1.5, 2, 2.5, 3…31)"));
            *out = 0x1E201000u | ftype(o[0].ft) << 22 | (uint32_t)k << 13 | (uint32_t)o[0].n; return 1;
        }
        if (is_fp(&o[0]) && is_fp(&o[1])) { NEED(o[0].ft == o[1].ft && (o[0].ft == 's' || o[0].ft == 'd'), GXT("одинаковые s/d")); *out = 0x1E204000u | ftype(o[0].ft) << 22 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n; return 1; }
        if (is_fp(&o[0]) && is_gp(&o[1])) { NEED((o[0].ft == 's' && !o[1].sf) || (o[0].ft == 'd' && o[1].sf), GXT("fmov sN, wM или dN, xM")); *out = (o[1].sf ? 0x9E670000u : 0x1E270000u) | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n; return 1; }
        if (is_gp(&o[0]) && is_fp(&o[1])) { NEED((o[1].ft == 's' && !o[0].sf) || (o[1].ft == 'd' && o[0].sf), GXT("fmov wN, sM или xN, dM")); *out = (o[0].sf ? 0x9E660000u : 0x1E260000u) | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n; return 1; }
        ERR(GXT("неподходящие операнды fmov"));
    }
    static const char *f2[9] = {"fmul", "fdiv", "fadd", "fsub", "fmax", "fmin", "fmaxnm", "fminnm", "fnmul"};
    for (int j = 0; j < 9; j++) if (!strcmp(m, f2[j])) {
        NEED(np == 3 && is_fp(&o[0]) && is_fp(&o[1]) && is_fp(&o[2]) && o[0].ft == o[1].ft && o[1].ft == o[2].ft && (o[0].ft == 's' || o[0].ft == 'd'), GXT("%s sd, sn, sm (или d)"), m);
        *out = 0x1E200800u | ftype(o[0].ft) << 22 | (uint32_t)o[2].n << 16 | (uint32_t)j << 12 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "fabs") || !strcmp(m, "fneg") || !strcmp(m, "fsqrt") || !strcmp(m, "fcvt")) {
        NEED(np == 2 && is_fp(&o[0]) && is_fp(&o[1]), GXT("%s приёмник, источник"), m);
        uint32_t opc;
        if (m[1] == 'c') { NEED(o[0].ft != o[1].ft, GXT("fcvt: разные типы")); opc = o[0].ft == 's' ? 4 : o[0].ft == 'd' ? 5 : 7; }
        else { NEED(o[0].ft == o[1].ft, GXT("одинаковые типы")); opc = m[1] == 'a' ? 1 : m[1] == 'n' ? 2 : 3; }
        *out = 0x1E204000u | ftype(o[1].ft) << 22 | opc << 15 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "fcmp") || !strcmp(m, "fcmpe")) {
        NEED(np == 2 && is_fp(&o[0]), "%s sn, sm|#0.0", m);
        uint32_t e = m[4] == 'e' ? 16 : 0;
        if (is_fp(&o[1])) { NEED(o[0].ft == o[1].ft, GXT("одинаковые типы")); *out = 0x1E202000u | ftype(o[0].ft) << 22 | (uint32_t)o[1].n << 16 | (uint32_t)o[0].n << 5 | e; return 1; }
        NEED((o[1].kind == 7 || is_imm(&o[1])) && o[1].f == 0.0, GXT("сравнение только с #0.0"));
        *out = 0x1E202008u | ftype(o[0].ft) << 22 | (uint32_t)o[0].n << 5 | e;
        return 1;
    }
    if (!strcmp(m, "scvtf") || !strcmp(m, "ucvtf")) {
        NEED(np == 2 && is_fp(&o[0]) && is_gp(&o[1]), "%s sd, wn", m);
        *out = (m[0] == 'u' ? 0x1E230000u : 0x1E220000u) | (uint32_t)o[1].sf << 31 | ftype(o[0].ft) << 22 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "fcvtzs") || !strcmp(m, "fcvtzu")) {
        NEED(np == 2 && is_gp(&o[0]) && is_fp(&o[1]), "%s wd, sn", m);
        *out = (m[5] == 'u' ? 0x1E390000u : 0x1E380000u) | (uint32_t)o[0].sf << 31 | ftype(o[1].ft) << 22 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    if (!strcmp(m, "fcsel")) {
        NEED(np == 4 && is_fp(&o[0]) && is_fp(&o[1]) && is_fp(&o[2]) && o[3].kind == 6, GXT("fcsel sd, sn, sm, условие"));
        *out = 0x1E200C00u | ftype(o[0].ft) << 22 | (uint32_t)o[2].n << 16 | (uint32_t)o[3].cond << 12 | (uint32_t)o[1].n << 5 | (uint32_t)o[0].n;
        return 1;
    }
    ERR(GXT("неизвестная инструкция «%s»"), m);
}

int gx_asm(const char *text, uint64_t pc, uint32_t *out, int max, char *err, size_t errlen) {
    char buf[4096];
    snprintf(buf, sizeof buf, "%s", text);
    int n = 0, lineno = 0;
    char *save = NULL;
    for (char *ln = strtok_r(buf, ";\n", &save); ln; ln = strtok_r(NULL, ";\n", &save)) {
        lineno++;
        char *c = strstr(ln, "//"); if (c) *c = 0;
        char *t = ln; while (*t == ' ' || *t == '\t') t++;
        if (!*t) continue;
        if (n >= max) { snprintf(err, errlen, GXT("слишком много инструкций")); return 0; }
        char e[200] = {0};
        if (!enc_one(t, pc + (uint64_t)n * 4, &out[n], e, sizeof e)) { snprintf(err, errlen, "%s: %s", t, e); return 0; }
        n++;
    }
    if (!n) snprintf(err, errlen, GXT("пустой текст"));
    return n;
}

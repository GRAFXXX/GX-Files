#include "gx_tr.h"
#include "gx_pseudo.h"
#include "gx_a64.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>

#define EL 240

typedef struct { char *s; size_t n, cap; } sbuf;
static void out(sbuf *b, const char *fmt, ...) {
    va_list ap;
    for (;;) {
        size_t room = b->cap - b->n;
        va_start(ap, fmt);
        int k = vsnprintf(b->s ? b->s + b->n : NULL, b->s ? room : 0, fmt, ap);
        va_end(ap);
        if (k < 0) return;
        if (b->s && (size_t)k < room) { b->n += (size_t)k; return; }
        b->cap = (b->cap + (size_t)k + 64) * 2;
        b->s = realloc(b->s, b->cap);
    }
}

static uint32_t L32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

enum { K_NAME = 0, K_CONST = 1, K_ADDR = 2, K_EXPR = 3, K_LOAD = 4, K_IVOFF = 5 };

typedef struct {
    const gx_bin *b;
    uint64_t start, end;
    char e[32][EL]; uint8_t k[32]; uint64_t val[32];
    char f[32][EL]; uint8_t fk[32];
    uint32_t def, fdef;                 // записаны после последнего вызова (аргументы)
    char cl[EL], cr[EL]; int ck;        // последнее сравнение: 1 cmp, 2 tst, 3 fcmp, 4 cmn
    int lastx0, lasts0, idx;
    int vn;
    int objc, retkind;
    const gx_pivar *siv; int nsiv;
    const gx_pivar *aiv; int naiv;
    gx_namer namer; void *ctx;
    uint64_t *labels; size_t nlab;
    struct { int64_t off; char v[EL]; } pend[16]; int npend;   // аргументы на стеке (variadic)
    struct snap { uint64_t addr; char (*e)[EL]; uint8_t k[29]; uint64_t val[29]; uint32_t conflict; } *snaps; size_t nsnap, capsnap;
    int nofall;                         // предыдущая инструкция не передаёт управление дальше
    sbuf o;
} ps;

static void argname(ps *s, int r, char *buf) {
    if (s->objc && r == 0) strcpy(buf, "self");
    else if (s->objc && r == 1) strcpy(buf, "_cmd");
    else if (r < 8) sprintf(buf, "a%d", s->objc ? r - 1 : r + 1);
    else sprintf(buf, "x%d", r);
}
static void setname(ps *s, int r) { if (r < 31) { sprintf(s->e[r], "x%d", r); s->k[r] = K_NAME; } }
static void fsetname(ps *s, int r) { sprintf(s->f[r], "s%d", r); s->fk[r] = K_NAME; }

static const char *R(ps *s, int r) { return r == 31 ? "0" : s->e[r]; }

static int has_label(ps *s, uint64_t a) {
    size_t lo = 0, hi = s->nlab;
    while (lo < hi) { size_t m = (lo + hi) / 2; if (s->labels[m] < a) lo = m + 1; else hi = m; }
    return lo < s->nlab && s->labels[lo] == a;
}

static int cmp64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }

// приблизительный анализ чтения/записи регистров
static void rw(uint32_t w, uint32_t *R_, uint32_t *W_, uint32_t *FR, uint32_t *FW) {
    uint32_t r = 0, wr = 0, fr = 0, fw = 0;
    int rd = w & 31, rn = (w >> 5) & 31, rm = (w >> 16) & 31, ra = (w >> 10) & 31;
#define RD(x) do { if ((x) != 31) r |= 1u << (x); } while (0)
#define WR(x) do { if ((x) != 31) wr |= 1u << (x); } while (0)
    if ((w & 0x7C000000) == 0x14000000) { if (w >> 31) { r |= 0xFF; fr |= 0xFF; wr |= 0x7FFFF | 1u << 30; fw |= 0xFFFF00FFu; } }
    else if ((w & 0xFF000010) == 0x54000000) {}
    else if ((w & 0x7E000000) == 0x34000000 || (w & 0x7E000000) == 0x36000000) RD(rd);
    else if ((w & 0xFFFFFC1F) == 0xD65F0000 || w == 0xD65F0BFF || w == 0xD65F0FFF) { r |= 1; fr |= 1; }
    else if ((w & 0xFFFFFC1F) == 0xD63F0000 || (w & 0xFEFFF800) == 0xD63F0800) { RD(rn); r |= 0xFF; fr |= 0xFF; wr |= 0x7FFFF | 1u << 30; fw |= 0xFFFF00FFu; }
    else if ((w & 0xFFFFFC1F) == 0xD61F0000) RD(rn);
    else if ((w & 0x3A000000) == 0x28000000) {
        int v = (w >> 26) & 1, L = (w >> 22) & 1, rt2 = (w >> 10) & 31, ty = (w >> 23) & 3;
        RD(rn);
        if (v) { if (L) fw |= 1u << rd | 1u << rt2; else fr |= 1u << rd | 1u << rt2; }
        else { if (L) { WR(rd); WR(rt2); } else { RD(rd); RD(rt2); } }
        if (ty == 1 || ty == 3) WR(rn);
    }
    else if ((w & 0x3B000000) == 0x18000000) { if ((w >> 26) & 1) fw |= 1u << rd; else WR(rd); }
    else if ((w & 0x3A000000) == 0x38000000) {
        int v = (w >> 26) & 1, opc = (w >> 22) & 3, uimm = (w >> 24) & 1, regoff = !uimm && ((w >> 21) & 1);
        RD(rn);
        if (regoff) RD(rm);
        if (v) { if (opc & 1) fw |= 1u << rd; else fr |= 1u << rd; }
        else { if (opc) WR(rd); else RD(rd); }
        if (!uimm && !regoff && (((w >> 10) & 3) == 1 || ((w >> 10) & 3) == 3)) WR(rn);
    }
    else if ((w & 0x1F000000) == 0x10000000) WR(rd);
    else if ((w & 0x1F800000) == 0x12800000) { WR(rd); if (((w >> 29) & 3) == 3) RD(rd); }
    else if ((w & 0x1F000000) == 0x11000000 || (w & 0x1F800000) == 0x12000000 || (w & 0x1F800000) == 0x13000000) { RD(rn); WR(rd); if ((w & 0x1F800000) == 0x13000000 && ((w >> 29) & 3) == 1) RD(rd); }
    else if ((w & 0x1F000000) == 0x0A000000 || (w & 0x1F000000) == 0x0B000000 || (w & 0x1FE00000) == 0x1A800000 || (w & 0x5FE00000) == 0x1AC00000 || (w & 0x1FE00000) == 0x1A000000) { RD(rn); RD(rm); WR(rd); }
    else if ((w & 0x1F000000) == 0x1B000000) { RD(rn); RD(rm); RD(ra); WR(rd); }
    else if ((w & 0x1FE00400) == 0x1A400000) { RD(rn); if (!((w >> 11) & 1)) RD(rm); }
    else if ((w & 0x7FA00000) == 0x13800000) { RD(rn); RD(rm); WR(rd); }
    else if ((w & 0x5F000000) == 0x1E000000) {
        if ((w & 0x7F20FC00) == 0x1E200000) {
            int op = (w >> 16) & 7, rmode = (w >> 19) & 3;
            if (rmode == 0 && (op == 7 || op == 2 || op == 3)) { RD(rn); fw |= 1u << rd; }
            else { fr |= 1u << rn; WR(rd); }
        } else { fr |= 1u << rn | 1u << rm; fw |= 1u << rd; }
    }
#undef RD
#undef WR
    *R_ = r; *W_ = wr; *FR = fr; *FW = fw;
}

// читается ли регистр дальше до перезаписи (fp — регистр плавающей точки)
static int live_after(ps *s, uint64_t from, int reg, int fp) {
    for (uint64_t a = from, n = 0; a < s->end && n < 160; a += 4, n++) {
        int64_t off = gx_bin_a2o(s->b, a);
        if (off < 0 || (size_t)off + 4 > s->b->len) return 0;
        uint32_t w = L32(s->b->d + off), r, wr, fr, fw;
        rw(w, &r, &wr, &fr, &fw);
        uint32_t rm = fp ? fr : r, wm = fp ? fw : wr;
        if (rm >> reg & 1) return 1;
        if (wm >> reg & 1) return 0;
        if ((w & 0xFC000000) == 0x14000000) {               // безусловный переход: идём по нему
            uint64_t t = a + (uint64_t)(((int64_t)((w & 0x3FFFFFF) ^ 0x2000000) - 0x2000000) * 4);
            if (t < s->start || t >= s->end) return reg < 8 && !fp ? 1 : 0;   // хвостовой вызов читает аргументы
            a = t - 4;
            continue;
        }
        if ((w & 0xFFFFFC1F) == 0xD61F0000) return 1;
    }
    return 0;
}

static void emit(ps *s, const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    out(&s->o, "    %s\n", buf);
}

static int is_callee(int r) { return r >= 19 && r <= 28; }

static void emit_pending(ps *s) {
    for (int i = 0; i < s->npend; i++) {
        int64_t o = s->pend[i].off;
        if (o < 0) emit(s, "sp_m%llx = %s;", (unsigned long long)-o, s->pend[i].v);
        else emit(s, "sp_%llx = %s;", (unsigned long long)o, s->pend[i].v);
    }
    s->npend = 0;
}
static void store_sp(ps *s, int64_t off, const char *v) {
    for (int i = 0; i < s->npend; i++) if (s->pend[i].off == off) { snprintf(s->pend[i].v, EL, "%s", v); return; }
    if (s->npend == 16) emit_pending(s);
    s->pend[s->npend].off = off;
    snprintf(s->pend[s->npend].v, EL, "%s", v);
    s->npend++;
}
static const char *pending_at(ps *s, int64_t off) {
    for (int i = 0; i < s->npend; i++) if (s->pend[i].off == off) return s->pend[i].v;
    return NULL;
}
static int cmp_pend(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return x < y ? -1 : x > y; }
// дописать стековые аргументы variadic-вызова
static void append_varargs(ps *s, char *call, size_t n) {
    if (!s->npend) return;
    qsort(s->pend, (size_t)s->npend, sizeof s->pend[0], cmp_pend);
    size_t k = strlen(call);
    int close = k && (call[k - 1] == ')' || call[k - 1] == ']');
    char endc = close ? call[k - 1] : 0;
    if (close) call[--k] = 0;
    for (int i = 0; i < s->npend && k < n; i++) k += (size_t)snprintf(call + k, n - k, ", %s", s->pend[i].v);
    if (endc && k + 1 < n) { call[k++] = endc; call[k] = 0; }
    s->npend = 0;
}
static int is_variadic(const char *name) {
    return strstr(name, "printf") || strstr(name, "Log") || strstr(name, "ormat") || strstr(name, "scanf");
}

// записать значение в регистр: временные — подстановкой, сохраняемые — оператором присваивания
static void assign(ps *s, int r, const char *expr, int kind, uint64_t val) {
    if (r == 31) return;
    char tmp[EL];
    snprintf(tmp, sizeof tmp, "%s", expr);
    if (is_callee(r) && (kind == K_CONST || kind == K_EXPR || kind == K_LOAD)) {
        char nm[8]; sprintf(nm, "x%d", r);
        if (strcmp(tmp, nm)) emit(s, "%s = %s;", nm, tmp);
        setname(s, r);
        return;
    }
    if (strlen(tmp) > 110 && kind != K_ADDR) {    // слишком длинное — выносим во временную
        int v = ++s->vn;
        emit(s, "v%d = %s;", v, tmp);
        snprintf(tmp, sizeof tmp, "v%d", v);
        kind = K_NAME;
    }
    memcpy(s->e[r], tmp, EL);
    s->k[r] = (uint8_t)kind; s->val[r] = val;
    if (r < 8) s->def |= 1u << r;
    if (r == 0) s->lastx0 = s->idx;
}
static void fassign(ps *s, int r, const char *expr, int kind) {
    snprintf(s->f[r], EL, "%s", expr);
    s->fk[r] = (uint8_t)kind;
    if (r < 8) s->fdef |= 1u << r;
    if (r == 0) s->lasts0 = s->idx;
}

// перед сохранением в память / вызовом — материализуем загруженные значения временных регистров
static void flush_loads(ps *s, uint64_t next) {
    for (int r = 0; r < 19; r++) if (s->k[r] == K_LOAD && live_after(s, next, r, 0)) {
        int v = ++s->vn;
        emit(s, "v%d = %s;", v, s->e[r]);
        sprintf(s->e[r], "v%d", v);
        s->k[r] = K_NAME;
    }
}

static int is_canon(ps *s, int r) {
    char nm[8]; sprintf(nm, "x%d", r);
    if (!strcmp(s->e[r], nm)) return 1;
    if (s->k[r] == K_NAME) for (int q = 0; q < 8; q++) { char an[16]; argname(s, q, an); if (!strcmp(s->e[r], an)) return 1; }   // значение аргумента со входа (self и т.п.)
    return s->k[r] == K_ADDR || s->k[r] == K_IVOFF;
}
// перед переходом на метку: живые на метке регистры приводим к именам xN — на всех входах одинаково
static void sync_to(ps *s, uint64_t target) {
    for (int r = 0; r < 29; r++) {
        if (is_canon(s, r) || !live_after(s, target, r, 0)) continue;
        char nm[8]; sprintf(nm, "x%d", r);
        emit(s, "%s = %s;", nm, s->e[r]);
        setname(s, r);
    }
}
static struct snap *find_snap(ps *s, uint64_t a) {
    for (size_t i = 0; i < s->nsnap; i++) if (s->snaps[i].addr == a) return &s->snaps[i];
    return NULL;
}
// запомнить состояние регистров на ребре перехода вперёд
static void record_edge(ps *s, uint64_t pc, uint64_t target) {
    if (target <= pc) return;
    struct snap *sn = find_snap(s, target);
    if (!sn) {
        if (s->nsnap >= 1024) return;
        if (s->nsnap == s->capsnap) { s->capsnap = s->capsnap ? s->capsnap * 2 : 32; s->snaps = realloc(s->snaps, sizeof(struct snap) * s->capsnap); }
        sn = &s->snaps[s->nsnap++];
        memset(sn, 0, sizeof *sn);
        sn->addr = target;
        sn->e = malloc(sizeof(char[EL]) * 29);
        for (int r = 0; r < 29; r++) { memcpy(sn->e[r], s->e[r], EL); sn->k[r] = s->k[r]; sn->val[r] = s->val[r]; }
        return;
    }
    for (int r = 0; r < 29; r++) if (strcmp(sn->e[r], s->e[r]) || sn->k[r] != s->k[r]) sn->conflict |= 1u << r;
}
// на метке значения могут прийти с разных путей
static void at_label(ps *s, uint64_t a) {
    struct snap *sn = find_snap(s, a);
    if (!s->nofall) { emit_pending(s); sync_to(s, a); }
    else s->npend = 0;
    if (sn && s->nofall) {
        for (int r = 0; r < 29; r++) {
            if (sn->conflict >> r & 1) { setname(s, r); continue; }
            memcpy(s->e[r], sn->e[r], EL); s->k[r] = sn->k[r]; s->val[r] = sn->val[r];
        }
    } else if (sn) {
        for (int r = 0; r < 29; r++) if ((sn->conflict >> r & 1) || strcmp(sn->e[r], s->e[r]) || sn->k[r] != s->k[r]) setname(s, r);
    } else {
        // цель только обратных переходов (начало цикла): временные — к именам
        for (int r = 0; r < (s->nofall ? 29 : 19); r++) {
            char an[16];
            if (r < 8) { argname(s, r, an); if (!strcmp(s->e[r], an)) continue; }
            if (s->k[r] == K_ADDR || s->k[r] == K_IVOFF) continue;
            setname(s, r);
        }
    }
    s->ck = 0;
}

static const char *ctype(int size, int fp) {
    if (fp) return size == 4 ? "float" : size == 8 ? "double" : size == 2 ? "__fp16" : "__int128";
    return size == 1 ? "uint8_t" : size == 2 ? "uint16_t" : size == 4 ? "int" : size == 8 ? "long" : "__int128";
}

static const char *iv_by_off(ps *s, uint64_t off) {
    for (int i = 0; i < s->nsiv; i++) if (s->siv[i].off == off) return s->siv[i].name;
    return NULL;
}
static const char *iv_by_slot(ps *s, uint64_t a, uint32_t *off) {
    for (int i = 0; i < s->naiv; i++) if (s->aiv[i].slot == a) { *off = s->aiv[i].off; return s->aiv[i].name; }
    return NULL;
}

// имя для адреса в данных
static void gname(ps *s, uint64_t a, char *out, size_t n, int deref) {
    char d[EL];
    if (gx_bin_describe(s->b, a, d, sizeof d)) {
        if (deref && d[0] == '&') snprintf(out, n, "%s", d);            // слот GOT: загружается адрес символа
        else if (deref && (d[0] == '"' || (d[0] == '@' && d[1] == '"'))) snprintf(out, n, "*(long *)%s", d);
        else snprintf(out, n, "%s", d);
        return;
    }
    snprintf(out, n, deref ? "g_%llx" : "&g_%llx", (unsigned long long)a);
}

// операнд памяти [base + off]
static void memop(ps *s, int rn, int64_t off, int size, int fp, char *out, size_t n) {
    if (rn == 31) { if (off < 0) snprintf(out, n, "sp_m%llx", (unsigned long long)-off); else snprintf(out, n, "sp_%llx", (unsigned long long)off); return; }
    if (rn == 29) { if (off < 0) snprintf(out, n, "fp_m%llx", (unsigned long long)-off); else snprintf(out, n, "fp_%llx", (unsigned long long)off); return; }
    if (s->k[rn] == K_ADDR) { gname(s, s->val[rn] + (uint64_t)off, out, n, 1); return; }
    const char *base = R(s, rn);
    if (!strcmp(base, "self") && off >= 0) { const char *iv = iv_by_off(s, (uint64_t)off); if (iv) { snprintf(out, n, "self->%s", iv); return; } }
    if (!off && base[0] == '&' && !strpbrk(base, " +-*()")) { snprintf(out, n, "%s", base + 1); return; }   // *&x → x
    if (off) snprintf(out, n, "*(%s *)(%s + 0x%llx)", ctype(size, fp), base, (unsigned long long)off);
    else snprintf(out, n, "*(%s *)%s", ctype(size, fp), base);
}

static void condstr(ps *s, int cc, char *out, size_t n) {
    static const char *op[16] = {"==", "!=", ">=", "<", "<", ">=", "?", "?", ">", "<=", ">=", "<", ">", "<=", "1", "1"};
    if (cc >= 14) { snprintf(out, n, "1"); return; }
    if (!s->ck) { static const char *nm[14] = {"eq","ne","hs","lo","mi","pl","vs","vc","hi","ls","ge","lt","gt","le"}; snprintf(out, n, "cond_%s", nm[cc]); return; }
    if (s->ck == 2) {
        const char *x = cc == 0 ? "!(%s & %s)" : cc == 1 ? "(%s & %s)" : cc == 4 ? "(%s & %s) < 0" : cc == 5 ? "(%s & %s) >= 0" : "(%s & %s) ?";
        snprintf(out, n, x, s->cl, s->cr);
        return;
    }
    if (cc == 6 || cc == 7) { snprintf(out, n, "%s(%s, %s)", cc == 6 ? "overflow" : "!overflow", s->cl, s->cr); return; }
    if (s->ck == 4) { snprintf(out, n, "%s %s -(%s)", s->cl, op[cc], s->cr); return; }
    const char *u = (cc == 2 || cc == 3 || cc == 8 || cc == 9) && s->ck == 1 ? "(unsigned)" : "";
    snprintf(out, n, "%s%s %s %s", u, s->cl, op[cc], s->cr);
}

static void lab(char *out, uint64_t a) { sprintf(out, "loc_%llx", (unsigned long long)a); }

static int sel_args(const char *sel) { int n = 0; for (; *sel; sel++) if (*sel == ':') n++; return n; }

// [recv a:x b:y]
static void objc_call(ps *s, const char *recv, const char *sel, int firstarg, char *out, size_t n) {
    size_t k = (size_t)snprintf(out, n, "[%s ", recv);
    int ai = firstarg, fi = 0;
    if (!strchr(sel, ':')) k += (size_t)snprintf(out + k, k < n ? n - k : 0, "%s", sel);
    else {
        const char *p = sel; int first = 1;
        while (*p && k < n) {
            const char *c = strchr(p, ':');
            if (!c) break;
            const char *arg;
            if (ai < 8 && !(s->def >> ai & 1) && fi < 8 && (s->fdef >> fi & 1)) arg = s->f[fi++];   // аргумент float/double
            else { arg = ai < 8 ? R(s, ai) : "?"; ai++; }
            k += (size_t)snprintf(out + k, k < n ? n - k : 0, "%s%.*s:%s", first ? "" : " ", (int)(c - p), p, arg);
            first = 0; p = c + 1;
        }
    }
    if (k < n) snprintf(out + k, n - k, "]");
}

static int strip_us(const char *n) { return n[0] == '_' && n[1] != '_' && n[1] != 'Z' ? 1 : 0; }

// сформировать вызов; target==0 — косвенный через R(ireg). Возвращает 1 если «прозрачный» (retain и т.п.)
static int make_call(ps *s, uint64_t target, int ireg, char *call, size_t n) {
    char nm[EL] = "", tmp[EL];
    if (target) {
        if (gx_bin_describe(s->b, target, tmp, sizeof tmp) && gx_bin_import_at(s->b, target)) snprintf(nm, sizeof nm, "%s", tmp);
        else if (s->namer && s->namer(s->ctx, target, tmp, sizeof tmp)) snprintf(nm, sizeof nm, "%s", tmp);
        else snprintf(nm, sizeof nm, "sub_%llx", (unsigned long long)target);
    } else snprintf(nm, sizeof nm, "((void *(*)())%s)", R(s, ireg));
    const char *f = nm + (target ? strip_us(nm) : 0);
    // Objective-C
    if (!strcmp(f, "objc_msgSend") || !strcmp(f, "objc_msgSendSuper2") || !strcmp(f, "objc_msgSendSuper")) {
        const char *sl = R(s, 1);
        const char *recv = !strcmp(f, "objc_msgSend") ? R(s, 0) : "super";
        if (!strncmp(sl, "@selector(", 10)) {
            char sel[EL]; snprintf(sel, sizeof sel, "%s", sl + 10);
            size_t l = strlen(sel); if (l && sel[l - 1] == ')') sel[l - 1] = 0;
            objc_call(s, recv, sel, 2, call, n);
        } else snprintf(call, n, "objc_msgSend(%s, %s, ...)", recv, sl);
        return 0;
    }
    if (!strncmp(f, "objc_msgSend$", 13)) { objc_call(s, R(s, 0), f + 13, 2, call, n); return 0; }
    static const char *pass[] = {"objc_retain", "objc_retainAutoreleasedReturnValue", "objc_claimAutoreleasedReturnValue", "objc_unsafeClaimAutoreleasedReturnValue",
        "objc_autoreleaseReturnValue", "objc_retainAutorelease", "objc_autorelease", "objc_retainBlock", "objc_retainAutoreleaseReturnValue", "swift_retain", "swift_bridgeObjectRetain", NULL};
    for (int i = 0; pass[i]; i++) if (!strcmp(f, pass[i]) || (!strncmp(f, "objc_retain_x", 13) && i == 0)) return 1;
    static const char *drop[] = {"objc_release", "swift_release", "swift_bridgeObjectRelease", NULL};
    for (int i = 0; drop[i]; i++) if (!strcmp(f, drop[i]) || !strncmp(f, "objc_release_x", 14)) return 2;
    if (!strcmp(f, "objc_alloc")) { snprintf(call, n, "[%s alloc]", R(s, 0)); return 0; }
    if (!strcmp(f, "objc_alloc_init")) { snprintf(call, n, "[[%s alloc] init]", R(s, 0)); return 0; }
    if (!strcmp(f, "objc_opt_new")) { snprintf(call, n, "[%s new]", R(s, 0)); return 0; }
    if (!strcmp(f, "objc_opt_class")) { snprintf(call, n, "[%s class]", R(s, 0)); return 0; }
    if (!strcmp(f, "objc_opt_isKindOfClass")) { snprintf(call, n, "[%s isKindOfClass:%s]", R(s, 0), R(s, 1)); return 0; }
    if (!strcmp(f, "objc_opt_respondsToSelector")) { snprintf(call, n, "[%s respondsToSelector:%s]", R(s, 0), R(s, 1)); return 0; }
    if (!strcmp(f, "objc_storeStrong")) {
        const char *d = R(s, 0);
        if (d[0] == '&') snprintf(call, n, "%s = %s", d + 1, R(s, 1)); else snprintf(call, n, "*(id *)(%s) = %s", d, R(s, 1));
        return 3;
    }
    // обычная функция: аргументы — подряд записанные x0.. и v0..
    int na = 0; for (int i = 0; i < 8; i++) if (s->def >> i & 1) na = i + 1;
    int nf = 0; for (int i = 0; i < 8; i++) if (s->fdef >> i & 1) nf = i + 1;
    if (s->npend && is_variadic(f)) {   // variadic: регистровые аргументы — до строки формата включительно
        for (int i = 0; i < na; i++) { const char *x = R(s, i); if (x[0] == '"' || (x[0] == '@' && x[1] == '"')) { na = i + 1; break; } }
        nf = 0;
    }
    size_t k = (size_t)snprintf(call, n, "%s(", f);
    for (int i = 0; i < na && k < n; i++) k += (size_t)snprintf(call + k, n - k, "%s%s", i ? ", " : "", R(s, i));
    for (int i = 0; i < nf && k < n; i++) k += (size_t)snprintf(call + k, n - k, "%s%s", (i || na) ? ", " : "", s->f[i]);
    if (k < n) snprintf(call + k, n - k, ")");
    return 0;
}

static void after_call(ps *s, uint64_t next, const char *call, int transparent, int is_tail) {
    if (is_tail) { if (s->retkind == 1) { emit(s, "%s;", call); emit(s, "return;"); } else emit(s, "return %s;", call); }
    else if (transparent == 1) {
        // x0 остаётся прежним
    } else if (transparent == 2) {
        // release — пропускаем
    } else if (transparent == 3) {
        emit(s, "%s;", call);
    } else {
        int lx = live_after(s, next, 0, 0), lf = !lx && (live_after(s, next, 0, 1) || live_after(s, next, 1, 1) || live_after(s, next, 2, 1) || live_after(s, next, 3, 1));
        if (lx || lf) {
            int v = ++s->vn;
            emit(s, "v%d = %s;", v, call);
            char nm[16]; sprintf(nm, "v%d", v);
            for (int r = 1; r < 19; r++) setname(s, r);
            int nfl = 0;   // сколько float-регистров результата живы (CGRect → 4, CGSize/CGPoint → 2)
            if (lf) { nfl = 1; for (int r = 1; r < 4; r++) if (live_after(s, next, r, 1)) nfl = r + 1; }
            if (lx) { memcpy(s->e[0], nm, sizeof nm); s->k[0] = K_NAME; }
            else {
                setname(s, 0);
                if (nfl > 1) for (int r = 0; r < nfl; r++) { snprintf(s->f[r], EL, "%s[%d]", nm, r); s->fk[r] = K_NAME; }
                else { snprintf(s->f[0], EL, "%s", nm); s->fk[0] = K_NAME; }
            }
            for (int r = lf ? (nfl > 1 ? nfl : 1) : 0; r < 8; r++) fsetname(s, r);
            for (int r = 16; r < 32; r++) fsetname(s, r);
            s->def = 0; s->fdef = 0; s->ck = 0;
            s->lastx0 = lx ? s->idx : s->lastx0; s->lasts0 = lf ? s->idx : s->lasts0;
            return;
        }
        emit(s, "%s;", call);
    }
    if (transparent != 1) setname(s, 0);
    for (int r = 1; r < 19; r++) setname(s, r);
    for (int r = 0; r < 8; r++) fsetname(s, r);
    for (int r = 16; r < 32; r++) fsetname(s, r);
    s->def = transparent == 1 ? 1 : 0; s->fdef = 0; s->ck = 0;
}

static void fmt_num(char *o, size_t n, uint64_t v, int sf) {
    int64_t sv = sf ? (int64_t)v : (int64_t)(int32_t)(uint32_t)v;
    if (sv >= -9999 && sv <= 9999) snprintf(o, n, "%lld", (long long)sv);
    else if (sv < 0 && sv > -0x10000) snprintf(o, n, "-0x%llx", (unsigned long long)-sv);
    else snprintf(o, n, "0x%llx", (unsigned long long)(sf ? v : (uint32_t)v));
}

static void do_ins(ps *s, uint64_t pc, uint32_t w) {
    char a[EL * 2], b2[EL], c[EL];
    int rd = w & 31, rn = (w >> 5) & 31, rm = (w >> 16) & 31, sf = w >> 31;
    uint64_t next = pc + 4, t;
    char dis[160];
    int kind = gx_a64_dis(w, pc, dis, sizeof dis, &t);

    // пролог/эпилог и служебное
    if ((w & 0xFFFFF01F) == 0xD503201F) return;                                     // nop, pac, bti
    if ((w & 0x3A000000) == 0x28000000 && (rn == 31 || rn == 29) && !((w >> 26) & 1)) {   // stp/ldp на стеке
        int L = (w >> 22) & 1, rt2 = (w >> 10) & 31;
        int64_t imm = ((int64_t)(((w >> 15) & 0x7F) ^ 0x40) - 0x40) * ((w >> 31) ? 8 : 4);
        int ty = (w >> 23) & 3;
        if (ty == 2 && rn == 31 && rd != 29 && rd != 30 && !is_callee(rd)) {   // локальные переменные
            char m1[64], m2[64];
            snprintf(m1, sizeof m1, "sp_%llx", (unsigned long long)imm); snprintf(m2, sizeof m2, "sp_%llx", (unsigned long long)(imm + ((w >> 31) ? 8 : 4)));
            if (L) { assign(s, rd, m1, K_LOAD, 0); assign(s, rt2, m2, K_LOAD, 0); }
            else { store_sp(s, imm, R(s, rd)); store_sp(s, imm + ((w >> 31) ? 8 : 4), R(s, rt2)); }
        } else if (L) {
            // восстановление сохранённых регистров — без вывода
            if (rd < 31 && !is_callee(rd) && rd != 29 && rd != 30) setname(s, rd);
        }
        return;
    }
    if ((w & 0x3A000000) == 0x28000000 && (rn == 31 || rn == 29) && ((w >> 26) & 1) && rd >= 8 && rd <= 15) return;   // сохранение d8–d15
    if ((w & 0x3A000000) == 0x38000000 && (rn == 31 || rn == 29) && ((w >> 26) & 1) && rd >= 8 && rd <= 15 && ((w >> 30) == 3)) return;
    if ((w & 0xFF8003FF) == 0x910003FD || (w & 0xFFFFFFFF) == 0x910003FD) return;   // add x29, sp, #
    if ((w & 0x7F8003FF) == 0x510003FF || (w & 0x7F8003FF) == 0x110003FF) return;   // sub/add sp, sp, #
    if (w == 0xAA1D03FD) return;   // mov x29, x29 (маркер ARC)

    // переходы
    if (kind == GX_A64_CALL) {
        flush_loads(s, next);
        char call[EL * 3];
        int tr = make_call(s, t, 0, call, sizeof call);
        if (s->npend && is_variadic(call)) append_varargs(s, call, sizeof call); else emit_pending(s);
        after_call(s, next, call, tr, 0);
        return;
    }
    if ((w & 0xFFFFFC1F) == 0xD63F0000 || (w & 0xFEFFF800) == 0xD63F0800) {
        flush_loads(s, next);
        char call[EL * 2];
        make_call(s, 0, rn, call, sizeof call);
        after_call(s, next, call, 0, 0);
        return;
    }
    if (kind == GX_A64_BRANCH) {
        emit_pending(s);
        if (t >= s->start && t < s->end) { sync_to(s, t); record_edge(s, pc, t); lab(a, t); emit(s, "goto %s;", a); s->nofall = 1; return; }
        else { flush_loads(s, next); char call[EL * 3]; int tr = make_call(s, t, 0, call, sizeof call); if (s->npend && is_variadic(call)) append_varargs(s, call, sizeof call); else emit_pending(s); if (tr == 1 || tr == 2) { if (s->retkind == 1) emit(s, "return;"); else emit(s, "return %s;", R(s, 0)); } else after_call(s, next, call, 0, 1); s->nofall = 1; }
        return;
    }
    if (kind == GX_A64_RET && ((w & 0xFFFFFC1F) == 0xD61F0000)) { emit(s, GXT("goto *%s;   // таблица переходов / хвостовой вызов"), R(s, rn)); s->nofall = 1; return; }
    if (kind == GX_A64_RET) {
        s->nofall = 1;
        emit_pending(s);
        if (s->retkind == 1) { emit(s, "return;"); return; }
        if (s->retkind == 3) { emit(s, "return %s;", R(s, 0)); return; }
        if (s->retkind == 2 || s->lasts0 > s->lastx0) {
            int nf = 1; while (nf < 4 && (s->fdef >> nf & 1)) nf++;
            if (nf > 1) {   // структура из float/double (CGRect, CGPoint, CGSize)
                char r[EL * 4]; size_t k = (size_t)snprintf(r, sizeof r, "{ %s", s->f[0]);
                for (int i = 1; i < nf && k < sizeof r; i++) k += (size_t)snprintf(r + k, sizeof r - k, ", %s", s->f[i]);
                emit(s, "return %s };", r);
            } else emit(s, "return %s;", s->f[0]);
        }
        else if (s->lastx0 >= 0) emit(s, "return %s;", R(s, 0));
        else emit(s, "return;");
        return;
    }
    if (kind == GX_A64_COND) {
        char cond[EL * 2];
        if ((w & 0xFF000010) == 0x54000000) condstr(s, w & 15, cond, sizeof cond);
        else if ((w & 0x7E000000) == 0x34000000) snprintf(cond, sizeof cond, (w >> 24) & 1 ? "%s" : "!%s", R(s, rd));
        else { int bit = (int)(((w >> 31) << 5) | ((w >> 19) & 31)); snprintf(cond, sizeof cond, (w >> 24) & 1 ? "%s & 0x%llx" : "!(%s & 0x%llx)", R(s, rd), (unsigned long long)1 << bit); }
        emit_pending(s);
        if (t >= s->start && t < s->end) { sync_to(s, t); record_edge(s, pc, t); lab(a, t); emit(s, "if (%s) goto %s;", cond, a); }
        else emit(s, "if (%s) return sub_%llx();", cond, (unsigned long long)t);
        return;
    }

    int ad; uint64_t pg, imm;
    if (gx_a64_is_adrp(w, pc, &ad, &pg)) { sprintf(a, "0x%llx", (unsigned long long)pg); assign(s, ad, a, K_ADDR, pg); return; }
    if (kind == GX_A64_ADR) { gname(s, t, a, sizeof a, 0); assign(s, rd, a, K_ADDR, t); s->val[rd] = t; s->k[rd] = K_ADDR; return; }
    if (kind == GX_A64_LIT) {
        int fp = (w >> 26) & 1;
        uint32_t ivo; const char *ivn = fp ? NULL : iv_by_slot(s, t, &ivo);
        if (ivn) { assign(s, rd, ivn, K_IVOFF, ivo); if (rd != 31) s->k[rd] = K_IVOFF; return; }
        gname(s, t, a, sizeof a, 1);
        if (fp) fassign(s, rd, a, K_LOAD);
        else {
            int k = (!strncmp(a, "@selector(", 10) || (a[0] != 'g' && a[0] != '*')) ? K_NAME : K_LOAD;
            assign(s, rd, a, k, 0);
        }
        return;
    }

    // ADD/SUB imm, CMP
    if ((w & 0x1F800000) == 0x11000000) {
        int op = (w >> 30) & 1, S = (w >> 29) & 1;
        imm = (w >> 10) & 0xFFF; if ((w >> 22) & 1) imm <<= 12;
        if (S && rd == 31) { snprintf(s->cl, EL, "%s", R(s, rn)); fmt_num(s->cr, EL, imm, sf); s->ck = op ? 1 : 4; return; }
        if (rn == 31 || rn == 29) {   // адрес локальной переменной
            snprintf(a, sizeof a, "&%s_%llx", rn == 31 ? "sp" : "fp", (unsigned long long)imm);
            assign(s, rd, a, K_NAME, 0);
            return;
        }
        if (s->k[rn] == K_ADDR && !op) {
            uint64_t ab = s->val[rn] + imm;
            gname(s, ab, a, sizeof a, 0);
            assign(s, rd, a, K_ADDR, ab);
            s->val[rd] = ab; s->k[rd] = K_ADDR;
            return;
        }
        if (s->k[rn] == K_CONST) { uint64_t v = op ? s->val[rn] - imm : s->val[rn] + imm; if (!sf) v &= 0xFFFFFFFF; fmt_num(a, sizeof a, v, sf); assign(s, rd, a, K_CONST, v); s->val[rd] = v; return; }
        char num[40]; fmt_num(num, sizeof num, imm, sf);
        if (rd == rn && is_callee(rd)) { emit(s, "x%d %s= %s;", rd, op ? "-" : "+", num); return; }
        snprintf(a, sizeof a, "%s %s %s", R(s, rn), op ? "-" : "+", num);
        if (S) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", num); s->ck = op ? 1 : 4; }
        assign(s, rd, a, K_EXPR, 0);
        return;
    }
    // MOVZ/MOVN/MOVK
    if ((w & 0x1F800000) == 0x12800000) {
        int opc = (w >> 29) & 3, hw = (w >> 21) & 3;
        uint64_t v = (uint64_t)((w >> 5) & 0xFFFF) << (16 * hw);
        if (opc == 0) v = ~v;
        if (opc == 3) { uint64_t cur = s->k[rd] == K_CONST ? s->val[rd] : 0; v = (cur & ~(0xFFFFull << (16 * hw))) | v; }
        if (!sf) v &= 0xFFFFFFFF;
        fmt_num(a, sizeof a, v, sf);
        assign(s, rd, a, K_CONST, v);
        if (rd != 31) s->val[rd] = v;
        return;
    }
    // логические с immediate
    if ((w & 0x1F800000) == 0x12000000) {
        int opc = (w >> 29) & 3;
        char *p = strchr(dis, '#');
        const char *im = p ? p + 1 : "?";
        if (opc == 1 && rn == 31) { assign(s, rd, im, K_CONST, strtoull(im, NULL, 0)); if (rd != 31) s->val[rd] = strtoull(im, NULL, 0); return; }
        if (opc == 3 && rd == 31) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", im); s->ck = 2; return; }
        static const char *op[4] = {"&", "|", "^", "&"};
        snprintf(a, sizeof a, "%s %s %s", R(s, rn), op[opc], im);
        if (opc == 3) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", im); s->ck = 2; }
        assign(s, rd, a, K_EXPR, 0);
        return;
    }
    // логические с регистром (в т.ч. mov)
    if ((w & 0x1F000000) == 0x0A000000) {
        int opc = (w >> 29) & 3, N = (w >> 21) & 1, sh = (w >> 22) & 3, amt = (w >> 10) & 63;
        if (opc == 1 && !N && rn == 31 && !amt) {   // mov
            if (rm == 31) { assign(s, rd, "0", K_CONST, 0); if (rd != 31) s->val[rd] = 0; return; }
            int k = s->k[rm];
            if (is_callee(rd) && (k == K_NAME || k == K_ADDR)) { memcpy(s->e[rd], s->e[rm], EL); s->k[rd] = (uint8_t)k; s->val[rd] = s->val[rm]; return; }
            assign(s, rd, R(s, rm), k, s->val[rm]);
            if (rd != 31) s->val[rd] = s->val[rm];
            return;
        }
        static const char *shn[4] = {"<<", ">>", ">>", "ror"};
        if (amt) snprintf(b2, sizeof b2, "(%s %s %d)", R(s, rm), shn[sh], amt); else snprintf(b2, sizeof b2, "%s", R(s, rm));
        if (N) { snprintf(c, sizeof c, "~%s", b2); memcpy(b2, c, EL); }
        if (opc == 3 && rd == 31) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", b2); s->ck = 2; return; }
        if (opc == 1 && rn == 31) { assign(s, rd, b2, K_EXPR, 0); return; }
        static const char *op[4] = {"&", "|", "^", "&"};
        snprintf(a, sizeof a, "(%s %s %s)", R(s, rn), op[opc], b2);
        if (opc == 3) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", b2); s->ck = 2; }
        assign(s, rd, a, K_EXPR, 0);
        return;
    }
    // ADD/SUB со сдвинутым или расширенным регистром
    if ((w & 0x1F000000) == 0x0B000000) {
        int op = (w >> 30) & 1, S = (w >> 29) & 1, amt = (w >> 10) & 63;
        if ((w >> 21) & 1) amt = (w >> 10) & 7;
        if (amt) snprintf(b2, sizeof b2, "(%s << %d)", R(s, rm), amt); else snprintf(b2, sizeof b2, "%s", R(s, rm));
        if (S && rd == 31) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", b2); s->ck = op ? 1 : 4; return; }
        if (s->k[rm] == K_IVOFF && !op) {   // self + смещение ivar
            snprintf(a, sizeof a, "&%s->%s", R(s, rn), s->e[rm]);
            assign(s, rd, a, K_EXPR, 0);
            return;
        }
        if (op && rn == 31) snprintf(a, sizeof a, "-%s", b2);
        else snprintf(a, sizeof a, "%s %s %s", R(s, rn), op ? "-" : "+", b2);
        if (S) { snprintf(s->cl, EL, "%s", R(s, rn)); snprintf(s->cr, EL, "%s", b2); s->ck = op ? 1 : 4; }
        assign(s, rd, a, K_EXPR, 0);
        return;
    }
    // CSEL/CSET
    if ((w & 0x1FE00800) == 0x1A800000) {
        int op = (w >> 30) & 1, o2 = (w >> 10) & 1, cc = (w >> 12) & 15;
        char cond[EL * 2];
        if (!op && o2 && rn == 31 && rm == 31) { condstr(s, cc ^ 1, cond, sizeof cond); snprintf(a, sizeof a, "(%s)", cond); }
        else if (op && !o2 && rn == 31 && rm == 31) { condstr(s, cc ^ 1, cond, sizeof cond); snprintf(a, sizeof a, "-(%s)", cond); }
        else {
            condstr(s, cc, cond, sizeof cond);
            const char *alt = !op && !o2 ? R(s, rm) : NULL;
            if (alt) snprintf(a, sizeof a, "(%s) ? %s : %s", cond, R(s, rn), alt);
            else snprintf(a, sizeof a, "(%s) ? %s : %s%s", cond, R(s, rn), op ? (o2 ? "-" : "~") : "", !op && o2 ? strcat(strcpy(c, R(s, rm)), " + 1") : R(s, rm));
        }
        assign(s, rd, a, K_EXPR, 0);
        return;
    }
    // CCMP — сложное условие
    if ((w & 0x1FE00400) == 0x1A400000) {
        char prev[EL * 2];
        condstr(s, (w >> 12) & 15, prev, sizeof prev);
        char rhs[EL];
        if ((w >> 11) & 1) snprintf(rhs, sizeof rhs, "%d", rm); else snprintf(rhs, sizeof rhs, "%s", R(s, rm));
        snprintf(s->cl, EL, "(%s) && %s", prev, R(s, rn));
        snprintf(s->cr, EL, "%s", rhs);
        s->ck = (w >> 30) & 1 ? 1 : 4;
        return;
    }
    // MUL/MADD/деление/сдвиги
    if ((w & 0x1F000000) == 0x1B000000) {
        int op31 = (w >> 21) & 7, o0 = (w >> 15) & 1, ra = (w >> 10) & 31;
        if (op31 == 2 || op31 == 6) snprintf(a, sizeof a, "(%s * %s) >> 64", R(s, rn), R(s, rm));
        else if (ra == 31) snprintf(a, sizeof a, "%s%s * %s", o0 ? "-" : "", R(s, rn), R(s, rm));
        else snprintf(a, sizeof a, "%s %s %s * %s", R(s, ra), o0 ? "-" : "+", R(s, rn), R(s, rm));
        assign(s, rd, a, K_EXPR, 0);
        return;
    }
    if ((w & 0x5FE00000) == 0x1AC00000) {
        int opc = (w >> 10) & 63;
        const char *op = opc == 2 || opc == 3 ? "/" : opc == 8 ? "<<" : opc == 9 || opc == 10 ? ">>" : NULL;
        if (op) { snprintf(a, sizeof a, "%s %s %s", R(s, rn), op, R(s, rm)); assign(s, rd, a, K_EXPR, 0); return; }
    }
    if ((w & 0x1F800000) == 0x13000000) {   // битовые поля: lsl/lsr/asr/расширения
        char *p = strchr(dis, ' ');
        if (!strncmp(dis, "lsl", 3) || !strncmp(dis, "lsr", 3) || !strncmp(dis, "asr", 3)) {
            const char *num = strrchr(dis, '#');
            snprintf(a, sizeof a, "%s %s %s", R(s, rn), dis[0] == 'l' && dis[2] == 'l' ? "<<" : ">>", num ? num + 1 : "?");
        } else if (!strncmp(dis, "uxtb", 4)) snprintf(a, sizeof a, "(uint8_t)%s", R(s, rn));
        else if (!strncmp(dis, "uxth", 4)) snprintf(a, sizeof a, "(uint16_t)%s", R(s, rn));
        else if (!strncmp(dis, "sxtb", 4)) snprintf(a, sizeof a, "(int8_t)%s", R(s, rn));
        else if (!strncmp(dis, "sxth", 4)) snprintf(a, sizeof a, "(int16_t)%s", R(s, rn));
        else if (!strncmp(dis, "sxtw", 4)) snprintf(a, sizeof a, "(long)(int)%s", R(s, rn));
        else snprintf(a, sizeof a, "%s(%s)", p ? (*p = 0, dis) : "bits", R(s, rn));
        assign(s, rd, a, K_EXPR, 0);
        return;
    }

    // загрузки/сохранения
    if ((w & 0x3A000000) == 0x38000000) {
        int size = 1 << (w >> 30), v = (w >> 26) & 1, opc = (w >> 22) & 3;
        if (v && size == 1 && (opc & 2)) size = 16;
        int load = v ? (opc & 1) : opc != 0;
        int uimm = (w >> 24) & 1, regoff = !uimm && ((w >> 21) & 1);
        int64_t off = 0; int mode = 0;
        if (uimm) off = (int64_t)((w >> 10) & 0xFFF) * size;
        else if (!regoff) { off = ((int64_t)((w >> 12) & 0x1FF) ^ 0x100) - 0x100; mode = (w >> 10) & 3; }
        char m[EL * 2];
        if (regoff) {
            if (s->k[rm] == K_IVOFF) snprintf(m, sizeof m, "%s->%s", R(s, rn), s->e[rm]);
            else {
                int S = (w >> 12) & 1;
                snprintf(m, sizeof m, "*(%s *)(%s + %s%s)", ctype(size, v), R(s, rn), R(s, rm), S && size > 1 ? (size == 2 ? " * 2" : size == 4 ? " * 4" : size == 8 ? " * 8" : " * 16") : "");
            }
        } else memop(s, rn, (mode == 1) ? 0 : off, size, v, m, sizeof m);
        if ((rn == 31 || rn == 29) && !v && (is_callee(rd) || rd == 29 || rd == 30)) return;   // сохранение/восстановление регистров
        if (rn == 31 && !regoff && mode != 1 && mode != 3) {
            if (!load) { store_sp(s, off, v ? s->f[rd] : (rd == 31 ? "0" : R(s, rd))); return; }
            const char *pv = pending_at(s, off);
            if (pv) { char tmp[EL]; snprintf(tmp, sizeof tmp, "%s", pv); if (v) fassign(s, rd, tmp, K_EXPR); else assign(s, rd, tmp, K_EXPR, 0); return; }
        }
        if (!v && load && s->k[rn] == K_ADDR && size == 4 && uimm) {   // ldr/ldrsw смещения ivar
            uint32_t ivo; const char *ivn = iv_by_slot(s, s->val[rn] + (uint64_t)off, &ivo);
            if (ivn) { assign(s, rd, ivn, K_IVOFF, ivo); s->k[rd] = K_IVOFF; return; }
        }
        if (load) {
            if (v) fassign(s, rd, m, K_LOAD);
            else {
                int k = K_LOAD;
                if (s->k[rn] == K_ADDR && (!strncmp(m, "@selector(", 10) || (m[0] != 'g' && m[0] != '*'))) k = K_ADDR;   // селектор, класс, импорт
                assign(s, rd, m, k, 0);
                if (k == K_ADDR && rd != 31) s->k[rd] = K_NAME;
            }
        } else {
            flush_loads(s, next);
            emit(s, "%s = %s;", m, v ? s->f[rd] : (rd == 31 ? "0" : R(s, rd)));
        }
        if ((mode == 1 || mode == 3) && rn != 31 && rn != 29) { char nb[EL]; snprintf(nb, sizeof nb, "%s + %lld", R(s, rn), (long long)off); assign(s, rn, nb, K_EXPR, 0); }
        return;
    }
    if ((w & 0x3A000000) == 0x28000000) {   // ldp/stp не на стеке
        int v = (w >> 26) & 1, L = (w >> 22) & 1, rt2 = (w >> 10) & 31, opc = w >> 30;
        int size = v ? 4 << opc : (opc == 2 ? 8 : 4);
        int64_t imm = ((int64_t)(((w >> 15) & 0x7F) ^ 0x40) - 0x40) * size;
        char m1[EL * 2], m2[EL * 2];
        memop(s, rn, imm, size, v, m1, sizeof m1);
        memop(s, rn, imm + size, size, v, m2, sizeof m2);
        if (L) { if (v) { fassign(s, rd, m1, K_LOAD); fassign(s, rt2, m2, K_LOAD); } else { assign(s, rd, m1, K_LOAD, 0); assign(s, rt2, m2, K_LOAD, 0); } }
        else { flush_loads(s, next); emit(s, "%s = %s;", m1, v ? s->f[rd] : R(s, rd)); emit(s, "%s = %s;", m2, v ? s->f[rt2] : R(s, rt2)); }
        return;
    }

    // плавающая точка
    if ((w & 0xFF201FE0) == 0x1E201000) { char *p = strchr(dis, '#'); fassign(s, rd, p ? p + 1 : "?", K_CONST); return; }
    if ((w & 0xFF200C00) == 0x1E200C00) {   // fcsel
        char cond[EL * 2]; condstr(s, (w >> 12) & 15, cond, sizeof cond);
        snprintf(a, sizeof a, "(%s) ? %s : %s", cond, s->f[rn], s->f[rm]);
        fassign(s, rd, a, K_EXPR);
        return;
    }
    if ((w & 0xFFFFFFE0) == 0x2F00E400 || (w & 0xFFFFFFE0) == 0x6F00E400) { fassign(s, rd, "0.0", K_CONST); return; }   // movi #0
    if ((w & 0x7F20FC00) == 0x1E200000) {
        int op = (w >> 16) & 7, rmode = (w >> 19) & 3, ty = (w >> 22) & 3;
        if (rmode == 0 && op == 7) {   // fmov s, w
            if (rn == 31) { fassign(s, rd, "0.0", K_CONST); return; }
            if (s->k[rn] == K_CONST) {
                if (ty == 0) { uint32_t bits = (uint32_t)s->val[rn]; float f; memcpy(&f, &bits, 4); snprintf(a, sizeof a, "%g", f); }
                else { uint64_t bits = s->val[rn]; double f; memcpy(&f, &bits, 8); snprintf(a, sizeof a, "%g", f); }
                fassign(s, rd, a, K_CONST);
            } else { snprintf(a, sizeof a, "*(%s *)&%s", ty ? "double" : "float", R(s, rn)); fassign(s, rd, a, K_EXPR); }
            return;
        }
        if (rmode == 0 && op == 6) { snprintf(a, sizeof a, "*(int *)&%s", s->f[rn]); assign(s, rd, a, K_EXPR, 0); return; }
        if (rmode == 0 && (op == 2 || op == 3)) { snprintf(a, sizeof a, "(%s)%s", ty ? "double" : "float", R(s, rn)); fassign(s, rd, a, K_EXPR); return; }
        if (op == 0 || op == 1) { snprintf(a, sizeof a, "(%s)%s", sf ? "long" : "int", s->f[rn]); assign(s, rd, a, K_EXPR, 0); return; }
    }
    if ((w & 0xFF200C00) == 0x1E200800) {
        int op = (w >> 12) & 15;
        static const char *o2[9] = {"*", "/", "+", "-", "max", "min", "maxnm", "minnm", "*"};
        if (op < 4 || op == 8) snprintf(a, sizeof a, "%s%s %s %s%s", op == 8 ? "-(" : "", s->f[rn], o2[op], s->f[rm], op == 8 ? ")" : "");
        else if (op <= 7) snprintf(a, sizeof a, "f%s(%s, %s)", o2[op], s->f[rn], s->f[rm]);
        else goto unk;
        fassign(s, rd, a, K_EXPR);
        return;
    }
    if ((w & 0xFF20FC07) == 0x1E202000 || (w & 0xFF20FC17) == 0x1E202010) {
        snprintf(s->cl, EL, "%s", s->f[rn]);
        if ((w >> 3) & 1) snprintf(s->cr, EL, "0.0"); else snprintf(s->cr, EL, "%s", s->f[rm]);
        s->ck = 3;
        return;
    }
    if ((w & 0xFF207C00) == 0x1E204000) {
        int op = (w >> 15) & 63;
        if (op == 0) { fassign(s, rd, s->f[rn], s->fk[rn]); return; }
        const char *f = op == 1 ? "fabs" : op == 2 ? "-" : op == 3 ? "sqrt" : op == 4 || op == 5 ? "" : NULL;
        if (f) { snprintf(a, sizeof a, op == 2 ? "-%s" : "%s(%s)", op == 2 ? s->f[rn] : f, s->f[rn]); if (op == 4 || op == 5) snprintf(a, sizeof a, "(%s)%s", op == 4 ? "float" : "double", s->f[rn]); fassign(s, rd, a, K_EXPR); return; }
    }

unk:
    emit(s, "__asm { %s }", dis);
    {
        uint32_t r, wr, fr, fw;
        rw(w, &r, &wr, &fr, &fw);
        for (int i = 0; i < 31; i++) if (wr >> i & 1) setname(s, i);
        for (int i = 0; i < 32; i++) if (fw >> i & 1) fsetname(s, i);
    }
}

char *gx_pseudo(const gx_bin *b, uint64_t start, uint64_t end, const char *fname, int objc, const char *proto, int retkind,
                const gx_pivar *self_iv, int nself, const gx_pivar *all_iv, int nall,
                gx_namer namer, void *ctx) {
    ps *s = calloc(1, sizeof *s);
    s->b = b; s->start = start; s->end = end; s->objc = objc; s->retkind = retkind;
    s->siv = self_iv; s->nsiv = nself; s->aiv = all_iv; s->naiv = nall;
    s->namer = namer; s->ctx = ctx;
    s->lastx0 = -1; s->lasts0 = -1;
    if (end - start > 0x40000) s->end = end = start + 0x40000;
    for (int r = 0; r < 31; r++) { if (r < 8) argname(s, r, s->e[r]); else setname(s, r); s->k[r] = K_NAME; }
    for (int r = 0; r < 32; r++) { if (r < 8) sprintf(s->f[r], "f%d", r + 1); else fsetname(s, r); }
    // метки
    size_t cap = 0;
    for (uint64_t a = start; a < end; a += 4) {
        int64_t off = gx_bin_a2o(b, a);
        if (off < 0 || (size_t)off + 4 > b->len) break;
        uint64_t t; char tmp[4];
        int k = gx_a64_dis(L32(b->d + off), a, tmp, 0, &t);
        if ((k == GX_A64_BRANCH || k == GX_A64_COND) && t >= start && t < end) {
            if (s->nlab == cap) { cap = cap ? cap * 2 : 32; s->labels = realloc(s->labels, cap * 8); }
            s->labels[s->nlab++] = t;
        }
    }
    if (s->nlab) qsort(s->labels, s->nlab, 8, cmp64);
    // заголовок
    if (objc && proto && *proto) {
        out(&s->o, GXT("// %s\n// Псевдокод (приблизительно): восстановлен из машинного кода ARM64\n@implementation %.*s\n%s\n{\n"), fname,
            (int)(strcspn(fname + 2, " ")), fname + 2, proto);
    } else if (objc) {
        const char *sp = strchr(fname, ' ');
        int na = sp ? sel_args(sp) : 0;
        out(&s->o, GXT("// %s\n// Псевдокод (приблизительно): восстановлен из машинного кода ARM64\nid %s(id self, SEL _cmd"), fname, fname);
        for (int i = 0; i < na && i < 6; i++) out(&s->o, ", id a%d", i + 1);
        out(&s->o, ")\n{\n");
    } else out(&s->o, GXT("// %s\n// Псевдокод (приблизительно): восстановлен из машинного кода ARM64\n%s(a1, a2, ...)\n{\n"), fname, fname);
    for (uint64_t a = start; a < end; a += 4) {
        int64_t off = gx_bin_a2o(b, a);
        if (off < 0 || (size_t)off + 4 > b->len) break;
        if (has_label(s, a)) { at_label(s, a); char l[40]; lab(l, a); out(&s->o, "%s:\n", l); }
        s->nofall = 0;
        s->idx++;
        do_ins(s, a, L32(b->d + off));
    }
    emit_pending(s);
    out(&s->o, objc && proto && *proto ? "}\n@end\n" : "}\n");
    char *r = s->o.s ? s->o.s : strdup("");
    // убрать «vN = », если vN больше нигде не используется
    for (int v = 1; v <= s->vn; v++) {
        char tok[24]; int tl = snprintf(tok, sizeof tok, "v%d", v);
        int cnt = 0; char *def = NULL;
        for (char *p = r; (p = strstr(p, tok)); p += tl) {
            char before = p == r ? ' ' : p[-1], after = p[tl];
            if ((before >= 'a' && before <= 'z') || (before >= 'A' && before <= 'Z') || (before >= '0' && before <= '9') || before == '_') continue;
            if ((after >= '0' && after <= '9') || (after >= 'a' && after <= 'z') || after == '_') continue;
            cnt++;
            if (!def && !strncmp(p + tl, " = ", 3) && p >= r + 4 && !strncmp(p - 4, "    ", 4)) def = p;
        }
        if (cnt == 1 && def) memmove(def, def + tl + 3, strlen(def + tl + 3) + 1);
    }
    for (size_t i = 0; i < s->nsnap; i++) free(s->snaps[i].e);
    free(s->snaps);
    free(s->labels);
    free(s);
    return r;
}

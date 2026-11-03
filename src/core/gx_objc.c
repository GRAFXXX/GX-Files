#include "gx_tr.h"
#include "gx_objc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

typedef struct { char *s; size_t n, cap; } sb;
static void sb_add(sb *b, const char *fmt, ...) {
    va_list ap;
    for (;;) {
        size_t room = b->cap - b->n;
        va_start(ap, fmt);
        int k = vsnprintf(b->s ? b->s + b->n : NULL, b->s ? room : 0, fmt, ap);
        va_end(ap);
        if (k < 0) return;
        if (b->s && (size_t)k < room) { b->n += (size_t)k; return; }
        b->cap = (b->cap + (size_t)k + 1) * 2;
        b->s = realloc(b->s, b->cap);
    }
}

static int rd32(const gx_bin *b, uint64_t a, uint32_t *v) {
    int64_t o = gx_bin_a2o(b, a);
    if (o < 0 || (size_t)o + 4 > b->len) return 0;
    const uint8_t *p = b->d + o;
    *v = (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
    return 1;
}
static uint64_t rdptr(const gx_bin *b, uint64_t a) {
    uint64_t t; const char *n; uint32_t l;
    return gx_bin_ptr_at(b, a, &t, &n, &l) == 1 ? t : 0;
}
static const char *rdstr(const gx_bin *b, uint64_t a, char *buf, size_t n) {
    buf[0] = 0;
    int64_t o = gx_bin_a2o(b, a);
    if (!a || o < 0) return NULL;
    size_t lim = b->len - (size_t)o;
    if (lim > n - 1) lim = n - 1;
    size_t l = strnlen((const char *)b->d + o, lim);
    if (l == lim && l == n - 1) l = n - 1;
    memcpy(buf, b->d + o, l); buf[l] = 0;
    return l ? buf : NULL;
}
static const char *strstrip(const char *s) {
    if (!strncmp(s, "_OBJC_CLASS_$_", 14)) return s + 14;
    if (!strncmp(s, "_OBJC_METACLASS_$_", 18)) return s + 18;
    return s;
}

#pragma mark - типы

static const char *skip_type(const char *p);
static void dec(const char **pp, char *out, size_t n) {
    const char *p = *pp;
    char pre[16] = "";
    while (*p && strchr("rnNoORVAj+", *p)) { if (*p == 'r') strcpy(pre, "const "); p++; }
    char t[256] = "";
    switch (*p) {
        case 'c': strcpy(t, "char"); p++; break;
        case 'C': strcpy(t, "unsigned char"); p++; break;
        case 's': strcpy(t, "short"); p++; break;
        case 'S': strcpy(t, "unsigned short"); p++; break;
        case 'i': strcpy(t, "int"); p++; break;
        case 'I': strcpy(t, "unsigned int"); p++; break;
        case 'l': strcpy(t, "long"); p++; break;
        case 'L': strcpy(t, "unsigned long"); p++; break;
        case 'q': strcpy(t, "long long"); p++; break;
        case 'Q': strcpy(t, "unsigned long long"); p++; break;
        case 'f': strcpy(t, "float"); p++; break;
        case 'd': strcpy(t, "double"); p++; break;
        case 'D': strcpy(t, "long double"); p++; break;
        case 'B': strcpy(t, "BOOL"); p++; break;
        case 'v': strcpy(t, "void"); p++; break;
        case '*': strcpy(t, "char *"); p++; break;
        case '#': strcpy(t, "Class"); p++; break;
        case ':': strcpy(t, "SEL"); p++; break;
        case '?': strcpy(t, "void * /* fn */"); p++; break;
        case '@':
            p++;
            if (*p == '?') { strcpy(t, "id /* block */"); p++; }
            else if (*p == '"') {
                const char *e = strchr(p + 1, '"');
                if (!e) { strcpy(t, "id"); break; }
                size_t l = (size_t)(e - p - 1);
                if (!l) strcpy(t, "id");
                else if (p[1] == '<') snprintf(t, sizeof t, "id%.*s", (int)l, p + 1);
                else snprintf(t, sizeof t, "%.*s *", (int)l, p + 1);
                p = e + 1;
            } else strcpy(t, "id");
            break;
        case '^': {
            p++;
            char in[200]; dec(&p, in, sizeof in);
            size_t l = strlen(in);
            snprintf(t, sizeof t, "%s%s*", in, l && in[l - 1] == '*' ? "" : " ");
            break;
        }
        case '{': case '(': {
            char close = *p == '{' ? '}' : ')';
            const char *kw = *p == '{' ? "struct" : "union";
            const char *s = p + 1;
            size_t l = strcspn(s, "=}),");
            if (l && !(l == 1 && s[0] == '?')) snprintf(t, sizeof t, "%s %.*s", kw, (int)l, s);
            else snprintf(t, sizeof t, "%s { ... }", kw);
            // пропустить с учётом вложенности
            int depth = 0;
            for (; *p; p++) {
                if (*p == '{' || *p == '(') depth++;
                else if (*p == '}' || *p == ')') { if (--depth == 0) { p++; break; } }
                else if (*p == '"') { const char *e = strchr(p + 1, '"'); if (!e) break; p = e; }
            }
            (void)close;
            break;
        }
        case '[': {
            p++;
            long cnt = strtol(p, (char **)&p, 10);
            char in[200]; dec(&p, in, sizeof in);
            if (*p == ']') p++;
            snprintf(t, sizeof t, "%s[%ld]", in, cnt);
            break;
        }
        case 'b': { p++; long bits = strtol(p, (char **)&p, 10); snprintf(t, sizeof t, "unsigned int :%ld", bits); break; }
        case 0: strcpy(t, "void"); break;
        default: snprintf(t, sizeof t, "/* %c */ void *", *p); p++; break;
    }
    while (*p >= '0' && *p <= '9') p++;
    snprintf(out, n, "%s%s", pre, t);
    *pp = p;
}
static const char *skip_type(const char *p) { char tmp[256]; dec(&p, tmp, sizeof tmp); return p; }

void gx_objc_type(const char *enc, char *out, size_t n) { const char *p = enc; dec(&p, out, n); }

static void fmt_method(sb *o, char sign, const char *sel, const char *types, uint64_t imp) {
    char ret[256] = "id";
    const char *p = types && *types ? types : NULL;
    char args[16][200]; int na = 0;
    if (p) {
        dec(&p, ret, sizeof ret);
        p = skip_type(p);        // self
        p = skip_type(p);        // _cmd
        while (*p && na < 16) { dec(&p, args[na], sizeof args[na]); na++; }
    }
    sb_add(o, "%c (%s)", sign, ret);
    const char *s = sel;
    int ai = 0;
    if (!strchr(sel, ':')) sb_add(o, "%s", sel);
    else while (*s) {
        const char *c = strchr(s, ':');
        if (!c) { sb_add(o, "%s", s); break; }
        sb_add(o, "%s%.*s:(%s)a%d", ai ? " " : "", (int)(c - s), s, ai < na ? args[ai] : "id", ai + 1);
        ai++;
        s = c + 1;
    }
    if (imp) sb_add(o, ";   // 0x%llx\n", (unsigned long long)imp);
    else sb_add(o, ";\n");
}

#pragma mark - списки

typedef struct { gx_objc_m *a; int n, cap; } mvec;
static void madd(mvec *v, const char *cls, char sign, const char *sel, uint64_t imp, const char *proto, int rk) {
    if (v->n == v->cap) { v->cap = v->cap ? v->cap * 2 : 16; v->a = realloc(v->a, sizeof(gx_objc_m) * v->cap); }
    size_t l = strlen(cls) + strlen(sel) + 8;
    char *nm = malloc(l);
    snprintf(nm, l, "%c[%s %s]", sign, cls, sel);
    v->a[v->n++] = (gx_objc_m){nm, imp, sign == '+', strdup(proto), rk};
}

static void methods(const gx_bin *b, uint64_t ml, char sign, const char *cls, sb *o, mvec *mv) {
    uint32_t ef, cnt;
    if (!ml || !rd32(b, ml, &ef) || !rd32(b, ml + 4, &cnt) || cnt > 20000) return;
    int rel = (ef & 0x80000000u) != 0;
    uint32_t es = ef & 0xFFFC;
    if (!es) es = rel ? 12 : 24;
    for (uint32_t i = 0; i < cnt; i++) {
        uint64_t e = ml + 8 + (uint64_t)i * es;
        char sel[512], ty[512]; const char *s = NULL, *t = NULL; uint64_t imp = 0;
        if (rel) {
            uint32_t no, to, io;
            if (!rd32(b, e, &no) || !rd32(b, e + 4, &to) || !rd32(b, e + 8, &io)) break;
            uint64_t selref = e + (uint64_t)(int64_t)(int32_t)no;
            uint64_t sp = rdptr(b, selref);
            s = sp ? rdstr(b, sp, sel, sizeof sel) : NULL;
            if (!s) s = rdstr(b, selref, sel, sizeof sel);    // селектор может лежать напрямую
            t = rdstr(b, e + 4 + (uint64_t)(int64_t)(int32_t)to, ty, sizeof ty);
            if (io) imp = e + 8 + (uint64_t)(int64_t)(int32_t)io;
        } else {
            s = rdstr(b, rdptr(b, e), sel, sizeof sel);
            t = rdstr(b, rdptr(b, e + 8), ty, sizeof ty);
            imp = rdptr(b, e + 16);
        }
        if (!s) continue;
        size_t before = o->n;
        fmt_method(o, sign, s, t, imp);
        if (mv) {
            char proto[1024];
            size_t l = o->n - before; if (l >= sizeof proto) l = sizeof proto - 1;
            memcpy(proto, o->s + before, l); proto[l] = 0;
            char *semi = strchr(proto, ';'); if (semi) *semi = 0;
            int rk = 3;
            if (t) { const char *q = t; while (*q && strchr("rnNoORV", *q)) q++; rk = *q == 'v' ? 1 : (*q == 'f' || *q == 'd') ? 2 : *q == '{' ? 0 : 3; }
            madd(mv, cls, sign, s, imp, proto, rk);
        }
    }
}

typedef struct { gx_objc_iv *a; int n, cap; } ivec;
static void ivars(const gx_bin *b, uint64_t il, sb *o, ivec *iv) {
    uint32_t es, cnt;
    if (!il || !rd32(b, il, &es) || !rd32(b, il + 4, &cnt) || cnt > 20000) return;
    if (es < 32) es = 32;
    if (!cnt) return;
    sb_add(o, "{\n");
    for (uint32_t i = 0; i < cnt; i++) {
        uint64_t e = il + 8 + (uint64_t)i * es;
        char nm[256], ty[512], tt[300];
        const char *n = rdstr(b, rdptr(b, e + 8), nm, sizeof nm), *t = rdstr(b, rdptr(b, e + 16), ty, sizeof ty);
        uint64_t op = rdptr(b, e); uint32_t off = 0;
        if (op) rd32(b, op, &off);
        gx_objc_type(t ? t : "?", tt, sizeof tt);
        if (iv && n) {
            if (iv->n == iv->cap) { iv->cap = iv->cap ? iv->cap * 2 : 8; iv->a = realloc(iv->a, sizeof(gx_objc_iv) * iv->cap); }
            iv->a[iv->n++] = (gx_objc_iv){strdup(n), op, off};
        }
        size_t l = strlen(tt);
        sb_add(o, "    %s%s%s;   // +0x%x\n", tt, l && tt[l - 1] == '*' ? "" : " ", n ? n : "?", off);
    }
    sb_add(o, "}\n");
}

static void props(const gx_bin *b, uint64_t pl, sb *o) {
    uint32_t es, cnt;
    if (!pl || !rd32(b, pl, &es) || !rd32(b, pl + 4, &cnt) || cnt > 20000) return;
    if (es < 16) es = 16;
    for (uint32_t i = 0; i < cnt; i++) {
        uint64_t e = pl + 8 + (uint64_t)i * es;
        char nm[256], at[1024];
        const char *n = rdstr(b, rdptr(b, e), nm, sizeof nm), *a = rdstr(b, rdptr(b, e + 8), at, sizeof at);
        if (!n) continue;
        char type[300] = "id", attrs[200] = "";
        int ro = 0, copy = 0, retain = 0, weak = 0, nonatomic = 0;
        char getter[200] = "", setter[200] = "";
        if (a) {
            const char *q = a;
            while (*q) {
                const char *end = q;
                // T-атрибут может содержать запятые в кавычках — ищем запятую вне кавычек
                int inq = 0;
                while (*end && (inq || *end != ',')) { if (*end == '"') inq = !inq; end++; }
                char part[600]; size_t l = (size_t)(end - q); if (l >= sizeof part) l = sizeof part - 1;
                memcpy(part, q, l); part[l] = 0;
                switch (part[0]) {
                    case 'T': gx_objc_type(part + 1, type, sizeof type); break;
                    case 'R': ro = 1; break;
                    case 'C': copy = 1; break;
                    case '&': retain = 1; break;
                    case 'W': weak = 1; break;
                    case 'N': nonatomic = 1; break;
                    case 'G': snprintf(getter, sizeof getter, "getter=%s", part + 1); break;
                    case 'S': snprintf(setter, sizeof setter, "setter=%s", part + 1); break;
                }
                q = *end ? end + 1 : end;
            }
        }
        size_t k = 0;
        #define ATT(s) do { k += (size_t)snprintf(attrs + k, k < sizeof attrs ? sizeof attrs - k : 0, "%s%s", k ? ", " : "", s); } while (0)
        if (nonatomic) ATT("nonatomic");
        if (copy) ATT("copy"); else if (retain) ATT("strong"); else if (weak) ATT("weak"); else if (type[strlen(type) - 1] != '*' && strncmp(type, "id", 2)) ATT("assign");
        if (ro) ATT("readonly");
        if (getter[0]) ATT(getter);
        if (setter[0]) ATT(setter);
        #undef ATT
        size_t tl = strlen(type);
        sb_add(o, "@property (%s) %s%s%s;\n", attrs, type, tl && type[tl - 1] == '*' ? "" : " ", n);
    }
}

static void protos(const gx_bin *b, uint64_t pl, sb *o) {
    uint32_t cnt;
    if (!pl || !rd32(b, pl, &cnt) || !cnt || cnt > 500) return;
    sb_add(o, " <");
    for (uint32_t i = 0; i < cnt; i++) {
        uint64_t p = rdptr(b, pl + 8 + (uint64_t)i * 8);
        char nm[256]; const char *n = p ? rdstr(b, rdptr(b, p + 8), nm, sizeof nm) : NULL;
        sb_add(o, "%s%s", i ? ", " : "", n ? n : "?");
    }
    sb_add(o, ">");
}

static uint64_t class_ro(const gx_bin *b, uint64_t cls) {
    uint64_t r = rdptr(b, cls + 32);
    return r & ~7ull;
}

static void super_name(const gx_bin *b, uint64_t slot, char *out, size_t n) {
    uint64_t t; const char *nm; uint32_t nl;
    int k = gx_bin_ptr_at(b, slot, &t, &nm, &nl);
    out[0] = 0;
    if (k == 2) { char tmp[300]; snprintf(tmp, sizeof tmp, "%.*s", (int)nl, nm); snprintf(out, n, "%s", strstrip(tmp)); }
    else if (k == 1 && gx_bin_objc_class_name(b, t, &nm, &nl)) snprintf(out, n, "%.*s", (int)nl, nm);
}

static int cmp_cls(const void *a, const void *c) { return strcmp(((const gx_objc_cls *)a)->name, ((const gx_objc_cls *)c)->name); }

int gx_objc_dump(const gx_bin *b, gx_objc_cls **out, int *n) {
    *out = NULL; *n = 0;
    if (b->fmt != 1) return 0;
    int cap = 0;
    for (int pass = 0; pass < 2; pass++) {
        int si = gx_bin_sect_named(b, pass ? "__objc_catlist" : "__objc_classlist");
        if (si < 0) continue;
        const gx_sect *s = &b->s[si];
        if (s->kind == GX_SK_ZERO || s->size > b->len) continue;   // секция не из файла / битый размер
        for (uint64_t a = s->addr; a + 8 <= s->addr + s->size && *n < 100000; a += 8) {
            uint64_t c = rdptr(b, a);
            if (!c) continue;
            sb o = {0};
            mvec mv = {0};
            ivec iv = {0};
            char name[512] = "?", sup[300] = "";
            if (!pass) {
                uint64_t ro = class_ro(b, c);
                if (!ro) continue;
                char nb[512]; const char *nm = rdstr(b, rdptr(b, ro + 24), nb, sizeof nb);
                if (!nm) continue;
                snprintf(name, sizeof name, "%s", nm);
                super_name(b, c + 8, sup, sizeof sup);
                sb_add(&o, GXT("// адрес класса 0x%llx\n@interface %s"), (unsigned long long)c, name);
                if (sup[0]) sb_add(&o, " : %s", sup);
                protos(b, rdptr(b, ro + 40), &o);
                sb_add(&o, "\n");
                ivars(b, rdptr(b, ro + 48), &o, &iv);
                sb_add(&o, "\n");
                props(b, rdptr(b, ro + 64), &o);
                uint64_t meta = rdptr(b, c);
                uint64_t mro = meta ? class_ro(b, meta) : 0;
                if (mro) methods(b, rdptr(b, mro + 32), '+', name, &o, &mv);
                methods(b, rdptr(b, ro + 32), '-', name, &o, &mv);
                sb_add(&o, "@end\n");
            } else {
                char cn[256], tn[300] = "?";
                const char *catn = rdstr(b, rdptr(b, c), cn, sizeof cn);
                super_name(b, c + 8, tn, sizeof tn);
                if (!tn[0]) snprintf(tn, sizeof tn, "?");
                snprintf(name, sizeof name, "%s (%s)", tn, catn ? catn : "");
                sb_add(&o, GXT("// категория 0x%llx\n@interface %s"), (unsigned long long)c, name);
                protos(b, rdptr(b, c + 32), &o);
                sb_add(&o, "\n");
                props(b, rdptr(b, c + 40), &o);
                methods(b, rdptr(b, c + 24), '+', tn, &o, &mv);
                methods(b, rdptr(b, c + 16), '-', tn, &o, &mv);
                sb_add(&o, "@end\n");
            }
            if (*n == cap) { cap = cap ? cap * 2 : 64; *out = realloc(*out, sizeof(gx_objc_cls) * cap); }
            (*out)[(*n)++] = (gx_objc_cls){strdup(name), o.s ? o.s : strdup(""), mv.a, mv.n, pass, c, iv.a, iv.n};
        }
    }
    if (*n) qsort(*out, (size_t)*n, sizeof **out, cmp_cls);
    return 1;
}

void gx_objc_free(gx_objc_cls *c, int n) {
    for (int i = 0; i < n; i++) {
        free(c[i].name); free(c[i].header);
        for (int k = 0; k < c[i].nm; k++) { free(c[i].m[k].name); free(c[i].m[k].proto); }
        free(c[i].m);
        for (int k = 0; k < c[i].niv; k++) free(c[i].iv[k].name);
        free(c[i].iv);
    }
    free(c);
}

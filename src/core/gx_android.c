#include "gx_tr.h"
#include "gx_android.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

#pragma mark - пул строк

static int pool_init(gxa_pool *p, const uint8_t *base, size_t avail) {
    memset(p, 0, sizeof *p);
    if (avail < 28) return 0;
    uint16_t hs = u16(base + 2);
    uint32_t size = u32(base + 4);
    if (size > avail || size < 28 || hs > size) return 0;
    p->base = base;
    p->len = size;
    p->count = u32(base + 8);
    p->utf8 = (u32(base + 16) & 0x100) != 0;
    uint32_t ss = u32(base + 20);
    if ((uint64_t)hs + (uint64_t)p->count * 4 > size) { p->count = 0; return 0; }
    p->offs = base + hs;
    if (ss > size) ss = size;
    p->strs = base + ss;
    p->strs_len = size - ss;
    p->cache = calloc(p->count ? p->count : 1, sizeof(char *));
    return 1;
}

static void pool_free(gxa_pool *p) {
    if (!p->cache) return;
    for (uint32_t i = 0; i < p->count; i++) free(p->cache[i]);
    free(p->cache);
    p->cache = NULL;
}

static size_t utf16_to_utf8(const uint8_t *s, size_t nchars, char *out) {
    size_t o = 0;
    for (size_t i = 0; i < nchars; i++) {
        uint32_t c = u16(s + i * 2);
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < nchars) {
            uint32_t c2 = u16(s + (i + 1) * 2);
            if (c2 >= 0xDC00 && c2 < 0xE000) { c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00); i++; }
        }
        if (c < 0x80) out[o++] = (char)c;
        else if (c < 0x800) { out[o++] = (char)(0xC0 | c >> 6); out[o++] = (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out[o++] = (char)(0xE0 | c >> 12); out[o++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[o++] = (char)(0x80 | (c & 0x3F)); }
        else { out[o++] = (char)(0xF0 | c >> 18); out[o++] = (char)(0x80 | ((c >> 12) & 0x3F)); out[o++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[o++] = (char)(0x80 | (c & 0x3F)); }
    }
    out[o] = 0;
    return o;
}

const char *gxa_pool_get(gxa_pool *p, uint32_t idx) {
    if (!p || !p->cache || idx >= p->count) return "";
    if (p->cache[idx]) return p->cache[idx];
    uint32_t off = u32(p->offs + idx * 4);
    if (off >= p->strs_len) return "";
    const uint8_t *s = p->strs + off;
    size_t left = p->strs_len - off;
    char *r = NULL;
    if (p->utf8) {
        if (left < 2) return "";
        size_t k = 0;
        uint32_t n16 = s[k++];
        if (n16 & 0x80) { if (k >= left) return ""; n16 = ((n16 & 0x7F) << 8) | s[k++]; }
        if (k >= left) return "";
        uint32_t n8 = s[k++];
        if (n8 & 0x80) { if (k >= left) return ""; n8 = ((n8 & 0x7F) << 8) | s[k++]; }
        if (k + n8 > left) n8 = (uint32_t)(left - k);
        r = malloc(n8 + 1);
        memcpy(r, s + k, n8);
        r[n8] = 0;
    } else {
        if (left < 2) return "";
        size_t k = 0;
        uint32_t n = u16(s);
        k = 2;
        if (n & 0x8000) { if (left < 4) return ""; n = ((n & 0x7FFF) << 16) | u16(s + 2); k = 4; }
        if (k + (size_t)n * 2 > left) n = (uint32_t)((left - k) / 2);
        r = malloc((size_t)n * 4 + 1);
        utf16_to_utf8(s + k, n, r);
    }
    p->cache[idx] = r;
    return r;
}

#pragma mark - AXML

static const struct { uint32_t id; const char *name; } kAttrNames[] = {
    {0x01010000, "theme"}, {0x01010001, "label"}, {0x01010002, "icon"}, {0x01010003, "name"},
    {0x01010006, "permission"}, {0x0101000f, "debuggable"}, {0x01010010, "exported"}, {0x0101021b, "versionCode"},
    {0x0101021c, "versionName"}, {0x0101020c, "minSdkVersion"}, {0x01010270, "targetSdkVersion"},
    {0x0101052c, "roundIcon"}, {0x01010199, "drawable"}, {0x01010018, "value"}, {0x01010024, "resource"},
    {0x0101001e, "screenOrientation"}, {0x01010019, "authorities"}, {0x01010281, "required"},
    {0x01010003, "name"}, {0x0101001f, "configChanges"}, {0x0101022b, "installLocation"},
    {0x0101000e, "enabled"}, {0x01010011, "process"}, {0x01010020, "description"},
};

static const char *attr_name_for(uint32_t id) {
    for (size_t i = 0; i < sizeof kAttrNames / sizeof kAttrNames[0]; i++) if (kAttrNames[i].id == id) return kAttrNames[i].name;
    return NULL;
}

int gxa_xml_parse(gxa_xml *x, const uint8_t *d, size_t len) {
    memset(x, 0, sizeof *x);
    if (len < 8 || u16(d) != 0x0003) return 0;
    x->copy = malloc(len);
    memcpy(x->copy, d, len);
    x->copy_len = len;
    d = x->copy;
    size_t total = u32(d + 4);
    if (total > len) total = len;
    size_t cap = 64, evcap = 128;
    x->el = calloc(cap, sizeof(gxa_elem));
    x->ev = calloc(evcap, sizeof(int));
    int depth = 0;
    int stack[256];
    int sp = 0;
    size_t p = u16(d + 2);
    int have_pool = 0;
    while (p + 8 <= total) {
        uint16_t type = u16(d + p), hs = u16(d + p + 2);
        uint32_t size = u32(d + p + 4);
        if (size < 8 || p + size > total) break;
        const uint8_t *c = d + p;
        if (hs < 8 || hs > size) { p += size; continue; }
        if (type == 0x0001 && !have_pool) {
            have_pool = pool_init(&x->pool, c, size);
        } else if (type == 0x0180) {
            x->resmap = (const uint32_t *)(c + hs);
            x->nres = (size - hs) / 4;
        } else if (type == 0x0100 && size >= 24) {
            if (x->nns < 16) {
                const char *pre = gxa_pool_get(&x->pool, u32(c + 16));
                const char *uri = gxa_pool_get(&x->pool, u32(c + 20));
                x->ns_prefix_name[x->nns] = strdup(pre);
                x->ns_prefix_uri[x->nns] = strdup(uri);
                x->nns++;
            }
        } else if (type == 0x0102 && size >= 36) {
            const uint8_t *ext = c + hs;
            if (ext + 20 > c + size) { p += size; continue; }
            uint32_t nm = u32(ext + 4);
            uint16_t astart = u16(ext + 8), asize = u16(ext + 10), acount = u16(ext + 12);
            if (asize < 20) asize = 20;
            if (x->nel == cap) { cap *= 2; x->el = realloc(x->el, cap * sizeof(gxa_elem)); }
            gxa_elem *e = &x->el[x->nel];
            memset(e, 0, sizeof *e);
            e->depth = depth;
            e->name = gxa_pool_get(&x->pool, nm);
            e->attr = calloc(acount ? acount : 1, sizeof(gxa_attr));
            for (uint16_t i = 0; i < acount; i++) {
                const uint8_t *a = ext + astart + (size_t)i * asize;
                if (a + 20 > c + size) break;
                gxa_attr *at = &e->attr[e->nattr++];
                uint32_t ns = u32(a), name = u32(a + 4), raw = u32(a + 8);
                at->ns = ns == 0xFFFFFFFFu ? "" : gxa_pool_get(&x->pool, ns);
                at->resid = (x->resmap && name < x->nres) ? u32((const uint8_t *)(x->resmap + name)) : 0;
                at->name = gxa_pool_get(&x->pool, name);
                if (!at->name[0] && at->resid) { const char *n = attr_name_for(at->resid); if (n) at->name = n; }
                at->type = a[15];
                at->data = u32(a + 16);
                at->str = raw != 0xFFFFFFFFu ? gxa_pool_get(&x->pool, raw) : (at->type == GXA_T_STRING ? gxa_pool_get(&x->pool, at->data) : NULL);
            }
            if (x->nev == evcap) { evcap *= 2; x->ev = realloc(x->ev, evcap * sizeof(int)); }
            x->ev[x->nev++] = (int)x->nel;
            if (sp < 256) stack[sp++] = (int)x->nel;
            x->nel++;
            depth++;
        } else if (type == 0x0103) {
            if (depth > 0) depth--;
            int idx = sp > 0 ? stack[--sp] : 0;
            if (x->nev == evcap) { evcap *= 2; x->ev = realloc(x->ev, evcap * sizeof(int)); }
            x->ev[x->nev++] = -idx - 1;
        }
        p += size;
    }
    if (x->nel == 0) { gxa_xml_free(x); return 0; }
    return 1;
}

void gxa_xml_free(gxa_xml *x) {
    for (size_t i = 0; i < x->nel; i++) free(x->el[i].attr);
    free(x->el);
    free(x->ev);
    for (int i = 0; i < x->nns; i++) { free(x->ns_prefix_name[i]); free(x->ns_prefix_uri[i]); }
    pool_free(&x->pool);
    free(x->copy);
    memset(x, 0, sizeof *x);
}

const gxa_attr *gxa_find_attr(const gxa_elem *e, const char *name, uint32_t resid) {
    if (resid) for (int i = 0; i < e->nattr; i++) if (e->attr[i].resid == resid) return &e->attr[i];
    if (name) for (int i = 0; i < e->nattr; i++) if (!strcmp(e->attr[i].name, name)) return &e->attr[i];
    return NULL;
}

#pragma mark - ARSC

typedef struct {
    const uint8_t *chunk;
    uint8_t id, flags;
    uint32_t count, entries_start;
    uint16_t header_size;
    const uint8_t *config;
    uint32_t config_size;
    uint32_t size;
} arsc_type;

typedef struct {
    uint32_t id;
    gxa_pool types, keys;
    uint32_t type_id_offset;
    arsc_type *t;
    size_t nt;
} arsc_pkg;

struct gxa_arsc {
    uint8_t *copy;
    size_t len;
    gxa_pool strings;
    arsc_pkg *pkg;
    size_t npkg;
};

gxa_arsc *gxa_arsc_parse(const uint8_t *src, size_t len) {
    if (len < 12 || u16(src) != 0x0002) return NULL;
    gxa_arsc *a = calloc(1, sizeof *a);
    a->copy = malloc(len);
    memcpy(a->copy, src, len);
    a->len = len;
    const uint8_t *d = a->copy;
    size_t total = u32(d + 4);
    if (total > len) total = len;
    size_t p = u16(d + 2);
    int have_strings = 0;
    while (p + 8 <= total) {
        uint16_t type = u16(d + p), hs = u16(d + p + 2);
        uint32_t size = u32(d + p + 4);
        if (size < 8 || p + size > total) break;
        const uint8_t *c = d + p;
        if (hs < 8 || hs > size) { p += size; continue; }
        if (type == 0x0001 && !have_strings) {
            have_strings = pool_init(&a->strings, c, size);
        } else if (type == 0x0200 && size >= 288) {
            a->pkg = realloc(a->pkg, (a->npkg + 1) * sizeof(arsc_pkg));
            arsc_pkg *k = &a->pkg[a->npkg++];
            memset(k, 0, sizeof *k);
            k->id = u32(c + 8);
            uint32_t ts = u32(c + 268), ks = u32(c + 276);
            k->type_id_offset = hs >= 288 ? u32(c + 284) : 0;
            if (ts && ts < size) pool_init(&k->types, c + ts, size - ts);
            if (ks && ks < size) pool_init(&k->keys, c + ks, size - ks);
            size_t q = hs, cap = 0;
            while (q + 8 <= size) {
                uint16_t t2 = u16(c + q), hs2 = u16(c + q + 2);
                uint32_t s2 = u32(c + q + 4);
                if (s2 < 8 || q + s2 > size) break;
                if (t2 == 0x0201 && s2 >= 20 + 4 && hs2 >= 20 && hs2 <= s2) {
                    const uint8_t *tc = c + q;
                    if (k->nt == cap) { cap = cap ? cap * 2 : 64; k->t = realloc(k->t, cap * sizeof(arsc_type)); }
                    arsc_type *ty = &k->t[k->nt++];
                    ty->chunk = tc;
                    ty->size = s2;
                    ty->header_size = hs2;
                    ty->id = tc[8];
                    ty->flags = tc[9];
                    ty->count = u32(tc + 12);
                    ty->entries_start = u32(tc + 16);
                    ty->config = tc + 20;
                    ty->config_size = u32(tc + 20);
                    if (ty->config_size > (uint32_t)hs2 - 20) ty->config_size = (uint32_t)hs2 - 20;
                }
                q += s2;
            }
        }
        p += size;
    }
    return a;
}

void gxa_arsc_free(gxa_arsc *a) {
    if (!a) return;
    pool_free(&a->strings);
    for (size_t i = 0; i < a->npkg; i++) { pool_free(&a->pkg[i].types); pool_free(&a->pkg[i].keys); free(a->pkg[i].t); }
    free(a->pkg);
    free(a->copy);
    free(a);
}

static arsc_pkg *find_pkg(gxa_arsc *a, uint32_t pid) {
    for (size_t i = 0; i < a->npkg; i++) if (a->pkg[i].id == pid) return &a->pkg[i];
    // динамические id (shared library) — берём единственный пакет
    if (a->npkg == 1 && (pid == 0 || pid == 0x7f)) return &a->pkg[0];
    return NULL;
}

// Смещение записи внутри чанка типа, либо -1
static long entry_offset(const arsc_type *t, uint32_t eid) {
    const uint8_t *offs = t->chunk + t->header_size;
    const uint8_t *end = t->chunk + t->size;
    if (t->flags & 0x01) { // sparse
        for (uint32_t i = 0; i < t->count; i++) {
            const uint8_t *e = offs + i * 4;
            if (e + 4 > end) break;
            if (u16(e) == eid) return (long)u16(e + 2) * 4;
            if (u16(e) > eid) break;
        }
        return -1;
    }
    if (eid >= t->count) return -1;
    if (t->flags & 0x02) { // offset16
        const uint8_t *e = offs + eid * 2;
        if (e + 2 > end) return -1;
        uint16_t v = u16(e);
        return v == 0xFFFF ? -1 : (long)v * 4;
    }
    const uint8_t *e = offs + eid * 4;
    if (e + 4 > end) return -1;
    uint32_t v = u32(e);
    return v == 0xFFFFFFFFu ? -1 : (long)v;
}

int gxa_arsc_values(gxa_arsc *a, uint32_t id, gxa_value *out, int max) {
    if (!a) return 0;
    arsc_pkg *k = find_pkg(a, id >> 24);
    if (!k) return 0;
    uint8_t tid = (id >> 16) & 0xFF;
    uint32_t eid = id & 0xFFFF;
    int n = 0;
    for (size_t i = 0; i < k->nt && n < max; i++) {
        arsc_type *t = &k->t[i];
        if (t->id != tid) continue;
        long off = entry_offset(t, eid);
        if (off < 0) continue;
        const uint8_t *e = t->chunk + t->entries_start + off;
        if (e + 8 > t->chunk + t->size) continue;
        uint16_t esize = u16(e), eflags = u16(e + 2);
        gxa_value *v = &out[n];
        memset(v, 0, sizeof *v);
        if (eflags & 0x0008) { // compact
            v->type = (uint8_t)(eflags >> 8);
            v->data = u32(e + 4);
        } else if (eflags & 0x0001) { // complex (bag) — пропускаем
            continue;
        } else {
            const uint8_t *rv = e + esize;
            if (rv + 8 > t->chunk + t->size) continue;
            v->type = rv[3];
            v->data = u32(rv + 4);
        }
        if (v->type == GXA_T_STRING) v->str = gxa_pool_get(&a->strings, v->data);
        const uint8_t *cf = t->config;
        if (t->config_size >= 16) {
            v->density = u16(cf + 14);
            if (cf[8] && !(cf[8] & 0x80)) { v->lang[0] = (char)cf[8]; v->lang[1] = (char)cf[9]; }
            if (cf[10] && !(cf[10] & 0x80)) { v->region[0] = (char)cf[10]; v->region[1] = (char)cf[11]; }
        }
        if (t->config_size >= 28) v->version = u16(cf + 24);            // sdkVersion
        if (t->config_size >= 32) v->night = (cf[29] & 0x30) == 0x20;   // uiMode night
        n++;
    }
    return n;
}

const char *gxa_arsc_name(gxa_arsc *a, uint32_t id, char *buf, size_t n) {
    arsc_pkg *k = a ? find_pkg(a, id >> 24) : NULL;
    if (!k) { snprintf(buf, n, "@0x%08x", id); return buf; }
    uint8_t tid = (id >> 16) & 0xFF;
    const char *tname = gxa_pool_get(&k->types, (uint32_t)(tid - 1 - k->type_id_offset));
    const char *kname = NULL;
    for (size_t i = 0; i < k->nt && !kname; i++) {
        arsc_type *t = &k->t[i];
        if (t->id != tid) continue;
        long off = entry_offset(t, id & 0xFFFF);
        if (off < 0) continue;
        const uint8_t *e = t->chunk + t->entries_start + off;
        if (e + 8 > t->chunk + t->size) continue;
        uint16_t eflags = u16(e + 2);
        uint32_t key = (eflags & 0x0008) ? u16(e) : u32(e + 4);
        kname = gxa_pool_get(&k->keys, key);
    }
    if (tname[0] && kname && kname[0]) snprintf(buf, n, "@%s/%s", tname, kname);
    else snprintf(buf, n, "@0x%08x", id);
    return buf;
}

#pragma mark - текст

static float complex_to_float(uint32_t c) {
    static const float mult[4] = {1.0f / (1 << 8), 1.0f / (1 << 15), 1.0f / (1 << 23), 1.0f / (1u << 31)};
    return (float)(int32_t)(c & 0xFFFFFF00u) * mult[(c >> 4) & 3];
}

const char *gxa_format_value(uint8_t type, uint32_t data, const char *str, gxa_arsc *a, char *buf, size_t n) {
    static const char *dimen[] = {"px", "dp", "sp", "pt", "in", "mm"};
    switch (type) {
        case GXA_T_STRING: snprintf(buf, n, "%s", str ? str : ""); break;
        case GXA_T_REF: case GXA_T_DYN_REF:
            if (!data) snprintf(buf, n, "@null");
            else gxa_arsc_name(a, data, buf, n);
            break;
        case GXA_T_ATTR: snprintf(buf, n, "?0x%08x", data); break;
        case GXA_T_INT_DEC: snprintf(buf, n, "%d", (int32_t)data); break;
        case GXA_T_INT_HEX: snprintf(buf, n, "0x%x", data); break;
        case GXA_T_BOOL: snprintf(buf, n, "%s", data ? "true" : "false"); break;
        case GXA_T_FLOAT: { float f; memcpy(&f, &data, 4); snprintf(buf, n, "%g", f); break; }
        case GXA_T_DIMEN: { uint32_t u = data & 0xF; snprintf(buf, n, "%g%s", complex_to_float(data), u < 6 ? dimen[u] : ""); break; }
        case GXA_T_FRACTION: snprintf(buf, n, "%g%s", complex_to_float(data) * 100, (data & 0xF) ? "%p" : "%"); break;
        case GXA_T_COLOR_ARGB8: case GXA_T_COLOR_RGB8: case GXA_T_COLOR_ARGB4: case GXA_T_COLOR_RGB4:
            snprintf(buf, n, "#%08x", data); break;
        case GXA_T_NULL: snprintf(buf, n, "%s", str ? str : ""); break;
        default: if (str) snprintf(buf, n, "%s", str); else snprintf(buf, n, GXT("0x%x (тип %u)"), data, type); break;
    }
    return buf;
}

typedef struct { char *b; size_t len, cap; } sbuf;
static void sb_put(sbuf *s, const char *t, size_t n) {
    if (s->len + n + 1 > s->cap) {
        size_t nc = s->cap ? s->cap * 2 : 4096;
        while (nc < s->len + n + 1) nc *= 2;
        s->b = realloc(s->b, nc);
        s->cap = nc;
    }
    memcpy(s->b + s->len, t, n);
    s->len += n;
    s->b[s->len] = 0;
}
static void sb_str(sbuf *s, const char *t) { sb_put(s, t, strlen(t)); }
static void sb_esc(sbuf *s, const char *t) {
    for (; *t; t++) {
        switch (*t) {
            case '&': sb_str(s, "&amp;"); break;
            case '<': sb_str(s, "&lt;"); break;
            case '>': sb_str(s, "&gt;"); break;
            case '"': sb_str(s, "&quot;"); break;
            case '\n': sb_str(s, "&#10;"); break;
            default: sb_put(s, t, 1);
        }
    }
}
static void sb_indent(sbuf *s, int d) { for (int i = 0; i < d; i++) sb_str(s, "    "); }

static const char *prefix_for(gxa_xml *x, const char *uri) {
    if (!uri || !uri[0]) return NULL;
    for (int i = 0; i < x->nns; i++) if (!strcmp(x->ns_prefix_uri[i], uri)) return x->ns_prefix_name[i];
    if (strstr(uri, "android.com/apk/res/android")) return "android";
    return NULL;
}

char *gxa_xml_to_text(gxa_xml *x, gxa_arsc *a) {
    sbuf s = {0};
    sb_str(&s, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    char buf[1024];
    for (size_t i = 0; i < x->nev; i++) {
        int ev = x->ev[i];
        if (ev >= 0) {
            gxa_elem *e = &x->el[ev];
            sb_indent(&s, e->depth);
            sb_str(&s, "<");
            sb_str(&s, e->name);
            if (ev == 0) for (int k = 0; k < x->nns; k++) {
                sb_str(&s, "\n"); sb_indent(&s, e->depth + 2);
                sb_str(&s, "xmlns:"); sb_str(&s, x->ns_prefix_name[k]); sb_str(&s, "=\""); sb_esc(&s, x->ns_prefix_uri[k]); sb_str(&s, "\"");
            }
            for (int k = 0; k < e->nattr; k++) {
                gxa_attr *at = &e->attr[k];
                sb_str(&s, "\n"); sb_indent(&s, e->depth + 2);
                const char *pre = prefix_for(x, at->ns);
                if (pre && pre[0]) { sb_str(&s, pre); sb_str(&s, ":"); }
                if (at->name[0]) sb_str(&s, at->name);
                else { snprintf(buf, sizeof buf, "attr_0x%08x", at->resid); sb_str(&s, buf); }
                sb_str(&s, "=\"");
                const char *v = (at->type == GXA_T_STRING || (at->type == GXA_T_NULL && at->str)) ? (at->str ? at->str : "")
                               : gxa_format_value(at->type, at->data, at->str, a, buf, sizeof buf);
                sb_esc(&s, v);
                sb_str(&s, "\"");
            }
            // пустой элемент — если следующее событие закрывает его же
            if (i + 1 < x->nev && x->ev[i + 1] == -ev - 1) { sb_str(&s, " />\n"); i++; }
            else sb_str(&s, ">\n");
        } else {
            gxa_elem *e = &x->el[-ev - 1];
            sb_indent(&s, e->depth);
            sb_str(&s, "</"); sb_str(&s, e->name); sb_str(&s, ">\n");
        }
    }
    return s.b ? s.b : strdup("");
}

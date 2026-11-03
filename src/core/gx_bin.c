#include "gx_tr.h"
#include "gx_bin.h"
#include "gx_a64.h"
#include "gx_sha256.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static uint16_t L16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t L32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t L64(const uint8_t *p) { return (uint64_t)L32(p) | (uint64_t)L32(p + 4) << 32; }
static uint32_t B32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void PB32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void PB64(uint8_t *p, uint64_t v) { PB32(p, (uint32_t)(v >> 32)); PB32(p + 4, (uint32_t)v); }
static void PL32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void PL64(uint8_t *p, uint64_t v) { PL32(p, (uint32_t)v); PL32(p + 4, (uint32_t)(v >> 32)); }

static const char *cpu_name(uint32_t t, uint32_t st) {
    switch (t) {
        case 0x0100000C: return (st & 0xFF) == 2 ? "arm64e" : "arm64";
        case 0x0200000C: return "arm64_32";
        case 12: return "armv7";
        case 0x01000007: return "x86_64";
        case 7: return "i386";
    }
    return "?";
}

int gx_bin_slices(const uint8_t *d, size_t len, char names[][24], size_t *offs, size_t *sizes, int max) {
    if (len >= 8 && B32(d) == 0xCAFEBABE) {
        uint32_t n = B32(d + 4);
        if (n > 0 && n < 32 && 8 + (size_t)n * 20 <= len) {
            int k = 0;
            for (uint32_t i = 0; i < n && k < max; i++) {
                const uint8_t *a = d + 8 + i * 20;
                size_t o = B32(a + 8), s = B32(a + 12);
                if (o > len || s > len - o) continue;
                snprintf(names[k], 24, "%s", cpu_name(B32(a), B32(a + 4)));
                offs[k] = o; sizes[k] = s; k++;
            }
            if (k) return k;
        }
    }
    snprintf(names[0], 24, "%s", GXT("весь файл"));
    offs[0] = 0; sizes[0] = len;
    return 1;
}

static void add_sect(gx_bin *b, int *cap, const char *name, uint64_t addr, uint64_t size, size_t off, int exec, int kind) {
    if (b->ns == *cap) { *cap = *cap ? *cap * 2 : 16; b->s = realloc(b->s, sizeof(gx_sect) * *cap); }
    gx_sect *s = &b->s[b->ns++];
    memset(s, 0, sizeof *s);
    snprintf(s->name, sizeof s->name, "%s", name);
    s->addr = addr; s->size = size; s->off = off; s->exec = (uint8_t)exec; s->kind = (uint8_t)kind;
    if (kind != GX_SK_ZERO && (off > b->len || size > b->len - off)) s->kind = GX_SK_ZERO;   // не в файле
}

static int cmp_name(const void *a, const void *c) { const gx_name *x = a, *y = c; return x->addr < y->addr ? -1 : x->addr > y->addr; }

static void add_name(gx_name **arr, size_t *n, size_t *cap, uint64_t addr, const char *nm, uint32_t nl) {
    if (*n == *cap) { *cap = *cap ? *cap * 2 : 256; *arr = realloc(*arr, sizeof(gx_name) * *cap); }
    (*arr)[(*n)++] = (gx_name){addr, nm, nl};
}

// уникальные по адресу, предпочитая именованные
static void uniq_names(gx_name *a, size_t *n) {
    if (!*n) return;
    qsort(a, *n, sizeof *a, cmp_name);
    size_t k = 0;
    for (size_t i = 0; i < *n; i++) {
        if (k && a[k - 1].addr == a[i].addr) { if (!a[k - 1].name && a[i].name) a[k - 1] = a[i]; continue; }
        a[k++] = a[i];
    }
    *n = k;
}

static const char *strtab_name(const gx_bin *b, size_t stroff, size_t strsize, uint32_t idx, uint32_t *nl) {
    if (idx >= strsize || stroff + idx >= b->len) return NULL;
    const char *s = (const char *)b->d + stroff + idx;
    size_t lim = strsize - idx;
    if (stroff + strsize > b->len) lim = b->len - stroff - idx;
    size_t l = strnlen(s, lim);
    if (!l || l == lim) return NULL;
    *nl = (uint32_t)l;
    return s;
}


static uint64_t uleb(const uint8_t **p, const uint8_t *e) {
    uint64_t v = 0; int sh = 0;
    while (*p < e) { uint8_t c = *(*p)++; if (sh < 64) v |= (uint64_t)(c & 0x7F) << sh; sh += 7; if (!(c & 0x80)) break; }
    return v;
}
static int64_t sleb(const uint8_t **p, const uint8_t *e) {
    int64_t v = 0; int sh = 0; uint8_t c = 0;
    while (*p < e) { c = *(*p)++; if (sh < 64) v |= (int64_t)(c & 0x7F) << sh; sh += 7; if (!(c & 0x80)) break; }
    if (sh < 64 && (c & 0x40)) v |= -((int64_t)1 << sh);
    return v;
}

static void parse_chained(gx_bin *b, const uint8_t *h, size_t sz) {
    uint32_t startsoff = L32(h + 4), impoff = L32(h + 8), symoff = L32(h + 12), nimp = L32(h + 16), impfmt = L32(h + 20);
    if (startsoff + 4 <= sz) {
        uint32_t segs = L32(h + startsoff);
        for (uint32_t i = 0; i < segs && i < 64 && startsoff + 4 + (size_t)(i + 1) * 4 <= sz; i++) {
            uint32_t o = L32(h + startsoff + 4 + i * 4);
            if (!o || (size_t)startsoff + o + 8 > sz) continue;
            b->chain_fmt = L16(h + startsoff + o + 6);
            if (b->chain_fmt) break;
        }
    }
    size_t isz = impfmt == 1 ? 4 : impfmt == 2 ? 8 : impfmt == 3 ? 16 : 0;
    if (isz && impoff <= sz && (uint64_t)nimp * isz <= sz - impoff && symoff <= sz) {
        b->ch_imports = h + impoff; b->ch_nimports = nimp; b->ch_impfmt = impfmt;
        b->ch_syms = h + symoff; b->ch_symsize = sz - symoff;
    }
}

static const char *chained_import(const gx_bin *b, uint32_t ord, uint32_t *nl) {
    if (!b->ch_imports || ord >= b->ch_nimports) return NULL;
    uint32_t noff;
    if (b->ch_impfmt == 1) noff = L32(b->ch_imports + ord * 4) >> 9;
    else if (b->ch_impfmt == 2) noff = L32(b->ch_imports + ord * 8) >> 9;
    else noff = L32(b->ch_imports + (size_t)ord * 16 + 4);
    if (noff >= b->ch_symsize) return NULL;
    const char *s = (const char *)b->ch_syms + noff;
    size_t l = strnlen(s, b->ch_symsize - noff);
    if (!l || l == b->ch_symsize - noff) return NULL;
    *nl = (uint32_t)l;
    return s;
}

static void parse_binds(gx_bin *b, const uint8_t *p, size_t sz, int lazy) {
    const uint8_t *e = p + sz;
    const char *sym = NULL; uint32_t sl = 0;
    int seg = 0; uint64_t off = 0;
    size_t cap = b->nbind;
    while (p < e) {
        uint8_t c = *p++, op = c & 0xF0, imm = c & 0x0F;
        switch (op) {
            case 0x00: if (!lazy) return; break;
            case 0x10: case 0x30: break;
            case 0x20: uleb(&p, e); break;
            case 0x40: { const char *s = (const char *)p; size_t l = strnlen(s, (size_t)(e - p)); if (l == (size_t)(e - p)) return; sym = s; sl = (uint32_t)l; p += l + 1; break; }
            case 0x50: break;
            case 0x60: sleb(&p, e); break;
            case 0x70: seg = imm; off = uleb(&p, e); break;
            case 0x80: off += uleb(&p, e); break;
            case 0x90: case 0xA0: case 0xB0: case 0xC0: {
                uint64_t cnt = 1, skip = 0;
                if (op == 0xC0) { cnt = uleb(&p, e); skip = uleb(&p, e); if (cnt > 100000) return; }
                for (uint64_t k = 0; k < cnt; k++) {
                    if (sym && seg < b->nseg) {
                        if (b->nbind == cap) { cap = cap ? cap * 2 : 256; b->bind = realloc(b->bind, sizeof(gx_name) * cap); }
                        b->bind[b->nbind++] = (gx_name){b->seg[seg].vm + off, sym, sl};
                    }
                    off += 8 + skip;
                }
                if (op == 0xA0) off += uleb(&p, e);
                else if (op == 0xB0) off += (uint64_t)imm * 8;
                break;
            }
            default: return;
        }
    }
}

static int open_macho(gx_bin *b) {
    const uint8_t *h = b->d + b->base;
    if (b->slen < 32 || L32(h) != 0xFEEDFACF) return 0;
    uint32_t cpu = L32(h + 4), sub = L32(h + 8), ft = L32(h + 12), ncmds = L32(h + 16), szc = L32(h + 20);
    if (32 + (size_t)szc > b->slen) return 0;
    b->fmt = 1;
    b->arm64 = cpu == 0x0100000C;
    snprintf(b->arch, sizeof b->arch, "%s", cpu_name(cpu, sub));
    snprintf(b->type, sizeof b->type, "%s", ft == 2 ? GXT("исполняемый") : ft == 6 ? "dylib" : ft == 8 ? "bundle" : ft == 1 ? GXT("объектный") : ft == 0xB ? "dSYM/kext" : "Mach-O");
    int scap = 0, gcap = 0;
    size_t symoff = 0, nsyms = 0, stroff = 0, strsize = 0, indoff = 0, nind = 0, fsoff = 0, fssize = 0;
    size_t choff = 0, chsize = 0, bindoff[3] = {0}, bindsz[3] = {0};
    b->vmlo = UINT64_MAX; b->vmhi = 0;
    const uint8_t *p = h + 32, *end = h + 32 + szc;
    for (uint32_t i = 0; i < ncmds && p + 8 <= end; i++) {
        uint32_t cmd = L32(p), cs = L32(p + 4);
        if (cs < 8 || p + cs > end) break;
        if (cmd == 0x19 && cs >= 72) {
            char segname[17] = {0}; memcpy(segname, p + 8, 16);
            uint64_t vm = L64(p + 24), vms = L64(p + 32), fo = L64(p + 40), fs = L64(p + 48);
            uint32_t ns = L32(p + 64);
            if (b->nseg == gcap) { gcap = gcap ? gcap * 2 : 8; b->seg = realloc(b->seg, sizeof(gx_seg) * gcap); }
            b->seg[b->nseg++] = (gx_seg){vm, vms, b->base + (size_t)fo, (size_t)fs};
            if (strcmp(segname, "__PAGEZERO")) {
                if (vm < b->vmlo) b->vmlo = vm;
                if (vm + vms > b->vmhi) b->vmhi = vm + vms;
            }
            if (!strcmp(segname, "__TEXT")) b->image_base = vm;
            for (uint32_t k = 0; k < ns && 72 + (size_t)(k + 1) * 80 <= cs; k++) {
                const uint8_t *s = p + 72 + k * 80;
                char sn[17] = {0}, gn[17] = {0}, full[40];
                memcpy(sn, s, 16); memcpy(gn, s + 16, 16);
                snprintf(full, sizeof full, "%s,%s", gn, sn);
                uint64_t addr = L64(s + 32), size = L64(s + 40);
                uint32_t off = L32(s + 48), fl = L32(s + 64), type = fl & 0xFF;
                int exec = (fl & 0x80000000u) || (fl & 0x400);
                int kind = GX_SK_NORMAL;
                if (type == 1 || type == 0xC || type == 0x12 || type == 0x13 || type == 0x10) kind = GX_SK_ZERO;
                else if (type == 2) kind = GX_SK_CSTRING;
                else if (!strcmp(sn, "__ustring")) kind = GX_SK_USTRING;
                else if (!strcmp(sn, "__cfstring")) kind = GX_SK_CFSTRING;
                else if (!strncmp(sn, "__objc_", 7) && type != 2) kind = GX_SK_SKIP;
                else if (!strcmp(sn, "__unwind_info") || !strcmp(sn, "__eh_frame") || !strcmp(sn, "__gcc_except_tab") || !strcmp(sn, "__got") || !strcmp(sn, "__la_symbol_ptr") || !strcmp(sn, "__auth_got") || !strcmp(sn, "__auth_ptr") || !strncmp(sn, "__swift5_", 9) || !strcmp(sn, "__init_offsets") || !strcmp(sn, "__mod_init_func")) kind = GX_SK_SKIP;
                add_sect(b, &scap, full, addr, size, b->base + off, exec, kind);
                // заглушки / указатели на импорты — запомним в reserved1/2 через отдельный проход
            }
        } else if (cmd == 0x2 && cs >= 24) { symoff = L32(p + 8); nsyms = L32(p + 12); stroff = L32(p + 16); strsize = L32(p + 20); }
        else if (cmd == 0xB && cs >= 80) { indoff = L32(p + 56); nind = L32(p + 60); }
        else if (cmd == 0x26 && cs >= 16) { fsoff = L32(p + 8); fssize = L32(p + 12); }
        else if (cmd == 0x1D && cs >= 16) { b->sig_off = b->base + L32(p + 8); b->sig_size = L32(p + 12); }
        else if ((cmd == 0x2C || cmd == 0x21) && cs >= 20) { if (L32(p + 16)) b->encrypted = 1; }
        else if (cmd == 0x80000034 && cs >= 16) { choff = L32(p + 8); chsize = L32(p + 12); }
        else if ((cmd == 0x22 || cmd == 0x80000022) && cs >= 48) {
            bindoff[0] = L32(p + 16); bindsz[0] = L32(p + 20);
            bindoff[1] = L32(p + 24); bindsz[1] = L32(p + 28);
            bindoff[2] = L32(p + 32); bindsz[2] = L32(p + 36);
        }
        p += cs;
    }
    if (b->vmlo == UINT64_MAX) b->vmlo = 0;
    size_t fcap = 0, icap = 0;
    if (choff && chsize >= 28 && b->base + choff + chsize <= b->len) parse_chained(b, b->d + b->base + choff, chsize);
    for (int k = 0; k < 3; k++) if (bindoff[k] && bindsz[k] && b->base + bindoff[k] + bindsz[k] <= b->len) parse_binds(b, b->d + b->base + bindoff[k], bindsz[k], k == 2);
    if (b->nbind) uniq_names(b->bind, &b->nbind);
    // символы
    if (symoff && nsyms && b->base + symoff + nsyms * 16 <= b->len && b->base + stroff + strsize <= b->len) {
        const uint8_t *st = b->d + b->base + symoff;
        for (size_t i = 0; i < nsyms; i++) {
            const uint8_t *e = st + i * 16;
            uint8_t t = e[4], sec = e[5];
            if ((t & 0xE0) || (t & 0x0E) != 0x0E || !sec || sec > b->ns) continue;
            if (!b->s[sec - 1].exec) continue;
            uint32_t nl = 0;
            const char *nm = strtab_name(b, b->base + stroff, strsize, L32(e), &nl);
            add_name(&b->fn, &b->nfn, &fcap, L64(e + 8), nm, nl);
        }
    }
    // function starts
    if (fsoff && fssize && b->base + fsoff + fssize <= b->len) {
        const uint8_t *q = b->d + b->base + fsoff, *qe = q + fssize;
        uint64_t a = b->image_base;
        while (q < qe) {
            uint64_t v = 0; int sh = 0;
            while (q < qe) { uint8_t c = *q++; v |= (uint64_t)(c & 0x7F) << sh; sh += 7; if (!(c & 0x80) || sh > 63) break; }
            if (!v) break;
            a += v;
            add_name(&b->fn, &b->nfn, &fcap, a, NULL, 0);
        }
    }
    uniq_names(b->fn, &b->nfn);
    // импорты: секции stubs (тип 8) и указатели (6, 7) через таблицу косвенных символов
    if (indoff && nind && b->base + indoff + nind * 4 <= b->len && symoff && b->base + symoff + nsyms * 16 <= b->len) {
        const uint8_t *q = h + 32;
        for (uint32_t i = 0; i < ncmds && q + 8 <= end; i++) {
            uint32_t cmd = L32(q), cs = L32(q + 4);
            if (cs < 8 || q + cs > end) break;
            if (cmd == 0x19) {
                uint32_t ns = L32(q + 64);
                for (uint32_t k = 0; k < ns && 72 + (size_t)(k + 1) * 80 <= cs; k++) {
                    const uint8_t *s = q + 72 + k * 80;
                    uint32_t fl = L32(s + 64), type = fl & 0xFF, r1 = L32(s + 68), r2 = L32(s + 72);
                    uint64_t addr = L64(s + 32), size = L64(s + 40);
                    uint32_t esz = type == 8 ? r2 : (type == 6 || type == 7 || type == 0x11) ? 8 : 0;
                    if (!esz) continue;
                    for (uint64_t j = 0; j < size / esz && r1 + j < nind; j++) {
                        uint32_t si = L32(b->d + b->base + indoff + (r1 + j) * 4);
                        if (si & 0xC0000000u || si >= nsyms) continue;
                        uint32_t nl = 0;
                        const char *nm = strtab_name(b, b->base + stroff, strsize, L32(b->d + b->base + symoff + (size_t)si * 16), &nl);
                        if (nm) add_name(&b->imp, &b->nimp, &icap, addr + j * esz, nm, nl);
                    }
                }
            }
            q += cs;
        }
        uniq_names(b->imp, &b->nimp);
    }
    return 1;
}

static int open_elf(gx_bin *b) {
    const uint8_t *h = b->d + b->base;
    if (b->slen < 64 || memcmp(h, "\x7f" "ELF", 4) || h[4] != 2 || h[5] != 1) return 0;
    b->fmt = 2;
    uint16_t mach = L16(h + 18), et = L16(h + 16);
    b->arm64 = mach == 183;
    snprintf(b->arch, sizeof b->arch, "%s", mach == 183 ? "arm64" : mach == 62 ? "x86_64" : mach == 40 ? "arm" : "?");
    snprintf(b->type, sizeof b->type, "%s", et == 3 ? "ELF .so" : et == 2 ? GXT("ELF исполняемый") : "ELF");
    uint64_t phoff = L64(h + 32), shoff = L64(h + 40);
    uint16_t phes = L16(h + 54), phn = L16(h + 56), shes = L16(h + 58), shn = L16(h + 60), shstr = L16(h + 62);
    int gcap = 0, scap = 0;
    b->vmlo = UINT64_MAX; b->vmhi = 0;
    if (phes >= 56 && phoff < b->slen && (uint64_t)phn * phes <= b->slen - phoff) {
        for (int i = 0; i < phn; i++) {
            const uint8_t *ph = h + phoff + (size_t)i * phes;
            if (L32(ph) != 1) continue;
            uint64_t off = L64(ph + 8), va = L64(ph + 16), fs = L64(ph + 32), ms = L64(ph + 40);
            if (b->nseg == gcap) { gcap = gcap ? gcap * 2 : 8; b->seg = realloc(b->seg, sizeof(gx_seg) * gcap); }
            b->seg[b->nseg++] = (gx_seg){va, ms, b->base + (size_t)off, (size_t)fs};
            if (va < b->vmlo) b->vmlo = va;
            if (va + ms > b->vmhi) b->vmhi = va + ms;
        }
    }
    if (b->vmlo == UINT64_MAX) b->vmlo = 0;
    if (shes < 64 || shoff >= b->slen || (uint64_t)shn * shes > b->slen - shoff || shstr >= shn) return 1;
    const uint8_t *sh0 = h + shoff;
    const uint8_t *strsh = sh0 + (size_t)shstr * shes;
    uint64_t stro = L64(strsh + 24), strs = L64(strsh + 32);
    size_t fcap = 0, icap = 0;
    int plt = -1, relaplt = -1;
    for (int i = 0; i < shn; i++) {
        const uint8_t *s = sh0 + (size_t)i * shes;
        uint32_t nmi = L32(s), type = L32(s + 4);
        uint64_t fl = L64(s + 8), addr = L64(s + 16), off = L64(s + 24), size = L64(s + 32);
        char nm[40] = "?";
        if (stro + nmi < b->slen && nmi < strs) { const char *x = (const char *)h + stro + nmi; size_t l = strnlen(x, b->slen - stro - nmi); if (l < sizeof nm) { memcpy(nm, x, l); nm[l] = 0; } }
        int kind = GX_SK_NORMAL;
        if (type == 8) kind = GX_SK_ZERO;
        else if (type != 1 && type != 14 && type != 15) kind = GX_SK_SKIP;
        else if (!strncmp(nm, ".eh_frame", 9) || !strcmp(nm, ".got") || !strcmp(nm, ".got.plt") || !strcmp(nm, ".gcc_except_table") || !strncmp(nm, ".note", 5) || !strcmp(nm, ".comment") || !strncmp(nm, ".debug", 6)) kind = GX_SK_SKIP;
        if (!(fl & 2) && type == 1 && !strncmp(nm, ".debug", 6)) kind = GX_SK_SKIP;
        if (!strcmp(nm, ".plt")) plt = i;
        if (!strcmp(nm, ".rela.plt")) relaplt = i;
        add_sect(b, &scap, nm, addr, size, b->base + (size_t)off, (fl & 4) != 0, kind);
    }
    // символы функций
    for (int i = 0; i < shn; i++) {
        const uint8_t *s = sh0 + (size_t)i * shes;
        uint32_t type = L32(s + 4), link = L32(s + 40);
        if ((type != 2 && type != 11) || link >= shn) continue;
        uint64_t off = L64(s + 24), size = L64(s + 32);
        const uint8_t *ls = sh0 + (size_t)link * shes;
        uint64_t so = L64(ls + 24), ss = L64(ls + 32);
        if (off > b->slen || size > b->slen - off || so > b->slen || ss > b->slen - so) continue;
        for (uint64_t k = 0; k + 24 <= size; k += 24) {
            const uint8_t *e = h + off + k;
            if ((e[4] & 15) != 2 || !L16(e + 6)) continue;
            uint32_t nl = 0;
            const char *nm = strtab_name(b, b->base + so, ss, L32(e), &nl);
            add_name(&b->fn, &b->nfn, &fcap, L64(e + 8), nm, nl);
        }
    }
    uniq_names(b->fn, &b->nfn);
    // слоты GOT/данных с внешними символами (GLOB_DAT, ABS64) → имена
    {
        size_t bcap = 0;
        for (int i = 0; i < shn; i++) {
            const uint8_t *rs = sh0 + (size_t)i * shes;
            if (L32(rs + 4) != 4) continue;
            uint64_t ro = L64(rs + 24), rsz = L64(rs + 32);
            uint32_t link = L32(rs + 40);
            if (link >= shn || ro > b->slen || rsz > b->slen - ro) continue;
            const uint8_t *ds = sh0 + (size_t)link * shes;
            uint64_t dso = L64(ds + 24), dss = L64(ds + 32);
            uint32_t dl = L32(ds + 40);
            if (dl >= shn || dso > b->slen || dss > b->slen - dso) continue;
            const uint8_t *dst = sh0 + (size_t)dl * shes;
            uint64_t so = L64(dst + 24), ss = L64(dst + 32);
            for (uint64_t k = 0; k + 24 <= rsz; k += 24) {
                uint64_t info = L64(h + ro + k + 8);
                uint32_t ty = (uint32_t)info, si = (uint32_t)(info >> 32);
                if ((ty != 1025 && ty != 257) || !si || (uint64_t)si * 24 + 24 > dss) continue;
                uint32_t nl = 0;
                const char *nm = strtab_name(b, b->base + so, ss, L32(h + dso + (size_t)si * 24), &nl);
                if (!nm) continue;
                if (b->nbind == bcap) { bcap = bcap ? bcap * 2 : 64; b->bind = realloc(b->bind, sizeof(gx_name) * bcap); }
                b->bind[b->nbind++] = (gx_name){L64(h + ro + k), nm, nl};
            }
        }
        if (b->nbind) uniq_names(b->bind, &b->nbind);
    }
    // PLT → имена
    if (plt >= 0 && relaplt >= 0) {
        const uint8_t *rs = sh0 + (size_t)relaplt * shes;
        uint64_t ro = L64(rs + 24), rsz = L64(rs + 32);
        uint32_t link = L32(rs + 40);
        uint64_t pa = L64(sh0 + (size_t)plt * shes + 16);
        if (link < shn && ro <= b->slen && rsz <= b->slen - ro) {
            const uint8_t *ds = sh0 + (size_t)link * shes;
            uint64_t dso = L64(ds + 24), dss = L64(ds + 32);
            uint32_t dl = L32(ds + 40);
            if (dl < shn && dso <= b->slen && dss <= b->slen - dso) {
                const uint8_t *dst = sh0 + (size_t)dl * shes;
                uint64_t so = L64(dst + 24), ss = L64(dst + 32);
                for (uint64_t k = 0, i = 0; k + 24 <= rsz; k += 24, i++) {
                    uint32_t si = (uint32_t)(L64(h + ro + k + 8) >> 32);
                    if ((uint64_t)si * 24 + 24 > dss) continue;
                    uint32_t nl = 0;
                    const char *nm = strtab_name(b, b->base + so, ss, L32(h + dso + (size_t)si * 24), &nl);
                    if (nm) add_name(&b->imp, &b->nimp, &icap, pa + 32 + i * 16, nm, nl);
                }
                uniq_names(b->imp, &b->nimp);
            }
        }
    }
    return 1;
}

int gx_bin_open(gx_bin *b, const uint8_t *d, size_t len, int slice) {
    memset(b, 0, sizeof *b);
    b->d = d; b->len = len;
    char names[16][24]; size_t offs[16], sizes[16];
    int n = gx_bin_slices(d, len, names, offs, sizes, 16);
    if (slice < 0 || slice >= n) slice = 0;
    b->base = offs[slice]; b->slen = sizes[slice];
    if (open_macho(b) || open_elf(b)) return 1;
    // сырой файл: одна «секция» на весь файл
    int cap = 0;
    b->fmt = 0;
    snprintf(b->arch, sizeof b->arch, "—");
    snprintf(b->type, sizeof b->type, GXT("файл"));
    add_sect(b, &cap, GXT("файл"), 0, b->slen, b->base, 0, GX_SK_NORMAL);
    return 1;
}

void gx_bin_close(gx_bin *b) { free(b->s); free(b->seg); free(b->fn); free(b->imp); free(b->bind); memset(b, 0, sizeof *b); }

int64_t gx_bin_a2o(const gx_bin *b, uint64_t a) {
    if (b->fmt == 0) return a < b->slen ? (int64_t)(b->base + a) : -1;
    for (int i = 0; i < b->nseg; i++) {
        const gx_seg *s = &b->seg[i];
        if (a >= s->vm && a < s->vm + s->fsize && a - s->vm < s->vmsize) { size_t o = s->off + (size_t)(a - s->vm); return o < b->len ? (int64_t)o : -1; }
    }
    return -1;
}
int gx_bin_o2a(const gx_bin *b, size_t off, uint64_t *a) {
    if (b->fmt == 0) { if (off < b->base || off >= b->base + b->slen) return 0; *a = off - b->base; return 1; }
    for (int i = 0; i < b->nseg; i++) {
        const gx_seg *s = &b->seg[i];
        if (off >= s->off && off < s->off + s->fsize && s->vmsize) { *a = s->vm + (off - s->off); return 1; }
    }
    return 0;
}
int gx_bin_sect_of_off(const gx_bin *b, size_t off) {
    for (int i = 0; i < b->ns; i++) if (b->s[i].kind != GX_SK_ZERO && off >= b->s[i].off && off < b->s[i].off + b->s[i].size) return i;
    return -1;
}
int gx_bin_sect_of_addr(const gx_bin *b, uint64_t a) {
    for (int i = 0; i < b->ns; i++) if (b->s[i].size && a >= b->s[i].addr && a < b->s[i].addr + b->s[i].size) return i;
    return -1;
}
const gx_name *gx_bin_func_of(const gx_bin *b, uint64_t a) {
    size_t lo = 0, hi = b->nfn;
    while (lo < hi) { size_t m = (lo + hi) / 2; if (b->fn[m].addr <= a) lo = m + 1; else hi = m; }
    if (!lo) return NULL;
    const gx_name *f = &b->fn[lo - 1];
    int s1 = gx_bin_sect_of_addr(b, f->addr), s2 = gx_bin_sect_of_addr(b, a);
    return s1 == s2 ? f : NULL;
}
const gx_name *gx_bin_import_at(const gx_bin *b, uint64_t a) {
    size_t lo = 0, hi = b->nimp;
    while (lo < hi) { size_t m = (lo + hi) / 2; if (b->imp[m].addr < a) lo = m + 1; else hi = m; }
    return lo < b->nimp && b->imp[lo].addr == a ? &b->imp[lo] : NULL;
}
uint64_t gx_bin_func_end(const gx_bin *b, uint64_t a) {
    int si = gx_bin_sect_of_addr(b, a);
    uint64_t end = si >= 0 ? b->s[si].addr + b->s[si].size : a + 4096;
    size_t lo = 0, hi = b->nfn;
    while (lo < hi) { size_t m = (lo + hi) / 2; if (b->fn[m].addr <= a) lo = m + 1; else hi = m; }
    if (lo < b->nfn && b->fn[lo].addr < end) end = b->fn[lo].addr;
    return end;
}

#pragma mark - строки

static int utf8_cp(const uint8_t *p, size_t n, uint32_t *cp) {
    uint8_t c = p[0];
    if (c < 0x80) { *cp = c; return 1; }
    int l = c >= 0xF0 && c <= 0xF4 ? 4 : c >= 0xE0 ? (c <= 0xEF ? 3 : 0) : c >= 0xC2 ? 2 : 0;
    if (!l || (size_t)l > n) return 0;
    uint32_t v = c & (0xFF >> (l + 1));
    for (int i = 1; i < l; i++) { if ((p[i] & 0xC0) != 0x80) return 0; v = v << 6 | (p[i] & 0x3F); }
    if ((l == 3 && v < 0x800) || (l == 4 && (v < 0x10000 || v > 0x10FFFF)) || (v >= 0xD800 && v <= 0xDFFF)) return 0;
    *cp = v;
    return l;
}
static int printable(uint32_t c) { return (c >= 0x20 && c != 0x7F && (c < 0x80 || c >= 0xA0)) || c == 9 || c == 10 || c == 13; }
// Классификация байта CP1251: 0 запрещён, 1 кириллическая согласная, 2 кириллическая гласная,
// 3 пробел/базовая пунктуация, 4 цифра
static int cp1251_cls(uint8_t c) {
    // гласные: А Е Ё И О У Ы Э Ю Я (и строчные) + Ё/ё
    static const char *vow = "\xC0\xC5\xC8\xCE\xD3\xDB\xDD\xDE\xDF\xE0\xE5\xE8\xEE\xF3\xFB\xFD\xFE\xFF\xA8\xB8";
    if (c >= 0xC0 || c == 0xA8 || c == 0xB8) { for (const char *p = vow; *p; p++) if ((uint8_t)*p == c) return 2; return 1; }
    if (c >= '0' && c <= '9') return 4;
    if (c == ' ' || c == '.' || c == ',' || c == '!' || c == '?' || c == ':' || c == ';' || c == '-' || c == '(' || c == ')' || c == '\n' || c == '\t' || c == '"' || c == '\'' || c == '%' || c == 0xAB || c == 0xBB) return 3;
    return 0;   // в т.ч. латиница, управляющие, @ # и прочее — верный признак не-текста
}
// Строгая проверка: похоже ли [i,k) на настоящую русскую строку CP1251
static int cp1251_upper(uint8_t c) { return (c >= 0xC0 && c <= 0xDF) || c == 0xA8; }
static int cp1251_badword(int wlen, int wup, int firstUp) {
    if (!wlen || wup == 0 || wup == wlen) return 0;   // всё строчными или всё ПРОПИСНЫМИ — ок
    if (wup == 1 && firstUp) return 0;                // Первая прописная — ок
    return 1;                                         // смешанный регистр (камелкейс) — мусор
}
static int cp1251_valid(const uint8_t *d, size_t i, size_t k) {
    int cyr = 0, vowels = 0, total = 0;
    int wlen = 0, wup = 0, firstUp = 0;
    for (size_t p = i; p < k; p++) {
        int cl = cp1251_cls(d[p]);
        if (!cl) return 0;
        total++;
        int isLetter = cl == 1 || cl == 2;
        if (cl == 2) vowels++;
        if (isLetter) {
            cyr++;
            int up = cp1251_upper(d[p]);
            if (!wlen) firstUp = up;
            if (up) wup++;
            wlen++;
        } else {
            if (cp1251_badword(wlen, wup, firstUp)) return 0;
            wlen = wup = 0;
        }
    }
    if (cp1251_badword(wlen, wup, firstUp)) return 0;
    if (cyr < 4 || vowels < 1) return 0;          // минимум 4 буквы и хотя бы одна гласная
    if (vowels * 6 < cyr) return 0;               // слишком мало гласных для русского
    if (cyr * 4 < total * 3) return 0;            // кириллица должна занимать ≥75%
    return 1;
}

typedef struct { gx_str *a; size_t n, cap; } strvec;
static void push(strvec *v, size_t off, size_t bl, int enc, int sect) {
    if (v->n == v->cap) { v->cap = v->cap ? v->cap * 2 : 1024; v->a = realloc(v->a, sizeof(gx_str) * v->cap); }
    v->a[v->n++] = (gx_str){off, (uint32_t)bl, (uint8_t)enc, 0, (int16_t)sect};
}

static void scan8(const uint8_t *d, size_t s, size_t e, int minlen, int lit, int sect, int allow_cp1251, strvec *v) {
    size_t i = s;
    while (i < e) {
        if (!d[i]) { i++; continue; }
        size_t j = i; int chars = 0, na = 0, letters = 0;
        while (j < e && d[j]) {
            uint32_t cp; int l = utf8_cp(d + j, e - j, &cp);
            if (!l || !printable(cp)) break;
            if (cp >= 0x80) na++;
            if ((cp | 32) >= 'a' && (cp | 32) <= 'z') letters++;
            j += l; chars++;
        }
        if (j < e && !d[j] && j > i) {
            int need = lit ? 1 : (na ? 2 : minlen);
            if (chars >= need && (lit || na || letters * 2 >= chars || chars >= 8)) push(v, i, j - i, GX_ENC_UTF8, sect);
            i = j + 1;
            continue;
        }
        // CP1251 — только для ELF/.so и сырых файлов; в Mach-O русский текст всегда UTF-8/UTF-16
        if (allow_cp1251) {
            size_t k = i;
            while (k < e && d[k] && cp1251_cls(d[k])) k++;
            if (k < e && !d[k] && cp1251_valid(d, i, k)) { push(v, i, k - i, GX_ENC_CP1251, sect); i = k + 1; continue; }
        }
        i = (j > i ? j : i) + 1;
    }
}

static void scan16(const uint8_t *d, size_t s, size_t e, int minlen, int sect, strvec *v) {
    size_t i = s + ((e - s) & 0);
    if ((i - s) & 1) i++;
    while (i + 2 <= e) {
        if (!L16(d + i)) { i += 2; continue; }
        size_t j = i; int chars = 0, good = 0;
        while (j + 2 <= e) {
            uint16_t c = L16(d + j);
            if (!c) break;
            if (c >= 0xD800 && c <= 0xDBFF && j + 4 <= e && L16(d + j + 2) >= 0xDC00 && L16(d + j + 2) <= 0xDFFF) { j += 4; chars++; good++; continue; }
            if (!printable(c) || (c >= 0xD800 && c <= 0xDFFF)) break;
            if ((c >= 'A' && c <= 'z') || (c >= 0x400 && c <= 0x4FF) || c == ' ') good++;
            j += 2; chars++;
        }
        if (j + 2 <= e && !L16(d + j) && chars >= minlen && good * 2 >= chars) { push(v, i, j - i, GX_ENC_UTF16, sect); i = j + 2; continue; }
        i = (j > i ? j : i) + 2;
    }
}

typedef struct { uint64_t target; size_t lenoff; uint64_t entry; } cfent;

// Разбор «сырого» указателя с учётом формата chained fixups. *bind_ord = -1 если не привязка
static uint64_t decode_raw(const gx_bin *b, uint64_t raw, int64_t *bind_ord) {
    *bind_ord = -1;
    if (!raw) return 0;
    uint64_t t = 0;
    switch (b->chain_fmt) {
        case 2: case 6:   // DYLD_CHAINED_PTR_64 / _OFFSET
            if (raw >> 63) { *bind_ord = (int64_t)(raw & 0xFFFFFF); return 0; }
            t = raw & 0xFFFFFFFFFull;
            if (b->chain_fmt == 6) t += b->image_base;
            break;
        case 1: case 9: case 12: case 13: {   // ARM64E
            int auth = (int)(raw >> 63), bind = (int)((raw >> 62) & 1);
            if (bind) { *bind_ord = (int64_t)(raw & (b->chain_fmt == 13 ? 0xFFFFFF : 0xFFFF)); return 0; }
            if (auth) t = (raw & 0xFFFFFFFFull) + b->image_base;
            else { t = raw & 0x7FFFFFFFFFFull; if (b->chain_fmt != 1) t += b->image_base; }
            break;
        }
        default:
            if (raw >= b->vmlo && raw < b->vmhi) return raw;
            if (b->fmt != 1) return 0;
            t = raw & 0xFFFFFFFFFull;
            if (!(t >= b->vmlo && t < b->vmhi)) t += b->image_base;
    }
    return t >= b->vmlo && t < b->vmhi ? t : 0;
}
static uint64_t decode_ptr(const gx_bin *b, uint64_t raw) { int64_t o; return decode_raw(b, raw, &o); }

static int cmp_cf(const void *a, const void *c) { const cfent *x = a, *y = c; return x->target < y->target ? -1 : x->target > y->target; }

static cfent *cf_list(const gx_bin *b, size_t *n) {
    cfent *a = NULL; size_t k = 0, cap = 0;
    for (int i = 0; i < b->ns; i++) {
        const gx_sect *s = &b->s[i];
        if (s->kind != GX_SK_CFSTRING) continue;
        for (uint64_t o = 0; o + 32 <= s->size; o += 32) {
            const uint8_t *e = b->d + s->off + o;
            uint64_t t = decode_ptr(b, L64(e + 16));
            if (!t) continue;
            if (k == cap) { cap = cap ? cap * 2 : 256; a = realloc(a, sizeof(cfent) * cap); }
            a[k++] = (cfent){t, s->off + (size_t)o + 24, s->addr + o};
        }
    }
    if (k) qsort(a, k, sizeof *a, cmp_cf);
    *n = k;
    return a;
}

int gx_bin_cfstring_lens(const gx_bin *b, uint64_t addr, size_t *lo, uint64_t *ea, int max) {
    size_t n; cfent *a = cf_list(b, &n);
    int k = 0;
    for (size_t i = 0; i < n && k < max; i++) if (a[i].target == addr) { lo[k] = a[i].lenoff; ea[k] = a[i].entry; k++; }
    free(a);
    return k;
}

int gx_bin_strings(const gx_bin *b, int minlen, gx_str **out, size_t *n) {
    strvec v = {0};
    for (int i = 0; i < b->ns; i++) {
        const gx_sect *s = &b->s[i];
        if (s->kind == GX_SK_ZERO || s->kind == GX_SK_SKIP || s->kind == GX_SK_CFSTRING || s->exec || !s->size) continue;
        size_t st = s->off, en = s->off + (size_t)s->size;
        if (en > b->len) en = b->len;
        if (s->kind == GX_SK_USTRING) { scan16(b->d, st, en, 1, i, &v); continue; }
        scan8(b->d, st, en, minlen, s->kind == GX_SK_CSTRING, i, b->fmt != 1, &v);
        if (b->fmt == 0) scan16(b->d, st, en, minlen < 4 ? 4 : minlen, i, &v);
    }
    if (b->fmt == 1 && v.n) {
        size_t nc; cfent *cf = cf_list(b, &nc);
        for (size_t i = 0; i < v.n && nc; i++) {
            uint64_t a;
            if (!gx_bin_o2a(b, v.a[i].off, &a)) continue;
            size_t lo = 0, hi = nc;
            while (lo < hi) { size_t m = (lo + hi) / 2; if (cf[m].target < a) lo = m + 1; else hi = m; }
            if (lo < nc && cf[lo].target == a) v.a[i].cf = 1;
        }
        free(cf);
    }
    // строки в сыром режиме из UTF-16 скана могли пересечься с UTF-8 — сортируем по смещению
    *out = v.a; *n = v.n;
    return 1;
}

#pragma mark - ссылки

typedef struct { gx_xref *a; size_t n, cap, max; } xvec;
static void xpush2(xvec *v, uint64_t from, int code, int kind, uint64_t adrp) {
    if (v->n >= v->max) return;
    if (v->n == v->cap) { v->cap = v->cap ? v->cap * 2 : 64; v->a = realloc(v->a, sizeof(gx_xref) * v->cap); }
    v->a[v->n++] = (gx_xref){from, (uint8_t)code, (uint8_t)kind, adrp};
}
static void xpush(xvec *v, uint64_t from, int code) { xpush2(v, from, code, code ? 3 : 0, 0); }

int gx_bin_xrefs(const gx_bin *b, uint64_t lo, uint64_t hi, gx_xref **out, size_t *n, size_t max) {
    xvec v = {0}; v.max = max;
    if (b->arm64) {
        for (int si = 0; si < b->ns; si++) {
            const gx_sect *s = &b->s[si];
            if (!s->exec || s->kind == GX_SK_ZERO || s->off + s->size > b->len) continue;
            uint64_t val[32], src[32]; int64_t age[32];
            for (int r = 0; r < 32; r++) { age[r] = -1000; src[r] = 0; }
            for (uint64_t o = 0; o + 4 <= s->size && v.n < max; o += 4) {
                uint32_t ins = L32(b->d + s->off + o);
                uint64_t pc = s->addr + o, t;
                int64_t ix = (int64_t)(o / 4);
                int rd, rn; uint64_t imm;
                if (gx_a64_is_adrp(ins, pc, &rd, &t)) {
                    val[rd] = t; age[rd] = ix; src[rd] = pc;
                    continue;
                }
                if (gx_a64_is_addimm(ins, &rd, &rn, &imm)) {
                    if (rn != 31 && ix - age[rn] < 48) {
                        uint64_t a = val[rn] + imm;
                        if (a >= lo && a < hi) xpush2(&v, pc, 1, src[rn] ? 1 : 3, src[rn]);
                        val[rd] = a; age[rd] = ix; src[rd] = 0;
                    } else if (rd != 31) age[rd] = -1000;
                    continue;
                }
                if (gx_a64_is_ldst_uimm(ins, &rd, &rn, &imm)) {
                    if (rn != 31 && ix - age[rn] < 48) { uint64_t a = val[rn] + imm; if (a >= lo && a < hi) xpush2(&v, pc, 1, src[rn] ? 2 : 3, src[rn]); }
                    if ((ins >> 22) & 3) age[rd] = -1000;   // загрузка портит регистр
                    continue;
                }
                char tmp[8];
                int k = gx_a64_dis(ins, pc, tmp, 0, &t);
                if (k == GX_A64_BRANCH || k == GX_A64_CALL || k == GX_A64_COND || k == GX_A64_ADR || k == GX_A64_LIT) {
                    if (t >= lo && t < hi) xpush(&v, pc, 1);
                    if (k == GX_A64_ADR) { val[ins & 31] = t; age[ins & 31] = ix; src[ins & 31] = 0; }
                    if (k == GX_A64_CALL || k == GX_A64_BRANCH) for (int r = 0; r < 19; r++) age[r] = -1000;
                    continue;
                }
                if (k == GX_A64_RET) { for (int r = 0; r < 32; r++) age[r] = -1000; continue; }
                age[ins & 31] = -1000;
            }
        }
    }
    // указатели в данных
    if (b->fmt == 1) {
        for (int si = 0; si < b->ns && v.n < max; si++) {
            const gx_sect *s = &b->s[si];
            if (s->exec || s->kind == GX_SK_ZERO || s->kind == GX_SK_CSTRING || s->kind == GX_SK_USTRING) continue;
            uint64_t start = (s->addr + 7) & ~7ull;
            for (uint64_t a = start; a + 8 <= s->addr + s->size && v.n < max; a += 8) {
                size_t o = s->off + (size_t)(a - s->addr);
                if (o + 8 > b->len) break;
                uint64_t t = decode_ptr(b, L64(b->d + o));
                if (t && t >= lo && t < hi) xpush(&v, a, 0);
            }
        }
    } else if (b->fmt == 2) {
        const uint8_t *h = b->d + b->base;
        uint64_t shoff = L64(h + 40); uint16_t shes = L16(h + 58), shn = L16(h + 60);
        if (shes >= 64 && shoff < b->slen && (uint64_t)shn * shes <= b->slen - shoff)
            for (int i = 0; i < shn; i++) {
                const uint8_t *s = h + shoff + (size_t)i * shes;
                if (L32(s + 4) != 4) continue;
                uint64_t off = L64(s + 24), size = L64(s + 32);
                if (off > b->slen || size > b->slen - off) continue;
                for (uint64_t k = 0; k + 24 <= size && v.n < max; k += 24) {
                    const uint8_t *e = h + off + k;
                    if ((uint32_t)L64(e + 8) != 1027) continue;
                    uint64_t t = L64(e + 16);
                    if (t >= lo && t < hi) xpush(&v, L64(e), 0);
                }
            }
        // плюс абсолютные указатели (на случай без релокаций)
    }
    *out = v.a; *n = v.n;
    return 1;
}

#pragma mark - числа

typedef struct { gx_numhit *a; size_t n, cap, max; } nvec;
static void npush(nvec *v, size_t off, int kind) {
    if (v->n >= v->max) return;
    if (v->n == v->cap) { v->cap = v->cap ? v->cap * 2 : 128; v->a = realloc(v->a, sizeof(gx_numhit) * v->cap); }
    v->a[v->n++] = (gx_numhit){off, (uint8_t)kind};
}
static int feq(double x, double v) { if (!isfinite(x)) return 0; if (v == 0) return x == 0; return fabs(x - v) <= fabs(v) * 1e-6; }

int gx_bin_find_num(const gx_bin *b, int type, double v, int in_code, gx_numhit **out, size_t *n, size_t max) {
    nvec r = {0}; r.max = max;
    int sz = type == GX_NT_I32 || type == GX_NT_F32 ? 4 : type == GX_NT_I16 ? 2 : type == GX_NT_I8 ? 1 : 8;
    int isf = type == GX_NT_F32 || type == GX_NT_F64;
    int64_t iv = (int64_t)v;
    for (int si = 0; si < b->ns && r.n < max; si++) {
        const gx_sect *s = &b->s[si];
        if (s->kind == GX_SK_ZERO || !s->size) continue;
        size_t st = s->off, en = s->off + (size_t)s->size;
        if (en > b->len) en = b->len;
        if (s->exec) {
            if (!in_code || !b->arm64) continue;
            for (size_t o = st; o + 4 <= en && r.n < max; o += 4) {
                uint32_t ins = L32(b->d + o);
                int kind, w; double cv;
                if (gx_a64_const(ins, &kind, &cv, &w)) {
                    if ((kind == 1 || kind == 4) && !isf && cv == (double)iv && v == floor(v)) npush(&r, o, kind);
                    else if (kind == 2 && isf && feq(cv, v)) npush(&r, o, 2);
                }
                if (isf && (ins & 0xFFE00000) == 0x52A00000) {   // mov wN, #imm, lsl #16
                    uint32_t bits = ((ins >> 5) & 0xFFFF) << 16; float f; memcpy(&f, &bits, 4);
                    if (feq(f, v)) npush(&r, o, 3);
                }
            }
            continue;
        }
        uint64_t a0 = s->addr;
        for (size_t o = st; o + sz <= en && r.n < max; o++) {
            if (b->fmt && ((a0 + (o - st)) % (sz > 4 ? 4 : sz))) continue;
            if (!b->fmt && (o % (sz > 4 ? 4 : sz))) continue;
            const uint8_t *p = b->d + o;
            int ok = 0;
            switch (type) {
                case GX_NT_I8: ok = (int64_t)(int8_t)p[0] == iv || (int64_t)p[0] == iv; break;
                case GX_NT_I16: ok = (int64_t)(int16_t)L16(p) == iv || (int64_t)L16(p) == iv; break;
                case GX_NT_I32: ok = (int64_t)(int32_t)L32(p) == iv || (int64_t)L32(p) == iv; break;
                case GX_NT_I64: ok = (int64_t)L64(p) == iv; break;
                case GX_NT_F32: { uint32_t x = L32(p); float f; memcpy(&f, &x, 4); ok = feq(f, v); break; }
                case GX_NT_F64: { uint64_t x = L64(p); double f; memcpy(&f, &x, 8); ok = feq(f, v); break; }
            }
            if (ok && !isf && v != floor(v)) ok = 0;
            if (ok) npush(&r, o, 0);
        }
    }
    *out = r.a; *n = r.n;
    return 1;
}

#pragma mark - ad-hoc подпись

typedef struct { uint32_t type; const uint8_t *p; uint32_t len; } blob;

static uint8_t *sign_thin(const uint8_t *in, size_t len, const char *ident, uint32_t flags, size_t *outlen, int *did, char *err, size_t errlen) {
    *did = 0;
    if (len < 32 || L32(in) != 0xFEEDFACF) { uint8_t *c = malloc(len ? len : 1); memcpy(c, in, len); *outlen = len; return c; }
    uint32_t ft = L32(in + 12), ncmds = L32(in + 16), szc = L32(in + 20);
    if (32 + (size_t)szc > len) { snprintf(err, errlen, GXT("битые команды загрузки")); return NULL; }
    size_t sigcmd = 0, linkcmd = 0, textcmd = 0;
    const uint8_t *p = in + 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        if ((size_t)(p - in) + 8 > 32 + (size_t)szc) break;
        uint32_t cmd = L32(p), cs = L32(p + 4);
        if (cs < 8 || (size_t)(p - in) + cs > 32 + (size_t)szc) break;
        if (cmd == 0x1D) sigcmd = (size_t)(p - in);
        if (cmd == 0x19 && !strncmp((const char *)p + 8, "__LINKEDIT", 16)) linkcmd = (size_t)(p - in);
        if (cmd == 0x19 && !strncmp((const char *)p + 8, "__TEXT", 16)) textcmd = (size_t)(p - in);
        p += cs;
    }
    if (!sigcmd) { uint8_t *c = malloc(len); memcpy(c, in, len); *outlen = len; return c; }
    uint32_t sigoff = L32(in + sigcmd + 8), sigsz = L32(in + sigcmd + 12);
    if (!sigoff && !sigsz) {
        // пустая заглушка (так делает встроенный компилятор): подпись дописывается в конец __LINKEDIT
        if (!linkcmd) { snprintf(err, errlen, GXT("нет __LINKEDIT для подписи")); return NULL; }
        uint64_t lfo = L64(in + linkcmd + 40), lfs = L64(in + linkcmd + 48);
        if (lfo + lfs > len) { snprintf(err, errlen, GXT("__LINKEDIT за пределами файла")); return NULL; }
        size_t len2 = (len + 15) & ~(size_t)15;
        uint8_t *in2 = calloc(1, len2);
        memcpy(in2, in, len);
        PL32(in2 + sigcmd + 8, (uint32_t)len2);
        PL64(in2 + linkcmd + 48, len2 - lfo);
        uint8_t *r = sign_thin(in2, len2, ident, flags, outlen, did, err, errlen);
        free(in2);
        return r;
    }
    if (sigoff > len || sigsz > len - sigoff) { snprintf(err, errlen, GXT("подпись за пределами файла")); return NULL; }
    // старые entitlements
    blob ents[2] = {{0}}; int ne = 0;
    if (sigsz >= 12 && B32(in + sigoff) == 0xFADE0CC0) {
        uint32_t cnt = B32(in + sigoff + 8);
        for (uint32_t i = 0; i < cnt && 12 + (size_t)(i + 1) * 8 <= sigsz; i++) {
            uint32_t ty = B32(in + sigoff + 12 + i * 8), bo = B32(in + sigoff + 16 + i * 8);
            if ((ty == 5 || ty == 7) && bo + 8 <= sigsz) {
                uint32_t bl = B32(in + sigoff + bo + 4);
                if (bl >= 8 && bo + bl <= sigsz && ne < 2) ents[ne++] = (blob){ty, in + sigoff + bo, bl};
            }
        }
    }
    int nspecial = 0;
    for (int i = 0; i < ne; i++) if ((int)ents[i].type > nspecial) nspecial = (int)ents[i].type;
    if (nspecial) nspecial = nspecial < 2 ? 2 : nspecial;
    uint8_t emptyreq[12]; PB32(emptyreq, 0xFADE0C01); PB32(emptyreq + 4, 12); PB32(emptyreq + 8, 0);
    size_t idl = strlen(ident) + 1;
    uint32_t codelimit = sigoff;
    uint32_t nslots = (codelimit + 4095) / 4096;
    size_t hashoff = ((88 + idl + 7) & ~(size_t)7) + (size_t)nspecial * 32;
    size_t cdlen = hashoff + (size_t)nslots * 32;
    int nblobs = 1 + (nspecial ? 1 : 0) + ne;
    size_t hdr = (12 + (size_t)nblobs * 8 + 7) & ~(size_t)7;
    size_t total = hdr + cdlen + (nspecial ? 12 : 0);
    for (int i = 0; i < ne; i++) total += ents[i].len;
    size_t need = (total + 15) & ~(size_t)15;
    size_t newsig = sigsz >= need ? sigsz : need;
    size_t newlen = (size_t)sigoff + newsig;
    if (newsig != sigsz) {
        if ((size_t)sigoff + sigsz != len || !linkcmd) { snprintf(err, errlen, GXT("мало места для подписи")); return NULL; }
    }
    uint8_t *o = calloc(1, newlen);
    memcpy(o, in, sigoff);
    if (newsig != sigsz) {
        size_t delta = newsig - sigsz;
        PL32(o + sigcmd + 12, (uint32_t)newsig);
        uint64_t fs = L64(o + linkcmd + 48) + delta, vs = L64(o + linkcmd + 32);
        PL64(o + linkcmd + 48, fs);
        if (fs > vs) PL64(o + linkcmd + 32, (fs + 0x3FFF) & ~0x3FFFull);
    }
    // суперблоб
    uint8_t *sb = o + sigoff;
    PB32(sb, 0xFADE0CC0); PB32(sb + 4, (uint32_t)total); PB32(sb + 8, (uint32_t)nblobs);
    size_t cur = hdr, idx = 12;
    PB32(sb + idx, 0); PB32(sb + idx + 4, (uint32_t)cur); idx += 8;
    uint8_t *cd = sb + cur;
    size_t cdpos = cur;
    cur += cdlen;
    size_t reqpos = 0, entpos[2] = {0};
    if (nspecial) { PB32(sb + idx, 2); PB32(sb + idx + 4, (uint32_t)cur); idx += 8; reqpos = cur; memcpy(sb + cur, emptyreq, 12); cur += 12; }
    for (int i = 0; i < ne; i++) { PB32(sb + idx, ents[i].type); PB32(sb + idx + 4, (uint32_t)cur); idx += 8; entpos[i] = cur; memcpy(sb + cur, ents[i].p, ents[i].len); cur += ents[i].len; }
    (void)cdpos;
    PB32(cd, 0xFADE0C02); PB32(cd + 4, (uint32_t)cdlen); PB32(cd + 8, 0x20400); PB32(cd + 12, flags);
    PB32(cd + 16, (uint32_t)hashoff); PB32(cd + 20, 88); PB32(cd + 24, (uint32_t)nspecial); PB32(cd + 28, nslots);
    PB32(cd + 32, codelimit); cd[36] = 32; cd[37] = 2; cd[38] = 0; cd[39] = 12;
    uint64_t tbase = textcmd ? L64(o + textcmd + 40) : 0, tlim = textcmd ? L64(o + textcmd + 48) : 0;
    PB64(cd + 64, tbase); PB64(cd + 72, tlim); PB64(cd + 80, ft == 2 ? 1 : 0);
    memcpy(cd + 88, ident, idl);
    uint8_t *hs = cd + hashoff;
    if (nspecial) gx_sha256_buf(sb + reqpos, 12, hs - 2 * 32);
    for (int i = 0; i < ne; i++) gx_sha256_buf(sb + entpos[i], ents[i].len, hs - (size_t)ents[i].type * 32);
    for (uint32_t i = 0; i < nslots; i++) {
        size_t a = (size_t)i * 4096, l = codelimit - a < 4096 ? codelimit - a : 4096;
        gx_sha256_buf(o + a, l, hs + (size_t)i * 32);
    }
    *outlen = newlen; *did = 1;
    return o;
}

uint8_t *gx_adhoc_sign(const uint8_t *d, size_t len, const char *ident, uint32_t flags, size_t *outlen, int *signed_slices, char *err, size_t errlen) {
    *signed_slices = 0;
    if (len >= 8 && B32(d) == 0xCAFEBABE) {
        uint32_t n = B32(d + 4);
        if (!n || n > 32 || 8 + (size_t)n * 20 > len) { snprintf(err, errlen, GXT("битый fat-заголовок")); return NULL; }
        uint8_t *parts[32] = {0}; size_t plen[32] = {0};
        size_t pos = 8 + (size_t)n * 20;
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *a = d + 8 + i * 20;
            size_t o = B32(a + 8), s = B32(a + 12);
            if (o > len || s > len - o) { snprintf(err, errlen, GXT("срез за пределами файла")); goto fail; }
            int did = 0;
            parts[i] = sign_thin(d + o, s, ident, flags, &plen[i], &did, err, errlen);
            if (!parts[i]) goto fail;
            *signed_slices += did;
        }
        size_t total = pos;
        size_t offs[32];
        for (uint32_t i = 0; i < n; i++) {
            uint32_t al = B32(d + 8 + i * 20 + 16);
            size_t A = al < 20 ? (size_t)1 << al : 0x4000;
            total = (total + A - 1) & ~(A - 1);
            offs[i] = total; total += plen[i];
        }
        uint8_t *o = calloc(1, total);
        memcpy(o, d, 8 + (size_t)n * 20);
        for (uint32_t i = 0; i < n; i++) {
            PB32(o + 8 + i * 20 + 8, (uint32_t)offs[i]); PB32(o + 8 + i * 20 + 12, (uint32_t)plen[i]);
            memcpy(o + offs[i], parts[i], plen[i]);
            free(parts[i]);
        }
        *outlen = total;
        return o;
    fail:
        for (uint32_t i = 0; i < n; i++) free(parts[i]);
        return NULL;
    }
    int did = 0;
    uint8_t *o = sign_thin(d, len, ident, flags, outlen, &did, err, errlen);
    *signed_slices = did;
    return o;
}

#pragma mark - указатели и описания адресов

int gx_bin_sect_named(const gx_bin *b, const char *sn) {
    for (int i = 0; i < b->ns; i++) {
        const char *c = strchr(b->s[i].name, ',');
        if (!strcmp(c ? c + 1 : b->s[i].name, sn)) return i;
    }
    return -1;
}

int gx_bin_ptr_at(const gx_bin *b, uint64_t addr, uint64_t *target, const char **name, uint32_t *nlen) {
    *target = 0; *name = NULL; *nlen = 0;
    int64_t off = gx_bin_a2o(b, addr);
    if (off < 0 || (size_t)off + 8 > b->len) return 0;
    if (b->nbind) {
        size_t lo = 0, hi = b->nbind;
        while (lo < hi) { size_t m = (lo + hi) / 2; if (b->bind[m].addr < addr) lo = m + 1; else hi = m; }
        if (lo < b->nbind && b->bind[lo].addr == addr) { *name = b->bind[lo].name; *nlen = b->bind[lo].nlen; return 2; }
    }
    int64_t ord;
    uint64_t t = decode_raw(b, L64(b->d + off), &ord);
    if (ord >= 0) { *name = chained_import(b, (uint32_t)ord, nlen); return *name ? 2 : 0; }
    if (t) { *target = t; return 1; }
    return 0;
}

// Строка C по адресу (UTF-8, печатная). Длина или 0
static size_t cstr_at(const gx_bin *b, uint64_t a, const char **s) {
    int64_t off = gx_bin_a2o(b, a);
    if (off < 0) return 0;
    const uint8_t *p = b->d + off;
    size_t lim = b->len - (size_t)off, l = 0;
    if (lim > 4096) lim = 4096;
    while (l < lim && p[l]) {
        uint32_t cp; int k = utf8_cp(p + l, lim - l, &cp);
        if (!k || !printable(cp)) return 0;
        l += k;
    }
    if (l == lim || !l) return 0;
    *s = (const char *)p;
    return l;
}

static void quote(char *out, size_t n, const char *pre, const char *s, size_t l, size_t maxl) {
    size_t o = 0;
    #define PUT(c) do { if (o + 1 < n) out[o++] = (c); } while (0)
    for (const char *q = pre; *q; q++) PUT(*q);
    PUT('"');
    for (size_t i = 0; i < l && o + 8 < n; i++) {
        if (i >= maxl && ((uint8_t)s[i] & 0xC0) != 0x80) { PUT('.'); PUT('.'); PUT('.'); break; }
        char c = s[i];
        if (c == '\n') { PUT('\\'); PUT('n'); }
        else if (c == '\t') { PUT('\\'); PUT('t'); }
        else if (c == '"') { PUT('\\'); PUT('"'); }
        else PUT(c);
    }
    PUT('"');
    #undef PUT
    out[o < n ? o : n - 1] = 0;
}

static size_t utf16_to_utf8(const uint8_t *p, size_t units, char *out, size_t n) {
    size_t o = 0;
    for (size_t i = 0; i < units; i++) {
        uint32_t c = L16(p + i * 2);
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < units) { uint32_t c2 = L16(p + (i + 1) * 2); if (c2 >= 0xDC00 && c2 <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00); i++; } }
        if (c < 0x80) { if (o + 1 >= n) break; out[o++] = (char)c; }
        else if (c < 0x800) { if (o + 2 >= n) break; out[o++] = (char)(0xC0 | c >> 6); out[o++] = (char)(0x80 | (c & 63)); }
        else if (c < 0x10000) { if (o + 3 >= n) break; out[o++] = (char)(0xE0 | c >> 12); out[o++] = (char)(0x80 | ((c >> 6) & 63)); out[o++] = (char)(0x80 | (c & 63)); }
        else { if (o + 4 >= n) break; out[o++] = (char)(0xF0 | c >> 18); out[o++] = (char)(0x80 | ((c >> 12) & 63)); out[o++] = (char)(0x80 | ((c >> 6) & 63)); out[o++] = (char)(0x80 | (c & 63)); }
    }
    out[o] = 0;
    return o;
}

static const char *strip_sym(const char *s, uint32_t *l) {
    if (*l > 14 && !strncmp(s, "_OBJC_CLASS_$_", 14)) { *l -= 14; return s + 14; }
    if (*l > 18 && !strncmp(s, "_OBJC_METACLASS_$_", 18)) { *l -= 18; return s + 18; }
    if (*l > 1 && s[0] == '_') { (*l)--; return s + 1; }
    return s;
}

// Имя класса ObjC по адресу class_t
int gx_bin_objc_class_name(const gx_bin *b, uint64_t cls, const char **name, uint32_t *nl) {
    uint64_t ro; const char *bn; uint32_t bl;
    if (gx_bin_ptr_at(b, cls + 32, &ro, &bn, &bl) != 1) {
        // data у Swift-классов может быть с флагами — пробуем по сырому значению
        int64_t off = gx_bin_a2o(b, cls + 32);
        if (off < 0 || (size_t)off + 8 > b->len) return 0;
        int64_t ord; ro = decode_raw(b, L64(b->d + off) & ~7ull, &ord);
        if (!ro) return 0;
    }
    ro &= ~7ull;
    uint64_t np;
    if (gx_bin_ptr_at(b, ro + 24, &np, &bn, &bl) != 1) return 0;
    const char *s; size_t l = cstr_at(b, np, &s);
    if (!l) return 0;
    *name = s; *nl = (uint32_t)l;
    return 1;
}

int gx_bin_describe(const gx_bin *b, uint64_t a, char *out, size_t n) {
    out[0] = 0;
    const gx_name *im = gx_bin_import_at(b, a);
    if (im) { uint32_t l = im->nlen; const char *s = strip_sym(im->name, &l); snprintf(out, n, "%.*s", (int)l, s); return 1; }
    int si = gx_bin_sect_of_addr(b, a);
    if (si < 0) return 0;
    const gx_sect *sc = &b->s[si];
    const char *c = strchr(sc->name, ',');
    const char *sn = c ? c + 1 : sc->name;
    uint64_t t; const char *nm; uint32_t nl;
    if (!strcmp(sn, "__objc_selrefs")) {
        if (gx_bin_ptr_at(b, a, &t, &nm, &nl) == 1) { const char *s; size_t l = cstr_at(b, t, &s); if (l) { snprintf(out, n, "@selector(%.*s)", (int)l, s); return 1; } }
        return 0;
    }
    if (!strcmp(sn, "__objc_classrefs") || !strcmp(sn, "__objc_superrefs")) {
        int k = gx_bin_ptr_at(b, a, &t, &nm, &nl);
        if (k == 2) { const char *s = strip_sym(nm, &nl); snprintf(out, n, "%.*s", (int)nl, s); return 1; }
        if (k == 1 && gx_bin_objc_class_name(b, t, &nm, &nl)) { snprintf(out, n, "%.*s", (int)nl, nm); return 1; }
        return 0;
    }
    if (sc->kind == GX_SK_CFSTRING) {
        uint64_t ent = sc->addr + ((a - sc->addr) / 32) * 32;
        int64_t off = gx_bin_a2o(b, ent);
        if (off < 0 || (size_t)off + 32 > b->len) return 0;
        uint64_t flags = L64(b->d + off + 8), len = L64(b->d + off + 24);
        if (gx_bin_ptr_at(b, ent + 16, &t, &nm, &nl) != 1) return 0;
        int64_t so = gx_bin_a2o(b, t);
        if (so < 0) return 0;
        char buf[512];
        if ((flags & 0xFF) == 0xD0 || (flags & 0xFFFF) == 0x07D0) {
            if (len > 120) len = 120;
            if ((size_t)so + len * 2 > b->len) return 0;
            size_t l = utf16_to_utf8(b->d + so, (size_t)len, buf, sizeof buf);
            quote(out, n, "@", buf, l, 80);
        } else {
            const char *s; size_t l = cstr_at(b, t, &s);
            if (!l) return 0;
            quote(out, n, "@", s, l, 80);
        }
        return 1;
    }
    if (sc->kind == GX_SK_USTRING) {
        int64_t so = gx_bin_a2o(b, a);
        if (so < 0) return 0;
        size_t u = 0; while ((size_t)so + u * 2 + 2 <= b->len && u < 120 && L16(b->d + so + u * 2)) u++;
        char buf[512]; size_t l = utf16_to_utf8(b->d + so, u, buf, sizeof buf);
        quote(out, n, "", buf, l, 80);
        return 1;
    }
    if (!sc->exec && sc->kind != GX_SK_ZERO && sc->kind != GX_SK_CFSTRING) {
        // слот указателя (GOT, данные) → внешний символ
        if (((a - sc->addr) & 7) == 0 && sc->kind != GX_SK_CSTRING) {
            int k = gx_bin_ptr_at(b, a, &t, &nm, &nl);
            if (k == 2) { const char *s = strip_sym(nm, &nl); snprintf(out, n, "&%.*s", (int)nl, s); return 1; }
        }
        const char *s; size_t l = cstr_at(b, a, &s);
        if (l && (sc->kind == GX_SK_CSTRING || l >= 3)) { quote(out, n, "", s, l, 80); return 1; }
    }
    const gx_name *f = gx_bin_func_of(b, a);
    if (f && f->addr == a && f->name) { uint32_t l = f->nlen; const char *s = strip_sym(f->name, &l); snprintf(out, n, "%.*s", (int)l, s); return 1; }
    return 0;
}

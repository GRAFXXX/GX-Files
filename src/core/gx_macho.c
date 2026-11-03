#include "gx_tr.h"
#include "gx_macho.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MH64 0xFEEDFACFu
#define MH32 0xFEEDFACEu
#define FAT 0xCAFEBABEu
#define FAT64 0xCAFEBABFu
#define LC_SEGMENT_64 0x19
#define LC_SEGMENT 0x1
#define LC_LOAD_DYLIB 0xC
#define LC_LOAD_WEAK_DYLIB 0x80000018u
#define LC_REEXPORT_DYLIB 0x8000001Fu
#define LC_LAZY_LOAD_DYLIB 0x20
#define LC_RPATH 0x8000001Cu

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t be64(const uint8_t *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }

typedef struct { size_t off, len; } slice;

static int slices(const uint8_t *d, size_t len, slice *out, int max) {
    if (len < 8) return 0;
    uint32_t m = be32(d);
    if (m == FAT || m == FAT64) {
        uint32_t n = be32(d + 4);
        int k = 0;
        for (uint32_t i = 0; i < n && k < max; i++) {
            size_t e = 8 + (size_t)i * (m == FAT ? 20 : 32);
            if (e + 20 > len) break;
            uint64_t o = m == FAT ? be32(d + e + 8) : be64(d + e + 8), l = m == FAT ? be32(d + e + 12) : be64(d + e + 16);
            if (o + l <= len) { out[k].off = (size_t)o; out[k].len = (size_t)l; k++; }
        }
        return k;
    }
    uint32_t le = rd32(d);
    if (le == MH64 || le == MH32) { out[0].off = 0; out[0].len = len; return 1; }
    return 0;
}

// заголовок среза: размер шапки, конец команд и начало первой секции (свободное место)
static int layout(const uint8_t *s, size_t len, size_t *hdr, size_t *cmds_end, size_t *first) {
    uint32_t m = rd32(s);
    if (m != MH64 && m != MH32) return 0;
    *hdr = m == MH64 ? 32 : 28;
    uint32_t ncmds = rd32(s + 16), sz = rd32(s + 20);
    *cmds_end = *hdr + sz;
    if (*cmds_end > len) return 0;
    size_t f = len;
    size_t p = *hdr;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (p + 8 > *cmds_end) return 0;
        uint32_t cmd = rd32(s + p), cs = rd32(s + p + 4);
        if (cs < 8 || p + cs > *cmds_end) return 0;
        if (cmd == LC_SEGMENT_64 || cmd == LC_SEGMENT) {
            int is64 = cmd == LC_SEGMENT_64;
            uint32_t ns = rd32(s + p + (is64 ? 64 : 48));
            size_t sh = p + (is64 ? 72 : 56);
            for (uint32_t j = 0; j < ns; j++) {
                size_t so = sh + (size_t)j * (is64 ? 80 : 68);
                if (so + (is64 ? 80 : 68) > *cmds_end) break;
                uint32_t off = rd32(s + so + (is64 ? 48 : 40));
                uint32_t flags = rd32(s + so + (is64 ? 64 : 56));
                if (off && (flags & 0xff) != 0x1 && off < f) f = off;   // не zerofill
            }
            uint64_t fo = is64 ? *(const uint64_t *)(s + p + 40) : rd32(s + p + 32);
            uint64_t fsz = is64 ? *(const uint64_t *)(s + p + 48) : rd32(s + p + 36);
            if (fsz && fo > *cmds_end && fo < f) f = (size_t)fo;
        }
        p += cs;
    }
    *first = f;
    return 1;
}

static const char *dylib_name(const uint8_t *s, size_t p, uint32_t cs) {
    uint32_t no = rd32(s + p + 8);
    if (no >= cs) return NULL;
    return (const char *)s + p + no;
}

char *gx_macho_list_dylibs(const uint8_t *d, size_t len) {
    slice sl[8];
    int n = slices(d, len, sl, 8);
    size_t cap = 4096, o = 0;
    char *out = malloc(cap);
    out[0] = 0;
    for (int k = 0; k < n; k++) {
        const uint8_t *s = d + sl[k].off;
        size_t hdr, end, first;
        if (!layout(s, sl[k].len, &hdr, &end, &first)) continue;
        if (rd32(s) != MH64 && k + 1 < n) continue;
        uint32_t ncmds = rd32(s + 16);
        size_t p = hdr;
        for (uint32_t i = 0; i < ncmds; i++) {
            uint32_t cmd = rd32(s + p), cs = rd32(s + p + 4);
            if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB || cmd == LC_LAZY_LOAD_DYLIB || cmd == LC_RPATH) {
                const char *nm = cmd == LC_RPATH ? (const char *)s + p + rd32(s + p + 8) : dylib_name(s, p, cs);
                if (nm) {
                    size_t l = strnlen(nm, cs);
                    const char *tag = cmd == LC_LOAD_WEAK_DYLIB ? " (weak)" : cmd == LC_RPATH ? " (rpath)" : cmd == LC_REEXPORT_DYLIB ? " (reexport)" : "";
                    if (o + l + 32 > cap) { cap = (o + l + 32) * 2; out = realloc(out, cap); }
                    memcpy(out + o, nm, l); o += l;
                    o += (size_t)sprintf(out + o, "%s\n", tag);
                }
            }
            p += cs;
        }
        break;
    }
    out[o] = 0;
    return out;
}

static int add_cmd(uint8_t *s, size_t len, const uint8_t *cmd, size_t cmdsize, char *err, size_t errlen) {
    size_t hdr, end, first;
    if (!layout(s, len, &hdr, &end, &first)) { snprintf(err, errlen, GXT("не Mach-O")); return 0; }
    if (end + cmdsize > first) { snprintf(err, errlen, GXT("в заголовке нет места для новой команды (нужно %zu байт, свободно %zu)"), cmdsize, first > end ? first - end : 0); return 0; }
    for (size_t i = end; i < end + cmdsize; i++) if (s[i]) { snprintf(err, errlen, GXT("место после команд занято")); return 0; }
    memcpy(s + end, cmd, cmdsize);
    wr32(s + 16, rd32(s + 16) + 1);
    wr32(s + 20, rd32(s + 20) + (uint32_t)cmdsize);
    return 1;
}

int gx_macho_add_dylib(uint8_t *d, size_t len, const char *path, int weak, char *err, size_t errlen) {
    slice sl[8];
    int n = slices(d, len, sl, 8);
    if (!n) { snprintf(err, errlen, GXT("это не исполняемый файл Mach-O")); return 0; }
    size_t nl = strlen(path) + 1, cs = (24 + nl + 7) & ~(size_t)7;
    uint8_t *c = calloc(1, cs);
    wr32(c, weak ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB);
    wr32(c + 4, (uint32_t)cs);
    wr32(c + 8, 24);
    wr32(c + 12, 2);
    wr32(c + 16, 0x10000);
    wr32(c + 20, 0x10000);
    memcpy(c + 24, path, nl);
    int ok = 1;
    for (int k = 0; k < n && ok; k++) {
        uint8_t *s = d + sl[k].off;
        // уже есть?
        size_t hdr, end, first;
        if (!layout(s, sl[k].len, &hdr, &end, &first)) { snprintf(err, errlen, GXT("срез %d повреждён"), k); ok = 0; break; }
        uint32_t ncmds = rd32(s + 16);
        size_t p = hdr;
        int exists = 0;
        for (uint32_t i = 0; i < ncmds; i++) {
            uint32_t cmd = rd32(s + p), csz = rd32(s + p + 4);
            if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB) { const char *nm = dylib_name(s, p, csz); if (nm && !strcmp(nm, path)) exists = 1; }
            p += csz;
        }
        if (!exists) ok = add_cmd(s, sl[k].len, c, cs, err, errlen);
    }
    free(c);
    return ok;
}

int gx_macho_add_rpath(uint8_t *d, size_t len, const char *rpath, char *err, size_t errlen) {
    slice sl[8];
    int n = slices(d, len, sl, 8);
    if (!n) { snprintf(err, errlen, GXT("не Mach-O")); return 0; }
    size_t nl = strlen(rpath) + 1, cs = (12 + nl + 7) & ~(size_t)7;
    uint8_t *c = calloc(1, cs);
    wr32(c, LC_RPATH); wr32(c + 4, (uint32_t)cs); wr32(c + 8, 12);
    memcpy(c + 12, rpath, nl);
    int ok = 1;
    for (int k = 0; k < n && ok; k++) {
        uint8_t *s = d + sl[k].off;
        size_t hdr, end, first;
        if (!layout(s, sl[k].len, &hdr, &end, &first)) { ok = 0; snprintf(err, errlen, GXT("срез повреждён")); break; }
        uint32_t ncmds = rd32(s + 16);
        size_t p = hdr;
        int exists = 0;
        for (uint32_t i = 0; i < ncmds; i++) {
            uint32_t cmd = rd32(s + p), csz = rd32(s + p + 4);
            if (cmd == LC_RPATH && !strcmp((const char *)s + p + rd32(s + p + 8), rpath)) exists = 1;
            p += csz;
        }
        if (!exists) ok = add_cmd(s, sl[k].len, c, cs, err, errlen);
    }
    free(c);
    return ok;
}

int gx_macho_remove_dylib(uint8_t *d, size_t len, const char *path) {
    slice sl[8];
    int n = slices(d, len, sl, 8), removed = 0;
    for (int k = 0; k < n; k++) {
        uint8_t *s = d + sl[k].off;
        size_t hdr, end, first;
        if (!layout(s, sl[k].len, &hdr, &end, &first)) continue;
        uint32_t ncmds = rd32(s + 16);
        size_t p = hdr;
        for (uint32_t i = 0; i < ncmds;) {
            uint32_t cmd = rd32(s + p), cs = rd32(s + p + 4);
            int hit = 0;
            if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_LAZY_LOAD_DYLIB) { const char *nm = dylib_name(s, p, cs); hit = nm && !strcmp(nm, path); }
            if (cmd == LC_RPATH) hit = !strcmp((const char *)s + p + rd32(s + p + 8), path);
            if (hit) {
                memmove(s + p, s + p + cs, end - p - cs);
                memset(s + end - cs, 0, cs);
                end -= cs;
                ncmds--;
                wr32(s + 16, ncmds);
                wr32(s + 20, rd32(s + 20) - cs);
                removed++;
                continue;
            }
            p += cs; i++;
        }
    }
    return removed;
}

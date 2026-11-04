// Статический аудит безопасности (SAST): поиск небезопасных вызовов, слабой криптографии
// и опасных настроек в бинарнике Mach-O/ELF (ARM64). Только чтение, ничего не меняет.
#include "gx_audit.h"
#include "gx_a64.h"
#include <stdlib.h>
#include <string.h>

static uint32_t L32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

// имя без ведущего '_'
static const char *bare(const char *n) { return (n[0] == '_' && n[1] != '_') ? n + 1 : n; }

// классификация имени вызываемой функции → категория (или -1)
static int classify(const char *nm, int *sev) {
    const char *n = bare(nm);
    static const char *unsafe2[] = {"strcpy", "stpcpy", "strcat", "sprintf", "vsprintf", "gets", "wcscpy", "wcscat", NULL};
    static const char *unsafe1[] = {"scanf", "sscanf", "fscanf", "vscanf", "vsscanf", "strncpy", "strncat", NULL};
    static const char *sys2[]    = {"system", "popen", "execl", "execle", "execlp", "execv", "execve", "execvp", "posix_spawn", NULL};
    static const char *hash1[]   = {"CC_MD5", "CC_MD4", "CC_MD2", "MD5", "MD5_Init", "MD5_Update", "MD5_Final",
                                    "CC_SHA1", "SHA1", "SHA1_Init", "SHA1_Update", "SHA1_Final", NULL};
    static const char *rnd0[]    = {"rand", "random", "srand", "srandom", "drand48", "lrand48", "rand_r", NULL};
    for (int i = 0; unsafe2[i]; i++) if (!strcmp(n, unsafe2[i])) { *sev = 2; return GX_SAST_UNSAFE_STR; }
    for (int i = 0; unsafe1[i]; i++) if (!strcmp(n, unsafe1[i])) { *sev = 1; return GX_SAST_UNSAFE_STR; }
    for (int i = 0; sys2[i];    i++) if (!strcmp(n, sys2[i]))    { *sev = 2; return GX_SAST_SYSTEM; }
    for (int i = 0; hash1[i];   i++) if (!strcmp(n, hash1[i]))   { *sev = 1; return GX_SAST_WEAKHASH; }
    for (int i = 0; rnd0[i];    i++) if (!strcmp(n, rnd0[i]))    { *sev = 0; return GX_SAST_RANDOM; }
    // слабые шифры по подстроке в имени
    if (strstr(n, "DES_") == n || !strcmp(n, "DES") || strstr(n, "RC4") || strstr(n, "arc4_") == n) { *sev = 1; return GX_SAST_WEAKCIPHER; }
    return -1;
}

// имя цели вызова BL по адресу
static const char *callee_name(const gx_bin *b, uint64_t t, char *buf, size_t n) {
    const gx_name *im = gx_bin_import_at(b, t);
    if (im && im->name) return im->name;
    if (gx_bin_describe(b, t, buf, n) && buf[0]) return buf;    // символ/стаб
    return NULL;
}

static void add(gx_sast **a, int *n, int *cap, gx_sast f) {
    if (*n == *cap) { *cap = *cap ? *cap * 2 : 64; *a = realloc(*a, sizeof(gx_sast) * *cap); }
    (*a)[(*n)++] = f;
}

// поиск опасных строк в данных (ASCII) — без адреса, разовый флаг
static int find_str(const gx_bin *b, const char *needle) {
    size_t nl = strlen(needle);
    if (b->len < nl) return 0;
    for (size_t i = 0; i + nl <= b->len; i++) if (b->d[i] == (uint8_t)needle[0] && !memcmp(b->d + i, needle, nl)) return 1;
    return 0;
}

int gx_audit(const gx_bin *b, gx_sast **out) {
    gx_sast *a = NULL; int n = 0, cap = 0;
    if (b->arm64) {
        char buf[256];
        for (int si = 0; si < b->ns; si++) {
            const gx_sect *s = &b->s[si];
            if (!s->exec || !s->size) continue;
            size_t off = s->off;
            for (uint64_t p = 0; p + 4 <= s->size; p += 4) {
                if (off + p + 4 > b->len) break;
                uint32_t w = L32(b->d + off + p);
                if ((w & 0xFC000000) != 0x94000000) continue;   // только BL (прямой вызов)
                uint64_t site = s->addr + p;
                int64_t d = (int64_t)((w & 0x3FFFFFF) ^ 0x2000000) - 0x2000000;   // знаковое imm26
                uint64_t t = site + (uint64_t)(d * 4);
                const char *nm = callee_name(b, t, buf, sizeof buf);
                if (!nm) continue;
                int sev, cat = classify(nm, &sev);
                if (cat < 0) continue;
                const gx_name *fn = gx_bin_func_of(b, site);
                gx_sast f = { site, fn ? fn->addr : 0, nm, cat, sev };
                add(&a, &n, &cap, f);
            }
        }
    }
    // опасные строки / настройки (пояснения даёт UI по категории)
    static const struct { const char *s; int cat; int sev; } strs[] = {
        {"NSAllowsArbitraryLoads",             GX_SAST_ATS, 2},
        {"NSExceptionAllowsInsecureHTTPLoads", GX_SAST_ATS, 1},
        {"kSSLProtocolAll",                    GX_SAST_ATS, 1},
        {"allowsAnyHTTPSCertificate",          GX_SAST_ATS, 2},
        {"kSecTrustOptionAllowExpired",        GX_SAST_ATS, 1},
        {NULL, 0, 0}
    };
    for (int i = 0; strs[i].s; i++) if (find_str(b, strs[i].s)) {
        gx_sast f = { 0, 0, strs[i].s, strs[i].cat, strs[i].sev };
        add(&a, &n, &cap, f);
    }
    *out = a;
    return n;
}

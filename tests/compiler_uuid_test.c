// Регрессионный тест: встроенный компилятор обязан класть LC_UUID в dylib,
// иначе dyld на iOS отказывается грузить файл ("missing LC_UUID load command").
// Компилируем крошечный исходник через libtcc, затем подписываем как в приложении.
#include "libtcc.h"
#include "core/gx_bin.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(c, ...) do { if (c) {} else { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// найти load command cmd; вернуть смещение тела (после cmd,cmdsize) или -1
static long find_lc(const unsigned char *d, size_t n, unsigned want, unsigned *size_out) {
    if (n < 32) return -1;
    unsigned ncmds; memcpy(&ncmds, d + 16, 4);
    size_t off = 32;
    for (unsigned i = 0; i < ncmds && off + 8 <= n; i++) {
        unsigned cmd, sz; memcpy(&cmd, d + off, 4); memcpy(&sz, d + off + 4, 4);
        if (sz < 8 || off + sz > n) break;
        if (cmd == want) { if (size_out) *size_out = sz; return (long)(off + 8); }
        off += sz;
    }
    return -1;
}

static void errf(void *o, const char *m) { (void)o; (void)m; }

int main(int argc, char **argv) {
    const char *res = argc > 1 ? argv[1] : "tcc/res";
    char src[512], out[512];
    snprintf(src, sizeof src, "%s/gx_uuid_src.c", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    snprintf(out, sizeof out, "%s/gx_uuid_out.dylib", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    FILE *f = fopen(src, "w");
    fputs("int gx_test_add(int a, int b) { return a + b; }\n", f);
    fclose(f);

    TCCState *s = tcc_new();
    tcc_set_error_func(s, 0, errf);
    tcc_set_lib_path(s, res);
    tcc_set_options(s, "-nostdinc -nostdlib -install_name @rpath/test.dylib");
    tcc_set_output_type(s, TCC_OUTPUT_DLL);
    char p[600];
    snprintf(p, sizeof p, "%s/include", res); tcc_add_sysinclude_path(s, p);
    snprintf(p, sizeof p, "%s/sdk/include", res); tcc_add_sysinclude_path(s, p);
    CHECK(tcc_add_file(s, src) >= 0, "compile the source");
    snprintf(p, sizeof p, "%s/sdk/lib/libSystem.tbd", res);
    CHECK(tcc_add_file(s, p) >= 0, "link libSystem");
    CHECK(tcc_output_file(s, out) >= 0, "write dylib");
    tcc_delete(s);

    FILE *r = fopen(out, "rb");
    CHECK(r != NULL, "open the produced dylib");
    if (!r) { printf("compiler uuid test: %d failed\n", fails); return 1; }
    fseek(r, 0, SEEK_END); long n = ftell(r); rewind(r);
    unsigned char *d = malloc(n); if (fread(d, 1, n, r) != (size_t)n) return 1; fclose(r);

    // тип файла должен быть MH_DYLIB (6) — dlopen грузит только dylib, не исполняемый файл
    unsigned filetype; memcpy(&filetype, d + 12, 4);
    CHECK(filetype == 6, "filetype is MH_DYLIB (got %u)", filetype);
    // символ заголовка не должен называться _mh_execute_header (иначе анализаторы решат, что это exe)
    int has_exe_sym = 0;
    for (long i = 0; i + 18 <= n; i++) if (!memcmp(d + i, "_mh_execute_header", 18)) { has_exe_sym = 1; break; }
    CHECK(!has_exe_sym, "no _mh_execute_header symbol in a dylib (should be __mh_dylib_header)");

    unsigned usz = 0; long uo = find_lc(d, n, 0x1b /* LC_UUID */, &usz);
    CHECK(uo >= 0, "LC_UUID present in the compiled dylib");
    CHECK(usz == 24, "LC_UUID size is 24");
    int nonzero = 0; if (uo >= 0) for (int i = 0; i < 16; i++) if (d[uo + i]) nonzero = 1;
    CHECK(nonzero, "LC_UUID is not all-zero");

    // подпись как в приложении — UUID должен сохраниться, Mach-O остаться валидным
    char err[256] = {0}; size_t ol = 0; int ns = 0;
    unsigned char *o = gx_adhoc_sign(d, n, "test", 2, &ol, &ns, err, sizeof err);
    CHECK(o != NULL, "ad-hoc sign succeeds: %s", err);
    if (o) {
        long uo2 = find_lc(o, ol, 0x1b, NULL);
        CHECK(uo2 >= 0, "LC_UUID still present after signing");
        int nz2 = 0; if (uo2 >= 0) for (int i = 0; i < 16; i++) if (o[uo2 + i]) nz2 = 1;
        CHECK(nz2, "LC_UUID still non-zero after signing");
        gx_bin b; int ok = gx_bin_open(&b, o, ol, 0);
        CHECK(ok && b.fmt == 1 && b.arm64, "signed output is a valid arm64 Mach-O");
        gx_bin_close(&b);
        free(o);
    }
    free(d);
    printf("compiler uuid test: %s (%d failed)\n", fails ? "FAILED" : "all passed", fails);
    return fails ? 1 : 0;
}

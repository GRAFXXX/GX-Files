// Тест своего разбора PKCS#12: распарсить .p12 и сверить извлечённые ключ/серт с эталоном.
// Бэкенд крипто подставляется при линковке (OpenSSL на хосте, CommonCrypto в CI).
#include "core/gx_p12.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(c, ...) do { if (c) {} else { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint8_t *rd(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); rewind(f);
    uint8_t *d = malloc(l); if (fread(d, 1, l, f) != (size_t)l) { fclose(f); return NULL; }
    fclose(f); *n = l; return d;
}

int main(int ac, char **av) {
    // av: p12 password keyPkcs1.der cert.der  [label]
    if (ac < 5) { printf("usage\n"); return 2; }
    const char *label = ac > 5 ? av[5] : av[1];
    size_t pn, kn, cn;
    uint8_t *p12 = rd(av[1], &pn), *key = rd(av[3], &kn), *cert = rd(av[4], &cn);
    CHECK(p12 && key && cert, "[%s] read inputs", label);
    if (!p12 || !key || !cert) { printf("p12 parse [%s]: FAILED\n", label); return 1; }

    gx_p12 out; int reason = 0; char err[256] = {0};
    int ok = gx_p12_parse(p12, pn, av[2], &out, &reason, err, sizeof err);
    CHECK(ok, "[%s] parse ok (reason=%d err=%s)", label, reason, err);
    if (ok) {
        CHECK(out.key_len == kn && !memcmp(out.key_pkcs1, key, kn), "[%s] extracted key matches original (%zu vs %zu)", label, out.key_len, kn);
        CHECK(out.ncerts >= 1, "[%s] has >=1 cert", label);
        CHECK(out.ncerts >= 1 && out.cert_lens[0] == cn && !memcmp(out.certs[0], cert, cn), "[%s] leaf cert matches original", label);
        CHECK(out.key_bits == 2048, "[%s] key_bits=2048 (got %d)", label, out.key_bits);
        gx_p12_free(&out);
    }

    // неверный пароль → BADPW (не падение)
    gx_p12 o2; int r2 = 0; char e2[256] = {0};
    int ok2 = gx_p12_parse(p12, pn, "definitely-wrong-xyz", &o2, &r2, e2, sizeof e2);
    CHECK(!ok2 && r2 == GXP12_BADPW, "[%s] wrong password → BADPW (ok=%d reason=%d)", label, ok2, r2);
    if (ok2) gx_p12_free(&o2);

    free(p12); free(key); free(cert);
    printf("p12 parse [%s]: %s (%d failed)\n", label, fails ? "FAILED" : "ok", fails);
    return fails ? 1 : 0;
}

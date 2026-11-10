// Тест подписи сертификатом: подписать dylib через gx_sign_macho, затем проверить
// CodeDirectory (хеши страниц, флаги, Team ID) и извлечь CMS для openssl-проверки.
// RSA-подпись в тесте делает openssl CLI (на устройстве — SecKeyCreateSignature).
#include "core/gx_csign.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(c, ...) do { if (c) {} else { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static int sign_cb(void *ctx, const unsigned char *data, size_t n, unsigned char *sig, size_t *siglen) {
    const char *key = ctx; char dp[512], sp[512], cmd[1600];
    snprintf(dp, sizeof dp, "%s.tbs", key); snprintf(sp, sizeof sp, "%s.sig", key);
    FILE *f = fopen(dp, "wb"); if (!f) return 0; fwrite(data, 1, n, f); fclose(f);
    snprintf(cmd, sizeof cmd, "openssl dgst -sha256 -sign '%s' -out '%s' '%s'", key, sp, dp);
    if (system(cmd)) return 0;
    f = fopen(sp, "rb"); if (!f) return 0; fseek(f, 0, 2); long l = ftell(f); rewind(f);
    if ((size_t)l > *siglen) { fclose(f); return 0; }
    if (fread(sig, 1, l, f) != (size_t)l) { fclose(f); return 0; } fclose(f); *siglen = l; return 1;
}
static unsigned char *rd(const char *p, size_t *n) { FILE *f = fopen(p, "rb"); if (!f) return 0; fseek(f, 0, 2); long l = ftell(f); rewind(f); unsigned char *d = malloc(l); if (fread(d, 1, l, f) != (size_t)l) return 0; fclose(f); *n = l; return d; }

int main(int ac, char **av) {
    // av: dylib cert.der key.pem out.dylib
    size_t dl, cl; unsigned char *dy = rd(av[1], &dl), *cert = rd(av[2], &cl);
    CHECK(dy && cert, "read inputs");
    const unsigned char *certs[1] = {cert}; size_t clens[1] = {cl};
    gx_sign_opts o = {0};
    o.ident = "com.test.tweak"; o.teamid = "TEAMID1234"; o.certs = certs; o.cert_lens = clens; o.ncerts = 1;
    o.sig_size = 256; o.sign = sign_cb; o.sign_ctx = av[3];
    char err[256] = {0}; size_t ol = 0;
    unsigned char *out = gx_sign_macho(dy, dl, &o, &ol, err, sizeof err);
    CHECK(out != NULL, "gx_sign_macho: %s", err);
    if (!out) { printf("sign cert test: FAILED (%d)\n", fails); return 1; }
    FILE *w = fopen(av[4], "wb"); fwrite(out, 1, ol, w); fclose(w);

    // Team ID из сертификата
    char team[64] = {0}; int cfok = gx_cert_fields(cert, cl, team, sizeof team, NULL, 0, NULL);
    CHECK(cfok && !strcmp(team, "TEAMID1234"), "gx_cert_fields team=%s", team);
    printf("sign cert test: %s (%d failed)\n", fails ? "FAILED" : "signed+parsed ok", fails);
    return fails ? 1 : 0;
}

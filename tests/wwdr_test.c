// Тест подбора промежуточного Apple WWDR и разбора Name.
// Для каждого переданного сертификата: извлечь его subject, скормить как issuer в
// gx_wwdr_for_issuer — должен вернуться встроенный сертификат с тем же subject.
#include "core/gx_wwdr.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned char *rd(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long l = ftell(f); rewind(f);
    unsigned char *d = malloc(l); if (fread(d, 1, l, f) != (size_t)l) { fclose(f); return NULL; }
    fclose(f); *n = l; return d;
}

int main(int ac, char **av) {
    int fails = 0;
    for (int i = 1; i < ac; i++) {
        size_t n; unsigned char *c = rd(av[i], &n);
        if (!c) { printf("FAIL: read %s\n", av[i]); fails++; continue; }
        const unsigned char *sub; size_t sl;
        if (!gx_cert_name(c, n, 1, &sub, &sl)) { printf("FAIL: subject parse %s\n", av[i]); fails++; free(c); continue; }
        size_t wl; const unsigned char *w = gx_wwdr_for_issuer(sub, sl, &wl);
        if (!w) { printf("FAIL: no WWDR match for %s\n", av[i]); fails++; free(c); continue; }
        // у найденного subject обязан совпадать
        const unsigned char *ws; size_t wsl;
        if (!gx_cert_name(w, wl, 1, &ws, &wsl) || wsl != sl || memcmp(ws, sub, sl)) { printf("FAIL: subject mismatch %s\n", av[i]); fails++; }
        free(c);
    }
    printf("wwdr match test: %s (%d failed, %d certs)\n", fails ? "FAILED" : "ok", fails, ac - 1);
    return fails ? 1 : 0;
}

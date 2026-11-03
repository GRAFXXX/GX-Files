#include "gx_tr.h"
#include "gx_apksign.h"
#include "gx_zip.h"
#include "gx_zipw.h"
#include "gx_sha256.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>

#pragma mark - буфер

typedef struct { uint8_t *p; size_t n, cap; } buf;
static void bput(buf *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { size_t c = b->cap ? b->cap * 2 : 256; while (c < b->n + n) c *= 2; b->p = realloc(b->p, c); b->cap = c; }
    if (n) memcpy(b->p + b->n, d, n);
    b->n += n;
}
static void bstr(buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bu32(buf *b, uint32_t v) { uint8_t x[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)}; bput(b, x, 4); }
static void bu64(buf *b, uint64_t v) { bu32(b, (uint32_t)v); bu32(b, (uint32_t)(v >> 32)); }
static void blp(buf *b, const buf *in) { bu32(b, (uint32_t)in->n); bput(b, in->p, in->n); }   // length-prefixed

#pragma mark - DER

static void der(buf *b, uint8_t tag, const void *d, size_t n) {
    uint8_t h[6]; size_t hl = 0;
    h[hl++] = tag;
    if (n < 128) h[hl++] = (uint8_t)n;
    else if (n < 256) { h[hl++] = 0x81; h[hl++] = (uint8_t)n; }
    else if (n < 65536) { h[hl++] = 0x82; h[hl++] = (uint8_t)(n >> 8); h[hl++] = (uint8_t)n; }
    else { h[hl++] = 0x83; h[hl++] = (uint8_t)(n >> 16); h[hl++] = (uint8_t)(n >> 8); h[hl++] = (uint8_t)n; }
    bput(b, h, hl); bput(b, d, n);
}
static void derb(buf *b, uint8_t tag, buf *in) { der(b, tag, in->p, in->n); free(in->p); memset(in, 0, sizeof *in); }
static const uint8_t OID_RSA[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01};
static const uint8_t OID_SHA256RSA[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b};
static const uint8_t OID_SHA256[] = {0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01};
static const uint8_t OID_DATA[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01};
static const uint8_t OID_SIGNED[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02};
static const uint8_t OID_CN[] = {0x55, 0x04, 0x03};

static void alg_id(buf *b, const uint8_t *oid, size_t n) {
    buf s = {0}; der(&s, 0x06, oid, n); der(&s, 0x05, NULL, 0); derb(b, 0x30, &s);
}

// Разбор DER-сертификата: issuer и serial (для PKCS#7 IssuerAndSerialNumber), SPKI (для v2)
static int der_hdr(const uint8_t *p, size_t len, size_t *hl, size_t *cl) {
    if (len < 2) return 0;
    size_t l = p[1], h = 2;
    if (l & 0x80) { int k = l & 0x7f; if (k > 3 || len < 2u + k) return 0; l = 0; for (int i = 0; i < k; i++) l = l << 8 | p[2 + i]; h += k; }
    if (h + l > len) return 0;
    *hl = h; *cl = l; return 1;
}
// i-й элемент последовательности (с заголовком)
static int der_child(const uint8_t *seq, size_t len, int idx, const uint8_t **out, size_t *outlen) {
    size_t hl, cl;
    if (!der_hdr(seq, len, &hl, &cl)) return 0;
    const uint8_t *p = seq + hl, *e = seq + hl + cl;
    for (int i = 0; p < e; i++) {
        size_t h2, c2;
        if (!der_hdr(p, (size_t)(e - p), &h2, &c2)) return 0;
        if (i == idx) { *out = p; *outlen = h2 + c2; return 1; }
        p += h2 + c2;
    }
    return 0;
}
static int cert_parts(const uint8_t *cert, size_t n, const uint8_t **issuer, size_t *il, const uint8_t **serial, size_t *sl, const uint8_t **spki, size_t *pl) {
    const uint8_t *tbs; size_t tl;
    if (!der_child(cert, n, 0, &tbs, &tl)) return 0;
    const uint8_t *x; size_t xl;
    if (!der_child(tbs, tl, 0, &x, &xl)) return 0;
    int off = x[0] == 0xA0 ? 1 : 0;
    if (!der_child(tbs, tl, off + 0, serial, sl)) return 0;
    if (!der_child(tbs, tl, off + 2, issuer, il)) return 0;
    if (!der_child(tbs, tl, off + 5, spki, pl)) return 0;
    return 1;
}

uint8_t *gx_make_cert(const uint8_t *pub, size_t publen, const char *cn, gx_rsa_sign_fn sign, void *ctx, size_t *out_len) {
    buf name = {0}, rdn = {0}, atv = {0}, tbs = {0}, t = {0};
    der(&atv, 0x06, OID_CN, sizeof OID_CN); der(&atv, 0x0C, cn, strlen(cn));
    derb(&rdn, 0x30, &atv);
    buf set = {0}; derb(&set, 0x31, &rdn);
    derb(&name, 0x30, &set);
    // version v3
    buf v = {0}; uint8_t two = 2; der(&v, 0x02, &two, 1); derb(&t, 0xA0, &v);
    uint8_t serial[9]; serial[0] = 0x01;
    uint64_t r = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32);
    for (int i = 1; i < 9; i++) serial[i] = (uint8_t)(r >> (8 * (i - 1)));
    der(&t, 0x02, serial, 9);
    alg_id(&t, OID_SHA256RSA, sizeof OID_SHA256RSA);
    bput(&t, name.p, name.n);
    buf val = {0};
    der(&val, 0x17, "260101000000Z", 13);
    der(&val, 0x18, "20560101000000Z", 15);
    derb(&t, 0x30, &val);
    bput(&t, name.p, name.n);
    // SubjectPublicKeyInfo
    buf spki = {0}, bits = {0};
    alg_id(&spki, OID_RSA, sizeof OID_RSA);
    uint8_t z = 0; bput(&bits, &z, 1); bput(&bits, pub, publen);
    derb(&spki, 0x03, &bits);
    derb(&t, 0x30, &spki);
    derb(&tbs, 0x30, &t);
    uint8_t sig[1024]; size_t sl = sizeof sig;
    if (!sign(ctx, tbs.p, tbs.n, sig, &sl)) { free(tbs.p); free(name.p); return NULL; }
    buf c = {0}, sb = {0};
    bput(&c, tbs.p, tbs.n);
    alg_id(&c, OID_SHA256RSA, sizeof OID_SHA256RSA);
    bput(&sb, &z, 1); bput(&sb, sig, sl);
    derb(&c, 0x03, &sb);
    buf out = {0}; derb(&out, 0x30, &c);
    free(tbs.p); free(name.p);
    *out_len = out.n;
    return out.p;
}

// PKCS#7 SignedData (detached, без подписанных атрибутов) для v1
static int pkcs7(const gx_signer *s, const uint8_t *content, size_t n, buf *out) {
    const uint8_t *iss, *ser, *spki; size_t il, sl, pl;
    if (!cert_parts(s->cert, s->cert_len, &iss, &il, &ser, &sl, &spki, &pl)) return 0;
    uint8_t sig[1024]; size_t siglen = sizeof sig;
    if (!s->sign(s->ctx, content, n, sig, &siglen)) return 0;
    buf sd = {0}, tmp = {0}, si = {0}, sis = {0};
    uint8_t one = 1;
    der(&sd, 0x02, &one, 1);
    buf algs = {0}; alg_id(&algs, OID_SHA256, sizeof OID_SHA256); derb(&sd, 0x31, &algs);
    der(&tmp, 0x06, OID_DATA, sizeof OID_DATA); derb(&sd, 0x30, &tmp);
    der(&sd, 0xA0, s->cert, s->cert_len);
    der(&si, 0x02, &one, 1);
    buf ias = {0}; bput(&ias, iss, il); bput(&ias, ser, sl); derb(&si, 0x30, &ias);
    alg_id(&si, OID_SHA256, sizeof OID_SHA256);
    alg_id(&si, OID_RSA, sizeof OID_RSA);
    der(&si, 0x04, sig, siglen);
    derb(&sis, 0x30, &si);
    derb(&sd, 0x31, &sis);
    buf sdseq = {0}; derb(&sdseq, 0x30, &sd);
    buf ci = {0}, exp = {0};
    der(&ci, 0x06, OID_SIGNED, sizeof OID_SIGNED);
    bput(&exp, sdseq.p, sdseq.n); free(sdseq.p);
    derb(&ci, 0xA0, &exp);
    derb(out, 0x30, &ci);
    return 1;
}

#pragma mark - v1

static int is_sig_file(const char *n) {
    if (strncasecmp(n, "META-INF/", 9)) return 0;
    const char *b = n + 9;
    if (strchr(b, '/')) return 0;
    if (!strcasecmp(b, "MANIFEST.MF")) return 1;
    size_t l = strlen(b);
    return l > 3 && (!strcasecmp(b + l - 3, ".SF") || !strcasecmp(b + l - 4, ".RSA") || !strcasecmp(b + l - 4, ".DSA") || !strcasecmp(b + l - 3, ".EC"));
}

// строка манифеста с переносом по 72 байта
static void mf_line(buf *b, const char *s) {
    size_t n = strlen(s), first = 1;
    while (n) {
        size_t take = first ? (n < 70 ? n : 70) : (n < 69 ? n : 69);
        if (!first) bstr(b, " ");
        bput(b, s, take);
        bstr(b, "\r\n");
        s += take; n -= take; first = 0;
    }
}

static int sha_sink(void *ctx, const uint8_t *p, size_t n) { gx_sha256_update(ctx, p, n); return 1; }

#pragma mark - v2

static void chunk_digest(const uint8_t *p, size_t n, buf *digests) {
    for (size_t o = 0; o < n || (n == 0 && o == 0); o += 1u << 20) {
        if (n == 0) break;
        size_t c = n - o < (1u << 20) ? n - o : (1u << 20);
        gx_sha256 h; gx_sha256_init(&h);
        uint8_t pre[5] = {0xa5, (uint8_t)c, (uint8_t)(c >> 8), (uint8_t)(c >> 16), (uint8_t)(c >> 24)};
        gx_sha256_update(&h, pre, 5); gx_sha256_update(&h, p + o, c);
        uint8_t d[32]; gx_sha256_final(&h, d);
        bput(digests, d, 32);
    }
}

static int read_all(int fd, uint64_t off, uint64_t n, uint8_t *dst) {
    while (n) { ssize_t k = pread(fd, dst, n > (1u << 30) ? (1u << 30) : (size_t)n, (off_t)off); if (k <= 0) return 0; dst += k; off += (uint64_t)k; n -= (uint64_t)k; }
    return 1;
}

static int add_v2(const char *path, const gx_signer *s, char *err, size_t errlen) {
    gxz z;
    if (!gxz_open(&z, path, 0, 0)) { snprintf(err, errlen, "%s", z.err); return 0; }
    uint64_t cd_off, cd_size, eocd; int z64;
    int ok = gxz_layout(&z, &cd_off, &cd_size, &eocd, &z64);
    uint64_t fsize = z.size;
    gxz_close(&z);
    if (!ok || z64) { snprintf(err, errlen, z64 ? GXT("ZIP64 APK не поддерживается для подписи v2") : GXT("плохой zip")); return 0; }
    int fd = open(path, O_RDWR);
    if (fd < 0) { snprintf(err, errlen, GXT("не открыть")); return 0; }
    // дайджест секций чанками по 1 МиБ, читаем кусками
    buf dig = {0};
    uint8_t *tmp = malloc(1u << 20);
    uint64_t sec[3][2] = {{0, cd_off}, {cd_off, cd_size}, {eocd, fsize - eocd}};
    uint32_t nchunks = 0;
    for (int k = 0; k < 3 && ok; k++) {
        uint64_t o = sec[k][0], left = sec[k][1];
        while (left) {
            size_t c = left < (1u << 20) ? (size_t)left : (1u << 20);
            if (!read_all(fd, o, c, tmp)) { ok = 0; break; }
            if (k == 2 && o == eocd) { tmp[16] = (uint8_t)cd_off; tmp[17] = (uint8_t)(cd_off >> 8); tmp[18] = (uint8_t)(cd_off >> 16); tmp[19] = (uint8_t)(cd_off >> 24); }
            chunk_digest(tmp, c, &dig);
            nchunks++;
            o += c; left -= c;
        }
    }
    if (!ok) { snprintf(err, errlen, GXT("ошибка чтения")); free(tmp); free(dig.p); close(fd); return 0; }
    gx_sha256 h; gx_sha256_init(&h);
    uint8_t pre[5] = {0x5a, (uint8_t)nchunks, (uint8_t)(nchunks >> 8), (uint8_t)(nchunks >> 16), (uint8_t)(nchunks >> 24)};
    gx_sha256_update(&h, pre, 5); gx_sha256_update(&h, dig.p, dig.n);
    uint8_t top[32]; gx_sha256_final(&h, top);
    free(dig.p);
    // signed data
    const uint32_t ALG = 0x0103;
    buf digests = {0}, one = {0}, dv = {0};
    bu32(&one, ALG); dv.p = top; dv.n = 32; blp(&one, &dv);
    blp(&digests, &one); free(one.p);
    buf certs = {0}, cv = {0}; cv.p = (uint8_t *)s->cert; cv.n = s->cert_len; blp(&certs, &cv);
    buf sdata = {0}, empty = {0};
    blp(&sdata, &digests); blp(&sdata, &certs); blp(&sdata, &empty);
    free(digests.p); free(certs.p);
    uint8_t sig[1024]; size_t sl = sizeof sig;
    if (!s->sign(s->ctx, sdata.p, sdata.n, sig, &sl)) { snprintf(err, errlen, GXT("ошибка RSA-подписи")); free(sdata.p); free(tmp); close(fd); return 0; }
    buf sigs = {0}, s1 = {0}, sv = {0};
    bu32(&s1, ALG); sv.p = sig; sv.n = sl; blp(&s1, &sv);
    blp(&sigs, &s1); free(s1.p);
    const uint8_t *iss, *ser, *spki; size_t il, sl2, pl;
    if (!cert_parts(s->cert, s->cert_len, &iss, &il, &ser, &sl2, &spki, &pl)) { snprintf(err, errlen, GXT("плохой сертификат")); free(sdata.p); free(sigs.p); free(tmp); close(fd); return 0; }
    buf signer = {0}, pk = {0}; pk.p = (uint8_t *)spki; pk.n = pl;
    blp(&signer, &sdata); blp(&signer, &sigs); blp(&signer, &pk);
    free(sdata.p); free(sigs.p);
    buf signers = {0}; blp(&signers, &signer); free(signer.p);
    buf value = {0}; blp(&value, &signers); free(signers.p);
    // блок: size, пары (u64 len, u32 id, value), size, magic
    buf pairs = {0};
    bu64(&pairs, value.n + 4); bu32(&pairs, 0x7109871a); bput(&pairs, value.p, value.n);
    free(value.p);
    uint64_t bsize = pairs.n + 8 + 16;
    buf block = {0};
    bu64(&block, bsize); bput(&block, pairs.p, pairs.n); bu64(&block, bsize); bstr(&block, "APK Sig Block 42");
    free(pairs.p);
    // вставка перед центральным каталогом
    uint64_t tail = fsize - cd_off;
    uint8_t *t = malloc(tail);
    ok = read_all(fd, cd_off, tail, t);
    uint64_t new_cd = cd_off + block.n;
    uint64_t e = eocd - cd_off;
    t[e + 16] = (uint8_t)new_cd; t[e + 17] = (uint8_t)(new_cd >> 8); t[e + 18] = (uint8_t)(new_cd >> 16); t[e + 19] = (uint8_t)(new_cd >> 24);
    if (ok) ok = pwrite(fd, block.p, block.n, (off_t)cd_off) == (ssize_t)block.n && pwrite(fd, t, tail, (off_t)new_cd) == (ssize_t)tail;
    free(t); free(block.p); free(tmp);
    close(fd);
    if (!ok) snprintf(err, errlen, GXT("ошибка записи"));
    return ok;
}

int gx_apk_sign(const char *in_path, const char *out_path, const gx_signer *s, char *err, size_t errlen,
                volatile int *cancel, void (*progress)(double, void *), void *pctx) {
    gxz z;
    if (!gxz_open(&z, in_path, 0, 0)) { snprintf(err, errlen, "%s", z.err); return 0; }
    buf mf = {0};
    bstr(&mf, "Manifest-Version: 1.0\r\nCreated-By: 1.0 (Android)\r\n\r\n");
    buf sfe = {0};
    gxzw_op *ops = calloc(z.n + 4, sizeof(gxzw_op));
    size_t nops = 0;
    uint64_t total = 1, done = 0;
    for (size_t i = 0; i < z.n; i++) total += z.e[i].usize;
    int ok = 1;
    for (size_t i = 0; i < z.n && ok; i++) {
        gxz_entry *e = &z.e[i];
        if (is_sig_file(e->name)) { ops[nops].name = e->name; ops[nops].del = 1; nops++; continue; }
        if (e->name_len && e->name[e->name_len - 1] == '/') continue;
        if (cancel && *cancel) { snprintf(err, errlen, GXT("отменено")); ok = 0; break; }
        gx_sha256 h; gx_sha256_init(&h);
        if (!gxz_stream(&z, e, sha_sink, &h, cancel)) { snprintf(err, errlen, "%s: %s", e->name, z.err); ok = 0; break; }
        uint8_t d[32]; gx_sha256_final(&h, d);
        char b64[64]; gx_base64(d, 32, b64);
        buf sec = {0};
        char *line = malloc(e->name_len + 16);
        sprintf(line, "Name: %s", e->name);
        mf_line(&sec, line); free(line);
        bstr(&sec, "SHA-256-Digest: "); bstr(&sec, b64); bstr(&sec, "\r\n\r\n");
        bput(&mf, sec.p, sec.n);
        uint8_t sd[32]; gx_sha256_buf(sec.p, sec.n, sd);
        char sb64[64]; gx_base64(sd, 32, sb64);
        line = malloc(e->name_len + 16);
        sprintf(line, "Name: %s", e->name);
        mf_line(&sfe, line); free(line);
        bstr(&sfe, "SHA-256-Digest: "); bstr(&sfe, sb64); bstr(&sfe, "\r\n\r\n");
        free(sec.p);
        done += e->usize;
        if (progress) progress(0.6 * done / total, pctx);
    }
    buf sf = {0}, rsa = {0};
    if (ok) {
        uint8_t md[32]; gx_sha256_buf(mf.p, mf.n, md);
        char m64[64]; gx_base64(md, 32, m64);
        bstr(&sf, "Signature-Version: 1.0\r\nCreated-By: 1.0 (Android)\r\nSHA-256-Digest-Manifest: ");
        bstr(&sf, m64);
        bstr(&sf, "\r\nX-Android-APK-Signed: 2\r\n\r\n");
        bput(&sf, sfe.p, sfe.n);
        if (!pkcs7(s, sf.p, sf.n, &rsa)) { snprintf(err, errlen, GXT("ошибка подписи v1")); ok = 0; }
    }
    if (ok) {
        ops[nops++] = (gxzw_op){.name = "META-INF/MANIFEST.MF", .src_data = mf.p, .src_len = mf.n};
        ops[nops++] = (gxzw_op){.name = "META-INF/CERT.SF", .src_data = sf.p, .src_len = sf.n};
        ops[nops++] = (gxzw_op){.name = "META-INF/CERT.RSA", .src_data = rsa.p, .src_len = rsa.n};
        ok = gxzw_rewrite(in_path, out_path, ops, nops, GXZW_ALIGN_APK, err, errlen, cancel, NULL, NULL);
    }
    gxz_close(&z);
    free(ops); free(mf.p); free(sfe.p); free(sf.p); free(rsa.p);
    if (ok && progress) progress(0.8, pctx);
    if (ok) ok = add_v2(out_path, s, err, errlen);
    if (!ok) unlink(out_path);
    if (ok && progress) progress(1, pctx);
    return ok;
}

void gx_apk_sig_info(const char *path, int *v1, int *v2) {
    *v1 = *v2 = 0;
    gxz z;
    if (!gxz_open(&z, path, 0, 0)) return;
    for (size_t i = 0; i < z.n; i++) {
        size_t l = strlen(z.e[i].name);
        if (!strncasecmp(z.e[i].name, "META-INF/", 9) && l > 3 && (!strcasecmp(z.e[i].name + l - 3, ".SF"))) *v1 = 1;
    }
    uint64_t cd, cs, eo; int z64;
    if (gxz_layout(&z, &cd, &cs, &eo, &z64) && cd >= 32) {
        uint8_t m[16];
        if (pread(z.fd, m, 16, (off_t)(z.base + cd - 16)) == 16 && !memcmp(m, "APK Sig Block 42", 16)) *v2 = 1;
    }
    gxz_close(&z);
}

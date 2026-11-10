// Разбор PKCS#12 (RFC 7292) своим кодом. Поддержка:
//   PBES1 (PKCS#12 PBE): pbeWithSHAAnd3-KeyTripleDES-CBC, pbeWithSHAAnd40BitRC2-CBC
//   PBES2: PBKDF2 (HMAC-SHA1/224/256/384/512) + AES-128/192/256-CBC или 3DES-CBC
// Крипто (SHA1, PBKDF2, CBC) — во внешнем бэкенде (CommonCrypto / OpenSSL).
#include "gx_p12.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ------- мелкий DER-парсер (только definite length, одно-байтовые теги) -------
typedef struct { const uint8_t *p, *e; } D;

static int tlv(D *d, unsigned *tag, const uint8_t **vp, size_t *vlen) {
    if (d->p >= d->e) return 0;
    unsigned t = *d->p++;
    if ((t & 0x1f) == 0x1f) return 0;              // многобайтовый тег — не нужен для p12
    if (d->p >= d->e) return 0;
    size_t len; unsigned b = *d->p++;
    if (b < 0x80) len = b;
    else {
        int nb = b & 0x7f;
        if (nb == 0 || nb > 4 || d->p + nb > d->e) return 0;
        len = 0; while (nb--) len = (len << 8) | *d->p++;
    }
    if ((size_t)(d->e - d->p) < len) return 0;
    *tag = t; *vp = d->p; *vlen = len; d->p += len;
    return 1;
}
// войти в конструктор ожидаемого тега: вернуть D по его телу
static int enter(D *d, unsigned want, D *inner) {
    unsigned t; const uint8_t *v; size_t n;
    if (!tlv(d, &t, &v, &n) || t != want) return 0;
    inner->p = v; inner->e = v + n; return 1;
}
// прочитать один TLV ожидаемого тега
static int take(D *d, unsigned want, const uint8_t **v, size_t *n) {
    unsigned t; if (!tlv(d, &t, v, n)) return 0; return t == want;
}

// ------- OID'ы (содержимое, без тега/длины) -------
#define OID(name, ...) static const uint8_t name[] = { __VA_ARGS__ }
OID(oid_data,      0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x01);
OID(oid_encdata,   0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x07,0x06);
OID(oid_keybag,    0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x01);
OID(oid_shroud,    0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x02);
OID(oid_certbag,   0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x0a,0x01,0x03);
OID(oid_x509,      0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x09,0x16,0x01);
OID(oid_pbe3des,   0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x01,0x03);
OID(oid_pberc2_40, 0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x0c,0x01,0x06);
OID(oid_pbes2,     0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x05,0x0d);
OID(oid_pbkdf2,    0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x05,0x0c);
OID(oid_hmac_sha1, 0x2a,0x86,0x48,0x86,0xf7,0x0d,0x02,0x07);
OID(oid_hmac_224,  0x2a,0x86,0x48,0x86,0xf7,0x0d,0x02,0x08);
OID(oid_hmac_256,  0x2a,0x86,0x48,0x86,0xf7,0x0d,0x02,0x09);
OID(oid_hmac_384,  0x2a,0x86,0x48,0x86,0xf7,0x0d,0x02,0x0a);
OID(oid_hmac_512,  0x2a,0x86,0x48,0x86,0xf7,0x0d,0x02,0x0b);
OID(oid_des3_cbc,  0x2a,0x86,0x48,0x86,0xf7,0x0d,0x03,0x07);
OID(oid_aes128cbc, 0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x01,0x02);
OID(oid_aes192cbc, 0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x01,0x16);
OID(oid_aes256cbc, 0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x01,0x2a);
OID(oid_rsa,       0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01);

static int oideq(const uint8_t *v, size_t n, const uint8_t *o, size_t ol) { return n == ol && !memcmp(v, o, ol); }
#define OIDEQ(v, n, name) oideq((v), (n), name, sizeof name)

static unsigned rd_uint(const uint8_t *v, size_t n) {           // маленький INTEGER
    unsigned r = 0; for (size_t i = 0; i < n && i < 4; i++) r = (r << 8) | v[i]; return r;
}

// Похоже ли на корректный DER SEQUENCE? При неверном пароле расшифровка даёт мусор,
// а снятие PKCS#7-паддинга не везде ловит это (CommonCrypto пропускает «правдоподобный»
// паддинг) — поэтому отличаем неверный пароль от реального сбоя по первому TLV.
static int der_ok(const uint8_t *d, size_t n) {
    if (n < 2 || d[0] != 0x30) return 0;
    D t = { d, d + n }; unsigned tag; const uint8_t *v; size_t vn;
    return tlv(&t, &tag, &v, &vn) && tag == 0x30;
}

// пароль → BMPString (UTF-16BE) + двойной нуль-терминатор (для PKCS#12 KDF)
static uint8_t *to_bmp(const char *pw, size_t *outlen) {
    size_t n = pw ? strlen(pw) : 0;
    uint8_t *b = malloc(n * 2 + 2);
    size_t j = 0;
    for (size_t i = 0; i < n; ) {
        unsigned cp = (unsigned char)pw[i];                      // упрощённый UTF-8 → код-поинт (BMP)
        if (cp < 0x80) i += 1;
        else if ((cp & 0xe0) == 0xc0 && i + 1 < n) { cp = ((cp & 0x1f) << 6) | (pw[i+1] & 0x3f); i += 2; }
        else if ((cp & 0xf0) == 0xe0 && i + 2 < n) { cp = ((cp & 0x0f) << 12) | ((pw[i+1] & 0x3f) << 6) | (pw[i+2] & 0x3f); i += 3; }
        else i += 1;
        b[j++] = (cp >> 8) & 0xff; b[j++] = cp & 0xff;
    }
    b[j++] = 0; b[j++] = 0;                                      // терминатор
    *outlen = j;                                                 // пустой пароль → 2 нулевых байта
    return b;
}

// PKCS#12 KDF (RFC 7292 B.2) на SHA-1 (u=20, v=64). id: 1=ключ, 2=IV.
static void p12kdf(const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t slen,
                   unsigned iter, int id, uint8_t *out, size_t need) {
    const int u = 20, v = 64;
    uint8_t Db[64]; memset(Db, id, v);
    size_t Slen = slen ? ((slen + v - 1) / v) * v : 0;
    size_t Plen = pwlen ? ((pwlen + v - 1) / v) * v : 0;
    size_t Ilen = Slen + Plen;
    uint8_t *I = malloc(Ilen ? Ilen : 1);
    for (size_t i = 0; i < Slen; i++) I[i] = salt[i % slen];
    for (size_t i = 0; i < Plen; i++) I[Slen + i] = pw[i % pwlen];
    uint8_t *buf = malloc((size_t)v + Ilen);
    while (need) {
        uint8_t A[20];
        memcpy(buf, Db, v); memcpy(buf + v, I, Ilen);
        gxp12_sha1(buf, (size_t)v + Ilen, A);
        for (unsigned k = 1; k < iter; k++) gxp12_sha1(A, u, A);
        size_t take_n = need < (size_t)u ? need : (size_t)u;
        memcpy(out, A, take_n); out += take_n; need -= take_n;
        if (!need) break;
        uint8_t B[64]; for (int i = 0; i < v; i++) B[i] = A[i % u];
        for (size_t off = 0; off < Ilen; off += v) {             // I_j = (I_j + B + 1) mod 2^(v*8)
            int carry = 1;
            for (int i = v - 1; i >= 0; i--) { int s = I[off + i] + B[i] + carry; I[off + i] = (uint8_t)s; carry = s >> 8; }
        }
    }
    free(buf); free(I);
}

// ------- расшифровка одного зашифрованного блока по AlgorithmIdentifier -------
// alg: D по телу SEQUENCE AlgorithmIdentifier (уже внутри). Возвращает malloc(pt) или NULL.
static uint8_t *pbe_decrypt(D alg, const char *pw, const uint8_t *ct, size_t ctlen,
                            size_t *ptlen, int *reason) {
    const uint8_t *oid; size_t oidn;
    if (!take(&alg, 0x06, &oid, &oidn)) { *reason = GXP12_PARSE; return NULL; }

    uint8_t key[32], iv[16]; size_t keylen = 0, ivlen = 0; int cipher = 0;

    if (OIDEQ(oid, oidn, oid_pbe3des) || OIDEQ(oid, oidn, oid_pberc2_40)) {
        // PBES1 PKCS#12: params = SEQUENCE { salt OCTET STRING, iter INTEGER }
        D pr; if (!enter(&alg, 0x30, &pr)) { *reason = GXP12_PARSE; return NULL; }
        const uint8_t *salt, *itv; size_t sl, il;
        if (!take(&pr, 0x04, &salt, &sl) || !take(&pr, 0x02, &itv, &il)) { *reason = GXP12_PARSE; return NULL; }
        unsigned iter = rd_uint(itv, il);
        size_t bl; uint8_t *bmp = to_bmp(pw, &bl);
        if (OIDEQ(oid, oidn, oid_pbe3des)) { cipher = GXP12_C_3DES; keylen = 24; ivlen = 8; }
        else                               { cipher = GXP12_C_RC2;  keylen = 5;  ivlen = 8; }
        p12kdf(bmp, bl, salt, sl, iter, 1, key, keylen);
        p12kdf(bmp, bl, salt, sl, iter, 2, iv, ivlen);
        free(bmp);
    } else if (OIDEQ(oid, oidn, oid_pbes2)) {
        // PBES2: SEQUENCE { kdf AlgId(PBKDF2), enc AlgId }
        D p2; if (!enter(&alg, 0x30, &p2)) { *reason = GXP12_PARSE; return NULL; }
        D kdf, enc;
        if (!enter(&p2, 0x30, &kdf) || !enter(&p2, 0x30, &enc)) { *reason = GXP12_PARSE; return NULL; }
        const uint8_t *ko; size_t kon;
        if (!take(&kdf, 0x06, &ko, &kon) || !OIDEQ(ko, kon, oid_pbkdf2)) { *reason = GXP12_UNSUPPORTED; return NULL; }
        // PBKDF2-params: SEQUENCE { salt OCTET STRING, iter INT, [keyLen INT], [prf AlgId] }
        D kp; if (!enter(&kdf, 0x30, &kp)) { *reason = GXP12_PARSE; return NULL; }
        const uint8_t *salt, *itv; size_t sl, il;
        if (!take(&kp, 0x04, &salt, &sl) || !take(&kp, 0x02, &itv, &il)) { *reason = GXP12_PARSE; return NULL; }
        unsigned iter = rd_uint(itv, il);
        int prf = GXP12_SHA1; long explicitKeyLen = -1;
        // необязательные поля: keyLength (INTEGER) и/или prf (SEQUENCE)
        while (kp.p < kp.e) {
            unsigned t; const uint8_t *v; size_t n;
            const uint8_t *save = kp.p; (void)save;
            if (!tlv(&kp, &t, &v, &n)) break;
            if (t == 0x02) explicitKeyLen = (long)rd_uint(v, n);
            else if (t == 0x30) {
                D pd = { v, v + n }; const uint8_t *po; size_t pn;
                if (take(&pd, 0x06, &po, &pn)) {
                    if (OIDEQ(po, pn, oid_hmac_256)) prf = GXP12_SHA256;
                    else if (OIDEQ(po, pn, oid_hmac_224)) prf = GXP12_SHA224;
                    else if (OIDEQ(po, pn, oid_hmac_384)) prf = GXP12_SHA384;
                    else if (OIDEQ(po, pn, oid_hmac_512)) prf = GXP12_SHA512;
                    else prf = GXP12_SHA1;
                }
            }
        }
        // enc: SEQUENCE { OID, iv OCTET STRING }
        const uint8_t *eo; size_t en;
        if (!take(&enc, 0x06, &eo, &en)) { *reason = GXP12_PARSE; return NULL; }
        if      (OIDEQ(eo, en, oid_aes128cbc)) { cipher = GXP12_C_AES; keylen = 16; }
        else if (OIDEQ(eo, en, oid_aes192cbc)) { cipher = GXP12_C_AES; keylen = 24; }
        else if (OIDEQ(eo, en, oid_aes256cbc)) { cipher = GXP12_C_AES; keylen = 32; }
        else if (OIDEQ(eo, en, oid_des3_cbc))  { cipher = GXP12_C_3DES; keylen = 24; }
        else { *reason = GXP12_UNSUPPORTED; return NULL; }
        if (explicitKeyLen > 0 && (size_t)explicitKeyLen <= sizeof key) keylen = (size_t)explicitKeyLen;
        const uint8_t *ivp; size_t ivn;
        if (!take(&enc, 0x04, &ivp, &ivn) || ivn > sizeof iv) { *reason = GXP12_PARSE; return NULL; }
        ivlen = ivn; memcpy(iv, ivp, ivn);
        if (gxp12_pbkdf2(prf, (const uint8_t *)(pw ? pw : ""), pw ? strlen(pw) : 0, salt, sl, iter, key, keylen) != 0) {
            *reason = GXP12_PARSE; return NULL;
        }
    } else {
        *reason = GXP12_UNSUPPORTED; return NULL;
    }

    (void)ivlen;
    uint8_t *pt = malloc(ctlen ? ctlen : 1); size_t pl = ctlen;
    if (gxp12_cbc_decrypt(cipher, key, keylen, iv, ct, ctlen, pt, &pl) != 0) {
        free(pt); *reason = GXP12_BADPW; return NULL;            // битый паддинг → неверный пароль
    }
    *ptlen = pl; return pt;
}

// ------- сбор сертификатов и ключа из SafeContents -------
typedef struct {
    uint8_t **certs; size_t *clens; int nc, cap;
    uint8_t *key; size_t klen;                                   // PKCS#8 PrivateKeyInfo (как есть)
} bag_sink;

static void add_cert(bag_sink *s, const uint8_t *der, size_t n) {
    if (s->nc >= s->cap) { s->cap = s->cap ? s->cap * 2 : 8;
        s->certs = realloc(s->certs, s->cap * sizeof *s->certs);
        s->clens = realloc(s->clens, s->cap * sizeof *s->clens); }
    uint8_t *c = malloc(n); memcpy(c, der, n);
    s->certs[s->nc] = c; s->clens[s->nc] = n; s->nc++;
}

// разобрать PrivateKeyInfo (PKCS#8) → вытащить RSAPrivateKey (PKCS#1) в key_pkcs1
static int pkcs8_to_pkcs1(const uint8_t *p8, size_t n, uint8_t **out, size_t *outlen) {
    D d = { p8, p8 + n }, pki;
    if (!enter(&d, 0x30, &pki)) return 0;
    const uint8_t *v; size_t vn;
    if (!take(&pki, 0x02, &v, &vn)) return 0;                    // version
    D alg; if (!enter(&pki, 0x30, &alg)) return 0;               // AlgorithmIdentifier
    const uint8_t *ao; size_t an;
    if (!take(&alg, 0x06, &ao, &an) || !OIDEQ(ao, an, oid_rsa)) return 0;  // только RSA
    const uint8_t *pk; size_t pkn;
    if (!take(&pki, 0x04, &pk, &pkn)) return 0;                  // privateKey OCTET STRING = RSAPrivateKey
    uint8_t *k = malloc(pkn); memcpy(k, pk, pkn);
    *out = k; *outlen = pkn; return 1;
}

static int process_safecontents(const uint8_t *der, size_t n, const char *pw, bag_sink *s, int *reason);

// один SafeBag
static int process_bag(D bag, const char *pw, bag_sink *s, int *reason) {
    const uint8_t *bid; size_t bidn;
    if (!take(&bag, 0x06, &bid, &bidn)) { *reason = GXP12_PARSE; return 0; }
    D val; if (!enter(&bag, 0xA0, &val)) { *reason = GXP12_PARSE; return 0; }   // [0] EXPLICIT

    if (OIDEQ(bid, bidn, oid_certbag)) {
        D cb; if (!enter(&val, 0x30, &cb)) return 1;             // CertBag SEQUENCE
        const uint8_t *cid; size_t cidn;
        if (!take(&cb, 0x06, &cid, &cidn)) return 1;
        if (!OIDEQ(cid, cidn, oid_x509)) return 1;              // только x509
        D cv; if (!enter(&cb, 0xA0, &cv)) return 1;             // [0] EXPLICIT
        const uint8_t *der; size_t dn;
        if (take(&cv, 0x04, &der, &dn)) add_cert(s, der, dn);   // OCTET STRING = cert DER
    } else if (OIDEQ(bid, bidn, oid_keybag)) {
        if (!s->key) pkcs8_to_pkcs1(val.p, (size_t)(val.e - val.p), &s->key, &s->klen);  // PKCS#8 открытым текстом
    } else if (OIDEQ(bid, bidn, oid_shroud)) {
        // EncryptedPrivateKeyInfo: SEQUENCE { AlgId, OCTET STRING enc }
        D epki; if (!enter(&val, 0x30, &epki)) { *reason = GXP12_PARSE; return 0; }
        D alg; if (!enter(&epki, 0x30, &alg)) { *reason = GXP12_PARSE; return 0; }
        const uint8_t *enc; size_t encn;
        if (!take(&epki, 0x04, &enc, &encn)) { *reason = GXP12_PARSE; return 0; }
        size_t ptlen = 0; uint8_t *pt = pbe_decrypt(alg, pw, enc, encn, &ptlen, reason);
        if (!pt) return 0;
        if (!der_ok(pt, ptlen)) { free(pt); *reason = GXP12_BADPW; return 0; }  // мусор → неверный пароль
        if (!s->key) pkcs8_to_pkcs1(pt, ptlen, &s->key, &s->klen);
        free(pt);
    }
    return 1;
}

static int process_safecontents(const uint8_t *der, size_t n, const char *pw, bag_sink *s, int *reason) {
    D d = { der, der + n }, seq;
    if (!enter(&d, 0x30, &seq)) { *reason = GXP12_PARSE; return 0; }   // SEQUENCE OF SafeBag
    while (seq.p < seq.e) {
        unsigned t; const uint8_t *v; size_t vn;
        if (!tlv(&seq, &t, &v, &vn) || t != 0x30) { *reason = GXP12_PARSE; return 0; }
        D bag = { v, v + vn };
        if (!process_bag(bag, pw, s, reason)) return 0;
    }
    return 1;
}

// ------- выбор leaf-сертификата по совпадению модуля с ключом -------
// вытащить модуль RSA (байты INTEGER без ведущего 0x00) из RSAPrivateKey
static const uint8_t *key_modulus(const uint8_t *k, size_t n, size_t *mlen) {
    D d = { k, k + n }, s;
    if (!enter(&d, 0x30, &s)) return NULL;
    const uint8_t *v; size_t vn;
    if (!take(&s, 0x02, &v, &vn)) return NULL;                   // version
    if (!take(&s, 0x02, &v, &vn)) return NULL;                   // modulus
    while (vn > 1 && v[0] == 0) { v++; vn--; }
    *mlen = vn; return v;
}
// из cert DER вытащить модуль subjectPublicKey (RSA)
static const uint8_t *cert_modulus(const uint8_t *c, size_t n, size_t *mlen) {
    D d = { c, c + n }, cert, tbs;
    if (!enter(&d, 0x30, &cert) || !enter(&cert, 0x30, &tbs)) return NULL;
    while (tbs.p < tbs.e) {                                      // ищем SPKI: SEQ{ SEQ{OID rsa}, BIT STRING }
        unsigned t; const uint8_t *v; size_t vn;
        if (!tlv(&tbs, &t, &v, &vn)) return NULL;
        if (t != 0x30) continue;
        D spki = { v, v + vn }, ai; const uint8_t *ao; size_t an;
        if (!enter(&spki, 0x30, &ai)) continue;
        if (!take(&ai, 0x06, &ao, &an) || !OIDEQ(ao, an, oid_rsa)) continue;
        const uint8_t *bit; size_t bn;
        if (!take(&spki, 0x03, &bit, &bn) || bn < 1) return NULL;
        D pk = { bit + 1, bit + bn }, rsa;                      // пропустить байт «unused bits»
        if (!enter(&pk, 0x30, &rsa)) return NULL;
        const uint8_t *m; size_t mn;
        if (!take(&rsa, 0x02, &m, &mn)) return NULL;
        while (mn > 1 && m[0] == 0) { m++; mn--; }
        *mlen = mn; return m;
    }
    return NULL;
}

int gx_p12_parse(const uint8_t *p12, size_t n, const char *password,
                 gx_p12 *out, int *reason, char *err, size_t errlen) {
    int dummy; if (!reason) reason = &dummy; *reason = GXP12_PARSE;
    memset(out, 0, sizeof *out);
    if (err && errlen) err[0] = 0;

    D d = { p12, p12 + n }, pfx;
    if (!enter(&d, 0x30, &pfx)) { if (err) snprintf(err, errlen, "not a PFX"); return 0; }
    const uint8_t *v; size_t vn;
    if (!take(&pfx, 0x02, &v, &vn)) return 0;                    // version (3)
    // authSafe ContentInfo: SEQUENCE { OID data, [0] { OCTET STRING authSafe } }
    D ci; if (!enter(&pfx, 0x30, &ci)) return 0;
    const uint8_t *ctype; size_t ctn;
    if (!take(&ci, 0x06, &ctype, &ctn) || !OIDEQ(ctype, ctn, oid_data)) { *reason = GXP12_UNSUPPORTED; return 0; }
    D c0; if (!enter(&ci, 0xA0, &c0)) return 0;
    const uint8_t *asafe; size_t asn;
    if (!take(&c0, 0x04, &asafe, &asn)) return 0;               // OCTET STRING = AuthenticatedSafe DER

    bag_sink sink; memset(&sink, 0, sizeof sink);

    D as = { asafe, asafe + asn }, aseq;
    if (!enter(&as, 0x30, &aseq)) { *reason = GXP12_PARSE; goto fail; }   // SEQUENCE OF ContentInfo
    while (aseq.p < aseq.e) {
        unsigned t; const uint8_t *cv; size_t cvn;
        if (!tlv(&aseq, &t, &cv, &cvn) || t != 0x30) { *reason = GXP12_PARSE; goto fail; }
        D item = { cv, cv + cvn };
        const uint8_t *oid; size_t oidn;
        if (!take(&item, 0x06, &oid, &oidn)) { *reason = GXP12_PARSE; goto fail; }
        D cont; if (!enter(&item, 0xA0, &cont)) { *reason = GXP12_PARSE; goto fail; }

        if (OIDEQ(oid, oidn, oid_data)) {
            const uint8_t *sc; size_t scn;
            if (!take(&cont, 0x04, &sc, &scn)) { *reason = GXP12_PARSE; goto fail; }
            if (!process_safecontents(sc, scn, password, &sink, reason)) goto fail;
        } else if (OIDEQ(oid, oidn, oid_encdata)) {
            // EncryptedData: SEQUENCE { INT ver, EncryptedContentInfo SEQ { OID data, AlgId, [0] IMPLICIT enc } }
            D ed; if (!enter(&cont, 0x30, &ed)) { *reason = GXP12_PARSE; goto fail; }
            const uint8_t *edv; size_t edvn; if (!take(&ed, 0x02, &edv, &edvn)) { *reason = GXP12_PARSE; goto fail; }
            D eci; if (!enter(&ed, 0x30, &eci)) { *reason = GXP12_PARSE; goto fail; }
            const uint8_t *eo; size_t eon; if (!take(&eci, 0x06, &eo, &eon)) { *reason = GXP12_PARSE; goto fail; }
            D alg; if (!enter(&eci, 0x30, &alg)) { *reason = GXP12_PARSE; goto fail; }
            unsigned tg; const uint8_t *ect; size_t ectn;
            if (!tlv(&eci, &tg, &ect, &ectn) || (tg != 0x80 && tg != 0x04)) { *reason = GXP12_PARSE; goto fail; } // [0] implicit или OCTET STRING
            size_t ptlen = 0; uint8_t *pt = pbe_decrypt(alg, password, ect, ectn, &ptlen, reason);
            if (!pt) goto fail;
            if (!der_ok(pt, ptlen)) { free(pt); *reason = GXP12_BADPW; goto fail; }  // мусор → неверный пароль
            int ok = process_safecontents(pt, ptlen, password, &sink, reason);
            free(pt);
            if (!ok) { if (*reason == GXP12_PARSE) *reason = GXP12_BADPW; goto fail; }  // сбой разбора расшифрованного ≈ неверный пароль
        }
    }

    if (!sink.key) { *reason = sink.nc ? GXP12_UNSUPPORTED : GXP12_BADPW;
        if (err) snprintf(err, errlen, "no RSA private key found"); goto fail; }
    if (!sink.nc) { *reason = GXP12_PARSE; if (err) snprintf(err, errlen, "no certificate found"); goto fail; }

    // переставить leaf (совпадающий с ключом модуль) на позицию 0
    size_t kml = 0; const uint8_t *km = key_modulus(sink.key, sink.klen, &kml);
    if (km) {
        for (int i = 0; i < sink.nc; i++) {
            size_t cml = 0; const uint8_t *cm = cert_modulus(sink.certs[i], sink.clens[i], &cml);
            if (cm && cml == kml && !memcmp(cm, km, kml)) {
                if (i != 0) { uint8_t *tc = sink.certs[0]; size_t tl = sink.clens[0];
                    sink.certs[0] = sink.certs[i]; sink.clens[0] = sink.clens[i];
                    sink.certs[i] = tc; sink.clens[i] = tl; }
                break;
            }
        }
    }

    out->key_pkcs1 = sink.key; out->key_len = sink.klen;
    out->certs = sink.certs; out->cert_lens = sink.clens; out->ncerts = sink.nc;
    out->key_bits = (int)(kml * 8);
    *reason = GXP12_OK;
    return 1;

fail:
    for (int i = 0; i < sink.nc; i++) free(sink.certs[i]);
    free(sink.certs); free(sink.clens); free(sink.key);
    return 0;
}

void gx_p12_free(gx_p12 *o) {
    if (!o) return;
    for (int i = 0; i < o->ncerts; i++) free(o->certs[i]);
    free(o->certs); free(o->cert_lens); free(o->key_pkcs1);
    memset(o, 0, sizeof *o);
}

#include "gx_tr.h"
// Подпись Mach-O настоящим сертификатом. Чистый C, тестируется на хосте (openssl).
#include "gx_csign.h"
#include "gx_sha256.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

// ---------- big-endian helpers ----------
static uint32_t RB32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void WB32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void WB64(uint8_t *p, uint64_t v) { for (int i = 7; i >= 0; i--) { p[i] = (uint8_t)v; v >>= 8; } }
static uint32_t LE32(const uint8_t *p) { return (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void WLE32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static uint64_t LE64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static void WLE64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) { p[i] = v; v >>= 8; } }

// ---------- растущий буфер ----------
typedef struct { uint8_t *p; size_t n, cap; int bad; } buf;
static void bput(buf *b, const void *d, size_t n) {
    if (b->bad) return;
    if (b->n + n > b->cap) { size_t c = (b->n + n) * 2 + 64; uint8_t *np = realloc(b->p, c); if (!np) { b->bad = 1; return; } b->p = np; b->cap = c; }
    if (d) memcpy(b->p + b->n, d, n); else memset(b->p + b->n, 0, n);
    b->n += n;
}
static void bb(buf *b, uint8_t x) { bput(b, &x, 1); }

// ---------- DER ----------
// длина в форме DER
static void der_len(buf *b, size_t n) {
    if (n < 0x80) { bb(b, (uint8_t)n); return; }
    uint8_t t[8]; int i = 0;
    while (n) { t[i++] = (uint8_t)n; n >>= 8; }
    bb(b, (uint8_t)(0x80 | i));
    for (int k = i - 1; k >= 0; k--) bb(b, t[k]);
}
// TLV: тег + длина + содержимое
static void der_tlv(buf *b, uint8_t tag, const void *v, size_t n) { bb(b, tag); der_len(b, n); bput(b, v, n); }
// обёртка: взять содержимое из временного буфера c и завернуть тегом
static void der_wrap(buf *b, uint8_t tag, buf *c) { if (c->bad) b->bad = 1; der_tlv(b, tag, c->p, c->n); }

// готовые OID (значение без тега/длины)
static const uint8_t OID_signedData[] = {0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x02};
static const uint8_t OID_data[]       = {0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x01};
static const uint8_t OID_sha256[]     = {0x60,0x86,0x48,0x01,0x65,0x03,0x04,0x02,0x01};
static const uint8_t OID_rsaEnc[]     = {0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01};
static const uint8_t OID_ctype[]      = {0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x03};
static const uint8_t OID_mdigest[]    = {0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x04};
static const uint8_t OID_stime[]      = {0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x09,0x05};
static const uint8_t OID_appleHashes[]= {0x2A,0x86,0x48,0x86,0xF7,0x63,0x64,0x09,0x02};
static void der_oid(buf *b, const uint8_t *oid, size_t n) { der_tlv(b, 0x06, oid, n); }

// AlgorithmIdentifier { sha256, NULL }
static void alg_sha256(buf *b) { buf c = {0}; der_oid(&c, OID_sha256, sizeof OID_sha256); der_tlv(&c, 0x05, NULL, 0); der_wrap(b, 0x30, &c); free(c.p); }
// AlgorithmIdentifier { rsaEncryption, NULL }
static void alg_rsa(buf *b) { buf c = {0}; der_oid(&c, OID_rsaEnc, sizeof OID_rsaEnc); der_tlv(&c, 0x05, NULL, 0); der_wrap(b, 0x30, &c); free(c.p); }

// ---------- разбор X.509 для issuer+serial ----------
// читает один TLV: возвращает тег, указатель на содержимое, длину содержимого, полный размер TLV
static int der_read(const uint8_t *p, size_t avail, uint8_t *tag, const uint8_t **content, size_t *clen, size_t *total) {
    if (avail < 2) return 0;
    *tag = p[0];
    size_t i = 1, l;
    if (p[1] < 0x80) { l = p[1]; i = 2; }
    else { int nb = p[1] & 0x7f; if (nb == 0 || nb > 4 || avail < 2 + (size_t)nb) return 0; l = 0; for (int k = 0; k < nb; k++) l = l << 8 | p[2 + k]; i = 2 + nb; }
    if (i + l > avail) return 0;
    *content = p + i; *clen = l; *total = i + l;
    return 1;
}
// из DER-сертификата вытащить issuer (полный TLV) и serialNumber (полный TLV)
static int cert_issuer_serial(const uint8_t *cert, size_t n, const uint8_t **iss, size_t *isslen, const uint8_t **ser, size_t *serlen) {
    uint8_t tag; const uint8_t *c; size_t cl, tot;
    if (!der_read(cert, n, &tag, &c, &cl, &tot) || tag != 0x30) return 0;      // Certificate SEQ
    const uint8_t *tbs; size_t tbsl;
    if (!der_read(c, cl, &tag, &tbs, &tbsl, &tot) || tag != 0x30) return 0;     // tbsCertificate SEQ
    const uint8_t *p = tbs; size_t rem = tbsl;
    if (!der_read(p, rem, &tag, &c, &cl, &tot)) return 0;
    if (tag == 0xA0) { p += tot; rem -= tot; }                                 // [0] version — пропустить
    if (!der_read(p, rem, &tag, &c, &cl, &tot) || tag != 0x02) return 0;        // serialNumber INTEGER
    *ser = p; *serlen = tot; p += tot; rem -= tot;
    if (!der_read(p, rem, &tag, &c, &cl, &tot) || tag != 0x30) return 0;        // signature AlgId SEQ — пропустить
    p += tot; rem -= tot;
    if (!der_read(p, rem, &tag, &c, &cl, &tot) || tag != 0x30) return 0;        // issuer Name SEQ
    *iss = p; *isslen = tot;
    return 1;
}

// subject/CN/OU и notAfter из сертификата
static int64_t parse_asn1_time(const uint8_t *p, size_t n, uint8_t tag) {
    // UTCTime YYMMDDHHMMSSZ (n>=13) или GeneralizedTime YYYYMMDDHHMMSSZ (n>=15)
    char buf[16]; if (n >= sizeof buf) return 0; memcpy(buf, p, n); buf[n] = 0;
    struct tm t; memset(&t, 0, sizeof t); int i = 0; int y;
    if (tag == 0x17) { if (n < 12) return 0; y = (buf[0]-'0')*10 + (buf[1]-'0'); y += y < 50 ? 2000 : 1900; i = 2; }
    else { if (n < 14) return 0; y = (buf[0]-'0')*1000 + (buf[1]-'0')*100 + (buf[2]-'0')*10 + (buf[3]-'0'); i = 4; }
    t.tm_year = y - 1900;
    t.tm_mon  = (buf[i]-'0')*10 + (buf[i+1]-'0') - 1; i += 2;
    t.tm_mday = (buf[i]-'0')*10 + (buf[i+1]-'0'); i += 2;
    t.tm_hour = (buf[i]-'0')*10 + (buf[i+1]-'0'); i += 2;
    t.tm_min  = (buf[i]-'0')*10 + (buf[i+1]-'0'); i += 2;
    t.tm_sec  = (buf[i]-'0')*10 + (buf[i+1]-'0');
#if defined(_WIN32)
    return (int64_t)_mkgmtime(&t);
#else
    return (int64_t)timegm(&t);
#endif
}
int gx_cert_fields(const uint8_t *cert, size_t n, char *team, size_t tsz, char *cn, size_t csz, int64_t *not_after) {
    if (team && tsz) team[0] = 0; if (cn && csz) cn[0] = 0; if (not_after) *not_after = 0;
    uint8_t tag; const uint8_t *c; size_t cl, tot;
    if (!der_read(cert, n, &tag, &c, &cl, &tot) || tag != 0x30) return 0;
    const uint8_t *tbs; size_t tbsl;
    if (!der_read(c, cl, &tag, &tbs, &tbsl, &tot) || tag != 0x30) return 0;
    const uint8_t *p = tbs; size_t rem = tbsl;
    if (!der_read(p, rem, &tag, &c, &cl, &tot)) return 0;
    if (tag == 0xA0) { p += tot; rem -= tot; }                      // version
    if (!der_read(p, rem, &tag, &c, &cl, &tot)) return 0; p += tot; rem -= tot;  // serial
    if (!der_read(p, rem, &tag, &c, &cl, &tot)) return 0; p += tot; rem -= tot;  // sigalg
    if (!der_read(p, rem, &tag, &c, &cl, &tot)) return 0; p += tot; rem -= tot;  // issuer
    // validity SEQ { notBefore, notAfter }
    if (!der_read(p, rem, &tag, &c, &cl, &tot) || tag != 0x30) return 0;
    { const uint8_t *vp = c; size_t vr = cl; uint8_t vt; const uint8_t *vc; size_t vcl, vtt;
      if (der_read(vp, vr, &vt, &vc, &vcl, &vtt)) { vp += vtt; vr -= vtt;
        if (der_read(vp, vr, &vt, &vc, &vcl, &vtt) && not_after) *not_after = parse_asn1_time(vc, vcl, vt); } }
    p += tot; rem -= tot;
    // subject Name SEQ of RDN SET of { OID, value }
    if (!der_read(p, rem, &tag, &c, &cl, &tot) || tag != 0x30) return 0;
    const uint8_t *sp = c; size_t sr = cl;
    static const uint8_t OID_OU[] = {0x55,0x04,0x0B}, OID_CN[] = {0x55,0x04,0x03};
    while (sr > 0) {
        uint8_t rt; const uint8_t *rc; size_t rcl, rtt;
        if (!der_read(sp, sr, &rt, &rc, &rcl, &rtt) || rt != 0x31) break;   // RDN SET
        const uint8_t *ap = rc; size_t ar = rcl;
        uint8_t at; const uint8_t *ac; size_t acl, att;
        if (der_read(ap, ar, &at, &ac, &acl, &att) && at == 0x30) {        // AttributeTypeAndValue SEQ
            const uint8_t *tp = ac; size_t tr = acl;
            uint8_t ot; const uint8_t *oc; size_t ocl, ott;
            if (der_read(tp, tr, &ot, &oc, &ocl, &ott) && ot == 0x06) {    // type OID
                tp += ott; tr -= ott;
                uint8_t st; const uint8_t *sc2; size_t scl, stt;
                if (der_read(tp, tr, &st, &sc2, &scl, &stt)) {             // value (строка)
                    char *dst = NULL; size_t dsz = 0;
                    if (ocl == 3 && !memcmp(oc, OID_OU, 3)) { dst = team; dsz = tsz; }
                    else if (ocl == 3 && !memcmp(oc, OID_CN, 3)) { dst = cn; dsz = csz; }
                    if (dst && dsz && dst[0] == 0) { size_t k = scl < dsz - 1 ? scl : dsz - 1; memcpy(dst, sc2, k); dst[k] = 0; }
                }
            }
        }
        sp += rtt; sr -= rtt;
    }
    return 1;
}

// ---------- атрибут CMS: SEQUENCE { OID, SET { value } } ----------
static void attr(buf *out, const uint8_t *oid, size_t oidn, const uint8_t *valset, size_t valn) {
    buf a = {0};
    der_oid(&a, oid, oidn);
    { buf s = {0}; bput(&s, valset, valn); der_wrap(&a, 0x31, &s); free(s.p); }   // SET { value }
    der_wrap(out, 0x30, &a);
    free(a.p);
}
// элемент для сортировки SET OF
typedef struct { uint8_t *p; size_t n; } item;
static int item_cmp(const void *x, const void *y) {
    const item *a = x, *b = y; size_t m = a->n < b->n ? a->n : b->n;
    int c = memcmp(a->p, b->p, m);
    if (c) return c;
    return a->n < b->n ? -1 : a->n > b->n ? 1 : 0;
}

// Собрать подписанные атрибуты (отсортированный SET OF) в att; вернуть также их DER для подписи (с тегом SET 0x31).
static int build_signed_attrs(buf *att_implicit /*тег A0*/, buf *att_for_sign /*тег 31*/, const uint8_t cdhash[32]) {
    // 1 contentType = data
    buf v_ct = {0}; der_oid(&v_ct, OID_data, sizeof OID_data);
    // 2 signingTime UTCTime
    char ts[16]; time_t now = time(NULL); struct tm g;
#if defined(_WIN32)
    gmtime_s(&g, &now);
#else
    gmtime_r(&now, &g);
#endif
    snprintf(ts, sizeof ts, "%02d%02d%02d%02d%02d%02dZ", g.tm_year % 100, g.tm_mon + 1, g.tm_mday, g.tm_hour, g.tm_min, g.tm_sec);
    buf v_st = {0}; der_tlv(&v_st, 0x17, ts, strlen(ts));
    // 3 messageDigest = OCTET STRING(cdhash)
    buf v_md = {0}; der_tlv(&v_md, 0x04, cdhash, 32);
    // 4 apple cdhashes (9.2): SET-value = SEQUENCE { SEQUENCE{AlgId sha256} , OCTET STRING cdhash }
    buf v_ah = {0}; { buf seq = {0}; alg_sha256(&seq); der_tlv(&seq, 0x04, cdhash, 32); der_wrap(&v_ah, 0x30, &seq); free(seq.p); }

    item its[4]; int ni = 0;
    buf a0 = {0}, a1 = {0}, a2 = {0}, a3 = {0};
    attr(&a0, OID_ctype,  sizeof OID_ctype,  v_ct.p, v_ct.n);
    attr(&a1, OID_stime,  sizeof OID_stime,  v_st.p, v_st.n);
    attr(&a2, OID_mdigest,sizeof OID_mdigest,v_md.p, v_md.n);
    attr(&a3, OID_appleHashes, sizeof OID_appleHashes, v_ah.p, v_ah.n);
    its[ni++] = (item){a0.p, a0.n}; its[ni++] = (item){a1.p, a1.n}; its[ni++] = (item){a2.p, a2.n}; its[ni++] = (item){a3.p, a3.n};
    free(v_ct.p); free(v_st.p); free(v_md.p); free(v_ah.p);
    qsort(its, ni, sizeof its[0], item_cmp);

    buf body = {0};
    for (int i = 0; i < ni; i++) bput(&body, its[i].p, its[i].n);
    der_tlv(att_implicit, 0xA0, body.p, body.n);   // для встраивания в SignerInfo
    der_tlv(att_for_sign, 0x31, body.p, body.n);   // для вычисления подписи
    int bad = body.bad | att_implicit->bad | att_for_sign->bad | a0.bad | a1.bad | a2.bad | a3.bad;
    free(body.p); free(a0.p); free(a1.p); free(a2.p); free(a3.p);
    return !bad;
}

// Построить CMS SignedData (ContentInfo) для primary CodeDirectory cd[cdlen].
static uint8_t *build_cms(const uint8_t *cd, size_t cdlen, const gx_sign_opts *o, size_t *outlen) {
    uint8_t cdhash[32]; gx_sha256_buf(cd, cdlen, cdhash);
    buf att_i = {0}, att_s = {0};
    if (!build_signed_attrs(&att_i, &att_s, cdhash)) { free(att_i.p); free(att_s.p); return NULL; }

    // подпись приватным ключом поверх att_s (DER с тегом SET)
    size_t siglen = o->sig_size ? o->sig_size + 64 : 1024;
    uint8_t *sig = malloc(siglen);
    if (!o->sign(o->sign_ctx, att_s.p, att_s.n, sig, &siglen)) { free(sig); free(att_i.p); free(att_s.p); return NULL; }

    // SignerInfo
    const uint8_t *iss, *ser; size_t issl, serl;
    if (!cert_issuer_serial(o->certs[0], o->cert_lens[0], &iss, &issl, &ser, &serl)) { free(sig); free(att_i.p); free(att_s.p); return NULL; }
    buf si = {0};
    der_tlv(&si, 0x02, (const uint8_t[]){1}, 1);                 // version 1
    { buf ias = {0}; bput(&ias, iss, issl); bput(&ias, ser, serl); der_wrap(&si, 0x30, &ias); free(ias.p); }  // IssuerAndSerialNumber
    alg_sha256(&si);                                            // digestAlgorithm
    bput(&si, att_i.p, att_i.n);                                // signedAttrs [0]
    alg_rsa(&si);                                               // signatureAlgorithm
    der_tlv(&si, 0x04, sig, siglen);                           // signature OCTET STRING
    free(sig);

    // SignedData
    buf sd = {0};
    der_tlv(&sd, 0x02, (const uint8_t[]){1}, 1);                 // version 1
    { buf set = {0}; alg_sha256(&set); der_wrap(&sd, 0x31, &set); free(set.p); }   // digestAlgorithms
    { buf eci = {0}; der_oid(&eci, OID_data, sizeof OID_data); der_wrap(&sd, 0x30, &eci); free(eci.p); }   // encapContentInfo (detached)
    { buf certs = {0}; for (int i = 0; i < o->ncerts; i++) bput(&certs, o->certs[i], o->cert_lens[i]); der_tlv(&sd, 0xA0, certs.p, certs.n); free(certs.p); }  // certificates [0]
    { buf sis = {0}; der_wrap(&sis, 0x30, &si); der_wrap(&sd, 0x31, &sis); free(sis.p); }   // signerInfos SET { SignerInfo }
    free(si.p);

    // ContentInfo { signedData, [0] SignedData }
    buf ci = {0};
    der_oid(&ci, OID_signedData, sizeof OID_signedData);
    { buf exp = {0}; der_wrap(&exp, 0x30, &sd); der_wrap(&ci, 0xA0, &exp); free(exp.p); }
    free(sd.p);
    buf top = {0}; der_wrap(&top, 0x30, &ci); free(ci.p);
    free(att_i.p); free(att_s.p);
    if (top.bad) { free(top.p); return NULL; }
    *outlen = top.n;
    return top.p;
}

// ---------- CodeDirectory + Requirements ----------
// Пустой Requirements-блоб (0xfade0c01, count 0) — 12 байт.
static void make_requirements(uint8_t out[12]) { WB32(out, 0xFADE0C01); WB32(out + 4, 12); WB32(out + 8, 0); }

// Построить CodeDirectory. Возвращает malloc-буфер и длину.
// special[i] — хеш спецслота -(i+1): -1 Info.plist, -2 Requirements, -3 CodeResources,
// -4 (нет), -5 Entitlements, -6 (нет), -7 DER Entitlements. NULL — пустой слот (нули).
// Хвост пустых слотов отбрасывается, как это делает codesign/zsign.
static uint8_t *make_cd(const uint8_t *file, uint32_t codelimit, const char *ident, const char *teamid,
                        const uint8_t *const special[7],
                        uint64_t execBase, uint64_t execLimit, uint64_t execFlags, size_t *outlen) {
    uint32_t nslots = (codelimit + 4095) / 4096;
    size_t idl = strlen(ident) + 1, tml = teamid && *teamid ? strlen(teamid) + 1 : 0;
    int nspecial = 0;
    for (int i = 0; i < 7; i++) if (special[i]) nspecial = i + 1;
    size_t identOffset = 88;
    size_t teamOffset = tml ? identOffset + idl : 0;
    size_t after = identOffset + idl + tml;
    size_t hashOffset = after + (size_t)nspecial * 32;
    size_t cdlen = hashOffset + (size_t)nslots * 32;
    uint8_t *cd = calloc(1, cdlen);
    if (!cd) return NULL;
    WB32(cd, 0xFADE0C02); WB32(cd + 4, (uint32_t)cdlen); WB32(cd + 8, 0x20400); WB32(cd + 12, 0);  // flags=0 (НЕ ad-hoc)
    WB32(cd + 16, (uint32_t)hashOffset); WB32(cd + 20, (uint32_t)identOffset);
    WB32(cd + 24, (uint32_t)nspecial); WB32(cd + 28, nslots);
    WB32(cd + 32, codelimit); cd[36] = 32; cd[37] = 2; cd[38] = 0; cd[39] = 12;
    if (tml) WB32(cd + 48, (uint32_t)teamOffset);     // teamOffset (version >= 0x20200)
    // execSegment (version 0x20400): покрывает __TEXT. Без этого AMFI отвергает подпись
    // («code signature invalid»), т.к. исполняемый регион вне подписанного exec-сегмента.
    WB64(cd + 64, execBase);                           // execSegBase  (fileoff __TEXT)
    WB64(cd + 72, execLimit);                          // execSegLimit (filesize __TEXT)
    WB64(cd + 80, execFlags);                          // execSegFlags: 0 для dylib, MAIN_BINARY для приложения
    memcpy(cd + identOffset, ident, idl);
    if (tml) memcpy(cd + teamOffset, teamid, tml);
    for (int i = 0; i < nspecial; i++)
        if (special[i]) memcpy(cd + hashOffset - (size_t)(i + 1) * 32, special[i], 32);   // слот -(i+1)
    uint8_t *hs = cd + hashOffset;
    for (uint32_t i = 0; i < nslots; i++) {
        uint32_t a = i * 4096, l = codelimit - a < 4096 ? codelimit - a : 4096;
        gx_sha256_buf(file + a, l, hs + (size_t)i * 32);
    }
    *outlen = cdlen;
    return cd;
}

// Собрать полный SuperBlob подписи: CodeDirectory, Requirements, Entitlements (XML, слот 5),
// DER Entitlements (слот 7) и CMS в BlobWrapper (слот 0x10000). Блобы ent/der — уже с заголовком.
static uint8_t *make_superblob(const uint8_t *cd, size_t cdlen, const uint8_t *req, size_t reqlen,
                               const uint8_t *ent, size_t entlen, const uint8_t *der, size_t derlen,
                               const uint8_t *cms, size_t cmslen, size_t *outlen) {
    int nblobs = 1 + (req ? 1 : 0) + (ent ? 1 : 0) + (der ? 1 : 0) + (cms ? 1 : 0);
    size_t hdr = 12 + (size_t)nblobs * 8;
    size_t cms_wrapped = cms ? cmslen + 8 : 0;                                   // CMS внутри BlobWrapper (magic + len)
    size_t total = hdr + cdlen + (req ? reqlen : 0) + (ent ? entlen : 0) + (der ? derlen : 0) + cms_wrapped;
    uint8_t *sb = calloc(1, total);
    if (!sb) return NULL;
    WB32(sb, 0xFADE0CC0); WB32(sb + 4, (uint32_t)total); WB32(sb + 8, (uint32_t)nblobs);
    size_t idx = 12, cur = hdr;
    WB32(sb + idx, 0); WB32(sb + idx + 4, (uint32_t)cur); idx += 8;              // slot 0: CodeDirectory
    memcpy(sb + cur, cd, cdlen); cur += cdlen;
    if (req) { WB32(sb + idx, 2); WB32(sb + idx + 4, (uint32_t)cur); idx += 8; memcpy(sb + cur, req, reqlen); cur += reqlen; }   // slot 2: Requirements
    if (ent) { WB32(sb + idx, 5); WB32(sb + idx + 4, (uint32_t)cur); idx += 8; memcpy(sb + cur, ent, entlen); cur += entlen; }   // slot 5: Entitlements
    if (der) { WB32(sb + idx, 7); WB32(sb + idx + 4, (uint32_t)cur); idx += 8; memcpy(sb + cur, der, derlen); cur += derlen; }   // slot 7: DER Entitlements
    if (cms) {                                                                   // slot 0x10000: CMS в BlobWrapper
        WB32(sb + idx, 0x10000); WB32(sb + idx + 4, (uint32_t)cur); idx += 8;
        WB32(sb + cur, 0xFADE0B01); WB32(sb + cur + 4, (uint32_t)cms_wrapped);
        memcpy(sb + cur + 8, cms, cmslen); cur += cms_wrapped;
    }
    *outlen = total;
    return sb;
}

// Блоб с заголовком magic+len вокруг данных
static uint8_t *wrap_blob(uint32_t magic, const uint8_t *data, size_t n, size_t *outlen) {
    uint8_t *b = malloc(n + 8);
    if (!b) return NULL;
    WB32(b, magic); WB32(b + 4, (uint32_t)(n + 8)); memcpy(b + 8, data, n);
    *outlen = n + 8;
    return b;
}

// ---------- встраивание в тонкий Mach-O ----------
static uint8_t *sign_thin(const uint8_t *in, size_t len, const gx_sign_opts *o, size_t *outlen, char *err, size_t errlen) {
    if (len < 32 || LE32(in) != 0xFEEDFACF) { snprintf(err, errlen, GXT("не 64-битный Mach-O")); return NULL; }
    uint32_t ncmds = LE32(in + 16), szc = LE32(in + 20);
    if (32 + (size_t)szc > len) { snprintf(err, errlen, GXT("битые команды загрузки")); return NULL; }
    size_t sigcmd = 0, linkcmd = 0;
    uint64_t textoff = 0, textsize = 0;
    const uint8_t *p = in + 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        if ((size_t)(p - in) + 8 > 32 + (size_t)szc) break;
        uint32_t cmd = LE32(p), cs = LE32(p + 4);
        if (cs < 8 || (size_t)(p - in) + cs > 32 + (size_t)szc) break;
        if (cmd == 0x1D) sigcmd = (size_t)(p - in);
        if (cmd == 0x19 && !strncmp((const char *)p + 8, "__LINKEDIT", 16)) linkcmd = (size_t)(p - in);
        if (cmd == 0x19 && !strncmp((const char *)p + 8, "__TEXT", 16)) { textoff = LE64(p + 40); textsize = LE64(p + 48); }  // для execSegment
        p += cs;
    }
    if (!sigcmd || !linkcmd) { snprintf(err, errlen, GXT("нет LC_CODE_SIGNATURE/__LINKEDIT (нужен dylib из этого компилятора)")); return NULL; }

    // codeLimit — текущий конец файла, выровненный по 16; подпись добавляется после.
    size_t codelimit = (len + 15) & ~(size_t)15;
    uint32_t nslots = (uint32_t)((codelimit + 4095) / 4096);

    // Резервируем место под подпись: оцениваем сверху и дополняем нулями.
    size_t cdlen_est = 88 + strlen(o->ident) + 1 + (o->teamid && *o->teamid ? strlen(o->teamid) + 1 : 0) + 7 * 32 + (size_t)nslots * 32;
    size_t ent_est = (o->entitlements ? o->entitlements_len + 8 + 8 : 0) + (o->der_entitlements ? o->der_entitlements_len + 8 + 8 : 0);
    size_t certs_total = 0; for (int i = 0; i < o->ncerts; i++) certs_total += o->cert_lens[i];
    size_t cms_est = certs_total + o->sig_size + 2048;        // с запасом на ASN.1
    size_t reserve = 12 + 5 * 8 + cdlen_est + 12 + ent_est + cms_est;
    reserve = (reserve + 15) & ~(size_t)15;

    // Готовим файл: удлиняем до codelimit, фиксируем LC_CODE_SIGNATURE и __LINKEDIT, затем хешируем.
    size_t newlen = codelimit + reserve;
    uint8_t *f = calloc(1, newlen);
    if (!f) { snprintf(err, errlen, GXT("нет памяти")); return NULL; }
    memcpy(f, in, len);
    WLE32(f + sigcmd + 8, (uint32_t)codelimit);              // dataoff
    WLE32(f + sigcmd + 12, (uint32_t)reserve);               // datasize
    uint64_t lfo = LE64(f + linkcmd + 40);
    uint64_t lvs = LE64(f + linkcmd + 32);
    uint64_t newfs = codelimit + reserve - lfo;
    WLE64(f + linkcmd + 48, newfs);                          // __LINKEDIT filesize
    if (newfs > lvs) WLE64(f + linkcmd + 32, (newfs + 0x3FFF) & ~0x3FFFull);   // vmsize

    // Requirements
    uint8_t req[12]; make_requirements(req);
    uint8_t reqhash[32]; gx_sha256_buf(req, 12, reqhash);

    // Энтайтлменты (только у главного бинарника приложения)
    size_t entlen = 0, derlen = 0;
    uint8_t *ent = o->entitlements ? wrap_blob(0xFADE7171, o->entitlements, o->entitlements_len, &entlen) : NULL;
    uint8_t *der = o->der_entitlements ? wrap_blob(0xFADE7172, o->der_entitlements, o->der_entitlements_len, &derlen) : NULL;
    uint8_t enthash[32], derhash[32];
    if (ent) gx_sha256_buf(ent, entlen, enthash);
    if (der) gx_sha256_buf(der, derlen, derhash);
    const uint8_t *special[7] = { o->info_hash, reqhash, o->res_hash, NULL, ent ? enthash : NULL, NULL, der ? derhash : NULL };
    uint64_t execFlags = o->is_exec ? (0x1 /*CS_EXECSEG_MAIN_BINARY*/ | (o->allow_unsigned ? 0x10 /*CS_EXECSEG_ALLOW_UNSIGNED*/ : 0)) : 0;

    // CodeDirectory (хеши страниц уже по финальным командам загрузки)
    size_t cdlen = 0;
    uint8_t *cd = make_cd(f, (uint32_t)codelimit, o->ident, o->teamid ? o->teamid : "", special,
                          textoff, textsize, execFlags, &cdlen);
    if (!cd) { free(ent); free(der); free(f); snprintf(err, errlen, GXT("ошибка CodeDirectory")); return NULL; }

    // CMS
    size_t cmslen = 0;
    uint8_t *cms = build_cms(cd, cdlen, o, &cmslen);
    if (!cms) { free(cd); free(ent); free(der); free(f); snprintf(err, errlen, GXT("ошибка подписи/CMS (сертификат или ключ)")); return NULL; }

    // SuperBlob
    size_t sblen = 0;
    uint8_t *sb = make_superblob(cd, cdlen, req, 12, ent, entlen, der, derlen, cms, cmslen, &sblen);
    free(cd); free(cms); free(ent); free(der);
    if (!sb) { free(f); snprintf(err, errlen, GXT("ошибка сборки подписи")); return NULL; }
    if (sblen > reserve) { free(sb); free(f); snprintf(err, errlen, GXT("подпись больше зарезервированного места")); return NULL; }

    memcpy(f + codelimit, sb, sblen);                        // остаток зарезервированного места — нули
    free(sb);
    *outlen = newlen;
    return f;
}

uint8_t *gx_sign_macho(const uint8_t *d, size_t len, const gx_sign_opts *o, size_t *outlen, char *err, size_t errlen) {
    if (!o->ncerts || !o->certs || !o->sign) { snprintf(err, errlen, GXT("нет сертификата или колбэка подписи")); return NULL; }
    if (len >= 8 && RB32(d) == 0xCAFEBABE) {
        uint32_t n = RB32(d + 4);
        if (!n || n > 32 || 8 + (size_t)n * 20 > len) { snprintf(err, errlen, GXT("битый fat-заголовок")); return NULL; }
        uint8_t *parts[32] = {0}; size_t plen[32] = {0};
        for (uint32_t i = 0; i < n; i++) {
            const uint8_t *a = d + 8 + i * 20;
            size_t off = RB32(a + 8), s = RB32(a + 12);
            if (off > len || s > len - off) { snprintf(err, errlen, GXT("срез за пределами файла")); goto fail; }
            parts[i] = sign_thin(d + off, s, o, &plen[i], err, errlen);
            if (!parts[i]) goto fail;
        }
        size_t total = 8 + (size_t)n * 20, offs[32];
        for (uint32_t i = 0; i < n; i++) {
            uint32_t al = RB32(d + 8 + i * 20 + 16);
            size_t A = al < 20 ? (size_t)1 << al : 0x4000;
            total = (total + A - 1) & ~(A - 1); offs[i] = total; total += plen[i];
        }
        uint8_t *out = calloc(1, total);
        memcpy(out, d, 8 + (size_t)n * 20);
        for (uint32_t i = 0; i < n; i++) { WB32(out + 8 + i * 20 + 8, (uint32_t)offs[i]); WB32(out + 8 + i * 20 + 12, (uint32_t)plen[i]); memcpy(out + offs[i], parts[i], plen[i]); free(parts[i]); }
        *outlen = total;
        return out;
    fail:
        for (uint32_t i = 0; i < n; i++) free(parts[i]);
        return NULL;
    }
    return sign_thin(d, len, o, outlen, err, errlen);
}

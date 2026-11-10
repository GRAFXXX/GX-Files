// Свой разбор PKCS#12 (.p12/.pfx) — как у zsign/Feather, в обход SecPKCS12Import.
// SecPKCS12Import на iOS не читает современный формат OpenSSL 3 (PBES2: PBKDF2 +
// AES-256-CBC) и отдаёт errSecDecode (-26275). Здесь мы разбираем контейнер сами,
// а приватный RSA-ключ возвращаем в DER PKCS#1 — его принимает SecKeyCreateWithData,
// так что сама подпись дальше идёт через Security.framework (ключ не «голый» в коде).
#pragma once
#include <stdint.h>
#include <stddef.h>

enum { GXP12_OK = 0, GXP12_BADPW = 1, GXP12_UNSUPPORTED = 2, GXP12_PARSE = 3 };

typedef struct {
    uint8_t  *key_pkcs1;   // приватный RSA-ключ, DER RSAPrivateKey (PKCS#1) для SecKeyCreateWithData
    size_t    key_len;
    int       key_bits;    // размер модуля в битах (для kSecAttrKeySizeInBits)
    uint8_t **certs;       // DER-сертификаты, [0] — leaf (совпадает с ключом), далее цепочка
    size_t   *cert_lens;
    int       ncerts;
} gx_p12;

// Разобрать .p12 паролем password (UTF-8, может быть ""). 1 — успех (заполнен out),
// 0 — ошибка: *reason = GXP12_*, текст-подсказка (англ., для лога) в err.
int  gx_p12_parse(const uint8_t *p12, size_t n, const char *password,
                  gx_p12 *out, int *reason, char *err, size_t errlen);
void gx_p12_free(gx_p12 *o);

// --- криптопримитивы: их даёт бэкенд (CommonCrypto на устройстве, OpenSSL в тесте) ---
enum { GXP12_SHA1 = 1, GXP12_SHA224 = 224, GXP12_SHA256 = 256, GXP12_SHA384 = 384, GXP12_SHA512 = 512 };
enum { GXP12_C_3DES = 1, GXP12_C_AES = 2, GXP12_C_RC2 = 3 };

void gxp12_sha1(const uint8_t *d, size_t n, uint8_t out[20]);
// PBKDF2-HMAC(prf). 0 — успех.
int  gxp12_pbkdf2(int prf, const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen,
                  unsigned iters, uint8_t *out, size_t outlen);
// CBC-расшифровка со снятием PKCS#7-паддинга. *outlen: на входе — ёмкость, на выходе — длина.
// 0 — успех; -1 — ошибка/битый паддинг (обычно неверный пароль).
int  gxp12_cbc_decrypt(int alg, const uint8_t *key, size_t keylen, const uint8_t *iv,
                       const uint8_t *in, size_t inlen, uint8_t *out, size_t *outlen);

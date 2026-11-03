// Подпись APK схемами v1 (JAR) и v2 (APK Signature Scheme v2), RSA-2048 + SHA-256.
// Криптография RSA — через колбэк (на iOS — Security.framework), всё остальное — здесь.
#pragma once
#include <stdint.h>
#include <stddef.h>

// Подписать сообщение: SHA256withRSA (PKCS#1 v1.5). sig — буфер >= 512 байт. 1 = ок
typedef int (*gx_rsa_sign_fn)(void *ctx, const uint8_t *msg, size_t len, uint8_t *sig, size_t *siglen);

typedef struct {
    gx_rsa_sign_fn sign;
    void *ctx;
    const uint8_t *cert; size_t cert_len;      // X.509 DER
} gx_signer;

// Самоподписанный сертификат из открытого ключа RSA (PKCS#1 RSAPublicKey DER). Возвращает malloc DER.
uint8_t *gx_make_cert(const uint8_t *rsa_pub_pkcs1, size_t len, const char *cn, gx_rsa_sign_fn sign, void *ctx, size_t *out_len);

// in_path → out_path (подписанный). 1 = ок
int gx_apk_sign(const char *in_path, const char *out_path, const gx_signer *s, char *err, size_t errlen,
                volatile int *cancel, void (*progress)(double, void *), void *pctx);

// Есть ли у APK подпись v1/v2 (быстрая проверка наличия)
void gx_apk_sig_info(const char *path, int *v1, int *v2);

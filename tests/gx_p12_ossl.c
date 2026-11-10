// Крипто-бэкенд PKCS#12 на OpenSSL — ТОЛЬКО для host-теста (на устройстве — gx_p12_cc.c).
#include "core/gx_p12.h"
#include <openssl/sha.h>
#include <openssl/evp.h>
#include <openssl/provider.h>
#include <string.h>

// RC2/3DES-legacy в OpenSSL 3 лежат в legacy-провайдере (на устройстве их даёт CommonCrypto).
static void ensure_legacy(void) {
    static int done = 0; if (done) return; done = 1;
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");
}

void gxp12_sha1(const uint8_t *d, size_t n, uint8_t out[20]) { SHA1(d, n, out); }

int gxp12_pbkdf2(int prf, const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen,
                 unsigned iters, uint8_t *out, size_t outlen) {
    const EVP_MD *md;
    switch (prf) {
        case GXP12_SHA224: md = EVP_sha224(); break;
        case GXP12_SHA256: md = EVP_sha256(); break;
        case GXP12_SHA384: md = EVP_sha384(); break;
        case GXP12_SHA512: md = EVP_sha512(); break;
        default:           md = EVP_sha1();   break;
    }
    return PKCS5_PBKDF2_HMAC((const char *)pw, (int)pwlen, salt, (int)saltlen,
                            (int)iters, md, (int)outlen, out) == 1 ? 0 : -1;
}

int gxp12_cbc_decrypt(int alg, const uint8_t *key, size_t keylen, const uint8_t *iv,
                      const uint8_t *in, size_t inlen, uint8_t *out, size_t *outlen) {
    const EVP_CIPHER *c = NULL;
    if (alg == GXP12_C_RC2 || alg == GXP12_C_3DES) ensure_legacy();
    if (alg == GXP12_C_AES)  c = keylen == 16 ? EVP_aes_128_cbc() : keylen == 24 ? EVP_aes_192_cbc() : EVP_aes_256_cbc();
    else if (alg == GXP12_C_3DES) c = EVP_des_ede3_cbc();
    else if (alg == GXP12_C_RC2)  c = keylen == 5 ? EVP_rc2_40_cbc() : EVP_rc2_cbc();
    else return -1;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new(); if (!ctx) return -1;
    int rc = -1, ol = 0, fl = 0;
    if (EVP_DecryptInit_ex(ctx, c, NULL, NULL, NULL) != 1) goto done;
    if (alg == GXP12_C_RC2 && keylen != 5) {
        if (EVP_CIPHER_CTX_set_key_length(ctx, (int)keylen) != 1) goto done;
        EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_SET_RC2_KEY_BITS, (int)(keylen * 8), NULL);
    }
    if (EVP_DecryptInit_ex(ctx, NULL, NULL, key, iv) != 1) goto done;
    if (EVP_DecryptUpdate(ctx, out, &ol, in, (int)inlen) != 1) goto done;
    if (EVP_DecryptFinal_ex(ctx, out + ol, &fl) != 1) goto done;   // проверяет PKCS#7-паддинг
    *outlen = (size_t)(ol + fl); rc = 0;
done:
    EVP_CIPHER_CTX_free(ctx);
    return rc;
}

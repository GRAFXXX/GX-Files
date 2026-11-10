// Крипто-бэкенд PKCS#12 на CommonCrypto (iOS/macOS). Парность — tests/gx_p12_ossl.c.
#include "gx_p12.h"
#include <CommonCrypto/CommonCrypto.h>
#include <string.h>

void gxp12_sha1(const uint8_t *d, size_t n, uint8_t out[20]) {
    CC_SHA1(d, (CC_LONG)n, out);
}

int gxp12_pbkdf2(int prf, const uint8_t *pw, size_t pwlen, const uint8_t *salt, size_t saltlen,
                 unsigned iters, uint8_t *out, size_t outlen) {
    CCPseudoRandomAlgorithm a;
    switch (prf) {
        case GXP12_SHA224: a = kCCPRFHmacAlgSHA224; break;
        case GXP12_SHA256: a = kCCPRFHmacAlgSHA256; break;
        case GXP12_SHA384: a = kCCPRFHmacAlgSHA384; break;
        case GXP12_SHA512: a = kCCPRFHmacAlgSHA512; break;
        default:           a = kCCPRFHmacAlgSHA1;   break;
    }
    return CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)pw, pwlen, salt, saltlen,
                               a, iters, out, outlen) == kCCSuccess ? 0 : -1;
}

int gxp12_cbc_decrypt(int alg, const uint8_t *key, size_t keylen, const uint8_t *iv,
                      const uint8_t *in, size_t inlen, uint8_t *out, size_t *outlen) {
    CCAlgorithm a;
    if      (alg == GXP12_C_AES)  a = kCCAlgorithmAES;
    else if (alg == GXP12_C_3DES) a = kCCAlgorithm3DES;
    else if (alg == GXP12_C_RC2)  a = kCCAlgorithmRC2;
    else return -1;
    size_t moved = 0;
    CCCryptorStatus s = CCCrypt(kCCDecrypt, a, kCCOptionPKCS7Padding,
                                key, keylen, iv, in, inlen, out, *outlen, &moved);
    if (s != kCCSuccess) return -1;   // в т.ч. битый паддинг → неверный пароль
    *outlen = moved;
    return 0;
}

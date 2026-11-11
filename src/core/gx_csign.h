// Подпись Mach-O (dylib) настоящим сертификатом: CodeDirectory + Requirements + CMS.
// Вся сборка подписи — здесь (чистый C, тестируется на хосте). Приватный ключ не трогаем:
// RSA-подпись даёт колбэк (на устройстве — SecKeyCreateSignature из Security.framework).
#pragma once
#include <stdint.h>
#include <stddef.h>

// Подписать SHA-256 → RSA PKCS#1 v1.5 поверх data[n]. Записать подпись в sig (ёмкость *siglen),
// обновить *siglen. Вернуть 1 при успехе. Колбэк предоставляет вызывающий (ObjC).
typedef int (*gx_rsa_sign_fn)(void *ctx, const uint8_t *data, size_t n, uint8_t *sig, size_t *siglen);

typedef struct {
    const char *ident;              // идентификатор (как CFBundleIdentifier)
    const char *teamid;             // Team ID из сертификата (напр. "ABCDE12345"); может быть ""
    const uint8_t **certs;          // DER-сертификаты: [0] — подписант (leaf), далее промежуточные
    const size_t *cert_lens;
    int ncerts;
    const uint8_t *entitlements;    // XML энтайтлментов или NULL (для dylib обычно NULL)
    size_t entitlements_len;
    const uint8_t *der_entitlements;   // те же энтайтлменты в DER (iOS 15+), без заголовка блоба; или NULL
    size_t der_entitlements_len;
    const uint8_t *info_hash;       // SHA-256 Info.plist (32 байта) — для главного бинарника приложения; или NULL
    const uint8_t *res_hash;        // SHA-256 _CodeSignature/CodeResources (32 байта); или NULL
    int is_exec;                    // главный исполняемый файл (MH_EXECUTE): execSegFlags MAIN_BINARY
    int allow_unsigned;             // get-task-allow = true (development-профиль): execSegFlags ALLOW_UNSIGNED
    size_t sig_size;                // размер RSA-подписи в байтах (= размер ключа, напр. 256 для RSA-2048)
    gx_rsa_sign_fn sign;
    void *sign_ctx;
} gx_sign_opts;

// Подписать тонкий или fat Mach-O. Возвращает malloc-буфер (*outlen) или NULL + текст в err.
uint8_t *gx_sign_macho(const uint8_t *d, size_t len, const gx_sign_opts *o, size_t *outlen, char *err, size_t errlen);

// Из DER-сертификата вытащить OU subject (Team ID), CN (имя) и notAfter (unix-время, 0 если не найдено).
// team/cn — буферы вызывающего; любой из указателей может быть NULL. Возвращает 1 при успешном разборе.
int gx_cert_fields(const uint8_t *cert, size_t n, char *team, size_t tsz, char *cn, size_t csz, int64_t *not_after);

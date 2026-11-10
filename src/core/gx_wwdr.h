// Встроенные промежуточные сертификаты Apple WWDR и подбор нужного по издателю leaf.
// Без них amfid не строит цепочку leaf -> WWDR -> Apple Root и подпись считается невалидной.
#pragma once
#include <stdint.h>
#include <stddef.h>

// DER поля Name из сертификата. which: 0 = issuer, 1 = subject.
// Возвращает 1 и заполняет *p/*len (указатели внутрь cert, полный TLV).
int gx_cert_name(const uint8_t *cert, size_t n, int which, const uint8_t **p, size_t *len);

// Промежуточный WWDR, чей subject == issuer_der (DER Name издателя leaf). NULL, если нет.
const uint8_t *gx_wwdr_for_issuer(const uint8_t *issuer_der, size_t issuer_len, size_t *out_len);

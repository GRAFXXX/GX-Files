#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct { uint32_t h[8]; uint64_t len; uint8_t buf[64]; size_t n; } gx_sha256;
void gx_sha256_init(gx_sha256 *c);
void gx_sha256_update(gx_sha256 *c, const void *data, size_t len);
void gx_sha256_final(gx_sha256 *c, uint8_t out[32]);
void gx_sha256_buf(const void *data, size_t len, uint8_t out[32]);
size_t gx_base64(const uint8_t *in, size_t n, char *out); // out >= 4*((n+2)/3)+1

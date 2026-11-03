// Лёгкий ZIP-ридер с произвольным доступом (ZIP64, stored/deflate), умеет «zip внутри zip» через смещение.
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    char *name;          // сырые байты имени (обычно UTF-8), с завершающим 0
    uint16_t name_len;
    uint16_t method;     // 0 stored, 8 deflate
    uint16_t flags;      // bit0 — зашифрован, bit11 — UTF-8
    uint32_t crc;
    uint32_t dostime;
    uint32_t ext_attr;
    uint16_t ver_made, int_attr;
    uint64_t csize, usize, local_off;
} gxz_entry;

typedef struct {
    int fd;
    int own_fd;
    uint64_t base, size;   // окно внутри файла
    gxz_entry *e;
    size_t n;
    char err[160];
} gxz;

int  gxz_open(gxz *z, const char *path, uint64_t base, uint64_t size); // size=0 → до конца файла. 1 = ок
void gxz_close(gxz *z);
long gxz_find(const gxz *z, const char *name);              // -1 если нет
int  gxz_data_offset(gxz *z, const gxz_entry *e, uint64_t *abs_off); // абсолютное смещение данных в файле
// Читает запись в память (malloc). limit — максимум несжатых байт. 1 = ок
int  gxz_read(gxz *z, const gxz_entry *e, size_t limit, uint8_t **out, size_t *outlen);
// Распаковывает запись в открытый fd. progress может быть NULL. 1 = ок
int  gxz_extract_fd(gxz *z, const gxz_entry *e, int outfd, volatile int *cancel);
// Потоковое чтение распакованных данных записи в sink. 1 = ок
int  gxz_stream(gxz *z, const gxz_entry *e, int (*sink)(void *ctx, const uint8_t *p, size_t n), void *ctx, volatile int *cancel);
// Найти конец записей (начало центрального каталога) и EOCD. 1 = ок
int  gxz_layout(gxz *z, uint64_t *cd_off, uint64_t *cd_size, uint64_t *eocd_off, int *zip64);

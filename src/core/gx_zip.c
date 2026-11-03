#include "gx_tr.h"
#include "gx_zip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <zlib.h>

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32; }

static int rd(gxz *z, uint64_t off, void *buf, size_t len) {
    if (off + len > z->size) return 0;
    size_t got = 0;
    while (got < len) {
        ssize_t r = pread(z->fd, (char *)buf + got, len - got, (off_t)(z->base + off + got));
        if (r <= 0) return 0;
        got += (size_t)r;
    }
    return 1;
}

void gxz_close(gxz *z) {
    if (!z) return;
    for (size_t i = 0; i < z->n; i++) free(z->e[i].name);
    free(z->e);
    z->e = NULL; z->n = 0;
    if (z->own_fd && z->fd >= 0) close(z->fd);
    z->fd = -1;
}

int gxz_open(gxz *z, const char *path, uint64_t base, uint64_t size) {
    memset(z, 0, sizeof(*z));
    z->fd = open(path, O_RDONLY);
    if (z->fd < 0) { snprintf(z->err, sizeof z->err, GXT("не открыть файл")); return 0; }
    z->own_fd = 1;
    struct stat st;
    fstat(z->fd, &st);
    z->base = base;
    z->size = size ? size : (uint64_t)st.st_size - base;
    if (z->size < 22) { snprintf(z->err, sizeof z->err, GXT("слишком мал для zip")); gxz_close(z); return 0; }

    uint64_t tail = z->size < 70000 ? z->size : 70000;
    uint8_t *b = malloc(tail);
    if (!b || !rd(z, z->size - tail, b, tail)) { free(b); snprintf(z->err, sizeof z->err, GXT("ошибка чтения")); gxz_close(z); return 0; }
    long e = (long)tail - 22;
    while (e >= 0 && !(b[e] == 'P' && b[e + 1] == 'K' && b[e + 2] == 5 && b[e + 3] == 6)) e--;
    if (e < 0) { free(b); snprintf(z->err, sizeof z->err, GXT("не zip-архив")); gxz_close(z); return 0; }
    uint64_t count = le16(b + e + 10), dsize = le32(b + e + 12), doff = le32(b + e + 16);
    // Смещение может быть сдвинуто, если перед zip есть данные (самораспаковывающиеся архивы)
    uint64_t eocd_pos = z->size - tail + (uint64_t)e;
    if (count == 0xffff || dsize == 0xffffffffu || doff == 0xffffffffu) {
        if (e >= 20 && le32(b + e - 20) == 0x07064b50) {
            uint64_t r64 = le64(b + e - 20 + 8);
            uint8_t rec[56];
            if (rd(z, r64, rec, 56) && le32(rec) == 0x06064b50) {
                count = le64(rec + 32); dsize = le64(rec + 40); doff = le64(rec + 48);
            }
        }
    }
    free(b);
    int64_t shift = 0;
    if (doff + dsize < eocd_pos) shift = (int64_t)(eocd_pos - (doff + dsize));
    if (doff + dsize > z->size || dsize > (512u << 20)) { snprintf(z->err, sizeof z->err, GXT("повреждённый каталог zip")); gxz_close(z); return 0; }
    uint8_t *cd = malloc(dsize ? dsize : 4);
    int have = cd && rd(z, doff, cd, dsize) && (dsize == 0 || le32(cd) == 0x02014b50);
    if (have) shift = 0;
    else if (cd && shift && rd(z, doff + (uint64_t)shift, cd, dsize) && le32(cd) == 0x02014b50) have = 1;
    if (!have) { free(cd); snprintf(z->err, sizeof z->err, GXT("не прочитать каталог zip")); gxz_close(z); return 0; }
    if (count > 2000000) count = 2000000;
    z->e = calloc(count ? count : 1, sizeof(gxz_entry));
    size_t p = 0;
    for (uint64_t i = 0; i < count; i++) {
        if (p + 46 > dsize || le32(cd + p) != 0x02014b50) break;
        gxz_entry *en = &z->e[z->n];
        en->flags = le16(cd + p + 8);
        en->method = le16(cd + p + 10);
        en->dostime = le32(cd + p + 12);
        en->crc = le32(cd + p + 16);
        en->csize = le32(cd + p + 20);
        en->usize = le32(cd + p + 24);
        uint16_t nl = le16(cd + p + 28), xl = le16(cd + p + 30), cl = le16(cd + p + 32);
        en->ext_attr = le32(cd + p + 38);
        en->ver_made = le16(cd + p + 4);
        en->int_attr = le16(cd + p + 36);
        en->local_off = le32(cd + p + 42);
        if (p + 46 + nl + xl > dsize) break;
        en->name = malloc(nl + 1);
        memcpy(en->name, cd + p + 46, nl);
        en->name[nl] = 0;
        en->name_len = nl;
        size_t x = p + 46 + nl, xe = x + xl;
        while (x + 4 <= xe) {
            uint16_t id = le16(cd + x), len = le16(cd + x + 2);
            if (id == 1) {
                size_t q = x + 4, qe = x + 4 + len;
                if (en->usize == 0xffffffffu && q + 8 <= qe) { en->usize = le64(cd + q); q += 8; }
                if (en->csize == 0xffffffffu && q + 8 <= qe) { en->csize = le64(cd + q); q += 8; }
                if (en->local_off == 0xffffffffu && q + 8 <= qe) { en->local_off = le64(cd + q); }
            }
            x += 4 + len;
        }
        en->local_off += (uint64_t)shift;
        z->n++;
        p += 46 + nl + xl + cl;
    }
    free(cd);
    return 1;
}

long gxz_find(const gxz *z, const char *name) {
    for (size_t i = 0; i < z->n; i++) if (!strcmp(z->e[i].name, name)) return (long)i;
    return -1;
}

int gxz_data_offset(gxz *z, const gxz_entry *e, uint64_t *abs_off) {
    uint8_t lh[30];
    if (!rd(z, e->local_off, lh, 30) || le32(lh) != 0x04034b50) { snprintf(z->err, sizeof z->err, GXT("плохой локальный заголовок")); return 0; }
    uint64_t off = e->local_off + 30 + le16(lh + 26) + le16(lh + 28);
    if (off + e->csize > z->size) { snprintf(z->err, sizeof z->err, GXT("запись выходит за файл")); return 0; }
    *abs_off = z->base + off;
    return 1;
}

typedef int (*sink_fn)(void *ctx, const uint8_t *p, size_t n);

static int stream_entry(gxz *z, const gxz_entry *e, sink_fn sink, void *ctx, volatile int *cancel) {
    if (e->flags & 1) { snprintf(z->err, sizeof z->err, GXT("запись зашифрована")); return 0; }
    if (e->method != 0 && e->method != 8) { snprintf(z->err, sizeof z->err, GXT("метод сжатия %u не поддерживается"), e->method); return 0; }
    uint64_t abs;
    if (!gxz_data_offset(z, e, &abs)) return 0;
    uint64_t off = abs - z->base, left = e->csize;
    const size_t CH = 1 << 20;
    uint8_t *in = malloc(CH), *out = e->method == 8 ? malloc(CH) : NULL;
    z_stream s;
    memset(&s, 0, sizeof s);
    if (e->method == 8 && inflateInit2(&s, -MAX_WBITS) != Z_OK) { free(in); free(out); return 0; }
    int ok = 1, done = 0;
    while (left > 0 && !done) {
        if (cancel && *cancel) { ok = 0; snprintf(z->err, sizeof z->err, GXT("отменено")); break; }
        size_t n = left < CH ? (size_t)left : CH;
        if (!rd(z, off, in, n)) { ok = 0; snprintf(z->err, sizeof z->err, GXT("ошибка чтения")); break; }
        off += n; left -= n;
        if (e->method == 0) { if (!sink(ctx, in, n)) { ok = 0; break; } continue; }
        s.next_in = in; s.avail_in = (uInt)n;
        do {
            s.next_out = out; s.avail_out = (uInt)CH;
            int r = inflate(&s, Z_NO_FLUSH);
            if (r != Z_OK && r != Z_STREAM_END && r != Z_BUF_ERROR) { ok = 0; snprintf(z->err, sizeof z->err, GXT("ошибка распаковки")); break; }
            size_t have = CH - s.avail_out;
            if (have && !sink(ctx, out, have)) { ok = 0; break; }
            if (r == Z_STREAM_END) { done = 1; break; }
            if (r == Z_BUF_ERROR && s.avail_in == 0) break;
        } while (s.avail_out == 0 || s.avail_in > 0);
        if (!ok) break;
    }
    if (e->method == 8) inflateEnd(&s);
    free(in); free(out);
    return ok;
}

typedef struct { uint8_t *buf; size_t len, cap, limit; int over; } membuf;
static int mem_sink(void *c, const uint8_t *p, size_t n) {
    membuf *m = c;
    if (m->len + n > m->limit) { m->over = 1; return 0; }
    if (m->len + n > m->cap) {
        size_t nc = m->cap ? m->cap * 2 : 65536;
        while (nc < m->len + n) nc *= 2;
        uint8_t *nb = realloc(m->buf, nc);
        if (!nb) return 0;
        m->buf = nb; m->cap = nc;
    }
    memcpy(m->buf + m->len, p, n);
    m->len += n;
    return 1;
}

int gxz_read(gxz *z, const gxz_entry *e, size_t limit, uint8_t **out, size_t *outlen) {
    if (e->usize > limit) { snprintf(z->err, sizeof z->err, GXT("запись слишком велика")); return 0; }
    membuf m = {0};
    m.limit = limit;
    m.cap = e->usize ? (size_t)e->usize + 1 : 65536;
    m.buf = malloc(m.cap);
    if (!m.buf) return 0;
    if (!stream_entry(z, e, mem_sink, &m, NULL)) { free(m.buf); if (m.over) snprintf(z->err, sizeof z->err, GXT("запись слишком велика")); return 0; }
    *out = m.buf; *outlen = m.len;
    return 1;
}

static int fd_sink(void *c, const uint8_t *p, size_t n) {
    int fd = *(int *)c;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return 0;
        p += w; n -= (size_t)w;
    }
    return 1;
}

int gxz_stream(gxz *z, const gxz_entry *e, int (*sink)(void *, const uint8_t *, size_t), void *ctx, volatile int *cancel) {
    return stream_entry(z, e, sink, ctx, cancel);
}

int gxz_extract_fd(gxz *z, const gxz_entry *e, int outfd, volatile int *cancel) {
    return stream_entry(z, e, fd_sink, &outfd, cancel);
}

int gxz_layout(gxz *z, uint64_t *cd_off, uint64_t *cd_size, uint64_t *eocd_off, int *zip64) {
    uint64_t tail = z->size < 70000 ? z->size : 70000;
    uint8_t *b = malloc(tail);
    if (!b || !rd(z, z->size - tail, b, tail)) { free(b); return 0; }
    long e = (long)tail - 22;
    while (e >= 0 && !(b[e] == 'P' && b[e + 1] == 'K' && b[e + 2] == 5 && b[e + 3] == 6)) e--;
    if (e < 0) { free(b); return 0; }
    *eocd_off = z->size - tail + (uint64_t)e;
    *cd_size = le32(b + e + 12);
    *cd_off = le32(b + e + 16);
    *zip64 = 0;
    if (e >= 20 && le32(b + e - 20) == 0x07064b50) {
        *zip64 = 1;
        uint8_t rec[56];
        if (rd(z, le64(b + e - 20 + 8), rec, 56) && le32(rec) == 0x06064b50) { *cd_size = le64(rec + 40); *cd_off = le64(rec + 48); }
    }
    free(b);
    return 1;
}

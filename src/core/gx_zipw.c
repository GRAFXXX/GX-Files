#include "gx_tr.h"
#include "gx_zipw.h"
#include "gx_zip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <zlib.h>

typedef struct {
    char *name; uint16_t nlen;
    uint16_t flags, method, ver_made, int_attr;
    uint32_t crc, dostime, ext_attr;
    uint64_t csize, usize, off;
} cd_rec;

typedef struct {
    int fd;
    uint64_t pos;
    int failed;
    cd_rec *cd; size_t ncd, capcd;
    uint8_t *buf;
} wctx;

static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }
static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)v); put32(p + 4, (uint32_t)(v >> 32)); }

static void wr(wctx *w, const void *d, size_t n) {
    if (w->failed) return;
    const uint8_t *p = d;
    while (n) {
        ssize_t r = pwrite(w->fd, p, n, (off_t)w->pos);
        if (r <= 0) { w->failed = 1; return; }
        p += r; n -= (size_t)r; w->pos += (uint64_t)r;
    }
}

static int ends(const char *s, const char *suf) { size_t a = strlen(s), b = strlen(suf); return a >= b && !strcasecmp(s + a - b, suf); }

static int prefer_stored(const char *name) {
    static const char *ex[] = {".so", ".arsc", ".png", ".jpg", ".jpeg", ".webp", ".gif", ".mp3", ".ogg", ".m4a", ".mp4", ".zip", ".apk", ".jar",
                               ".gz", ".xz", ".7z", ".obb", ".unity3d", ".bundle", ".car", NULL};
    for (int i = 0; ex[i]; i++) if (ends(name, ex[i])) return 1;
    return 0;
}

static uint32_t dos_now(void) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    return (uint32_t)((tm.tm_year - 80) << 25 | (tm.tm_mon + 1) << 21 | tm.tm_mday << 16 | tm.tm_hour << 11 | tm.tm_min << 5 | tm.tm_sec / 2);
}

// Локальный заголовок; data начинается сразу после него. Возвращает смещение заголовка.
static uint64_t write_local(wctx *w, cd_rec *r, int align, int zip64) {
    uint64_t hoff = w->pos;
    size_t extra = zip64 ? 20 : 0;
    size_t A = 0;
    if (align == GXZW_ALIGN_APK && r->method == 0) A = ends(r->name, ".so") ? 16384 : 4;
    size_t pad = 0;
    if (A) {
        uint64_t start = hoff + 30 + r->nlen + extra + 6;
        pad = (A - start % A) % A;
        extra += 6 + pad;
    }
    uint8_t h[30];
    put32(h, 0x04034b50);
    put16(h + 4, zip64 ? 45 : (r->method == 8 ? 20 : 10));
    put16(h + 6, r->flags & ~0x8);
    put16(h + 8, r->method);
    put32(h + 10, r->dostime);
    put32(h + 14, r->crc);
    put32(h + 18, zip64 ? 0xFFFFFFFFu : (uint32_t)r->csize);
    put32(h + 22, zip64 ? 0xFFFFFFFFu : (uint32_t)r->usize);
    put16(h + 26, r->nlen);
    put16(h + 28, (uint16_t)extra);
    wr(w, h, 30);
    wr(w, r->name, r->nlen);
    if (zip64) {
        uint8_t x[20];
        put16(x, 1); put16(x + 2, 16); put64(x + 4, r->usize); put64(x + 12, r->csize);
        wr(w, x, 20);
    }
    if (A) {
        uint8_t x[6 + 16384];
        memset(x, 0, 6 + pad);
        put16(x, 0xD935); put16(x + 2, (uint16_t)(2 + pad)); put16(x + 4, (uint16_t)A);
        wr(w, x, 6 + pad);
    }
    return hoff;
}

static void add_cd(wctx *w, cd_rec *r) {
    if (w->ncd == w->capcd) { w->capcd = w->capcd ? w->capcd * 2 : 256; w->cd = realloc(w->cd, w->capcd * sizeof(cd_rec)); }
    w->cd[w->ncd++] = *r;
}

// Сжатие/копирование источника в архив. Возвращает 1 при успехе.
static int write_new(wctx *w, cd_rec *r, int fd_in, const uint8_t *mem, size_t memlen, int align, char *err, size_t errlen) {
    uint64_t total = 0;
    if (fd_in >= 0) { struct stat st; fstat(fd_in, &st); total = (uint64_t)st.st_size; } else total = memlen;
    int zip64 = total >= 0xFFFFFFF0ull;
    r->usize = total;
    r->csize = r->method == 0 ? total : 0;
    r->crc = 0;
    r->off = write_local(w, r, align, zip64);
    uint64_t data_start = w->pos;
    const size_t CH = 1 << 20;
    uint8_t *in = w->buf, *out = w->buf + CH;
    z_stream s;
    memset(&s, 0, sizeof s);
    if (r->method == 8 && deflateInit2(&s, 6, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) { snprintf(err, errlen, "zlib"); return 0; }
    uLong crc = crc32(0, NULL, 0);
    uint64_t done = 0;
    for (;;) {
        size_t n;
        if (fd_in >= 0) { ssize_t k = read(fd_in, in, CH); if (k < 0) { snprintf(err, errlen, GXT("ошибка чтения источника")); if (r->method == 8) deflateEnd(&s); return 0; } n = (size_t)k; }
        else { n = memlen - done < CH ? memlen - done : CH; if (n) memcpy(in, mem + done, n); }
        done += n;
        int last = n == 0 || done >= total;
        crc = crc32(crc, in, (uInt)n);
        if (r->method == 0) { wr(w, in, n); }
        else {
            s.next_in = in; s.avail_in = (uInt)n;
            int flush = last ? Z_FINISH : Z_NO_FLUSH;
            do {
                s.next_out = out; s.avail_out = (uInt)CH;
                deflate(&s, flush);
                wr(w, out, CH - s.avail_out);
            } while (s.avail_out == 0);
        }
        if (last) break;
    }
    if (r->method == 8) deflateEnd(&s);
    r->crc = (uint32_t)crc;
    r->csize = w->pos - data_start;
    if (zip64 != (r->csize >= 0xFFFFFFF0ull || r->usize >= 0xFFFFFFF0ull)) { snprintf(err, errlen, GXT("файл слишком велик")); return 0; }
    // дописываем crc и размеры в локальный заголовок
    uint8_t f[12];
    put32(f, r->crc);
    put32(f + 4, zip64 ? 0xFFFFFFFFu : (uint32_t)r->csize);
    put32(f + 8, zip64 ? 0xFFFFFFFFu : (uint32_t)r->usize);
    if (pwrite(w->fd, f, 12, (off_t)(r->off + 14)) != 12) w->failed = 1;
    if (zip64) { uint8_t x[16]; put64(x, r->usize); put64(x + 8, r->csize); if (pwrite(w->fd, x, 16, (off_t)(r->off + 30 + r->nlen + 4)) != 16) w->failed = 1; }
    return !w->failed;
}

static const gxzw_op *find_op(const gxzw_op *ops, size_t n, const char *name, char *used) {
    for (size_t i = 0; i < n; i++) if (!used[i] && ops[i].name && !strcmp(ops[i].name, name)) { used[i] = 1; return &ops[i]; }
    return NULL;
}

int gxzw_rewrite(const char *in_path, const char *out_path, const gxzw_op *ops, size_t nops, int align,
                 char *err, size_t errlen, volatile int *cancel, void (*progress)(double, void *), void *pctx) {
    gxz z;
    if (!gxz_open(&z, in_path, 0, 0)) { snprintf(err, errlen, "%s", z.err); return 0; }
    wctx w = {0};
    w.fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (w.fd < 0) { snprintf(err, errlen, GXT("не создать временный файл")); gxz_close(&z); return 0; }
    w.buf = malloc(2u << 20);
    char *used = calloc(nops ? nops : 1, 1);
    int ok = 1;
    uint64_t total = 1, done = 0;
    for (size_t i = 0; i < z.n; i++) total += z.e[i].csize;
    for (size_t i = 0; i < z.n && ok; i++) {
        if (cancel && *cancel) { snprintf(err, errlen, GXT("отменено")); ok = 0; break; }
        gxz_entry *e = &z.e[i];
        const gxzw_op *op = find_op(ops, nops, e->name, used);
        if (op && op->del) continue;
        cd_rec r = {0};
        const char *nm = op && op->new_name ? op->new_name : e->name;
        r.nlen = (uint16_t)strlen(nm);
        r.name = strdup(nm);
        r.flags = e->flags | (op && op->new_name ? 0x800 : 0);
        r.method = e->method;
        r.ver_made = e->ver_made;
        r.int_attr = e->int_attr;
        r.ext_attr = e->ext_attr;
        r.dostime = e->dostime;
        if (op && (op->src_path || op->src_data)) {
            r.flags &= ~(0x1 | 0x8 | 0x40);
            if (r.method != 0 && r.method != 8) r.method = 8;
            if (align == GXZW_ALIGN_APK && (ends(nm, "resources.arsc"))) r.method = 0;
            r.dostime = dos_now();
            int fd = op->src_path ? open(op->src_path, O_RDONLY) : -1;
            if (op->src_path && fd < 0) { snprintf(err, errlen, GXT("не открыть %s"), op->src_path); ok = 0; free(r.name); break; }
            ok = write_new(&w, &r, fd, op->src_data, op->src_len, align, err, errlen);
            if (fd >= 0) close(fd);
        } else {
            // как есть: сжатые данные копируются без изменений
            uint64_t abs;
            if (!gxz_data_offset(&z, e, &abs)) { snprintf(err, errlen, "%s: %s", e->name, z.err); ok = 0; free(r.name); break; }
            r.crc = e->crc; r.csize = e->csize; r.usize = e->usize;
            int zip64 = r.csize >= 0xFFFFFFF0ull || r.usize >= 0xFFFFFFF0ull;
            r.off = write_local(&w, &r, align, zip64);
            uint64_t left = e->csize, src = abs;
            while (left && !w.failed) {
                size_t n = left < (2u << 20) ? (size_t)left : (2u << 20);
                ssize_t k = pread(z.fd, w.buf, n, (off_t)src);
                if (k <= 0) { snprintf(err, errlen, GXT("ошибка чтения %s"), e->name); ok = 0; break; }
                wr(&w, w.buf, (size_t)k);
                left -= (uint64_t)k; src += (uint64_t)k;
            }
        }
        if (!ok) { free(r.name); break; }
        add_cd(&w, &r);
        done += e->csize;
        if (progress) progress((double)done / (double)total, pctx);
    }
    // новые записи
    for (size_t i = 0; i < nops && ok; i++) {
        if (used[i] || ops[i].del || !(ops[i].src_path || ops[i].src_data)) continue;
        const char *nm = ops[i].new_name ? ops[i].new_name : ops[i].name;
        cd_rec r = {0};
        r.name = strdup(nm);
        r.nlen = (uint16_t)strlen(nm);
        r.flags = 0x800;
        int dir = r.nlen && nm[r.nlen - 1] == '/';
        r.method = dir || prefer_stored(nm) ? 0 : 8;
        r.ver_made = 3 << 8 | 20;
        r.ext_attr = (uint32_t)(dir ? (040755u << 16) | 0x10u : (0100644u << 16));
        r.dostime = dos_now();
        int fd = ops[i].src_path && !dir ? open(ops[i].src_path, O_RDONLY) : -1;
        if (ops[i].src_path && !dir && fd < 0) { snprintf(err, errlen, GXT("не открыть %s"), ops[i].src_path); ok = 0; free(r.name); break; }
        ok = write_new(&w, &r, fd, dir ? (const uint8_t *)"" : ops[i].src_data, dir ? 0 : ops[i].src_len, align, err, errlen);
        if (fd >= 0) close(fd);
        if (ok) add_cd(&w, &r); else free(r.name);
    }
    // центральный каталог
    uint64_t cd_start = w.pos;
    int need64 = w.ncd >= 0xFFFF;
    for (size_t i = 0; i < w.ncd && ok; i++) {
        cd_rec *r = &w.cd[i];
        int z64 = r->csize >= 0xFFFFFFF0ull || r->usize >= 0xFFFFFFF0ull || r->off >= 0xFFFFFFF0ull;
        if (r->off >= 0xFFFFFFF0ull) need64 = 1;
        uint8_t h[46];
        put32(h, 0x02014b50);
        put16(h + 4, r->ver_made ? r->ver_made : 20);
        put16(h + 6, z64 ? 45 : (r->method == 8 ? 20 : 10));
        put16(h + 8, r->flags & ~0x8);
        put16(h + 10, r->method);
        put32(h + 12, r->dostime);
        put32(h + 16, r->crc);
        put32(h + 20, z64 ? 0xFFFFFFFFu : (uint32_t)r->csize);
        put32(h + 24, z64 ? 0xFFFFFFFFu : (uint32_t)r->usize);
        put16(h + 28, r->nlen);
        put16(h + 30, z64 ? 28 : 0);
        put16(h + 32, 0);
        put16(h + 34, 0);
        put16(h + 36, r->int_attr);
        put32(h + 38, r->ext_attr);
        put32(h + 42, z64 ? 0xFFFFFFFFu : (uint32_t)r->off);
        wr(&w, h, 46);
        wr(&w, r->name, r->nlen);
        if (z64) { uint8_t x[28]; put16(x, 1); put16(x + 2, 24); put64(x + 4, r->usize); put64(x + 12, r->csize); put64(x + 20, r->off); wr(&w, x, 28); }
    }
    uint64_t cd_size = w.pos - cd_start;
    if (cd_start >= 0xFFFFFFF0ull) need64 = 1;
    if (ok && need64) {
        uint64_t z64off = w.pos;
        uint8_t r64[56];
        put32(r64, 0x06064b50); put64(r64 + 4, 44); put16(r64 + 12, 45); put16(r64 + 14, 45);
        put32(r64 + 16, 0); put32(r64 + 20, 0); put64(r64 + 24, w.ncd); put64(r64 + 32, w.ncd); put64(r64 + 40, cd_size); put64(r64 + 48, cd_start);
        wr(&w, r64, 56);
        uint8_t loc[20];
        put32(loc, 0x07064b50); put32(loc + 4, 0); put64(loc + 8, z64off); put32(loc + 16, 1);
        wr(&w, loc, 20);
    }
    if (ok) {
        uint8_t e[22];
        put32(e, 0x06054b50); put16(e + 4, 0); put16(e + 6, 0);
        put16(e + 8, need64 ? 0xFFFF : (uint16_t)w.ncd); put16(e + 10, need64 ? 0xFFFF : (uint16_t)w.ncd);
        put32(e + 12, need64 ? 0xFFFFFFFFu : (uint32_t)cd_size); put32(e + 16, need64 ? 0xFFFFFFFFu : (uint32_t)cd_start);
        put16(e + 20, 0);
        wr(&w, e, 22);
    }
    if (w.failed && ok) { snprintf(err, errlen, GXT("ошибка записи (нет места?)")); ok = 0; }
    if (fsync(w.fd) != 0 && ok) { /* не критично */ }
    close(w.fd);
    for (size_t i = 0; i < w.ncd; i++) free(w.cd[i].name);
    free(w.cd); free(w.buf); free(used);
    gxz_close(&z);
    if (!ok) unlink(out_path);
    return ok;
}

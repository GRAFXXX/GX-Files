// Редактор бинарников: .dylib / Mach-O / .so — строки (в т.ч. русские), функции с дизассемблером ARM64,
// патчи инструкций и шаблоны, поиск и правка чисел, ссылки, ad-hoc переподпись при сохранении.
#import "GXCore.h"
#include "core/gx_bin.h"
#include "core/gx_a64.h"
#include "core/gx_objc.h"
#include "core/gx_pseudo.h"
#include "core/gx_asm.h"
#include "core/gx_img.h"
#include "core/gx_design.h"
#import <CoreText/CoreText.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>

extern char *__cxa_demangle(const char *mangled, char *buf, size_t *n, int *status);

static NSString *GXDemangle(const char *s, size_t len, int macho) {
    if (!s || !len) return nil;
    char tmp[1024];
    if (len >= sizeof tmp) len = sizeof tmp - 1;
    memcpy(tmp, s, len); tmp[len] = 0;
    const char *n = tmp;
    if (macho && n[0] == '_') n++;
    if (n[0] == '_' && n[1] == 'Z') {
        int st = 0;
        char *r = __cxa_demangle(n, NULL, NULL, &st);
        if (r && !st) { NSString *x = [NSString stringWithUTF8String:r]; free(r); if (x) return x; }
        free(r);
    }
    if (!strncmp(n, "$s", 2) || !strncmp(n, "_$s", 3) || !strncmp(n, "$S", 2)) {
        static char *(*sd)(const char *, size_t, char *, size_t *, uint32_t);
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            void *h = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY);
            sd = h ? dlsym(h, "swift_demangle") : NULL;
        });
        if (sd) { char *r = sd(n, strlen(n), NULL, NULL, 0); if (r) { NSString *x = [NSString stringWithUTF8String:r]; free(r); if (x) return x; } }
    }
    return [NSString stringWithUTF8String:n] ?: [[NSString alloc] initWithBytes:n length:strlen(n) encoding:NSISOLatin1StringEncoding];
}

static NSString *GXHex(uint64_t v) { return [NSString stringWithFormat:@"0x%llx", (unsigned long long)v]; }
static UIFont *GXMono(CGFloat s) { return [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightRegular]; }
static BOOL GXParseHex(NSString *s, uint64_t *out) {
    s = [[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
    if ([s hasPrefix:@"0x"]) s = [s substringFromIndex:2];
    if (!s.length || s.length > 16) return NO;
    NSScanner *sc = [NSScanner scannerWithString:s];
    unsigned long long v;
    if (![sc scanHexLongLong:&v] || !sc.isAtEnd) return NO;
    *out = v;
    return YES;
}

#pragma mark - Документ

@interface GXBinStr : NSObject
@property (nonatomic) size_t off;
@property (nonatomic) uint32_t blen;
@property (nonatomic) uint8_t enc, cf;
@property (nonatomic) int sect;
@property (nonatomic, copy) NSString *text;
@property (nonatomic) BOOL cyr, service;
@end
@implementation GXBinStr @end

@interface GXBinFunc : NSObject
@property (nonatomic) uint64_t addr, size;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL import;
@end
@implementation GXBinFunc @end

@interface GXBinDoc : NSObject {
@public
    gx_bin bin;
    gx_objc_cls *_cls; int _ncls;
    gx_pivar *_allIv; int _nAllIv;
}
@property (nonatomic) BOOL objcLoaded;
@property (nonatomic, strong, nullable) NSDictionary<NSNumber *, NSArray<NSNumber *> *> *impMap;   // адрес реализации → @[класс, метод]
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic) int slice, nslices;
@property (nonatomic, strong) NSArray<NSString *> *sliceNames;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *patches;   // off, old, new, desc
@property (nonatomic, strong, nullable) NSArray<GXBinStr *> *strings;
@property (nonatomic, strong, nullable) NSArray<GXBinFunc *> *funcs, *imports;
@property (nonatomic) BOOL resign;
@property (nonatomic, copy, nullable) NSString *lastNote;
@end

@implementation GXBinDoc

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = path.copy;
        _data = [NSMutableData dataWithContentsOfFile:path] ?: [NSMutableData data];
        _patches = [NSMutableArray array];
        _resign = YES;
        [self reopen];
    }
    return self;
}
- (void)freeObjC {
    @synchronized (self) {
        if (_cls) gx_objc_free(_cls, _ncls);
        free(_allIv);
        _cls = NULL; _ncls = 0; _allIv = NULL; _nAllIv = 0;
        _objcLoaded = NO; _impMap = nil;
    }
}
- (void)dealloc { [self freeObjC]; gx_bin_close(&bin); }

- (void)loadObjC {
    @synchronized (self) {
        if (_objcLoaded) return;
        gx_objc_dump(&bin, &_cls, &_ncls);
        int total = 0;
        for (int i = 0; i < _ncls; i++) total += _cls[i].niv;
        _allIv = calloc((size_t)(total ? total : 1), sizeof(gx_pivar));
        _nAllIv = 0;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (int i = 0; i < _ncls; i++) {
            for (int k = 0; k < _cls[i].niv; k++) _allIv[_nAllIv++] = (gx_pivar){_cls[i].iv[k].name, _cls[i].iv[k].slot, _cls[i].iv[k].off};
            for (int k = 0; k < _cls[i].nm; k++) if (_cls[i].m[k].imp) m[@(_cls[i].m[k].imp)] = @[@(i), @(k)];
        }
        _impMap = m;
        _objcLoaded = YES;
    }
}
- (int)nclasses { [self loadObjC]; return _ncls; }
- (NSString *)objcNameAt:(uint64_t)a {
    if (!_objcLoaded) return nil;
    NSArray *m = _impMap[@(a)];
    if (!m) return nil;
    return [NSString stringWithUTF8String:_cls[[m[0] intValue]].m[[m[1] intValue]].name];
}
static NSString *GXStr(const char *p) {
    if (!p) return @"";
    return [NSString stringWithUTF8String:p] ?: [NSString stringWithCString:p encoding:NSISOLatin1StringEncoding] ?: @"";
}
static const char *gxNamer(void *ctx, uint64_t a, char *buf, size_t n) {
    GXBinDoc *d = (__bridge GXBinDoc *)ctx;
    NSString *s = [d nameForAddr:a exactOnly:YES];
    if (!s) return NULL;
    strlcpy(buf, s.UTF8String ?: "", n);
    return buf;
}
- (NSString *)pseudoFor:(uint64_t)a {
    [self loadObjC];
    const gx_name *f = gx_bin_func_of(&bin, a);
    uint64_t start = f ? f->addr : (a & ~3ull), end = gx_bin_func_end(&bin, start);
    NSArray *m = _impMap[@(start)];
    int objc = 0, retkind = 0; gx_pivar *siv = NULL; int nsiv = 0;
    const char *proto = NULL;
    NSString *name;
    if (m) {
        gx_objc_cls *c = &_cls[[m[0] intValue]];
        gx_objc_m *mm = &c->m[[m[1] intValue]];
        name = GXStr(mm->name);
        proto = mm->proto; retkind = mm->retkind;
        objc = 1;
        // ivars класса (для категорий — ivars одноимённого класса, если он есть в этом файле)
        gx_objc_cls *src = c;
        if (c->is_cat) {
            const char *sp = strchr(c->name, ' ');
            size_t l = sp ? (size_t)(sp - c->name) : strlen(c->name);
            src = NULL;
            for (int i = 0; i < _ncls; i++) if (!_cls[i].is_cat && strlen(_cls[i].name) == l && !strncmp(_cls[i].name, c->name, l)) { src = &_cls[i]; break; }
        }
        if (src && src->niv) {
            siv = calloc((size_t)src->niv, sizeof(gx_pivar));
            for (int k = 0; k < src->niv; k++) siv[nsiv++] = (gx_pivar){src->iv[k].name, src->iv[k].slot, src->iv[k].off};
        }
    } else name = [self nameForAddr:start exactOnly:YES] ?: [NSString stringWithFormat:@"sub_%llx", (unsigned long long)start];
    char *p = gx_pseudo(&bin, start, end, name.UTF8String ?: "?", objc, proto, retkind, siv, nsiv, _allIv, _nAllIv, gxNamer, (__bridge void *)self);
    NSString *r = GXStr(p);
    free(p); free(siv);
    return r;
}
// Папка для восстановленного кода
+ (NSString *)decompDir {
    NSString *d = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"GX Compiler"] stringByAppendingPathComponent:@"Восстановленный код"]; // noi18n — имя папки не переводится
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
+ (NSString *)safeName:(NSString *)n {
    NSMutableString *r = [NSMutableString string];
    for (NSUInteger i = 0; i < n.length && r.length < 80; i++) {
        unichar c = [n characterAtIndex:i];
        [r appendString:(c == '/' || c == ':' || c == ' ' || c == '[' || c == ']' || c == '+' || c == '-' || c < 32) ? @"_" : [NSString stringWithCharacters:&c length:1]];
    }
    while ([r hasPrefix:@"_"]) [r deleteCharactersInRange:NSMakeRange(0, 1)];
    return r.length ? r : @"code";
}
static void gxw(FILE *f, NSString *s) { const char *u = s.UTF8String; if (u) fputs(u, f); }

// Восстановить приблизительный C-код: класс ci (или весь файл при ci < 0) → файл. nil — ошибка
- (NSString *)writeDecompiledClass:(int)ci progress:(void (^)(double))progress cancelled:(BOOL (^)(void))cancelled {
    [self loadObjC];
    NSString *base = ci >= 0 ? [GXBinDoc safeName:GXStr(_cls[ci].name)] : [[GXBinDoc safeName:_path.lastPathComponent.stringByDeletingPathExtension] stringByAppendingString:@"_decompiled"];
    NSString *dest = GXUniquePath([GXBinDoc decompDir], [base stringByAppendingPathExtension:ci >= 0 ? @"m" : @"c"]);
    FILE *f = fopen(dest.fileSystemRepresentation, "w");
    if (!f) return nil;
    gxw(f, [NSString stringWithFormat:GXL(@"/*\n * %@%@ — код, восстановленный GX Files из машинного кода ARM64.\n"
        " * Это ПРИБЛИЗИТЕЛЬНЫЙ псевдокод: по нему видно, что делает каждая функция,\n"
        " * но собрать его обратно как есть нельзя — имена переменных, типы и часть\n"
        " * конструкций потеряны при компиляции. Используй как основу для переписывания.\n */\n\n"),
        _path.lastPathComponent, ci >= 0 ? [NSString stringWithFormat:GXL(@", класс %@"), GXStr(_cls[ci].name)] : @""]);
    NSMutableSet *done = [NSMutableSet set];
    int from = ci >= 0 ? ci : 0, to = ci >= 0 ? ci + 1 : _ncls;
    size_t total = 0, cur = 0;
    for (int i = from; i < to; i++) total += (size_t)_cls[i].nm;
    if (ci < 0) total += bin.nfn;
    if (!total) total = 1;
    if (to > from) {
        gxw(f, GXL(@"/* ===== Классы Objective-C (заголовки) ===== */\n#if 0\n"));
        for (int i = from; i < to; i++) { gxw(f, GXStr(_cls[i].header)); gxw(f, @"\n"); }
        gxw(f, @"#endif\n\n");
    }
    for (int i = from; i < to; i++) {
        for (int k = 0; k < _cls[i].nm; k++) {
            if (cancelled && cancelled()) { fclose(f); return dest; }
            uint64_t imp = _cls[i].m[k].imp;
            cur++;
            if (!imp || !bin.arm64 || [done containsObject:@(imp)]) continue;
            [done addObject:@(imp)];
            gxw(f, [self pseudoFor:imp]); gxw(f, @"\n");
            if (progress && cur % 32 == 0) progress((double)cur / total);
        }
    }
    if (ci < 0 && bin.arm64) {
        gxw(f, GXL(@"/* ===== Функции C / C++ ===== */\n\n"));
        for (size_t i = 0; i < bin.nfn; i++) {
            if (cancelled && cancelled()) break;
            cur++;
            uint64_t a = bin.fn[i].addr;
            if ([done containsObject:@(a)]) continue;
            int si = gx_bin_sect_of_addr(&bin, a);
            if (si < 0 || !bin.s[si].exec) continue;
            gxw(f, [self pseudoFor:a]); gxw(f, @"\n");
            if (progress && cur % 32 == 0) progress((double)cur / total);
        }
    }
    fclose(f);
    return dest;
}

- (NSString *)allHeaders {
    [self loadObjC];
    NSMutableString *s = [NSMutableString stringWithFormat:GXL(@"// %@ — заголовки Objective-C (восстановлены из метаданных)\n// Классов и категорий: %d\n\n#import <Foundation/Foundation.h>\n#import <UIKit/UIKit.h>\n\n"), _path.lastPathComponent, _ncls];
    for (int i = 0; i < _ncls; i++) { [s appendString:GXStr(_cls[i].header)]; [s appendString:@"\n"]; }
    return s;
}

- (void)reopen {
    gx_bin_close(&bin);
    char names[16][24]; size_t offs[16], sizes[16];
    _nslices = gx_bin_slices(_data.bytes, _data.length, names, offs, sizes, 16);
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < _nslices; i++) [a addObject:[NSString stringWithUTF8String:names[i]] ?: @"?"];
    _sliceNames = a;
    if (_slice >= _nslices) _slice = 0;
    if (_nslices > 1 && _slice == 0) for (int i = 0; i < _nslices; i++) if (!strcmp(names[i], "arm64")) { _slice = i; break; }
    [self freeObjC];
    gx_bin_open(&bin, _data.mutableBytes, _data.length, _slice);
    _strings = nil; _funcs = nil; _imports = nil;
}

- (BOOL)dirty { return _patches.count > 0; }

- (NSString *)sigState {
    if (bin.fmt != 1) return bin.fmt == 2 ? GXL(@"подпись не нужна (ELF)") : @"—";
    if (!bin.sig_size) return GXL(@"нет подписи");
    const uint8_t *s = (const uint8_t *)_data.bytes + bin.sig_off;
    if (bin.sig_off + 12 > _data.length) return GXL(@"битая");
    uint32_t cnt = (uint32_t)s[8] << 24 | s[9] << 16 | s[10] << 8 | s[11];
    for (uint32_t i = 0; i < cnt && 12 + (i + 1) * 8 <= bin.sig_size; i++) {
        const uint8_t *e = s + 12 + i * 8;
        uint32_t t = (uint32_t)e[0] << 24 | e[1] << 16 | e[2] << 8 | e[3];
        if (t == 0x10000) return GXL(@"подписан сертификатом");
    }
    return @"ad-hoc";
}

- (NSString *)nameForAddr:(uint64_t)a exactOnly:(BOOL)exact {
    const gx_name *im = gx_bin_import_at(&bin, a);
    if (im) return GXDemangle(im->name, im->nlen, bin.fmt == 1);
    const gx_name *f = gx_bin_func_of(&bin, a);
    if (!f || (exact && f->addr != a)) return nil;
    NSString *n = f->name ? GXDemangle(f->name, f->nlen, bin.fmt == 1) : ([self objcNameAt:f->addr] ?: [NSString stringWithFormat:@"sub_%llx", (unsigned long long)f->addr]);
    if (f->addr != a) n = [n stringByAppendingFormat:@"+0x%llx", (unsigned long long)(a - f->addr)];
    return n;
}

- (NSString *)sectName:(int)i { return i >= 0 && i < bin.ns ? [NSString stringWithUTF8String:bin.s[i].name] ?: @"?" : @"—"; }

+ (NSStringEncoding)nsenc:(int)enc { return enc == GX_ENC_UTF16 ? NSUTF16LittleEndianStringEncoding : enc == GX_ENC_CP1251 ? NSWindowsCP1251StringEncoding : NSUTF8StringEncoding; }
+ (NSString *)encName:(int)enc { return enc == GX_ENC_UTF16 ? @"UTF-16" : enc == GX_ENC_CP1251 ? @"CP1251" : @"UTF-8"; }

- (void)loadStrings {
    if (_strings) return;
    gx_str *s; size_t n;
    gx_bin_strings(&bin, 4, &s, &n);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    NSCharacterSet *cyr = [NSCharacterSet characterSetWithRange:NSMakeRange(0x400, 0x100)];
    for (size_t i = 0; i < n; i++) {
        NSString *t = [[NSString alloc] initWithBytes:(const uint8_t *)_data.bytes + s[i].off length:s[i].blen encoding:[GXBinDoc nsenc:s[i].enc]];
        if (!t) continue;
        GXBinStr *o = [GXBinStr new];
        o.off = s[i].off; o.blen = s[i].blen; o.enc = s[i].enc; o.cf = s[i].cf; o.sect = s[i].sect; o.text = t;
        o.cyr = [t rangeOfCharacterFromSet:cyr].location != NSNotFound;
        const char *sn = s[i].sect >= 0 ? bin.s[s[i].sect].name : "";
        o.service = strstr(sn, "__objc_") || strstr(sn, "__swift") || strstr(sn, ".dynstr");
        [a addObject:o];
    }
    free(s);
    _strings = a;
}

- (void)loadFuncs {
    if (_funcs) return;
    [self loadObjC];
    NSMutableArray *f = [NSMutableArray arrayWithCapacity:bin.nfn], *im = [NSMutableArray arrayWithCapacity:bin.nimp];
    for (size_t i = 0; i < bin.nfn; i++) {
        GXBinFunc *o = [GXBinFunc new];
        o.addr = bin.fn[i].addr;
        o.size = gx_bin_func_end(&bin, o.addr) - o.addr;
        o.name = bin.fn[i].name ? GXDemangle(bin.fn[i].name, bin.fn[i].nlen, bin.fmt == 1) : ([self objcNameAt:o.addr] ?: [NSString stringWithFormat:@"sub_%llx", (unsigned long long)o.addr]);
        [f addObject:o];
    }
    for (size_t i = 0; i < bin.nimp; i++) {
        GXBinFunc *o = [GXBinFunc new];
        o.addr = bin.imp[i].addr; o.import = YES;
        o.name = GXDemangle(bin.imp[i].name, bin.imp[i].nlen, bin.fmt == 1) ?: @"?";
        [im addObject:o];
    }
    _funcs = f; _imports = im;
}

- (GXBinStr *)stringAtOffset:(size_t)off {
    [self loadStrings];
    for (GXBinStr *s in _strings) if (off >= s.off && off < s.off + s.blen + 1) return s;
    return nil;
}

// Записать байты с учётом истории
- (void)write:(NSData *)bytes at:(size_t)off desc:(NSString *)desc {
    if (off + bytes.length > _data.length || !bytes.length) return;
    uint8_t *p = (uint8_t *)_data.mutableBytes + off;
    NSMutableDictionary *ex = nil;
    for (NSMutableDictionary *d in _patches) if ([d[@"off"] unsignedLongLongValue] == off && [d[@"old"] length] == bytes.length) { ex = d; break; }
    if (ex) {
        if ([ex[@"old"] isEqualToData:bytes]) { memcpy(p, bytes.bytes, bytes.length); [_patches removeObject:ex]; return; }
        ex[@"new"] = bytes.copy; ex[@"desc"] = desc;
    } else {
        if (!memcmp(p, bytes.bytes, bytes.length)) return;
        [_patches addObject:[@{@"off": @(off), @"old": [NSData dataWithBytes:p length:bytes.length], @"new": bytes.copy, @"desc": desc} mutableCopy]];
    }
    memcpy(p, bytes.bytes, bytes.length);
}

- (void)revert:(NSMutableDictionary *)patch {
    size_t off = [patch[@"off"] unsignedLongLongValue];
    NSData *old = patch[@"old"];
    memcpy((uint8_t *)_data.mutableBytes + off, old.bytes, old.length);
    [_patches removeObject:patch];
}

- (void)revertString:(GXBinStr *)s {
    NSMutableSet *offs = [NSMutableSet setWithObject:@(s.off)];
    uint64_t a;
    if (s.cf && gx_bin_o2a(&bin, s.off, &a)) { size_t lo[8]; uint64_t ea[8]; int k = gx_bin_cfstring_lens(&bin, a, lo, ea, 8); for (int i = 0; i < k; i++) [offs addObject:@(lo[i])]; }
    for (NSMutableDictionary *p in _patches.copy) if ([offs containsObject:p[@"off"]]) [self revert:p];
    const uint8_t *b = (const uint8_t *)_data.bytes + s.off;
    NSString *t = [[NSString alloc] initWithBytes:b length:s.blen encoding:[GXBinDoc nsenc:s.enc]];
    if (t) s.text = t;
}

- (BOOL)isPatched:(size_t)off len:(size_t)len {
    for (NSDictionary *d in _patches) {
        size_t o = [d[@"off"] unsignedLongLongValue], l = [d[@"new"] length];
        if (off < o + l && o < off + len) return YES;
    }
    return NO;
}

- (void)writeWords:(const uint32_t *)w count:(int)n at:(uint64_t)addr desc:(NSString *)desc {
    int64_t off = gx_bin_a2o(&bin, addr);
    if (off < 0) return;
    NSMutableData *d = [NSMutableData dataWithLength:n * 4];
    uint8_t *p = d.mutableBytes;
    for (int i = 0; i < n; i++) { p[i * 4] = w[i]; p[i * 4 + 1] = w[i] >> 8; p[i * 4 + 2] = w[i] >> 16; p[i * 4 + 3] = w[i] >> 24; }
    [self write:d at:(size_t)off desc:desc];
}

// Новый текст строки. nil = успех, иначе текст ошибки
- (NSString *)setString:(GXBinStr *)s text:(NSString *)text {
    NSData *enc = [text dataUsingEncoding:[GXBinDoc nsenc:s.enc] allowLossyConversion:NO];
    if (!enc) return [NSString stringWithFormat:GXL(@"Текст нельзя записать в кодировке %@ (есть неподдерживаемые символы)"), [GXBinDoc encName:s.enc]];
    if (enc.length > s.blen) return [NSString stringWithFormat:GXL(@"Не влезает: %lu байт, а место есть только на %u"), (unsigned long)enc.length, s.blen];
    NSMutableData *buf = [enc mutableCopy];
    buf.length = s.blen;   // остаток — нули
    uint64_t addr = 0;
    BOOL hasAddr = gx_bin_o2a(&bin, s.off, &addr);
    [self write:buf at:s.off desc:[NSString stringWithFormat:GXL(@"Строка «%@» → «%@»"), [self shortText:s.text], [self shortText:text]]];
    if (s.cf && hasAddr) {
        size_t lo[8]; uint64_t ea[8];
        int k = gx_bin_cfstring_lens(&bin, addr, lo, ea, 8);
        uint64_t units = s.enc == GX_ENC_UTF16 ? enc.length / 2 : enc.length;
        for (int i = 0; i < k; i++) {
            uint8_t le[8]; for (int j = 0; j < 8; j++) le[j] = (uint8_t)(units >> (8 * j));
            [self write:[NSData dataWithBytes:le length:8] at:lo[i] desc:[NSString stringWithFormat:GXL(@"Длина NSString → %llu"), (unsigned long long)units]];
        }
    }
    s.text = text;
    return nil;
}

- (NSString *)shortText:(NSString *)t {
    t = [[t stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"] stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"];
    return t.length > 40 ? [[t substringToIndex:40] stringByAppendingString:@"…"] : t;
}

- (NSString *)identForSign {
    if (bin.fmt == 1 && bin.sig_size >= 28 && bin.sig_off + bin.sig_size <= _data.length) {
        const uint8_t *s = (const uint8_t *)_data.bytes + bin.sig_off;
        uint32_t cnt = (uint32_t)s[8] << 24 | s[9] << 16 | s[10] << 8 | s[11];
        for (uint32_t i = 0; i < cnt && 12 + (i + 1) * 8 <= bin.sig_size; i++) {
            const uint8_t *e = s + 12 + i * 8;
            uint32_t t = (uint32_t)e[0] << 24 | e[1] << 16 | e[2] << 8 | e[3], o = (uint32_t)e[4] << 24 | e[5] << 16 | e[6] << 8 | e[7];
            if (t == 0 && o + 92 < bin.sig_size) {
                const uint8_t *cd = s + o;
                uint32_t io = (uint32_t)cd[20] << 24 | cd[21] << 16 | cd[22] << 8 | cd[23];
                if (o + io < bin.sig_size) {
                    const char *id = (const char *)cd + io;
                    size_t l = strnlen(id, bin.sig_size - o - io);
                    if (l && l < 256) return [[NSString alloc] initWithBytes:id length:l encoding:NSUTF8StringEncoding];
                }
            }
        }
    }
    return _path.lastPathComponent.stringByDeletingPathExtension;
}

- (NSString *)save {
    NSData *out = _data;
    NSString *note = @"";
    if (_resign) {
        char err[200] = {0}; size_t ol = 0; int ss = 0;
        uint8_t *o = gx_adhoc_sign(_data.bytes, _data.length, [self identForSign].UTF8String, 2, &ol, &ss, err, sizeof err);
        if (!o) return [NSString stringWithFormat:GXL(@"Подпись: %s"), err];
        out = [NSData dataWithBytesNoCopy:o length:ol freeWhenDone:YES];
        note = ss ? [NSString stringWithFormat:GXL(@" Переподписано ad-hoc (%d срез.)."), ss] : @"";
    }
    NSString *orig = [_path stringByAppendingPathExtension:@"orig"];
    if (![FM() fileExistsAtPath:orig]) [FM() copyItemAtPath:_path toPath:orig error:nil];
    NSError *e = nil;
    if (![out writeToFile:_path options:NSDataWritingAtomic error:&e]) return e.localizedDescription ?: GXL(@"Запись не удалась");
    _data = [out mutableCopy];
    [_patches removeAllObjects];
    [self reopen];
    self.lastNote = note;
    return nil;
}
@end

static void GXShowPseudo(UIViewController *from, GXBinDoc *doc, uint64_t addr);
static void GXRunDecompile(UIViewController *vc, GXBinDoc *doc, int ci);

#pragma mark - Редактор строки

@interface GXBinStrEditVC : UIViewController <UITextViewDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc str:(GXBinStr *)s;
@property (nonatomic, copy, nullable) void (^onSave)(void);
@end

@implementation GXBinStrEditVC {
    GXBinDoc *_doc; GXBinStr *_s; UITextView *_tv; UILabel *_count;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc str:(GXBinStr *)s { if ((self = [super init])) { _doc = doc; _s = s; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Строка");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Записать") style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    UILabel *info = [UILabel new];
    info.numberOfLines = 0;
    info.font = [UIFont systemFontOfSize:12];
    info.textColor = UIColor.secondaryLabelColor;
    uint64_t a = 0; gx_bin_o2a(&_doc->bin, _s.off, &a);
    info.text = [NSString stringWithFormat:GXL(@"Адрес %@ · смещение %@ · %@ · %@%@\nСтрока заменяется на месте: новый текст должен уложиться в те же байты (остаток заполнится нулями). В UTF-8 русская буква занимает 2 байта, латинская — 1.%@"),
                 GXHex(a), GXHex(_s.off), [_doc sectName:_s.sect], [GXBinDoc encName:_s.enc], _s.cf ? @" · NSString" : @"",
                 _s.cf ? GXL(@"\nЭто NSString — длина в структуре обновится автоматически.") : @""];
    _tv = [UITextView new];
    _tv.font = [UIFont systemFontOfSize:17];
    _tv.text = _s.text;
    _tv.delegate = self;
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.layer.cornerRadius = 8;
    _tv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _count = [UILabel new];
    _count.font = GXMono(14);
    _count.numberOfLines = 0;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[info, _count, _tv]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [st.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [st.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [st.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-10],
    ]];
    [self textViewDidChange:_tv];
    [_tv becomeFirstResponder];
}
- (void)textViewDidChange:(UITextView *)tv {
    NSData *d = [tv.text dataUsingEncoding:[GXBinDoc nsenc:_s.enc] allowLossyConversion:NO];
    BOOL ok = d && d.length <= _s.blen;
    _count.textColor = ok ? UIColor.labelColor : UIColor.systemRedColor;
    _count.text = d ? [NSString stringWithFormat:GXL(@"Байт: %lu из %u%@"), (unsigned long)d.length, _s.blen, ok ? [NSString stringWithFormat:GXL(@" · свободно %lu"), (unsigned long)(_s.blen - d.length)] : GXL(@" — не влезает, сократи текст")]
                    : [NSString stringWithFormat:GXL(@"Есть символы, которых нет в %@"), [GXBinDoc encName:_s.enc]];
    self.navigationItem.rightBarButtonItem.enabled = ok;
}
- (void)save {
    NSString *e = [_doc setString:_s text:_tv.text];
    if (e) { GXAlert(self, GXL(@"Не записано"), e); return; }
    if (self.onSave) self.onSave();
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - Ссылки

@interface GXBinDisasmVC : UITableViewController
- (instancetype)initWithDoc:(GXBinDoc *)doc addr:(uint64_t)addr;
@end

@interface GXBinXrefsVC : UITableViewController
- (instancetype)initWithDoc:(GXBinDoc *)doc lo:(uint64_t)lo hi:(uint64_t)hi title:(NSString *)t;
@end

@implementation GXBinXrefsVC {
    GXBinDoc *_doc; uint64_t _lo, _hi; NSArray<NSArray *> *_rows;   // @[from, code, text]
}
- (instancetype)initWithDoc:(GXBinDoc *)doc lo:(uint64_t)lo hi:(uint64_t)hi title:(NSString *)t {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _doc = doc; _lo = lo; _hi = hi; self.title = t; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _rows = @[];
    [GXHUD showIn:self.view text:GXL(@"Поиск ссылок…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gx_xref *x; size_t n;
        gx_bin_xrefs(&self->_doc->bin, self->_lo, self->_hi, &x, &n, 2000);
        NSMutableArray *r = [NSMutableArray array];
        for (size_t i = 0; i < n; i++) {
            NSString *t;
            if (x[i].code) {
                int64_t off = gx_bin_a2o(&self->_doc->bin, x[i].from);
                char dis[128] = "?";
                if (off >= 0 && (size_t)off + 4 <= self->_doc.data.length) { const uint8_t *p = (const uint8_t *)self->_doc.data.bytes + off; gx_a64_dis((uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24, x[i].from, dis, sizeof dis, NULL); }
                t = [NSString stringWithFormat:@"%@\n%s", [self->_doc nameForAddr:x[i].from exactOnly:NO] ?: @"?", dis];
            } else t = [NSString stringWithFormat:GXL(@"указатель в данных (%@)"), [self->_doc sectName:gx_bin_sect_of_addr(&self->_doc->bin, x[i].from)]];
            [r addObject:@[@(x[i].from), @(x[i].code), t]];
        }
        free(x);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            self->_rows = r;
            [self.tableView reloadData];
        });
    });
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count ? _rows.count : 1; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return GXL(@"Код: место, где адрес загружается (ADRP+ADD/LDR, ADR, переходы). Данные: таблица указателей (например, список пунктов меню ImGui). Нажми, чтобы открыть.");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!_rows.count) { c.textLabel.text = GXL(@"Ссылок не найдено"); c.detailTextLabel.text = GXL(@"Строка может читаться через смещение, таблицу или из Swift — поищи её текстом"); c.detailTextLabel.numberOfLines = 0; return c; }
    NSArray *r = _rows[ip.row];
    c.textLabel.text = GXHex([r[0] unsignedLongLongValue]);
    c.textLabel.font = GXMono(14);
    c.detailTextLabel.text = r[2];
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.font = GXMono(12);
    c.imageView.image = [UIImage systemImageNamed:[r[1] boolValue] ? @"chevron.left.forwardslash.chevron.right" : @"list.bullet.indent"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!_rows.count) return;
    NSArray *r = _rows[ip.row];
    uint64_t a = [r[0] unsignedLongLongValue];
    if ([r[1] boolValue]) [self.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:_doc addr:a] animated:YES];
    else [self.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:_doc lo:(a > 0x200 ? (a & ~7ull) - 0x200 : 0) hi:a + 8 title:[NSString stringWithFormat:GXL(@"Ссылки на таблицу у %@"), GXHex(a)]] animated:YES];
}
@end

#pragma mark - Строки

@interface GXBinStringsVC : UITableViewController <UISearchResultsUpdating, UISearchBarDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc;
@end

@implementation GXBinStringsVC {
    GXBinDoc *_doc; NSArray<GXBinStr *> *_shown; UISearchController *_sc;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc { if ((self = [super initWithStyle:UITableViewStylePlain])) { _doc = doc; self.title = GXL(@"Строки"); } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    _sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    _sc.searchResultsUpdater = self;
    _sc.obscuresBackgroundDuringPresentation = NO;
    _sc.searchBar.placeholder = GXL(@"Поиск текста (русский тоже)");
    _sc.searchBar.scopeButtonTitles = @[GXL(@"Все"), GXL(@"Русские"), GXL(@"Без служебных")];
    _sc.searchBar.delegate = self;
    _sc.searchBar.showsScopeBar = YES;
    self.navigationItem.searchController = _sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.left.arrow.right"] style:UIBarButtonItemStylePlain target:self action:@selector(replaceAll)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    _shown = @[];
    if (_doc.strings) [self filter];
    else {
        [GXHUD showIn:self.view text:GXL(@"Поиск строк…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self->_doc loadStrings];
            dispatch_async(dispatch_get_main_queue(), ^{ [GXHUD hide]; [self filter]; });
        });
    }
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.tableView reloadData]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self filter]; }
- (void)searchBar:(UISearchBar *)sb selectedScopeButtonIndexDidChange:(NSInteger)i { [self filter]; }
- (void)filter {
    NSString *q = _sc.searchBar.text ?: @"";
    NSInteger scope = _sc.searchBar.selectedScopeButtonIndex;
    NSMutableArray *r = [NSMutableArray array];
    for (GXBinStr *s in _doc.strings) {
        if (scope == 1 && !s.cyr) continue;
        if (scope == 2 && s.service) continue;
        if (q.length && [s.text rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) continue;
        [r addObject:s];
    }
    _shown = r;
    self.title = [NSString stringWithFormat:GXL(@"Строки (%lu)"), (unsigned long)r.count];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _shown.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"s"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
    GXBinStr *s = _shown[ip.row];
    NSString *t = [[s.text stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"] stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"];
    c.textLabel.text = t.length > 300 ? [[t substringToIndex:300] stringByAppendingString:@"…"] : t;
    c.textLabel.numberOfLines = 3;
    BOOL edited = [_doc isPatched:s.off len:s.blen];
    c.textLabel.textColor = edited ? UIColor.systemOrangeColor : UIColor.labelColor;
    c.detailTextLabel.text = [NSString stringWithFormat:GXL(@"%@ · %@ · %u Б · %@%@%@"), GXHex(s.off), [_doc sectName:s.sect], s.blen, [GXBinDoc encName:s.enc], s.cf ? @" · NSString" : @"", edited ? GXL(@" · изменено") : @""];
    c.detailTextLabel.font = GXMono(11);
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    GXBinStrEditVC *e = [[GXBinStrEditVC alloc] initWithDoc:_doc str:_shown[ip.row]];
    [self.navigationController pushViewController:e animated:YES];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    GXBinStr *s = _shown[ip.row];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *sug) {
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:[UIAction actionWithTitle:GXL(@"Изменить") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *x) { [ws.navigationController pushViewController:[[GXBinStrEditVC alloc] initWithDoc:ws.doc str:s] animated:YES]; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Где используется") image:[UIImage systemImageNamed:@"arrow.triangle.branch"] identifier:nil handler:^(UIAction *x) { [ws showXrefs:s]; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Копировать текст") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *x) { UIPasteboard.generalPasteboard.string = s.text; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Копировать смещение") image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(UIAction *x) { UIPasteboard.generalPasteboard.string = GXHex(s.off); }]];
        if ([ws.doc isPatched:s.off len:s.blen])
            [a addObject:[UIAction actionWithTitle:GXL(@"Вернуть исходный текст") image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *x) { [ws.doc revertString:s]; [ws.tableView reloadData]; }]];
        return [UIMenu menuWithChildren:a];
    }];
}
- (GXBinDoc *)doc { return _doc; }
- (void)showXrefs:(GXBinStr *)s {
    uint64_t a;
    if (!gx_bin_o2a(&_doc->bin, s.off, &a)) { GXAlert(self, GXL(@"Нет адреса"), GXL(@"Строка вне загружаемых сегментов")); return; }
    if (s.cf) {
        size_t lo[4]; uint64_t ea[4];
        int k = gx_bin_cfstring_lens(&_doc->bin, a, lo, ea, 4);
        if (k) { [self.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:_doc lo:ea[0] hi:ea[0] + 32 title:GXL(@"Где используется (NSString)")] animated:YES]; return; }
    }
    [self.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:_doc lo:a hi:a + s.blen + 1 title:GXL(@"Где используется")] animated:YES];
}
- (void)replaceAll {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Заменить во всех строках") message:GXL(@"Замена идёт в каждой найденной строке на месте. Строки, где новый текст не влезает, будут пропущены.") preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = GXL(@"Найти"); t.text = self->_sc.searchBar.text; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = GXL(@"Заменить на"); }];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Заменить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *f = a.textFields[0].text, *r = a.textFields[1].text ?: @"";
        if (!f.length) return;
        int ok = 0; NSMutableArray *skip = [NSMutableArray array];
        for (GXBinStr *s in self->_doc.strings) {
            if ([s.text rangeOfString:f].location == NSNotFound) continue;
            NSString *nt = [s.text stringByReplacingOccurrencesOfString:f withString:r];
            if ([self->_doc setString:s text:nt]) [skip addObject:[self->_doc shortText:s.text]]; else ok++;
        }
        [self filter];
        NSString *msg = [NSString stringWithFormat:GXL(@"Заменено строк: %d"), ok];
        if (skip.count) msg = [msg stringByAppendingFormat:GXL(@"\nНе влезли (%lu):\n%@"), (unsigned long)skip.count, [[skip subarrayWithRange:NSMakeRange(0, MIN(10, skip.count))] componentsJoinedByString:@"\n"]];
        GXAlert(self, GXL(@"Готово"), msg);
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Дизассемблер

@implementation GXBinDisasmVC {
    GXBinDoc *_doc; uint64_t _start, _focus, _end, _secEnd;
    NSMutableArray<NSArray *> *_rows;   // @[addr, word, text, comment, target]
    uint64_t _regv[32]; int64_t _rega[32];
}
- (instancetype)initWithDoc:(GXBinDoc *)doc addr:(uint64_t)addr {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _doc = doc; _focus = addr;
        const gx_name *f = gx_bin_func_of(&doc->bin, addr);
        _start = f && addr - f->addr < 0x100000 ? f->addr : (addr & ~3ull);
        int si = gx_bin_sect_of_addr(&doc->bin, _start);
        _secEnd = si >= 0 ? doc->bin.s[si].addr + doc->bin.s[si].size : _start + 0x1000;
        _end = _start;
        _rows = [NSMutableArray array];
        self.title = [doc nameForAddr:_start exactOnly:NO] ?: GXHex(_start);
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 36;
    UIBarButtonItem *menu = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"wand.and.stars"] menu:[self funcMenu]];
    UIBarButtonItem *pseudo = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.plaintext"] style:UIBarButtonItemStylePlain target:self action:@selector(showPseudo)];
    self.navigationItem.rightBarButtonItems = @[menu, pseudo];
    for (int i = 0; i < 32; i++) _rega[i] = -1000;
    uint64_t fe = gx_bin_func_end(&_doc->bin, _start);
    [self loadUntil:MAX(fe, _focus + 64) max:6000];
    NSUInteger idx = [self rowForAddr:_focus];
    if (idx != NSNotFound) dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:idx inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:NO]; });
}
- (NSUInteger)rowForAddr:(uint64_t)a {
    if (a < _start || a >= _end) return NSNotFound;
    NSUInteger i = (NSUInteger)((a - _start) / 4);
    return i < _rows.count ? i : NSNotFound;
}
- (NSString *)describe:(uint64_t)a {
    char buf[300];
    if (!gx_bin_describe(&_doc->bin, a, buf, sizeof buf)) return nil;
    return GXStr(buf);
}
- (NSString *)stringPreviewAt:(uint64_t)a {
    int64_t off = gx_bin_a2o(&_doc->bin, a);
    if (off < 0) return nil;
    int si = gx_bin_sect_of_addr(&_doc->bin, a);
    if (si < 0 || _doc->bin.s[si].exec) return nil;
    const uint8_t *p = (const uint8_t *)_doc.data.bytes + off;
    size_t lim = MIN((size_t)200, _doc.data.length - (size_t)off), l = 0;
    if (_doc->bin.s[si].kind == GX_SK_CFSTRING && off + 32 <= (int64_t)_doc.data.length) return @"NSString";
    if (_doc->bin.s[si].kind == GX_SK_USTRING) {
        while (l + 2 <= lim && (p[l] || p[l + 1])) l += 2;
        NSString *s = [[NSString alloc] initWithBytes:p length:l encoding:NSUTF16LittleEndianStringEncoding];
        return s.length ? [NSString stringWithFormat:@"\"%@\"", s] : nil;
    }
    while (l < lim && p[l]) l++;
    if (l < 2 || l == lim) return nil;
    NSString *s = [[NSString alloc] initWithBytes:p length:l encoding:NSUTF8StringEncoding];
    if (!s) return nil;
    for (NSUInteger i = 0; i < s.length; i++) { unichar c = [s characterAtIndex:i]; if (c < 0x20 && c != '\n' && c != '\t') return nil; }
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"];
    return [NSString stringWithFormat:@"\"%@\"", s.length > 60 ? [[s substringToIndex:60] stringByAppendingString:@"…"] : s];
}
- (void)loadUntil:(uint64_t)until max:(NSUInteger)max {
    if (until > _secEnd) until = _secEnd;
    NSUInteger added = 0;
    const uint8_t *base = _doc.data.bytes;
    while (_end < until && added < max) {
        int64_t off = gx_bin_a2o(&_doc->bin, _end);
        if (off < 0 || (size_t)off + 4 > _doc.data.length) { _secEnd = _end; break; }
        const uint8_t *p = base + off;
        uint32_t w = (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
        char buf[160]; uint64_t t = 0;
        int k = gx_a64_dis(w, _end, buf, sizeof buf, &t);
        NSString *cm = nil;
        int rd, rn; uint64_t imm, pg;
        int64_t ix = (int64_t)((_end - _start) / 4);
        if (gx_a64_is_adrp(w, _end, &rd, &pg)) { _regv[rd] = pg; _rega[rd] = ix; }
        else if (gx_a64_is_addimm(w, &rd, &rn, &imm) && rn != 31 && ix - _rega[rn] < 48) {
            uint64_t a = _regv[rn] + imm; _regv[rd] = a; _rega[rd] = ix;
            cm = [self describe:a] ?: [_doc nameForAddr:a exactOnly:YES] ?: GXHex(a);
            t = a;
        } else if (gx_a64_is_ldst_uimm(w, &rd, &rn, &imm) && rn != 31 && ix - _rega[rn] < 48) {
            uint64_t a = _regv[rn] + imm;
            cm = [self describe:a] ?: [_doc nameForAddr:a exactOnly:YES] ?: GXHex(a);
            t = a;
            if ((w >> 22) & 3) _rega[rd] = -1000;
        } else if (k == GX_A64_CALL || k == GX_A64_BRANCH || k == GX_A64_COND) {
            cm = [_doc nameForAddr:t exactOnly:k == GX_A64_CALL];
            if (k == GX_A64_CALL) for (int r = 0; r < 19; r++) _rega[r] = -1000;
        } else if (k == GX_A64_ADR || k == GX_A64_LIT) {
            cm = [self describe:t] ?: [_doc nameForAddr:t exactOnly:YES];
            if (k == GX_A64_ADR) { _regv[w & 31] = t; _rega[w & 31] = ix; }
        } else if (k != GX_A64_RET) _rega[w & 31] = -1000;
        int ck, c64; double cv;
        if (!cm && gx_a64_const(w, &ck, &cv, &c64) && ck == 2) cm = [NSString stringWithFormat:@"= %g", cv];
        [_rows addObject:@[@(_end), @(w), [NSString stringWithUTF8String:buf] ?: @"?", cm ?: @"", @(t)]];
        _end += 4; added++;
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? _rows.count : (_end < _secEnd ? 1 : 0); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.textLabel.text = GXL(@"Показать дальше (+500 инструкций)");
        c.textLabel.textColor = tv.tintColor;
        return c;
    }
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"i"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"i"];
    NSArray *r = _rows[ip.row];
    uint64_t a = [r[0] unsignedLongLongValue];
    int64_t off = gx_bin_a2o(&_doc->bin, a);
    BOOL patched = off >= 0 && [_doc isPatched:(size_t)off len:4];
    const gx_name *f = gx_bin_func_of(&_doc->bin, a);
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    if (f && f->addr == a && a != _start) {
        NSString *nm = [_doc nameForAddr:a exactOnly:YES] ?: @"";
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:[nm stringByAppendingString:@":\n"] attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.systemPurpleColor}]];
    }
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%llx ", (unsigned long long)a] attributes:@{NSFontAttributeName: GXMono(11), NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%08X ", [r[1] unsignedIntValue]] attributes:@{NSFontAttributeName: GXMono(10), NSForegroundColorAttributeName: UIColor.tertiaryLabelColor}]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:r[2] attributes:@{NSFontAttributeName: GXMono(13), NSForegroundColorAttributeName: patched ? UIColor.systemOrangeColor : UIColor.labelColor}]];
    if ([r[3] length]) [s appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  ; " stringByAppendingString:r[3]] attributes:@{NSFontAttributeName: GXMono(12), NSForegroundColorAttributeName: UIColor.systemGreenColor}]];
    c.textLabel.attributedText = s;
    c.textLabel.numberOfLines = 0;
    c.backgroundColor = a == _focus ? [UIColor.systemYellowColor colorWithAlphaComponent:0.25] : UIColor.systemBackgroundColor;
    return c;
}
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)c forRowAtIndexPath:(NSIndexPath *)ip {}
- (void)reloadRowsFrom:(uint64_t)a count:(int)n {
    // перечитать слова и текст для изменённых инструкций
    NSUInteger i0 = [self rowForAddr:a];
    if (i0 == NSNotFound) return;
    for (int i = 0; i < n && i0 + i < _rows.count; i++) {
        uint64_t aa = a + i * 4;
        int64_t off = gx_bin_a2o(&_doc->bin, aa);
        const uint8_t *p = (const uint8_t *)_doc.data.bytes + off;
        uint32_t w = (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
        char buf[160]; uint64_t t = 0;
        int k = gx_a64_dis(w, aa, buf, sizeof buf, &t);
        NSString *cm = (k == GX_A64_CALL || k == GX_A64_BRANCH || k == GX_A64_COND) ? [_doc nameForAddr:t exactOnly:NO] : nil;
        int ck, c64; double cv;
        if (!cm && gx_a64_const(w, &ck, &cv, &c64) && ck == 2) cm = [NSString stringWithFormat:@"= %g", cv];
        _rows[i0 + i] = @[@(aa), @(w), [NSString stringWithUTF8String:buf] ?: @"?", cm ?: @"", @(t)];
    }
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        [self loadUntil:_end + 2000 max:500];
        [tv reloadData];
        return;
    }
    NSArray *r = _rows[ip.row];
    uint64_t a = [r[0] unsignedLongLongValue], t = [r[4] unsignedLongLongValue];
    uint32_t w = [r[1] unsignedIntValue];
    int64_t off = gx_bin_a2o(&_doc->bin, a);
    UIAlertController *m = [UIAlertController alertControllerWithTitle:r[2] message:[NSString stringWithFormat:GXL(@"Адрес %@ · смещение %@"), GXHex(a), GXHex((uint64_t)off)] preferredStyle:UIAlertControllerStyleActionSheet];
    void (^add)(NSString *, UIAlertActionStyle, void (^)(void)) = ^(NSString *title, UIAlertActionStyle st, void (^b)(void)) { [m addAction:[UIAlertAction actionWithTitle:title style:st handler:^(UIAlertAction *x) { b(); }]]; };
    __weak typeof(self) ws = self;
    GXBinDoc *doc = _doc;
    if (t) {
        int si = gx_bin_sect_of_addr(&doc->bin, t);
        if (si >= 0 && doc->bin.s[si].exec)
            add([NSString stringWithFormat:GXL(@"Перейти → %@"), [doc nameForAddr:t exactOnly:NO] ?: GXHex(t)], UIAlertActionStyleDefault, ^{ [ws.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:doc addr:t] animated:YES]; });
        else if (si >= 0) {
            int64_t to = gx_bin_a2o(&doc->bin, t);
            GXBinStr *s = to >= 0 ? [doc stringAtOffset:(size_t)to] : nil;
            if (s) add([NSString stringWithFormat:GXL(@"Изменить строку «%@»"), [doc shortText:s.text]], UIAlertActionStyleDefault, ^{ [ws.navigationController pushViewController:[[GXBinStrEditVC alloc] initWithDoc:doc str:s] animated:YES]; });
            add(GXL(@"Где ещё используется этот адрес"), UIAlertActionStyleDefault, ^{ [ws.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:doc lo:t hi:t + 1 title:GXHex(t)] animated:YES]; });
        }
    }
    int ck, c64; double cv;
    if (gx_a64_const(w, &ck, &cv, &c64)) {
        add([NSString stringWithFormat:GXL(@"Изменить число (сейчас %g)"), cv], UIAlertActionStyleDefault, ^{
            GXPrompt(ws, GXL(@"Новое значение"), ck == 2 ? GXL(@"FMOV умеет только «простые» дроби: 0.5, 1, 1.5, 2, 3, 10, 0.25… Для любого float используй шаблон функции.") : ck == 4 ? GXL(@"CMP: целое 0…4095 (или кратное 4096)") : GXL(@"MOV: целое, умещающееся в 16 бит (с возможным сдвигом)"), [NSString stringWithFormat:@"%g", cv], nil, GXL(@"Записать"), ^(NSString *v) {
                double nv = [v stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue;
                uint32_t nw = w;
                if (!gx_a64_set_const(&nw, ck, nv)) { GXAlert(ws, GXL(@"Не получится"), GXL(@"Это значение нельзя закодировать в этой инструкции. Попробуй шаблон «Вернуть число» для функции.")); return; }
                [doc writeWords:&nw count:1 at:a desc:[NSString stringWithFormat:@"%@: %g → %g", GXHex(a), cv, nv]];
                [ws reloadRowsFrom:a count:1];
            });
        });
    }
    add(GXL(@"Изменить инструкцию (ассемблер)…"), UIAlertActionStyleDefault, ^{ [ws askAsmAt:a initial:r[2]]; });
    add(GXL(@"Заменить на NOP (ничего не делать)"), UIAlertActionStyleDefault, ^{ uint32_t n = GX_A64_NOP; [doc writeWords:&n count:1 at:a desc:[NSString stringWithFormat:@"%@: NOP", GXHex(a)]]; [ws reloadRowsFrom:a count:1]; });
    add(GXL(@"Записать слова (hex)…"), UIAlertActionStyleDefault, ^{
        GXPrompt(ws, GXL(@"Инструкции (hex-слова)"), GXL(@"Как в сером столбце, через пробел. Например: 52800020 D65F03C0 = mov w0,#1; ret"), [NSString stringWithFormat:@"%08X", w], @"D503201F", GXL(@"Записать"), ^(NSString *v) {
            NSArray *parts = [v componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSMutableData *wd = [NSMutableData data]; int n = 0;
            for (NSString *p in parts) { if (!p.length) continue; uint64_t x; if (!GXParseHex(p, &x) || x > 0xFFFFFFFFull || n >= 256) { GXAlert(ws, GXL(@"Ошибка"), [NSString stringWithFormat:GXL(@"Не hex-слово: %@"), p]); return; } uint32_t w32 = (uint32_t)x; [wd appendBytes:&w32 length:4]; n++; }
            if (!n) return;
            void (^doWrite)(void) = ^{ [doc writeWords:wd.bytes count:n at:a desc:[NSString stringWithFormat:GXL(@"%@: %d слов(а)"), GXHex(a), n]]; [ws reloadRowsFrom:a count:n]; };
            if (a + n * 4 > gx_bin_func_end(&doc->bin, a)) { GXConfirm(ws, GXL(@"Выход за функцию"), GXL(@"Запись заденет следующую функцию. Всё равно записать?"), GXL(@"Записать"), YES, doWrite); return; }
            doWrite();
        });
    });
    add(GXL(@"Переход сюда → B на адрес…"), UIAlertActionStyleDefault, ^{
        GXPrompt(ws, GXL(@"Безусловный переход"), GXL(@"Адрес назначения (hex)"), nil, @"0x1234", GXL(@"Записать"), ^(NSString *v) {
            uint64_t to; uint32_t bw;
            if (!GXParseHex(v, &to) || !gx_a64_enc_branch(a, to, 0, &bw)) { GXAlert(ws, GXL(@"Ошибка"), GXL(@"Неверный адрес или слишком далеко (±128 МБ)")); return; }
            [doc writeWords:&bw count:1 at:a desc:[NSString stringWithFormat:@"%@: b %@", GXHex(a), GXHex(to)]];
            [ws reloadRowsFrom:a count:1];
        });
    });
    if (off >= 0 && [doc isPatched:(size_t)off len:4]) add(GXL(@"Откатить изменение"), UIAlertActionStyleDestructive, ^{
        for (NSMutableDictionary *p in doc.patches.copy) { size_t o = [p[@"off"] unsignedLongLongValue], l = [p[@"new"] length]; if ((size_t)off < o + l && o < (size_t)off + 4) { size_t oo = o; NSUInteger nl = l; [doc revert:p]; uint64_t pa; if (gx_bin_o2a(&doc->bin, oo, &pa)) [ws reloadRowsFrom:pa count:(int)(nl / 4)]; } }
    });
    add(GXL(@"Копировать адрес"), UIAlertActionStyleDefault, ^{ UIPasteboard.generalPasteboard.string = GXHex(a); });
    add(GXL(@"Копировать смещение в файле"), UIAlertActionStyleDefault, ^{ UIPasteboard.generalPasteboard.string = GXHex((uint64_t)off); });
    [m addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    m.popoverPresentationController.sourceView = cell ?: tv;
    m.popoverPresentationController.sourceRect = (cell ?: tv).bounds;
    [self presentViewController:m animated:YES completion:nil];
}
- (void)askAsmAt:(uint64_t)a initial:(NSString *)initial {
    GXBinDoc *doc = _doc;
    __weak typeof(self) ws = self;
    UIAlertController *al = [UIAlertController alertControllerWithTitle:GXL(@"Ассемблер ARM64")
        message:GXL(@"Инструкции через «;». Примеры:\nmov w0, #1; ret\nnop\nb 0x1234   (адрес) или b .+8\nfmov s0, #2.5\nldr x0, [x1, #8]\ncmp w8, #100") preferredStyle:UIAlertControllerStyleAlert];
    [al addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.text = initial; t.font = GXMono(14);
        t.autocorrectionType = UITextAutocorrectionTypeNo; t.autocapitalizationType = UITextAutocapitalizationTypeNone; t.spellCheckingType = UITextSpellCheckingTypeNo;
        t.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [al addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [al addAction:[UIAlertAction actionWithTitle:GXL(@"Собрать и записать") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *txt = al.textFields.firstObject.text ?: @"";
        uint32_t w[64]; char err[300] = {0};
        int n = gx_asm(txt.UTF8String ?: "", a, w, 64, err, sizeof err);
        if (!n) { GXAlert(ws, GXL(@"Ошибка ассемблера"), GXStr(err)); return; }
        NSMutableData *wd = [NSMutableData dataWithBytes:w length:(size_t)n * 4];
        NSString *desc = [NSString stringWithFormat:@"%@: %@", GXHex(a), txt.length > 60 ? [[txt substringToIndex:60] stringByAppendingString:@"…"] : txt];
        void (^doWrite)(void) = ^{ [doc writeWords:wd.bytes count:n at:a desc:desc]; [ws reloadRowsFrom:a count:n]; };
        if (a + (uint64_t)n * 4 > gx_bin_func_end(&doc->bin, a)) { GXConfirm(ws, GXL(@"Выход за функцию"), [NSString stringWithFormat:GXL(@"%d инструкций заденут следующую функцию. Всё равно записать?"), n], GXL(@"Записать"), YES, doWrite); return; }
        doWrite();
    }]];
    [self presentViewController:al animated:YES completion:nil];
}
- (UIMenu *)funcMenu {
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *img, void (^b)(void)) { return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:img] identifier:nil handler:^(UIAction *x) { b(); }]; };
    UIMenu *tpl = [UIMenu menuWithTitle:GXL(@"Шаблон для всей функции") image:[UIImage systemImageNamed:@"wand.and.stars"] identifier:nil options:UIMenuOptionsDisplayInline children:@[
        act(GXL(@"Вернуть true (1)"), @"checkmark.circle", ^{ [ws applyInt:1 wide:NO label:@"true"]; }),
        act(GXL(@"Вернуть false (0)"), @"xmark.circle", ^{ [ws applyInt:0 wide:NO label:@"false"]; }),
        act(GXL(@"Вернуть число (int)…"), @"number", ^{ GXPrompt(ws, GXL(@"Вернуть число"), GXL(@"Функция сразу вернёт это значение (w0/x0)"), @"999999", nil, GXL(@"Записать"), ^(NSString *v) { [ws applyInt:v.longLongValue wide:llabs(v.longLongValue) > 0x7FFFFFFF label:v]; }); }),
        act(GXL(@"Вернуть float…"), @"f.cursive", ^{ GXPrompt(ws, GXL(@"Вернуть float"), GXL(@"Функция сразу вернёт это значение (s0)"), @"100", nil, GXL(@"Записать"), ^(NSString *v) { uint32_t w[8]; int n = gx_a64_tpl_ret_float([v stringByReplacingOccurrencesOfString:@"," withString:@"."].floatValue, w); [ws applyWords:w count:n label:[@"float " stringByAppendingString:v]]; }); }),
        act(GXL(@"Вернуть double…"), @"d.circle", ^{ GXPrompt(ws, GXL(@"Вернуть double"), nil, @"100", nil, GXL(@"Записать"), ^(NSString *v) { uint32_t w[8]; int n = gx_a64_tpl_ret_double([v stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue, w); [ws applyWords:w count:n label:[@"double " stringByAppendingString:v]]; }); }),
        act(GXL(@"Ничего не делать (сразу ret)"), @"arrow.uturn.left", ^{ uint32_t w = GX_A64_RETI; [ws applyWords:&w count:1 label:@"ret"]; }),
        act(GXL(@"Свой код на ассемблере…"), @"chevron.left.forwardslash.chevron.right", ^{ [ws askAsmAt:ws.start initial:@"mov w0, #1; ret"]; }),
    ]];
    return [UIMenu menuWithChildren:@[tpl,
        act(GXL(@"Где вызывается эта функция"), @"arrow.triangle.branch", ^{ [ws.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:ws.doc lo:ws.start hi:ws.start + 1 title:GXL(@"Вызовы функции")] animated:YES]; }),
        act(GXL(@"Откатить изменения в функции"), @"arrow.uturn.backward", ^{ [ws revertFunc]; }),
        act(GXL(@"Копировать имя"), @"doc.on.doc", ^{ UIPasteboard.generalPasteboard.string = ws.title; }),
    ]];
}
- (GXBinDoc *)doc { return _doc; }
- (uint64_t)start { return _start; }
- (void)showPseudo { GXShowPseudo(self, _doc, _start); }
- (void)applyInt:(long long)v wide:(BOOL)wide label:(NSString *)l { uint32_t w[8]; int n = gx_a64_tpl_ret_int(v, wide, w); [self applyWords:w count:n label:l]; }
- (void)applyWords:(uint32_t *)w count:(int)n label:(NSString *)label {
    uint64_t fe = gx_bin_func_end(&_doc->bin, _start);
    if (_start + n * 4 > fe) { GXAlert(self, GXL(@"Не влезает"), GXL(@"Функция слишком короткая для этого шаблона.")); return; }
    [_doc writeWords:w count:n at:_start desc:[NSString stringWithFormat:GXL(@"%@ → вернуть %@"), self.title, label]];
    [self reloadRowsFrom:_start count:n];
    GXToast(self.view, [NSString stringWithFormat:GXL(@"Функция теперь возвращает %@. Не забудь сохранить."), label]);
}
- (void)revertFunc {
    uint64_t fe = gx_bin_func_end(&_doc->bin, _start);
    int64_t o1 = gx_bin_a2o(&_doc->bin, _start), o2 = o1 + (int64_t)(fe - _start);
    for (NSMutableDictionary *p in _doc.patches.copy) { int64_t o = (int64_t)[p[@"off"] unsignedLongLongValue]; if (o >= o1 && o < o2) [_doc revert:p]; }
    [self reloadRowsFrom:_start count:(int)MIN((uint64_t)_rows.count, (fe - _start) / 4)];
}
@end

#pragma mark - Функции

@interface GXBinFuncsVC : UITableViewController <UISearchResultsUpdating, UISearchBarDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc imports:(BOOL)imp;
@end

@implementation GXBinFuncsVC {
    GXBinDoc *_doc; BOOL _imp; NSArray<GXBinFunc *> *_shown; UISearchController *_sc;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc imports:(BOOL)imp { if ((self = [super initWithStyle:UITableViewStylePlain])) { _doc = doc; _imp = imp; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _imp ? GXL(@"Импорты") : GXL(@"Функции");
    _sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    _sc.searchResultsUpdater = self;
    _sc.obscuresBackgroundDuringPresentation = NO;
    _sc.searchBar.placeholder = _imp ? GXL(@"Имя импорта") : GXL(@"Имя функции или адрес");
    self.navigationItem.searchController = _sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    _shown = @[];
    [GXHUD showIn:self.view text:GXL(@"Загрузка имён…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self->_doc loadFuncs];
        dispatch_async(dispatch_get_main_queue(), ^{ [GXHUD hide]; [self updateSearchResultsForSearchController:self->_sc]; });
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text ?: @"";
    NSArray *src = _imp ? _doc.imports : _doc.funcs;
    uint64_t qa = 0; BOOL isAddr = q.length > 2 && GXParseHex(q, &qa) && [q.lowercaseString hasPrefix:@"0x"];
    NSMutableArray *r = [NSMutableArray array];
    for (GXBinFunc *f in src) {
        if (q.length) {
            if (isAddr) { if (!(qa >= f.addr && qa < f.addr + MAX(f.size, 4))) continue; }
            else if ([f.name rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [r addObject:f];
    }
    _shown = r;
    self.title = [NSString stringWithFormat:@"%@ (%lu)", _imp ? GXL(@"Импорты") : GXL(@"Функции"), (unsigned long)r.count];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _shown.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return _imp ? GXL(@"Нажми, чтобы найти, откуда вызывается импорт.") : (_shown.count ? GXL(@"Нажми — псевдокод на C. Кнопка ⓘ — ассемблер с патчами и шаблонами. Долгое нажатие — ещё действия.") : GXL(@"Символы удалены (stripped). Найди нужное место через строки → «Где используется»."));
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"f"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
    GXBinFunc *f = _shown[ip.row];
    c.textLabel.text = f.name;
    c.textLabel.numberOfLines = 2;
    c.textLabel.font = GXMono(13);
    int64_t off = gx_bin_a2o(&_doc->bin, f.addr);
    BOOL p = !_imp && off >= 0 && [_doc isPatched:(size_t)off len:(size_t)MIN(f.size, (uint64_t)1 << 20)];
    c.textLabel.textColor = p ? UIColor.systemOrangeColor : UIColor.labelColor;
    c.detailTextLabel.text = _imp ? GXHex(f.addr) : [NSString stringWithFormat:GXL(@"%@ · %llu Б%@"), GXHex(f.addr), (unsigned long long)f.size, p ? GXL(@" · изменена") : @""];
    c.accessoryType = _imp ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDetailButton;
    c.detailTextLabel.font = GXMono(11);
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    GXBinFunc *f = _shown[ip.row];
    if (_imp) [self.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:_doc lo:f.addr hi:f.addr + 1 title:f.name] animated:YES];
    else GXShowPseudo(self, _doc, f.addr);
}
- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    GXBinFunc *f = _shown[ip.row];
    [self.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:_doc addr:f.addr] animated:YES];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    if (_imp) return nil;
    GXBinFunc *f = _shown[ip.row];
    __weak typeof(self) ws = self;
    GXBinDoc *doc = _doc;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *sug) {
        return [UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:GXL(@"Псевдокод") image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil handler:^(UIAction *x) { GXShowPseudo(ws, doc, f.addr); }],
            [UIAction actionWithTitle:GXL(@"Ассемблер и патчи") image:[UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"] identifier:nil handler:^(UIAction *x) { [ws.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:doc addr:f.addr] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Где вызывается") image:[UIImage systemImageNamed:@"arrow.triangle.branch"] identifier:nil handler:^(UIAction *x) { [ws.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:doc lo:f.addr hi:f.addr + 1 title:f.name] animated:YES]; }],
            [UIAction actionWithTitle:GXL(@"Копировать имя") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *x) { UIPasteboard.generalPasteboard.string = f.name; }],
        ]];
    }];
}
@end

#pragma mark - Числа

@interface GXBinNumbersVC : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc;
@end

@implementation GXBinNumbersVC {
    GXBinDoc *_doc; UISegmentedControl *_type; UITextField *_field; UISwitch *_code; NSMutableArray<NSArray *> *_hits; // @[off, kind]
    int _searchedType;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _doc = doc; _hits = [NSMutableArray array]; self.title = GXL(@"Числа"); } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    _type = [[UISegmentedControl alloc] initWithItems:@[@"int32", @"int64", @"float", @"double", @"int16", GXL(@"байт")]];
    _type.selectedSegmentIndex = 2;
    _field = [UITextField new];
    _field.placeholder = GXL(@"Значение, например 2.5 или 100");
    _field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _field.borderStyle = UITextBorderStyleRoundedRect;
    _field.returnKeyType = UIReturnKeySearch;
    _field.delegate = self;
    _code = [UISwitch new];
    _code.on = YES;
    UILabel *cl = [UILabel new];
    cl.text = GXL(@"Искать и в коде (mov / fmov / cmp)");
    cl.font = [UIFont systemFontOfSize:14];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[cl, _code]];
    UIButton *go = [UIButton buttonWithType:UIButtonTypeSystem];
    [go setTitle:GXL(@"Найти") forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [go addTarget:self action:@selector(search) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[_type, _field, row, go]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.frame = CGRectMake(0, 0, 320, 170);
    st.layoutMargins = UIEdgeInsetsMake(10, 16, 10, 16);
    st.layoutMarginsRelativeArrangement = YES;
    self.tableView.tableHeaderView = st;
}
- (BOOL)textFieldShouldReturn:(UITextField *)t { [self search]; return YES; }
- (int)typeIdx { static const int map[6] = {GX_NT_I32, GX_NT_I64, GX_NT_F32, GX_NT_F64, GX_NT_I16, GX_NT_I8}; return map[_type.selectedSegmentIndex]; }
- (void)search {
    [_field resignFirstResponder];
    double v = [_field.text stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue;
    if (!_field.text.length) return;
    int type = [self typeIdx];
    BOOL code = _code.on;
    [GXHUD showIn:self.view text:GXL(@"Поиск…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gx_numhit *h; size_t n;
        gx_bin_find_num(&self->_doc->bin, type, v, code, &h, &n, 3000);
        NSMutableArray *r = [NSMutableArray array];
        for (size_t i = 0; i < n; i++) [r addObject:@[@(h[i].off), @(h[i].kind)]];
        free(h);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            self->_hits = r; self->_searchedType = type;
            [self.tableView reloadData];
        });
    });
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _hits.count; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return _hits.count ? [NSString stringWithFormat:GXL(@"Найдено: %lu%@"), (unsigned long)_hits.count, _hits.count >= 3000 ? GXL(@" (показаны первые 3000)") : @""] : nil; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return GXL(@"Данные — переменные и таблицы. Код — числа прямо в инструкциях (например, лимиты в cmp). Нажми, чтобы изменить."); }
- (NSString *)valueAt:(size_t)off kind:(int)kind {
    const uint8_t *p = (const uint8_t *)_doc.data.bytes + off;
    if (kind) {
        uint32_t w = (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
        char b[160]; uint64_t a = 0; gx_bin_o2a(&_doc->bin, off, &a);
        gx_a64_dis(w, a, b, sizeof b, NULL);
        return [NSString stringWithUTF8String:b];
    }
    switch (_searchedType) {
        case GX_NT_I8: return [NSString stringWithFormat:@"%d", p[0]];
        case GX_NT_I16: return [NSString stringWithFormat:@"%d", (int16_t)(p[0] | p[1] << 8)];
        case GX_NT_I32: { int32_t x; memcpy(&x, p, 4); return [NSString stringWithFormat:@"%d", x]; }
        case GX_NT_I64: { int64_t x; memcpy(&x, p, 8); return [NSString stringWithFormat:@"%lld", (long long)x]; }
        case GX_NT_F32: { float x; memcpy(&x, p, 4); return [NSString stringWithFormat:@"%g", x]; }
        default: { double x; memcpy(&x, p, 8); return [NSString stringWithFormat:@"%g", x]; }
    }
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"n"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"n"];
    size_t off = [_hits[ip.row][0] unsignedLongLongValue]; int kind = [_hits[ip.row][1] intValue];
    uint64_t a = 0; BOOL ha = gx_bin_o2a(&_doc->bin, off, &a);
    c.textLabel.text = [self valueAt:off kind:kind];
    c.textLabel.font = GXMono(14);
    c.textLabel.textColor = [_doc isPatched:off len:kind ? 4 : 1] ? UIColor.systemOrangeColor : UIColor.labelColor;
    NSString *where = kind ? ([_doc nameForAddr:a exactOnly:NO] ?: GXL(@"код")) : [_doc sectName:gx_bin_sect_of_off(&_doc->bin, off)];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@%@ · %@", ha ? [GXHex(a) stringByAppendingString:@" · "] : @"", GXHex(off), where];
    c.detailTextLabel.font = GXMono(11);
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.accessoryType = kind ? UITableViewCellAccessoryDetailButton : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    size_t off = [_hits[ip.row][0] unsignedLongLongValue]; uint64_t a;
    if (gx_bin_o2a(&_doc->bin, off, &a)) [self.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:_doc addr:a] animated:YES];
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    size_t off = [_hits[ip.row][0] unsignedLongLongValue]; int kind = [_hits[ip.row][1] intValue];
    int type = _searchedType;
    __weak typeof(self) ws = self;
    GXBinDoc *doc = _doc;
    NSString *cur = kind ? @"" : [self valueAt:off kind:0];
    if (kind) {
        const uint8_t *p = (const uint8_t *)doc.data.bytes + off;
        uint32_t w = (uint32_t)p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
        int ck, c64; double cv;
        if (kind == 3) { float f; uint32_t bits = ((w >> 5) & 0xFFFF) << 16; memcpy(&f, &bits, 4); cv = f; ck = 3; }
        else if (!gx_a64_const(w, &ck, &cv, &c64)) return;
        cur = [NSString stringWithFormat:@"%g", cv];
        NSString *hint = kind == 2 ? GXL(@"FMOV: только простые дроби (0.25, 0.5, 1, 1.5, 2, 2.5, 3…31)") : kind == 3 ? GXL(@"Верхняя половина float: 100, 200, 1000, 0.5… (без «хвоста» мантиссы)") : kind == 4 ? @"CMP: 0…4095" : GXL(@"MOV: 16-битное значение (можно со сдвигом)");
        GXPrompt(self, GXL(@"Новое значение в коде"), hint, cur, nil, GXL(@"Записать"), ^(NSString *v) {
            double nv = [v stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue;
            uint32_t nw = w;
            if (!gx_a64_set_const(&nw, ck, nv)) { GXAlert(ws, GXL(@"Не получится"), GXL(@"Это значение не кодируется в этой инструкции. Открой функцию (кнопка ⓘ) и используй шаблон «Вернуть число».")); return; }
            uint64_t a = 0; gx_bin_o2a(&doc->bin, off, &a);
            [doc writeWords:&nw count:1 at:a desc:[NSString stringWithFormat:GXL(@"Код %@: %g → %g"), GXHex(a), cv, nv]];
            [ws.tableView reloadData];
        });
        return;
    }
    GXPrompt(self, GXL(@"Новое значение"), [NSString stringWithFormat:GXL(@"Смещение %@"), GXHex(off)], cur, nil, GXL(@"Записать"), ^(NSString *v) {
        NSString *s = [v stringByReplacingOccurrencesOfString:@"," withString:@"."];
        uint8_t b[8]; size_t n;
        switch (type) {
            case GX_NT_I8: { b[0] = (uint8_t)s.intValue; n = 1; break; }
            case GX_NT_I16: { int16_t x = (int16_t)s.intValue; memcpy(b, &x, 2); n = 2; break; }
            case GX_NT_I32: { int32_t x = (int32_t)s.longLongValue; memcpy(b, &x, 4); n = 4; break; }
            case GX_NT_I64: { int64_t x = s.longLongValue; memcpy(b, &x, 8); n = 8; break; }
            case GX_NT_F32: { float x = s.floatValue; memcpy(b, &x, 4); n = 4; break; }
            default: { double x = s.doubleValue; memcpy(b, &x, 8); n = 8; break; }
        }
        [doc write:[NSData dataWithBytes:b length:n] at:off desc:[NSString stringWithFormat:GXL(@"Число %@: %@ → %@"), GXHex(off), cur, v]];
        [ws.tableView reloadData];
    });
}
@end

#pragma mark - Изменения и секции

@interface GXBinPatchesVC : UITableViewController
- (instancetype)initWithDoc:(GXBinDoc *)doc;
@end
@implementation GXBinPatchesVC { GXBinDoc *_doc; }
- (instancetype)initWithDoc:(GXBinDoc *)doc { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _doc = doc; self.title = GXL(@"Изменения"); } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Откатить всё") style:UIBarButtonItemStylePlain target:self action:@selector(revertAll)];
}
- (void)revertAll { GXConfirm(self, GXL(@"Откатить все изменения?"), nil, GXL(@"Откатить"), YES, ^{ for (NSMutableDictionary *p in self->_doc.patches.reverseObjectEnumerator.allObjects) [self->_doc revert:p]; [self->_doc reopen]; [self.tableView reloadData]; }); }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _doc.patches.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return _doc.patches.count ? GXL(@"Смахни влево, чтобы откатить отдельное изменение. Пока не нажато «Сохранить», файл на диске не меняется.") : GXL(@"Изменений пока нет"); }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSDictionary *p = _doc.patches[ip.row];
    c.textLabel.text = p[@"desc"];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.text = [NSString stringWithFormat:GXL(@"%@ · %lu Б: %@ → %@"), GXHex([p[@"off"] unsignedLongLongValue]), (unsigned long)[p[@"new"] length], GXHexString(p[@"old"], 12), GXHexString(p[@"new"], 12)];
    c.detailTextLabel.font = GXMono(10);
    c.detailTextLabel.numberOfLines = 0;
    return c;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    UIContextualAction *a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:GXL(@"Откатить") handler:^(UIContextualAction *x, UIView *v, void (^done)(BOOL)) {
        [self->_doc revert:self->_doc.patches[ip.row]];
        [tv reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[a]];
}
@end

#pragma mark - Просмотр текста (заголовки, псевдокод)

@interface GXBinTextVC : UIViewController
- (instancetype)initWithTitle:(NSString *)t text:(NSString *)text code:(BOOL)code;
@property (nonatomic, copy, nullable) void (^asmAction)(void);
@end

@implementation GXBinTextVC {
    NSString *_text; BOOL _code; UITextView *_tv;
}
- (instancetype)initWithTitle:(NSString *)t text:(NSString *)text code:(BOOL)code { if ((self = [super init])) { self.title = t; _text = text ?: @""; _code = code; } return self; }

static void GXColor(NSMutableAttributedString *s, NSString *pattern, UIColor *c, NSRegularExpressionOptions o) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:o error:nil];
    [re enumerateMatchesInString:s.string options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags f, BOOL *stop) {
        [s addAttribute:NSForegroundColorAttributeName value:c range:r.range];
    }];
}

- (NSAttributedString *)highlight {
    UIFont *f = GXMono(12);
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:_text attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.labelColor}];
    if (_text.length > 400000) return s;   // большие тексты без подсветки
    GXColor(s, @"\\b(if|goto|return|struct|union|const|id|SEL|Class|BOOL|void|int|long|float|double|char|short|unsigned|uint8_t|uint16_t|__int128|nonatomic|strong|weak|copy|assign|readonly|getter|setter)\\b", UIColor.systemPinkColor, 0);
    GXColor(s, @"@(interface|end|property|protocol|selector)\\b", UIColor.systemPinkColor, 0);
    GXColor(s, @"\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b", UIColor.systemOrangeColor, 0);
    GXColor(s, @"^loc_[0-9a-f]+:", UIColor.systemPurpleColor, NSRegularExpressionAnchorsMatchLines);
    GXColor(s, @"\\[[A-Za-z_][\\w]* [^\\]\\n]*\\]", UIColor.systemTealColor, 0);
    GXColor(s, @"@?\"(\\\\.|[^\"\\\\\\n])*\"", UIColor.systemGreenColor, 0);
    GXColor(s, @"//[^\\n]*", UIColor.secondaryLabelColor, 0);
    return s;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.editable = NO;
    _tv.alwaysBounceVertical = YES;
    _tv.textContainerInset = UIEdgeInsetsMake(10, 8, 30, 8);
    if (@available(iOS 16.0, *)) _tv.findInteractionEnabled = YES;
    [self.view addSubview:_tv];
    _tv.attributedText = _code ? [self highlight] : [[NSAttributedString alloc] initWithString:_text attributes:@{NSFontAttributeName: GXMono(12), NSForegroundColorAttributeName: UIColor.labelColor}];
    NSMutableArray *items = [NSMutableArray array];
    __weak typeof(self) ws = self;
    NSMutableArray *acts = [NSMutableArray arrayWithObjects:
        [UIAction actionWithTitle:GXL(@"Копировать всё") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *x) { UIPasteboard.generalPasteboard.string = ws.text; GXToast(ws.view, GXL(@"Скопировано")); }],
        [UIAction actionWithTitle:GXL(@"Поделиться / сохранить файлом") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *x) { [ws share]; }], nil];
    if (@available(iOS 16.0, *)) [acts insertObject:[UIAction actionWithTitle:GXL(@"Найти в тексте") image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *x) { [ws.textView.findInteraction presentFindNavigatorShowingReplace:NO]; }] atIndex:0];
    [acts insertObject:[UIAction actionWithTitle:GXL(@"Сохранить как файл и редактировать") image:[UIImage systemImageNamed:@"square.and.pencil"] identifier:nil handler:^(UIAction *x) { [ws saveAndEdit]; }] atIndex:0];
    if (self.asmAction) [acts insertObject:[UIAction actionWithTitle:GXL(@"Открыть ассемблер (для патчей)") image:[UIImage systemImageNamed:@"chevron.left.forwardslash.chevron.right"] identifier:nil handler:^(UIAction *x) { if (ws.asmAction) ws.asmAction(); }] atIndex:0];
    [items addObject:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:acts]]];
    self.navigationItem.rightBarButtonItems = items;
}
- (NSString *)text { return _text; }
- (void)saveAndEdit {
    NSString *ext = [_text containsString:@"@implementation"] || [_text containsString:@"@interface"] ? @"m" : @"c";
    NSString *p = GXUniquePath([GXBinDoc decompDir], [[GXBinDoc safeName:self.title] stringByAppendingPathExtension:ext]);
    NSError *e = nil;
    if (![_text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:&e]) { GXAlert(self, GXL(@"Не сохранено"), e.localizedDescription); return; }
    GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено: GX Compiler/Восстановленный код/%@"), p.lastPathComponent]);
    [GXOpener openText:p from:self readOnly:NO];
}
- (UITextView *)textView { return _tv; }
- (void)share {
    NSString *name = [[self.title stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    if (name.length > 60) name = [name substringToIndex:60];
    NSString *p = [GXTempDir() stringByAppendingPathComponent:[name stringByAppendingPathExtension:_code && [_text containsString:@"@interface"] ? @"h" : @"txt"]];
    [_text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:p]] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:av animated:YES completion:nil];
}
@end

static void GXShowPseudo(UIViewController *from, GXBinDoc *doc, uint64_t addr) {
    [GXHUD showIn:from.view text:GXL(@"Восстановление псевдокода…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *t = [doc pseudoFor:addr];
        NSString *nm = [doc nameForAddr:addr exactOnly:NO] ?: GXHex(addr);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            GXBinTextVC *v = [[GXBinTextVC alloc] initWithTitle:nm text:t code:YES];
            __weak UINavigationController *nav = from.navigationController;
            v.asmAction = ^{ [nav pushViewController:[[GXBinDisasmVC alloc] initWithDoc:doc addr:addr] animated:YES]; };
            [from.navigationController pushViewController:v animated:YES];
        });
    });
}

#pragma mark - Классы Objective-C

@interface GXBinClassVC : UITableViewController
- (instancetype)initWithDoc:(GXBinDoc *)doc index:(int)i;
@end

@implementation GXBinClassVC { GXBinDoc *_doc; int _i; }
- (instancetype)initWithDoc:(GXBinDoc *)doc index:(int)i { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _doc = doc; _i = i; self.title = GXStr(doc->_cls[i].name); } return self; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : _doc->_cls[_i].nm; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 1 ? [NSString stringWithFormat:GXL(@"Методы (%d)"), _doc->_cls[_i].nm] : nil; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return s == 1 ? GXL(@"Нажми — псевдокод метода. Кнопка ⓘ — ассемблер (там же шаблоны «вернуть true/число» и патчи).") : nil; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (ip.section == 0) {
        c.textLabel.text = ip.row ? GXL(@"Восстановить C-код класса (.m, редактируемый)") : GXL(@"Заголовок .h (как исходник)");
        c.imageView.image = [UIImage systemImageNamed:ip.row ? @"square.and.pencil" : @"doc.plaintext"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    gx_objc_m *m = &_doc->_cls[_i].m[ip.row];
    c.textLabel.text = GXStr(m->name);
    c.textLabel.font = GXMono(13);
    c.textLabel.numberOfLines = 2;
    int64_t off = m->imp ? gx_bin_a2o(&_doc->bin, m->imp) : -1;
    BOOL p = off >= 0 && [_doc isPatched:(size_t)off len:(size_t)MIN(gx_bin_func_end(&_doc->bin, m->imp) - m->imp, (uint64_t)1 << 20)];
    c.textLabel.textColor = p ? UIColor.systemOrangeColor : UIColor.labelColor;
    c.detailTextLabel.text = m->imp ? [NSString stringWithFormat:@"%@%@", GXHex(m->imp), p ? GXL(@" · изменён") : @""] : GXL(@"без реализации");
    c.detailTextLabel.font = GXMono(11);
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (m->imp) c.accessoryType = UITableViewCellAccessoryDetailButton;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 1) { GXRunDecompile(self, _doc, _i); return; }
    if (ip.section == 0) { [self.navigationController pushViewController:[[GXBinTextVC alloc] initWithTitle:[self.title stringByAppendingString:@".h"] text:GXStr(_doc->_cls[_i].header) code:YES] animated:YES]; return; }
    uint64_t imp = _doc->_cls[_i].m[ip.row].imp;
    if (!imp) return;
    if (!_doc->bin.arm64) { GXAlert(self, GXL(@"Только arm64"), nil); return; }
    GXShowPseudo(self, _doc, imp);
}
- (void)tableView:(UITableView *)tv accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)ip {
    uint64_t imp = _doc->_cls[_i].m[ip.row].imp;
    if (imp) [self.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:_doc addr:imp] animated:YES];
}
@end

@interface GXBinClassesVC : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithDoc:(GXBinDoc *)doc;
@end

@implementation GXBinClassesVC { GXBinDoc *_doc; NSArray<NSNumber *> *_shown; UISearchController *_sc; }
- (instancetype)initWithDoc:(GXBinDoc *)doc { if ((self = [super initWithStyle:UITableViewStylePlain])) { _doc = doc; self.title = GXL(@"Классы"); } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    _sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    _sc.searchResultsUpdater = self;
    _sc.obscuresBackgroundDuringPresentation = NO;
    _sc.searchBar.placeholder = GXL(@"Класс или метод");
    self.navigationItem.searchController = _sc;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.plaintext"] style:UIBarButtonItemStylePlain target:self action:@selector(allHeaders)];
    _shown = @[];
    [GXHUD showIn:self.view text:GXL(@"Чтение классов…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self->_doc loadObjC];
        dispatch_async(dispatch_get_main_queue(), ^{ [GXHUD hide]; [self updateSearchResultsForSearchController:self->_sc]; });
    });
}
- (void)allHeaders {
    [GXHUD showIn:self.view text:GXL(@"Сборка заголовков…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *t = [self->_doc allHeaders];
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            [self.navigationController pushViewController:[[GXBinTextVC alloc] initWithTitle:[self->_doc.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@"-headers.h"] text:t code:YES] animated:YES];
        });
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    if (!_doc.objcLoaded) return;
    NSString *q = sc.searchBar.text ?: @"";
    NSMutableArray *r = [NSMutableArray array];
    for (int i = 0; i < _doc->_ncls; i++) {
        if (q.length) {
            BOOL hit = [GXStr(_doc->_cls[i].name) rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
            for (int k = 0; !hit && k < _doc->_cls[i].nm; k++) hit = [GXStr(_doc->_cls[i].m[k].name) rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!hit) continue;
        }
        [r addObject:@(i)];
    }
    _shown = r;
    self.title = [NSString stringWithFormat:GXL(@"Классы (%lu)"), (unsigned long)r.count];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _shown.count; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return _doc.objcLoaded && !_doc->_ncls ? GXL(@"Классов Objective-C нет: библиотека на чистом C/C++ или Swift. Смотри «Функции» — там псевдокод для любой функции.") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    gx_objc_cls *k = &_doc->_cls[_shown[ip.row].intValue];
    c.textLabel.text = GXStr(k->name);
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    c.detailTextLabel.text = [NSString stringWithFormat:GXL(@"%@ · методов %d · ivars %d"), k->is_cat ? GXL(@"категория") : GXL(@"класс"), k->nm, k->niv];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:k->is_cat ? @"puzzlepiece.extension" : @"c.square"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self.navigationController pushViewController:[[GXBinClassVC alloc] initWithDoc:_doc index:_shown[ip.row].intValue] animated:YES];
}
@end

static void GXRunDecompile(UIViewController *vc, GXBinDoc *doc, int ci) {
    if (!doc->bin.arm64) { GXAlert(vc, GXL(@"Только arm64"), GXL(@"Псевдокод строится для arm64 (iPhone и Android arm64-v8a).")); return; }
    [GXHUD showCancellableIn:vc.view text:GXL(@"Восстановление C-кода…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *dest = [doc writeDecompiledClass:ci progress:^(double p) { dispatch_async(dispatch_get_main_queue(), ^{ [GXHUD setProgress:p]; }); }
                                         cancelled:^BOOL { return [GXHUD cancelled]; }];
        BOOL stopped = [GXHUD cancelled];
        unsigned long long sz = dest ? [[FM() attributesOfItemAtPath:dest error:nil] fileSize] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (!dest) { GXAlert(vc, GXL(@"Ошибка"), GXL(@"Не удалось создать файл")); return; }
            UIAlertController *a = [UIAlertController alertControllerWithTitle:stopped ? GXL(@"Остановлено (сохранена часть)") : GXL(@"C-код восстановлен")
                message:[NSString stringWithFormat:GXL(@"%@ · %@\nПапка: GX Compiler/Восстановленный код\n\nЭто приблизительный код: по нему видно логику, но собрать его обратно как есть нельзя — правь и переписывай."), dest.lastPathComponent, GXHuman(sz)]
                preferredStyle:UIAlertControllerStyleActionSheet];
            [a addAction:[UIAlertAction actionWithTitle:GXL(@"Открыть и редактировать") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [GXOpener openText:dest from:vc readOnly:NO]; }]];
            [a addAction:[UIAlertAction actionWithTitle:GXL(@"Поделиться…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:dest]] applicationActivities:nil];
                av.popoverPresentationController.sourceView = vc.view; av.popoverPresentationController.sourceRect = vc.view.bounds;
                [vc presentViewController:av animated:YES completion:nil];
            }]];
            [a addAction:[UIAlertAction actionWithTitle:GXL(@"Показать в папке") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                [vc.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:dest.stringByDeletingLastPathComponent] animated:YES];
            }]];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            a.popoverPresentationController.sourceView = vc.view; a.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
            [vc presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark - Картинки внутри файла

@interface GXBinImg : NSObject
@property (nonatomic) size_t off, len;
@property (nonatomic) int type;
@end
@implementation GXBinImg @end

static NSArray<GXBinImg *> *GXFindImgs(GXBinDoc *doc) {
    gx_imghit *h; size_t n = gx_find_images(doc.data.bytes, doc.data.length, 64, &h);
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    for (size_t i = 0; i < n; i++) { GXBinImg *o = [GXBinImg new]; o.off = h[i].off; o.len = h[i].len; o.type = h[i].type; [a addObject:o]; }
    free(h);
    return a;
}

// Перекодировать картинку так, чтобы влезла в maxLen байт. type — формат оригинала. nil, если не получилось
static NSData *GXEncodeFit(UIImage *img, int type, size_t maxLen, CGSize target, NSString **info) {
    CGSize base = target.width > 0 ? target : CGSizeMake(img.size.width * img.scale, img.size.height * img.scale);
    BOOL jpeg = type == GX_IMG_JPEG;
    for (double sc = 1.0; sc >= 0.099; sc -= 0.1) {
        CGSize sz = CGSizeMake(MAX(1, round(base.width * sc)), MAX(1, round(base.height * sc)));
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.scale = 1; fmt.opaque = jpeg;
        UIImage *r = [[[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt] imageWithActions:^(UIGraphicsImageRendererContext *c) {
            if (jpeg) { [UIColor.whiteColor setFill]; UIRectFill(CGRectMake(0, 0, sz.width, sz.height)); }
            [img drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        }];
        NSArray *qs = jpeg ? @[@0.92, @0.8, @0.7, @0.6, @0.5, @0.4, @0.3] : @[@1];
        for (NSNumber *q in qs) {
            NSData *d = nil;
            if (jpeg) d = UIImageJPEGRepresentation(r, q.doubleValue);
            else if (type == GX_IMG_GIF) {
                NSMutableData *md = [NSMutableData data];
                CGImageDestinationRef dst = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)md, (__bridge CFStringRef)UTTypeGIF.identifier, 1, NULL);
                if (dst) { CGImageDestinationAddImage(dst, r.CGImage, NULL); CGImageDestinationFinalize(dst); CFRelease(dst); d = md; }
            } else d = UIImagePNGRepresentation(r);
            if (d && d.length <= maxLen) {
                if (info) *info = [NSString stringWithFormat:@"%@ %.0f×%.0f, %@%@%@", jpeg ? @"JPEG" : type == GX_IMG_GIF ? @"GIF" : @"PNG", sz.width, sz.height, GXHuman(d.length),
                                   sc < 0.99 ? [NSString stringWithFormat:GXL(@", уменьшено до %.0f%%"), sc * 100] : @"", jpeg && q.doubleValue < 0.9 ? [NSString stringWithFormat:GXL(@", качество %.0f%%"), q.doubleValue * 100] : @""];
                return d;
            }
        }
    }
    return nil;
}

@interface GXBinImageVC : UIViewController <UIScrollViewDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc img:(GXBinImg *)img;
@property (nonatomic, copy, nullable) void (^onChange)(void);
@end

@implementation GXBinImageVC {
    GXBinDoc *_doc; GXBinImg *_img; UIScrollView *_sv; UIImageView *_iv; UILabel *_info;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc img:(GXBinImg *)img { if ((self = [super init])) { _doc = doc; _img = img; } return self; }
- (NSData *)bytes { return [_doc.data subdataWithRange:NSMakeRange(_img.off, _img.len)]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithFormat:@"%s @ %@", gx_img_typename(_img.type), GXHex(_img.off)];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _sv = [UIScrollView new]; _sv.delegate = self; _sv.maximumZoomScale = 12; _sv.minimumZoomScale = 1;
    _sv.backgroundColor = UIColor.secondarySystemBackgroundColor;
    _iv = [UIImageView new]; _iv.contentMode = UIViewContentModeScaleAspectFit; _iv.layer.magnificationFilter = kCAFilterNearest;
    _info = [UILabel new]; _info.numberOfLines = 0; _info.font = [UIFont systemFontOfSize:13]; _info.textColor = UIColor.secondaryLabelColor; _info.textAlignment = NSTextAlignmentCenter;
    for (UIView *v in @[_sv, _info]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    [_sv addSubview:_iv];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_sv.topAnchor constraintEqualToAnchor:g.topAnchor], [_sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_info.topAnchor constraintEqualToAnchor:_sv.bottomAnchor constant:8], [_info.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12], [_info.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [_info.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],
    ]];
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *im, void (^b)(void)) { return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:im] identifier:nil handler:^(UIAction *x) { b(); }]; };
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[
        act(GXL(@"Заменить фото из галереи"), @"photo", ^{ [ws pickPhoto]; }),
        act(GXL(@"Заменить картинкой из файлов"), @"folder", ^{ [ws pickFile]; }),
        act(GXL(@"Сохранить картинку…"), @"square.and.arrow.up", ^{ [ws share]; }),
        act(GXL(@"Вернуть оригинал"), @"arrow.uturn.backward", ^{ [ws revert]; }),
    ]]];
    [self reload];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; if (_sv.zoomScale == 1) _iv.frame = _sv.bounds; }
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)s { return _iv; }
- (void)reload {
    UIImage *im = [UIImage imageWithData:[self bytes]];
    _iv.image = im;
    BOOL patched = [_doc isPatched:_img.off len:_img.len];
    _info.text = [NSString stringWithFormat:GXL(@"%s · %@ · место: %@ (смещение %@)%@\nЗаменить можно картинкой того же или меньшего размера в байтах — при необходимости GX Files сам сожмёт её.%@"),
                  gx_img_typename(_img.type), im ? [NSString stringWithFormat:@"%.0f×%.0f", im.size.width * im.scale, im.size.height * im.scale] : GXL(@"не открывается"),
                  GXHuman(_img.len), GXHex(_img.off), patched ? GXL(@" · ЗАМЕНЕНА") : @"", patched ? GXL(@"\nНе забудь «Сохранить» в редакторе.") : @""];
}
- (void)pickPhoto {
    PHPickerConfiguration *c = [PHPickerConfiguration new];
    c.filter = PHPickerFilter.imagesFilter; c.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:c];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *ip = results.firstObject.itemProvider;
    if (![ip canLoadObjectOfClass:UIImage.class]) return;
    [ip loadObjectOfClass:UIImage.class completionHandler:^(id obj, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ if ([obj isKindOfClass:UIImage.class]) [self replaceWith:obj]; else GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось загрузить фото")); });
    }];
}
- (void)pickFile {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    UIImage *im = [UIImage imageWithContentsOfFile:urls.firstObject.path];
    if (im) [self replaceWith:im]; else GXAlert(self, GXL(@"Ошибка"), GXL(@"Файл не открывается как картинка"));
}
- (void)replaceWith:(UIImage *)img {
    UIImage *orig = [UIImage imageWithData:[self bytes]];
    CGSize os = orig ? CGSizeMake(orig.size.width * orig.scale, orig.size.height * orig.scale) : CGSizeZero;
    CGSize ns = CGSizeMake(img.size.width * img.scale, img.size.height * img.scale);
    void (^go)(CGSize) = ^(CGSize target) { [self encodeAndWrite:img target:target]; };
    if (os.width > 0 && (fabs(os.width - ns.width) > 0.5 || fabs(os.height - ns.height) > 0.5)) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Размер картинки") message:[NSString stringWithFormat:GXL(@"Оригинал %.0f×%.0f, новая %.0f×%.0f. Приложение обычно рассчитано на размер оригинала."), os.width, os.height, ns.width, ns.height] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:GXL(@"Подогнать под %.0f×%.0f"), os.width, os.height] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { go(os); }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Оставить свой размер") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { go(CGSizeZero); }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    go(CGSizeZero);
}
- (void)encodeAndWrite:(UIImage *)img target:(CGSize)target {
    int type = _img.type;
    if (type == GX_IMG_WEBP) type = GX_IMG_PNG;   // WebP на iPhone не кодируется — будет PNG
    size_t maxLen = _img.len;
    [GXHUD showIn:self.view text:GXL(@"Подгонка картинки…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *info = nil;
        NSData *d = GXEncodeFit(img, type, maxLen, target, &info);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (!d) { GXAlert(self, GXL(@"Не влезает"), [NSString stringWithFormat:GXL(@"Даже уменьшенная до 10%% картинка больше места оригинала (%@). Возьми картинку попроще или меньше."), GXHuman(maxLen)]); return; }
            NSMutableData *buf = [d mutableCopy];
            buf.length = maxLen;   // остаток — нули: декодеры их игнорируют
            [self->_doc write:buf at:self->_img.off desc:[NSString stringWithFormat:GXL(@"Картинка %@: %s → %@"), GXHex(self->_img.off), gx_img_typename(self->_img.type), info]];
            [self reload];
            if (self.onChange) self.onChange();
            NSString *warn = self->_img.type == GX_IMG_WEBP ? GXL(@"\n\nОригинал был WebP, а iPhone не умеет сохранять WebP — записан PNG. Если приложение читает картинку своим декодером WebP, она может не показаться.") : @"";
            GXAlert(self, GXL(@"Картинка заменена"), [NSString stringWithFormat:GXL(@"%@ · занято %@ из %@.\nНажми «Сохранить» в редакторе, чтобы записать файл.%@"), info, GXHuman(d.length), GXHuman(maxLen), warn]);
        });
    });
}
- (void)revert {
    BOOL any = NO;
    for (NSMutableDictionary *p in _doc.patches.copy) {
        size_t o = [p[@"off"] unsignedLongLongValue], l = [p[@"new"] length];
        if (o < _img.off + _img.len && _img.off < o + l) { [_doc revert:p]; any = YES; }
    }
    [self reload];
    if (self.onChange) self.onChange();
    GXToast(self.view, any ? GXL(@"Оригинал возвращён") : GXL(@"Картинка не менялась"));
}
- (void)share {
    const char *ext = _img.type == GX_IMG_PNG ? "png" : _img.type == GX_IMG_JPEG ? "jpg" : _img.type == GX_IMG_GIF ? "gif" : "webp";
    NSString *p = [GXTempDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"image_%@.%s", GXHex(_img.off), ext]];
    UIImage *im = [UIImage imageWithData:[self bytes]];
    NSData *d = [self bytes];
    if ([_doc isPatched:_img.off len:_img.len] && im) d = UIImagePNGRepresentation(im), p = [p.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"];
    [d writeToFile:p atomically:YES];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:p]] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}
@end

@interface GXBinImagesVC : UICollectionViewController
- (instancetype)initWithDoc:(GXBinDoc *)doc;
@end

@implementation GXBinImagesVC {
    GXBinDoc *_doc; NSArray<GXBinImg *> *_imgs; NSCache *_thumbs;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc {
    UICollectionViewFlowLayout *l = [UICollectionViewFlowLayout new];
    l.itemSize = CGSizeMake(104, 130); l.minimumInteritemSpacing = 8; l.minimumLineSpacing = 12; l.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);
    if ((self = [super initWithCollectionViewLayout:l])) { _doc = doc; _thumbs = [NSCache new]; self.title = GXL(@"Картинки"); }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
    [self.collectionView registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"c"];
    _imgs = @[];
    [self rescan];
}
- (void)rescan {
    [GXHUD showIn:self.view text:GXL(@"Поиск картинок…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *a = GXFindImgs(self->_doc);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            self->_imgs = a;
            [self->_thumbs removeAllObjects];
            self.title = [NSString stringWithFormat:GXL(@"Картинки (%lu)"), (unsigned long)a.count];
            [self.collectionView reloadData];
            if (!a.count) GXToast(self.view, GXL(@"Встроенных PNG/JPEG/GIF/WebP не найдено"));
        });
    });
}
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return _imgs.count; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:ip];
    UIImageView *iv = [c.contentView viewWithTag:1];
    UILabel *lb = [c.contentView viewWithTag:2];
    if (!iv) {
        iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 104, 96)]; iv.tag = 1; iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.backgroundColor = UIColor.secondarySystemBackgroundColor; iv.layer.cornerRadius = 8; iv.clipsToBounds = YES;
        lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 98, 104, 32)]; lb.tag = 2; lb.numberOfLines = 2; lb.font = [UIFont systemFontOfSize:10]; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.secondaryLabelColor;
        [c.contentView addSubview:iv]; [c.contentView addSubview:lb];
    }
    GXBinImg *m = _imgs[ip.item];
    BOOL patched = [_doc isPatched:m.off len:m.len];
    lb.text = [NSString stringWithFormat:@"%s · %@%@\n%@", gx_img_typename(m.type), GXHuman(m.len), patched ? @" ✎" : @"", GXHex(m.off)];
    NSString *key = [NSString stringWithFormat:@"%zu-%d", m.off, patched];
    UIImage *t = [_thumbs objectForKey:key];
    iv.image = t;
    if (!t) {
        NSData *d = [_doc.data subdataWithRange:NSMakeRange(m.off, m.len)];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            UIImage *im = [UIImage imageWithData:d];
            UIImage *th = im ? GXSquareImage(im, 96, 0) : [UIImage systemImageNamed:@"exclamationmark.triangle"];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (th) [self->_thumbs setObject:th forKey:key];
                UICollectionViewCell *cc = [cv cellForItemAtIndexPath:ip];
                ((UIImageView *)[cc.contentView viewWithTag:1]).image = th;
            });
        });
    }
    return c;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    GXBinImageVC *v = [[GXBinImageVC alloc] initWithDoc:_doc img:_imgs[ip.item]];
    __weak typeof(self) ws = self;
    v.onChange = ^{ [ws.collectionView reloadData]; };
    [self.navigationController pushViewController:v animated:YES];
}
@end

#pragma mark - Дизайн меню (ImGui и др.)

static NSData *GXRGBA(const float f[4]) { return [NSData dataWithBytes:f length:16]; }
static UIColor *GXColorF(const float f[4]) { return [UIColor colorWithRed:f[0] green:f[1] blue:f[2] alpha:f[3]]; }
static void GXRevertRange(GXBinDoc *doc, size_t off, size_t len) {
    for (NSMutableDictionary *p in doc.patches.copy) {
        size_t o = [p[@"off"] unsignedLongLongValue], l = [p[@"new"] length];
        if (o < off + len && off < o + l) [doc revert:p];
    }
}
static UIImage *GXSwatch(UIColor *c, CGFloat side) {
    UIGraphicsImageRendererFormat *fm = [UIGraphicsImageRendererFormat preferredFormat];
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fm] imageWithActions:^(UIGraphicsImageRendererContext *x) {
        CGRect r = CGRectMake(0.5, 0.5, side - 1, side - 1);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:6];
        [p addClip];
        // шахматка под прозрачным цветом
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {
            [((i + j) & 1 ? UIColor.whiteColor : UIColor.lightGrayColor) setFill];
            UIRectFill(CGRectMake(i * side / 4, j * side / 4, side / 4, side / 4));
        }
        [c setFill]; UIRectFillUsingBlendMode(r, kCGBlendModeNormal);
        [UIColor.separatorColor setStroke]; p.lineWidth = 1; [p stroke];
    }];
}

@interface GXBinFontVC : UIViewController <UIDocumentPickerDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc font:(gx_font)f;
@property (nonatomic, copy, nullable) void (^onChange)(void);
@end
@implementation GXBinFontVC { GXBinDoc *_doc; gx_font _f; UITextView *_tv; }
- (instancetype)initWithDoc:(GXBinDoc *)doc font:(gx_font)f { if ((self = [super init])) { _doc = doc; _f = f; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [NSString stringWithUTF8String:_f.name] ?: GXL(@"Шрифт");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [UITextView new]; _tv.editable = NO; _tv.translatesAutoresizingMaskIntoConstraints = NO;
    _tv.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
    [self.view addSubview:_tv];
    [NSLayoutConstraint activateConstraints:@[[_tv.topAnchor constraintEqualToAnchor:self.view.topAnchor], [_tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *im, void (^b)(void)) { return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:im] identifier:nil handler:^(UIAction *x) { b(); }]; };
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[
        act(GXL(@"Заменить шрифтом из файлов (.ttf/.otf)"), @"folder", ^{ [ws pick]; }),
        act(GXL(@"Сохранить шрифт как файл…"), @"square.and.arrow.up", ^{ [ws share]; }),
        act(GXL(@"Вернуть оригинал"), @"arrow.uturn.backward", ^{ [ws revert]; }),
    ]]];
    [self reload];
}
- (NSData *)bytes { return [_doc.data subdataWithRange:NSMakeRange(_f.off, _f.len)]; }
+ (UIFont *)fontFrom:(NSData *)d size:(CGFloat)sz {
    CGDataProviderRef pr = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
    CGFontRef cg = pr ? CGFontCreateWithDataProvider(pr) : NULL;
    if (pr) CGDataProviderRelease(pr);
    if (!cg) return nil;
    CTFontRef ct = CTFontCreateWithGraphicsFont(cg, sz, NULL, NULL);
    CGFontRelease(cg);
    return ct ? (__bridge_transfer UIFont *)ct : nil;
}
- (void)reload {
    BOOL patched = [_doc isPatched:_f.off len:_f.len];
    NSMutableAttributedString *s = [NSMutableAttributedString new];
    NSDictionary *meta = @{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: UIColor.secondaryLabelColor};
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:GXL(@"%@ · место %@ · смещение %@%@\nЗаменить можно любым TTF/OTF не больше этого места. Кириллица появится, только если она есть в новом шрифте и программа загружает нужные символы.\n\n"),
        _f.otf ? @"OpenType (CFF)" : @"TrueType", GXHuman(_f.len), GXHex(_f.off), patched ? GXL(@" · ЗАМЕНЁН — не забудь «Сохранить»") : @""] attributes:meta]];
    for (NSNumber *sz in @[@34, @22, @16]) {
        UIFont *f = [GXBinFontVC fontFrom:[self bytes] size:sz.doubleValue];
        if (!f) { [s appendAttributedString:[[NSAttributedString alloc] initWithString:GXL(@"Шрифт не открывается для предпросмотра\n") attributes:meta]]; break; }
        [s appendAttributedString:[[NSAttributedString alloc] initWithString:GXL(@"Menu Settings 0123456789\nМеню Настройки Привет\n\n") attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.labelColor}]];
    }
    _tv.attributedText = s;
}
- (void)pick {
    NSMutableArray *types = [NSMutableArray arrayWithObject:UTTypeFont];
    UTType *t;
    if ((t = [UTType typeWithFilenameExtension:@"ttf"])) [types addObject:t];
    if ((t = [UTType typeWithFilenameExtension:@"otf"])) [types addObject:t];
    [types addObject:UTTypeData];
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *d = [NSData dataWithContentsOfURL:urls.firstObject];
    gx_font *ff = NULL;
    size_t n = d.length ? gx_find_fonts(d.bytes, d.length, &ff) : 0;
    BOOL ok = n && ff[0].off == 0;
    free(ff);
    if (!ok || ![GXBinFontVC fontFrom:d size:12]) { GXAlert(self, GXL(@"Не шрифт"), GXL(@"Нужен файл TrueType (.ttf) или OpenType (.otf). Коллекции .ttc и WOFF не подходят.")); return; }
    if (d.length > _f.len) { GXAlert(self, GXL(@"Не влезает"), [NSString stringWithFormat:GXL(@"Новый шрифт %@, а места только %@. Возьми шрифт поменьше (или его урезанную версию — без лишних языков)."), GXHuman(d.length), GXHuman(_f.len)]); return; }
    NSMutableData *buf = d.mutableCopy; buf.length = _f.len;
    [_doc write:buf at:_f.off desc:[NSString stringWithFormat:GXL(@"Шрифт %@ → %@ (%@)"), self.title, urls.firstObject.lastPathComponent, GXHuman(d.length)]];
    [self reload];
    if (self.onChange) self.onChange();
    GXToast(self.view, GXL(@"Шрифт заменён. Нажми «Сохранить» в редакторе"));
}
- (void)share {
    NSString *p = [GXTempDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", [GXBinDoc safeName:self.title], _f.otf ? @"otf" : @"ttf"]];
    [[self bytes] writeToFile:p atomically:YES];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:p]] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}
- (void)revert { GXRevertRange(_doc, _f.off, _f.len); [self reload]; if (self.onChange) self.onChange(); GXToast(self.view, GXL(@"Оригинал возвращён")); }
@end

@interface GXBinDesignVC : UITableViewController <UIColorPickerViewControllerDelegate>
- (instancetype)initWithDoc:(GXBinDoc *)doc;
@end

@implementation GXBinDesignVC {
    GXBinDoc *_doc; gx_color *_c; size_t _nc; gx_font *_f; size_t _nf; NSString *_kind; size_t _editing; BOOL _loaded, _accent;
}
- (instancetype)initWithDoc:(GXBinDoc *)doc { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _doc = doc; self.title = GXL(@"Дизайн меню"); } return self; }
- (void)dealloc { free(_c); free(_f); }
static BOOL GXHas(NSData *d, const char *s) { return memmem(d.bytes, d.length, s, strlen(s)) != NULL; }
- (void)viewDidLoad {
    [super viewDidLoad];
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *im, void (^b)(void)) { return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:im] identifier:nil handler:^(UIAction *x) { b(); }]; };
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"paintpalette"] menu:[UIMenu menuWithTitle:GXL(@"Перекрасить все цвета") children:@[
        act(GXL(@"Сдвинуть оттенок…"), @"dial.medium", ^{ [ws askHue]; }),
        act(GXL(@"Один цвет-акцент для всех ярких…"), @"eyedropper", ^{ [ws pickAccent]; }),
        act(GXL(@"Светлее на 15%"), @"sun.max", ^{ [ws bulk:1]; }),
        act(GXL(@"Темнее на 15%"), @"moon", ^{ [ws bulk:2]; }),
        act(GXL(@"Инвертировать (тёмная ↔ светлая тема)"), @"circle.lefthalf.filled", ^{ [ws bulk:3]; }),
        act(GXL(@"Прозрачнее фон (−15% альфы)"), @"square.on.square.dashed", ^{ [ws bulk:4]; }),
        act(GXL(@"Плотнее (альфа = 100%)"), @"square.fill", ^{ [ws bulk:5]; }),
        act(GXL(@"Вернуть все цвета"), @"arrow.uturn.backward", ^{ [ws revertAll]; }),
    ]]];
    [GXHUD showIn:self.view text:GXL(@"Поиск цветов и шрифтов…")];
    GXBinDoc *doc = _doc;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        gx_color *c = NULL; gx_font *f = NULL;
        size_t nc = gx_find_colors(&doc->bin, &c);
        size_t nf = gx_find_fonts(doc.data.bytes, doc.data.length, &f);
        NSData *d = doc.data;
        NSString *k = nil;
        if (GXHas(d, "imgui.ini") || GXHas(d, "Dear ImGui") || GXHas(d, "ImGuiWindow") || GXHas(d, "##")) k = @"Dear ImGui";
        else if (GXHas(d, "nk_") && GXHas(d, "nuklear")) k = @"Nuklear";
        else if (GXHas(d, "UIButton") || GXHas(d, "UILabel")) k = @"UIKit";
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            self->_c = c; self->_nc = nc; self->_f = f; self->_nf = nf; self->_kind = k; self->_loaded = YES;
            [self.tableView reloadData];
        });
    });
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; if (_loaded) [self.tableView reloadData]; }
- (void)cur:(size_t)i rgba:(float *)f { memcpy(f, (const uint8_t *)_doc.data.bytes + _c[i].off, 16); }
- (void)setColor:(size_t)i rgba:(const float *)f desc:(NSString *)d {
    float o[4]; [self cur:i rgba:o];
    [_doc write:GXRGBA(f) at:_c[i].off desc:d ?: [NSString stringWithFormat:GXL(@"Цвет %@: (%.2f %.2f %.2f %.2f) → (%.2f %.2f %.2f %.2f)"), GXHex(_c[i].addr), o[0], o[1], o[2], o[3], f[0], f[1], f[2], f[3]]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (!_loaded) return 0;
    if (s == 0) return 1;
    if (s == 1) return 3;
    if (s == 2) return _nc ? (NSInteger)_nc : 1;
    return _nf ? (NSInteger)_nf : 1;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (!_loaded) return nil;
    return s == 1 ? GXL(@"Что ещё меняется") : s == 2 ? [NSString stringWithFormat:GXL(@"Цвета (%zu)"), _nc] : s == 3 ? [NSString stringWithFormat:GXL(@"Шрифты (%zu)"), _nf] : nil;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (!_loaded) return nil;
    if (s == 2) return GXL(@"Цвета — четвёрки float (R, G, B, альфа), которые код загружает целиком: так компилятор хранит ImVec4/цвета стиля. «код ×N» — сколько мест их читают, «таблица» — массив цветов в данных. Один цвет может использоваться в нескольких местах меню. Цвета, собранные из отдельных чисел, ищи в «Числах» (float).");
    if (s == 3) return GXL(@"Встроенные TTF/OTF. Стандартный шрифт ImGui (ProggyClean) хранится в сжатом виде и здесь не виден — заменяется только перекомпиляцией.");
    if (s == 1) return GXL(@"Расположение окон, новые кнопки и пункты задаются кодом, а не данными: в готовом файле их не перестроить. Для этого нужен исходник — его можно собрать во встроенном компиляторе C → dylib.");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 0;
    if (ip.section == 0) {
        c.textLabel.text = _kind ? [NSString stringWithFormat:GXL(@"Похоже на меню: %@"), _kind] : GXL(@"Тип меню не определён");
        c.detailTextLabel.text = [_kind isEqualToString:@"Dear ImGui"] ? GXL(@"Можно менять: тексты и заголовки, цвета темы, скругления/отступы/прозрачность (float в «Числах»), шрифты и картинки.") : GXL(@"Можно менять тексты, цвета, числа, шрифты и картинки, если они есть в файле.");
        c.imageView.image = [UIImage systemImageNamed:@"menucard"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    if (ip.section == 1) {
        NSArray *t = @[GXL(@"Тексты и надписи"), GXL(@"Размеры, скругления, отступы"), GXL(@"Картинки и иконки")];
        NSArray *d = @[GXL(@"Заголовки окон, кнопки, подсказки — правка на месте"), GXL(@"Числа float: например WindowRounding 12.0 → 4.0"), GXL(@"PNG/JPEG/GIF/WebP — замена своей")];
        NSArray *im = @[@"textformat", @"ruler", @"photo.on.rectangle"];
        c.textLabel.text = t[ip.row]; c.detailTextLabel.text = d[ip.row]; c.imageView.image = [UIImage systemImageNamed:im[ip.row]];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (ip.section == 2) {
        if (!_nc) { c.textLabel.text = _doc->bin.arm64 ? GXL(@"Цвета не найдены") : GXL(@"Поиск цветов — только для arm64"); c.selectionStyle = UITableViewCellSelectionStyleNone; return c; }
        float f[4]; [self cur:ip.row rgba:f];
        BOOL patched = [_doc isPatched:_c[ip.row].off len:16];
        c.imageView.image = GXSwatch(GXColorF(f), 36);
        c.textLabel.text = [NSString stringWithFormat:@"#%02X%02X%02X · α %.0f%%%@", (int)lroundf(f[0] * 255), (int)lroundf(f[1] * 255), (int)lroundf(f[2] * 255), f[3] * 100, patched ? @"  ✎" : @""];
        c.textLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
        c.detailTextLabel.text = [NSString stringWithFormat:@"(%.3g, %.3g, %.3g, %.3g) · %@ · %@", f[0], f[1], f[2], f[3], _c[ip.row].refs ? [NSString stringWithFormat:GXL(@"код ×%d"), _c[ip.row].refs] : GXL(@"таблица"), GXHex(_c[ip.row].addr)];
        c.detailTextLabel.font = GXMono(11);
        return c;
    }
    if (!_nf) { c.textLabel.text = GXL(@"Встроенных шрифтов нет"); c.selectionStyle = UITableViewCellSelectionStyleNone; return c; }
    c.textLabel.text = [NSString stringWithUTF8String:_f[ip.row].name] ?: GXL(@"Шрифт");
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@%@", _f[ip.row].otf ? @"OTF" : @"TTF", GXHuman(_f[ip.row].len), GXHex(_f[ip.row].off), [_doc isPatched:_f[ip.row].off len:_f[ip.row].len] ? GXL(@" · заменён") : @""];
    c.imageView.image = [UIImage systemImageNamed:@"textformat.size"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UINavigationController *nav = self.navigationController;
    if (ip.section == 1) {
        if (ip.row == 0) [nav pushViewController:[[GXBinStringsVC alloc] initWithDoc:_doc] animated:YES];
        else if (ip.row == 1) [nav pushViewController:[[GXBinNumbersVC alloc] initWithDoc:_doc] animated:YES];
        else [nav pushViewController:[[GXBinImagesVC alloc] initWithDoc:_doc] animated:YES];
        return;
    }
    if (ip.section == 2 && _nc) {
        _editing = ip.row;
        float f[4]; [self cur:ip.row rgba:f];
        UIColorPickerViewController *p = [UIColorPickerViewController new];
        p.supportsAlpha = YES;
        p.selectedColor = GXColorF(f);
        p.title = [NSString stringWithFormat:GXL(@"Цвет %@"), GXHex(_c[ip.row].addr)];
        p.delegate = self;
        [self presentViewController:p animated:YES completion:nil];
        return;
    }
    if (ip.section == 3 && _nf) {
        GXBinFontVC *v = [[GXBinFontVC alloc] initWithDoc:_doc font:_f[ip.row]];
        __weak typeof(self) ws = self;
        v.onChange = ^{ [ws.tableView reloadData]; };
        [nav pushViewController:v animated:YES];
    }
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    if (ip.section != 2 || !_nc) return nil;
    size_t i = ip.row;
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        GXBinDesignVC *me = ws;
        if (!me) return nil;
        NSMutableArray *a = [NSMutableArray array];
        [a addObject:[UIAction actionWithTitle:GXL(@"Ввести числа R G B A…") image:[UIImage systemImageNamed:@"keyboard"] identifier:nil handler:^(UIAction *x) { [ws askNumbers:i]; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Ввести HEX (#RRGGBBAA)…") image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(UIAction *x) { [ws askHex:i]; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Где используется") image:[UIImage systemImageNamed:@"arrow.triangle.branch"] identifier:nil handler:^(UIAction *x) {
            GXBinDesignVC *m = ws; if (!m) return;
            [m.navigationController pushViewController:[[GXBinXrefsVC alloc] initWithDoc:m->_doc lo:m->_c[i].addr hi:m->_c[i].addr + 16 title:GXL(@"Где используется цвет")] animated:YES];
        }]];
        if ([me->_doc isPatched:me->_c[i].off len:16]) [a addObject:[UIAction actionWithTitle:GXL(@"Вернуть оригинал") image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *x) {
            GXBinDesignVC *m = ws; if (!m) return; GXRevertRange(m->_doc, m->_c[i].off, 16); [m.tableView reloadData];
        }]];
        return [UIMenu menuWithChildren:a];
    }];
}
- (void)applyPicked:(UIColor *)col {
    CGFloat r = 0, g = 0, b = 0, al = 1;
    if (![col getRed:&r green:&g blue:&b alpha:&al]) return;
    float f[4] = {(float)MIN(1, MAX(0, r)), (float)MIN(1, MAX(0, g)), (float)MIN(1, MAX(0, b)), (float)MIN(1, MAX(0, al))};
    [self setColor:_editing rgba:f desc:nil];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:_editing inSection:2]] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)colorPickerViewController:(UIColorPickerViewController *)vc didSelectColor:(UIColor *)color continuously:(BOOL)cont { if (!cont && !_accent) [self applyPicked:color]; }
- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)vc {
    if (_accent) { _accent = NO; [self apply:7 arg:0 col:vc.selectedColor]; return; }
    [self applyPicked:vc.selectedColor];
}
- (void)askNumbers:(size_t)i {
    float f[4]; [self cur:i rgba:f];
    GXPrompt(self, GXL(@"Цвет"), GXL(@"Четыре числа от 0 до 1 через пробел: R G B A"), [NSString stringWithFormat:@"%.3g %.3g %.3g %.3g", f[0], f[1], f[2], f[3]], @"0.1 0.1 0.1 1", GXL(@"Записать"), ^(NSString *v) {
        NSArray *p = [[v stringByReplacingOccurrencesOfString:@"," withString:@"."] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        float n[4]; int k = 0;
        for (NSString *x in p) if (x.length && k < 4) n[k++] = (float)MIN(1, MAX(0, x.doubleValue));
        if (k != 4) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Нужно ровно 4 числа")); return; }
        [self setColor:i rgba:n desc:nil];
        [self.tableView reloadData];
    });
}
- (void)askHex:(size_t)i {
    float f[4]; [self cur:i rgba:f];
    GXPrompt(self, GXL(@"Цвет HEX"), GXL(@"#RRGGBB или #RRGGBBAA"), [NSString stringWithFormat:@"#%02X%02X%02X%02X", (int)lroundf(f[0] * 255), (int)lroundf(f[1] * 255), (int)lroundf(f[2] * 255), (int)lroundf(f[3] * 255)], @"#7A1FCCFF", GXL(@"Записать"), ^(NSString *v) {
        NSString *h = [[v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] stringByReplacingOccurrencesOfString:@"#" withString:@""];
        unsigned long long x = 0;
        if ((h.length != 6 && h.length != 8) || ![[NSScanner scannerWithString:h] scanHexLongLong:&x]) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Пример: #7A1FCC или #7A1FCCF0")); return; }
        if (h.length == 6) x = (x << 8) | 0xFF;
        float n[4] = {((x >> 24) & 255) / 255.0f, ((x >> 16) & 255) / 255.0f, ((x >> 8) & 255) / 255.0f, (x & 255) / 255.0f};
        [self setColor:i rgba:n desc:nil];
        [self.tableView reloadData];
    });
}
// mode: 1 светлее, 2 темнее, 3 инверсия яркости, 4 прозрачнее, 5 плотнее, 6 сдвиг оттенка (arg), 7 акцент (col)
- (void)apply:(int)mode arg:(double)arg col:(UIColor *)acc {
    CGFloat ah = 0, as = 0;
    if (acc) [acc getHue:&ah saturation:&as brightness:NULL alpha:NULL];
    int changed = 0;
    for (size_t i = 0; i < _nc; i++) {
        float f[4]; [self cur:i rgba:f];
        float n[4] = {f[0], f[1], f[2], f[3]};
        if (mode == 1 || mode == 2) { float k = mode == 1 ? 0.15f : -0.15f; for (int j = 0; j < 3; j++) n[j] = k > 0 ? f[j] + (1 - f[j]) * k : f[j] * (1 + k); }
        else if (mode == 3) {
            // инвертируем яркость, сохраняя оттенок
            CGFloat h, s, v, a; [GXColorF(f) getHue:&h saturation:&s brightness:&v alpha:&a];
            UIColor *c = [UIColor colorWithHue:h saturation:s brightness:1 - v alpha:a];
            CGFloat r, g, b; [c getRed:&r green:&g blue:&b alpha:NULL]; n[0] = r; n[1] = g; n[2] = b;
        }
        else if (mode == 4) n[3] = f[3] * 0.85f;
        else if (mode == 5) n[3] = 1;
        else if (mode == 6 || mode == 7) {
            CGFloat h, s, v, a; [GXColorF(f) getHue:&h saturation:&s brightness:&v alpha:&a];
            if (s < 0.12) continue;                         // серые/чёрные/белые не трогаем
            if (mode == 6) { h = fmod(h + arg / 360.0 + 1.0, 1.0); }
            else { h = ah; s = as; }
            UIColor *c = [UIColor colorWithHue:h saturation:s brightness:v alpha:a];
            CGFloat r, g, b; [c getRed:&r green:&g blue:&b alpha:NULL]; n[0] = r; n[1] = g; n[2] = b;
        }
        for (int j = 0; j < 4; j++) n[j] = MIN(1, MAX(0, n[j]));
        if (memcmp(n, f, 16)) { [self setColor:i rgba:n desc:nil]; changed++; }
    }
    [self.tableView reloadData];
    GXToast(self.view, changed ? [NSString stringWithFormat:GXL(@"Изменено цветов: %d. Не забудь «Сохранить»"), changed] : GXL(@"Нечего менять"));
}
- (void)bulk:(int)m { if (!_nc) { GXToast(self.view, GXL(@"Цветов нет")); return; } [self apply:m arg:0 col:nil]; }
- (void)askHue {
    if (!_nc) { GXToast(self.view, GXL(@"Цветов нет")); return; }
    GXPrompt(self, GXL(@"Сдвиг оттенка"), GXL(@"Градусы от −180 до 180. Например 120: синие станут зелёными, 180 — противоположный цвет. Серые не меняются."), @"120", @"120", GXL(@"Применить"), ^(NSString *v) { [self apply:6 arg:v.doubleValue col:nil]; });
}
- (void)pickAccent {
    if (!_nc) { GXToast(self.view, GXL(@"Цветов нет")); return; }
    _accent = YES;
    UIColorPickerViewController *p = [UIColorPickerViewController new];
    p.supportsAlpha = NO; p.title = GXL(@"Новый акцент (для всех цветных)"); p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)revertAll {
    for (size_t i = 0; i < _nc; i++) GXRevertRange(_doc, _c[i].off, 16);
    [self.tableView reloadData];
    GXToast(self.view, GXL(@"Цвета возвращены"));
}
@end

#pragma mark - Главный экран

@implementation GXBinEditorVC {
    GXBinDoc *_doc;
}
- (instancetype)initWithPath:(NSString *)path { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _doc = [[GXBinDoc alloc] initWithPath:path]; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _doc.path.lastPathComponent;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Сохранить") style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    if (_doc->bin.encrypted) dispatch_async(dispatch_get_main_queue(), ^{
        GXAlert(self, GXL(@"Бинарник зашифрован"), GXL(@"Это файл из App Store с шифрованием FairPlay (cryptid ≠ 0): код и часть строк выглядят как мусор. Нужна расшифрованная версия (decrypted IPA)."));
    });
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.tableView reloadData]; }
- (void)close {
    if (_doc.dirty) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Есть несохранённые изменения") message:[NSString stringWithFormat:GXL(@"Изменений: %lu"), (unsigned long)_doc.patches.count] preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Сохранить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { if ([self doSave]) [self dismissViewControllerAnimated:YES completion:nil]; }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Выйти без сохранения") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { [self dismissViewControllerAnimated:YES completion:nil]; }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (BOOL)doSave {
    NSUInteger n = _doc.patches.count;
    NSString *e = [_doc save];
    if (e) { GXAlert(self, GXL(@"Не сохранено"), e); return NO; }
    GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено изменений: %lu.%@"), (unsigned long)n, _doc.lastNote ?: @""]);
    [self.tableView reloadData];
    return YES;
}
- (void)save {
    if (!_doc.dirty) { GXToast(self.view, GXL(@"Изменений нет")); return; }
    [self doSave];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return _doc.nslices > 1 ? 2 : 1;
    if (s == 1) return 10;
    return 5;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1) return GXL(@"Строки — тексты, правка на месте. Классы — заголовки Objective-C. Функции — псевдокод на C и ассемблер ARM64 с патчами. «Восстановить C-код» сохраняет весь псевдокод в редактируемый файл. «Картинки» — встроенные PNG/JPEG/GIF/WebP: просмотр и замена. «Дизайн меню» — цвета темы (ImGui и др.), шрифты, перекраска всего меню разом.");
    if (s == 2) return _doc->bin.fmt == 1 ? GXL(@"После правки Mach-O подпись становится недействительной — переподпись ad-hoc чинит это (entitlements сохраняются). Если LiveContainer не запустит приложение, переподпиши его в LiveContainer. Оригинал сохраняется рядом как .orig.") : GXL(@"Оригинал сохраняется рядом как .orig.");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    gx_bin *b = &_doc->bin;
    if (ip.section == 0 && ip.row == 0) {
        UITableViewCell *s = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        s.textLabel.text = [NSString stringWithFormat:@"%s · %s", b->type, b->arch];
        s.detailTextLabel.text = [NSString stringWithFormat:GXL(@"%@ · подпись: %@%@%@"), GXHuman(_doc.data.length), [_doc sigState], b->encrypted ? GXL(@" · ЗАШИФРОВАН") : @"", b->fmt == 0 ? GXL(@"\nФормат не распознан — доступны строки и числа по всему файлу") : @""];
        s.detailTextLabel.numberOfLines = 0;
        s.imageView.image = [UIImage systemImageNamed:@"cpu"];
        s.selectionStyle = UITableViewCellSelectionStyleNone;
        return s;
    }
    if (ip.section == 0) { c.textLabel.text = GXL(@"Срез (архитектура)"); c.detailTextLabel.text = _doc.sliceNames[_doc.slice]; c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c; }
    if (ip.section == 1) {
        NSArray *t = @[GXL(@"Строки и тексты"), GXL(@"Классы Objective-C (.h)"), GXL(@"Функции: псевдокод и ассемблер"), GXL(@"Восстановить C-код всего файла"), GXL(@"Картинки внутри файла"), GXL(@"Дизайн меню: цвета, шрифты (ImGui и др.)"), GXL(@"Числа и константы"), GXL(@"Импорты"), GXL(@"Перейти по адресу"), GXL(@"Изменения")];
        NSArray *im = @[@"textformat", @"c.square", @"chevron.left.forwardslash.chevron.right", @"square.and.pencil", @"photo.on.rectangle", @"paintpalette", @"number", @"arrow.down.right.and.arrow.up.left", @"location", @"clock.arrow.circlepath"];
        c.textLabel.text = t[ip.row];
        c.imageView.image = [UIImage systemImageNamed:im[ip.row]];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (ip.row == 1) c.detailTextLabel.text = b->fmt != 1 ? GXL(@"только Mach-O") : (_doc.objcLoaded ? [NSString stringWithFormat:@"%d", _doc->_ncls] : nil);
        if (ip.row == 2) c.detailTextLabel.text = b->arm64 ? [NSString stringWithFormat:@"%zu", b->nfn] : GXL(@"только arm64");
        if (ip.row == 3) c.detailTextLabel.text = b->arm64 ? GXL(@".c файл") : GXL(@"только arm64");
        if (ip.row == 7) c.detailTextLabel.text = [NSString stringWithFormat:@"%zu", b->nimp];
        if (ip.row == 9) c.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)_doc.patches.count];
        if (_doc.strings && ip.row == 0) c.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)_doc.strings.count];
        return c;
    }
    switch (ip.row) {
        case 0: {
            c.textLabel.text = GXL(@"Переподписать при сохранении");
            UISwitch *sw = [UISwitch new];
            sw.on = _doc.resign && b->fmt == 1;
            sw.enabled = b->fmt == 1;
            [sw addTarget:self action:@selector(resignChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case 1: c.textLabel.text = GXL(@"Сохранить"); c.textLabel.textColor = tv.tintColor; c.detailTextLabel.text = _doc.dirty ? [NSString stringWithFormat:GXL(@"%lu изм."), (unsigned long)_doc.patches.count] : nil; break;
        case 2: c.textLabel.text = b->fmt == 2 ? GXL(@"Сведения ELF") : GXL(@"Сведения Mach-O (команды, библиотеки)"); c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; break;
        case 3: c.textLabel.text = GXL(@"Открыть в hex-редакторе"); c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; break;
        case 4: c.textLabel.text = GXL(@"Сохранить все заголовки .h рядом"); c.textLabel.textColor = b->fmt == 1 ? tv.tintColor : UIColor.secondaryLabelColor; break;
    }
    return c;
}
- (void)resignChanged:(UISwitch *)s { _doc.resign = s.on; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UINavigationController *nav = self.navigationController;
    gx_bin *b = &_doc->bin;
    if (ip.section == 0 && ip.row == 1) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Срез") message:GXL(@"Изменения делаются в выбранном срезе. Несохранённые правки останутся в файле.") preferredStyle:UIAlertControllerStyleActionSheet];
        for (int i = 0; i < _doc.nslices; i++) [a addAction:[UIAlertAction actionWithTitle:_doc.sliceNames[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { self->_doc.slice = i; [self->_doc reopen]; [tv reloadData]; }]];
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip] ?: tv;
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (ip.section == 1) {
        switch (ip.row) {
            case 0: [nav pushViewController:[[GXBinStringsVC alloc] initWithDoc:_doc] animated:YES]; break;
            case 1: if (b->fmt != 1) { GXAlert(self, GXL(@"Только Mach-O"), GXL(@"Классы Objective-C бывают только в iOS/macOS бинарниках. Для .so используй «Функции» — там есть псевдокод.")); break; } [nav pushViewController:[[GXBinClassesVC alloc] initWithDoc:_doc] animated:YES]; break;
            case 2: if (!b->arm64) { GXAlert(self, GXL(@"Только arm64"), GXL(@"Дизассемблер работает с arm64 (iPhone и Android arm64-v8a).")); break; } [nav pushViewController:[[GXBinFuncsVC alloc] initWithDoc:_doc imports:NO] animated:YES]; break;
            case 3: GXRunDecompile(self, _doc, -1); break;
            case 4: [nav pushViewController:[[GXBinImagesVC alloc] initWithDoc:_doc] animated:YES]; break;
            case 5: [nav pushViewController:[[GXBinDesignVC alloc] initWithDoc:_doc] animated:YES]; break;
            case 6: [nav pushViewController:[[GXBinNumbersVC alloc] initWithDoc:_doc] animated:YES]; break;
            case 7: [nav pushViewController:[[GXBinFuncsVC alloc] initWithDoc:_doc imports:YES] animated:YES]; break;
            case 8: [self gotoAddr]; break;
            case 9: [nav pushViewController:[[GXBinPatchesVC alloc] initWithDoc:_doc] animated:YES]; break;
        }
        return;
    }
    if (ip.row == 1) [self save];
    else if (ip.row == 2) {
        if (_doc.dirty) { GXAlert(self, GXL(@"Сначала сохрани"), GXL(@"Сведения читаются с диска.")); return; }
        [nav pushViewController:[[GXReportVC alloc] initWithTitle:_doc.path.lastPathComponent text:b->fmt == 2 ? GXELFReport(_doc.path) : GXMachOReport(_doc.path)] animated:YES];
    } else if (ip.row == 3) {
        if (_doc.dirty) { GXAlert(self, GXL(@"Сначала сохрани"), GXL(@"Hex-редактор работает с файлом на диске, а у тебя есть несохранённые изменения.")); return; }
        GXHexVC *h = [[GXHexVC alloc] initWithPath:_doc.path];
        [nav pushViewController:h animated:YES];
    } else if (ip.row == 4 && b->fmt == 1) {
        GXBinDoc *doc = _doc;
        GXRunBG(self, GXL(@"Сборка заголовков…"), ^NSString *{
            NSString *t = [doc allHeaders];
            NSString *dest = GXUniquePath(doc.path.stringByDeletingLastPathComponent, [doc.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@"-headers.h"]);
            NSError *e = nil;
            if (![t writeToFile:dest atomically:YES encoding:NSUTF8StringEncoding error:&e]) return e.localizedDescription ?: GXL(@"Не удалось записать");
            dispatch_async(dispatch_get_main_queue(), ^{ GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено: %@"), dest.lastPathComponent]); });
            return nil;
        }, nil);
    }
}
- (void)gotoAddr {
    GXPrompt(self, GXL(@"Перейти"), GXL(@"Адрес (например 0x1a2b3c) или смещение в файле с «+» (например +0x4000). Для .so адреса = смещения IDA/Ghidra."), nil, @"0x…", GXL(@"Перейти"), ^(NSString *v) {
        gx_bin *b = &self->_doc->bin;
        BOOL isOff = [v hasPrefix:@"+"];
        uint64_t x;
        if (!GXParseHex(isOff ? [v substringFromIndex:1] : v, &x)) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Нужен hex-адрес")); return; }
        uint64_t a = x;
        if (isOff && !gx_bin_o2a(b, (size_t)x + b->base, &a)) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Смещение вне сегментов")); return; }
        int si = gx_bin_sect_of_addr(b, a);
        if (si < 0) { GXAlert(self, GXL(@"Не найдено"), GXL(@"Адрес не попадает ни в одну секцию")); return; }
        if (b->s[si].exec && b->arm64) { [self.navigationController pushViewController:[[GXBinDisasmVC alloc] initWithDoc:self->_doc addr:a] animated:YES]; return; }
        int64_t off = gx_bin_a2o(b, a);
        GXBinStr *s = off >= 0 ? [self->_doc stringAtOffset:(size_t)off] : nil;
        if (s) { [self.navigationController pushViewController:[[GXBinStrEditVC alloc] initWithDoc:self->_doc str:s] animated:YES]; return; }
        NSData *d = off >= 0 ? [self->_doc.data subdataWithRange:NSMakeRange((NSUInteger)off, MIN((NSUInteger)32, self->_doc.data.length - (NSUInteger)off))] : nil;
        GXAlert(self, [NSString stringWithFormat:@"%@ · %@", GXHex(a), [self->_doc sectName:si]], d ? [NSString stringWithFormat:GXL(@"Смещение %@\n%@"), GXHex((uint64_t)off), GXHexString(d, 32)] : GXL(@"Нет данных в файле (bss)"));
    });
}
@end

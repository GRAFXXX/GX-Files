// Редактирование zip/apk/ipa без распаковки, подпись APK, общая модель архива
#import "GXCore.h"
#import <Security/Security.h>
#include <sys/stat.h>
#include "core/gx_zipw.h"
#include "core/gx_apksign.h"
#include "core/gx_sha256.h"

NSString *const GXArcChangedNotification = @"GXArcChanged";

BOOL GXIsAPKPath(NSString *path) { return [path.pathExtension.lowercaseString isEqualToString:@"apk"]; }

static void gx_prog_cb(double p, void *ctx) { void (^b)(double) = (__bridge void (^)(double))ctx; if (b) b(p); }

NSString *GXZipApply(NSString *archive, NSArray<NSDictionary *> *ops, void (^progress)(double)) {
    if (!ops.count) return nil;
    NSMutableArray *keep = [NSMutableArray array];
    gxzw_op *c = calloc(ops.count, sizeof(gxzw_op));
    for (NSUInteger i = 0; i < ops.count; i++) {
        NSDictionary *o = ops[i];
        NSString *name = o[@"name"], *nn = o[@"newName"], *src = o[@"src"];
        NSData *data = o[@"data"];
        if (name) [keep addObject:name];
        if (nn) [keep addObject:nn];
        if (data) [keep addObject:data];
        c[i].name = name.UTF8String;
        c[i].new_name = nn.UTF8String;
        c[i].src_path = src.fileSystemRepresentation;
        c[i].src_data = data.bytes ?: (data ? "" : NULL);
        c[i].src_len = data.length;
        c[i].del = [o[@"del"] boolValue];
    }
    NSString *dir = archive.stringByDeletingLastPathComponent;
    NSString *tmp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.gxtmp", archive.lastPathComponent]];
    char err[256] = "";
    void (^pb)(double) = [progress copy];
    int ok = gxzw_rewrite(archive.fileSystemRepresentation, tmp.fileSystemRepresentation, c, ops.count,
                          GXIsAPKPath(archive) ? GXZW_ALIGN_APK : GXZW_ALIGN_NONE, err, sizeof err, NULL, pb ? gx_prog_cb : NULL, (__bridge void *)pb);
    free(c);
    if (!ok) return @(err);
    if (rename(tmp.fileSystemRepresentation, archive.fileSystemRepresentation) != 0) {
        NSString *e = [NSString stringWithFormat:GXL(@"не удалось заменить архив: %s"), strerror(errno)];
        unlink(tmp.fileSystemRepresentation);
        return e;
    }
    (void)keep;
    return nil;
}

NSString *GXZipCreateFromFolder(NSString *folder, NSString *dest, BOOL apkAlign) {
    // пустой zip (только EOCD) → добавляем все файлы
    static const uint8_t eocd[22] = {'P', 'K', 5, 6};
    NSString *empty = [GXTempDir() stringByAppendingPathComponent:@"empty.zip"];
    [[NSData dataWithBytes:eocd length:22] writeToFile:empty atomically:YES];
    NSMutableArray *names = [NSMutableArray array], *srcs = [NSMutableArray array];
    NSDirectoryEnumerator *en = [FM() enumeratorAtPath:folder];
    for (NSString *rel in en) {
        NSString *full = [folder stringByAppendingPathComponent:rel];
        BOOL d = GXIsDir(full);
        if ([rel.lastPathComponent isEqualToString:@".DS_Store"]) continue;
        if (d) continue;
        [names addObject:rel];
        [srcs addObject:full];
    }
    if (!names.count) return GXL(@"Папка пуста");
    // AndroidManifest.xml и classes.dex — первыми, как в обычной сборке
    gxzw_op *c = calloc(names.count, sizeof(gxzw_op));
    NSArray *order = [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int ra = [a isEqualToString:@"AndroidManifest.xml"] ? 0 : [a hasPrefix:@"classes"] ? 1 : [a isEqualToString:@"resources.arsc"] ? 2 : 3;
        int rb = [b isEqualToString:@"AndroidManifest.xml"] ? 0 : [b hasPrefix:@"classes"] ? 1 : [b isEqualToString:@"resources.arsc"] ? 2 : 3;
        return ra != rb ? (ra < rb ? NSOrderedAscending : NSOrderedDescending) : [a compare:b];
    }];
    for (NSUInteger i = 0; i < order.count; i++) {
        NSString *full = [folder stringByAppendingPathComponent:order[i]];
        c[i].name = [order[i] UTF8String];
        c[i].src_path = full.fileSystemRepresentation;
        NSUInteger perm = [[FM() attributesOfItemAtPath:full error:nil] filePosixPermissions];
        c[i].mode = (perm & 0111) ? 0755 : 0644;   // исполняемые файлы (бинарник приложения) — с битом x
    }
    char err[256] = "";
    int ok = gxzw_rewrite(empty.fileSystemRepresentation, dest.fileSystemRepresentation, c, order.count, apkAlign ? GXZW_ALIGN_APK : GXZW_ALIGN_NONE, err, sizeof err, NULL, NULL, NULL);
    free(c);
    (void)srcs;
    return ok ? nil : @(err);
}

#pragma mark - Подпись

static SecKeyRef gxKey;
static NSData *gxCert;

static int gx_rsa_sign(void *ctx, const uint8_t *msg, size_t len, uint8_t *sig, size_t *siglen) {
    CFErrorRef e = NULL;
    NSData *m = [NSData dataWithBytesNoCopy:(void *)msg length:len freeWhenDone:NO];
    CFDataRef s = SecKeyCreateSignature((SecKeyRef)ctx, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)m, &e);
    if (!s) { if (e) CFRelease(e); return 0; }
    size_t n = (size_t)CFDataGetLength(s);
    if (n > *siglen) { CFRelease(s); return 0; }
    memcpy(sig, CFDataGetBytePtr(s), n);
    *siglen = n;
    CFRelease(s);
    return 1;
}

static NSString *GXSignDir(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"GXSign"];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSString *GXLoadSigner(void) {
    if (gxKey && gxCert) return nil;
    NSString *kp = [GXSignDir() stringByAppendingPathComponent:@"key.der"], *cp = [GXSignDir() stringByAppendingPathComponent:@"cert.der"];
    NSData *kd = [NSData dataWithContentsOfFile:kp], *cd = [NSData dataWithContentsOfFile:cp];
    NSDictionary *attrs = @{(id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate, (id)kSecAttrKeySizeInBits: @2048};
    CFErrorRef e = NULL;
    if (kd) gxKey = SecKeyCreateWithData((__bridge CFDataRef)kd, (__bridge CFDictionaryRef)attrs, &e);
    if (!gxKey) {
        NSDictionary *gen = @{(id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeySizeInBits: @2048, (id)kSecAttrIsPermanent: @NO};
        gxKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)gen, &e);
        if (!gxKey) return GXL(@"Не удалось создать ключ RSA");
        CFDataRef ext = SecKeyCopyExternalRepresentation(gxKey, &e);
        if (ext) { [(__bridge NSData *)ext writeToFile:kp atomically:YES]; CFRelease(ext); }
        cd = nil;
        [FM() removeItemAtPath:cp error:nil];
    }
    if (!cd) {
        SecKeyRef pub = SecKeyCopyPublicKey(gxKey);
        CFDataRef pd = pub ? SecKeyCopyExternalRepresentation(pub, &e) : NULL;
        if (pub) CFRelease(pub);
        if (!pd) return GXL(@"Не удалось получить открытый ключ");
        size_t cl = 0;
        uint8_t *cert = gx_make_cert(CFDataGetBytePtr(pd), (size_t)CFDataGetLength(pd), "GX Files", gx_rsa_sign, gxKey, &cl);
        CFRelease(pd);
        if (!cert) return GXL(@"Не удалось создать сертификат");
        cd = [NSData dataWithBytesNoCopy:cert length:cl freeWhenDone:YES];
        [cd writeToFile:cp atomically:YES];
    }
    gxCert = cd;
    return nil;
}

NSString *GXSignerInfo(void) {
    NSString *e = GXLoadSigner();
    if (e) return e;
    uint8_t h[32];
    gx_sha256_buf(gxCert.bytes, gxCert.length, h);
    return [NSString stringWithFormat:GXL(@"Ключ GX Files (RSA-2048, CN=GX Files)\nSHA-256 сертификата: %@"), GXHexString([NSData dataWithBytes:h length:32], 32)];
}

NSString *GXSignAPK(NSString *inPath, NSString *outPath, void (^progress)(double)) {
    NSString *e = GXLoadSigner();
    if (e) return e;
    gx_signer s = {gx_rsa_sign, gxKey, gxCert.bytes, gxCert.length};
    BOOL same = [inPath isEqualToString:outPath];
    NSString *dst = same ? [outPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.signtmp", outPath.lastPathComponent]] : outPath;
    char err[256] = "";
    void (^pb)(double) = [progress copy];
    int ok = gx_apk_sign(inPath.fileSystemRepresentation, dst.fileSystemRepresentation, &s, err, sizeof err, NULL, pb ? gx_prog_cb : NULL, (__bridge void *)pb);
    if (!ok) return @(err);
    if (same && rename(dst.fileSystemRepresentation, outPath.fileSystemRepresentation) != 0) { unlink(dst.fileSystemRepresentation); return GXL(@"не удалось заменить файл"); }
    return nil;
}

void GXAPKSigInfo(NSString *path, BOOL *v1, BOOL *v2) {
    int a = 0, b = 0;
    gx_apk_sig_info(path.fileSystemRepresentation, &a, &b);
    if (v1) *v1 = a;
    if (v2) *v2 = b;
}

#pragma mark - Модель архива

@implementation GXArcModel {
    NSArray<GXArcEntry *> *_entries;
    NSMutableDictionary<NSString *, NSDictionary *> *_pending;  // tmp → {name, mtime}
}

static NSMutableDictionary<NSString *, GXArcModel *> *gxModels;

+ (instancetype)modelFor:(NSString *)path {
    if (!gxModels) gxModels = [NSMutableDictionary dictionary];
    GXArcModel *m = gxModels[path];
    if (!m) {
        m = [GXArcModel new];
        m->_path = path;
        m->_pending = [NSMutableDictionary dictionary];
        m->_editable = GXIsZipFamily(path) && [FM() isWritableFileAtPath:path.stringByDeletingLastPathComponent];
        m->_isAPK = GXIsAPKPath(path);
        gxModels[path] = m;
    }
    return m;
}

- (NSArray<GXArcEntry *> *)entries { return _entries ?: @[]; }

- (NSString *)reload {
    NSString *err = nil;
    NSArray *list = GXArchiveList(_path, &err);
    _entries = list ?: @[];
    return list ? nil : (err ?: GXL(@"не удалось прочитать"));
}

- (GXArcEntry *)entryNamed:(NSString *)name {
    for (GXArcEntry *e in self.entries) if ([e.rawName isEqualToString:name] || [e.path isEqualToString:name]) return e;
    return nil;
}

static NSDate *GXMTime(NSString *p) { return [[FM() attributesOfItemAtPath:p error:nil] fileModificationDate]; }

- (void)openEntry:(GXArcEntry *)e from:(UIViewController *)vc { [self openEntry:e from:vc with:nil]; }

- (void)openEntry:(GXArcEntry *)e from:(UIViewController *)vc with:(NSString *)how {
    NSString *dir = GXTempDir();
    NSString *dest = [dir stringByAppendingPathComponent:e.path.lastPathComponent];
    NSString *arc = _path;
    [GXHUD showIn:vc.view text:GXL(@"Извлекаю…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = GXArchiveExtractEntry(arc, e, dest);
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err) { GXAlert(vc, GXL(@"Не удалось извлечь"), err); return; }
            if (self.editable && e.rawName) self->_pending[dest] = @{@"name": e.rawName, @"mtime": GXMTime(dest) ?: [NSDate date]};
            if ([how isEqualToString:@"menu"]) [GXOpener openWithMenu:dest from:vc sourceView:nil];
            else if ([how isEqualToString:@"text"]) [GXOpener openText:dest from:vc readOnly:!self.editable];
            else if ([how isEqualToString:@"hex"]) [GXOpener openHex:dest from:vc readOnly:!self.editable];
            else [GXOpener open:dest from:vc readOnly:!self.editable];
        });
    });
}

- (NSArray<NSDictionary *> *)changedOps {
    NSMutableArray *ops = [NSMutableArray array];
    for (NSString *tmp in _pending.allKeys) {
        NSDictionary *p = _pending[tmp];
        NSDate *m = GXMTime(tmp);
        if (!m) { [_pending removeObjectForKey:tmp]; continue; }
        if ([m compare:p[@"mtime"]] == NSOrderedDescending) {
            [ops addObject:@{@"name": p[@"name"], @"src": tmp}];
            _pending[tmp] = @{@"name": p[@"name"], @"mtime": m};
        }
    }
    return ops;
}

+ (void)commitAllFrom:(UIViewController *)vc {
    for (GXArcModel *m in gxModels.allValues) {
        NSArray *ops = [m changedOps];
        if (!ops.count) continue;
        [m apply:ops from:vc title:GXL(@"Сохраняю в архив…") done:^(BOOL ok) {
            if (ok) GXToast(vc.view ?: UIApplication.sharedApplication.windows.firstObject, [NSString stringWithFormat:GXL(@"Сохранено в %@: %lu"), m.path.lastPathComponent, (unsigned long)ops.count]);
        }];
    }
}

- (void)apply:(NSArray<NSDictionary *> *)ops from:(UIViewController *)vc title:(NSString *)title done:(void (^)(BOOL))done {
    if (!ops.count) { if (done) done(YES); return; }
    if (!self.editable) { GXAlert(vc, GXL(@"Только чтение"), GXL(@"Этот архив нельзя изменять: формат не zip или папка недоступна для записи.")); if (done) done(NO); return; }
    NSString *arc = _path;
    [GXHUD showIn:vc.view ?: UIApplication.sharedApplication.windows.firstObject text:title];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = GXZipApply(arc, ops, ^(double p) { [GXHUD setProgress:p]; });
        NSString *rerr = err ? nil : [self reload];
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err || rerr) { GXAlert(vc, GXL(@"Не удалось изменить архив"), err ?: rerr); if (done) done(NO); return; }
            if (self.isAPK) self.modifiedSinceSign = YES;
            [NSNotificationCenter.defaultCenter postNotificationName:GXArcChangedNotification object:self];
            if (done) done(YES);
        });
    });
}
@end

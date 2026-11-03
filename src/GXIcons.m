// Иконки: бандлы .app, APK (растр, adaptive, VectorDrawable), IPA, миниатюры Quick Look
#import "GXCore.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include "core/gx_zip.h"
#include "core/gx_apk.h"

#pragma mark - VectorDrawable

typedef struct { const char *s; size_t i, n; } pd_t;

static void pd_skip(pd_t *p) { while (p->i < p->n && (p->s[p->i] == ' ' || p->s[p->i] == ',' || p->s[p->i] == '\n' || p->s[p->i] == '\t' || p->s[p->i] == '\r')) p->i++; }
static int pd_isnum(pd_t *p) {
    pd_skip(p);
    if (p->i >= p->n) return 0;
    char c = p->s[p->i];
    return (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.';
}
static CGFloat pd_num(pd_t *p) {
    pd_skip(p);
    size_t st = p->i;
    if (p->i < p->n && (p->s[p->i] == '-' || p->s[p->i] == '+')) p->i++;
    int dot = 0;
    while (p->i < p->n) {
        char c = p->s[p->i];
        if (c >= '0' && c <= '9') p->i++;
        else if (c == '.' && !dot) { dot = 1; p->i++; }
        else if ((c == 'e' || c == 'E') && p->i + 1 < p->n) {
            p->i++;
            if (p->s[p->i] == '-' || p->s[p->i] == '+') p->i++;
        } else break;
    }
    char tmp[64];
    size_t l = MIN(p->i - st, sizeof tmp - 1);
    memcpy(tmp, p->s + st, l);
    tmp[l] = 0;
    return (CGFloat)strtod(tmp, NULL);
}
static int pd_flag(pd_t *p) {
    pd_skip(p);
    if (p->i < p->n && (p->s[p->i] == '0' || p->s[p->i] == '1')) return p->s[p->i++] == '1';
    return (int)pd_num(p);
}

static void add_arc(CGMutablePathRef path, CGFloat x1, CGFloat y1, CGFloat rx, CGFloat ry, CGFloat phiDeg, int large, int sweep, CGFloat x2, CGFloat y2) {
    if (rx == 0 || ry == 0) { CGPathAddLineToPoint(path, NULL, x2, y2); return; }
    rx = fabs(rx); ry = fabs(ry);
    CGFloat phi = phiDeg * M_PI / 180, cs = cos(phi), sn = sin(phi);
    CGFloat dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
    CGFloat x1p = cs * dx + sn * dy, y1p = -sn * dx + cs * dy;
    CGFloat lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lam > 1) { CGFloat s = sqrt(lam); rx *= s; ry *= s; }
    CGFloat num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    CGFloat den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    CGFloat co = den == 0 ? 0 : sqrt(MAX(0, num / den));
    if (large == sweep) co = -co;
    CGFloat cxp = co * rx * y1p / ry, cyp = -co * ry * x1p / rx;
    CGFloat cx = cs * cxp - sn * cyp + (x1 + x2) / 2, cy = sn * cxp + cs * cyp + (y1 + y2) / 2;
    CGFloat t1 = atan2((y1p - cyp) / ry, (x1p - cxp) / rx);
    CGFloat t2 = atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx);
    CGFloat dt = t2 - t1;
    if (sweep && dt < 0) dt += 2 * M_PI;
    else if (!sweep && dt > 0) dt -= 2 * M_PI;
    CGAffineTransform t = CGAffineTransformMakeTranslation(cx, cy);
    t = CGAffineTransformRotate(t, phi);
    t = CGAffineTransformScale(t, rx, ry);
    CGPathAddRelativeArc(path, &t, 0, 0, 1, t1, dt);
}

static CGPathRef GXPathFromData(const char *s) {
    CGMutablePathRef path = CGPathCreateMutable();
    pd_t p = {s, 0, strlen(s)};
    CGFloat cx = 0, cy = 0, sx = 0, sy = 0, lcx = 0, lcy = 0;
    char cmd = 0, prev = 0;
    while (1) {
        pd_skip(&p);
        if (p.i >= p.n) break;
        char c = p.s[p.i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) { cmd = c; p.i++; }
        else if (!cmd) { p.i++; continue; }
        else if (!pd_isnum(&p)) { p.i++; continue; }
        BOOL rel = cmd >= 'a';
        char C = (char)(rel ? cmd - 32 : cmd);
        switch (C) {
            case 'M': {
                CGFloat x = pd_num(&p), y = pd_num(&p);
                if (rel) { x += cx; y += cy; }
                CGPathMoveToPoint(path, NULL, x, y);
                cx = sx = x; cy = sy = y;
                cmd = rel ? 'l' : 'L';
                break;
            }
            case 'L': { CGFloat x = pd_num(&p), y = pd_num(&p); if (rel) { x += cx; y += cy; } if (CGPathIsEmpty(path)) CGPathMoveToPoint(path, NULL, cx, cy); CGPathAddLineToPoint(path, NULL, x, y); cx = x; cy = y; break; }
            case 'H': { CGFloat x = pd_num(&p); if (rel) x += cx; CGPathAddLineToPoint(path, NULL, x, cy); cx = x; break; }
            case 'V': { CGFloat y = pd_num(&p); if (rel) y += cy; CGPathAddLineToPoint(path, NULL, cx, y); cy = y; break; }
            case 'C': {
                CGFloat x1 = pd_num(&p), y1 = pd_num(&p), x2 = pd_num(&p), y2 = pd_num(&p), x = pd_num(&p), y = pd_num(&p);
                if (rel) { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy; }
                CGPathAddCurveToPoint(path, NULL, x1, y1, x2, y2, x, y);
                lcx = x2; lcy = y2; cx = x; cy = y;
                break;
            }
            case 'S': {
                CGFloat x2 = pd_num(&p), y2 = pd_num(&p), x = pd_num(&p), y = pd_num(&p);
                if (rel) { x2 += cx; y2 += cy; x += cx; y += cy; }
                CGFloat x1 = cx, y1 = cy;
                char pc = (char)(prev >= 'a' ? prev - 32 : prev);
                if (pc == 'C' || pc == 'S') { x1 = 2 * cx - lcx; y1 = 2 * cy - lcy; }
                CGPathAddCurveToPoint(path, NULL, x1, y1, x2, y2, x, y);
                lcx = x2; lcy = y2; cx = x; cy = y;
                break;
            }
            case 'Q': {
                CGFloat x1 = pd_num(&p), y1 = pd_num(&p), x = pd_num(&p), y = pd_num(&p);
                if (rel) { x1 += cx; y1 += cy; x += cx; y += cy; }
                CGPathAddQuadCurveToPoint(path, NULL, x1, y1, x, y);
                lcx = x1; lcy = y1; cx = x; cy = y;
                break;
            }
            case 'T': {
                CGFloat x = pd_num(&p), y = pd_num(&p);
                if (rel) { x += cx; y += cy; }
                CGFloat x1 = cx, y1 = cy;
                char pc = (char)(prev >= 'a' ? prev - 32 : prev);
                if (pc == 'Q' || pc == 'T') { x1 = 2 * cx - lcx; y1 = 2 * cy - lcy; }
                CGPathAddQuadCurveToPoint(path, NULL, x1, y1, x, y);
                lcx = x1; lcy = y1; cx = x; cy = y;
                break;
            }
            case 'A': {
                CGFloat rx = pd_num(&p), ry = pd_num(&p), rot = pd_num(&p);
                int la = pd_flag(&p), sw = pd_flag(&p);
                CGFloat x = pd_num(&p), y = pd_num(&p);
                if (rel) { x += cx; y += cy; }
                add_arc(path, cx, cy, rx, ry, rot, la, sw, x, y);
                cx = x; cy = y;
                break;
            }
            case 'Z': CGPathCloseSubpath(path); cx = sx; cy = sy; break;
            default: p.i++; break;
        }
        prev = cmd;
        if (C == 'Z') cmd = 0;
    }
    return path;
}

static UIColor *GXColorARGB(uint32_t c, CGFloat alphaMul) {
    return [UIColor colorWithRed:((c >> 16) & 0xFF) / 255.0 green:((c >> 8) & 0xFF) / 255.0 blue:(c & 0xFF) / 255.0 alpha:((c >> 24) & 0xFF) / 255.0 * alphaMul];
}

static BOOL attr_color(const gxa_attr *a, gxa_arsc *arsc, uint32_t *out) {
    if (!a) return NO;
    if (a->type >= GXA_T_COLOR_ARGB8 && a->type <= GXA_T_COLOR_RGB4) {
        uint32_t c = a->data;
        if (a->type == GXA_T_COLOR_RGB8 || a->type == GXA_T_COLOR_RGB4) c |= 0xFF000000u;
        *out = c;
        return YES;
    }
    if (a->type == GXA_T_REF && arsc) {
        uint32_t id = a->data;
        for (int depth = 0; depth < 5; depth++) {
            gxa_value v[32];
            int n = gxa_arsc_values(arsc, id, v, 32);
            int pick = -1;
            for (int i = 0; i < n; i++) if (!v[i].night) { pick = i; break; }
            if (pick < 0 && n) pick = 0;
            if (pick < 0) return NO;
            if (v[pick].type >= GXA_T_COLOR_ARGB8 && v[pick].type <= GXA_T_COLOR_RGB4) { *out = v[pick].data; return YES; }
            if (v[pick].type == GXA_T_REF) { id = v[pick].data; continue; }
            return NO;
        }
    }
    if (a->type == GXA_T_STRING && a->str && a->str[0] == '#') {
        unsigned v = 0;
        sscanf(a->str + 1, "%x", &v);
        size_t l = strlen(a->str + 1);
        *out = l <= 6 ? (0xFF000000u | v) : v;
        return YES;
    }
    return NO;
}

static CGFloat attr_float(const gxa_elem *e, const char *name, CGFloat def) {
    const gxa_attr *a = gxa_find_attr(e, name, 0);
    if (!a) return def;
    if (a->type == GXA_T_FLOAT) { float f; memcpy(&f, &a->data, 4); return f; }
    if (a->type == GXA_T_INT_DEC || a->type == GXA_T_INT_HEX) return (CGFloat)(int32_t)a->data;
    if (a->type == GXA_T_DIMEN) return (CGFloat)(int32_t)(a->data & 0xFFFFFF00u) / 256.0;
    if (a->type == GXA_T_STRING && a->str) return (CGFloat)atof(a->str);
    return def;
}

// Рисует VectorDrawable в rect текущего контекста
static BOOL GXDrawVector(const uint8_t *data, size_t len, gxa_arsc *arsc, CGContextRef ctx, CGRect rect) {
    gxa_xml x;
    if (!gxa_xml_parse(&x, data, len)) return NO;
    if (strcmp(x.el[0].name, "vector")) { gxa_xml_free(&x); return NO; }
    CGFloat vw = attr_float(&x.el[0], "viewportWidth", 24), vh = attr_float(&x.el[0], "viewportHeight", 24);
    if (vw <= 0 || vh <= 0) { gxa_xml_free(&x); return NO; }
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y);
    CGContextScaleCTM(ctx, rect.size.width / vw, rect.size.height / vh);
    int saves[64];
    int sp = 0;
    int depthStack[64];
    // проходим события: открытие group → save + transform; закрытие → restore
    for (size_t i = 0; i < x.nev; i++) {
        int ev = x.ev[i];
        if (ev >= 0) {
            const gxa_elem *e = &x.el[ev];
            if (!strcmp(e->name, "group")) {
                CGContextSaveGState(ctx);
                if (sp < 64) { saves[sp] = 1; depthStack[sp] = ev; sp++; }
                CGFloat px = attr_float(e, "pivotX", 0), py = attr_float(e, "pivotY", 0);
                CGFloat tx = attr_float(e, "translateX", 0), ty = attr_float(e, "translateY", 0);
                CGFloat sx = attr_float(e, "scaleX", 1), sy = attr_float(e, "scaleY", 1), rot = attr_float(e, "rotation", 0);
                CGContextTranslateCTM(ctx, tx + px, ty + py);
                CGContextRotateCTM(ctx, rot * M_PI / 180);
                CGContextScaleCTM(ctx, sx, sy);
                CGContextTranslateCTM(ctx, -px, -py);
            } else if (!strcmp(e->name, "clip-path")) {
                const gxa_attr *pd = gxa_find_attr(e, "pathData", 0x01010405);
                if (pd && pd->str) {
                    CGPathRef p = GXPathFromData(pd->str);
                    CGContextAddPath(ctx, p);
                    CGContextClip(ctx);
                    CGPathRelease(p);
                }
            } else if (!strcmp(e->name, "path")) {
                const gxa_attr *pd = gxa_find_attr(e, "pathData", 0x01010405);
                if (!pd || !pd->str) continue;
                CGPathRef p = GXPathFromData(pd->str);
                uint32_t fill = 0, stroke = 0;
                BOOL hasFill = attr_color(gxa_find_attr(e, "fillColor", 0x01010404), arsc, &fill);
                BOOL hasStroke = attr_color(gxa_find_attr(e, "strokeColor", 0x01010406), arsc, &stroke);
                const gxa_attr *fa = gxa_find_attr(e, "fillColor", 0x01010404);
                if (!hasFill && fa && fa->type == GXA_T_REF) { hasFill = YES; fill = 0xFF888888; } // градиент/selector — серым
                CGFloat fillAlpha = attr_float(e, "fillAlpha", 1), strokeAlpha = attr_float(e, "strokeAlpha", 1);
                const gxa_attr *ft = gxa_find_attr(e, "fillType", 0);
                BOOL evenOdd = ft && ((ft->type == GXA_T_INT_DEC && ft->data == 1) || (ft->str && !strcmp(ft->str, "evenOdd")));
                if (hasFill) {
                    CGContextAddPath(ctx, p);
                    CGContextSetFillColorWithColor(ctx, GXColorARGB(fill, fillAlpha).CGColor);
                    if (evenOdd) CGContextEOFillPath(ctx); else CGContextFillPath(ctx);
                }
                if (hasStroke) {
                    CGContextAddPath(ctx, p);
                    CGContextSetStrokeColorWithColor(ctx, GXColorARGB(stroke, strokeAlpha).CGColor);
                    CGContextSetLineWidth(ctx, attr_float(e, "strokeWidth", 1));
                    CGContextStrokePath(ctx);
                }
                CGPathRelease(p);
            }
        } else {
            int idx = -ev - 1;
            if (sp > 0 && depthStack[sp - 1] == idx) { if (saves[sp - 1]) CGContextRestoreGState(ctx); sp--; }
        }
    }
    while (sp-- > 0) CGContextRestoreGState(ctx);
    CGContextRestoreGState(ctx);
    gxa_xml_free(&x);
    return YES;
}

#pragma mark - APK

static NSData *zip_entry(gxz *z, const char *name, size_t limit) {
    long i = gxz_find(z, name);
    if (i < 0) return nil;
    uint8_t *d; size_t n;
    if (!gxz_read(z, &z->e[i], limit, &d, &n)) return nil;
    return [NSData dataWithBytesNoCopy:d length:n freeWhenDone:YES];
}

// Рисует слой (растр/vector/цвет) в rect
static BOOL draw_layer(gxz *z, gxa_arsc *arsc, const gx_icon_layer *l, CGContextRef ctx, CGRect rect) {
    if (l->is_color) {
        CGContextSetFillColorWithColor(ctx, GXColorARGB(l->color | (((l->color >> 24) == 0) ? 0xFF000000u : 0), 1).CGColor);
        CGContextFillRect(ctx, rect);
        return YES;
    }
    if (!l->path[0]) return NO;
    NSData *d = zip_entry(z, l->path, 16 << 20);
    if (!d) return NO;
    NSString *p = @(l->path).lowercaseString;
    if ([p hasSuffix:@".xml"]) return GXDrawVector(d.bytes, d.length, arsc, ctx, rect);
    UIImage *img = [UIImage imageWithData:d];
    if (!img) return NO;
    UIGraphicsPushContext(ctx);
    [img drawInRect:rect];
    UIGraphicsPopContext();
    return YES;
}

@implementation GXIcons

static NSCache *gxIconCache;
static dispatch_queue_t gxIconQueue;

+ (void)initialize {
    if (self != GXIcons.class) return;
    gxIconCache = [NSCache new];
    gxIconCache.countLimit = 600;
    gxIconQueue = dispatch_queue_create("gx.icons", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_UTILITY, 0));
}

+ (NSString *)keyFor:(NSString *)path side:(CGFloat)side {
    struct stat st;
    long long m = 0, sz = 0;
    if (stat(path.fileSystemRepresentation, &st) == 0) { m = st.st_mtimespec.tv_sec; sz = st.st_size; }
    return [NSString stringWithFormat:@"%@|%lld|%lld|%.0f", path, m, sz, side];
}

+ (NSString *)diskPathForKey:(NSString *)key {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"GXIcons"];
    [FM() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *k = [key dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t h[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(k.bytes, (CC_LONG)k.length, h);
    return [[dir stringByAppendingPathComponent:GXHexString([NSData dataWithBytes:h length:sizeof h], 40)] stringByAppendingPathExtension:@"png"];
}

+ (void)clearCache {
    [gxIconCache removeAllObjects];
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    [FM() removeItemAtPath:[caches stringByAppendingPathComponent:@"GXIcons"] error:nil];
    [FM() removeItemAtPath:[caches stringByAppendingPathComponent:@"GXTemp"] error:nil];
}

+ (UIImage *)cachedForPath:(NSString *)path side:(CGFloat)side {
    return [gxIconCache objectForKey:[self keyFor:path side:side]];
}

+ (UIImage *)appBundleIcon:(NSString *)bundlePath {
    BOOL dark = UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    NSArray *cached = dark ? @[@"LCAppIconDark.png", @"LCAppIconLight.png"] : @[@"LCAppIconLight.png", @"LCAppIconDark.png"];
    for (NSString *n in cached) {
        UIImage *i = [UIImage imageWithContentsOfFile:[bundlePath stringByAppendingPathComponent:n]];
        if (i) return i;
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    NSString *assetName = nil;
    for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *icons = info[key];
        if (![icons isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:NSDictionary.class]) {
            for (id n in primary[@"CFBundleIconFiles"] ?: @[]) if ([n isKindOfClass:NSString.class]) [names addObject:n];
            if ([primary[@"CFBundleIconName"] isKindOfClass:NSString.class]) assetName = assetName ?: primary[@"CFBundleIconName"];
        } else if ([primary isKindOfClass:NSString.class]) [names addObject:(NSString *)primary];
    }
    for (id n in info[@"CFBundleIconFiles"] ?: @[]) if ([n isKindOfClass:NSString.class]) [names addObject:n];
    if ([info[@"CFBundleIconFile"] isKindOfClass:NSString.class]) [names addObject:info[@"CFBundleIconFile"]];
    // Крупнейший подходящий png
    NSArray *files = [FM() contentsOfDirectoryAtPath:bundlePath error:nil];
    NSString *best = nil;
    unsigned long long bestSize = 0;
    for (NSString *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
        BOOL match = NO;
        for (NSString *n in names) {
            NSString *base = n.pathExtension.length ? n.stringByDeletingPathExtension : n;
            if ([f hasPrefix:base]) { match = YES; break; }
        }
        if (!match && !names.count && [f hasPrefix:@"AppIcon"]) match = YES;
        if (!match) continue;
        unsigned long long s = [[FM() attributesOfItemAtPath:[bundlePath stringByAppendingPathComponent:f] error:nil] fileSize];
        if (s > bestSize) { bestSize = s; best = f; }
    }
    if (best) {
        UIImage *i = [UIImage imageWithContentsOfFile:[bundlePath stringByAppendingPathComponent:best]];
        if (i) return i;
    }
    if (assetName || names.count) {
        NSBundle *b = [NSBundle bundleWithPath:bundlePath];
        for (NSString *n in assetName ? [@[assetName] arrayByAddingObjectsFromArray:names.array] : names.array) {
            UIImage *i = [UIImage imageNamed:n inBundle:b compatibleWithTraitCollection:nil];
            if (i) return i;
        }
    }
    return nil;
}

+ (UIImage *)apkIcon:(NSString *)path base:(uint64_t)base size:(uint64_t)size {
    gx_apk_info info;
    if (!gx_apk_analyze(path.fileSystemRepresentation, base, size, &info)) return nil;
    __block gxz z;
    if (!gxz_open(&z, path.fileSystemRepresentation, base, size)) { gx_apk_free(&info); return nil; }
    gxa_arsc *arsc = NULL;
    NSData *ad = zip_entry(&z, "resources.arsc", 256u << 20);
    if (ad) arsc = gxa_arsc_parse(ad.bytes, ad.length);
    ad = nil;
    UIImage *result = nil;
    const CGFloat S = 192;
    if (info.icon_adaptive && (info.icon_fg.path[0] || info.icon_bg.path[0] || info.icon_bg.is_color)) {
        UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat];
        f.scale = 1;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(S, S) format:f];
        __block BOOL drew = NO;
        result = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
            CGFloat full = S * 108 / 72;
            CGRect canvas = CGRectMake(-(full - S) / 2, -(full - S) / 2, full, full);
            if (info.icon_bg.path[0] || info.icon_bg.is_color) drew |= draw_layer(&z, arsc, &info.icon_bg, rc.CGContext, canvas);
            else { CGContextSetFillColorWithColor(rc.CGContext, UIColor.whiteColor.CGColor); CGContextFillRect(rc.CGContext, CGRectMake(0, 0, S, S)); }
            if (info.icon_fg.path[0] || info.icon_fg.is_color) drew |= draw_layer(&z, arsc, &info.icon_fg, rc.CGContext, canvas);
        }];
        if (!drew) result = nil;
    }
    if (!result && (info.icon.path[0] || info.icon.is_color)) {
        NSString *p = @(info.icon.path).lowercaseString;
        if (!info.icon.is_color && ![p hasSuffix:@".xml"]) {
            NSData *d = zip_entry(&z, info.icon.path, 16 << 20);
            if (d) result = [UIImage imageWithData:d];
        } else {
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(S, S)];
            __block BOOL drew = NO;
            result = [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
                drew = draw_layer(&z, arsc, &info.icon, rc.CGContext, CGRectMake(0, 0, S, S));
            }];
            if (!drew) result = nil;
        }
    }
    gxa_arsc_free(arsc);
    gxz_close(&z);
    gx_apk_free(&info);
    return result;
}

// XAPK/APKM/APKS: иконка из icon.png в корне, иначе из базового APK
+ (UIImage *)bundleIcon:(NSString *)path {
    gxz z;
    if (!gxz_open(&z, path.fileSystemRepresentation, 0, 0)) return nil;
    UIImage *img = nil;
    NSData *d = zip_entry(&z, "icon.png", 8 << 20);
    if (d) img = [UIImage imageWithData:d];
    if (!img) {
        long pick = -1;
        uint64_t best = 0;
        for (size_t i = 0; i < z.n; i++) {
            NSString *n = @(z.e[i].name);
            if (![n.lowercaseString hasSuffix:@".apk"]) continue;
            NSString *b = n.lastPathComponent.lowercaseString;
            if ([b isEqualToString:@"base.apk"]) { pick = (long)i; break; }
            if ([b hasPrefix:@"config."] || [b hasPrefix:@"split_"]) continue;
            if (z.e[i].usize > best) { best = z.e[i].usize; pick = (long)i; }
        }
        if (pick >= 0 && z.e[pick].method == 0) {
            uint64_t off;
            if (gxz_data_offset(&z, &z.e[pick], &off)) img = [self apkIcon:path base:off size:z.e[pick].csize];
        }
    }
    gxz_close(&z);
    return img;
}

+ (UIImage *)ipaIcon:(NSString *)path {
    gxz z;
    if (!gxz_open(&z, path.fileSystemRepresentation, 0, 0)) return nil;
    NSString *appDir = nil;
    NSDictionary *info = nil;
    for (size_t i = 0; i < z.n; i++) {
        NSString *n = @(z.e[i].name);
        NSArray *c = n.pathComponents;
        if (c.count == 3 && [c[0] isEqualToString:@"Payload"] && [c[1] hasSuffix:@".app"] && [c[2] isEqualToString:@"Info.plist"]) {
            uint8_t *d; size_t len;
            if (gxz_read(&z, &z.e[i], 8 << 20, &d, &len)) {
                info = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytesNoCopy:d length:len freeWhenDone:YES] options:0 format:nil error:nil];
            }
            appDir = [@"Payload" stringByAppendingPathComponent:c[1]];
            break;
        }
    }
    UIImage *img = nil;
    if (appDir) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *key in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
            NSDictionary *pi = [info[key] isKindOfClass:NSDictionary.class] ? info[key][@"CFBundlePrimaryIcon"] : nil;
            if ([pi isKindOfClass:NSDictionary.class]) for (id n in pi[@"CFBundleIconFiles"] ?: @[]) if ([n isKindOfClass:NSString.class]) [names addObject:n];
        }
        for (id n in info[@"CFBundleIconFiles"] ?: @[]) if ([n isKindOfClass:NSString.class]) [names addObject:n];
        if (!names.count) [names addObject:@"AppIcon"];
        long best = -1;
        uint64_t bestSize = 0;
        for (size_t i = 0; i < z.n; i++) {
            NSString *n = @(z.e[i].name);
            if (![n.stringByDeletingLastPathComponent isEqualToString:appDir] || ![n.pathExtension.lowercaseString isEqualToString:@"png"]) continue;
            NSString *f = n.lastPathComponent;
            for (NSString *nm in names) {
                NSString *b = nm.pathExtension.length ? nm.stringByDeletingPathExtension : nm;
                if ([f hasPrefix:b] && z.e[i].usize > bestSize) { bestSize = z.e[i].usize; best = (long)i; }
            }
        }
        if (best >= 0) {
            uint8_t *d; size_t len;
            if (gxz_read(&z, &z.e[best], 8 << 20, &d, &len)) img = [UIImage imageWithData:[NSData dataWithBytesNoCopy:d length:len freeWhenDone:YES]];
        }
    }
    gxz_close(&z);
    return img;
}

+ (void)iconForPath:(NSString *)path kind:(GXKind)kind side:(CGFloat)side completion:(void (^)(UIImage *))completion {
    NSString *key = [self keyFor:path side:side];
    UIImage *c = [gxIconCache objectForKey:key];
    if (c) { completion(c); return; }
    CGFloat scale = UIScreen.mainScreen.scale;
    BOOL appLike = kind == GXKindApp || kind == GXKindAndroid || kind == GXKindIPA || kind == GXKindFolder;
    void (^finish)(UIImage *, BOOL) = ^(UIImage *img, BOOL store) {
        UIImage *sq = img ? GXSquareImage(img, side, appLike ? side * 0.225 : side * 0.12) : nil;
        if (sq) [gxIconCache setObject:sq forKey:key];
        if (sq && store) [UIImagePNGRepresentation(img.size.width > 256 ? GXSquareImage(img, 256, 0) : img) writeToFile:[self diskPathForKey:key] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sq); });
    };
    dispatch_async(gxIconQueue, ^{
        @autoreleasepool {
            if (kind == GXKindApp) { finish([self appBundleIcon:path], NO); return; }
            if (kind == GXKindFolder) {
                // контейнер данных LC → иконка владельца
                GXLCApp *owner = [GXLCApp appOwningDataFolder:path];
                finish(owner.icon, NO);
                return;
            }
            if (kind == GXKindAndroid || kind == GXKindIPA) {
                NSString *disk = [self diskPathForKey:key];
                UIImage *cached = [UIImage imageWithContentsOfFile:disk];
                if (cached) { finish(cached, NO); return; }
                NSString *ext = path.pathExtension.lowercaseString;
                UIImage *img = kind == GXKindIPA ? [self ipaIcon:path]
                             : [ext isEqualToString:@"apk"] ? [self apkIcon:path base:0 size:0] : [self bundleIcon:path];
                finish(img, img != nil);
                return;
            }
            if (GXThumbnails() && kind == GXKindImage && GXIsTexturePath(path)) {
                struct stat tst;
                UIImage *t = (stat(path.fileSystemRepresentation, &tst) == 0 && tst.st_size < 48 * 1024 * 1024) ? GXTextureImage(path, nil) : nil;
                if (t) { finish(t, NO); return; }
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }
            if (!GXThumbnails() || !(kind == GXKindImage || kind == GXKindVideo || kind == GXKindPDF || kind == GXKindFont || kind == GXKindAudio)) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                return;
            }
            QLThumbnailGenerationRequest *req = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:path]
                                                                                                    size:CGSizeMake(side, side) scale:scale
                                                                                     representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
            [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:req completionHandler:^(QLThumbnailRepresentation *rep, NSError *err) {
                UIImage *img = rep.UIImage;
                if (!img) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); return; }
                UIImage *sq = GXSquareImage(img, side, side * 0.12);
                [gxIconCache setObject:sq forKey:key];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(sq); });
            }];
        }
    });
}
@end

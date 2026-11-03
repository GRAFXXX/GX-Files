// Просмотр и замена текстур .btx (Spike Chunsoft LZ: SHTX / SHTXFS / SHTXFf / DDS DXT1/3/5), а также голых .dds
#import "GXCore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "core/gx_btx.h"
#include <fcntl.h>
#include <unistd.h>

BOOL GXIsTexturePath(NSString *path) {
    NSString *e = path.pathExtension.lowercaseString;
    if ([@[@"btx", @"dds", @"shtx", @"shtxfs", @"shtxff"] containsObject:e]) return YES;
    if (e.length && ![@[@"bin", @"dat", @"tex", @"img", @"raw"] containsObject:e]) return NO;
    uint8_t h[8] = {0};
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    ssize_t n = read(fd, h, 8);
    close(fd);
    if (n < 4) return NO;
    return !memcmp(h, "\xFC\xAA\x55\xA7", 4) || (n == 8 && !memcmp(h, "GX3", 4) && !memcmp(h + 4, "\xFC\xAA\x55\xA7", 4)) || !memcmp(h, "SHTX", 4) || !memcmp(h, "DDS ", 4);
}

static UIImage *GXImageFromRGBA(const uint8_t *rgba, int w, int h) {
    NSData *d = [NSData dataWithBytes:rgba length:(size_t)w * h * 4];
    CGDataProviderRef pr = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaLast, pr, NULL, NO, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs); CGDataProviderRelease(pr);
    if (!cg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return img;
}

// RGBA без премультипликации из любой картинки (размер — в пикселях)
static uint8_t *GXRGBAFromImage(UIImage *img, int *ow, int *oh) {
    CGImageRef cg = img.CGImage;
    if (!cg) return NULL;
    int w = (int)CGImageGetWidth(cg), h = (int)CGImageGetHeight(cg);
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return NULL;
    uint8_t *buf = calloc((size_t)w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, (size_t)w * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    for (size_t i = 0; i < (size_t)w * h; i++) {
        uint8_t *p = buf + i * 4;
        if (p[3] && p[3] < 255) for (int k = 0; k < 3; k++) p[k] = (uint8_t)MIN(255, (p[k] * 255 + p[3] / 2) / p[3]);
    }
    *ow = w; *oh = h;
    return buf;
}

static NSData *GXReadAll(NSString *path) { return [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil]; }

UIImage *GXTextureImage(NSString *path, NSString **info) {
    NSData *d = GXReadAll(path);
    if (!d.length) { if (info) *info = GXL(@"пустой файл"); return nil; }
    gx_btx b; char err[256] = {0};
    if (!gx_btx_decode(d.bytes, d.length, &b, err, sizeof err)) {
        if (info) *info = [NSString stringWithUTF8String:err] ?: GXL(@"не распознано");
        gx_btx_free(&b);
        return nil;
    }
    UIImage *img = nil;
    if (b.inner == 5) img = [UIImage imageWithData:[NSData dataWithBytes:b.raw + b.inner_off length:b.raw_len - b.inner_off]];
    else img = GXImageFromRGBA(b.rgba, b.width, b.height);
    if (info) *info = [NSString stringWithFormat:@"%@ · %d×%d", [NSString stringWithUTF8String:b.kind] ?: @"", img ? (int)(img.size.width * img.scale) : b.width, img ? (int)(img.size.height * img.scale) : b.height];
    gx_btx_free(&b);
    return img;
}

@interface GXTextureVC () <UIScrollViewDelegate, UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *iv;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, assign) BOOL checker;
@end

@implementation GXTextureVC

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) { _path = path.copy; _checker = YES; }
    return self;
}

- (UIColor *)checkerColor {
    CGFloat s = 12;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s * 2, s * 2)];
    UIImage *pat = [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        [[UIColor colorWithWhite:0.80 alpha:1] setFill]; UIRectFill(CGRectMake(0, 0, s * 2, s * 2));
        [[UIColor colorWithWhite:0.62 alpha:1] setFill]; UIRectFill(CGRectMake(0, 0, s, s)); UIRectFill(CGRectMake(s, s, s, s));
    }];
    return [UIColor colorWithPatternImage:pat];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.path.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[self buildMenu]];

    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.delegate = self;
    _scroll.maximumZoomScale = 16;
    _scroll.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:_scroll];
    _iv = [UIImageView new];
    _iv.layer.magnificationFilter = kCAFilterNearest;
    [_scroll addSubview:_iv];

    _infoLabel = [UILabel new];
    _infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _infoLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _infoLabel.textColor = UIColor.secondaryLabelColor;
    _infoLabel.numberOfLines = 0;
    _infoLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_infoLabel];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:g.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_infoLabel.topAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:6],
        [_infoLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [_infoLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [_infoLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-6],
    ]];
    UITapGestureRecognizer *dt = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)];
    dt.numberOfTapsRequired = 2;
    [_scroll addGestureRecognizer:dt];
    [self reload];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)reload {
    _infoLabel.text = GXL(@"Декодирование…");
    NSString *p = self.path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *info = nil;
        UIImage *img = GXTextureImage(p, &info);
        unsigned long long sz = [[NSFileManager.defaultManager attributesOfItemAtPath:p error:nil] fileSize];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.image = img;
            self.infoLabel.text = img ? [NSString stringWithFormat:@"%@ · %@", info, GXHuman(sz)]
                                      : [NSString stringWithFormat:GXL(@"Не удалось показать: %@\nМожно открыть в hex-редакторе или сохранить распакованные данные через меню «…»."), info ?: @"?"];
            self.iv.image = img;
            self.iv.frame = CGRectZero;
            self.iv.backgroundColor = self.checker ? [self checkerColor] : UIColor.clearColor;
            [self layoutImage];
        });
    });
}

- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; [self layoutImage]; }

- (void)layoutImage {
    if (!_image) { _iv.frame = CGRectZero; return; }
    CGSize b = _scroll.bounds.size, s = _image.size;
    if (b.width <= 0 || b.height <= 0 || s.width <= 0) return;
    CGFloat fit = MIN(b.width / s.width, b.height / s.height);
    if (!_iv.frame.size.width) {
        _scroll.zoomScale = 1;
        _iv.frame = CGRectMake(0, 0, s.width, s.height);
        _scroll.contentSize = s;
        _scroll.minimumZoomScale = MIN(1, fit);
        _scroll.zoomScale = MIN(fit, 4);
    } else _scroll.minimumZoomScale = MIN(MIN(1, fit), _scroll.zoomScale);
    [self center];
}

- (void)center {
    CGSize b = _scroll.bounds.size, c = _iv.frame.size;
    _scroll.contentInset = UIEdgeInsetsMake(MAX(0, (b.height - c.height) / 2), MAX(0, (b.width - c.width) / 2), 0, 0);
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)s { return _iv; }
- (void)scrollViewDidZoom:(UIScrollView *)s { [self center]; }

- (void)doubleTap:(UITapGestureRecognizer *)t {
    if (!_image) return;
    CGFloat fit = _scroll.minimumZoomScale;
    [_scroll setZoomScale:(_scroll.zoomScale > fit * 1.5 ? fit : MIN(_scroll.maximumZoomScale, MAX(fit * 3, 1))) animated:YES];
}

- (void)resetImageFrame { _iv.frame = CGRectZero; _scroll.zoomScale = 1; }

- (UIMenu *)buildMenu {
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *sym, void (^b)(void)) {
        return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:sym] identifier:nil handler:^(UIAction *a) { b(); }];
    };
    return [UIMenu menuWithChildren:@[
        act(GXL(@"Сохранить как PNG рядом"), @"square.and.arrow.down", ^{ [ws exportPNG]; }),
        act(GXL(@"Поделиться PNG"), @"square.and.arrow.up", ^{ [ws sharePNG]; }),
        act(GXL(@"Заменить картинкой (PNG/JPG…)"), @"photo.on.rectangle", ^{ [ws pickReplacement]; }),
        act(GXL(@"Сохранить распакованные данные"), @"doc.zipper", ^{ [ws saveRaw]; }),
        act(GXL(@"Фон-шахматка вкл/выкл"), @"checkerboard.rectangle", ^{ ws.checker = !ws.checker; ws.iv.backgroundColor = ws.checker ? [ws checkerColor] : UIColor.clearColor; }),
        act(GXL(@"Открыть в hex-редакторе"), @"number", ^{ [GXOpener openHex:ws.path from:ws readOnly:NO]; }),
    ]];
}

- (void)exportPNG {
    if (!_image) { GXAlert(self, GXL(@"Нет картинки"), nil); return; }
    NSString *dir = self.path.stringByDeletingLastPathComponent;
    NSString *dest = GXUniquePath(dir, [self.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"]);
    if ([UIImagePNGRepresentation(_image) writeToFile:dest atomically:YES]) GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено: %@"), dest.lastPathComponent]);
    else GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось записать PNG (папка только для чтения?)"));
}

- (void)sharePNG {
    if (!_image) return;
    NSString *t = [GXTempDir() stringByAppendingPathComponent:[self.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"png"]];
    [UIImagePNGRepresentation(_image) writeToFile:t atomically:YES];
    UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:t]] applicationActivities:nil];
    av.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:av animated:YES completion:nil];
}

- (void)saveRaw {
    NSData *d = GXReadAll(self.path);
    uint8_t *o; size_t ol;
    if (!d || !gx_spike_decompress(d.bytes, d.length, &o, &ol)) { GXAlert(self, GXL(@"Не сжато"), GXL(@"Файл не в контейнере FC AA 55 A7 — данные уже «сырые».")); return; }
    uint8_t *o2; size_t l2;
    if (gx_spike_decompress(o, ol, &o2, &l2)) { free(o); o = o2; ol = l2; }
    NSData *raw = [NSData dataWithBytesNoCopy:o length:ol freeWhenDone:YES];
    const uint8_t *p = raw.bytes;
    NSString *ext = (ol >= 8 && !memcmp(p, "DDS1DDS ", 8)) || (ol >= 4 && !memcmp(p, "DDS ", 4)) ? @"dds" : (ol >= 4 && !memcmp(p, "GXT", 4)) ? @"gxt" : (ol >= 4 && !memcmp(p, "SHTX", 4)) ? @"shtx" : @"bin";
    if ([ext isEqualToString:@"dds"] && !memcmp(p, "DDS1", 4)) raw = [raw subdataWithRange:NSMakeRange(4, ol - 4)];
    NSString *dest = GXUniquePath(self.path.stringByDeletingLastPathComponent, [self.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:ext]);
    if ([raw writeToFile:dest atomically:YES]) GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено: %@"), dest.lastPathComponent]);
    else GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось записать файл"));
}

- (void)pickReplacement {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    UIImage *img = [UIImage imageWithContentsOfFile:urls.firstObject.path];
    if (!img) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось прочитать картинку")); return; }
    NSString *msg = [NSString stringWithFormat:GXL(@"Новая картинка %d×%d будет записана в «%@» (оригинал сохранится рядом как .orig)."), (int)(img.size.width * img.scale), (int)(img.size.height * img.scale), self.path.lastPathComponent];
    if (self.image && (img.size.width * img.scale != self.image.size.width * self.image.scale || img.size.height * img.scale != self.image.size.height * self.image.scale))
        msg = [msg stringByAppendingString:GXL(@"\n\nВнимание: размер отличается от исходного — игра может ожидать прежний.")];
    GXConfirm(self, GXL(@"Заменить текстуру?"), msg, GXL(@"Заменить"), NO, ^{ [self replaceWith:img]; });
}

- (void)replaceWith:(UIImage *)img {
    NSData *d = GXReadAll(self.path);
    gx_btx b; char err[256] = {0};
    if (!d || !gx_btx_decode(d.bytes, d.length, &b, err, sizeof err)) {
        gx_btx_free(&b);
        GXAlert(self, GXL(@"Нельзя заменить"), [NSString stringWithFormat:GXL(@"Исходник не распознан: %s"), err]);
        return;
    }
    NSString *errStr = nil;
    if (b.inner == 5) {
        // внутри обычная картинка — подменяем её PNG-байтами, сохраняя префикс
        NSMutableData *raw = [NSMutableData dataWithBytes:b.raw length:b.inner_off];
        [raw appendData:UIImagePNGRepresentation(img)];
        NSData *out = raw;
        if (b.compressed) { size_t ol; uint8_t *pk = gx_spike_pack(raw.bytes, raw.length, &ol); out = [NSData dataWithBytesNoCopy:pk length:ol freeWhenDone:YES]; }
        errStr = [self writeBack:out];
    } else {
        int w, h;
        uint8_t *rgba = GXRGBAFromImage(img, &w, &h);
        if (!rgba) errStr = GXL(@"Не удалось получить пиксели картинки");
        else {
            size_t ol = 0;
            uint8_t *enc = gx_btx_encode(&b, rgba, w, h, &ol, err, sizeof err);
            free(rgba);
            if (!enc) errStr = [NSString stringWithUTF8String:err];
            else errStr = [self writeBack:[NSData dataWithBytesNoCopy:enc length:ol freeWhenDone:YES]];
        }
    }
    NSString *kind = [NSString stringWithUTF8String:b.kind];
    int inner = b.inner;
    gx_btx_free(&b);
    if (errStr) { GXAlert(self, GXL(@"Ошибка"), errStr); return; }
    [self resetImageFrame];
    [self reload];
    NSString *note = inner == 4 ? GXL(@"DDS записан несжатым RGBA (32 бит) — так читается любым загрузчиком DDS.") : inner == 2 ? GXL(@"Цвета подобраны по исходной палитре 256 цветов.") : inner == 1 ? GXL(@"Сохранено как SHTXFf (32 бит).") : @"";
    GXAlert(self, GXL(@"Готово"), [NSString stringWithFormat:GXL(@"Текстура заменена (%@). %@"), kind, note]);
}

- (NSString *)writeBack:(NSData *)data {
    NSString *orig = [self.path stringByAppendingPathExtension:@"orig"];
    if (![NSFileManager.defaultManager fileExistsAtPath:orig]) [NSFileManager.defaultManager copyItemAtPath:self.path toPath:orig error:nil];
    NSError *e = nil;
    if (![data writeToFile:self.path options:NSDataWritingAtomic error:&e]) return e.localizedDescription ?: GXL(@"Запись не удалась");
    return nil;
}

@end

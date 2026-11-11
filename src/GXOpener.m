// Выбор просмотрщика для файла
#import "GXCore.h"
#import <QuickLook/QuickLook.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

@interface GXQLSource : NSObject <QLPreviewControllerDataSource>
@property (nonatomic, strong) NSArray<NSURL *> *urls;
@end
@implementation GXQLSource
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return _urls.count; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i { return _urls[i]; }
@end

static GXQLSource *gxQL;

@implementation GXOpener

+ (void)quickLook:(NSArray<NSString *> *)paths index:(NSInteger)idx from:(UIViewController *)vc {
    if (!paths.count) return;
    gxQL = [GXQLSource new];
    NSMutableArray *u = [NSMutableArray array];
    for (NSString *p0 in paths) {
        NSString *p = p0;
        // Quick Look не узнаёт картинку без расширения — даём копию с нужным расширением
        if (!p.pathExtension.length) {
            int fd = open(p.fileSystemRepresentation, O_RDONLY);
            uint8_t h[12] = {0};
            if (fd >= 0) { read(fd, h, sizeof h); close(fd); }
            NSString *ext = !memcmp(h, "\x89PNG", 4) ? @"png" : (h[0] == 0xFF && h[1] == 0xD8) ? @"jpg" : !memcmp(h, "GIF8", 4) ? @"gif" : !memcmp(h, "%PDF", 4) ? @"pdf" : nil;
            if (ext) {
                NSString *t = [[GXTempDir() stringByAppendingPathComponent:p.lastPathComponent] stringByAppendingPathExtension:ext];
                if ([FM() copyItemAtPath:p toPath:t error:nil]) p = t;
            }
        }
        [u addObject:[NSURL fileURLWithPath:p]];
    }
    gxQL.urls = u;
    QLPreviewController *q = [QLPreviewController new];
    q.dataSource = gxQL;
    q.currentPreviewItemIndex = MAX(0, MIN(idx, (NSInteger)u.count - 1));
    [GXTopVC(vc) presentViewController:q animated:YES completion:nil];
}

+ (void)open:(NSString *)path from:(UIViewController *)vc { [self open:path from:vc readOnly:NO]; }

+ (void)present:(UIViewController *)v from:(UIViewController *)vc {
    GXPresentNav(vc, v, YES);
}

+ (void)openText:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro {
    struct stat st;
    stat(path.fileSystemRepresentation, &st);
    if (st.st_size > 10 * 1024 * 1024) { [self present:[[GXBigTextVC alloc] initWithPath:path] from:vc]; return; }
    GXTextEditorVC *ed = [[GXTextEditorVC alloc] initWithPath:path];
    ed.readOnly = ro;
    [self present:ed from:vc];
}

+ (void)openHex:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro {
    GXHexVC *h = [[GXHexVC alloc] initWithPath:path];
    h.readOnly = ro;
    [self present:h from:vc];
}

+ (BOOL)openPlist:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro {
    NSString *err = nil;
    GXPlistVC *p = [[GXPlistVC alloc] initWithPath:path error:&err];
    if (!p) return NO;
    if (ro) p.readOnly = YES;
    [self present:p from:vc];
    return YES;
}

+ (void)open:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro {
    BOOL isDir = NO;
    if (![FM() fileExistsAtPath:path isDirectory:&isDir]) {
        // битая ссылка
        GXAlert(vc, GXL(@"Не найдено"), [NSString stringWithFormat:GXL(@"«%@» не существует или ссылка битая"), path.lastPathComponent]);
        return;
    }
    if (isDir) {
        GXBrowserVC *b = [[GXBrowserVC alloc] initWithPath:path];
        if (vc.navigationController && !vc.presentingViewController) [vc.navigationController pushViewController:b animated:YES];
        else [self present:b from:vc];
        return;
    }
    if (!ro) GXAddRecent(path);
    if (GXIsTexturePath(path)) { [self present:[[GXTextureVC alloc] initWithPath:path] from:vc]; return; }
    GXKind k = GXKindForPath(path, NO);
    // файлы без расширения (iTunesArtwork, бинарники, конфиги) и неизвестные типы — сразу в текстовый редактор
    BOOL noExt = path.lastPathComponent.pathExtension.length == 0;
    if ((noExt && k != GXKindMachO && k != GXKindSQLite && k != GXKindPlist && k != GXKindArchive) || k == GXKindOther || k == GXKindBinary) {
        [self openText:path from:vc readOnly:ro];
        return;
    }
    switch (k) {
        case GXKindAndroid: [self present:[[GXApkVC alloc] initWithPath:path] from:vc]; return;
        case GXKindIPA: [self present:[[GXIpaVC alloc] initWithPath:path] from:vc]; return;
        case GXKindArchive: [self present:[[GXArchiveVC alloc] initWithArchive:path] from:vc]; return;
        case GXKindPlist: case GXKindStrings: case GXKindJSON: case GXKindProvision:
            if ([self openPlist:path from:vc readOnly:ro || k == GXKindProvision]) return;
            if (k == GXKindProvision) { GXAlert(vc, GXL(@"Ошибка"), GXL(@"Не удалось извлечь plist из профиля")); return; }
            [self openText:path from:vc readOnly:ro];
            return;
        case GXKindSQLite: [self present:[[GXSQLiteVC alloc] initWithPath:path] from:vc]; return;
        case GXKindMachO: case GXKindELF:
            if ([path.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
                // dylib: запустить внутри GX Files или открыть в редакторе бинарника
                UIAlertController *a = [UIAlertController alertControllerWithTitle:path.lastPathComponent message:nil preferredStyle:UIAlertControllerStyleActionSheet];
                [a addAction:[UIAlertAction actionWithTitle:GXL(@"▶︎ Запустить в GX Files") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { GXPresentNav(vc, [[GXDylibRunVC alloc] initWithPath:path], NO); }]];
                [a addAction:[UIAlertAction actionWithTitle:GXL(@"Редактор бинарника (строки, функции, числа)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self present:[[GXBinEditorVC alloc] initWithPath:path] from:vc]; }]];
                [a addAction:[UIAlertAction actionWithTitle:GXL(@"Открыть как…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self openWithMenu:path from:vc sourceView:nil]; }]];
                [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
                a.popoverPresentationController.sourceView = vc.view;
                a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
                [GXTopVC(vc) presentViewController:a animated:YES completion:nil];
                return;
            }
            [self present:[[GXBinEditorVC alloc] initWithPath:path] from:vc]; return;
        case GXKindCar: [self present:[[GXCarVC alloc] initWithPath:path] from:vc]; return;
        case GXKindText: case GXKindCode: [self openText:path from:vc readOnly:ro]; return;
        case GXKindBinary: [self openWithMenu:path from:vc sourceView:nil]; return;
        default: break;
    }
    // Quick Look по всем файлам папки того же рода
    if (k == GXKindImage || k == GXKindVideo) {
        NSString *dir = path.stringByDeletingLastPathComponent;
        NSMutableArray *list = [NSMutableArray array];
        NSInteger idx = 0;
        for (NSString *n in [[FM() contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            GXKind kk = GXKindForName(n, NO);
            if (kk != GXKindImage && kk != GXKindVideo) continue;
            NSString *p = [dir stringByAppendingPathComponent:n];
            if (GXIsTexturePath(p)) continue;
            if ([p isEqualToString:path]) idx = list.count;
            [list addObject:p];
        }
        if (list.count) { [self quickLook:list index:idx from:vc]; return; }
    }
    [self quickLook:@[path] index:0 from:vc];
}

+ (void)openWithMenu:(NSString *)path from:(UIViewController *)vc sourceView:(UIView *)sv {
    struct stat st;
    stat(path.fileSystemRepresentation, &st);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:path.lastPathComponent message:[NSString stringWithFormat:@"%@ · %@", GXKindTitle(GXKindForPath(path, NO)), GXHuman((unsigned long long)st.st_size)] preferredStyle:UIAlertControllerStyleActionSheet];
    void (^add)(NSString *, void (^)(void)) = ^(NSString *t, void (^b)(void)) {
        [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { b(); }]];
    };
    add(@"Quick Look", ^{ [self quickLook:@[path] index:0 from:vc]; });
    add(GXL(@"Текстовый редактор"), ^{ [self openText:path from:vc readOnly:NO]; });
    if (st.st_size > 512 * 1024) add(GXL(@"Просмотр большого текста"), ^{ [self present:[[GXBigTextVC alloc] initWithPath:path] from:vc]; });
    add(GXL(@"Как текстуру (.btx / .dds / SHTX)"), ^{ [self present:[[GXTextureVC alloc] initWithPath:path] from:vc]; });
    add(GXL(@"Hex-редактор"), ^{ [self openHex:path from:vc readOnly:NO]; });
    add(GXL(@"Как plist / JSON / .strings"), ^{ if (![self openPlist:path from:vc readOnly:NO]) GXAlert(vc, GXL(@"Не получилось"), GXL(@"Файл не разбирается как plist или JSON")); });
    add(GXL(@"Как базу SQLite"), ^{ [self present:[[GXSQLiteVC alloc] initWithPath:path] from:vc]; });
    add(GXL(@"Как архив"), ^{ [self present:[[GXArchiveVC alloc] initWithArchive:path] from:vc]; });
    add(GXL(@"Как APK (Android)"), ^{ [self present:[[GXApkVC alloc] initWithPath:path] from:vc]; });
    if ([@[@"c", @"h"] containsObject:path.pathExtension.lowercaseString] && [GXCodeLanguageForPath(path)[@"kind"] intValue] == 0)
        add(GXL(@"Скомпилировать в dylib (C → arm64)"), ^{ GXPresentNav(vc, [[GXCompilerVC alloc] initWithPath:path], YES); });
    else if (GXCodeLanguageForPath(path))
        add([NSString stringWithFormat:GXL(@"Запустить код (%@)"), GXCodeLanguageForPath(path)[@"name"]], ^{ GXPresentNav(vc, [[GXCompilerVC alloc] initWithPath:path], YES); });
    if ([path.pathExtension.lowercaseString isEqualToString:@"dylib"])
        add(GXL(@"▶︎ Запустить dylib в GX Files"), ^{ GXPresentNav(vc, [[GXDylibRunVC alloc] initWithPath:path], NO); });
    add(GXL(@"Редактор бинарника (строки, функции, числа)"), ^{ [self present:[[GXBinEditorVC alloc] initWithPath:path] from:vc]; });
    add(GXL(@"Сведения Mach-O"), ^{ [self present:[[GXReportVC alloc] initWithTitle:path.lastPathComponent text:GXMachOReport(path)] from:vc]; });
    add(GXL(@"Сведения ELF (.so)"), ^{ [self present:[[GXReportVC alloc] initWithTitle:path.lastPathComponent text:GXELFReport(path)] from:vc]; });
    add(GXL(@"Поделиться…"), ^{
        UIActivityViewController *av = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
        av.popoverPresentationController.sourceView = sv ?: vc.view;
        av.popoverPresentationController.sourceRect = (sv ?: vc.view).bounds;
        [GXTopVC(vc) presentViewController:av animated:YES completion:nil];
    });
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = sv ?: vc.view;
    a.popoverPresentationController.sourceRect = sv ? sv.bounds : CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
    [GXTopVC(vc) presentViewController:a animated:YES completion:nil];
}
@end

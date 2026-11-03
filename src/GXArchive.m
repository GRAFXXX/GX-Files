// Архивы: ZIP-семейство через собственный ридер, остальное — через системный libarchive
#import "GXCore.h"
#include <sys/stat.h>
#include <fcntl.h>
#include "core/gx_zip.h"
#include "core/gx_apk.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "la/archive.h"
#include "la/archive_entry.h"

@implementation GXArcEntry
@end

static NSString *GXZipName(const gxz_entry *e) {
    NSData *d = [NSData dataWithBytes:e->name length:e->name_len];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s && !(e->flags & 0x800)) s = [[NSString alloc] initWithData:d encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSRussian)];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    return [s stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] ?: @"?";
}

static NSDate *GXDosDate(uint32_t t) {
    NSDateComponents *c = [NSDateComponents new];
    c.year = 1980 + ((t >> 25) & 0x7F);
    c.month = (t >> 21) & 0xF;
    c.day = (t >> 16) & 0x1F;
    c.hour = (t >> 11) & 0x1F;
    c.minute = (t >> 5) & 0x3F;
    c.second = (t & 0x1F) * 2;
    return [NSCalendar.currentCalendar dateFromComponents:c];
}

// Безопасный относительный путь (без .. и абсолютных путей)
static NSString *GXSafeRel(NSString *p) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *c in [p componentsSeparatedByString:@"/"]) {
        if (!c.length || [c isEqualToString:@"."] || [c isEqualToString:@".."]) continue;
        [out addObject:c];
    }
    return [out componentsJoinedByString:@"/"];
}

static void GXApplyArchiveOptions(struct archive *a) {
    archive_read_support_format_all(a);
    archive_read_support_filter_all(a);
    archive_read_support_format_raw(a);
}

NSArray<GXArcEntry *> *GXArchiveList(NSString *path, NSString **err) {
    NSMutableArray *r = [NSMutableArray array];
    if (GXIsZipFamily(path)) {
        gxz z;
        if (!gxz_open(&z, path.fileSystemRepresentation, 0, 0)) { if (err) *err = @(z.err); return nil; }
        for (size_t i = 0; i < z.n; i++) {
            GXArcEntry *e = [GXArcEntry new];
            NSString *n = GXZipName(&z.e[i]);
            e.isDir = [n hasSuffix:@"/"];
            e.path = GXSafeRel(n);
            e.rawName = [NSString stringWithUTF8String:z.e[i].name] ?: n;
            if (!e.path.length) continue;
            e.size = z.e[i].usize;
            e.csize = z.e[i].csize;
            e.date = GXDosDate(z.e[i].dostime);
            e.index = (long)i;
            e.isLink = ((z.e[i].ext_attr >> 16) & S_IFMT) == S_IFLNK;
            [r addObject:e];
        }
        gxz_close(&z);
        return r;
    }
    struct archive *a = archive_read_new();
    GXApplyArchiveOptions(a);
    if (archive_read_open_filename(a, path.fileSystemRepresentation, 1 << 16) != ARCHIVE_OK) {
        if (err) *err = @(archive_error_string(a) ?: GXT("не удалось открыть архив"));
        archive_read_free(a);
        return nil;
    }
    struct archive_entry *en;
    long idx = 0;
    BOOL raw = NO;
    while (1) {
        int rc = archive_read_next_header(a, &en);
        if (rc == ARCHIVE_EOF) break;
        if (rc < ARCHIVE_WARN) { if (err && !r.count) *err = @(archive_error_string(a) ?: GXT("ошибка чтения")); break; }
        const char *pn = archive_entry_pathname_utf8(en) ?: archive_entry_pathname(en);
        GXArcEntry *e = [GXArcEntry new];
        NSString *name = pn ? (@(pn) ?: [[NSString alloc] initWithBytes:pn length:strlen(pn) encoding:NSISOLatin1StringEncoding]) : @"data";
        if (archive_format(a) == ARCHIVE_FORMAT_RAW) {
            raw = YES;
            NSString *base = path.lastPathComponent;
            for (NSString *x in @[@".gz", @".bz2", @".xz", @".lzma", @".z", @".zst"]) if ([base.lowercaseString hasSuffix:x]) base = [base substringToIndex:base.length - x.length];
            name = base;
        }
        e.isDir = archive_entry_filetype(en) == AE_IFDIR;
        e.isLink = archive_entry_filetype(en) == AE_IFLNK;
        e.path = GXSafeRel(name);
        e.size = archive_entry_size_is_set(en) ? (unsigned long long)archive_entry_size(en) : 0;
        e.csize = 0;
        e.date = archive_entry_mtime_is_set(en) ? [NSDate dateWithTimeIntervalSince1970:archive_entry_mtime(en)] : nil;
        e.index = idx++;
        if (e.path.length) [r addObject:e];
        archive_read_data_skip(a);
        if (raw) break;
    }
    archive_read_free(a);
    return r;
}

static NSString *GXWriteFromArchive(struct archive *a, NSString *dest) {
    [FM() createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return [NSString stringWithFormat:GXL(@"не создать %@"), dest.lastPathComponent];
    const void *buf;
    size_t size;
    la_int64_t off;
    NSString *err = nil;
    while (1) {
        int rc = archive_read_data_block(a, &buf, &size, &off);
        if (rc == ARCHIVE_EOF) break;
        if (rc < ARCHIVE_WARN) { err = @(archive_error_string(a) ?: GXT("ошибка распаковки")); break; }
        if (pwrite(fd, buf, size, off) != (ssize_t)size) { err = GXL(@"ошибка записи"); break; }
    }
    close(fd);
    return err;
}

NSString *GXArchiveExtractEntry(NSString *path, GXArcEntry *entry, NSString *destFile) {
    if (GXIsZipFamily(path)) {
        gxz z;
        if (!gxz_open(&z, path.fileSystemRepresentation, 0, 0)) return @(z.err);
        NSString *err = nil;
        if (entry.index < 0 || (size_t)entry.index >= z.n) err = GXL(@"запись не найдена");
        else {
            [FM() createDirectoryAtPath:destFile.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            int fd = open(destFile.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) err = GXL(@"не создать файл");
            else {
                if (!gxz_extract_fd(&z, &z.e[entry.index], fd, NULL)) err = @(z.err);
                close(fd);
            }
        }
        gxz_close(&z);
        return err;
    }
    struct archive *a = archive_read_new();
    GXApplyArchiveOptions(a);
    if (archive_read_open_filename(a, path.fileSystemRepresentation, 1 << 16) != ARCHIVE_OK) {
        NSString *e = @(archive_error_string(a) ?: GXT("не открыть"));
        archive_read_free(a);
        return e;
    }
    struct archive_entry *en;
    long idx = 0;
    NSString *err = GXL(@"запись не найдена");
    while (archive_read_next_header(a, &en) >= ARCHIVE_WARN) {
        if (idx == entry.index) { err = GXWriteFromArchive(a, destFile); break; }
        idx++;
        archive_read_data_skip(a);
    }
    archive_read_free(a);
    return err;
}

NSString *GXZipExtractEntries(NSString *zipPath, NSArray<NSString *> *names, NSString *destDir, BOOL flatten) {
    gxz z;
    if (!gxz_open(&z, zipPath.fileSystemRepresentation, 0, 0)) return @(z.err);
    NSMutableString *errs = [NSMutableString string];
    for (size_t i = 0; i < z.n; i++) {
        NSString *n = GXZipName(&z.e[i]);
        if (names && ![names containsObject:n]) continue;
        NSString *rel = GXSafeRel(n);
        if (!rel.length) continue;
        if ([n hasSuffix:@"/"]) {
            if (!flatten) [FM() createDirectoryAtPath:[destDir stringByAppendingPathComponent:rel] withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        NSString *dest = [destDir stringByAppendingPathComponent:flatten ? rel.lastPathComponent : rel];
        [FM() createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        int fd = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { [errs appendFormat:GXL(@"%@: не создать\n"), rel]; continue; }
        if (!gxz_extract_fd(&z, &z.e[i], fd, NULL)) [errs appendFormat:@"%@: %s\n", rel, z.err];
        close(fd);
        mode_t mode = (z.e[i].ext_attr >> 16) & 0777;
        if (mode) chmod(dest.fileSystemRepresentation, mode | 0600);
    }
    gxz_close(&z);
    return errs.length ? errs : nil;
}

NSString *GXArchiveExtractAll(NSString *path, NSString *destDir, void (^progress)(double)) {
    [FM() createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    struct stat st;
    stat(path.fileSystemRepresentation, &st);
    double total = MAX(1, (double)st.st_size);
    if (GXIsZipFamily(path)) {
        gxz z;
        if (!gxz_open(&z, path.fileSystemRepresentation, 0, 0)) return @(z.err);
        NSMutableString *errs = [NSMutableString string];
        uint64_t done = 0;
        for (size_t i = 0; i < z.n; i++) {
            if ([GXHUD cancelled]) { [errs appendString:GXL(@"Отменено\n")]; break; }
            NSString *n = GXZipName(&z.e[i]);
            NSString *rel = GXSafeRel(n);
            if (!rel.length) continue;
            NSString *dest = [destDir stringByAppendingPathComponent:rel];
            if ([n hasSuffix:@"/"]) { [FM() createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil]; continue; }
            [FM() createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (((z.e[i].ext_attr >> 16) & S_IFMT) == S_IFLNK) {
                uint8_t *d; size_t l;
                if (gxz_read(&z, &z.e[i], 4096, &d, &l)) {
                    NSString *target = [[NSString alloc] initWithBytes:d length:l encoding:NSUTF8StringEncoding];
                    free(d);
                    if (target) { [FM() removeItemAtPath:dest error:nil]; [FM() createSymbolicLinkAtPath:dest withDestinationPath:target error:nil]; }
                }
                continue;
            }
            int fd = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd < 0) { [errs appendFormat:GXL(@"%@: не создать\n"), rel]; continue; }
            if (!gxz_extract_fd(&z, &z.e[i], fd, NULL)) [errs appendFormat:@"%@: %s\n", rel, z.err];
            close(fd);
            mode_t mode = (z.e[i].ext_attr >> 16) & 0777;
            if (mode) chmod(dest.fileSystemRepresentation, mode | 0600);
            NSDate *dt = GXDosDate(z.e[i].dostime);
            if (dt) [FM() setAttributes:@{NSFileModificationDate: dt} ofItemAtPath:dest error:nil];
            done += z.e[i].csize;
            if (progress) progress(done / total);
        }
        gxz_close(&z);
        return errs.length ? errs : nil;
    }
    struct archive *a = archive_read_new();
    GXApplyArchiveOptions(a);
    if (archive_read_open_filename(a, path.fileSystemRepresentation, 1 << 16) != ARCHIVE_OK) {
        NSString *e = @(archive_error_string(a) ?: GXT("не удалось открыть архив"));
        archive_read_free(a);
        return e;
    }
    struct archive *w = archive_write_disk_new();
    archive_write_disk_set_options(w, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM | ARCHIVE_EXTRACT_SECURE_NODOTDOT | ARCHIVE_EXTRACT_SECURE_SYMLINKS);
    struct archive_entry *en;
    NSMutableString *errs = [NSMutableString string];
    BOOL raw = NO;
    while (1) {
        if ([GXHUD cancelled]) { [errs appendString:GXL(@"Отменено\n")]; break; }
        int rc = archive_read_next_header(a, &en);
        if (rc == ARCHIVE_EOF) break;
        if (rc < ARCHIVE_WARN) { [errs appendFormat:@"%s\n", archive_error_string(a) ?: GXT("ошибка")]; break; }
        const char *pn = archive_entry_pathname_utf8(en) ?: archive_entry_pathname(en);
        NSString *name = pn ? @(pn) : nil;
        if (archive_format(a) == ARCHIVE_FORMAT_RAW) {
            raw = YES;
            NSString *base = path.lastPathComponent;
            for (NSString *x in @[@".gz", @".bz2", @".xz", @".lzma", @".z", @".zst"]) if ([base.lowercaseString hasSuffix:x]) base = [base substringToIndex:base.length - x.length];
            if ([base isEqualToString:path.lastPathComponent]) base = [base stringByAppendingString:@".out"];
            NSString *dest = [destDir stringByAppendingPathComponent:base];
            NSString *e = GXWriteFromArchive(a, dest);
            if (e) [errs appendString:e];
            break;
        }
        NSString *rel = GXSafeRel(name ?: @"");
        if (!rel.length) { archive_read_data_skip(a); continue; }
        archive_entry_set_pathname_utf8(en, [destDir stringByAppendingPathComponent:rel].UTF8String);
        const char *hl = archive_entry_hardlink(en);
        if (hl) archive_entry_set_hardlink(en, [destDir stringByAppendingPathComponent:GXSafeRel(@(hl))].fileSystemRepresentation);
        rc = archive_write_header(w, en);
        if (rc < ARCHIVE_WARN) { [errs appendFormat:@"%@: %s\n", rel, archive_error_string(w) ?: "?"]; archive_read_data_skip(a); continue; }
        if (archive_entry_size(en) > 0) {
            const void *buf; size_t size; la_int64_t off;
            while (1) {
                int r2 = archive_read_data_block(a, &buf, &size, &off);
                if (r2 == ARCHIVE_EOF) break;
                if (r2 < ARCHIVE_WARN) { [errs appendFormat:@"%@: %s\n", rel, archive_error_string(a) ?: "?"]; break; }
                if (archive_write_data_block(w, buf, size, off) < ARCHIVE_WARN) { [errs appendFormat:GXL(@"%@: запись\n"), rel]; break; }
            }
        }
        archive_write_finish_entry(w);
        if (progress) progress((double)archive_filter_bytes(a, -1) / total);
    }
    (void)raw;
    archive_write_free(w);
    archive_read_free(a);
    return errs.length ? errs : nil;
}

static NSString *GXAddToArchive(struct archive *w, NSString *src, NSString *rel, unsigned long long *done, double total, void (^progress)(double)) {
    struct stat st;
    if (lstat(src.fileSystemRepresentation, &st) != 0) return [NSString stringWithFormat:GXL(@"%@: нет доступа"), rel];
    if ([GXHUD cancelled]) return GXL(@"Отменено");
    struct archive_entry *en = archive_entry_new();
    archive_entry_copy_stat(en, &st);
    archive_entry_set_pathname_utf8(en, rel.UTF8String);
    NSString *err = nil;
    if (S_ISLNK(st.st_mode)) {
        NSString *dest = [FM() destinationOfSymbolicLinkAtPath:src error:nil];
        archive_entry_set_symlink_utf8(en, dest.UTF8String ?: "");
        archive_write_header(w, en);
    } else if (S_ISDIR(st.st_mode)) {
        archive_write_header(w, en);
        for (NSString *n in [FM() contentsOfDirectoryAtPath:src error:nil]) {
            err = GXAddToArchive(w, [src stringByAppendingPathComponent:n], [rel stringByAppendingPathComponent:n], done, total, progress);
            if (err) break;
        }
    } else if (S_ISREG(st.st_mode)) {
        if (archive_write_header(w, en) < ARCHIVE_WARN) err = [NSString stringWithFormat:@"%@: %s", rel, archive_error_string(w) ?: "?"];
        int fd = err ? -1 : open(src.fileSystemRepresentation, O_RDONLY);
        if (fd >= 0) {
            const size_t CH = 1 << 20;
            char *buf = malloc(CH);
            ssize_t n;
            while ((n = read(fd, buf, CH)) > 0) {
                if (archive_write_data(w, buf, (size_t)n) < 0) { err = [NSString stringWithFormat:@"%@: %s", rel, archive_error_string(w) ?: GXT("запись")]; break; }
                *done += (unsigned long long)n;
                if (progress) progress(*done / total);
                if ([GXHUD cancelled]) { err = GXL(@"Отменено"); break; }
            }
            free(buf);
            close(fd);
        }
    }
    archive_entry_free(en);
    return err;
}

static unsigned long long GXTreeSize(NSString *p) {
    BOOL d = NO;
    if (![FM() fileExistsAtPath:p isDirectory:&d]) return 0;
    if (!d) return [[FM() attributesOfItemAtPath:p error:nil] fileSize];
    unsigned long long t = 0;
    NSDirectoryEnumerator *en = [FM() enumeratorAtPath:p];
    for (NSString *x in en) t += [en.fileAttributes fileSize];
    return t;
}

NSString *GXArchiveCreate(NSArray<NSString *> *paths, NSString *dest, NSString *format, void (^progress)(double)) {
    struct archive *w = archive_write_new();
    if ([format isEqualToString:@"tar.gz"]) { archive_write_set_format_pax_restricted(w); archive_write_add_filter_gzip(w); }
    else if ([format isEqualToString:@"tar.xz"]) { archive_write_set_format_pax_restricted(w); archive_write_add_filter_xz(w); }
    else if ([format isEqualToString:@"tar"]) { archive_write_set_format_pax_restricted(w); }
    else if ([format isEqualToString:@"7z"]) { archive_write_set_format_7zip(w); }
    else { archive_write_set_format_zip(w); archive_write_set_options(w, "zip:hdrcharset=UTF-8"); }
    if (archive_write_open_filename(w, dest.fileSystemRepresentation) != ARCHIVE_OK) {
        NSString *e = @(archive_error_string(w) ?: GXT("не создать архив"));
        archive_write_free(w);
        return e;
    }
    double total = 1;
    for (NSString *p in paths) total += GXTreeSize(p);
    unsigned long long done = 0;
    NSString *err = nil;
    for (NSString *p in paths) {
        err = GXAddToArchive(w, p, p.lastPathComponent, &done, total, progress);
        if (err) break;
    }
    archive_write_close(w);
    archive_write_free(w);
    if (err) [FM() removeItemAtPath:dest error:nil];
    return err;
}

#pragma mark - Просмотр архива


@interface GXArchiveVC () <UISearchResultsUpdating, UIDocumentPickerDelegate>
- (instancetype)initWithModel:(GXArcModel *)m prefix:(NSString *)prefix;
@end

static GXArcEntry *_replaceTarget;

@implementation GXArchiveVC {
    GXArcModel *_m;
    NSString *_prefix;              // текущая «папка» внутри архива ("" — корень)
    NSArray *_rows;                 // GXArcEntry либо NSString (имя подпапки)
    NSString *_error;
    UISearchController *_search;
    BOOL _loaded;
}

- (instancetype)initWithArchive:(NSString *)path { return [self initWithModel:[GXArcModel modelFor:path] prefix:@""]; }

- (instancetype)initWithModel:(GXArcModel *)m prefix:(NSString *)prefix {
    if ((self = [super initWithStyle:UITableViewStylePlain])) { _m = m; _prefix = prefix; }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _prefix.length ? _prefix.lastPathComponent : _m.path.lastPathComponent;
    self.tableView.rowHeight = 56;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = GXL(@"Поиск по именам во всём архиве");
    self.navigationItem.searchController = _search;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    [self buildItems];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:GXArcChangedNotification object:_m];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    if (!_m.entries.count) {
        [GXHUD showIn:self.view text:GXL(@"Читаю архив…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *err = [self->_m reload];
            dispatch_async(dispatch_get_main_queue(), ^{ [GXHUD hide]; self->_error = err; self->_loaded = YES; [self rebuild]; });
        });
    } else { _loaded = YES; [self rebuild]; }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:!_m.editable animated:animated];
    [self updateToolbar];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [GXArcModel commitAllFrom:self]; }
- (void)becameActive { if (self.view.window) [GXArcModel commitAllFrom:self]; }
- (void)changed:(NSNotification *)n { [self rebuild]; [self updateToolbar]; }
- (void)close { [GXArcModel commitAllFrom:self]; [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSString *)prefixSlash { return _prefix.length ? [_prefix stringByAppendingString:@"/"] : @""; }

- (void)buildItems {
    __weak typeof(self) ws = self;
    NSMutableArray *acts = [NSMutableArray array];
    [acts addObject:[UIAction actionWithTitle:GXL(@"Найти и заменить текст в архиве") image:[UIImage systemImageNamed:@"text.magnifyingglass"] identifier:nil handler:^(UIAction *a) {
        [ws.navigationController pushViewController:[[GXFindVC alloc] initWithRoot:self->_m.path] animated:YES]; }]];
    if (_m.isAPK) {
        [acts addObject:[UIAction actionWithTitle:GXL(@"Подписать APK") image:[UIImage systemImageNamed:@"signature"] identifier:nil handler:^(UIAction *a) { [ws sign]; }]];
        [acts addObject:[UIAction actionWithTitle:GXL(@"Сведения об APK") image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) {
            [ws.navigationController pushViewController:[[GXApkVC alloc] initWithPath:self->_m.path] animated:YES]; }]];
    }
    [acts addObject:[UIAction actionWithTitle:GXL(@"Выбрать") image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *a) { [ws setEditing:YES animated:YES]; }]];
    [acts addObject:[UIAction actionWithTitle:GXL(@"Распаковать всё рядом") image:[UIImage systemImageNamed:@"arrow.down.doc"] identifier:nil handler:^(UIAction *a) { [ws extractAll]; }]];
    if (_prefix.length) [acts addObject:[UIAction actionWithTitle:GXL(@"Распаковать эту папку") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) { [ws extractFolder]; }]];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"" children:acts]];
    if (!_m.editable) { self.navigationItem.rightBarButtonItems = @[more]; return; }
    UIMenu *add = [UIMenu menuWithTitle:GXL(@"Добавить в архив") children:@[
        [UIAction actionWithTitle:GXL(@"Файлы из «Файлов»") image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) { [ws importFiles]; }],
        [UIAction actionWithTitle:GXL(@"Из буфера GX Files") image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *a) { [ws addFromClip]; }],
        [UIAction actionWithTitle:GXL(@"Новый файл") image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws newFile]; }],
        [UIAction actionWithTitle:GXL(@"Новая папка") image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws newFolder]; }]]];
    self.navigationItem.rightBarButtonItems = @[more, [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle"] menu:add]];
}

- (void)updateToolbar {
    if (!_m.editable) return;
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    if (self.editing) {
        BOOL any = self.tableView.indexPathsForSelectedRows.count > 0;
        UIBarButtonItem *ex = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(extractSelected)];
        UIBarButtonItem *del = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"] style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelected)];
        del.tintColor = UIColor.systemRedColor;
        UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(endSelect)];
        ex.enabled = del.enabled = any;
        self.toolbarItems = @[ex, flex, del, flex, done];
        return;
    }
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = _m.modifiedSinceSign ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
    l.text = _m.modifiedSinceSign ? GXL(@"APK изменён — подпись снята") : GXL(@"Правки сохраняются в архив сразу");
    [l sizeToFit];
    NSMutableArray *items = [NSMutableArray arrayWithObjects:flex, [[UIBarButtonItem alloc] initWithCustomView:l], flex, nil];
    if (_m.isAPK) [items addObject:[[UIBarButtonItem alloc] initWithTitle:GXL(@"Подписать") style:_m.modifiedSinceSign ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain target:self action:@selector(sign)]];
    self.toolbarItems = items;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated { [super setEditing:editing animated:animated]; [self updateToolbar]; }
- (void)endSelect { [self setEditing:NO animated:YES]; }
- (void)tableView:(UITableView *)tv didDeselectRowAtIndexPath:(NSIndexPath *)ip { if (self.editing) [self updateToolbar]; }

- (void)rebuild {
    NSString *q = _search.searchBar.text;
    NSArray *all = _m.entries;
    if (q.length) {
        _rows = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(GXArcEntry *e, id b) {
            return !e.isDir && [e.path.lastPathComponent localizedCaseInsensitiveContainsString:q];
        }]];
        [self.tableView reloadData];
        return;
    }
    NSMutableOrderedSet *dirs = [NSMutableOrderedSet orderedSet];
    NSMutableArray *files = [NSMutableArray array];
    NSString *pre = [self prefixSlash];
    for (GXArcEntry *e in all) {
        if (pre.length && ![e.path hasPrefix:pre]) continue;
        NSString *rest = [e.path substringFromIndex:pre.length];
        if (!rest.length) continue;
        NSRange sl = [rest rangeOfString:@"/"];
        if (sl.location != NSNotFound) [dirs addObject:[rest substringToIndex:sl.location]];
        else if (e.isDir) [dirs addObject:rest];
        else [files addObject:e];
    }
    NSArray *ds = [dirs.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    [files sortUsingComparator:^NSComparisonResult(GXArcEntry *a, GXArcEntry *b) { return [a.path.lastPathComponent localizedStandardCompare:b.path.lastPathComponent]; }];
    _rows = [ds arrayByAddingObjectsFromArray:files];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc { [self rebuild]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (_error) return [NSString stringWithFormat:GXL(@"Не удалось открыть: %@"), _error];
    if (!_prefix.length && _loaded) {
        unsigned long long t = 0, c = 0;
        for (GXArcEntry *e in _m.entries) { t += e.size; c += e.csize; }
        NSString *base = [NSString stringWithFormat:GXL(@"Записей: %lu · распаковано %@%@"), (unsigned long)_m.entries.count, GXHuman(t), c ? [NSString stringWithFormat:GXL(@" · сжато %@"), GXHuman(c)] : @""];
        if (_m.editable) base = [base stringByAppendingString:GXL(@"\nОткрытые файлы можно править — после закрытия редактора изменения записываются прямо в архив, без распаковки. Долгое нажатие — заменить, переименовать, удалить.")];
        else base = [base stringByAppendingString:GXL(@"\nЭтот формат только для чтения (редактировать можно zip, apk, ipa, jar и т.п.).")];
        return base;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"a"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"a"];
    id row = _rows[ip.row];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if ([row isKindOfClass:NSString.class]) {
        c.imageView.image = GXSymbolTile(@"folder.fill", UIColor.systemBlueColor, 36);
        c.textLabel.text = row;
        c.detailTextLabel.text = GXL(@"Папка");
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        GXArcEntry *e = row;
        GXKind k = GXKindForName(e.path.lastPathComponent, NO);
        c.imageView.image = GXSymbolTile(GXSymbolForKind(k), GXColorForKind(k), 36);
        c.textLabel.text = _search.searchBar.text.length ? e.path : e.path.lastPathComponent;
        c.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        NSString *date = e.date ? [GXDateFmt() stringFromDate:e.date] : @"";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@%@ · %@", GXHuman(e.size), e.csize ? [NSString stringWithFormat:@" (%@)", GXHuman(e.csize)] : @"", date];
        c.accessoryType = UITableViewCellAccessoryNone;
    }
    return c;
}

- (NSString *)folderPathForRow:(NSString *)name { return _prefix.length ? [_prefix stringByAppendingPathComponent:name] : name; }

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editing) { [self updateToolbar]; return; }
    [tv deselectRowAtIndexPath:ip animated:YES];
    id row = _rows[ip.row];
    if ([row isKindOfClass:NSString.class]) {
        [self.navigationController pushViewController:[[GXArchiveVC alloc] initWithModel:_m prefix:[self folderPathForRow:row]] animated:YES];
        return;
    }
    GXArcEntry *e = row;
    if (_m.isAPK && [e.path.pathExtension.lowercaseString isEqualToString:@"xml"]) {
        char *t = gx_apk_xml_text(_m.path.fileSystemRepresentation, 0, 0, e.rawName.UTF8String ?: e.path.UTF8String);
        if (t) {
            NSString *s = @(t) ?: @"";
            free(t);
            GXTextEditorVC *ed = [[GXTextEditorVC alloc] initWithText:s title:[e.path.lastPathComponent stringByAppendingString:GXL(@" (бинарный XML, просмотр)")]];
            ed.highlightExt = @"xml";
            GXPresentNav(self, ed, YES);
            return;
        }
    }
    [_m openEntry:e from:self];
}

// все записи внутри «папки» архива
- (NSArray<GXArcEntry *> *)entriesUnder:(NSString *)folder {
    NSString *pre = [folder stringByAppendingString:@"/"];
    NSMutableArray *r = [NSMutableArray array];
    for (GXArcEntry *e in _m.entries) if ([e.path hasPrefix:pre] || [e.path isEqualToString:folder]) [r addObject:e];
    return r;
}

- (NSArray<GXArcEntry *> *)entriesForRows:(NSArray *)rows {
    NSMutableArray *r = [NSMutableArray array];
    for (id row in rows) {
        if ([row isKindOfClass:NSString.class]) [r addObjectsFromArray:[self entriesUnder:[self folderPathForRow:row]]];
        else [r addObject:row];
    }
    return r;
}

- (NSArray *)selectedRows {
    NSMutableArray *r = [NSMutableArray array];
    for (NSIndexPath *ip in self.tableView.indexPathsForSelectedRows) [r addObject:_rows[ip.row]];
    return r;
}

- (void)deleteRows:(NSArray *)rows {
    NSArray *es = [self entriesForRows:rows];
    if (!es.count) return;
    GXConfirm(self, GXL(@"Удалить из архива?"), [NSString stringWithFormat:GXL(@"Записей: %lu"), (unsigned long)es.count], GXL(@"Удалить"), YES, ^{
        NSMutableArray *ops = [NSMutableArray array];
        for (GXArcEntry *e in es) if (e.rawName) [ops addObject:@{@"name": e.rawName, @"del": @YES}];
        [self setEditing:NO animated:YES];
        [self->_m apply:ops from:self title:GXL(@"Удаляю из архива…") done:nil];
    });
}
- (void)deleteSelected { [self deleteRows:[self selectedRows]]; }

- (void)extractRows:(NSArray *)rows { [self extractEntries:[self entriesForRows:rows]]; }
- (void)extractEntries:(NSArray<GXArcEntry *> *)es {
    NSString *dest = GXUniquePath(_m.path.stringByDeletingLastPathComponent, [_m.path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:GXL(@" (извлечено)")]);
    NSMutableArray *names = [NSMutableArray array];
    for (GXArcEntry *e in es) if (e.rawName) [names addObject:e.rawName];
    NSString *arc = _m.path;
    [self setEditing:NO animated:YES];
    GXRunBG(self, GXL(@"Извлекаю…"), ^NSString *{ return GXZipExtractEntries(arc, names, dest, NO); },
            ^{ GXToast(self.view, [NSString stringWithFormat:GXL(@"Извлечено в «%@»"), dest.lastPathComponent]); });
}
- (void)extractSelected { [self extractRows:[self selectedRows]]; }

- (void)renameRow:(id)row {
    BOOL folder = [row isKindOfClass:NSString.class];
    NSString *old = folder ? row : ((GXArcEntry *)row).path.lastPathComponent;
    GXPrompt(self, folder ? GXL(@"Переименовать папку в архиве") : GXL(@"Переименовать запись"), nil, old, nil, GXL(@"Готово"), ^(NSString *nn) {
        nn = [nn stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!nn.length || [nn isEqualToString:old] || [nn containsString:@"/"]) return;
        NSMutableArray *ops = [NSMutableArray array];
        if (folder) {
            NSString *from = [self folderPathForRow:row], *to = [self folderPathForRow:nn];
            for (GXArcEntry *e in [self entriesUnder:from]) {
                if (!e.rawName) continue;
                NSString *tail = [e.rawName substringFromIndex:MIN(e.rawName.length, from.length)];
                [ops addObject:@{@"name": e.rawName, @"newName": [to stringByAppendingString:tail]}];
            }
        } else {
            GXArcEntry *e = row;
            NSString *np = [[self prefixSlash] stringByAppendingString:nn];
            if ([self->_m entryNamed:np]) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Такая запись уже есть")); return; }
            [ops addObject:@{@"name": e.rawName, @"newName": np}];
        }
        [self->_m apply:ops from:self title:GXL(@"Переименовываю…") done:nil];
    });
}

- (void)replaceEntry:(GXArcEntry *)e {
    _replaceTarget = e;
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    dp.delegate = self;
    [self presentViewController:dp animated:YES completion:nil];
}


- (void)importFiles {
    _replaceTarget = nil;
    UIDocumentPickerViewController *dp = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    dp.allowsMultipleSelection = YES;
    dp.delegate = self;
    [self presentViewController:dp animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *ops = [NSMutableArray array];
    NSString *tmp = GXTempDir();
    for (NSURL *u in urls) {
        BOOL sc = [u startAccessingSecurityScopedResource];
        NSString *local = [tmp stringByAppendingPathComponent:u.lastPathComponent];
        [FM() copyItemAtURL:u toURL:[NSURL fileURLWithPath:local] error:nil];
        if (sc) [u stopAccessingSecurityScopedResource];
        if (_replaceTarget) { [ops addObject:@{@"name": _replaceTarget.rawName, @"src": local}]; break; }
        [self addOps:ops path:local name:u.lastPathComponent];
    }
    GXArcEntry *t = _replaceTarget;
    _replaceTarget = nil;
    [_m apply:ops from:self title:t ? GXL(@"Заменяю…") : GXL(@"Добавляю в архив…") done:nil];
}

// файл или папку — рекурсивно — в ops с текущим префиксом
- (void)addOps:(NSMutableArray *)ops path:(NSString *)p name:(NSString *)name {
    NSString *base = [[self prefixSlash] stringByAppendingString:name];
    if (GXIsDir(p)) {
        NSDirectoryEnumerator *en = [FM() enumeratorAtPath:p];
        for (NSString *rel in en) {
            NSString *full = [p stringByAppendingPathComponent:rel];
            if (GXIsDir(full)) continue;
            NSString *nm = [base stringByAppendingPathComponent:rel];
            [ops addObject:@{@"name": nm, @"src": full}];
        }
    } else [ops addObject:@{@"name": base, @"src": p}];
}

- (void)addFromClip {
    NSArray *clip = GXClipboardPaths();
    if (!clip.count) { GXToast(self.view, GXL(@"Буфер пуст: скопируйте файлы в браузере GX Files")); return; }
    NSMutableArray *ops = [NSMutableArray array];
    for (NSString *p in clip) [self addOps:ops path:p name:p.lastPathComponent];
    [_m apply:ops from:self title:GXL(@"Добавляю в архив…") done:nil];
}

- (void)newFile {
    GXPrompt(self, GXL(@"Новый файл в архиве"), nil, @"new.txt", nil, GXL(@"Создать"), ^(NSString *n) {
        if (!n.length || [n containsString:@"/"]) return;
        [self->_m apply:@[@{@"name": [[self prefixSlash] stringByAppendingString:n], @"data": [NSData data]}] from:self title:GXL(@"Создаю…") done:nil];
    });
}
- (void)newFolder {
    GXPrompt(self, GXL(@"Новая папка в архиве"), nil, @"folder", nil, GXL(@"Создать"), ^(NSString *n) {
        if (!n.length || [n containsString:@"/"]) return;
        [self->_m apply:@[@{@"name": [[[self prefixSlash] stringByAppendingString:n] stringByAppendingString:@"/"], @"data": [NSData data]}] from:self title:GXL(@"Создаю…") done:nil];
    });
}

- (void)sign {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Подписать APK") message:GXL(@"Подпись v1 + v2 ключом GX Files (RSA-2048). Android установит такой APK, но поверх версии с другой подписью — только после удаления старой.") preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *p = _m.path;
    void (^run)(NSString *) = ^(NSString *out) {
        [GXHUD showIn:self.view text:GXL(@"Подписываю…")];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *err = GXSignAPK(p, out, ^(double x) { [GXHUD setProgress:x]; });
            dispatch_async(dispatch_get_main_queue(), ^{
                [GXHUD hide];
                if (err) { GXAlert(self, GXL(@"Не удалось подписать"), err); return; }
                if ([out isEqualToString:p]) { self->_m.modifiedSinceSign = NO; [self->_m reload]; [self rebuild]; [self updateToolbar]; }
                GXToast(self.view, [NSString stringWithFormat:GXL(@"Подписано: %@"), out.lastPathComponent]);
            });
        });
    };
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Подписать этот файл") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { run(p); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Подписать в копию (_signed.apk)") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        run(GXUniquePath(p.stringByDeletingLastPathComponent, [[p.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@"_signed.apk"])); }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = self.toolbarItems.lastObject;
    [self presentViewController:a animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    if (self.editing) return nil;
    id row = _rows[ip.row];
    BOOL folder = [row isKindOfClass:NSString.class];
    GXArcEntry *e = folder ? nil : row;
    __weak typeof(self) ws = self;
    BOOL ed = _m.editable;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *a = [NSMutableArray array];
        if (e) {
            [a addObject:[UIAction actionWithTitle:ed ? GXL(@"Открыть / редактировать") : GXL(@"Открыть") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *x) { [self->_m openEntry:e from:ws]; }]];
            [a addObject:[UIAction actionWithTitle:GXL(@"В текстовом редакторе") image:[UIImage systemImageNamed:@"doc.plaintext"] identifier:nil handler:^(UIAction *x) { [self->_m openEntry:e from:ws with:@"text"]; }]];
            [a addObject:[UIAction actionWithTitle:GXL(@"В hex-редакторе") image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(UIAction *x) { [self->_m openEntry:e from:ws with:@"hex"]; }]];
            [a addObject:[UIAction actionWithTitle:GXL(@"Открыть с помощью…") image:[UIImage systemImageNamed:@"square.grid.3x3"] identifier:nil handler:^(UIAction *x) { [self->_m openEntry:e from:ws with:@"menu"]; }]];
            if (ed) [a addObject:[UIAction actionWithTitle:GXL(@"Заменить файлом…") image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath.doc.on.clipboard"] identifier:nil handler:^(UIAction *x) { [ws replaceEntry:e]; }]];
        }
        [a addObject:[UIAction actionWithTitle:GXL(@"Извлечь рядом с архивом") image:[UIImage systemImageNamed:@"arrow.down.doc"] identifier:nil handler:^(UIAction *x) { [ws extractRows:@[row]]; }]];
        if (ed) {
            [a addObject:[UIAction actionWithTitle:GXL(@"Переименовать") image:[UIImage systemImageNamed:@"character.cursor.ibeam"] identifier:nil handler:^(UIAction *x) { [ws renameRow:row]; }]];
            UIAction *d = [UIAction actionWithTitle:GXL(@"Удалить из архива") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *x) { [ws deleteRows:@[row]]; }];
            d.attributes = UIMenuElementAttributesDestructive;
            [a addObject:d];
        }
        if (e) [a addObject:[UIAction actionWithTitle:GXL(@"Копировать путь") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *x) { UIPasteboard.generalPasteboard.string = e.path; }]];
        return [UIMenu menuWithTitle:folder ? row : e.path children:a];
    }];
}

- (void)extractAll {
    NSString *arc = _m.path;
    NSString *name = arc.lastPathComponent;
    for (NSString *x in @[@".tar.gz", @".tar.xz", @".tar.bz2"]) if ([name.lowercaseString hasSuffix:x]) name = [name substringToIndex:name.length - x.length];
    if ([name isEqualToString:arc.lastPathComponent]) name = name.stringByDeletingPathExtension;
    NSString *dest = GXUniquePath(arc.stringByDeletingLastPathComponent, name);
    [GXHUD showCancellableIn:self.view text:GXL(@"Распаковка…")];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = GXArchiveExtractAll(arc, dest, ^(double p) { [GXHUD setProgress:p]; });
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err) GXAlert(self, GXL(@"Распаковано с ошибками"), err);
            else GXToast(self.view, [NSString stringWithFormat:GXL(@"Распаковано в «%@»"), dest.lastPathComponent]);
        });
    });
}

- (void)extractFolder {
    if (!_prefix.length) { [self extractAll]; return; }
    [self extractEntries:[self entriesUnder:_prefix]];
}
@end

// GX Files — запуск dylib внутри GX Files.
// Копия файла подписывается (сертификатом из «Подписи сертификатом» или ad-hoc при JIT), загружается dlopen
// в процесс GX Files — конструкторы dylib выполняются, меню/окна появляются поверх приложения.
// Экран показывает вывод printf/NSLog, классы Objective-C и экспортированные функции из этой dylib.

#import "GXCore.h"
#import "core/gx_bin.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/stat.h>

#pragma mark - перехват stdout/stderr (один на всё приложение, включается при первой загрузке)

static NSMutableString *gOut;
static NSLock *gOutLock;
static int gPipeR = -1;
NSString *const GXDylibOutputNote = @"GXDylibOutputNote";

static void GXAppendOut(NSString *s) {
    if (!s.length) return;
    [gOutLock lock];
    [gOut appendString:s];
    if (gOut.length > 300000) [gOut deleteCharactersInRange:NSMakeRange(0, gOut.length - 250000)];
    [gOutLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:GXDylibOutputNote object:nil]; });
}
static NSString *GXOutText(void) { [gOutLock lock]; NSString *s = gOut.copy; [gOutLock unlock]; return s; }

static void GXStartCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gOut = [NSMutableString string]; gOutLock = [NSLock new];
        setenv("OS_ACTIVITY_DT_MODE", "1", 1);      // NSLog дублирует в stderr
        int fds[2];
        if (pipe(fds) != 0) return;
        gPipeR = fds[0];
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);
        [NSThread detachNewThreadWithBlock:^{
            char buf[4096];
            for (;;) {
                ssize_t n = read(gPipeR, buf, sizeof buf);
                if (n <= 0) break;
                NSString *s = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding]
                           ?: [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSISOLatin1StringEncoding];
                GXAppendOut(s);
            }
        }];
    });
}

#pragma mark - состояние процесса

static BOOL GXHasJIT(void) {
    int (*csops_)(pid_t, unsigned int, void *, size_t) = dlsym(RTLD_DEFAULT, "csops");
    uint32_t flags = 0;
    if (!csops_ || csops_(getpid(), 0 /* CS_OPS_STATUS */, &flags, sizeof flags) != 0) return NO;
    return (flags & 0x10000000 /* CS_DEBUGGED */) != 0;
}

// Загруженные в этом запуске dylib: исходный путь → сведения (выгрузить без перезапуска нельзя)
static NSMutableDictionary<NSString *, NSDictionary *> *GXLoaded(void) {
    static NSMutableDictionary *d; static dispatch_once_t o;
    dispatch_once(&o, ^{ d = [NSMutableDictionary dictionary]; });
    return d;
}

static NSString *GXSigInfo(NSData *d) {
    gx_bin b;
    if (gx_bin_open(&b, d.bytes, d.length, 0) != 0 || b.fmt != 1) { gx_bin_close(&b); return GXL(@"не Mach-O 64"); }
    gx_bin_close(&b);
    // ищем LC_CODE_SIGNATURE в первом срезе
    const uint8_t *p = d.bytes; size_t len = d.length, base = 0;
    if (len >= 8 && OSSwapBigToHostInt32(*(uint32_t *)p) == 0xCAFEBABE) {
        uint32_t n = OSSwapBigToHostInt32(*(uint32_t *)(p + 4));
        for (uint32_t i = 0; i < n && 8 + (i + 1) * 20 <= len; i++) {
            const uint8_t *a = p + 8 + i * 20;
            if (OSSwapBigToHostInt32(*(uint32_t *)a) == 0x0100000C) { base = OSSwapBigToHostInt32(*(uint32_t *)(a + 8)); break; }
        }
    }
    if (base + 32 > len) return @"?";
    const struct mach_header_64 *h = (const void *)(p + base);
    if (h->magic != MH_MAGIC_64) return @"?";
    const uint8_t *c = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const void *)c;
        if ((const uint8_t *)lc + 8 > p + len || lc->cmdsize < 8) break;
        if (lc->cmd == LC_CODE_SIGNATURE) {
            const struct linkedit_data_command *s = (const void *)lc;
            if (!s->datasize) return GXL(@"нет подписи");
            size_t so = base + s->dataoff;
            if (so + 12 > len) return GXL(@"повреждена");
            // SuperBlob: ищем CMS (0xfade0b01) с непустым содержимым
            const uint8_t *sb = p + so;
            uint32_t cnt = OSSwapBigToHostInt32(*(uint32_t *)(sb + 8));
            for (uint32_t k = 0; k < cnt && so + 12 + (k + 1) * 8 <= len; k++) {
                uint32_t off = OSSwapBigToHostInt32(*(uint32_t *)(sb + 12 + k * 8 + 4));
                if (so + off + 8 > len) continue;
                if (OSSwapBigToHostInt32(*(uint32_t *)(sb + off)) == 0xFADE0B01 && OSSwapBigToHostInt32(*(uint32_t *)(sb + off + 4)) > 8)
                    return GXL(@"сертификат");
            }
            return @"ad-hoc";
        }
        c += lc->cmdsize;
    }
    return GXL(@"нет подписи");
}

@interface GXDylibRunVC ()
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *loadedPath;       // путь копии, которую загрузил dyld
@property (nonatomic) void *handle;
@property (nonatomic, strong) NSArray<NSString *> *classes;
@property (nonatomic, strong) NSArray<NSString *> *funcs;
@property (nonatomic, copy) NSString *status, *sig;
@property (nonatomic) BOOL busy;
@property (nonatomic) NSUInteger outMark;              // с какого места вывода показывать (вывод этой загрузки)
@end

@implementation GXDylibRunVC

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _path = path.copy; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.path.lastPathComponent;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 50;
    NSData *d = [NSData dataWithContentsOfFile:self.path options:NSDataReadingMappedIfSafe error:nil];
    self.sig = d ? GXSigInfo(d) : @"?";
    NSDictionary *was = GXLoaded()[self.path];
    if (was) {
        self.loadedPath = was[@"copy"]; self.handle = [was[@"handle"] pointerValue];
        self.outMark = [was[@"mark"] unsignedIntegerValue];
        self.status = GXL(@"✓ уже загружена в этом запуске GX Files");
        [self collectInfo];
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(refresh)];
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(outChanged) name:GXDylibOutputNote object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refresh { if (self.handle) [self collectInfo]; [self.tableView reloadData]; }
- (void)outChanged {
    if (!self.handle || !self.isViewLoaded || !self.view.window) return;
    [UIView performWithoutAnimation:^{ [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone]; }];
}

- (NSString *)outputText {
    NSString *all = GXOutText() ?: @"";
    return self.outMark <= all.length ? [all substringFromIndex:self.outMark] : all;
}

#pragma mark - загрузка

- (void)runAsIs:(BOOL)asIs {
    if (self.busy || self.handle) return;
    self.busy = YES;
    self.status = GXL(@"Подготовка…");
    [self.tableView reloadData];
    NSString *src = self.path;
    BOOL jit = GXHasJIT(), cert = GXSignEnabled();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *log = [NSMutableString string];
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *dir = [[caches stringByAppendingPathComponent:@"GXRun"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [FM() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dst = [dir stringByAppendingPathComponent:src.lastPathComponent];
        NSError *ce = nil;
        NSString *err = nil;
        if (![FM() copyItemAtPath:src toPath:dst error:&ce]) err = ce.localizedDescription;
        NSString *ident = [src.lastPathComponent.stringByDeletingPathExtension stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        if (!err && !asIs) {
            if (cert) {
                NSString *se = GXSignFileWithCert(dst, ident, log);
                if (se) [log appendFormat:GXL(@"⚠︎ подпись сертификатом не удалась: %@ — пробую как есть\n"), se];
            } else if (jit) {
                NSData *d = [NSData dataWithContentsOfFile:dst];
                char e[256] = {0}; size_t ol = 0; int ns = 0;
                uint8_t *sg = gx_adhoc_sign(d.bytes, d.length, ident.UTF8String, 2, &ol, &ns, e, sizeof e);
                if (sg) { [[NSData dataWithBytesNoCopy:sg length:ol freeWhenDone:YES] writeToFile:dst atomically:YES]; [log appendString:GXL(@"✓ подписано ad-hoc (JIT включён)\n")]; }
                else [log appendFormat:GXL(@"⚠︎ ad-hoc подпись не удалась: %s — пробую как есть\n"), e];
            } else {
                [log appendString:GXL(@"Сертификат не включён и JIT нет — загружаю как есть (сработает, если dylib уже подписана подходящим сертификатом)\n")];
            }
        } else if (!err) [log appendString:GXL(@"Загрузка без переподписи\n")];
        chmod(dst.fileSystemRepresentation, 0755);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) { self.busy = NO; self.status = [GXL(@"Ошибка: ") stringByAppendingString:err]; [self.tableView reloadData]; return; }
            GXStartCapture();
            self.outMark = GXOutText().length;
            GXAppendOut(log);
            // dlopen на главном потоке: конструкторы dylib часто сразу создают UI
            void *h = dlopen(dst.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
            self.busy = NO;
            if (!h) {
                const char *de = dlerror();
                NSString *e = de ? @(de) : @"?";
                self.status = [NSString stringWithFormat:@"%@\n\n%@", e, [self hintFor:e jit:jit cert:cert]];
                [FM() removeItemAtPath:dir error:nil];
                [self.tableView reloadData];
                return;
            }
            self.handle = h; self.loadedPath = dst;
            GXLoaded()[src] = @{@"copy": dst, @"handle": [NSValue valueWithPointer:h], @"mark": @(self.outMark)};
            self.status = GXL(@"✓ загружена в GX Files — конструкторы выполнены. Если это меню, оно уже на экране.");
            [self collectInfo];
            [self.tableView reloadData];
            // меню часто появляются с задержкой (dispatch_after в конструкторе) — обновим список позже
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
        });
    });
}

- (NSString *)hintFor:(NSString *)e jit:(BOOL)jit cert:(BOOL)cert {
    NSMutableArray *h = [NSMutableArray array];
    if ([e containsString:@"code signature"] || [e containsString:@"not valid for use"] || [e containsString:@"signature"]) {
        if (!cert) [h addObject:GXL(@"iOS не принял подпись. Включи «Подпись сертификатом» (тот же сертификат, которым подписан GX Files) или запусти GX Files с JIT.")];
        else [h addObject:GXL(@"iOS не принял подпись. Сертификат должен совпадать с тем, которым подписан GX Files (тот же Team ID). В LiveContainer — сертификат LiveContainer.")];
    }
    if ([e containsString:@"Library not loaded"] || [e containsString:@"image not found"]) {
        if ([e containsString:@"Substrate"] || [e containsString:@"substrate"] || [e containsString:@"ellekit"] || [e containsString:@"libhooker"])
            [h addObject:GXL(@"dylib требует CydiaSubstrate/ElleKit — это твик для джейлбрейка или LiveContainer. Запусти его через папку твиков LiveContainer.")];
        else
            [h addObject:GXL(@"Не найдена библиотека, от которой зависит dylib (см. текст выше). Положи её рядом или собери dylib без этой зависимости.")];
    }
    if ([e containsString:@"incompatible"] || [e containsString:@"mach-o file, but is an incompatible architecture"] || [e containsString:@"platform"])
        [h addObject:GXL(@"dylib собрана не для iOS arm64 (например, для macOS или симулятора).")];
    if ([e containsString:@"missing LC_UUID"]) [h addObject:GXL(@"У dylib нет LC_UUID — пересобери её в новом компиляторе GX Files.")];
    if (!h.count) [h addObject:GXL(@"Посмотри текст ошибки dyld выше. Попробуй и вторую кнопку — «как есть» или с переподписью.")];
    return [h componentsJoinedByString:@"\n"];
}

// Классы Objective-C и экспортированные функции загруженного образа
- (void)collectInfo {
    if (!self.loadedPath) return;
    NSString *real = self.loadedPath.stringByResolvingSymlinksInPath;
    NSString *tail = [self.loadedPath.stringByDeletingLastPathComponent.lastPathComponent stringByAppendingPathComponent:self.loadedPath.lastPathComponent];
    const char *img = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (!n) continue;
        NSString *s = @(n);
        if ([s isEqualToString:self.loadedPath] || [s isEqualToString:real] || [s hasSuffix:tail]) { img = n; break; }
    }
    NSMutableArray *cls = [NSMutableArray array];
    if (img) {
        unsigned cnt = 0;
        const char **names = objc_copyClassNamesForImage(img, &cnt);
        for (unsigned i = 0; i < cnt; i++) [cls addObject:@(names[i])];
        free(names);
    }
    self.classes = [cls sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];

    NSMutableOrderedSet *fns = [NSMutableOrderedSet orderedSet];
    NSData *d = [NSData dataWithContentsOfFile:self.loadedPath options:NSDataReadingMappedIfSafe error:nil];
    gx_bin b;
    if (d && gx_bin_open(&b, d.bytes, d.length, 0) == 0) {
        for (size_t i = 0; i < b.nfn; i++) {
            if (!b.fn[i].name || !b.fn[i].nlen) continue;
            NSString *n = [[NSString alloc] initWithBytes:b.fn[i].name length:b.fn[i].nlen encoding:NSUTF8StringEncoding];
            if (!n.length || [n hasPrefix:@"-["] || [n hasPrefix:@"+["]) continue;
            NSString *c = [n hasPrefix:@"_"] ? [n substringFromIndex:1] : n;
            if (self.handle && dlsym(self.handle, c.UTF8String)) [fns addObject:c];
        }
    }
    gx_bin_close(&b);
    self.funcs = fns.array;
}

#pragma mark - таблица

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return GXL(@"Файл");
        case 1: return GXL(@"Запуск");
        case 2: return self.handle ? GXL(@"Вывод (printf, NSLog)") : nil;
        case 3: return self.handle ? [NSString stringWithFormat:GXL(@"Классы Objective-C · %lu"), (unsigned long)self.classes.count] : nil;
        default: return self.handle ? [NSString stringWithFormat:GXL(@"Экспортированные функции · %lu"), (unsigned long)self.funcs.count] : nil;
    }
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 1 && !self.handle) return GXL(@"dylib загружается прямо в GX Files: её код выполняется в этом приложении, меню и окна появляются поверх него. Если dylib упадёт — GX Files закроется. Выгрузить загруженную dylib можно только перезапуском GX Files. Запускай только то, чему доверяешь.");
    if (s == 3 && self.handle) return GXL(@"Нажми на класс — методы, свойства, переменные. Контроллеры (UIViewController) можно открыть.");
    if (s == 4 && self.handle && self.funcs.count) return GXL(@"Нажми, чтобы вызвать функцию без аргументов. Функции с аргументами так вызывать нельзя — приложение упадёт.");
    return nil;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return 4;
        case 1: return self.handle ? 1 : (self.status ? 3 : 2);
        case 2: return self.handle ? 2 : 0;
        case 3: return self.handle ? MAX(1, self.classes.count) : 0;
        default: return self.handle ? MAX(1, self.funcs.count) : 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 0;
    if (ip.section == 0) {
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        struct stat st; stat(self.path.fileSystemRepresentation, &st);
        NSArray *rows = @[@[GXL(@"Размер"), GXHuman((unsigned long long)st.st_size)],
                          @[GXL(@"Подпись файла"), self.sig ?: @"?"],
                          @[GXL(@"Подпись сертификатом"), GXSignEnabled() ? GXL(@"включена") : GXL(@"выключена")],
                          @[@"JIT", GXHasJIT() ? GXL(@"включён") : GXL(@"нет")]];
        c.textLabel.text = rows[ip.row][0]; c.detailTextLabel.text = rows[ip.row][1];
        return c;
    }
    if (ip.section == 1) {
        if (self.handle || (self.status && ip.row == 2)) {
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.textLabel.text = self.status;
            c.textLabel.font = [UIFont systemFontOfSize:14];
            c.textLabel.textColor = self.handle ? UIColor.systemGreenColor : (self.busy ? UIColor.secondaryLabelColor : UIColor.systemRedColor);
            return c;
        }
        c.textLabel.text = ip.row == 0 ? GXL(@"▶︎ Запустить в GX Files") : GXL(@"Запустить как есть (без переподписи)");
        c.textLabel.textColor = self.busy ? UIColor.secondaryLabelColor : (ip.row == 0 ? self.view.tintColor : UIColor.labelColor);
        c.textLabel.font = ip.row == 0 ? [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:15];
        return c;
    }
    if (ip.section == 2) {
        if (ip.row == 0) {
            NSString *o = [self outputText];
            if (o.length > 20000) o = [@"…\n" stringByAppendingString:[o substringFromIndex:o.length - 20000]];
            c.textLabel.text = o.length ? o : GXL(@"(пока пусто)");
            c.textLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
            c.textLabel.textColor = o.length ? UIColor.labelColor : UIColor.secondaryLabelColor;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            c.textLabel.text = GXL(@"Копировать вывод");
            c.textLabel.textColor = self.view.tintColor;
        }
        return c;
    }
    NSArray *list = ip.section == 3 ? self.classes : self.funcs;
    if (!list.count) {
        c.textLabel.text = ip.section == 3 ? GXL(@"Нет классов Objective-C") : GXL(@"Нет экспортированных функций");
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSString *name = list[ip.row];
    c.textLabel.text = name;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    if (ip.section == 3) {
        Class k = NSClassFromString(name);
        Class sup = k ? class_getSuperclass(k) : Nil;
        c.detailTextLabel.text = sup ? NSStringFromClass(sup) : nil;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.imageView.image = [UIImage systemImageNamed:@"function"];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && !self.handle && ip.row < 2 && !self.busy) {
        BOOL asIs = ip.row == 1;
        GXConfirm(self, GXL(@"Запустить dylib?"), GXL(@"Код dylib выполнится внутри GX Files. Если она упадёт, GX Files закроется. Выгрузить её можно только перезапуском приложения."), GXL(@"Запустить"), NO, ^{
            self.status = nil;
            [self runAsIs:asIs];
        });
        return;
    }
    if (ip.section == 2 && ip.row == 1) {
        UIPasteboard.generalPasteboard.string = [self outputText];
        GXToast(self.view, GXL(@"Вывод скопирован"));
        return;
    }
    if (ip.section == 3 && self.classes.count) { [self showClass:self.classes[ip.row]]; return; }
    if (ip.section == 4 && self.funcs.count) {
        NSString *fn = self.funcs[ip.row];
        GXConfirm(self, [fn stringByAppendingString:@"()"], GXL(@"Вызвать функцию без аргументов? Если ей нужны аргументы, GX Files упадёт."), GXL(@"Вызвать"), NO, ^{
            long (*f)(void) = (long (*)(void))dlsym(self.handle, fn.UTF8String);
            if (!f) return;
            long r = f();
            GXAppendOut([NSString stringWithFormat:@"→ %@() = %ld (0x%lx)\n", fn, r, r]);
            [self refresh];
        });
    }
}

- (void)showClass:(NSString *)name {
    Class k = NSClassFromString(name);
    if (!k) return;
    NSMutableString *t = [NSMutableString string];
    [t appendFormat:@"@interface %@", name];
    Class sup = class_getSuperclass(k);
    if (sup) [t appendFormat:@" : %@", NSStringFromClass(sup)];
    unsigned n = 0;
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(k, &n);
    if (n) {
        NSMutableArray *ps = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) [ps addObject:@(protocol_getName(protos[i]))];
        [t appendFormat:@" <%@>", [ps componentsJoinedByString:@", "]];
    }
    free(protos);
    [t appendString:@"\n"];
    Ivar *iv = class_copyIvarList(k, &n);
    if (n) {
        [t appendString:@"{\n"];
        for (unsigned i = 0; i < n; i++) [t appendFormat:@"    %s %s;  // +0x%lx\n", ivar_getTypeEncoding(iv[i]) ?: "?", ivar_getName(iv[i]), (long)ivar_getOffset(iv[i])];
        [t appendString:@"}\n"];
    }
    free(iv);
    objc_property_t *pr = class_copyPropertyList(k, &n);
    for (unsigned i = 0; i < n; i++) [t appendFormat:@"@property %s;  // %s\n", property_getName(pr[i]), property_getAttributes(pr[i])];
    free(pr);
    for (int meta = 1; meta >= 0; meta--) {
        Method *m = class_copyMethodList(meta ? object_getClass(k) : k, &n);
        for (unsigned i = 0; i < n; i++) [t appendFormat:@"%c %s  // %s\n", meta ? '+' : '-', sel_getName(method_getName(m[i])), method_getTypeEncoding(m[i]) ?: ""];
        free(m);
    }
    [t appendString:@"@end\n"];
    GXReportVC *r = [[GXReportVC alloc] initWithTitle:name text:t];
    [r loadViewIfNeeded];   // GXReportVC ставит свою кнопку «Поделиться» в viewDidLoad — добавляем рядом
    UIBarButtonItem *open = nil;
    if ([k isSubclassOfClass:UIViewController.class])
        open = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Открыть") style:UIBarButtonItemStylePlain target:self action:@selector(openController:)];
    else if ([k isSubclassOfClass:UIView.class])
        open = [[UIBarButtonItem alloc] initWithTitle:GXL(@"Показать") style:UIBarButtonItemStylePlain target:self action:@selector(openView:)];
    if (open) {
        objc_setAssociatedObject(open, "gxcls", name, OBJC_ASSOCIATION_COPY);
        r.navigationItem.rightBarButtonItems = [(r.navigationItem.rightBarButtonItems ?: @[]) arrayByAddingObject:open];
    }
    [self.navigationController pushViewController:r animated:YES];
}

- (void)openController:(UIBarButtonItem *)b {
    NSString *name = objc_getAssociatedObject(b, "gxcls");
    GXConfirm(self, name, GXL(@"Создать контроллер ([[класс alloc] init]) и показать? Если ему нужны особые данные, GX Files может упасть."), GXL(@"Открыть"), NO, ^{
        UIViewController *vc = [[NSClassFromString(name) alloc] init];
        if (!vc) return;
        GXPresentNav(GXTopVC(self), vc, NO);
    });
}
- (void)openView:(UIBarButtonItem *)b {
    NSString *name = objc_getAssociatedObject(b, "gxcls");
    GXConfirm(self, name, GXL(@"Создать вид (initWithFrame:) и показать на отдельном экране?"), GXL(@"Показать"), NO, ^{
        UIView *v = [[NSClassFromString(name) alloc] initWithFrame:CGRectMake(20, 120, 320, 320)];
        if (!v) return;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.systemBackgroundColor;
        vc.title = name;
        [vc.view addSubview:v];
        GXPresentNav(GXTopVC(self), vc, NO);
    });
}

@end

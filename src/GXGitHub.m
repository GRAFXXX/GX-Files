// Клиент GitHub через REST API: свои и публичные репозитории, просмотр, скачивание,
// правка файлов в GX Files и отправка изменений коммитом. Токен — в Связке ключей.
#import "GXCore.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Токен и состояние

static NSString *const kGHService = @"GXFiles.github";

static NSString *_Nullable GXGHToken(void) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: kGHService, (__bridge id)kSecAttrAccount: @"token",
                        (__bridge id)kSecReturnData: @YES};
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    return [[NSString alloc] initWithData:(__bridge_transfer NSData *)out encoding:NSUTF8StringEncoding];
}
static void GXGHSetToken(NSString *_Nullable t) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: kGHService, (__bridge id)kSecAttrAccount: @"token"};
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!t.length) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(__bridge id)kSecValueData] = [t dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

// sha файлов на момент скачивания: «owner/repo@branch:path» → sha
static NSString *GXGHKey(NSString *repo, NSString *branch, NSString *path) { return [NSString stringWithFormat:@"%@@%@:%@", repo, branch, path]; }
static NSString *_Nullable GXGHBaseSha(NSString *key) { return [[GXDefaults() dictionaryForKey:@"gxGHShas"] objectForKey:key]; }
static void GXGHSetBaseSha(NSString *key, NSString *_Nullable sha) {
    NSMutableDictionary *d = [[GXDefaults() dictionaryForKey:@"gxGHShas"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (sha) d[key] = sha; else [d removeObjectForKey:key];
    [GXDefaults() setObject:d forKey:@"gxGHShas"];
}

// sha объекта git (blob) — так GitHub считает sha файла
static NSString *_Nullable GXGitBlobSha(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!d) return nil;
    CC_SHA1_CTX c; CC_SHA1_Init(&c);
    NSString *hdr = [NSString stringWithFormat:@"blob %lu", (unsigned long)d.length];
    CC_SHA1_Update(&c, hdr.UTF8String, (CC_LONG)strlen(hdr.UTF8String) + 1);
    const uint8_t *p = d.bytes; NSUInteger left = d.length;
    while (left) { CC_LONG n = (CC_LONG)MIN(left, (NSUInteger)(1 << 30)); CC_SHA1_Update(&c, p, n); p += n; left -= n; }
    uint8_t md[CC_SHA1_DIGEST_LENGTH]; CC_SHA1_Final(md, &c);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", md[i]];
    return s;
}

static NSString *GXGHEnc(NSString *path) { return [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: path; }
static NSString *GXGHEncQ(NSString *s) {
    NSMutableCharacterSet *cs = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [cs removeCharactersInString:@"&+=?#"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs] ?: s;
}

#pragma mark - API

@interface GXGH : NSObject
+ (NSURLSession *)session;
+ (NSMutableURLRequest *)req:(NSString *)method path:(NSString *)path;
+ (void)call:(NSString *)method path:(NSString *)path body:(nullable id)body done:(void (^)(id _Nullable json, NSInteger status, NSString *_Nullable err))done;
@end

@implementation GXGH
+ (NSURLSession *)session {
    static NSURLSession *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.timeoutIntervalForRequest = 60;
        c.HTTPAdditionalHeaders = @{@"User-Agent": @"GXFiles", @"X-GitHub-Api-Version": @"2022-11-28"};
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}
+ (NSMutableURLRequest *)req:(NSString *)method path:(NSString *)path {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.github.com" stringByAppendingString:path]]];
    r.HTTPMethod = method;
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    NSString *t = GXGHToken();
    if (t.length) [r setValue:[@"Bearer " stringByAppendingString:t] forHTTPHeaderField:@"Authorization"];
    return r;
}
+ (NSString *)errorFor:(NSInteger)status json:(id)json {
    NSString *m = [json isKindOfClass:NSDictionary.class] ? json[@"message"] : nil;
    if (status == 401) return GXL(@"Токен недействителен или истёк. Войди заново.");
    if (status == 403 && [m containsString:@"rate limit"]) return GXL(@"Превышен лимит запросов GitHub. Без токена — 60 в час; войди с токеном, чтобы лимит стал 5000.");
    if (status == 403) return [NSString stringWithFormat:GXL(@"Нет доступа. Проверь, что у токена есть право «Contents: Read and write» для этого репозитория.\n\n%@"), m ?: @""];
    if (status == 404) return GXL(@"Не найдено. Для приватного репозитория нужен токен с доступом к нему.");
    if (status == 409) return GXL(@"Конфликт: файл на GitHub уже изменился. Обнови список и попробуй снова.");
    return [NSString stringWithFormat:@"HTTP %ld%@%@", (long)status, m ? @": " : @"", m ?: @""];
}
+ (void)call:(NSString *)method path:(NSString *)path body:(id)body done:(void (^)(id, NSInteger, NSString *))done {
    NSMutableURLRequest *r = [self req:method path:path];
    if (body) { r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil]; [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"]; }
    [[[self session] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *err = e ? e.localizedDescription : (st >= 200 && st < 300) ? nil : [self errorFor:st json:json];
        dispatch_async(dispatch_get_main_queue(), ^{ done(json, st, err); });
    }] resume];
}
@end

static NSString *GXGHRoot(void) {
    NSString *d = [GXDocsDir() stringByAppendingPathComponent:@"GitHub"]; // noi18n
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

#pragma mark - Содержимое репозитория

@interface GXGHRepoVC : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithRepo:(NSString *)repo branch:(NSString *)branch path:(NSString *)path;
@end

@implementation GXGHRepoVC {
    NSString *_repo, *_branch, *_path;
    NSArray<NSDictionary *> *_items; NSString *_err; BOOL _loading;
}
- (instancetype)initWithRepo:(NSString *)repo branch:(NSString *)branch path:(NSString *)path {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _repo = repo.copy; _branch = branch.copy; _path = path.copy;
        self.title = path.length ? path.lastPathComponent : [repo componentsSeparatedByString:@"/"].lastObject;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self buildMenu];
    [self reload];
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.tableView reloadData]; }   // после правки файла — обновить отметки
- (void)buildMenu {
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *im, void (^b)(void)) {
        return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:im] identifier:nil handler:^(UIAction *x) { b(); }];
    };
    self.navigationItem.prompt = [NSString stringWithFormat:@"%@ · %@", _repo, _branch];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithChildren:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[
            act(GXL(@"Новый файл…"), @"doc.badge.plus", ^{ [ws newFile]; }),
            act(GXL(@"Загрузить из «Файлов»…"), @"folder", ^{ [ws pickUpload]; }),
            act(GXL(@"Загрузить из буфера GX Files"), @"doc.on.clipboard", ^{ [ws uploadClipboard]; }),
        ]],
        act([NSString stringWithFormat:GXL(@"Ветка: %@…"), _branch], @"arrow.triangle.branch", ^{ [ws pickBranch]; }),
        act(GXL(@"Скачать весь репозиторий (ZIP)"), @"arrow.down.circle", ^{ [ws downloadZip]; }),
        act(GXL(@"Открыть на сайте"), @"safari", ^{ [ws openWeb]; }),
        act(GXL(@"Обновить"), @"arrow.clockwise", ^{ [ws reload]; }),
    ]]];
}
- (NSString *)apiContents:(NSString *)p { return [NSString stringWithFormat:@"/repos/%@/contents/%@?ref=%@", _repo, GXGHEnc(p), GXGHEncQ(_branch)]; }
- (void)reload {
    _loading = YES; [self.tableView reloadData];
    [GXGH call:@"GET" path:[self apiContents:_path] body:nil done:^(id json, NSInteger st, NSString *err) {
        self->_loading = NO; self->_err = err;
        NSArray *a = [json isKindOfClass:NSArray.class] ? json : @[];
        self->_items = [a sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
            BOOL dx = [x[@"type"] isEqual:@"dir"], dy = [y[@"type"] isEqual:@"dir"];
            if (dx != dy) return dx ? NSOrderedAscending : NSOrderedDescending;
            return [x[@"name"] localizedStandardCompare:y[@"name"]];
        }];
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
    }];
}

#pragma mark Локальные копии

- (NSString *)localPath:(NSString *)p { return [[GXGHRoot() stringByAppendingPathComponent:_repo] stringByAppendingPathComponent:p]; }
- (NSString *)keyFor:(NSString *)p { return GXGHKey(_repo, _branch, p); }
// 0 — нет копии, 1 — совпадает, 2 — изменён у тебя, 3 — обновился на GitHub
- (int)stateOf:(NSDictionary *)it {
    NSString *p = it[@"path"], *lp = [self localPath:p];
    if (![FM() fileExistsAtPath:lp]) return 0;
    NSString *base = GXGHBaseSha([self keyFor:p]);
    if (!base) return 0;
    NSString *cur = GXGitBlobSha(lp);
    if (![cur isEqualToString:base]) return 2;
    if (![it[@"sha"] isEqualToString:base]) return 3;
    return 1;
}
- (NSArray<NSDictionary *> *)modifiedItems {
    NSMutableArray *m = [NSMutableArray array];
    for (NSDictionary *it in _items) if ([it[@"type"] isEqual:@"file"] && [self stateOf:it] == 2) [m addObject:it];
    return m;
}

#pragma mark Таблица

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return !_loading && [self modifiedItems].count ? 1 : 0;
    return _loading || _err || !_items.count ? 1 : (NSInteger)_items.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (ip.section == 0) {
        c.textLabel.text = [NSString stringWithFormat:GXL(@"Отправить изменения (%lu)"), (unsigned long)[self modifiedItems].count];
        c.detailTextLabel.text = GXL(@"Файлы, которые ты изменил в этой папке, — одним действием");
        c.textLabel.textColor = UIColor.systemGreenColor;
        c.imageView.image = [UIImage systemImageNamed:@"arrow.up.circle.fill"];
        c.imageView.tintColor = UIColor.systemGreenColor;
        return c;
    }
    if (_loading || _err || !_items.count) {
        c.textLabel.text = _loading ? GXL(@"Загрузка…") : _err ?: GXL(@"Папка пуста");
        c.textLabel.textColor = _err ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        c.textLabel.numberOfLines = 0;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *it = _items[ip.row];
    BOOL dir = [it[@"type"] isEqual:@"dir"];
    c.textLabel.text = it[@"name"];
    c.imageView.image = [UIImage systemImageNamed:dir ? @"folder.fill" : [it[@"type"] isEqual:@"submodule"] ? @"shippingbox" : @"doc"];
    c.imageView.tintColor = dir ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    c.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    if (!dir) {
        int st = [self stateOf:it];
        NSString *badge = st == 1 ? GXL(@" · скачан") : st == 2 ? GXL(@" · изменён тобой") : st == 3 ? GXL(@" · есть новая версия") : @"";
        c.detailTextLabel.text = [GXHuman([it[@"size"] unsignedLongLongValue]) stringByAppendingString:badge];
        if (st == 2) c.detailTextLabel.textColor = UIColor.systemOrangeColor;
        if (st == 3) c.detailTextLabel.textColor = UIColor.systemBlueColor;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) { [self commitItems:[self modifiedItems]]; return; }
    if (_loading || _err || !_items.count) return;
    NSDictionary *it = _items[ip.row];
    if ([it[@"type"] isEqual:@"dir"]) { [self.navigationController pushViewController:[[GXGHRepoVC alloc] initWithRepo:_repo branch:_branch path:it[@"path"]] animated:YES]; return; }
    if (![it[@"type"] isEqual:@"file"]) return;
    int st = [self stateOf:it];
    if (st == 1 || st == 2) { [GXOpener open:[self localPath:it[@"path"]] from:self]; return; }
    [self download:it open:YES];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    if (ip.section == 0 || _loading || _err || !_items.count) return nil;
    NSDictionary *it = _items[ip.row];
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *im, void (^b)(void)) {
        return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:im] identifier:nil handler:^(UIAction *x) { b(); }];
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *sug) {
        NSMutableArray *a = [NSMutableArray array];
        GXGHRepoVC *me = ws; if (!me) return nil;
        BOOL file = [it[@"type"] isEqual:@"file"];
        if (file) {
            int st = [me stateOf:it];
            [a addObject:act(GXL(@"Открыть"), @"doc.text", ^{ if (st == 1 || st == 2) [GXOpener open:[ws localPath:it[@"path"]] from:ws]; else [ws download:it open:YES]; })];
            if (st == 2) [a addObject:act(GXL(@"Отправить изменения (коммит)"), @"arrow.up.circle", ^{ [ws commitItems:@[it]]; })];
            [a addObject:act(st == 0 ? GXL(@"Скачать") : GXL(@"Скачать заново (заменить свою копию)"), @"arrow.down.circle", ^{ [ws download:it open:NO]; })];
            if (st) [a addObject:act(GXL(@"Показать в «Мои файлы»"), @"folder", ^{
                GXBrowserVC *b = [[GXBrowserVC alloc] initWithPath:[ws localPath:it[@"path"]].stringByDeletingLastPathComponent];
                [ws.navigationController pushViewController:b animated:YES];
            })];
        }
        [a addObject:act(GXL(@"Копировать ссылку"), @"link", ^{ UIPasteboard.generalPasteboard.string = it[@"html_url"] ?: @""; GXToast(ws.view, GXL(@"Скопировано")); })];
        if (file) {
            UIAction *del = act(GXL(@"Удалить на GitHub…"), @"trash", ^{ [ws deleteItem:it]; });
            del.attributes = UIMenuElementAttributesDestructive;
            [a addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[del]]];
        }
        return [UIMenu menuWithChildren:a];
    }];
}

#pragma mark Скачивание

- (void)download:(NSDictionary *)it open:(BOOL)open {
    NSString *p = it[@"path"], *dst = [self localPath:p];
    [FM() createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableURLRequest *r = [GXGH req:@"GET" path:[self apiContents:p]];
    [r setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];
    [GXHUD showCancellableIn:self.navigationController.view ?: self.view text:[NSString stringWithFormat:GXL(@"Скачиваю «%@»…"), it[@"name"]]];
    NSURLSessionDownloadTask *t = [[GXGH session] downloadTaskWithRequest:r completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSString *err = e ? (e.code == NSURLErrorCancelled ? @"cancelled" : e.localizedDescription) : (st == 200 ? nil : [GXGH errorFor:st json:nil]);
        if (!err) { [FM() removeItemAtPath:dst error:nil]; NSError *me; if (![FM() moveItemAtPath:loc.path toPath:dst error:&me]) err = me.localizedDescription; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err) { if (![err isEqualToString:@"cancelled"]) GXAlert(self, GXL(@"Не удалось скачать"), err); return; }
            GXGHSetBaseSha([self keyFor:p], GXGitBlobSha(dst));
            [self.tableView reloadData];
            if (open) [GXOpener open:dst from:self];
            else GXToast(self.view, GXL(@"Сохранено в «Мои файлы/GitHub»"));
        });
    }];
    [self track:t];
    [t resume];
}
- (void)track:(NSURLSessionTask *)t {
    __weak NSURLSessionTask *wt = t;
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        NSURLSessionTask *task = wt;
        if (!task || task.state == NSURLSessionTaskStateCompleted || task.state == NSURLSessionTaskStateCanceling) { [timer invalidate]; return; }
        if ([GXHUD cancelled]) { [task cancel]; [timer invalidate]; return; }
        int64_t all = task.countOfBytesExpectedToReceive;
        if (all > 0) [GXHUD setProgress:(double)task.countOfBytesReceived / (double)all];
    }];
}
- (void)downloadZip {
    NSString *name = [NSString stringWithFormat:@"%@-%@.zip", [_repo stringByReplacingOccurrencesOfString:@"/" withString:@"-"], [_branch stringByReplacingOccurrencesOfString:@"/" withString:@"-"]];
    NSString *dst = GXUniquePath(GXGHRoot(), name);
    NSMutableURLRequest *r = [GXGH req:@"GET" path:[NSString stringWithFormat:@"/repos/%@/zipball/%@", _repo, GXGHEnc(_branch)]];
    [GXHUD showCancellableIn:self.navigationController.view ?: self.view text:GXL(@"Скачиваю архив репозитория…")];
    NSURLSessionDownloadTask *t = [[GXGH session] downloadTaskWithRequest:r completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSString *err = e ? (e.code == NSURLErrorCancelled ? @"cancelled" : e.localizedDescription) : (st == 200 ? nil : [GXGH errorFor:st json:nil]);
        if (!err) { NSError *me; if (![FM() moveItemAtPath:loc.path toPath:dst error:&me]) err = me.localizedDescription; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [GXHUD hide];
            if (err) { if (![err isEqualToString:@"cancelled"]) GXAlert(self, GXL(@"Не удалось скачать"), err); return; }
            [GXOpener open:dst from:self];
        });
    }];
    [self track:t];
    [t resume];
}

#pragma mark Отправка

- (void)commitItems:(NSArray<NSDictionary *> *)items {
    if (!items.count) return;
    if (!GXGHToken().length) { GXAlert(self, GXL(@"Нужен вход"), GXL(@"Чтобы отправлять изменения, войди с токеном на главном экране GitHub.")); return; }
    BOOL conflict = NO;
    for (NSDictionary *it in items) if (![it[@"sha"] isEqualToString:GXGHBaseSha([self keyFor:it[@"path"]]) ?: @""]) conflict = YES;
    NSString *def = items.count == 1 ? [NSString stringWithFormat:@"Update %@", items[0][@"name"]] : [NSString stringWithFormat:@"Update %lu files", (unsigned long)items.count]; // noi18n
    NSString *msg = conflict ? GXL(@"Внимание: на GitHub файл изменился после того, как ты его скачал. Отправка заменит чужие правки твоей версией.") : nil;
    GXPrompt(self, GXL(@"Описание коммита"), msg, def, GXL(@"Что изменено"), GXL(@"Отправить"), ^(NSString *m) {
        NSMutableArray *jobs = [NSMutableArray array];
        for (NSDictionary *it in items) [jobs addObject:@{@"local": [self localPath:it[@"path"]], @"path": it[@"path"], @"sha": it[@"sha"] ?: @""}];
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Отправляю на GitHub…")];
        [self put:jobs index:0 message:m.length ? m : def failed:[NSMutableArray array]];
    });
}
// jobs: @{local, path, sha?}; sha пустой — узнать перед отправкой (файл может уже существовать)
- (void)put:(NSArray<NSDictionary *> *)jobs index:(NSUInteger)i message:(NSString *)m failed:(NSMutableArray *)failed {
    if (i >= jobs.count) {
        [GXHUD hide];
        if (failed.count) GXAlert(self, GXL(@"Отправлено с ошибками"), [failed componentsJoinedByString:@"\n\n"]);
        else GXToast(self.view, [NSString stringWithFormat:GXL(@"Отправлено файлов: %lu"), (unsigned long)jobs.count]);
        [self reload];
        return;
    }
    NSDictionary *j = jobs[i];
    [GXHUD setText:[NSString stringWithFormat:GXL(@"Отправляю %lu из %lu: %@"), (unsigned long)i + 1, (unsigned long)jobs.count, [j[@"path"] lastPathComponent]]];
    void (^send)(NSString *) = ^(NSString *sha) {
        NSData *d = [NSData dataWithContentsOfFile:j[@"local"]];
        if (!d) { [failed addObject:[NSString stringWithFormat:@"%@: %@", j[@"path"], GXL(@"не удалось прочитать файл")]]; [self put:jobs index:i + 1 message:m failed:failed]; return; }
        if (d.length > 50 * 1024 * 1024) { [failed addObject:[NSString stringWithFormat:@"%@: %@", j[@"path"], GXL(@"больше 50 МБ — GitHub не примет через API")]]; [self put:jobs index:i + 1 message:m failed:failed]; return; }
        NSMutableDictionary *body = [@{@"message": m, @"content": [d base64EncodedStringWithOptions:0], @"branch": self->_branch} mutableCopy];
        if (sha.length) body[@"sha"] = sha;
        [GXGH call:@"PUT" path:[NSString stringWithFormat:@"/repos/%@/contents/%@", self->_repo, GXGHEnc(j[@"path"])] body:body done:^(id json, NSInteger st, NSString *err) {
            if (err) [failed addObject:[NSString stringWithFormat:@"%@: %@", j[@"path"], err]];
            else {
                NSString *newSha = json[@"content"][@"sha"];
                NSString *lp = [self localPath:j[@"path"]];
                if (![j[@"local"] isEqualToString:lp]) {   // загрузка извне — положить копию в зеркало
                    [FM() createDirectoryAtPath:lp.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                    [FM() removeItemAtPath:lp error:nil]; [FM() copyItemAtPath:j[@"local"] toPath:lp error:nil];
                }
                if ([newSha isKindOfClass:NSString.class]) GXGHSetBaseSha([self keyFor:j[@"path"]], newSha);
            }
            [self put:jobs index:i + 1 message:m failed:failed];
        }];
    };
    if ([j[@"sha"] length]) { send(j[@"sha"]); return; }
    [GXGH call:@"GET" path:[self apiContents:j[@"path"]] body:nil done:^(id json, NSInteger st, NSString *err) {
        send([json isKindOfClass:NSDictionary.class] ? json[@"sha"] : nil);
    }];
}
- (void)deleteItem:(NSDictionary *)it {
    if (!GXGHToken().length) { GXAlert(self, GXL(@"Нужен вход"), GXL(@"Чтобы отправлять изменения, войди с токеном на главном экране GitHub.")); return; }
    GXPrompt(self, [NSString stringWithFormat:GXL(@"Удалить «%@» на GitHub?"), it[@"name"]], GXL(@"Будет создан коммит с удалением. Файл останется в истории репозитория."),
             [NSString stringWithFormat:@"Delete %@", it[@"name"]], GXL(@"Описание коммита"), GXL(@"Удалить"), ^(NSString *m) { // noi18n
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Удаляю…")];
        NSDictionary *body = @{@"message": m.length ? m : @"Delete", @"sha": it[@"sha"], @"branch": self->_branch};
        [GXGH call:@"DELETE" path:[NSString stringWithFormat:@"/repos/%@/contents/%@", self->_repo, GXGHEnc(it[@"path"])] body:body done:^(id json, NSInteger st, NSString *err) {
            [GXHUD hide];
            if (err) { GXAlert(self, GXL(@"Не удалось удалить"), err); return; }
            GXGHSetBaseSha([self keyFor:it[@"path"]], nil);
            [self reload];
        }];
    });
}
- (void)newFile {
    if (!GXGHToken().length) { GXAlert(self, GXL(@"Нужен вход"), GXL(@"Чтобы отправлять изменения, войди с токеном на главном экране GitHub.")); return; }
    GXPrompt(self, GXL(@"Новый файл"), GXL(@"Можно указать путь с папками: src/main.c"), nil, @"README.md", GXL(@"Создать"), ^(NSString *name) {
        name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!name.length) return;
        NSString *p = self->_path.length ? [self->_path stringByAppendingPathComponent:name] : name;
        NSString *lp = [self localPath:p];
        [FM() createDirectoryAtPath:lp.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![FM() fileExistsAtPath:lp]) [[NSData data] writeToFile:lp atomically:YES];
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Отправляю на GitHub…")];
        [self put:@[@{@"local": lp, @"path": p}] index:0 message:[NSString stringWithFormat:@"Create %@", name] failed:[NSMutableArray array]]; // noi18n
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [GXOpener open:lp from:self]; });
    });
}
- (void)pickUpload {
    if (!GXGHToken().length) { GXAlert(self, GXL(@"Нужен вход"), GXL(@"Чтобы отправлять изменения, войди с токеном на главном экране GitHub.")); return; }
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    p.allowsMultipleSelection = YES; p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];
    [self uploadPaths:paths];
}
- (void)uploadClipboard {
    if (!GXGHToken().length) { GXAlert(self, GXL(@"Нужен вход"), GXL(@"Чтобы отправлять изменения, войди с токеном на главном экране GitHub.")); return; }
    NSArray *p = GXClipboardPaths();
    if (!p.count) { GXAlert(self, GXL(@"Буфер пуст"), GXL(@"Отметь файлы в GX Files и нажми «Копировать», потом вернись сюда.")); return; }
    [self uploadPaths:p];
}
- (void)collect:(NSString *)path rel:(NSString *)rel into:(NSMutableArray *)jobs {
    if (GXIsDir(path)) {
        for (NSString *n in [FM() contentsOfDirectoryAtPath:path error:nil]) if (![n isEqualToString:@".git"] && ![n isEqualToString:@".DS_Store"])
            [self collect:[path stringByAppendingPathComponent:n] rel:[rel stringByAppendingPathComponent:n] into:jobs];
    } else [jobs addObject:@{@"local": path, @"path": rel}];
}
- (void)uploadPaths:(NSArray<NSString *> *)paths {
    NSMutableArray *jobs = [NSMutableArray array];
    for (NSString *p in paths) [self collect:p rel:(_path.length ? [_path stringByAppendingPathComponent:p.lastPathComponent] : p.lastPathComponent) into:jobs];
    if (!jobs.count) return;
    NSString *def = jobs.count == 1 ? [NSString stringWithFormat:@"Add %@", [jobs[0][@"path"] lastPathComponent]] : [NSString stringWithFormat:@"Add %lu files", (unsigned long)jobs.count]; // noi18n
    NSString *msg = jobs.count > 1 ? [NSString stringWithFormat:GXL(@"Файлов: %lu. Каждый файл станет отдельным коммитом с этим описанием."), (unsigned long)jobs.count] : nil;
    GXPrompt(self, GXL(@"Описание коммита"), msg, def, GXL(@"Что изменено"), GXL(@"Отправить"), ^(NSString *m) {
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Отправляю на GitHub…")];
        [self put:jobs index:0 message:m.length ? m : def failed:[NSMutableArray array]];
    });
}

#pragma mark Ветки и сайт

- (void)pickBranch {
    [GXGH call:@"GET" path:[NSString stringWithFormat:@"/repos/%@/branches?per_page=100", _repo] body:nil done:^(id json, NSInteger st, NSString *err) {
        if (err) { GXAlert(self, GXL(@"Ошибка"), err); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Ветка") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *b in ([json isKindOfClass:NSArray.class] ? json : @[])) {
            NSString *n = b[@"name"]; if (![n isKindOfClass:NSString.class]) continue;
            [a addAction:[UIAlertAction actionWithTitle:[n isEqualToString:self->_branch] ? [@"✓ " stringByAppendingString:n] : n style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                self->_branch = n; [self buildMenu];
                if (self->_path.length) [self.navigationController popToViewController:self animated:YES];
                [self reload];
            }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
        [self presentViewController:a animated:YES completion:nil];
    }];
}
- (void)openWeb {
    NSString *u = [NSString stringWithFormat:@"https://github.com/%@/tree/%@/%@", _repo, GXGHEnc(_branch), GXGHEnc(_path)];
    NSURL *url = [NSURL URLWithString:u];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
@end

#pragma mark - Главный экран

@implementation GXGitHubVC {
    NSDictionary *_user; NSArray<NSDictionary *> *_repos; NSString *_err; BOOL _loading;
}
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GitHub";
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
}
- (void)reload {
    if (!GXGHToken().length) { _user = nil; _repos = nil; _err = nil; [self.refreshControl endRefreshing]; [self.tableView reloadData]; return; }
    _loading = YES; [self.tableView reloadData];
    [GXGH call:@"GET" path:@"/user" body:nil done:^(id json, NSInteger st, NSString *err) {
        self->_user = [json isKindOfClass:NSDictionary.class] && !err ? json : nil;
        if (err) { self->_loading = NO; self->_err = err; [self.refreshControl endRefreshing]; [self.tableView reloadData]; return; }
        [GXGH call:@"GET" path:@"/user/repos?per_page=100&sort=updated" body:nil done:^(id j2, NSInteger s2, NSString *e2) {
            self->_loading = NO; self->_err = e2;
            self->_repos = [j2 isKindOfClass:NSArray.class] ? j2 : @[];
            [self.refreshControl endRefreshing];
            [self.tableView reloadData];
        }];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return @[GXL(@"Аккаунт"), @"", GXL(@"Мои репозитории")][s]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0 && !GXGHToken().length) return GXL(@"Без входа можно смотреть и скачивать публичные репозитории (до 60 запросов в час). Чтобы видеть приватные и отправлять изменения, войди с токеном доступа.");
    if (s == 1) return GXL(@"Файлы скачиваются в «Мои файлы/GitHub». Открой файл, измени его в GX Files — и в папке репозитория появится кнопка «Отправить изменения».");
    return nil;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 2;
    if (s == 1) return 1;
    if (!GXGHToken().length) return 0;
    return _loading || _err || !_repos.count ? 1 : (NSInteger)_repos.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 2;
    BOOL in = GXGHToken().length > 0;
    if (ip.section == 0) {
        if (ip.row == 0) {
            if (in) {
                c.textLabel.text = _user[@"login"] ?: (_err ? GXL(@"Ошибка входа") : GXL(@"Загрузка…"));
                c.detailTextLabel.text = _err ?: (_user[@"name"] != NSNull.null ? _user[@"name"] : nil);
                if (_err) c.detailTextLabel.textColor = UIColor.systemRedColor;
                c.imageView.image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
                c.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                c.textLabel.text = GXL(@"Войти с токеном…");
                c.textLabel.textColor = c.tintColor;
                c.imageView.image = [UIImage systemImageNamed:@"key.fill"];
            }
        } else {
            if (in) { c.textLabel.text = GXL(@"Выйти"); c.textLabel.textColor = UIColor.systemRedColor; c.imageView.image = [UIImage systemImageNamed:@"rectangle.portrait.and.arrow.right"]; c.imageView.tintColor = UIColor.systemRedColor; }
            else { c.textLabel.text = GXL(@"Как получить токен"); c.imageView.image = [UIImage systemImageNamed:@"questionmark.circle"]; }
        }
        return c;
    }
    if (ip.section == 1) {
        c.textLabel.text = GXL(@"Открыть репозиторий…");
        c.detailTextLabel.text = GXL(@"Любой публичный: владелец/название или ссылка");
        c.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (_loading || _err || !_repos.count) {
        c.textLabel.text = _loading ? GXL(@"Загрузка…") : _err ? _err : GXL(@"Репозиториев нет");
        c.textLabel.numberOfLines = 0;
        c.textLabel.textColor = _err ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *r = _repos[ip.row];
    c.textLabel.text = r[@"full_name"];
    NSString *desc = [r[@"description"] isKindOfClass:NSString.class] ? r[@"description"] : @"";
    c.detailTextLabel.text = [NSString stringWithFormat:@"★ %@ · %@%@%@", r[@"stargazers_count"], r[@"default_branch"], desc.length ? @" · " : @"", desc];
    c.imageView.image = [UIImage systemImageNamed:[r[@"private"] boolValue] ? @"lock.fill" : @"book.closed"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    BOOL in = GXGHToken().length > 0;
    if (ip.section == 0) {
        if (ip.row == 0 && !in) [self login];
        else if (ip.row == 1 && in) GXConfirm(self, GXL(@"Выйти из GitHub?"), GXL(@"Токен будет удалён с этого устройства. Скачанные файлы останутся."), GXL(@"Выйти"), YES, ^{ GXGHSetToken(nil); [self reload]; });
        else if (ip.row == 1) [self help];
        return;
    }
    if (ip.section == 1) { [self openOther]; return; }
    if (_loading || _err || !_repos.count) return;
    NSDictionary *r = _repos[ip.row];
    [self.navigationController pushViewController:[[GXGHRepoVC alloc] initWithRepo:r[@"full_name"] branch:r[@"default_branch"] ?: @"main" path:@""] animated:YES];
}
- (void)help {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Токен доступа GitHub")
        message:GXL(@"1. Открой github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.\n2. В «Repository access» выбери нужные репозитории.\n3. В «Permissions → Repository permissions» поставь «Contents: Read and write».\n4. Создай токен, скопируй его и вставь в GX Files.\n\nТокен хранится только в Связке ключей этого iPhone и отправляется только на api.github.com.")
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Открыть страницу токенов") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/settings/personal-access-tokens/new"] options:@{} completionHandler:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Войти с токеном…") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self login]; }]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Закрыть") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)login {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Вход в GitHub") message:GXL(@"Вставь токен доступа (github_pat_… или ghp_…).") preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) {
        t.placeholder = @"github_pat_…"; t.secureTextEntry = YES;
        t.autocorrectionType = UITextAutocorrectionTypeNo; t.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Войти") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *t = [a.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!t.length) return;
        GXGHSetToken(t);
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Проверяю токен…")];
        [GXGH call:@"GET" path:@"/user" body:nil done:^(id json, NSInteger st, NSString *err) {
            [GXHUD hide];
            if (err) { GXGHSetToken(nil); GXAlert(self, GXL(@"Не удалось войти"), err); [self reload]; return; }
            GXToast(self.view, [NSString stringWithFormat:GXL(@"Вошёл как %@"), json[@"login"]]);
            [self reload];
        }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)openOther {
    GXPrompt(self, GXL(@"Открыть репозиторий"), GXL(@"Например: GRAFXXX/GX-Files или ссылка github.com/…"), nil, @"owner/repo", GXL(@"Открыть"), ^(NSString *s) { // noi18n
        s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange r = [s rangeOfString:@"github.com/"];
        if (r.location != NSNotFound) s = [s substringFromIndex:NSMaxRange(r)];
        NSArray *parts = [s componentsSeparatedByString:@"/"];
        if (parts.count < 2 || ![parts[0] length] || ![parts[1] length]) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Нужен формат владелец/название.")); return; }
        NSString *name = [parts[1] hasSuffix:@".git"] ? [parts[1] substringToIndex:[parts[1] length] - 4] : parts[1];
        NSString *full = [NSString stringWithFormat:@"%@/%@", parts[0], name];
        [GXHUD showIn:self.navigationController.view ?: self.view text:GXL(@"Загрузка…")];
        [GXGH call:@"GET" path:[@"/repos/" stringByAppendingString:full] body:nil done:^(id json, NSInteger st, NSString *err) {
            [GXHUD hide];
            if (err) { GXAlert(self, GXL(@"Не удалось открыть"), err); return; }
            [self.navigationController pushViewController:[[GXGHRepoVC alloc] initWithRepo:json[@"full_name"] ?: full branch:json[@"default_branch"] ?: @"main" path:@""] animated:YES];
        }];
    });
}
@end

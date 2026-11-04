// Сетевые диски по WebDAV: ПК, NAS, Nextcloud/ownCloud, Яндекс Диск и др.
#import "GXCore.h"
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Учётные записи (адрес и логин — в настройках, пароль — в Связке ключей)

static NSString *const kDAVKey = @"gxDAVAccounts";

static NSString *GXDAVKeychainAccount(NSDictionary *acc) { return [NSString stringWithFormat:@"%@|%@", acc[@"url"], acc[@"user"] ?: @""]; }

static NSString *_Nullable GXDAVPassword(NSDictionary *acc) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: @"GXFiles.webdav",
                        (__bridge id)kSecAttrAccount: GXDAVKeychainAccount(acc),
                        (__bridge id)kSecReturnData: @YES};
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    NSData *d = (__bridge_transfer NSData *)out;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static void GXDAVSetPassword(NSDictionary *acc, NSString *_Nullable pass) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: @"GXFiles.webdav",
                        (__bridge id)kSecAttrAccount: GXDAVKeychainAccount(acc)};
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!pass.length) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(__bridge id)kSecValueData] = [pass dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

static NSArray<NSDictionary *> *GXDAVAccounts(void) { return [GXDefaults() arrayForKey:kDAVKey] ?: @[]; }
static void GXDAVSaveAccounts(NSArray *a) { [GXDefaults() setObject:a forKey:kDAVKey]; }

#pragma mark - Клиент

@interface GXDAVItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic) BOOL dir;
@property (nonatomic) unsigned long long size;
@property (nonatomic, strong, nullable) NSDate *modified;
@end
@implementation GXDAVItem
@end

@interface GXDAVClient : NSObject <NSURLSessionTaskDelegate, NSXMLParserDelegate>
- (instancetype)initWithAccount:(NSDictionary *)acc;
@property (nonatomic, readonly) NSURL *base;
- (void)list:(NSURL *)dir done:(void (^)(NSArray<GXDAVItem *> *_Nullable items, NSString *_Nullable err))done;
- (NSURLSessionTask *)download:(NSURL *)url to:(NSString *)path done:(void (^)(NSString *_Nullable err))done;
- (NSURLSessionTask *)upload:(NSString *)path to:(NSURL *)url done:(void (^)(NSString *_Nullable err))done;
- (void)method:(NSString *)m url:(NSURL *)url headers:(nullable NSDictionary *)h done:(void (^)(NSString *_Nullable err))done;
@end

@implementation GXDAVClient {
    NSDictionary *_acc; NSURLSession *_s; NSString *_pass;
    // разбор PROPFIND
    NSMutableArray<GXDAVItem *> *_items; GXDAVItem *_cur; NSMutableString *_text; BOOL _inProp; NSURL *_reqURL;
}
- (instancetype)initWithAccount:(NSDictionary *)acc {
    if ((self = [super init])) {
        _acc = acc;
        NSString *u = acc[@"url"];
        if (![u hasSuffix:@"/"]) u = [u stringByAppendingString:@"/"];
        _base = [NSURL URLWithString:u];
        _pass = GXDAVPassword(acc) ?: @"";
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.timeoutIntervalForRequest = 60;
        c.HTTPAdditionalHeaders = @{@"User-Agent": @"GXFiles"};
        _s = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    }
    return self;
}
- (void)dealloc { [_s finishTasksAndInvalidate]; }

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)ch
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))done {
    NSString *m = ch.protectionSpace.authenticationMethod;
    if ([m isEqualToString:NSURLAuthenticationMethodServerTrust]) { done(NSURLSessionAuthChallengePerformDefaultHandling, nil); return; }
    NSString *user = _acc[@"user"];
    // без логина или после неудачной попытки — пусть сервер вернёт 401, тогда покажем понятную ошибку
    if (!user.length || ch.previousFailureCount > 0) { done(NSURLSessionAuthChallengePerformDefaultHandling, nil); return; }
    done(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialWithUser:user password:_pass persistence:NSURLCredentialPersistenceForSession]);
}

static NSString *GXDAVStatusError(NSURLResponse *r, NSError *e) {
    if (e) return e.code == NSURLErrorCancelled ? @"cancelled" : e.code == NSURLErrorUserCancelledAuthentication ? GXL(@"Неверный логин или пароль") : e.localizedDescription;
    NSInteger c = [(NSHTTPURLResponse *)r statusCode];
    if (c >= 200 && c < 300) return nil;
    if (c == 401 || c == 403) return GXL(@"Нет доступа: проверь логин и пароль");
    if (c == 404) return GXL(@"Не найдено на сервере");
    if (c == 405) return GXL(@"Сервер не поддерживает это действие");
    if (c == 507) return GXL(@"На сервере закончилось место");
    return [NSString stringWithFormat:GXL(@"Ошибка сервера: HTTP %ld"), (long)c];
}

- (void)list:(NSURL *)dir done:(void (^)(NSArray<GXDAVItem *> *, NSString *))done {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:dir];
    r.HTTPMethod = @"PROPFIND";
    [r setValue:@"1" forHTTPHeaderField:@"Depth"];
    [r setValue:@"application/xml; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = [@"<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop>"
                  "<d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>"
                  dataUsingEncoding:NSUTF8StringEncoding];
    [[_s dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *e) {
        NSString *err = GXDAVStatusError(resp, e);
        NSArray *items = nil;
        if (!err) {
            items = [self parse:data request:dir];
            if (!items) err = GXL(@"Сервер ответил не как WebDAV — проверь адрес");
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(items, err); });
    }] resume];
}

static NSString *GXDAVNorm(NSURL *u) {
    NSString *p = u.path.length ? u.path : @"/";
    while (p.length > 1 && [p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    return p;
}

- (nullable NSArray *)parse:(NSData *)data request:(NSURL *)dir {
    @synchronized (self) {
        _items = [NSMutableArray array]; _cur = nil; _reqURL = dir;
        NSXMLParser *p = [[NSXMLParser alloc] initWithData:data];
        p.shouldProcessNamespaces = YES;
        p.delegate = self;
        if (![p parse] && !_items.count) return nil;
        NSString *self_ = GXDAVNorm(dir);
        NSMutableArray *out = [NSMutableArray array];
        for (GXDAVItem *it in _items) if (![GXDAVNorm(it.url) isEqualToString:self_]) [out addObject:it];
        [out sortUsingComparator:^NSComparisonResult(GXDAVItem *a, GXDAVItem *b) {
            if (a.dir != b.dir) return a.dir ? NSOrderedAscending : NSOrderedDescending;
            return [a.name localizedStandardCompare:b.name];
        }];
        return out;
    }
}

- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    _text = [NSMutableString string];
    if ([el isEqualToString:@"response"]) _cur = [GXDAVItem new];
    else if ([el isEqualToString:@"collection"]) _cur.dir = YES;
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { [_text appendString:s]; }
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)el namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    NSString *t = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!_cur) return;
    if ([el isEqualToString:@"href"] && !_cur.url) {
        NSString *h = [t stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLFragmentAllowedCharacterSet];
        if ([t rangeOfString:@"%"].location != NSNotFound) h = t;      // уже закодирован
        _cur.url = [NSURL URLWithString:h relativeToURL:_reqURL].absoluteURL;
    } else if ([el isEqualToString:@"displayname"] && t.length) _cur.name = t;
    else if ([el isEqualToString:@"getcontentlength"]) _cur.size = strtoull(t.UTF8String, NULL, 10);
    else if ([el isEqualToString:@"getlastmodified"] && t.length) {
        static NSDateFormatter *f; static dispatch_once_t o;
        dispatch_once(&o, ^{ f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz"; });
        _cur.modified = [f dateFromString:t];
    } else if ([el isEqualToString:@"response"]) {
        if (_cur.url) {
            if (!_cur.name.length) _cur.name = _cur.url.lastPathComponent.stringByRemovingPercentEncoding ?: _cur.url.lastPathComponent;
            [_items addObject:_cur];
        }
        _cur = nil;
    }
}

- (NSURLSessionTask *)download:(NSURL *)url to:(NSString *)path done:(void (^)(NSString *))done {
    NSURLSessionDownloadTask *t = [_s downloadTaskWithURL:url completionHandler:^(NSURL *loc, NSURLResponse *resp, NSError *e) {
        NSString *err = GXDAVStatusError(resp, e);
        if (!err) {
            [FM() removeItemAtPath:path error:nil];
            NSError *me = nil;
            if (![FM() moveItemAtURL:loc toURL:[NSURL fileURLWithPath:path] error:&me]) err = me.localizedDescription;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(err); });
    }];
    [t resume];
    return t;
}

- (NSURLSessionTask *)upload:(NSString *)path to:(NSURL *)url done:(void (^)(NSString *))done {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"PUT";
    r.timeoutInterval = 600;
    NSURLSessionUploadTask *t = [_s uploadTaskWithRequest:r fromFile:[NSURL fileURLWithPath:path] completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSString *err = GXDAVStatusError(resp, e);
        dispatch_async(dispatch_get_main_queue(), ^{ done(err); });
    }];
    [t resume];
    return t;
}

- (void)method:(NSString *)m url:(NSURL *)url headers:(NSDictionary *)h done:(void (^)(NSString *))done {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = m;
    [h enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) { [r setValue:v forHTTPHeaderField:k]; }];
    [[_s dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSString *err = GXDAVStatusError(resp, e);
        dispatch_async(dispatch_get_main_queue(), ^{ done(err); });
    }] resume];
}
@end

static NSURL *GXDAVChild(NSURL *dir, NSString *name, BOOL isDir) {
    NSString *enc = [name stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    enc = [enc stringByReplacingOccurrencesOfString:@"/" withString:@"%2F"];
    NSString *s = dir.absoluteString;
    if (![s hasSuffix:@"/"]) s = [s stringByAppendingString:@"/"];
    return [NSURL URLWithString:[s stringByAppendingFormat:@"%@%@", enc, isDir ? @"/" : @""]];
}

#pragma mark - Обзор папки на сервере

@interface GXDAVBrowserVC : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithClient:(GXDAVClient *)c url:(NSURL *)url title:(NSString *)title;
@end

@implementation GXDAVBrowserVC {
    GXDAVClient *_c; NSURL *_url; NSArray<GXDAVItem *> *_items; NSString *_err; BOOL _loading;
}
- (instancetype)initWithClient:(GXDAVClient *)c url:(NSURL *)url title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStylePlain])) { _c = c; _url = url; self.title = title; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) ws = self;
    UIAction *(^act)(NSString *, NSString *, void (^)(void)) = ^(NSString *t, NSString *im, void (^b)(void)) {
        return [UIAction actionWithTitle:t image:[UIImage systemImageNamed:im] identifier:nil handler:^(UIAction *x) { b(); }];
    };
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle"] menu:[UIMenu menuWithChildren:@[
        act(GXL(@"Загрузить из «Файлов»…"), @"folder", ^{ [ws pickUpload]; }),
        act(GXL(@"Загрузить из буфера GX Files"), @"doc.on.clipboard", ^{ [ws uploadClipboard]; }),
        act(GXL(@"Новая папка"), @"folder.badge.plus", ^{ [ws newFolder]; }),
        act(GXL(@"Обновить"), @"arrow.clockwise", ^{ [ws reload]; }),
    ]]];
    [self reload];
}
- (void)reload {
    _loading = YES; [self.tableView reloadData];
    [_c list:_url done:^(NSArray *items, NSString *err) {
        self->_loading = NO; self->_items = items ?: @[]; self->_err = err;
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
    }];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _loading || _err || !_items.count ? 1 : (NSInteger)_items.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (_loading || _err || !_items.count) {
        c.textLabel.text = _loading ? GXL(@"Загрузка…") : _err ?: GXL(@"Папка пуста");
        c.textLabel.textColor = _err ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
        c.textLabel.numberOfLines = 0;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    GXDAVItem *it = _items[ip.row];
    c.textLabel.text = it.name;
    c.imageView.image = [UIImage systemImageNamed:it.dir ? @"folder.fill" : @"doc"];
    c.imageView.tintColor = it.dir ? UIColor.systemBlueColor : UIColor.secondaryLabelColor;
    NSString *date = it.modified ? [NSDateFormatter localizedStringFromDate:it.modified dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"";
    c.detailTextLabel.text = it.dir ? date : [NSString stringWithFormat:@"%@ · %@", GXHuman(it.size), date];
    c.accessoryType = it.dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (_loading || _err || !_items.count) return;
    GXDAVItem *it = _items[ip.row];
    if (it.dir) { [self.navigationController pushViewController:[[GXDAVBrowserVC alloc] initWithClient:_c url:it.url title:it.name] animated:YES]; return; }
    [self downloadItem:it open:YES];
}

- (NSString *)downloadDir {
    NSString *d = [GXDocsDir() stringByAppendingPathComponent:@"WebDAV"]; // noi18n
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (void)downloadItem:(GXDAVItem *)it open:(BOOL)open {
    NSString *dst = GXUniquePath([self downloadDir], it.name);
    [GXHUD showCancellableIn:self.view text:[NSString stringWithFormat:GXL(@"Скачиваю «%@»…"), it.name]];
    NSURLSessionTask *t = [_c download:it.url to:dst done:^(NSString *err) {
        [GXHUD hide];
        if (err) { if (![err isEqualToString:@"cancelled"]) GXAlert(self, GXL(@"Не удалось скачать"), err); return; }
        if (open) [GXOpener open:dst from:self];
        else GXToast(self.view, [NSString stringWithFormat:GXL(@"Сохранено в «Мои файлы/WebDAV»: %@"), dst.lastPathComponent]);
    }];
    [self trackProgress:t total:it.size];
}

- (void)trackProgress:(NSURLSessionTask *)t total:(unsigned long long)total {
    __weak NSURLSessionTask *wt = t;
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        NSURLSessionTask *task = wt;
        if (!task || task.state == NSURLSessionTaskStateCompleted || task.state == NSURLSessionTaskStateCanceling) { [timer invalidate]; return; }
        if ([GXHUD cancelled]) { [task cancel]; [timer invalidate]; [GXHUD hide]; return; }
        int64_t done = MAX(task.countOfBytesReceived, task.countOfBytesSent);
        int64_t all = task.countOfBytesExpectedToSend > 0 ? task.countOfBytesExpectedToSend : (task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : (int64_t)total);
        if (all > 0) [GXHUD setProgress:(double)done / (double)all];
    }];
}

#pragma mark Загрузка на сервер

- (void)pickUpload {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    p.allowsMultipleSelection = YES;
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *u in urls) [paths addObject:u.path];
    [self uploadPaths:paths];
}
- (void)uploadClipboard {
    NSArray *p = GXClipboardPaths();
    if (!p.count) { GXAlert(self, GXL(@"Буфер пуст"), GXL(@"Отметь файлы в GX Files и нажми «Копировать», потом вернись сюда.")); return; }
    [self uploadPaths:p];
}

// Список «локальный файл → адрес на сервере» с папками (папки создаются заранее)
- (void)collect:(NSString *)path into:(NSURL *)dir files:(NSMutableArray *)files dirs:(NSMutableArray *)dirs {
    NSString *name = path.lastPathComponent;
    if (GXIsDir(path)) {
        NSURL *d = GXDAVChild(dir, name, YES);
        [dirs addObject:d];
        for (NSString *n in [FM() contentsOfDirectoryAtPath:path error:nil]) [self collect:[path stringByAppendingPathComponent:n] into:d files:files dirs:dirs];
    } else [files addObject:@[path, GXDAVChild(dir, name, NO)]];
}

- (void)uploadPaths:(NSArray<NSString *> *)paths {
    NSMutableArray *files = [NSMutableArray array], *dirs = [NSMutableArray array];
    for (NSString *p in paths) [self collect:p into:_url files:files dirs:dirs];
    if (!files.count && !dirs.count) return;
    [GXHUD showCancellableIn:self.view text:GXL(@"Загрузка на сервер…")];
    [self mkdirs:dirs index:0 then:^{ [self putFiles:files index:0 failed:0]; }];
}
- (void)mkdirs:(NSArray *)dirs index:(NSUInteger)i then:(void (^)(void))then {
    if (i >= dirs.count) { then(); return; }
    [_c method:@"MKCOL" url:dirs[i] headers:nil done:^(NSString *err) { [self mkdirs:dirs index:i + 1 then:then]; }];   // 405 — папка уже есть
}
- (void)putFiles:(NSArray *)files index:(NSUInteger)i failed:(int)failed {
    if (i >= files.count || [GXHUD cancelled]) {
        [GXHUD hide];
        if (failed) GXAlert(self, GXL(@"Загружено с ошибками"), [NSString stringWithFormat:GXL(@"Не удалось загрузить файлов: %d"), failed]);
        else GXToast(self.view, [NSString stringWithFormat:GXL(@"Загружено файлов: %lu"), (unsigned long)files.count]);
        [self reload];
        return;
    }
    NSArray *f = files[i];
    [GXHUD setText:[NSString stringWithFormat:@"%@ (%lu/%lu)", [f[0] lastPathComponent], (unsigned long)i + 1, (unsigned long)files.count]];
    NSURLSessionTask *t = [_c upload:f[0] to:f[1] done:^(NSString *err) { [self putFiles:files index:i + 1 failed:failed + (err ? 1 : 0)]; }];
    unsigned long long sz = [[FM() attributesOfItemAtPath:f[0] error:nil] fileSize];
    [self trackProgress:t total:sz];
}

#pragma mark Папки, удаление, переименование

- (void)newFolder {
    GXPrompt(self, GXL(@"Новая папка"), nil, nil, GXL(@"Имя папки"), GXL(@"Создать"), ^(NSString *name) {
        if (!name.length) return;
        [self->_c method:@"MKCOL" url:GXDAVChild(self->_url, name, YES) headers:nil done:^(NSString *err) {
            if (err) GXAlert(self, GXL(@"Не удалось создать"), err); else [self reload];
        }];
    });
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tv contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    if (_loading || _err || !_items.count) return nil;
    GXDAVItem *it = _items[ip.row];
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        NSMutableArray *a = [NSMutableArray array];
        if (!it.dir) {
            [a addObject:[UIAction actionWithTitle:GXL(@"Открыть") image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(UIAction *x) { [ws downloadItem:it open:YES]; }]];
            [a addObject:[UIAction actionWithTitle:GXL(@"Скачать в «Мои файлы»") image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(UIAction *x) { [ws downloadItem:it open:NO]; }]];
        }
        [a addObject:[UIAction actionWithTitle:GXL(@"Переименовать") image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *x) { [ws renameItem:it]; }]];
        [a addObject:[UIAction actionWithTitle:GXL(@"Копировать ссылку") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *x) {
            UIPasteboard.generalPasteboard.string = it.url.absoluteString; GXToast(ws.view, GXL(@"Скопировано"));
        }]];
        UIAction *del = [UIAction actionWithTitle:GXL(@"Удалить") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *x) { [ws removeItem:it]; }];
        del.attributes = UIMenuElementAttributesDestructive;
        [a addObject:del];
        return [UIMenu menuWithChildren:a];
    }];
}
- (void)renameItem:(GXDAVItem *)it {
    GXPrompt(self, GXL(@"Переименовать"), nil, it.name, nil, GXL(@"Готово"), ^(NSString *name) {
        if (!name.length || [name isEqualToString:it.name]) return;
        NSURL *parent = it.url.URLByDeletingLastPathComponent;
        NSURL *dst = GXDAVChild(parent, name, it.dir);
        [self->_c method:@"MOVE" url:it.url headers:@{@"Destination": dst.absoluteString, @"Overwrite": @"F"} done:^(NSString *err) {
            if (err) GXAlert(self, GXL(@"Не удалось переименовать"), err); else [self reload];
        }];
    });
}
- (void)removeItem:(GXDAVItem *)it {
    GXConfirm(self, [NSString stringWithFormat:GXL(@"Удалить «%@» с сервера?"), it.name], GXL(@"Файл удалится на сервере, вернуть его будет нельзя."), GXL(@"Удалить"), YES, ^{
        [self->_c method:@"DELETE" url:it.url headers:nil done:^(NSString *err) {
            if (err) GXAlert(self, GXL(@"Не удалось удалить"), err); else [self reload];
        }];
    });
}
@end

#pragma mark - Список серверов

@implementation GXDAVAccountsVC
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = GXL(@"Сетевые диски"); return self; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(add)];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return GXDAVAccounts().count ?: 1; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return GXL(@"WebDAV: компьютер, NAS, Nextcloud, ownCloud, Яндекс Диск (https://webdav.yandex.ru) и другие. Пароль хранится в Связке ключей iPhone.");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *a = GXDAVAccounts();
    if (!a.count) {
        c.textLabel.text = GXL(@"Добавить сервер");
        c.textLabel.textColor = self.view.tintColor;
        c.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
        return c;
    }
    NSDictionary *acc = a[ip.row];
    c.textLabel.text = acc[@"name"];
    c.detailTextLabel.text = [acc[@"user"] length] ? [NSString stringWithFormat:@"%@ · %@", acc[@"user"], acc[@"url"]] : acc[@"url"];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:@"externaldrive.connected.to.line.below.fill"];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *a = GXDAVAccounts();
    if (!a.count) { [self add]; return; }
    GXDAVClient *cl = [[GXDAVClient alloc] initWithAccount:a[ip.row]];
    if (!cl.base) { GXAlert(self, GXL(@"Неверный адрес"), a[ip.row][@"url"]); return; }
    [self.navigationController pushViewController:[[GXDAVBrowserVC alloc] initWithClient:cl url:cl.base title:a[ip.row][@"name"]] animated:YES];
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return GXDAVAccounts().count > 0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)st forRowAtIndexPath:(NSIndexPath *)ip {
    NSMutableArray *a = [GXDAVAccounts() mutableCopy];
    GXDAVSetPassword(a[ip.row], nil);
    [a removeObjectAtIndex:ip.row];
    GXDAVSaveAccounts(a);
    [tv reloadData];
}
- (void)add {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:GXL(@"Новый сервер WebDAV") message:GXL(@"Адрес вида https://сервер/remote.php/dav/files/имя/ или http://192.168.1.10:8080/") preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = GXL(@"Название (например, Мой ПК)"); }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = @"https://…"; t.keyboardType = UIKeyboardTypeURL; t.autocapitalizationType = UITextAutocapitalizationTypeNone; t.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = GXL(@"Логин (можно пусто)"); t.autocapitalizationType = UITextAutocapitalizationTypeNone; t.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *t) { t.placeholder = GXL(@"Пароль"); t.secureTextEntry = YES; }];
    [ac addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:GXL(@"Добавить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *name = ac.textFields[0].text, *url = [ac.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *user = ac.textFields[2].text, *pass = ac.textFields[3].text;
        if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) url = [@"https://" stringByAppendingString:url];
        NSURL *u = [NSURL URLWithString:url];
        if (!u.host.length) { GXAlert(self, GXL(@"Неверный адрес"), url); return; }
        NSDictionary *acc = @{@"name": name.length ? name : u.host, @"url": url, @"user": user ?: @""};
        GXDAVSetPassword(acc, pass);
        GXDAVSaveAccounts([GXDAVAccounts() arrayByAddingObject:acc]);
        [self.tableView reloadData];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

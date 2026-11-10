// Подпись dylib настоящим сертификатом разработчика (.p12 + опц. provisioning).
// Разбор .p12 и RSA-подпись — через Security.framework; сборка подписи — в gx_csign.c.
#import "GXCore.h"
#import "core/gx_csign.h"
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Хранилище

static NSString *GXSignDir(void) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"GXSign"];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static NSString *GXP12Path(void) { return [GXSignDir() stringByAppendingPathComponent:@"cert.p12"]; }
static NSString *GXProfPath(void) { return [GXSignDir() stringByAppendingPathComponent:@"profile.mobileprovision"]; }

static NSString *const kPwService = @"GXFiles.sign.pw";
static NSString *_Nullable GXSignPw(void) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: kPwService,
                        (__bridge id)kSecAttrAccount: @"p12", (__bridge id)kSecReturnData: @YES};
    CFTypeRef o = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &o) != errSecSuccess || !o) return nil;
    return [[NSString alloc] initWithData:(__bridge_transfer NSData *)o encoding:NSUTF8StringEncoding];
}
static void GXSignSetPw(NSString *_Nullable pw) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: kPwService, (__bridge id)kSecAttrAccount: @"p12"};
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!pw) return;
    NSMutableDictionary *a = [q mutableCopy];
    a[(__bridge id)kSecValueData] = [pw dataUsingEncoding:NSUTF8StringEncoding];
    a[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)a, NULL);
}

BOOL GXSignHasIdentity(void) { return [FM() fileExistsAtPath:GXP12Path()]; }
BOOL GXSignEnabled(void) { return GXSignHasIdentity() && [GXDefaults() boolForKey:@"gxSignEnabled"]; }
static NSDictionary *GXSignInfo(void) { return [GXDefaults() dictionaryForKey:@"gxSignInfo"] ?: @{}; }

#pragma mark - provisioning

// Разобрать .mobileprovision (CMS-обёртка вокруг XML-plist) → словарь.
static NSDictionary *_Nullable GXParseProfile(NSData *d) {
    if (!d) return nil;
    const char *b = d.bytes; NSInteger n = d.length;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    NSRange a = [s rangeOfString:@"<?xml"];
    NSRange e = [s rangeOfString:@"</plist>"];
    if (a.location == NSNotFound || e.location == NSNotFound) { (void)b; (void)n; return nil; }
    NSData *pl = [[s substringWithRange:NSMakeRange(a.location, NSMaxRange(e) - a.location)] dataUsingEncoding:NSISOLatin1StringEncoding];
    id o = [NSPropertyListSerialization propertyListWithData:pl options:0 format:NULL error:nil];
    return [o isKindOfClass:NSDictionary.class] ? o : nil;
}

#pragma mark - загрузка identity

// Понятный текст ошибки SecPKCS12Import.
static NSString *GXP12Err(OSStatus st, BOOL longPw) {
    if (st == errSecAuthFailed) return longPw ? GXL(@"Неверный пароль сертификата") : GXL(@"Неверный пароль");
    if (st == errSecDecode) return [NSString stringWithFormat:GXL(@"iOS не может прочитать этот формат .p12 (код %d). Обычно так бывает с файлами, сохранёнными в OpenSSL 3 (шифрование AES-256). Пересохрани .p12 в совместимом формате (3DES / SHA-1) и импортируй снова."), (int)st];
    return [NSString stringWithFormat:GXL(@"Не удалось открыть .p12 (код %d)"), (int)st];
}

// Возвращает identity + цепочку сертификатов + team id. nil + *err при ошибке.
static SecIdentityRef GXLoadIdentity(NSArray **certChainOut, NSString **teamOut, NSString **err) {
    NSData *p12 = [NSData dataWithContentsOfFile:GXP12Path()];
    if (!p12) { *err = GXL(@"Сертификат не загружен"); return NULL; }
    NSString *pw = GXSignPw() ?: @"";
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase: pw}, &items);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        if (items) CFRelease(items);
        *err = GXP12Err(st, YES);
        return NULL;
    }
    NSDictionary *item = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef ident = (SecIdentityRef)CFBridgingRetain(item[(__bridge id)kSecImportItemIdentity]);
    NSArray *chain = item[(__bridge id)kSecImportItemCertChain];
    if (certChainOut) *certChainOut = chain ? [chain copy] : @[];
    CFRelease(items);
    if (!ident) { *err = GXL(@"В .p12 нет приватного ключа и сертификата"); return NULL; }

    // Team ID: сначала из provisioning, иначе из OU сертификата
    NSString *team = nil;
    NSData *prof = [NSData dataWithContentsOfFile:GXProfPath()];
    NSDictionary *pp = GXParseProfile(prof);
    if ([pp[@"TeamIdentifier"] isKindOfClass:NSArray.class]) team = [pp[@"TeamIdentifier"] firstObject];
    if (!team.length && [pp[@"Entitlements"] isKindOfClass:NSDictionary.class]) team = pp[@"Entitlements"][@"com.apple.developer.team-identifier"];
    if (!team.length) {
        SecCertificateRef cert = NULL;
        if (SecIdentityCopyCertificate(ident, &cert) == errSecSuccess && cert) {
            NSData *der = (__bridge_transfer NSData *)SecCertificateCopyData(cert);
            char tm[64] = {0};
            if (der && gx_cert_fields(der.bytes, der.length, tm, sizeof tm, NULL, 0, NULL) && tm[0]) team = [NSString stringWithUTF8String:tm];
            CFRelease(cert);
        }
    }
    if (teamOut) *teamOut = team ?: @"";
    return ident;
}

#pragma mark - колбэк подписи

typedef struct { SecKeyRef key; NSString *err; } gxsctx;
static int gx_rsa_cb(void *ctx, const uint8_t *data, size_t n, uint8_t *sig, size_t *siglen) {
    gxsctx *c = ctx;
    NSData *d = [NSData dataWithBytes:data length:n];
    CFErrorRef e = NULL;
    CFDataRef s = SecKeyCreateSignature(c->key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)d, &e);
    if (!s) { c->err = e ? (__bridge_transfer NSString *)CFCopyDescription(e) : @"SecKeyCreateSignature"; return 0; }
    NSData *sd = (__bridge_transfer NSData *)s;
    if (sd.length > *siglen) return 0;
    memcpy(sig, sd.bytes, sd.length); *siglen = sd.length;
    return 1;
}

// Подписать файл dylib настоящим сертификатом. nil — успех, иначе текст ошибки.
NSString *_Nullable GXSignFileWithCert(NSString *path, NSString *ident, NSMutableString *log) {
    NSString *err = nil; NSArray *chain = nil; NSString *team = nil;
    SecIdentityRef identity = GXLoadIdentity(&chain, &team, &err);
    if (!identity) return err;
    SecKeyRef key = NULL;
    if (SecIdentityCopyPrivateKey(identity, &key) != errSecSuccess || !key) { CFRelease(identity); return GXL(@"Нет приватного ключа в сертификате"); }

    // DER сертификатов: leaf первым
    NSMutableArray<NSData *> *ders = [NSMutableArray array];
    SecCertificateRef leaf = NULL;
    if (SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess && leaf) { [ders addObject:(__bridge_transfer NSData *)SecCertificateCopyData(leaf)]; CFRelease(leaf); }
    for (id c in chain) { SecCertificateRef cc = (__bridge SecCertificateRef)c; NSData *dd = (__bridge_transfer NSData *)SecCertificateCopyData(cc);
        if (dd && ![ders containsObject:dd]) [ders addObject:dd]; }   // промежуточные (WWDR и т.п.)
    CFRelease(identity);
    if (!ders.count) { CFRelease(key); return GXL(@"Не удалось прочитать сертификат"); }

    size_t keyBytes = (SecKeyGetBlockSize(key));
    NSData *file = [NSData dataWithContentsOfFile:path];
    if (!file) { CFRelease(key); return GXL(@"Не удалось прочитать dylib"); }

    const uint8_t *certs[16]; size_t clens[16]; int nc = (int)MIN(ders.count, (NSUInteger)16);
    for (int i = 0; i < nc; i++) { certs[i] = ders[i].bytes; clens[i] = ders[i].length; }
    gxsctx cbctx = { key, nil };
    gx_sign_opts o = {0};
    o.ident = ident.UTF8String; o.teamid = team.UTF8String ?: ""; o.certs = certs; o.cert_lens = clens; o.ncerts = nc;
    o.sig_size = keyBytes; o.sign = gx_rsa_cb; o.sign_ctx = &cbctx;
    char e[256] = {0}; size_t ol = 0;
    uint8_t *out = gx_sign_macho(file.bytes, file.length, &o, &ol, e, sizeof e);
    CFRelease(key);
    if (!out) return cbctx.err ?: [NSString stringWithFormat:@"%s", e];
    NSData *sd = [NSData dataWithBytesNoCopy:out length:ol freeWhenDone:YES];
    if (![sd writeToFile:path atomically:YES]) return GXL(@"Не удалось записать подписанный файл");
    if (log) [log appendFormat:GXL(@"✓ подписано сертификатом (team %@, %d сертификат(а) в цепочке)\n"), team.length ? team : @"?", nc];
    return nil;
}

#pragma mark - импорт

// Проверить .p12 паролем и сохранить сведения для показа. nil — успех.
static NSString *GXTryImport(NSData *p12, NSString *pw) {
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase: pw ?: @""}, &items);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        if (items) CFRelease(items);
        return GXP12Err(st, NO);
    }
    NSDictionary *item = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef ident = (__bridge SecIdentityRef)(item[(__bridge id)kSecImportItemIdentity]);
    NSString *name = @"?", *expiry = nil;
    if (ident) {
        SecCertificateRef cert = NULL;
        if (SecIdentityCopyCertificate(ident, &cert) == errSecSuccess && cert) {
            name = (__bridge_transfer NSString *)SecCertificateCopySubjectSummary(cert) ?: @"?";
            NSData *der = (__bridge_transfer NSData *)SecCertificateCopyData(cert);
            char cn[128] = {0}; int64_t na = 0;
            if (der) gx_cert_fields(der.bytes, der.length, NULL, 0, cn, sizeof cn, &na);
            if (cn[0] && [name isEqualToString:@"?"]) name = [NSString stringWithUTF8String:cn];
            if (na > 0) {
                NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle;
                expiry = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)na]];
            }
            CFRelease(cert);
        }
    }
    CFRelease(items);
    [GXDefaults() setObject:@{@"name": name, @"expiry": expiry ?: @""} forKey:@"gxSignInfo"];
    return nil;
}

#pragma mark - Экран настроек подписи

@interface GXSignVC () <UIDocumentPickerDelegate>
@end

@implementation GXSignVC {
    NSString *_pendingKind;   // "p12" или "prof"
}
- (instancetype)init { if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = GXL(@"Подпись сертификатом"); return self; }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self.tableView reloadData]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return GXSignHasIdentity() ? 3 : 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 1;                 // переключатель
    if (s == 1) return 2;                 // импорт сертификата, импорт provisioning
    return 1;                             // удалить
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 1 ? GXL(@"Сертификат") : nil; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return GXL(@"Если включено, компилятор и «Внедрить dylib» подписывают файлы этим сертификатом вместо ad-hoc. Тогда dylib грузится и без JIT — на устройстве с тем же Team ID, что у приложения.");
    if (s == 1) return GXL(@"Нужен .p12 (сертификат разработчика с приватным ключом) и его пароль. Provisioning-профиль (.mobileprovision) не обязателен, но уточняет Team ID. Это те же файлы, которыми ты подписываешь IPA.");
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (ip.section == 0) {
        c.textLabel.text = GXL(@"Подписывать сертификатом");
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [UISwitch new]; sw.on = GXSignEnabled(); sw.enabled = GXSignHasIdentity();
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        NSDictionary *inf = GXSignInfo();
        if (GXSignHasIdentity() && [inf[@"name"] length]) c.detailTextLabel.text = [inf[@"expiry"] length] ? [NSString stringWithFormat:GXL(@"%@ · действует до %@"), inf[@"name"], inf[@"expiry"]] : inf[@"name"];
        return c;
    }
    if (ip.section == 1) {
        if (ip.row == 0) {
            c.textLabel.text = GXSignHasIdentity() ? GXL(@"Заменить сертификат (.p12)…") : GXL(@"Импортировать сертификат (.p12)…");
            c.imageView.image = [UIImage systemImageNamed:@"key.fill"]; c.textLabel.textColor = c.tintColor;
        } else {
            c.textLabel.text = [FM() fileExistsAtPath:GXProfPath()] ? GXL(@"Заменить provisioning…") : GXL(@"Добавить provisioning (.mobileprovision)…");
            c.imageView.image = [UIImage systemImageNamed:@"doc.badge.gearshape"]; c.textLabel.textColor = c.tintColor;
        }
        return c;
    }
    c.textLabel.text = GXL(@"Удалить сертификат"); c.textLabel.textColor = UIColor.systemRedColor;
    c.imageView.image = [UIImage systemImageNamed:@"trash"]; c.imageView.tintColor = UIColor.systemRedColor;
    return c;
}
- (void)toggle:(UISwitch *)sw { [GXDefaults() setBool:sw.on forKey:@"gxSignEnabled"]; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        _pendingKind = ip.row == 0 ? @"p12" : @"prof";
        UTType *t = ip.row == 0 ? [UTType typeWithFilenameExtension:@"p12"] ?: UTTypeData : [UTType typeWithFilenameExtension:@"mobileprovision"] ?: UTTypeData;
        UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[t, UTTypeData] asCopy:YES];
        p.delegate = self; [self presentViewController:p animated:YES completion:nil];
    } else if (ip.section == 2) {
        GXConfirm(self, GXL(@"Удалить сертификат?"), GXL(@"Файлы сертификата и пароль будут удалены с устройства."), GXL(@"Удалить"), YES, ^{
            [FM() removeItemAtPath:GXP12Path() error:nil]; [FM() removeItemAtPath:GXProfPath() error:nil];
            GXSignSetPw(nil); [GXDefaults() removeObjectForKey:@"gxSignInfo"]; [GXDefaults() setBool:NO forKey:@"gxSignEnabled"];
            [self.tableView reloadData];
        });
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject; if (!u) return;
    NSData *d = [NSData dataWithContentsOfURL:u];
    if (!d) { GXAlert(self, GXL(@"Ошибка"), GXL(@"Не удалось прочитать файл.")); return; }
    if ([_pendingKind isEqualToString:@"prof"]) {
        if (!GXParseProfile(d)) { GXAlert(self, GXL(@"Не похоже на provisioning"), GXL(@"Внутри нет plist-профиля.")); return; }
        [d writeToFile:GXProfPath() atomically:YES];
        GXToast(self.view, GXL(@"Provisioning добавлен"));
        [self.tableView reloadData];
        return;
    }
    // .p12 — спросить пароль и проверить
    UIAlertController *a = [UIAlertController alertControllerWithTitle:GXL(@"Пароль сертификата") message:GXL(@"Пароль, которым защищён .p12. Если пароля нет — оставь пусто.") preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t) { t.secureTextEntry = YES; t.placeholder = GXL(@"Пароль"); }];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Отмена") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:GXL(@"Проверить и сохранить") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *pw = a.textFields[0].text ?: @"";
        NSString *err = GXTryImport(d, pw);
        if (err) { GXAlert(self, GXL(@"Не подошло"), err); return; }
        [d writeToFile:GXP12Path() atomically:YES];
        GXSignSetPw(pw);
        if (![GXDefaults() objectForKey:@"gxSignEnabled"]) [GXDefaults() setBool:YES forKey:@"gxSignEnabled"];
        GXToast(self.view, GXL(@"Сертификат сохранён"));
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

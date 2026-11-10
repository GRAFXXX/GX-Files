// Подпись dylib настоящим сертификатом разработчика (.p12 + опц. provisioning).
// Разбор .p12 и RSA-подпись — через Security.framework; сборка подписи — в gx_csign.c.
#import "GXCore.h"
#import "core/gx_csign.h"
#import "core/gx_p12.h"
#import "core/gx_wwdr.h"
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

#pragma mark - загрузка подписанта

// Понятный текст ошибки системного импорта (фолбэк).
static NSString *GXP12Err(OSStatus st, BOOL longPw) {
    if (st == errSecAuthFailed) return longPw ? GXL(@"Неверный пароль сертификата") : GXL(@"Неверный пароль");
    if (st == errSecDecode) return GXL(@"Не удалось разобрать .p12");
    return [NSString stringWithFormat:GXL(@"Не удалось открыть .p12 (код %d)"), (int)st];
}

// Team ID: provisioning важнее, иначе OU сертификата (certTeam).
static NSString *GXResolveTeam(NSString *certTeam) {
    NSDictionary *pp = GXParseProfile([NSData dataWithContentsOfFile:GXProfPath()]);
    NSString *team = nil;
    if ([pp[@"TeamIdentifier"] isKindOfClass:NSArray.class]) team = [pp[@"TeamIdentifier"] firstObject];
    if (!team.length && [pp[@"Entitlements"] isKindOfClass:NSDictionary.class]) team = pp[@"Entitlements"][@"com.apple.developer.team-identifier"];
    return team.length ? team : (certTeam ?: @"");
}

// SecKeyRef (приватный RSA) из DER PKCS#1 (+1 к счётчику). nil при ошибке.
static SecKeyRef GXMakeRSAKey(const uint8_t *der, size_t n, int bits) {
    NSData *kd = [NSData dataWithBytes:der length:n];
    NSDictionary *a = @{(__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
                        (__bridge id)kSecAttrKeySizeInBits: @(bits)};
    CFErrorRef e = NULL;
    SecKeyRef k = SecKeyCreateWithData((__bridge CFDataRef)kd, (__bridge CFDictionaryRef)a, &e);
    if (e) CFRelease(e);
    return k;
}

// Свой разбор .p12 (поддерживает OpenSSL 3 / AES, который не берёт SecPKCS12Import).
// Выдаёт ключ (+1), DER-сертификаты (leaf первым) и team из сертификата. reason = GXP12_*.
static BOOL GXParseP12(NSData *p12, NSString *pw, SecKeyRef *keyOut,
                       NSMutableArray<NSData *> **dersOut, NSString **certTeamOut, int *reasonOut) {
    gx_p12 r; int reason = 0; char err[256] = {0};
    if (!gx_p12_parse(p12.bytes, p12.length, pw.UTF8String ?: "", &r, &reason, err, sizeof err)) {
        if (reasonOut) *reasonOut = reason; return NO;
    }
    SecKeyRef key = GXMakeRSAKey(r.key_pkcs1, r.key_len, r.key_bits);
    NSMutableArray<NSData *> *ders = [NSMutableArray array];
    for (int i = 0; i < r.ncerts; i++) [ders addObject:[NSData dataWithBytes:r.certs[i] length:r.cert_lens[i]]];
    NSString *team = nil;
    if (r.ncerts) { char tm[64] = {0}; if (gx_cert_fields(r.certs[0], r.cert_lens[0], tm, sizeof tm, NULL, 0, NULL) && tm[0]) team = @(tm); }
    gx_p12_free(&r);
    if (!key || !ders.count) { if (key) CFRelease(key); if (reasonOut) *reasonOut = GXP12_UNSUPPORTED; return NO; }
    *keyOut = key; *dersOut = ders; if (certTeamOut) *certTeamOut = team ?: @"";
    if (reasonOut) *reasonOut = GXP12_OK;
    return YES;
}

// Фолбэк: системный SecPKCS12Import. Выдаёт ключ (+1), DER-сертификаты (leaf первым), team из серта.
static BOOL GXLoadViaSec(NSData *p12, NSString *pw, SecKeyRef *keyOut,
                         NSMutableArray<NSData *> **dersOut, NSString **certTeamOut, NSString **err) {
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)@{(__bridge id)kSecImportExportPassphrase: pw ?: @""}, &items);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) == 0) { if (items) CFRelease(items); if (err) *err = GXP12Err(st, YES); return NO; }
    NSDictionary *item = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef ident = (SecIdentityRef)CFBridgingRetain(item[(__bridge id)kSecImportItemIdentity]);
    NSArray *chain = item[(__bridge id)kSecImportItemCertChain];
    CFRelease(items);
    if (!ident) { if (err) *err = GXL(@"В .p12 нет приватного ключа и сертификата"); return NO; }
    SecKeyRef key = NULL;
    if (SecIdentityCopyPrivateKey(ident, &key) != errSecSuccess || !key) { CFRelease(ident); if (err) *err = GXL(@"Нет приватного ключа в сертификате"); return NO; }
    NSMutableArray<NSData *> *ders = [NSMutableArray array]; NSString *certTeam = nil;
    SecCertificateRef leaf = NULL;
    if (SecIdentityCopyCertificate(ident, &leaf) == errSecSuccess && leaf) {
        NSData *ld = (__bridge_transfer NSData *)SecCertificateCopyData(leaf);
        if (ld) { [ders addObject:ld]; char tm[64] = {0}; if (gx_cert_fields(ld.bytes, ld.length, tm, sizeof tm, NULL, 0, NULL) && tm[0]) certTeam = @(tm); }
        CFRelease(leaf);
    }
    for (id c in chain) { NSData *dd = (__bridge_transfer NSData *)SecCertificateCopyData((__bridge SecCertificateRef)c); if (dd && ![ders containsObject:dd]) [ders addObject:dd]; }
    CFRelease(ident);
    if (!ders.count) { CFRelease(key); if (err) *err = GXL(@"Не удалось прочитать сертификат"); return NO; }
    *keyOut = key; *dersOut = ders; if (certTeamOut) *certTeamOut = certTeam ?: @"";
    return YES;
}

// Загрузить подписанта из данных .p12: сначала свой парсер, затем SecPKCS12Import.
// Выдаёт ключ (+1), DER-сертификаты (leaf первым) и готовый team (с учётом provisioning).
static BOOL GXLoadSignerData(NSData *p12, NSString *pw, SecKeyRef *keyOut,
                             NSMutableArray<NSData *> **dersOut, NSString **teamOut, NSString **err) {
    int reason = 0; NSString *certTeam = nil;
    if (GXParseP12(p12, pw, keyOut, dersOut, &certTeam, &reason)) { if (teamOut) *teamOut = GXResolveTeam(certTeam); return YES; }
    if (reason == GXP12_BADPW) { if (err) *err = GXL(@"Неверный пароль сертификата"); return NO; }
    if (!GXLoadViaSec(p12, pw, keyOut, dersOut, &certTeam, err)) return NO;   // фолбэк
    if (teamOut) *teamOut = GXResolveTeam(certTeam);
    return YES;
}

// Загрузить сохранённого подписанта (файл + пароль из Keychain).
static BOOL GXLoadSigner(SecKeyRef *keyOut, NSMutableArray<NSData *> **dersOut, NSString **teamOut, NSString **err) {
    NSData *p12 = [NSData dataWithContentsOfFile:GXP12Path()];
    if (!p12) { if (err) *err = GXL(@"Сертификат не загружен"); return NO; }
    return GXLoadSignerData(p12, GXSignPw() ?: @"", keyOut, dersOut, teamOut, err);
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

// Дополнить цепочку: если издателя leaf нет среди сертификатов, добавить встроенный Apple WWDR.
// Без промежуточного WWDR amfid не строит цепочку до Apple Root и подпись невалидна.
static void GXCompleteChain(NSMutableArray<NSData *> *ders) {
    if (!ders.count) return;
    NSData *leaf = ders[0];
    const uint8_t *iss; size_t issl;
    if (!gx_cert_name(leaf.bytes, leaf.length, 0, &iss, &issl)) return;
    for (NSData *c in ders) {               // издатель уже в цепочке?
        const uint8_t *sp; size_t sl;
        if (gx_cert_name(c.bytes, c.length, 1, &sp, &sl) && sl == issl && !memcmp(sp, iss, issl)) return;
    }
    size_t wl; const uint8_t *w = gx_wwdr_for_issuer(iss, issl, &wl);
    if (w) [ders addObject:[NSData dataWithBytes:w length:wl]];
}

// Подписать файл dylib настоящим сертификатом. nil — успех, иначе текст ошибки.
NSString *_Nullable GXSignFileWithCert(NSString *path, NSString *ident, NSMutableString *log) {
    SecKeyRef key = NULL; NSMutableArray<NSData *> *ders = nil; NSString *team = nil; NSString *err = nil;
    if (!GXLoadSigner(&key, &ders, &team, &err)) return err;
    GXCompleteChain(ders);                  // добавить Apple WWDR, если издателя leaf нет в цепочке

    NSData *file = [NSData dataWithContentsOfFile:path];
    if (!file) { CFRelease(key); return GXL(@"Не удалось прочитать dylib"); }

    const uint8_t *certs[16]; size_t clens[16]; int nc = (int)MIN(ders.count, (NSUInteger)16);
    for (int i = 0; i < nc; i++) { certs[i] = ders[i].bytes; clens[i] = ders[i].length; }
    gxsctx cbctx = { key, nil };
    gx_sign_opts o = {0};
    o.ident = ident.UTF8String; o.teamid = team.UTF8String ?: ""; o.certs = certs; o.cert_lens = clens; o.ncerts = nc;
    o.sig_size = SecKeyGetBlockSize(key); o.sign = gx_rsa_cb; o.sign_ctx = &cbctx;
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
    SecKeyRef key = NULL; NSMutableArray<NSData *> *ders = nil; NSString *team = nil, *err = nil;
    if (!GXLoadSignerData(p12, pw, &key, &ders, &team, &err)) return err ?: GXL(@"Не удалось разобрать .p12");
    CFRelease(key);
    NSData *leaf = ders.firstObject;
    NSString *name = @"?", *expiry = nil;
    if (leaf) {
        char cn[128] = {0}; int64_t na = 0;
        gx_cert_fields(leaf.bytes, leaf.length, NULL, 0, cn, sizeof cn, &na);
        if (cn[0]) name = @(cn);
        if (na > 0) { NSDateFormatter *f = [NSDateFormatter new]; f.dateStyle = NSDateFormatterMediumStyle;
            expiry = [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)na]]; }
    }
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

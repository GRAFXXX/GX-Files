// Языки интерфейса. Исходный язык — русский; переводы лежат в lang/<код>.json ({"русский": "перевод"})
#import "GXCore.h"
#include "core/gx_tr.h"
#include <os/lock.h>

static NSDictionary<NSString *, NSString *> *gxDict, *gxFallback;
static NSString *gxCode;
static os_unfair_lock gxLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSValue *, NSValue *> *gxCCache;

NSArray<NSArray<NSString *> *> *GXLanguages(void) {
    // код, название на этом языке
    return @[@[@"ru", @"Русский"] /* noi18n */, @[@"en", @"English"], @[@"uk", @"Українська"], @[@"be", @"Беларуская"],
             @[@"de", @"Deutsch"], @[@"fr", @"Français"], @[@"es", @"Español"], @[@"pt-BR", @"Português (Brasil)"]];
}
NSString *GXLangSetting(void) { return [NSUserDefaults.standardUserDefaults stringForKey:@"gxLanguage"]; }   // nil — как в системе

static NSString *GXSystemLang(void) {
    NSMutableArray *codes = [NSMutableArray array];
    for (NSArray *l in GXLanguages()) [codes addObject:l[0]];
    for (NSString *pref in NSLocale.preferredLanguages) {
        NSString *p = pref;
        if ([p hasPrefix:@"zh"]) p = [p containsString:@"Hant"] || [p hasSuffix:@"TW"] || [p hasSuffix:@"HK"] ? @"zh-Hant" : @"zh-Hans";
        if ([p hasPrefix:@"pt"]) p = @"pt-BR";
        if ([codes containsObject:p]) return p;
        NSString *base = [p componentsSeparatedByString:@"-"].firstObject;
        if ([codes containsObject:base]) return base;
    }
    return @"en";
}

static NSDictionary *GXLoadLang(NSString *code) {
    if ([code isEqualToString:@"ru"]) return @{};
    NSString *p = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"lang"] stringByAppendingPathComponent:[code stringByAppendingPathExtension:@"json"]];
    NSData *d = [NSData dataWithContentsOfFile:p];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [j isKindOfClass:NSDictionary.class] ? j : @{};
}

static void GXLangLoad(void) {
    NSString *code = @"ru"; NSDictionary *d = @{}, *fb = @{};
    @try {
        code = GXLangSetting() ?: GXSystemLang();
        d = GXLoadLang(code);
        fb = [code isEqualToString:@"ru"] || [code isEqualToString:@"en"] ? @{} : GXLoadLang(@"en");
        // славянские языки без перевода строки лучше показать по-русски, остальные — по-английски
        if ([@[@"uk", @"be"] containsObject:code]) fb = @{};
    } @catch (NSException *e) {
        // ошибка в переводах не должна мешать запуску — тогда интерфейс просто останется на русском
        NSLog(@"GX Files: language load failed: %@", e);
        code = @"ru"; d = @{}; fb = @{};
    }
    os_unfair_lock_lock(&gxLock);
    gxCode = code; gxDict = d; gxFallback = fb; gxCCache = [NSMutableDictionary dictionary];
    os_unfair_lock_unlock(&gxLock);
}

NSString *GXLangCode(void) {
    static dispatch_once_t o; dispatch_once(&o, ^{ if (!gxCode) GXLangLoad(); });
    return gxCode;
}

NSString *GXL(NSString *s) {
    if (!s) return s;
    GXLangCode();
    NSDictionary *d = gxDict, *fb = gxFallback;
    id t = d[s] ?: fb[s];
    return [t isKindOfClass:NSString.class] && [t length] ? t : s;
}

const char *gx_tr(const char *s) {
    if (!s) return s;
    GXLangCode();
    NSValue *k = [NSValue valueWithPointer:s];
    os_unfair_lock_lock(&gxLock);
    NSValue *v = gxCCache[k];
    os_unfair_lock_unlock(&gxLock);
    if (v) return v.pointerValue;
    NSString *src = [NSString stringWithUTF8String:s];
    NSString *t = src ? GXL(src) : nil;
    const char *r = s;
    if (t && t != src && ![t isEqualToString:src]) r = strdup(t.UTF8String);   // живёт до конца работы (строк немного)
    os_unfair_lock_lock(&gxLock);
    gxCCache[k] = [NSValue valueWithPointer:r];
    os_unfair_lock_unlock(&gxLock);
    return r;
}

void GXSetLanguage(NSString *code) {
    if (code) [NSUserDefaults.standardUserDefaults setObject:code forKey:@"gxLanguage"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"gxLanguage"];
    // системные экраны iOS (выбор файлов, палитра) берут язык из AppleLanguages
    if (code) [NSUserDefaults.standardUserDefaults setObject:@[code] forKey:@"AppleLanguages"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
    GXLangLoad();
}

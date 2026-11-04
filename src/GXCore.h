// GX Files — общие объявления
#import <UIKit/UIKit.h>
#include "core/gx_tr.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Помощники

NSFileManager *FM(void);
NSString *GXHuman(unsigned long long bytes);
NSDateFormatter *GXDateFmt(void);
NSString *GXUniquePath(NSString *dir, NSString *name);
NSString *GXTempDir(void);   // свежая временная папка в Caches
void GXAlert(UIViewController *vc, NSString *title, NSString *_Nullable msg);
void GXToast(UIView *anyView, NSString *text);
void GXConfirm(UIViewController *vc, NSString *title, NSString *_Nullable msg, NSString *action, BOOL destructive, void (^block)(void));
void GXPrompt(UIViewController *vc, NSString *title, NSString *_Nullable msg, NSString *_Nullable text, NSString *_Nullable placeholder,
              NSString *ok, void (^block)(NSString *value));
UIViewController *GXTopVC(UIViewController *vc);
void GXPresentNav(UIViewController *from, UIViewController *vc, BOOL fullScreen);
UIImage *GXSquareImage(UIImage *img, CGFloat side, CGFloat radius);
UIImage *GXSymbolTile(NSString *symbol, UIColor *color, CGFloat side);
NSString *GXHexString(NSData *d, NSUInteger max);

@interface GXHUD : NSObject
+ (void)showIn:(UIView *)v text:(NSString *)t;
+ (void)setText:(NSString *)t;
+ (void)setProgress:(double)p; // <0 — без прогресса
+ (void)hide;
+ (BOOL)cancelled;
+ (void)showCancellableIn:(UIView *)v text:(NSString *)t;
@end

// Работа в фоне с HUD; work возвращает текст ошибки или nil
void GXRunBG(UIViewController *vc, NSString *title, NSString *_Nullable (^work)(void), void (^_Nullable done)(void));

#pragma mark - Пути

NSString *_Nullable GXEnv(const char *name);
BOOL GXInLiveContainer(void);
NSString *_Nullable GXLCHome(void);
NSString *_Nullable GXLCAppGroup(void);
NSString *GXDocsDir(void);                                  // «Мои файлы»: Documents (в LiveContainer — общая папка)
// Подключённые папки из «Файлов» (iCloud Drive, «На iPhone», флешки) — закладки с доступом
NSArray<NSDictionary *> *GXLinkedFolders(void);             // @{name, path}
NSString *_Nullable GXAddLinkedFolder(NSURL *url);          // nil — успех, иначе текст ошибки
void GXRemoveLinkedFolder(NSString *path);
NSString *_Nullable GXLCBundlePath(void);
NSString *GXLCScheme(void);
BOOL GXIsDir(NSString *p);
NSArray<NSDictionary *> *GXRootSections(void); // [{title, rows:[{title, subtitle, path|action, icon, color}]}]

#pragma mark - Приложения LiveContainer

@interface GXLCApp : NSObject
@property (nonatomic, copy) NSString *name, *bundleId, *version, *bundlePath;
@property (nonatomic) BOOL isShared;
@property (nonatomic, strong) NSArray<NSDictionary *> *containers; // [{name, path}]
+ (NSArray<GXLCApp *> *)allApps:(BOOL)reload;
+ (nullable GXLCApp *)appWithBundleId:(NSString *)bid;
+ (nullable GXLCApp *)appForBundlePath:(NSString *)path;
+ (nullable GXLCApp *)appOwningDataFolder:(NSString *)path;
- (nullable UIImage *)icon;
- (void)launch;
@end


#pragma mark - Типы файлов

typedef NS_ENUM(NSInteger, GXKind) {
    GXKindFolder, GXKindApp, GXKindText, GXKindCode, GXKindPlist, GXKindJSON, GXKindStrings, GXKindImage, GXKindVideo, GXKindAudio,
    GXKindArchive, GXKindPDF, GXKindBinary, GXKindMachO, GXKindELF, GXKindAndroid, GXKindIPA, GXKindSQLite, GXKindFont,
    GXKindProvision, GXKindCar, GXKindOther
};

GXKind GXKindForPath(NSString *path, BOOL isDir);   // по расширению + сигнатуре
GXKind GXKindForName(NSString *name, BOOL isDir);   // только по расширению
NSString *GXSymbolForKind(GXKind k);
UIColor *GXColorForKind(GXKind k);
NSString *GXKindTitle(GXKind k);
BOOL GXIsZipFamily(NSString *path);
BOOL GXIsArchive(NSString *path);

#pragma mark - Настройки

// Языки интерфейса (GXLang.m). GXL(@"русский текст") → перевод на выбранный язык
NSString *GXL(NSString *s) NS_FORMAT_ARGUMENT(1);
NSString *GXLangCode(void);                                 // текущий: ru, en, uk…
NSString *_Nullable GXLangSetting(void);                    // nil — как в системе
NSArray<NSArray<NSString *> *> *GXLanguages(void);          // @[код, название]
void GXSetLanguage(NSString *_Nullable code);
NSUserDefaults *GXDefaults(void);
NSArray<NSString *> *GXFavorites(void);
void GXSetFavorites(NSArray *a);
NSArray<NSString *> *GXRecents(void);
void GXAddRecent(NSString *path);
BOOL GXShowHidden(void);
BOOL GXBigIcons(void);
BOOL GXThumbnails(void);

#pragma mark - Иконки

@interface GXIcons : NSObject
+ (nullable UIImage *)cachedForPath:(NSString *)path side:(CGFloat)side;
+ (void)iconForPath:(NSString *)path kind:(GXKind)kind side:(CGFloat)side completion:(void (^)(UIImage *_Nullable img))completion;
+ (nullable UIImage *)appBundleIcon:(NSString *)bundlePath;
+ (nullable UIImage *)apkIcon:(NSString *)path base:(uint64_t)base size:(uint64_t)size;
+ (nullable UIImage *)ipaIcon:(NSString *)path;
+ (void)clearCache;
@end

#pragma mark - Текстуры (.btx / .dds / SHTX)

BOOL GXIsTexturePath(NSString *path);
UIImage *_Nullable GXTextureImage(NSString *path, NSString *_Nullable *_Nullable info);
@interface GXTextureVC : UIViewController
- (instancetype)initWithPath:(NSString *)path;
@end

#pragma mark - Редактор бинарников (.dylib / Mach-O / .so)

@interface GXBinEditorVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

#pragma mark - Компилятор C → dylib (TinyCC)

@interface GXCompilerVC : UIViewController
- (instancetype)initWithPath:(nullable NSString *)path;   // nil — рабочая папка GX Compiler
@end
NSString *_Nullable GXCompileDylib(NSString *src, NSString *out, NSArray<NSString *> *libs, NSMutableString *log);

#pragma mark - Открытие

@interface GXOpener : NSObject
+ (void)open:(NSString *)path from:(UIViewController *)vc;
+ (void)open:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro;
+ (void)openWithMenu:(NSString *)path from:(UIViewController *)vc sourceView:(nullable UIView *)sv;
+ (void)quickLook:(NSArray<NSString *> *)paths index:(NSInteger)idx from:(UIViewController *)vc;
+ (void)openText:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro;
+ (void)openHex:(NSString *)path from:(UIViewController *)vc readOnly:(BOOL)ro;
@end

#pragma mark - Экраны

@interface GXBrowserVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
- (void)promptGoto;
- (void)downloadURL;
- (void)reload;
@property (nonatomic, readonly) NSString *path;
@end

@interface GXTextEditorVC : UIViewController
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initWithText:(NSString *)text title:(NSString *)title;
@property (nonatomic) BOOL readOnly;
@property (nonatomic, copy, nullable) NSString *_Nullable (^saveHandler)(NSString *text); // для текста не из файла
@property (nonatomic, copy, nullable) NSString *highlightExt;
@property (nonatomic, copy, nullable) NSString *initialFind;   // выделить первое вхождение после открытия
@property (nonatomic) BOOL initialFindRegex, initialFindCase;
@end

@interface GXBigTextVC : UIViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXHexVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@property (nonatomic) BOOL readOnly;
@end

@interface GXPlistVC : UITableViewController
- (nullable instancetype)initWithPath:(NSString *)path error:(NSString *_Nullable *_Nullable)err;
@property (nonatomic) BOOL readOnly;
@end

@interface GXSQLiteVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXReportVC : UIViewController
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text;
@end

@interface GXInfoVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXCarVC : UICollectionViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXArchiveVC : UITableViewController
- (instancetype)initWithArchive:(NSString *)path;
@end

@interface GXApkVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXIpaVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXAppsVC : UITableViewController
@end

@interface GXSearchVC : UITableViewController
- (instancetype)initWithRoot:(NSString *)root;
@end

@interface GXUsageVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;
@end

@interface GXGitHubVC : UITableViewController
@end
@interface GXDAVAccountsVC : UITableViewController   // сетевые диски WebDAV
@end

@interface GXServerVC : UITableViewController
- (instancetype)initWithRoot:(NSString *)root;
@end

@interface GXSettingsVC : UITableViewController
@end

@interface GXRootsVC : UITableViewController
@end

#pragma mark - Отчёты о бинарниках

NSString *GXMachOReport(NSString *path);
NSString *_Nullable GXEntitlementsXML(NSString *path);
NSString *GXELFReport(NSString *path);
NSData *_Nullable GXProvisionPlist(NSString *path);

#pragma mark - Архивы

@interface GXArcEntry : NSObject
@property (nonatomic, copy) NSString *path;   // без завершающего /
@property (nonatomic, copy, nullable) NSString *rawName; // точное имя записи в zip
@property (nonatomic) BOOL isDir, isLink;
@property (nonatomic) unsigned long long size, csize;
@property (nonatomic, strong, nullable) NSDate *date;
@property (nonatomic) long index;
@end

NSArray<GXArcEntry *> *_Nullable GXArchiveList(NSString *path, NSString *_Nullable *_Nullable err);
NSString *_Nullable GXArchiveExtractAll(NSString *path, NSString *destDir, void (^_Nullable progress)(double));
NSString *_Nullable GXArchiveExtractEntry(NSString *path, GXArcEntry *entry, NSString *destFile);
NSString *_Nullable GXArchiveCreate(NSArray<NSString *> *paths, NSString *dest, NSString *format, void (^_Nullable progress)(double));
NSString *_Nullable GXZipExtractEntries(NSString *zipPath, NSArray<NSString *> *names, NSString *destDir, BOOL flatten);

#pragma mark - Хэши

NSString *_Nullable GXHashFile(NSString *path, NSString *algo); // md5, sha1, sha256

#pragma mark - Редактирование архивов без распаковки (GXZipEdit.m)

// ops: @{@"name", @"newName", @"src" (путь), @"data" (NSData), @"del" (@YES)}. Пишет во временный файл и атомарно заменяет архив.
NSString *_Nullable GXZipApply(NSString *archive, NSArray<NSDictionary *> *ops, void (^_Nullable progress)(double));
NSString *_Nullable GXZipCreateFromFolder(NSString *folder, NSString *dest, BOOL apkAlign);
BOOL GXIsAPKPath(NSString *path);
NSString *_Nullable GXSignAPK(NSString *inPath, NSString *outPath, void (^_Nullable progress)(double));
void GXAPKSigInfo(NSString *path, BOOL *v1, BOOL *v2);
NSString *GXSignerInfo(void);

// Общая модель открытого архива: открытые на редактирование записи сохраняются обратно автоматически
@interface GXArcModel : NSObject
@property (nonatomic, readonly) NSString *path;
@property (nonatomic, readonly) NSArray<GXArcEntry *> *entries;
@property (nonatomic, readonly) BOOL editable, isAPK;
@property (nonatomic) BOOL modifiedSinceSign;
+ (instancetype)modelFor:(NSString *)path;
+ (void)commitAllFrom:(nullable UIViewController *)vc;
- (nullable NSString *)reload;
- (void)openEntry:(GXArcEntry *)e from:(UIViewController *)vc;
- (void)openEntry:(GXArcEntry *)e from:(UIViewController *)vc with:(nullable NSString *)how; // nil, @"menu", @"text", @"hex"
- (nullable GXArcEntry *)entryNamed:(NSString *)name;
- (void)apply:(NSArray<NSDictionary *> *)ops from:(UIViewController *)vc title:(NSString *)title done:(void (^_Nullable)(BOOL ok))done;
@end
extern NSString *const GXArcChangedNotification;

#pragma mark - Поиск/замена, пакетное переименование, сравнение, панели

@interface GXFindVC : UITableViewController
- (instancetype)initWithRoot:(NSString *)root;       // папка или архив
@end
@interface GXIpaToolsVC : UITableViewController
- (instancetype)initWithPath:(NSString *)path;   // .ipa или папка .app
@end
@interface GXDylibListVC : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, copy, nullable) void (^onRemove)(NSString *item);
@end
@interface GXDupVC : UITableViewController
- (instancetype)initWithRoot:(NSString *)root;
@end
@interface GXRenameVC : UITableViewController
- (instancetype)initWithPaths:(NSArray<NSString *> *)paths;
@end
@interface GXDiffVC : UITableViewController
- (instancetype)initWithLeft:(NSString *)a right:(NSString *)b;
@end
@interface GXPanelsVC : UIViewController
+ (nullable instancetype)shared;
@property (nonatomic, readonly) NSInteger current;
- (void)switchPanel;
- (nullable NSString *)otherPanelPath;      // папка, открытая в другой панели
- (UINavigationController *)currentNav;
@end
NSArray<NSString *> *GXClipboardPaths(void);
void GXSetCompareCandidate(NSString *_Nullable path);
NSString *_Nullable GXCompareCandidate(void);

NS_ASSUME_NONNULL_END

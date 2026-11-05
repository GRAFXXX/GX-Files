// Движок ИИ-помощника: только Foundation, без UIKit — собирается и тестируется отдельно.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// помощники из GXCore.m (в тестах — свои заглушки)
NSFileManager *FM(void);
NSString *GXHuman(unsigned long long bytes);
NSString *GXHexString(NSData *d, NSUInteger max);
BOOL GXIsDir(NSString *p);
NSUserDefaults *GXDefaults(void);
NSString *GXL(NSString *s) NS_FORMAT_ARGUMENT(1);

#pragma mark - Подключения

// подключение: @{id, name, kind: openai|anthropic, base, model, local?} (+ необязательный key — только для проверки, не сохраняется)
NSString *_Nullable GXAIKey(NSString *pid);
void GXAISetKey(NSString *pid, NSString *_Nullable key);
NSArray<NSDictionary *> *GXAIProviders(void);
void GXAISaveProviders(NSArray *a);
NSDictionary *_Nullable GXAIActive(void);
BOOL GXAIAskFirst(void);
NSArray<NSDictionary *> *GXAIPresets(void);
NSString *GXAIBase(NSDictionary *p);
NSString *GXJSONString(id _Nullable obj);
NSString *GXAIBackupRoot(void);
NSString *GXCut(NSString *s, NSUInteger n);

#pragma mark - Клиент API

// Ходы диалога в нейтральном виде:
//  @{role:user, text}
//  @{role:assistant, text, calls:[@{id, name, args}]}
//  @{role:tool, results:[@{id, name, content, error}]}
@interface GXAIClient : NSObject
+ (nullable NSURLSessionDataTask *)send:(NSDictionary *)p system:(NSString *)sys turns:(NSArray *)turns tools:(NSArray *)tools
                                   done:(void (^)(NSDictionary *_Nullable turn, NSString *_Nullable err))done;
+ (void)models:(NSDictionary *)p key:(nullable NSString *)key done:(void (^)(NSArray<NSString *> *list, NSString *_Nullable err))done;
@end

#pragma mark - Инструменты для файлов

@interface GXAITools : NSObject
- (instancetype)initWithRoot:(NSString *)root;
- (instancetype)initWithRoot:(NSString *)root state:(nullable NSDictionary *)st;   // восстановить из сохранённого чата
- (NSDictionary *)state;                                                           // для сохранения: журнал отмены и папка копий
@property (nonatomic, readonly) NSString *backupDir;
@property (nonatomic, readonly) NSString *root;
@property (nonatomic, readonly) NSMutableArray<NSDictionary *> *journal;   // для отмены
+ (NSArray<NSDictionary *> *)specs;                 // описания инструментов для модели
+ (BOOL)mutating:(NSString *)name;                  // меняет ли файлы (нужно подтверждение)
- (NSString *)describe:(NSString *)name args:(NSDictionary *)a;     // текст для подтверждения
- (NSString *)run:(NSString *)name args:(NSDictionary *)a isError:(BOOL *)isErr summary:(NSString *_Nullable *_Nonnull)sum;
- (NSString *)undoAll;
@end

#pragma mark - Сохранённые чаты

// Чат: @{id, title, root, created, updated, model, turns, items, tools} — файл Library/GXAIChats/<id>.json + index.json
@interface GXAISessions : NSObject
+ (NSArray<NSDictionary *> *)list;                  // кратко: id, title, root, updated, model, messages — новые сверху
+ (nullable NSDictionary *)load:(NSString *)sid;    // путь папки уточняется, незавершённые шаги закрываются
+ (void)save:(NSDictionary *)chat;                  // асинхронно, по порядку
+ (void)flush;                                      // дождаться записи
+ (void)rename:(NSString *)sid title:(NSString *)title;
+ (void)remove:(NSString *)sid;                     // вместе с резервными копиями этого чата
+ (void)forgetUndo;                                 // после удаления всех резервных копий
+ (NSArray *)sanitize:(NSArray *)turns;
@end

NS_ASSUME_NONNULL_END

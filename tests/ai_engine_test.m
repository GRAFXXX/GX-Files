// Автотесты движка ИИ-помощника (GXAIEngine.m). Запуск: tests/run_ai_tests.sh (macOS).
#import "GXAIEngine.h"

// ---- заглушки помощников из GXCore.m ----
NSFileManager *FM(void) { return NSFileManager.defaultManager; }
NSString *GXHuman(unsigned long long b) { return [NSString stringWithFormat:@"%llu B", b]; }
NSString *GXHexString(NSData *d, NSUInteger max) {
    NSMutableString *s = [NSMutableString string]; const uint8_t *p = d.bytes;
    for (NSUInteger i = 0; i < MIN(d.length, max); i++) [s appendFormat:@"%02x", p[i]];
    return s;
}
BOOL GXIsDir(NSString *p) { BOOL d = NO; return [FM() fileExistsAtPath:p isDirectory:&d] && d; }
NSUserDefaults *GXDefaults(void) { return NSUserDefaults.standardUserDefaults; }
NSString *GXL(NSString *s) { return s; }

static int fails = 0, passes = 0;
#define CHECK(cond, ...) do { if (cond) passes++; else { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static NSString *run(GXAITools *t, NSString *name, NSDictionary *a, BOOL *bad) {
    NSString *sum = nil; BOOL b = NO;
    NSString *r = [t run:name args:a isError:&b summary:&sum];
    if (bad) *bad = b;
    return r;
}
static NSString *rd(NSString *p) { return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil]; }

// снимок папки: относительный путь → содержимое (папки — @"<dir>")
static NSDictionary *snap(NSString *root) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *rel in [FM() enumeratorAtPath:root]) {
        NSString *p = [root stringByAppendingPathComponent:rel];
        m[rel] = GXIsDir(p) ? @"<dir>" : ([NSData dataWithContentsOfFile:p] ?: NSData.data);
    }
    return m;
}

static void testTools(void) {
    NSString *outer = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"gxai-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *root = [outer stringByAppendingPathComponent:@"root"];
    [FM() createDirectoryAtPath:[root stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"hello world\nline two\nhello again\n" writeToFile:[root stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"inner" writeToFile:[root stringByAppendingPathComponent:@"sub/inner.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSData *bp = [NSPropertyListSerialization dataWithPropertyList:@{@"Name": @"Old", @"Count": @3} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [bp writeToFile:[root stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    [@"secret" writeToFile:[outer stringByAppendingPathComponent:@"outside.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *before = snap(root);

    GXAITools *t = [[GXAITools alloc] initWithRoot:root];
    BOOL bad;

    // чтение и список
    NSString *r = run(t, @"list_dir", @{@"path": @".", @"depth": @2}, &bad);
    CHECK(!bad && [r containsString:@"hello.txt"] && [r containsString:@"sub/"] && [r containsString:@"inner.txt"], "list_dir: %s", r.UTF8String);
    r = run(t, @"read_file", @{@"path": @"hello.txt"}, &bad);
    CHECK(!bad && [r containsString:@"hello world"], "read_file");
    r = run(t, @"read_file", @{@"path": @"hello.txt", @"start_line": @2, @"max_lines": @1}, &bad);
    CHECK(!bad && [r containsString:@"line two"] && ![r containsString:@"hello world"], "read_file range: %s", r.UTF8String);

    // выход за пределы папки
    r = run(t, @"read_file", @{@"path": @"../outside.txt"}, &bad);
    CHECK(bad && ![r containsString:@"secret"], "escape read must fail: %s", r.UTF8String);
    r = run(t, @"write_file", @{@"path": @"sub/../../evil.txt", @"content": @"x"}, &bad);
    CHECK(bad && ![FM() fileExistsAtPath:[outer stringByAppendingPathComponent:@"evil.txt"]], "escape write must fail");
    r = run(t, @"delete", @{@"path": @"."}, &bad);
    CHECK(bad && GXIsDir(root), "deleting root must fail");
    r = run(t, @"read_file", @{@"path": [outer stringByAppendingPathComponent:@"outside.txt"]}, &bad);
    CHECK(bad || ![r containsString:@"secret"], "absolute outside path must not be readable");

    // правка текста
    r = run(t, @"edit_file", @{@"path": @"hello.txt", @"old_text": @"hello", @"new_text": @"bye"}, &bad);
    CHECK(bad && [r containsString:@"2 times"], "ambiguous edit must fail: %s", r.UTF8String);
    r = run(t, @"edit_file", @{@"path": @"hello.txt", @"old_text": @"nope", @"new_text": @"x"}, &bad);
    CHECK(bad, "missing fragment must fail");
    r = run(t, @"edit_file", @{@"path": @"hello.txt", @"old_text": @"line two", @"new_text": @"LINE 2"}, &bad);
    CHECK(!bad && [rd([root stringByAppendingPathComponent:@"hello.txt"]) containsString:@"LINE 2"], "edit_file: %s", r.UTF8String);
    r = run(t, @"edit_file", @{@"path": @"hello.txt", @"old_text": @"hello", @"new_text": @"bye", @"replace_all": @YES}, &bad);
    CHECK(!bad && ![rd([root stringByAppendingPathComponent:@"hello.txt"]) containsString:@"hello"], "replace_all");

    // бинарный plist: читается как XML, после правки остаётся двоичным
    r = run(t, @"read_file", @{@"path": @"Info.plist"}, &bad);
    CHECK(!bad && [r containsString:@"<string>Old</string>"], "bplist as XML: %s", r.UTF8String);
    r = run(t, @"edit_file", @{@"path": @"Info.plist", @"old_text": @"<string>Old</string>", @"new_text": @"<string>New</string>"}, &bad);
    NSData *nd = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"Info.plist"]];
    NSDictionary *pl = [NSPropertyListSerialization propertyListWithData:nd options:0 format:NULL error:nil];
    CHECK(!bad && nd.length > 6 && !memcmp(nd.bytes, "bplist", 6) && [pl[@"Name"] isEqual:@"New"] && [pl[@"Count"] isEqual:@3], "bplist edit stays binary");
    r = run(t, @"edit_file", @{@"path": @"Info.plist", @"old_text": @"<key>Name</key>", @"new_text": @"<key>Name"}, &bad);
    CHECK(bad, "broken plist XML must be rejected");

    // создание, перемещение, копирование, удаление
    r = run(t, @"write_file", @{@"path": @"new/deep/file.txt", @"content": @"fresh"}, &bad);
    CHECK(!bad && [rd([root stringByAppendingPathComponent:@"new/deep/file.txt"]) isEqual:@"fresh"], "write_file nested");
    r = run(t, @"make_dir", @{@"path": @"made/x"}, &bad);
    CHECK(!bad && GXIsDir([root stringByAppendingPathComponent:@"made/x"]), "make_dir");
    r = run(t, @"copy", @{@"from": @"hello.txt", @"to": @"sub"}, &bad);
    CHECK(!bad && [FM() fileExistsAtPath:[root stringByAppendingPathComponent:@"sub/hello.txt"]], "copy into folder");
    r = run(t, @"move", @{@"from": @"sub/inner.txt", @"to": @"renamed.txt"}, &bad);
    CHECK(!bad && [FM() fileExistsAtPath:[root stringByAppendingPathComponent:@"renamed.txt"]], "move/rename");
    r = run(t, @"move", @{@"from": @"renamed.txt", @"to": @"hello.txt"}, &bad);   // замена существующего
    CHECK(!bad && [rd([root stringByAppendingPathComponent:@"hello.txt"]) isEqual:@"inner"], "move over existing");
    r = run(t, @"delete", @{@"path": @"sub"}, &bad);
    CHECK(!bad && ![FM() fileExistsAtPath:[root stringByAppendingPathComponent:@"sub"]], "delete folder");
    r = run(t, @"search", @{@"query": @"fresh"}, &bad);
    CHECK(!bad && [r containsString:@"new/deep/file.txt:1"], "search content: %s", r.UTF8String);
    r = run(t, @"list_dir", @{@"path": @"."}, &bad);
    CHECK(![r containsString:@"GXAIBackups"], "backups hidden");

    // отмена возвращает папку побайтно
    CHECK(t.journal.count > 0, "journal not empty");
    NSString *u = [t undoAll];
    NSDictionary *after = snap(root);
    CHECK([after isEqualToDictionary:before], "undo must restore exactly (%s)\nbefore=%s\nafter=%s", u.UTF8String, before.allKeys.description.UTF8String, after.allKeys.description.UTF8String);
    CHECK([rd([outer stringByAppendingPathComponent:@"outside.txt"]) isEqual:@"secret"], "outside untouched");
    [FM() removeItemAtPath:outer error:nil];
}

// цикл агента: запрос → вызов инструмента → результат → ответ текстом
static void agentLoop(NSString *kind, NSString *base, NSString *root, NSString *expect) {
    NSDictionary *p = @{@"id": @"t", @"name": kind, @"kind": kind, @"base": base, @"model": @"mock-model", @"key": @"testkey"};
    GXAITools *tools = [[GXAITools alloc] initWithRoot:root];
    NSMutableArray *turns = [NSMutableArray arrayWithObject:@{@"role": @"user", @"text": @"What files are here?"}];
    __block NSString *final = nil, *error = nil; __block BOOL done = NO;
    __block void (^step)(int);
    __block __weak void (^wstep)(int);
    wstep = step = ^(int n) {
        if (n > 5) { error = @"too many steps"; done = YES; return; }
        [GXAIClient send:p system:@"test system" turns:turns tools:GXAITools.specs done:^(NSDictionary *turn, NSString *err) {
            if (err) { error = err; done = YES; return; }
            [turns addObject:turn];
            NSArray *calls = turn[@"calls"];
            if (!calls.count) { final = turn[@"text"]; done = YES; return; }
            NSMutableArray *res = [NSMutableArray array];
            for (NSDictionary *c in calls) {
                BOOL bad = NO; NSString *sum = nil;
                NSString *out = [tools run:c[@"name"] args:c[@"args"] isError:&bad summary:&sum];
                [res addObject:@{@"id": c[@"id"], @"name": c[@"name"], @"content": out, @"error": @(bad)}];
            }
            [turns addObject:@{@"role": @"tool", @"results": res}];
            wstep(n + 1);
        }];
    };
    step(0);
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done && [limit timeIntervalSinceNow] > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK(done && !error && [final containsString:expect], "%s agent loop: final=%s error=%s", kind.UTF8String, final.UTF8String ?: "nil", error.UTF8String ?: "nil");
}

static void testClient(NSString *server) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"gxai-c-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [FM() createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [@"hi" writeToFile:[root stringByAppendingPathComponent:@"hello.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    agentLoop(@"openai", [server stringByAppendingString:@"/v1/"], root, @"done-openai");
    agentLoop(@"anthropic", [server stringByAppendingString:@"/v1"], root, @"done-anthropic");   // «/v1» в адресе Anthropic отрезается

    // список моделей и ошибки
    __block BOOL done = NO; __block NSArray *list = nil;
    [GXAIClient models:@{@"kind": @"openai", @"base": [server stringByAppendingString:@"/v1"]} key:@"testkey" done:^(NSArray *l, NSString *e) { list = l; done = YES; }];
    while (!done) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK([list containsObject:@"mock-model"] && [list containsObject:@"other-model"], "models: %s", list.description.UTF8String);

    done = NO; __block NSString *err = nil;
    [GXAIClient send:@{@"id": @"t", @"kind": @"openai", @"base": [server stringByAppendingString:@"/v1"], @"model": @"missing-model", @"key": @"testkey"}
              system:@"s" turns:@[@{@"role": @"user", @"text": @"x"}] tools:GXAITools.specs done:^(NSDictionary *t, NSString *e) { err = e; done = YES; }];
    while (!done) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CHECK([err containsString:@"404"], "404 error mapped: %s", err.UTF8String);
    [FM() removeItemAtPath:root error:nil];
}


static void testSessions(void) {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"gxai-s-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [FM() createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [@"one" writeToFile:[root stringByAppendingPathComponent:@"a.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *before = snap(root);

    // изменения в «первом запуске»
    GXAITools *t = [[GXAITools alloc] initWithRoot:root];
    BOOL bad;
    run(t, @"edit_file", @{@"path": @"a.txt", @"old_text": @"one", @"new_text": @"two"}, &bad);
    run(t, @"write_file", @{@"path": @"dir/b.txt", @"content": @"new"}, &bad);
    run(t, @"move", @{@"from": @"a.txt", @"to": @"dir/a2.txt"}, &bad);
    NSString *backupDir = t.backupDir;
    NSString *sid = NSUUID.UUID.UUIDString;
    NSArray *turns = @[@{@"role": @"user", @"text": @"do it"},
                       @{@"role": @"assistant", @"text": @"", @"calls": @[@{@"id": @"c1", @"name": @"list_dir", @"args": @{}}]}];   // шаг без результата
    [GXAISessions save:@{@"id": sid, @"title": @"Test chat", @"root": root, @"turns": turns, @"items": @[@{@"kind": @"user", @"text": @"do it"}], @"tools": [t state]}];
    [GXAISessions flush];

    NSArray *list = [GXAISessions list];
    NSDictionary *meta = nil; for (NSDictionary *m in list) if ([m[@"id"] isEqual:sid]) meta = m;
    CHECK(meta && [meta[@"title"] isEqual:@"Test chat"] && [meta[@"messages"] intValue] == 1, "session listed: %s", meta.description.UTF8String);

    // «второй запуск»: загрузка и отмена по сохранённому журналу
    NSDictionary *c = [GXAISessions load:sid];
    CHECK([c[@"root"] isEqual:root], "root loaded");
    NSArray *lt = c[@"turns"];
    CHECK(lt.count == 3 && [lt.lastObject[@"role"] isEqual:@"tool"] && [lt.lastObject[@"results"][0][@"id"] isEqual:@"c1"], "unfinished step closed: %s", lt.description.UTF8String);
    GXAITools *t2 = [[GXAITools alloc] initWithRoot:c[@"root"] state:c[@"tools"]];
    CHECK(t2.journal.count == t.journal.count && [t2.backupDir isEqual:backupDir], "journal restored (%lu vs %lu)", (unsigned long)t2.journal.count, (unsigned long)t.journal.count);
    [t2 undoAll];
    CHECK([snap(root) isEqualToDictionary:before], "undo after reload restores folder");

    // переименование и удаление (с резервными копиями чата)
    [GXAISessions rename:sid title:@"Renamed"];
    meta = nil; for (NSDictionary *m in [GXAISessions list]) if ([m[@"id"] isEqual:sid]) meta = m;
    CHECK([meta[@"title"] isEqual:@"Renamed"] && [[GXAISessions load:sid][@"title"] isEqual:@"Renamed"], "rename");
    CHECK([FM() fileExistsAtPath:backupDir], "backup dir exists before delete");
    [GXAISessions remove:sid];
    BOOL still = NO; for (NSDictionary *m in [GXAISessions list]) if ([m[@"id"] isEqual:sid]) still = YES;
    CHECK(!still && ![GXAISessions load:sid] && ![FM() fileExistsAtPath:backupDir], "remove deletes chat and its backups");

    // путь из старого контейнера переводится в текущий
    NSString *rel = [@"Library/gxai-move-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *cur = [NSHomeDirectory() stringByAppendingPathComponent:rel];
    [FM() createDirectoryAtPath:cur withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *sid2 = NSUUID.UUID.UUIDString;
    NSString *f = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/GXAIChats"] stringByAppendingPathComponent:[sid2 stringByAppendingPathExtension:@"json"]];
    NSDictionary *raw = @{@"id": sid2, @"title": @"old", @"home": @"/var/old/container", @"root": [@"/var/old/container" stringByAppendingPathComponent:rel], @"turns": @[]};
    [[NSJSONSerialization dataWithJSONObject:raw options:0 error:nil] writeToFile:f atomically:YES];
    CHECK([[GXAISessions load:sid2][@"root"] isEqual:cur], "root remapped to current container: %s", [[GXAISessions load:sid2][@"root"] UTF8String]);
    CHECK(![GXAISessions load:@"../../etc/passwd"], "bad session id rejected");
    [GXAISessions remove:sid2];
    [FM() removeItemAtPath:cur error:nil];
    [FM() removeItemAtPath:root error:nil];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        testTools();
        testSessions();
        if (argc > 1) testClient([NSString stringWithUTF8String:argv[1]]);
        printf("AI engine tests: %d passed, %d failed\n", passes, fails);
        return fails ? 1 : 0;
    }
}

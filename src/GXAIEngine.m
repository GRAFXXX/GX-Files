// Движок ИИ-помощника (только Foundation): подключения, клиент API (OpenAI-совместимый / Anthropic)
// и файловые инструменты с ограничением папкой, резервными копиями и отменой.
#import "GXAIEngine.h"
#import <Security/Security.h>

#pragma mark - Ключи и провайдеры

static NSString *const kAIService = @"GXFiles.ai";

NSString *_Nullable GXAIKey(NSString *pid) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: kAIService, (__bridge id)kSecAttrAccount: pid,
                        (__bridge id)kSecReturnData: @YES};
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess || !out) return nil;
    return [[NSString alloc] initWithData:(__bridge_transfer NSData *)out encoding:NSUTF8StringEncoding];
}
void GXAISetKey(NSString *pid, NSString *_Nullable key) {
    NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecAttrService: kAIService, (__bridge id)kSecAttrAccount: pid};
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!key.length) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

// провайдер: @{id, name, kind: openai|anthropic, base, model}
NSArray<NSDictionary *> *GXAIProviders(void) { return [GXDefaults() arrayForKey:@"gxAIProviders"] ?: @[]; }
void GXAISaveProviders(NSArray *a) { [GXDefaults() setObject:a forKey:@"gxAIProviders"]; }
NSDictionary *_Nullable GXAIActive(void) {
    NSString *aid = [GXDefaults() stringForKey:@"gxAIActive"];
    for (NSDictionary *p in GXAIProviders()) if ([p[@"id"] isEqualToString:aid]) return p;
    return GXAIProviders().firstObject;
}
BOOL GXAIAskFirst(void) { return ![GXDefaults() objectForKey:@"gxAIConfirm"] || [GXDefaults() boolForKey:@"gxAIConfirm"]; }

NSArray<NSDictionary *> *GXAIPresets(void) {
    return @[
        @{@"name": @"OpenAI (ChatGPT)", @"kind": @"openai", @"base": @"https://api.openai.com/v1"},
        @{@"name": @"Anthropic (Claude)", @"kind": @"anthropic", @"base": @"https://api.anthropic.com"},
        @{@"name": @"Google Gemini", @"kind": @"openai", @"base": @"https://generativelanguage.googleapis.com/v1beta/openai"},
        @{@"name": @"OpenRouter", @"kind": @"openai", @"base": @"https://openrouter.ai/api/v1"},
        @{@"name": @"DeepSeek", @"kind": @"openai", @"base": @"https://api.deepseek.com/v1"},
        @{@"name": @"Groq", @"kind": @"openai", @"base": @"https://api.groq.com/openai/v1"},
        @{@"name": @"Mistral", @"kind": @"openai", @"base": @"https://api.mistral.ai/v1"},
        @{@"name": @"xAI (Grok)", @"kind": @"openai", @"base": @"https://api.x.ai/v1"},
        @{@"name": GXL(@"Ollama на компьютере"), @"kind": @"openai", @"base": @"http://192.168.1.10:11434/v1", @"local": @YES},
        @{@"name": GXL(@"LM Studio на компьютере"), @"kind": @"openai", @"base": @"http://192.168.1.10:1234/v1", @"local": @YES},
        @{@"name": GXL(@"Другой (OpenAI-совместимый)"), @"kind": @"openai", @"base": @""},
    ];
}

NSString *GXAIBase(NSDictionary *p) {
    NSString *b = [p[@"base"] ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([b hasSuffix:@"/"]) b = [b substringToIndex:b.length - 1];
    if ([p[@"kind"] isEqualToString:@"anthropic"] && [b hasSuffix:@"/v1"]) b = [b substringToIndex:b.length - 3];
    return b;
}

NSString *GXJSONString(id obj) {
    if (!obj) return @"{}";
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

#pragma mark - Клиент API

// Ходы диалога в нейтральном виде:
//  @{role:user, text}
//  @{role:assistant, text, calls:[@{id, name, args}]}
//  @{role:tool, results:[@{id, name, content, error}]}


@implementation GXAIClient
+ (NSURLSession *)session {
    static NSURLSession *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.timeoutIntervalForRequest = 600;      // локальные модели бывают медленными
        c.timeoutIntervalForResource = 1200;
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}
+ (NSString *)errorFrom:(id)json status:(NSInteger)st raw:(NSData *)d {
    NSString *m = nil;
    if ([json isKindOfClass:NSDictionary.class]) {
        id e = json[@"error"];
        if ([e isKindOfClass:NSDictionary.class]) m = e[@"message"];
        else if ([e isKindOfClass:NSString.class]) m = e;
        if (!m && [json[@"message"] isKindOfClass:NSString.class]) m = json[@"message"];
    } else if ([json isKindOfClass:NSArray.class] && [json count] && [json[0] isKindOfClass:NSDictionary.class]) {
        id e = json[0][@"error"]; if ([e isKindOfClass:NSDictionary.class]) m = e[@"message"];
    }
    if (!m && d.length) { m = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, (NSUInteger)400))] encoding:NSUTF8StringEncoding]; }
    if (st == 401 || st == 403) return [NSString stringWithFormat:GXL(@"Ключ API не подошёл (HTTP %ld). %@"), (long)st, m ?: @""];
    if (st == 404) return [NSString stringWithFormat:GXL(@"Адрес или модель не найдены (HTTP 404). Проверь адрес API и название модели. %@"), m ?: @""];
    if (st == 429) return [NSString stringWithFormat:GXL(@"Слишком много запросов или закончился лимит (HTTP 429). %@"), m ?: @""];
    return [NSString stringWithFormat:@"HTTP %ld: %@", (long)st, m ?: @"?"];
}
+ (NSMutableURLRequest *)req:(NSDictionary *)p path:(NSString *)path key:(NSString *)key {
    NSURL *u = [NSURL URLWithString:[GXAIBase(p) stringByAppendingString:path]];
    if (!u) return nil;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([p[@"kind"] isEqualToString:@"anthropic"]) {
        if (key.length) [r setValue:key forHTTPHeaderField:@"x-api-key"];
        [r setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    } else {
        if (key.length) [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
        [r setValue:@"GX Files" forHTTPHeaderField:@"X-Title"];
    }
    return r;
}

// ---------- OpenAI-совместимый формат ----------
+ (NSDictionary *)openAIBody:(NSDictionary *)p system:(NSString *)sys turns:(NSArray *)turns tools:(NSArray *)tools {
    NSMutableArray *msgs = [NSMutableArray arrayWithObject:@{@"role": @"system", @"content": sys}];
    for (NSDictionary *t in turns) {
        NSString *role = t[@"role"];
        if ([role isEqualToString:@"user"]) [msgs addObject:@{@"role": @"user", @"content": t[@"text"] ?: @""}];
        else if ([role isEqualToString:@"assistant"]) {
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithObject:@"assistant" forKey:@"role"];
            NSString *tx = t[@"text"];
            m[@"content"] = tx.length ? tx : (id)NSNull.null;
            NSArray *calls = t[@"calls"];
            if (calls.count) {
                NSMutableArray *tc = [NSMutableArray array];
                for (NSDictionary *c in calls)
                    [tc addObject:@{@"id": c[@"id"], @"type": @"function", @"function": @{@"name": c[@"name"], @"arguments": GXJSONString(c[@"args"])}}];
                m[@"tool_calls"] = tc;
            }
            [msgs addObject:m];
        } else if ([role isEqualToString:@"tool"]) {
            for (NSDictionary *r in t[@"results"])
                [msgs addObject:@{@"role": @"tool", @"tool_call_id": r[@"id"], @"content": r[@"content"] ?: @""}];
        }
    }
    NSMutableArray *ts = [NSMutableArray array];
    for (NSDictionary *s in tools)
        [ts addObject:@{@"type": @"function", @"function": @{@"name": s[@"name"], @"description": s[@"description"], @"parameters": s[@"params"]}}];
    return @{@"model": p[@"model"] ?: @"", @"messages": msgs, @"tools": ts};
}
+ (NSDictionary *)openAIParse:(id)json {
    NSDictionary *msg = nil;
    if ([json isKindOfClass:NSDictionary.class]) {
        NSArray *ch = json[@"choices"];
        if ([ch isKindOfClass:NSArray.class] && ch.count && [ch[0] isKindOfClass:NSDictionary.class]) msg = ch[0][@"message"];
    }
    if (![msg isKindOfClass:NSDictionary.class]) return nil;
    NSString *text = @"";
    id c = msg[@"content"];
    if ([c isKindOfClass:NSString.class]) text = c;
    else if ([c isKindOfClass:NSArray.class]) {
        NSMutableString *s = [NSMutableString string];
        for (id part in c) if ([part isKindOfClass:NSDictionary.class] && [part[@"text"] isKindOfClass:NSString.class]) [s appendString:part[@"text"]];
        text = s;
    }
    NSMutableArray *calls = [NSMutableArray array];
    NSArray *tc = msg[@"tool_calls"];
    if ([tc isKindOfClass:NSArray.class]) for (NSDictionary *x in tc) {
        if (![x isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *fn = x[@"function"];
        if (![fn isKindOfClass:NSDictionary.class] || ![fn[@"name"] isKindOfClass:NSString.class]) continue;
        id a = fn[@"arguments"];
        NSDictionary *args = @{};
        if ([a isKindOfClass:NSDictionary.class]) args = a;
        else if ([a isKindOfClass:NSString.class]) {
            id j = [NSJSONSerialization JSONObjectWithData:[a dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([j isKindOfClass:NSDictionary.class]) args = j;
        }
        NSString *cid = [x[@"id"] isKindOfClass:NSString.class] && [x[@"id"] length] ? x[@"id"] : [@"call_" stringByAppendingString:NSUUID.UUID.UUIDString];
        [calls addObject:@{@"id": cid, @"name": fn[@"name"], @"args": args}];
    }
    return @{@"role": @"assistant", @"text": text ?: @"", @"calls": calls};
}

// ---------- Anthropic ----------
+ (NSDictionary *)anthropicBody:(NSDictionary *)p system:(NSString *)sys turns:(NSArray *)turns tools:(NSArray *)tools {
    NSMutableArray *msgs = [NSMutableArray array];
    void (^push)(NSString *, NSArray *) = ^(NSString *role, NSArray *content) {
        if (!content.count) return;
        NSMutableDictionary *last = msgs.lastObject;
        if (last && [last[@"role"] isEqualToString:role]) [last[@"content"] addObjectsFromArray:content];   // подряд одна роль — склеить
        else [msgs addObject:[@{@"role": role, @"content": [content mutableCopy]} mutableCopy]];
    };
    for (NSDictionary *t in turns) {
        NSString *role = t[@"role"];
        if ([role isEqualToString:@"user"]) push(@"user", @[@{@"type": @"text", @"text": [t[@"text"] length] ? t[@"text"] : @"…"}]);
        else if ([role isEqualToString:@"assistant"]) {
            NSMutableArray *c = [NSMutableArray array];
            if ([t[@"text"] length]) [c addObject:@{@"type": @"text", @"text": t[@"text"]}];
            for (NSDictionary *x in t[@"calls"]) [c addObject:@{@"type": @"tool_use", @"id": x[@"id"], @"name": x[@"name"], @"input": x[@"args"] ?: @{}}];
            if (!c.count) [c addObject:@{@"type": @"text", @"text": @"…"}];
            push(@"assistant", c);
        } else if ([role isEqualToString:@"tool"]) {
            NSMutableArray *c = [NSMutableArray array];
            for (NSDictionary *r in t[@"results"]) {
                NSMutableDictionary *b = [@{@"type": @"tool_result", @"tool_use_id": r[@"id"], @"content": [r[@"content"] length] ? r[@"content"] : @"(empty)"} mutableCopy];
                if ([r[@"error"] boolValue]) b[@"is_error"] = @YES;
                [c addObject:b];
            }
            push(@"user", c);
        }
    }
    NSMutableArray *ts = [NSMutableArray array];
    for (NSDictionary *s in tools) [ts addObject:@{@"name": s[@"name"], @"description": s[@"description"], @"input_schema": s[@"params"]}];
    return @{@"model": p[@"model"] ?: @"", @"max_tokens": @8192, @"system": sys, @"messages": msgs, @"tools": ts};
}
+ (NSDictionary *)anthropicParse:(id)json {
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"content"] isKindOfClass:NSArray.class]) return nil;
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *calls = [NSMutableArray array];
    for (NSDictionary *b in json[@"content"]) {
        if (![b isKindOfClass:NSDictionary.class]) continue;
        if ([b[@"type"] isEqual:@"text"] && [b[@"text"] isKindOfClass:NSString.class]) [text appendString:b[@"text"]];
        else if ([b[@"type"] isEqual:@"tool_use"])
            [calls addObject:@{@"id": b[@"id"] ?: NSUUID.UUID.UUIDString, @"name": b[@"name"] ?: @"?", @"args": [b[@"input"] isKindOfClass:NSDictionary.class] ? b[@"input"] : @{}}];
    }
    return @{@"role": @"assistant", @"text": text, @"calls": calls};
}

+ (NSURLSessionDataTask *)send:(NSDictionary *)p system:(NSString *)sys turns:(NSArray *)turns tools:(NSArray *)tools
                          done:(void (^)(NSDictionary *, NSString *))done {
    BOOL ant = [p[@"kind"] isEqualToString:@"anthropic"];
    NSMutableURLRequest *r = [self req:p path:ant ? @"/v1/messages" : @"/chat/completions" key:[p[@"key"] isKindOfClass:NSString.class] ? p[@"key"] : GXAIKey(p[@"id"])];
    if (!r) { dispatch_async(dispatch_get_main_queue(), ^{ done(nil, GXL(@"Неверный адрес API")); }); return nil; }
    r.HTTPMethod = @"POST";
    NSDictionary *body = ant ? [self anthropicBody:p system:sys turns:turns tools:tools] : [self openAIBody:p system:sys turns:turns tools:tools];
    r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSURLSessionDataTask *t = [[self session] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSDictionary *turn = nil; NSString *err = nil;
        if (e) err = e.code == NSURLErrorCancelled ? @"cancelled" : e.localizedDescription;
        else if (st < 200 || st >= 300) err = [self errorFrom:json status:st raw:d];
        else {
            turn = ant ? [self anthropicParse:json] : [self openAIParse:json];
            if (!turn) err = [self errorFrom:json status:st raw:d];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(turn, err); });
    }];
    [t resume];
    return t;
}

+ (void)models:(NSDictionary *)p key:(NSString *)key done:(void (^)(NSArray<NSString *> *, NSString *))done {
    BOOL ant = [p[@"kind"] isEqualToString:@"anthropic"];
    NSMutableURLRequest *r = [self req:p path:ant ? @"/v1/models?limit=1000" : @"/models" key:key];
    if (!r) { done(@[], GXL(@"Неверный адрес API")); return; }
    r.timeoutInterval = 30;
    [[[self session] dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSMutableArray *list = [NSMutableArray array]; NSString *err = nil;
        if (e) err = e.localizedDescription;
        else if (st < 200 || st >= 300) err = [self errorFrom:json status:st raw:d];
        else {
            NSArray *data = [json isKindOfClass:NSDictionary.class] ? (json[@"data"] ?: json[@"models"]) : nil;
            if ([data isKindOfClass:NSArray.class]) for (NSDictionary *m in data) {
                if (![m isKindOfClass:NSDictionary.class]) continue;
                NSString *mid = m[@"id"] ?: m[@"name"] ?: m[@"model"];
                if ([mid isKindOfClass:NSString.class]) [list addObject:[mid hasPrefix:@"models/"] ? [mid substringFromIndex:7] : mid];
            }
            [list sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(list, err); });
    }] resume];
}
@end

#pragma mark - Инструменты для файлов

NSString *GXAIBackupRoot(void) { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/GXAIBackups"]; }



@implementation GXAITools {
    NSString *_backup; int _bn;
}
- (instancetype)initWithRoot:(NSString *)root { return [self initWithRoot:root state:nil]; }
- (instancetype)initWithRoot:(NSString *)root state:(NSDictionary *)st {
    if ((self = [super init])) {
        NSString *r = root.stringByStandardizingPath;
        while (r.length > 1 && [r hasSuffix:@"/"]) r = [r substringToIndex:r.length - 1];
        _root = r;
        _journal = [NSMutableArray array];
        NSString *bname = [st[@"backup"] isKindOfClass:NSString.class] ? st[@"backup"] : nil;
        if (!bname.length || [bname containsString:@"/"]) {
            NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyyMMdd-HHmmss";
            bname = [NSString stringWithFormat:@"%@-%@", [f stringFromDate:NSDate.date], [NSUUID.UUID.UUIDString substringToIndex:6]];
        }
        _backup = [GXAIBackupRoot() stringByAppendingPathComponent:bname];
        _bn = [st[@"bn"] respondsToSelector:@selector(intValue)] ? [st[@"bn"] intValue] : 0;
        // журнал хранится с относительными путями — переводим обратно в абсолютные
        NSString *br = GXAIBackupRoot();
        for (NSDictionary *e in ([st[@"journal"] isKindOfClass:NSArray.class] ? st[@"journal"] : @[])) {
            if (![e isKindOfClass:NSDictionary.class] || ![e[@"op"] isKindOfClass:NSString.class]) continue;
            NSMutableDictionary *x = [NSMutableDictionary dictionaryWithObject:e[@"op"] forKey:@"op"];
            BOOL ok = YES;
            for (NSString *k in @[@"path", @"from", @"to"]) if ([e[k] isKindOfClass:NSString.class]) {
                NSString *rel = e[k];
                if ([rel hasPrefix:@"/"] || [rel containsString:@".."]) { ok = NO; break; }
                x[k] = [rel isEqualToString:@"."] ? _root : [_root stringByAppendingPathComponent:rel];
            }
            if ([e[@"backup"] isKindOfClass:NSString.class]) {
                if ([e[@"backup"] containsString:@".."]) ok = NO; else x[@"backup"] = [br stringByAppendingPathComponent:e[@"backup"]];
            }
            if (ok && x[@"path"]) [_journal addObject:x];
        }
    }
    return self;
}
// состояние для сохранения чата (пути — относительные)
- (NSDictionary *)state {
    NSString *br = [GXAIBackupRoot() stringByAppendingString:@"/"];
    NSMutableArray *j = [NSMutableArray array];
    for (NSDictionary *e in _journal) {
        NSMutableDictionary *x = [NSMutableDictionary dictionaryWithObject:e[@"op"] forKey:@"op"];
        for (NSString *k in @[@"path", @"from", @"to"]) if (e[k]) x[k] = [self rel:e[k]];
        if ([e[@"backup"] hasPrefix:br]) x[@"backup"] = [e[@"backup"] substringFromIndex:br.length];
        [j addObject:x];
    }
    return @{@"backup": _backup.lastPathComponent, @"bn": @(_bn), @"journal": j};
}
- (NSString *)backupDir { return _backup; }

+ (NSDictionary *)obj:(NSDictionary *)props req:(NSArray *)req { return @{@"type": @"object", @"properties": props, @"required": req}; }
+ (NSArray<NSDictionary *> *)specs {
    static NSArray *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *str = @{@"type": @"string"};
        NSDictionary *path = @{@"type": @"string", @"description": @"Path relative to the working folder ('.' = the folder itself)"};
        s = @[
            @{@"name": @"list_dir", @"description": @"List files and folders. Use depth 2-3 to see nested structure (max 4).",
              @"params": [self obj:@{@"path": path, @"depth": @{@"type": @"integer", @"description": @"1-4, default 1"}} req:@[@"path"]]},
            @{@"name": @"read_file", @"description": @"Read a text file (binary .plist is shown as XML). Large files: use start_line/max_lines.",
              @"params": [self obj:@{@"path": path, @"start_line": @{@"type": @"integer"}, @"max_lines": @{@"type": @"integer"}} req:@[@"path"]]},
            @{@"name": @"write_file", @"description": @"Create a file or replace its whole content. Parent folders are created. Binary .plist stays binary.",
              @"params": [self obj:@{@"path": path, @"content": str} req:@[@"path", @"content"]]},
            @{@"name": @"edit_file", @"description": @"Replace an exact text fragment in a file. old_text must match exactly (including spaces) and be unique unless replace_all is true.",
              @"params": [self obj:@{@"path": path, @"old_text": str, @"new_text": str, @"replace_all": @{@"type": @"boolean"}} req:@[@"path", @"old_text", @"new_text"]]},
            @{@"name": @"make_dir", @"description": @"Create a folder (with parents).",
              @"params": [self obj:@{@"path": path} req:@[@"path"]]},
            @{@"name": @"move", @"description": @"Move or rename a file/folder. If 'to' is an existing folder, the item is moved into it.",
              @"params": [self obj:@{@"from": path, @"to": path} req:@[@"from", @"to"]]},
            @{@"name": @"copy", @"description": @"Copy a file/folder. If 'to' is an existing folder, the item is copied into it.",
              @"params": [self obj:@{@"from": path, @"to": path} req:@[@"from", @"to"]]},
            @{@"name": @"delete", @"description": @"Delete a file or folder (it is kept in a backup and can be restored by the user).",
              @"params": [self obj:@{@"path": path} req:@[@"path"]]},
            @{@"name": @"search", @"description": @"Find files whose name contains the text, and text files whose content contains it (case-insensitive).",
              @"params": [self obj:@{@"query": str, @"path": path, @"in_content": @{@"type": @"boolean", @"description": @"default true"}} req:@[@"query"]]},
            @{@"name": @"file_info", @"description": @"Size, dates and type of a file or folder.",
              @"params": [self obj:@{@"path": path} req:@[@"path"]]},
        ];
    });
    return s;
}
+ (BOOL)mutating:(NSString *)n { return [@[@"write_file", @"edit_file", @"make_dir", @"move", @"copy", @"delete"] containsObject:n]; }

#pragma mark пути

- (NSString *)rel:(NSString *)abs {
    if ([abs isEqualToString:_root]) return @".";
    if ([abs hasPrefix:[_root stringByAppendingString:@"/"]]) return [abs substringFromIndex:_root.length + 1];
    return abs;
}
- (nullable NSString *)abs:(id)p err:(NSString **)err {
    NSString *s = [p isKindOfClass:NSString.class] ? [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (!s.length || [s isEqualToString:@"."] || [s isEqualToString:@"./"] || [s isEqualToString:@"/"]) return _root;
    NSString *full = ([s isEqualToString:_root] || [s hasPrefix:[_root stringByAppendingString:@"/"]]) ? s : [_root stringByAppendingPathComponent:s];
    full = full.stringByStandardizingPath;
    BOOL inside = [full isEqualToString:_root] || [full hasPrefix:[_root stringByAppendingString:@"/"]];
    NSString *br = GXAIBackupRoot().stringByStandardizingPath;
    if (!inside || [full isEqualToString:br] || [full hasPrefix:[br stringByAppendingString:@"/"]]) {
        *err = [NSString stringWithFormat:@"Error: path '%@' is outside the working folder.", s];
        return nil;
    }
    return full;
}
- (BOOL)hidden:(NSString *)full {
    NSString *br = GXAIBackupRoot().stringByStandardizingPath;
    return [full isEqualToString:br] || [full hasPrefix:[br stringByAppendingString:@"/"]];
}

#pragma mark резервные копии и журнал

- (NSString *)backupSlot:(NSString *)name {
    NSString *d = [_backup stringByAppendingPathComponent:[NSString stringWithFormat:@"%d", ++_bn]];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return [d stringByAppendingPathComponent:name.length ? name : @"item"];
}
// первая несуществующая папка на пути к parent — её создадим и запишем в журнал
- (void)ensureParent:(NSString *)full {
    NSString *parent = full.stringByDeletingLastPathComponent, *top = nil;
    for (NSString *x = parent; x.length > _root.length && ![FM() fileExistsAtPath:x]; x = x.stringByDeletingLastPathComponent) top = x;
    if (top) {
        [FM() createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        [_journal addObject:@{@"op": @"created", @"path": top}];
    }
}
- (BOOL)backupCopy:(NSString *)full {     // файл остаётся на месте, копия — в резерв
    NSString *b = [self backupSlot:full.lastPathComponent];
    if (![FM() copyItemAtPath:full toPath:b error:nil]) return NO;
    [_journal addObject:@{@"op": @"modified", @"path": full, @"backup": b}];
    return YES;
}
- (BOOL)backupMove:(NSString *)full {     // файл уходит в резерв (удаление / замена)
    NSString *b = [self backupSlot:full.lastPathComponent];
    if (![FM() moveItemAtPath:full toPath:b error:nil]) return NO;
    [_journal addObject:@{@"op": @"deleted", @"path": full, @"backup": b}];
    return YES;
}

- (NSString *)undoAll {
    int ok = 0, bad = 0;
    for (NSDictionary *e in _journal.reverseObjectEnumerator) {
        NSString *op = e[@"op"], *p = e[@"path"];
        BOOL r = NO;
        if ([op isEqualToString:@"created"]) r = ![FM() fileExistsAtPath:p] || [FM() removeItemAtPath:p error:nil];
        else if ([op isEqualToString:@"modified"]) {
            [FM() removeItemAtPath:p error:nil];
            [FM() createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            r = [FM() copyItemAtPath:e[@"backup"] toPath:p error:nil];
        } else if ([op isEqualToString:@"deleted"]) {
            [FM() removeItemAtPath:p error:nil];
            [FM() createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            r = [FM() moveItemAtPath:e[@"backup"] toPath:p error:nil];
        } else if ([op isEqualToString:@"moved"]) {
            [FM() createDirectoryAtPath:[e[@"from"] stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
            r = [FM() moveItemAtPath:e[@"to"] toPath:e[@"from"] error:nil];
        }
        if (r) ok++; else bad++;
    }
    [_journal removeAllObjects];
    return bad ? [NSString stringWithFormat:GXL(@"Отменено действий: %d, не удалось: %d"), ok, bad]
               : [NSString stringWithFormat:GXL(@"Отменено действий: %d"), ok];
}

#pragma mark текст и plist

static BOOL GXIsBPlist(NSData *d) { return d.length >= 8 && !memcmp(d.bytes, "bplist", 6); }

// содержимое файла как текст (nil — двоичный); bplist → XML
- (nullable NSString *)textOf:(NSString *)full bplist:(BOOL *)bp err:(NSString **)err {
    *bp = NO;
    NSDictionary *at = [FM() attributesOfItemAtPath:full error:nil];
    if ([at.fileType isEqualToString:NSFileTypeDirectory]) { *err = @"Error: this is a folder, use list_dir."; return nil; }
    if (at.fileSize > 20 * 1024 * 1024) { *err = [NSString stringWithFormat:@"Error: file is too large (%@) to read as text.", GXHuman(at.fileSize)]; return nil; }
    NSData *d = [NSData dataWithContentsOfFile:full];
    if (!d) { *err = @"Error: cannot read the file (no access)."; return nil; }
    if (GXIsBPlist(d)) {
        id pl = [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListImmutable format:NULL error:nil];
        NSData *x = pl ? [NSPropertyListSerialization dataWithPropertyList:pl format:NSPropertyListXMLFormat_v1_0 options:0 error:nil] : nil;
        if (x) { *bp = YES; return [[NSString alloc] initWithData:x encoding:NSUTF8StringEncoding]; }
    }
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s && d.length >= 2) {
        const uint8_t *b = d.bytes;
        if ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF)) s = [[NSString alloc] initWithData:d encoding:NSUTF16StringEncoding];
    }
    if (!s) {
        BOOL nul = memchr(d.bytes, 0, MIN(d.length, (NSUInteger)8192)) != NULL;
        if (!nul) s = [[NSString alloc] initWithData:d encoding:NSWindowsCP1251StringEncoding];
    }
    if (!s) {
        *err = [NSString stringWithFormat:@"Binary file (%@), not editable as text. First bytes: %@", GXHuman(d.length), GXHexString(d, 256)];
        return nil;
    }
    return s;
}
// текст → байты для записи; если исходный был bplist — снова двоичный plist (с проверкой XML)
- (nullable NSData *)encode:(NSString *)s bplist:(BOOL)bp err:(NSString **)err {
    NSData *out = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!bp) return out;
    NSError *pe = nil;
    id pl = [NSPropertyListSerialization propertyListWithData:out options:NSPropertyListImmutable format:NULL error:&pe];
    if (!pl) { *err = [NSString stringWithFormat:@"Error: the new plist XML is invalid: %@", pe.localizedDescription]; return nil; }
    out = [NSPropertyListSerialization dataWithPropertyList:pl format:NSPropertyListBinaryFormat_v1_0 options:0 error:&pe];
    if (!out) *err = [NSString stringWithFormat:@"Error: %@", pe.localizedDescription];
    return out;
}
- (nullable NSString *)writeData:(NSData *)d to:(NSString *)full {
    NSError *we = nil;
    return [d writeToFile:full options:NSDataWritingAtomic error:&we] ? nil : [NSString stringWithFormat:@"Error: cannot write: %@", we.localizedDescription];
}

NSString *GXCut(NSString *s, NSUInteger n) { return s.length > n ? [[s substringToIndex:n] stringByAppendingString:@"…"] : s; }
static NSUInteger GXCount(NSString *hay, NSString *needle) {
    if (!needle.length) return 0;
    NSUInteger n = 0; NSRange r = NSMakeRange(0, hay.length);
    while (YES) { NSRange f = [hay rangeOfString:needle options:NSLiteralSearch range:r]; if (f.location == NSNotFound) break; n++; r = NSMakeRange(NSMaxRange(f), hay.length - NSMaxRange(f)); }
    return n;
}

#pragma mark описание для подтверждения

- (NSString *)describe:(NSString *)n args:(NSDictionary *)a {
    NSString *(^S)(NSString *) = ^NSString *(NSString *k) { return [a[k] isKindOfClass:NSString.class] ? a[k] : @""; };
    if ([n isEqualToString:@"write_file"]) {
        NSString *e = nil, *full = [self abs:a[@"path"] err:&e];
        BOOL exists = full && [FM() fileExistsAtPath:full];
        return [NSString stringWithFormat:@"%@ «%@»%@\n\n%@", exists ? GXL(@"Перезаписать файл") : GXL(@"Создать файл"), S(@"path"),
                exists ? GXL(@" (старая версия сохранится в резервной копии)") : @"", GXCut(S(@"content"), 500)];
    }
    if ([n isEqualToString:@"edit_file"])
        return [NSString stringWithFormat:@"%@ «%@»\n\n− %@\n\n+ %@", GXL(@"Изменить файл"), S(@"path"), GXCut(S(@"old_text"), 300), GXCut(S(@"new_text"), 300)];
    if ([n isEqualToString:@"make_dir"]) return [NSString stringWithFormat:@"%@ «%@»", GXL(@"Создать папку"), S(@"path")];
    if ([n isEqualToString:@"move"]) return [NSString stringWithFormat:@"%@\n«%@» → «%@»", GXL(@"Переместить / переименовать"), S(@"from"), S(@"to")];
    if ([n isEqualToString:@"copy"]) return [NSString stringWithFormat:@"%@\n«%@» → «%@»", GXL(@"Копировать"), S(@"from"), S(@"to")];
    if ([n isEqualToString:@"delete"]) return [NSString stringWithFormat:@"%@ «%@»\n%@", GXL(@"Удалить"), S(@"path"), GXL(@"(уйдёт в резервную копию — можно отменить)")];
    return n;
}

#pragma mark выполнение

- (NSString *)run:(NSString *)n args:(NSDictionary *)a isError:(BOOL *)isErr summary:(NSString **)sum {
    *isErr = NO; *sum = nil;
    if (![a isKindOfClass:NSDictionary.class]) a = @{};
    NSString *err = nil;
    NSString *res = [self run2:n args:a err:&err summary:sum];
    if (err) { *isErr = YES; if (!*sum) *sum = [NSString stringWithFormat:GXL(@"Ошибка: %@"), GXCut(err, 120)]; return err; }
    return res ?: @"OK";
}

- (void)listDir:(NSString *)dir lvl:(int)lvl depth:(int)depth out:(NSMutableString *)out lines:(int *)lines cut:(BOOL *)cut {
    NSArray *names = [[FM() contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    for (NSString *nm in names) {
        if (*lines >= 500) { *cut = YES; return; }
        NSString *p = [dir stringByAppendingPathComponent:nm];
        if ([self hidden:p]) continue;
        BOOL d = GXIsDir(p);
        NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)(lvl * 2) withString:@" " startingAtIndex:0];
        if (d) [out appendFormat:@"%@%@/\n", ind, nm];
        else [out appendFormat:@"%@%@  (%@)\n", ind, nm, GXHuman([[FM() attributesOfItemAtPath:p error:nil] fileSize])];
        (*lines)++;
        if (d && lvl + 1 < depth) [self listDir:p lvl:lvl + 1 depth:depth out:out lines:lines cut:cut];
    }
}

- (nullable NSString *)run2:(NSString *)n args:(NSDictionary *)a err:(NSString **)err summary:(NSString **)sum {
    NSFileManager *fm = FM();
    if ([n isEqualToString:@"list_dir"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        if (!GXIsDir(full)) { *err = @"Error: not a folder."; return nil; }
        int depth = [a[@"depth"] respondsToSelector:@selector(intValue)] ? [a[@"depth"] intValue] : 1;
        depth = MAX(1, MIN(depth, 4));
        NSMutableString *out = [NSMutableString string];
        int lines = 0; BOOL cut = NO;
        [self listDir:full lvl:0 depth:depth out:out lines:&lines cut:&cut];
        *sum = [NSString stringWithFormat:GXL(@"Просмотрел папку «%@»"), [self rel:full]];
        if (!lines) return @"(empty folder)";
        if (cut) [out appendString:@"… (truncated at 500 entries; list a subfolder)\n"];
        return out;
    }
    if ([n isEqualToString:@"read_file"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        if (![fm fileExistsAtPath:full]) { *err = @"Error: file not found."; return nil; }
        BOOL bp; NSString *t = [self textOf:full bplist:&bp err:err];
        *sum = [NSString stringWithFormat:GXL(@"Прочитал «%@»"), [self rel:full]];
        if (!t) { if ([*err hasPrefix:@"Binary"]) { NSString *r = *err; *err = nil; return r; } return nil; }
        NSArray *L = [t componentsSeparatedByString:@"\n"];
        NSInteger start = [a[@"start_line"] respondsToSelector:@selector(integerValue)] ? MAX(1, [a[@"start_line"] integerValue]) : 1;
        NSInteger maxl = [a[@"max_lines"] respondsToSelector:@selector(integerValue)] ? MAX(1, [a[@"max_lines"] integerValue]) : 2000;
        NSInteger from = MIN(start - 1, (NSInteger)L.count), to = MIN(from + maxl, (NSInteger)L.count);
        NSMutableString *body = [NSMutableString string];
        NSInteger i = from;
        for (; i < to; i++) { if (body.length > 60000) break; [body appendString:L[i]]; if (i + 1 < (NSInteger)L.count) [body appendString:@"\n"]; }
        NSMutableString *out = [NSMutableString stringWithFormat:@"[%@: lines %ld-%ld of %lu%@]\n", [self rel:full], (long)from + 1, (long)i, (unsigned long)L.count,
                                bp ? @"; binary plist shown as XML, will be saved back as binary" : @""];
        [out appendString:body];
        if (i < (NSInteger)L.count) [out appendFormat:@"\n[… more lines follow; use start_line=%ld]", (long)i + 1];
        return out;
    }
    if ([n isEqualToString:@"write_file"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        if ([full isEqualToString:_root] || GXIsDir(full)) { *err = @"Error: path is a folder."; return nil; }
        NSString *content = [a[@"content"] isKindOfClass:NSString.class] ? a[@"content"] : nil;
        if (!content) { *err = @"Error: 'content' is required."; return nil; }
        BOOL exists = [fm fileExistsAtPath:full], bp = NO;
        if (exists) { NSData *h = [NSData dataWithContentsOfFile:full options:NSDataReadingMappedIfSafe error:nil]; bp = GXIsBPlist(h); }
        NSData *data = [self encode:content bplist:bp err:err]; if (!data) return nil;
        if (exists) { if (![self backupCopy:full]) { *err = @"Error: cannot back up the original file (no access?)."; return nil; } }
        else [self ensureParent:full];
        NSString *we = [self writeData:data to:full];
        if (we) { *err = we; return nil; }
        if (!exists) [_journal addObject:@{@"op": @"created", @"path": full}];
        *sum = [NSString stringWithFormat:exists ? GXL(@"Перезаписал «%@»") : GXL(@"Создал «%@»"), [self rel:full]];
        return [NSString stringWithFormat:@"OK: %@ %@ (%lu chars)", exists ? @"overwrote" : @"created", [self rel:full], (unsigned long)content.length];
    }
    if ([n isEqualToString:@"edit_file"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        if (![fm fileExistsAtPath:full]) { *err = @"Error: file not found."; return nil; }
        NSString *old = [a[@"old_text"] isKindOfClass:NSString.class] ? a[@"old_text"] : @"";
        NSString *nw = [a[@"new_text"] isKindOfClass:NSString.class] ? a[@"new_text"] : @"";
        if (!old.length) { *err = @"Error: old_text is empty. Use write_file to replace the whole file."; return nil; }
        BOOL bp; NSString *t = [self textOf:full bplist:&bp err:err]; if (!t) return nil;
        NSUInteger cnt = GXCount(t, old);
        if (!cnt) {
            NSString *ws = [old stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            *err = (ws.length && GXCount(t, ws)) ? @"Error: old_text not found exactly (whitespace/indentation differs). Read the file again and copy the fragment exactly."
                                                 : @"Error: old_text not found in the file. Read the file first.";
            return nil;
        }
        BOOL all = [a[@"replace_all"] respondsToSelector:@selector(boolValue)] && [a[@"replace_all"] boolValue];
        if (cnt > 1 && !all) { *err = [NSString stringWithFormat:@"Error: old_text occurs %lu times. Add surrounding text to make it unique, or set replace_all=true.", (unsigned long)cnt]; return nil; }
        NSString *r = all ? [t stringByReplacingOccurrencesOfString:old withString:nw]
                          : [t stringByReplacingCharactersInRange:[t rangeOfString:old options:NSLiteralSearch] withString:nw];
        NSData *data = [self encode:r bplist:bp err:err]; if (!data) return nil;
        if (![self backupCopy:full]) { *err = @"Error: cannot back up the original file (no access?)."; return nil; }
        NSString *we = [self writeData:data to:full];
        if (we) { *err = we; return nil; }
        *sum = [NSString stringWithFormat:GXL(@"Изменил «%@»"), [self rel:full]];
        return [NSString stringWithFormat:@"OK: replaced %lu occurrence(s) in %@", (unsigned long)(all ? cnt : 1), [self rel:full]];
    }
    if ([n isEqualToString:@"make_dir"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        if ([fm fileExistsAtPath:full]) { *sum = [NSString stringWithFormat:GXL(@"Папка «%@» уже есть"), [self rel:full]]; return @"OK: already exists"; }
        NSString *top = full;
        for (NSString *x = full.stringByDeletingLastPathComponent; x.length > _root.length && ![fm fileExistsAtPath:x]; x = x.stringByDeletingLastPathComponent) top = x;
        NSError *e = nil;
        if (![fm createDirectoryAtPath:full withIntermediateDirectories:YES attributes:nil error:&e]) { *err = [NSString stringWithFormat:@"Error: %@", e.localizedDescription]; return nil; }
        [_journal addObject:@{@"op": @"created", @"path": top}];
        *sum = [NSString stringWithFormat:GXL(@"Создал папку «%@»"), [self rel:full]];
        return @"OK";
    }
    if ([n isEqualToString:@"move"] || [n isEqualToString:@"copy"]) {
        BOOL mv = [n isEqualToString:@"move"];
        NSString *from = [self abs:a[@"from"] err:err]; if (!from) return nil;
        NSString *to = [self abs:a[@"to"] err:err]; if (!to) return nil;
        if ([from isEqualToString:_root]) { *err = @"Error: cannot move/copy the working folder itself."; return nil; }
        if (![fm fileExistsAtPath:from]) { *err = @"Error: source not found."; return nil; }
        if (GXIsDir(to)) to = [to stringByAppendingPathComponent:from.lastPathComponent];
        if ([to isEqualToString:from]) { *err = @"Error: source and destination are the same."; return nil; }
        if ([to hasPrefix:[from stringByAppendingString:@"/"]]) { *err = @"Error: cannot put a folder inside itself."; return nil; }
        if ([fm fileExistsAtPath:to] && ![self backupMove:to]) { *err = @"Error: cannot replace the existing destination."; return nil; }
        [self ensureParent:to];
        NSError *e = nil;
        BOOL ok = mv ? [fm moveItemAtPath:from toPath:to error:&e] : [fm copyItemAtPath:from toPath:to error:&e];
        if (!ok) { *err = [NSString stringWithFormat:@"Error: %@", e.localizedDescription]; return nil; }
        if (mv) [_journal addObject:@{@"op": @"moved", @"from": from, @"to": to, @"path": to}];
        else [_journal addObject:@{@"op": @"created", @"path": to}];
        *sum = [NSString stringWithFormat:mv ? GXL(@"Переместил «%@» → «%@»") : GXL(@"Скопировал «%@» → «%@»"), [self rel:from], [self rel:to]];
        return [NSString stringWithFormat:@"OK: %@ -> %@", [self rel:from], [self rel:to]];
    }
    if ([n isEqualToString:@"delete"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        if ([full isEqualToString:_root]) { *err = @"Error: cannot delete the working folder itself."; return nil; }
        if (![fm fileExistsAtPath:full]) { *err = @"Error: not found."; return nil; }
        if (![self backupMove:full]) { *err = @"Error: cannot delete (no access?)."; return nil; }
        *sum = [NSString stringWithFormat:GXL(@"Удалил «%@»"), [self rel:full]];
        return @"OK: deleted (kept in backup)";
    }
    if ([n isEqualToString:@"search"]) {
        NSString *q = [a[@"query"] isKindOfClass:NSString.class] ? a[@"query"] : @"";
        if (!q.length) { *err = @"Error: empty query."; return nil; }
        NSString *base = [self abs:a[@"path"] err:err]; if (!base) return nil;
        BOOL inContent = ![a[@"in_content"] respondsToSelector:@selector(boolValue)] || [a[@"in_content"] boolValue];
        NSMutableString *out = [NSMutableString string];
        __block int hits = 0; int files = 0; NSDate *t0 = NSDate.date;
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:base];
        for (NSString *relp in en) {
            if (hits >= 200 || files > 30000 || -[t0 timeIntervalSinceNow] > 25) { [out appendString:@"… (stopped: limit reached, narrow the path)\n"]; break; }
            NSString *p = [base stringByAppendingPathComponent:relp];
            if ([self hidden:p]) { [en skipDescendants]; continue; }
            files++;
            if ([relp.lastPathComponent rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) { [out appendFormat:@"name: %@\n", [self rel:p]]; hits++; }
            if (!inContent || [en.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) continue;
            if (en.fileAttributes.fileSize > 2 * 1024 * 1024) continue;
            NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil];
            if (!d.length || memchr(d.bytes, 0, MIN(d.length, (NSUInteger)4096))) continue;
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (!s || [s rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            __block int ln = 0;
            [s enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                ln++;
                if ([line rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    NSString *tl = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    [out appendFormat:@"%@:%d: %@\n", [self rel:p], ln, GXCut(tl, 200)];
                    if (++hits >= 200) *stop = YES;
                }
            }];
        }
        *sum = [NSString stringWithFormat:GXL(@"Искал «%@»"), GXCut(q, 40)];
        return out.length ? out : @"No matches.";
    }
    if ([n isEqualToString:@"file_info"]) {
        NSString *full = [self abs:a[@"path"] err:err]; if (!full) return nil;
        NSDictionary *at = [fm attributesOfItemAtPath:full error:nil];
        if (!at) { *err = @"Error: not found."; return nil; }
        *sum = [NSString stringWithFormat:GXL(@"Свойства «%@»"), [self rel:full]];
        BOOL d = [at.fileType isEqualToString:NSFileTypeDirectory];
        return [NSString stringWithFormat:@"%@: %@, size %@, modified %@, created %@, permissions %lo%@", [self rel:full], d ? @"folder" : @"file",
                GXHuman(at.fileSize), at.fileModificationDate, at.fileCreationDate, (unsigned long)at.filePosixPermissions,
                d ? [NSString stringWithFormat:@", %lu items", (unsigned long)[fm contentsOfDirectoryAtPath:full error:nil].count] : @""];
    }
    *err = [NSString stringWithFormat:@"Error: unknown tool '%@'.", n];
    return nil;
}
@end


#pragma mark - Сохранённые чаты

@implementation GXAISessions
+ (NSString *)dir {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/GXAIChats"];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
+ (dispatch_queue_t)queue { static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{ q = dispatch_queue_create("gx.ai.sessions", DISPATCH_QUEUE_SERIAL); }); return q; }
+ (NSString *)fileFor:(NSString *)sid { return [[self dir] stringByAppendingPathComponent:[sid stringByAppendingPathExtension:@"json"]]; }
+ (BOOL)validId:(NSString *)sid { return [sid isKindOfClass:NSString.class] && sid.length && sid.length < 80 && ![sid containsString:@"/"] && ![sid hasPrefix:@"."]; }
+ (nullable id)readJSON:(NSString *)path {
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
}
+ (BOOL)writeJSON:(id)obj to:(NSString *)path {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return d && [d writeToFile:path options:NSDataWritingAtomic error:nil];
}
+ (NSDictionary *)metaOf:(NSDictionary *)c {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    for (NSString *k in @[@"id", @"title", @"root", @"home", @"created", @"updated", @"model"]) if (c[k]) m[k] = c[k];
    NSUInteger n = 0;
    for (NSDictionary *t in c[@"turns"]) if ([t isKindOfClass:NSDictionary.class] && [t[@"role"] isEqual:@"user"]) n++;
    m[@"messages"] = @(n);
    return m;
}
// индекс: краткие сведения обо всех чатах, чтобы список открывался быстро
+ (NSMutableArray *)indexLocked {
    NSString *ip = [[self dir] stringByAppendingPathComponent:@"index.json"];
    NSArray *idx = [self readJSON:ip];
    if ([idx isKindOfClass:NSArray.class]) return [idx mutableCopy];
    NSMutableArray *a = [NSMutableArray array];   // нет индекса — собрать по файлам
    for (NSString *f in [FM() contentsOfDirectoryAtPath:[self dir] error:nil]) {
        if (![f.pathExtension isEqualToString:@"json"] || [f isEqualToString:@"index.json"]) continue;
        NSDictionary *c = [self readJSON:[[self dir] stringByAppendingPathComponent:f]];
        if ([c isKindOfClass:NSDictionary.class] && [self validId:c[@"id"]]) [a addObject:[self metaOf:c]];
    }
    [self writeJSON:a to:ip];
    return a;
}
+ (void)saveIndexLocked:(NSArray *)a { [self writeJSON:a to:[[self dir] stringByAppendingPathComponent:@"index.json"]]; }

+ (NSArray<NSDictionary *> *)list {
    __block NSArray *r;
    dispatch_sync([self queue], ^{ r = [self indexLocked]; });
    return [r sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([b[@"updated"] doubleValue]) compare:@([a[@"updated"] doubleValue])];
    }];
}
+ (nullable NSDictionary *)load:(NSString *)sid {
    if (![self validId:sid]) return nil;
    __block NSDictionary *c;
    dispatch_sync([self queue], ^{ c = [self readJSON:[self fileFor:sid]]; });
    if (![c isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *m = [c mutableCopy];
    m[@"root"] = [self currentPath:c[@"root"] home:c[@"home"]];
    m[@"turns"] = [self sanitize:[c[@"turns"] isKindOfClass:NSArray.class] ? c[@"turns"] : @[]];
    return m;
}
// путь из старого контейнера (после обновления приложения iOS может сменить папку приложения)
+ (NSString *)currentPath:(NSString *)p home:(NSString *)oldHome {
    if (![p isKindOfClass:NSString.class]) return @"";
    if ([FM() fileExistsAtPath:p] || ![oldHome isKindOfClass:NSString.class] || !oldHome.length) return p;
    if ([p isEqualToString:oldHome] || [p hasPrefix:[oldHome stringByAppendingString:@"/"]]) {
        NSString *np = [NSHomeDirectory() stringByAppendingString:[p substringFromIndex:oldHome.length]];
        if ([FM() fileExistsAtPath:np]) return np;
    }
    return p;
}
// незавершённый шаг (вызов инструмента без результата) закрываем, чтобы модель приняла историю
+ (NSArray *)sanitize:(NSArray *)turns {
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < turns.count; i++) {
        NSDictionary *t = turns[i];
        if (![t isKindOfClass:NSDictionary.class] || ![t[@"role"] isKindOfClass:NSString.class]) continue;
        [out addObject:t];
        NSArray *calls = t[@"calls"];
        BOOL needResults = [t[@"role"] isEqual:@"assistant"] && [calls isKindOfClass:NSArray.class] && calls.count;
        BOOL hasNext = i + 1 < turns.count && [turns[i + 1] isKindOfClass:NSDictionary.class] && [turns[i + 1][@"role"] isEqual:@"tool"];
        if (needResults && !hasNext) {
            NSMutableArray *res = [NSMutableArray array];
            for (NSDictionary *c in calls) if ([c isKindOfClass:NSDictionary.class])
                [res addObject:@{@"id": c[@"id"] ?: @"?", @"name": c[@"name"] ?: @"?", @"content": @"Interrupted: the chat was closed before this action ran.", @"error": @YES}];
            [out addObject:@{@"role": @"tool", @"results": res}];
        }
    }
    return out;
}
+ (void)save:(NSDictionary *)chat {
    if (![self validId:chat[@"id"]]) return;
    NSMutableDictionary *c = [chat mutableCopy];
    c[@"home"] = NSHomeDirectory();
    c[@"updated"] = @(NSDate.date.timeIntervalSince1970);
    if (!c[@"created"]) c[@"created"] = c[@"updated"];
    dispatch_async([self queue], ^{
        if (![self writeJSON:c to:[self fileFor:c[@"id"]]]) return;
        NSMutableArray *idx = [self indexLocked];
        NSUInteger i = [idx indexOfObjectPassingTest:^BOOL(NSDictionary *x, NSUInteger n, BOOL *s) { return [x[@"id"] isEqual:c[@"id"]]; }];
        NSDictionary *m = [self metaOf:c];
        if (i == NSNotFound) [idx addObject:m]; else idx[i] = m;
        [self saveIndexLocked:idx];
    });
}
+ (void)flush { dispatch_sync([self queue], ^{}); }
+ (void)rename:(NSString *)sid title:(NSString *)title {
    if (![self validId:sid]) return;
    dispatch_sync([self queue], ^{
        NSMutableDictionary *c = [[self readJSON:[self fileFor:sid]] mutableCopy];
        if (![c isKindOfClass:NSDictionary.class]) return;
        c[@"title"] = title;
        [self writeJSON:c to:[self fileFor:sid]];
        NSMutableArray *idx = [self indexLocked];
        for (NSUInteger i = 0; i < idx.count; i++) if ([idx[i][@"id"] isEqual:sid]) { NSMutableDictionary *m = [idx[i] mutableCopy]; m[@"title"] = title; idx[i] = m; }
        [self saveIndexLocked:idx];
    });
}
+ (void)remove:(NSString *)sid {
    if (![self validId:sid]) return;
    dispatch_sync([self queue], ^{
        NSDictionary *c = [self readJSON:[self fileFor:sid]];
        NSString *b = [c isKindOfClass:NSDictionary.class] && [c[@"tools"] isKindOfClass:NSDictionary.class] ? c[@"tools"][@"backup"] : nil;
        if ([b isKindOfClass:NSString.class] && b.length && ![b containsString:@"/"] && ![b hasPrefix:@"."])   // резервные копии этого чата
            [FM() removeItemAtPath:[GXAIBackupRoot() stringByAppendingPathComponent:b] error:nil];
        [FM() removeItemAtPath:[self fileFor:sid] error:nil];
        NSMutableArray *idx = [self indexLocked];
        [idx filterUsingPredicate:[NSPredicate predicateWithFormat:@"id != %@", sid]];
        [self saveIndexLocked:idx];
    });
}
// резервные копии удалены — журналы отмены в чатах больше не действительны
+ (void)forgetUndo {
    dispatch_sync([self queue], ^{
        for (NSDictionary *m in [self indexLocked]) {
            NSString *f = [self fileFor:m[@"id"]];
            NSMutableDictionary *c = [[self readJSON:f] mutableCopy];
            if (![c isKindOfClass:NSDictionary.class] || ![c[@"tools"] isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *t = [c[@"tools"] mutableCopy]; t[@"journal"] = @[];
            c[@"tools"] = t;
            [self writeJSON:c to:f];
        }
    });
}
@end

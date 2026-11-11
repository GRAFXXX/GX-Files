// Многоязычный запуск кода.
//   • C (твики) — TinyCC → dylib (GXCompiler.m)
//   • JavaScript — встроенный в iOS JavaScriptCore, без интернета
//   • Lua 5.4 — встроенный интерпретатор (src/core/gx_lua.c), без интернета
//   • C++, C#, Rust, Go, Java, Kotlin, Python, Swift и др. — компиляция и запуск на
//     сервере Compiler Explorer (godbolt.org): нативные компиляторы этих языков на iOS
//     не помещаются, а запускать сгенерированный код без JIT iOS не даёт.
#import "GXCore.h"
#import "core/gx_lua.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <dlfcn.h>

static NSString *const kCEBase = @"https://godbolt.org";
static const double kRunTimeout = 10;   // секунд для JS/Lua на устройстве

#pragma mark - Языки

// kind: 0 — TinyCC (C → dylib), 1 — JavaScript, 2 — Lua, 3 — онлайн (Compiler Explorer)
static NSDictionary *L(NSString *lid, NSString *name, NSArray *ext, int kind, NSString *pref, NSString *tpl) {
    return @{@"id": lid, @"name": name, @"ext": ext, @"kind": @(kind), @"pref": pref ?: @"", @"tpl": tpl};
}

NSArray<NSDictionary *> *GXCodeLanguages(void) {
    static NSArray *a; static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[
        L(@"tcc", GXL(@"C (твик → dylib)"), @[@"c", @"h"], 0, nil, @""),
        L(@"js", @"JavaScript", @[@"js", @"mjs"], 1, nil,
          @"// JavaScript — {{NOTE_OFFLINE}}\n"
           "const name = readline() || \"{{WORLD}}\";   // {{NOTE_STDIN}}\n"
           "console.log(`{{HELLO}}, ${name}!`);\n\n"
           "const nums = [3, 1, 4, 1, 5, 9, 2, 6];\n"
           "console.log(\"{{NOTE_SORT}}\", nums.sort((a, b) => a - b));\n"),
        L(@"lua", @"Lua", @[@"lua"], 2, nil,
          @"-- Lua 5.4 — {{NOTE_OFFLINE}}\n"
           "local name = io.read() or \"{{WORLD}}\"   -- {{NOTE_STDIN}}\n"
           "print(\"{{HELLO}}, \" .. name .. \"!\")\n\n"
           "for i = 1, 5 do\n  io.write(i * i, \" \")\nend\nprint()\n"),
        L(@"c++", @"C++", @[@"cpp", @"cc", @"cxx", @"hpp", @"hh"], 3, @"x86-64 gcc",
          @"#include <iostream>\n#include <string>\n\nint main() {\n    std::string name;\n    if (!std::getline(std::cin, name) || name.empty()) name = \"{{WORLD}}\";\n    std::cout << \"{{HELLO}}, \" << name << \"!\" << std::endl;\n    return 0;\n}\n"),
        L(@"csharp", @"C#", @[@"cs"], 3, @"\\.NET",
          @"using System;\n\nclass Program {\n    static void Main() {\n        string name = Console.ReadLine();\n        if (string.IsNullOrEmpty(name)) name = \"{{WORLD}}\";\n        Console.WriteLine($\"{{HELLO}}, {name}!\");\n    }\n}\n"),
        L(@"python", @"Python", @[@"py"], 3, @"Python",
          @"import sys\n\nname = sys.stdin.readline().strip() or \"{{WORLD}}\"\nprint(f\"{{HELLO}}, {name}!\")\nprint([x * x for x in range(1, 6)])\n"),
        L(@"java", @"Java", @[@"java"], 3, @"jdk",
          @"import java.util.Scanner;\n\nclass Main {\n    public static void main(String[] args) {\n        Scanner in = new Scanner(System.in);\n        String name = in.hasNextLine() ? in.nextLine() : \"{{WORLD}}\";\n        System.out.println(\"{{HELLO}}, \" + name + \"!\");\n    }\n}\n"),
        L(@"kotlin", @"Kotlin", @[@"kt"], 3, @"kotlinc",
          @"fun main() {\n    val name = readLine()?.ifBlank { null } ?: \"{{WORLD}}\"\n    println(\"{{HELLO}}, $name!\")\n}\n"),
        L(@"rust", @"Rust", @[@"rs"], 3, @"rustc",
          @"use std::io::{self, BufRead};\n\nfn main() {\n    let mut name = String::new();\n    io::stdin().lock().read_line(&mut name).ok();\n    let name = if name.trim().is_empty() { \"{{WORLD}}\" } else { name.trim() };\n    println!(\"{{HELLO}}, {}!\", name);\n}\n"),
        L(@"go", @"Go", @[@"go"], 3, @"x86-64 gc",
          @"package main\n\nimport (\n\t\"bufio\"\n\t\"fmt\"\n\t\"os\"\n\t\"strings\"\n)\n\nfunc main() {\n\tname, _ := bufio.NewReader(os.Stdin).ReadString('\\n')\n\tname = strings.TrimSpace(name)\n\tif name == \"\" {\n\t\tname = \"{{WORLD}}\"\n\t}\n\tfmt.Printf(\"{{HELLO}}, %s!\\n\", name)\n}\n"),
        L(@"swift", @"Swift", @[@"swift"], 3, @"swiftc",
          @"let name = readLine().flatMap { $0.isEmpty ? nil : $0 } ?? \"{{WORLD}}\"\nprint(\"{{HELLO}}, \\(name)!\")\n"),
        L(@"c", GXL(@"C (программа, онлайн gcc)"), @[@"c", @"h"], 3, @"x86-64 gcc",
          @"#include <stdio.h>\n\nint main(void) {\n    char name[100] = \"{{WORLD}}\";\n    scanf(\"%99s\", name);\n    printf(\"{{HELLO}}, %s!\\n\", name);\n    return 0;\n}\n"),
        L(@"typescript", @"TypeScript", @[@"ts"], 1, nil,
          @"// TypeScript — {{NOTE_TS}}\n"
           "function greet(name: string): string {\n    return `{{HELLO}}, ${name}!`;\n}\nconsole.log(greet(readline() || \"{{WORLD}}\"));\n"),
        L(@"ruby", @"Ruby", @[@"rb"], 3, @"Ruby",
          @"name = gets&.strip\nname = \"{{WORLD}}\" if name.nil? || name.empty?\nputs \"{{HELLO}}, #{name}!\"\n"),
        L(@"dart", @"Dart", @[@"dart"], 3, @"Dart",
          @"import 'dart:io';\n\nvoid main() {\n  var name = stdin.readLineSync() ?? '';\n  if (name.isEmpty) name = '{{WORLD}}';\n  print('{{HELLO}}, $name!');\n}\n"),
        L(@"haskell", @"Haskell", @[@"hs"], 3, @"ghc",
          @"main :: IO ()\nmain = do\n  putStrLn \"{{HELLO}}, {{WORLD}}!\"\n  print (sum [1..10])\n"),
        L(@"pascal", @"Pascal", @[@"pas", @"pp"], 3, @"fpc",
          @"program Hello;\nvar\n  name: string;\nbegin\n  readln(name);\n  if name = '' then name := '{{WORLD}}';\n  writeln('{{HELLO}}, ', name, '!');\nend.\n"),
        L(@"fsharp", @"F#", @[@"fs"], 3, @"\\.NET", @"printfn \"{{HELLO}}, {{WORLD}}!\"\n"),
        L(@"vb", @"Visual Basic", @[@"vb"], 3, @"\\.NET",
          @"Module Program\n    Sub Main()\n        System.Console.WriteLine(\"{{HELLO}}, {{WORLD}}!\")\n    End Sub\nEnd Module\n"),
        L(@"d", @"D", @[@"d"], 3, @"ldc", @"import std.stdio;\n\nvoid main() {\n    writeln(\"{{HELLO}}, {{WORLD}}!\");\n}\n"),
        L(@"zig", @"Zig", @[@"zig"], 3, nil,
          @"const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"{{HELLO}}, {{WORLD}}!\\n\", .{});\n}\n"),
        L(@"julia", @"Julia", @[@"jl"], 3, nil, @"println(\"{{HELLO}}, {{WORLD}}!\")\nprintln(sum(1:10))\n"),
        L(@"perl", @"Perl", @[@"pl"], 3, nil, @"use strict;\nuse warnings;\n\nprint \"{{HELLO}}, {{WORLD}}!\\n\";\n"),
        L(@"ocaml", @"OCaml", @[@"ml"], 3, @"ocamlopt", @"let () = print_endline \"{{HELLO}}, {{WORLD}}!\"\n"),
        L(@"fortran", @"Fortran", @[@"f90", @"f95", @"f"], 3, nil, @"program hello\n  print *, \"{{HELLO}}, {{WORLD}}!\"\nend program hello\n"),
        L(@"objc", GXL(@"Objective-C (онлайн)"), @[@"m"], 3, @"x86-64 gcc",
          @"#include <stdio.h>\n\nint main(void) {\n    printf(\"{{HELLO}}, {{WORLD}}!\\n\");\n    return 0;\n}\n"),
        L(@"crystal", @"Crystal", @[@"cr"], 3, nil, @"puts \"{{HELLO}}, {{WORLD}}!\"\n"),
        L(@"cobol", @"COBOL", @[@"cob", @"cbl"], 3, nil,
          @"       IDENTIFICATION DIVISION.\n       PROGRAM-ID. HELLO.\n       PROCEDURE DIVISION.\n           DISPLAY \"{{HELLO}}, {{WORLD}}!\".\n           STOP RUN.\n"),
        L(@"ada", @"Ada", @[@"adb"], 3, @"gnat",
          @"with Ada.Text_IO;\nprocedure Example is\nbegin\n   Ada.Text_IO.Put_Line (\"{{HELLO}}, {{WORLD}}!\");\nend Example;\n"),
        L(@"odin", @"Odin", @[@"odin"], 3, nil,
          @"package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n    fmt.println(\"{{HELLO}}, {{WORLD}}!\")\n}\n"),
        L(@"mojo", @"Mojo", @[@"mojo"], 3, nil, @"def main():\n    print(\"{{HELLO}}, {{WORLD}}!\")\n"),
        L(@"raku", @"Raku", @[@"raku"], 3, nil, @"say \"{{HELLO}}, {{WORLD}}!\";\n"),
    ]; });
    return a;
}

// Текст шаблона на языке интерфейса: метки {{…}} заменяются переведёнными словами
NSString *GXCodeTemplate(NSDictionary *lang) {
    NSString *t = lang[@"tpl"] ?: @"";
    NSDictionary *m = @{@"{{HELLO}}": GXL(@"Привет"), @"{{WORLD}}": GXL(@"мир"),
                        @"{{NOTE_OFFLINE}}": GXL(@"работает прямо на iPhone, без интернета"),
                        @"{{NOTE_STDIN}}": GXL(@"строка из «Ввода» (stdin)"),
                        @"{{NOTE_SORT}}": GXL(@"Сортировка:"),
                        @"{{NOTE_TS}}": GXL(@"типы убираются, код выполняется как JavaScript прямо на iPhone")};
    for (NSString *k in m) t = [t stringByReplacingOccurrencesOfString:k withString:m[k]];
    return t;
}

NSDictionary *GXCodeLanguageForID(NSString *lid) {
    for (NSDictionary *l in GXCodeLanguages()) if ([l[@"id"] isEqualToString:lid]) return l;
    return nil;
}
// Папка языка в документах («C#», «Python»…); у C-твиков своей папки нет (GX Compiler)
NSString *_Nullable GXCodeLanguageFolder(NSDictionary *lang) {
    NSString *lid = lang[@"id"];
    if ([lid isEqualToString:@"tcc"]) return nil;
    NSDictionary *m = @{@"c": @"C", @"objc": @"Objective-C"};
    return m[lid] ?: lang[@"name"];
}
NSString *GXCodeLanguageDir(NSDictionary *lang) {
    NSString *d = [GXDocsDir() stringByAppendingPathComponent:GXCodeLanguageFolder(lang) ?: @"GX Compiler"];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
NSDictionary *GXCodeLanguageForPath(NSString *path) {
    NSString *e = path.pathExtension.lowercaseString;
    if (!e.length) return nil;
    // файл в папке языка (Documents/C/main.c) — этот язык, даже если расширение общее (.c у твиков и программ)
    NSString *parent = path.stringByDeletingLastPathComponent.lastPathComponent;
    for (NSDictionary *l in GXCodeLanguages()) {
        NSString *f = GXCodeLanguageFolder(l);
        if (f && [f isEqualToString:parent] && [l[@"ext"] containsObject:e]) return l;
    }
    for (NSDictionary *l in GXCodeLanguages()) if ([l[@"ext"] containsObject:e]) return l;
    return nil;
}
NSString *GXCodeLanguageExt(NSDictionary *lang) {
    NSArray *e = lang[@"ext"];
    return e.count ? e.firstObject : @"c";
}

#pragma mark - Оформление вывода

static UIFont *MonoFont(void) { return [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]; }
static void Append(NSMutableAttributedString *s, NSString *t, UIColor *c) {
    if (!t.length) return;
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:t attributes:@{NSFontAttributeName: MonoFont(), NSForegroundColorAttributeName: c}]];
}
static NSString *StripANSI(NSString *s) {
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"\\x1b\\[[0-9;?]*[A-Za-z]" options:0 error:nil]; });
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
}
static NSString *JoinLines(id arr) {
    if (![arr isKindOfClass:NSArray.class]) return @"";
    NSMutableString *m = [NSMutableString string];
    for (NSDictionary *x in arr) if ([x isKindOfClass:NSDictionary.class] && [x[@"text"] isKindOfClass:NSString.class]) [m appendFormat:@"%@\n", x[@"text"]];
    return StripANSI(m);
}

#pragma mark - Задача запуска (можно остановить)

@interface GXRunJob ()
@property (atomic, strong, nullable) NSURLSessionTask *task;
@end
@implementation GXRunJob { volatile int _flag; }
- (void)cancel { _flag = 1; [self.task cancel]; }
- (BOOL)cancelled { return _flag != 0; }
- (volatile int *)cancelFlag { return &_flag; }
@end

#pragma mark - Compiler Explorer

static NSURLSession *CESession(void) {
    static NSURLSession *s; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.defaultSessionConfiguration;
        c.timeoutIntervalForRequest = 90;
        NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        c.HTTPAdditionalHeaders = @{@"Accept": @"application/json", @"User-Agent": [NSString stringWithFormat:@"GXFiles/%@ (iOS)", ver]};
        s = [NSURLSession sessionWithConfiguration:c];
    });
    return s;
}
static NSString *CECachePath(NSString *ce) {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"CompilerExplorer"];
    [FM() createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return [d stringByAppendingPathComponent:[ce stringByAppendingPathExtension:@"json"]];
}
static NSArray<NSDictionary *> *CEFilterExec(NSArray *all) {
    NSMutableArray *r = [NSMutableArray array];
    for (NSDictionary *c in all) if ([c isKindOfClass:NSDictionary.class] && [c[@"supportsExecute"] boolValue] && [c[@"id"] isKindOfClass:NSString.class]) [r addObject:c];
    return r;
}
static NSArray<NSDictionary *> *CECached(NSString *ce, BOOL allowStale) {
    NSString *p = CECachePath(ce);
    NSDictionary *at = [FM() attributesOfItemAtPath:p error:nil];
    if (!at) return nil;
    if (!allowStale && -[at.fileModificationDate timeIntervalSinceNow] > 7 * 86400) return nil;
    NSArray *a = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:p] options:0 error:nil];
    return [a isKindOfClass:NSArray.class] ? CEFilterExec(a) : nil;
}
// Список компиляторов языка, умеющих запускать программу (кэш на 7 дней)
void GXCECompilers(NSString *ce, BOOL refresh, void (^done)(NSArray<NSDictionary *> *_Nullable list, NSString *_Nullable err)) {
    NSArray *cached = refresh ? nil : CECached(ce, NO);
    if (cached.count) { done(cached, nil); return; }
    NSString *u = [NSString stringWithFormat:@"%@/api/compilers/%@?fields=id,name,supportsExecute,semver,releaseTrack", kCEBase,
                   [ce stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
    [[CESession() dataTaskWithURL:[NSURL URLWithString:u] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSArray *a = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([a isKindOfClass:NSArray.class] && a.count) {
            [d writeToFile:CECachePath(ce) atomically:YES];
            done(CEFilterExec(a), nil);
            return;
        }
        NSArray *stale = CECached(ce, YES);
        if (stale.count) { done(stale, nil); return; }
        done(nil, e.localizedDescription ?: GXL(@"Compiler Explorer не ответил"));
    }] resume];
}

static NSArray<NSNumber *> *SemVer(NSDictionary *c) {
    NSString *s = [c[@"semver"] isKindOfClass:NSString.class] ? c[@"semver"] : @"";
    NSMutableArray *v = [NSMutableArray array];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\d+" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        [v addObject:@([[s substringWithRange:m.range] integerValue])];
        if (v.count == 4) break;
    }
    return v;
}
static NSComparisonResult CmpVer(NSArray *a, NSArray *b) {
    for (NSUInteger i = 0; i < MAX(a.count, b.count); i++) {
        NSInteger x = i < a.count ? [a[i] integerValue] : 0, y = i < b.count ? [b[i] integerValue] : 0;
        if (x != y) return x < y ? NSOrderedAscending : NSOrderedDescending;
    }
    return NSOrderedSame;
}
// Лучший стабильный x86-64 компилятор языка (не trunk/nightly/assertions), с самой свежей версией
NSDictionary *GXCEAutoCompiler(NSArray<NSDictionary *> *list, NSString *pref) {
    static NSRegularExpression *bad; static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [NSRegularExpression regularExpressionWithPattern:@"trunk|nightly|assert|latest|\\bdev\\b|\\bCI\\b|\\bpre|rc\\d|snapshot|beta|alpha|experimental|\\(No GC\\)|JIT|arm|aarch64|risc|mips|power|s390|wasm|ellcc|cl430|avr|msp"
                                                    options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableArray *good = [NSMutableArray array];
    for (NSDictionary *c in list) {
        NSString *n = c[@"name"] ?: @"", *rt = [c[@"releaseTrack"] isKindOfClass:NSString.class] ? c[@"releaseTrack"] : nil;
        if (rt && ![rt isEqualToString:@"stable"]) continue;
        if ([bad firstMatchInString:n options:0 range:NSMakeRange(0, n.length)]) continue;
        [good addObject:c];
    }
    if (pref.length) {
        NSRegularExpression *pr = [NSRegularExpression regularExpressionWithPattern:pref options:NSRegularExpressionCaseInsensitive error:nil];
        NSMutableArray *p = [NSMutableArray array];
        for (NSDictionary *c in good) { NSString *n = c[@"name"] ?: @""; if ([pr firstMatchInString:n options:0 range:NSMakeRange(0, n.length)]) [p addObject:c]; }
        if (p.count) good = p;
    }
    NSArray *pool = good.count ? good : list;
    NSDictionary *best = nil;
    for (NSDictionary *c in pool) if (!best || CmpVer(SemVer(best), SemVer(c)) == NSOrderedAscending) best = c;
    return best;
}
static NSString *CEKey(NSString *ce) { return [@"ceCompiler." stringByAppendingString:ce]; }
static NSDictionary *CEResolve(NSDictionary *lang, NSArray *list) {
    NSString *want = [GXDefaults() stringForKey:CEKey(lang[@"id"])];
    if (want) for (NSDictionary *c in list) if ([c[@"id"] isEqualToString:want]) return c;
    return GXCEAutoCompiler(list, lang[@"pref"]);
}
NSString *GXCEArgs(NSString *ce) { return [GXDefaults() stringForKey:[@"ceArgs." stringByAppendingString:ce]] ?: @""; }
void GXCESetArgs(NSString *ce, NSString *args) { [GXDefaults() setObject:args ?: @"" forKey:[@"ceArgs." stringByAppendingString:ce]]; }

static void RunOnline(GXRunJob *job, NSDictionary *lang, NSString *src, NSString *stdinText,
                      void (^done)(NSAttributedString *, BOOL)) {
    NSString *ce = lang[@"id"];
    GXCECompilers(ce, NO, ^(NSArray *list, NSString *err) {
        if (job.cancelled) return;
        NSMutableAttributedString *o = [NSMutableAttributedString new];
        NSDictionary *comp = list.count ? CEResolve(lang, list) : nil;
        if (!comp) {
            Append(o, [NSString stringWithFormat:GXL(@"Нет связи с Compiler Explorer: %@\nДля C++, C#, Python и других языков нужен интернет. JavaScript и Lua работают офлайн.\n"), err ?: @"?"], UIColor.systemRedColor);
            dispatch_async(dispatch_get_main_queue(), ^{ done(o, NO); });
            return;
        }
        NSDictionary *body = @{
            @"source": src,
            @"options": @{@"userArguments": GXCEArgs(ce),
                          @"compilerOptions": @{@"executorRequest": @YES},
                          @"filters": @{@"execute": @YES},
                          @"executeParameters": @{@"args": @[], @"stdin": stdinText ?: @""},
                          @"tools": @[], @"libraries": @[]},
            @"lang": ce, @"allowStoreCodeDebug": @YES};
        NSString *u = [NSString stringWithFormat:@"%@/api/compiler/%@/compile", kCEBase,
                       [comp[@"id"] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]];
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
        rq.HTTPMethod = @"POST";
        [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        NSURLSessionDataTask *t = [CESession() dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            if (job.cancelled) return;
            NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            BOOL ok = NO;
            if (![j isKindOfClass:NSDictionary.class]) {
                NSString *raw = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
                Append(o, [NSString stringWithFormat:GXL(@"Ошибка Compiler Explorer: %@\n"), e.localizedDescription ?: (raw.length ? [raw substringToIndex:MIN(raw.length, (NSUInteger)300)] : @"?")], UIColor.systemRedColor);
            } else {
                NSDictionary *br = [j[@"buildResult"] isKindOfClass:NSDictionary.class] ? j[@"buildResult"] : @{};
                NSString *bout = [JoinLines(br[@"stdout"]) stringByAppendingString:JoinLines(br[@"stderr"])];
                if (![j[@"didExecute"] boolValue]) {
                    Append(o, GXL(@"Ошибка компиляции:\n"), UIColor.systemRedColor);
                    Append(o, bout.length ? bout : JoinLines(j[@"stderr"]), UIColor.systemRedColor);
                } else {
                    if (bout.length) Append(o, bout, UIColor.systemOrangeColor);       // предупреждения компилятора
                    Append(o, JoinLines(j[@"stdout"]), UIColor.labelColor);
                    Append(o, JoinLines(j[@"stderr"]), UIColor.systemOrangeColor);
                    long code = [j[@"code"] longValue];
                    ok = code == 0 && ![j[@"timedOut"] boolValue];
                    if ([j[@"timedOut"] boolValue]) Append(o, GXL(@"⏱ Превышено время выполнения на сервере\n"), UIColor.systemRedColor);
                    Append(o, [NSString stringWithFormat:GXL(@"— код выхода %ld · %@ мс"), code, j[@"execTime"] ?: @"?"],
                           code == 0 ? UIColor.systemGreenColor : UIColor.systemRedColor);
                    Append(o, @"\n", UIColor.labelColor);
                }
            }
            Append(o, [NSString stringWithFormat:GXL(@"%@ · Compiler Explorer (godbolt.org)\n"), comp[@"name"] ?: comp[@"id"]], UIColor.secondaryLabelColor);
            dispatch_async(dispatch_get_main_queue(), ^{ done(o, ok); });
        }];
        job.task = t;
        [t resume];
    });
}

#pragma mark - JavaScript (JavaScriptCore, офлайн)

typedef bool (*GXJSShouldTerminate)(JSContextRef, void *);
static bool GXJSTerminate(JSContextRef ctx, void *info) { return true; }

// Убрать аннотации типов TypeScript — дальше код выполняется как JavaScript.
// Осторожно: трогаем только объявления (let/const/var x: T), параметры функций и тип
// результата, чтобы не задеть объектные литералы { a: b } и тернарный оператор a ? b : c.
static NSString *const kTSType = @"[A-Za-z_$][\\w$.]*(?:<[^<>()]*>)?(?:\\[\\])*(?:\\s*\\|\\s*[A-Za-z_$'\"][\\w$.'\"]*(?:<[^<>()]*>)?(?:\\[\\])*)*";
static NSString *ReplaceEach(NSString *s, NSString *pattern, NSString *(^fn)(NSString *whole, NSArray<NSString *> *groups)) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionAnchorsMatchLines error:nil];
    if (!re) return s;
    NSMutableString *out = [NSMutableString string]; NSUInteger last = 0;
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        [out appendString:[s substringWithRange:NSMakeRange(last, m.range.location - last)]];
        NSMutableArray *g = [NSMutableArray array];
        for (NSUInteger i = 1; i < m.numberOfRanges; i++) [g addObject:[m rangeAtIndex:i].location == NSNotFound ? @"" : [s substringWithRange:[m rangeAtIndex:i]]];
        [out appendString:fn([s substringWithRange:m.range], g)];
        last = NSMaxRange(m.range);
    }
    [out appendString:[s substringFromIndex:last]];
    return out;
}
static NSString *StripParams(NSString *params) {
    NSString *p = [NSString stringWithFormat:@"(\\b[A-Za-z_$][\\w$]*)\\s*\\??\\s*:\\s*%@", kTSType];
    return ReplaceEach(params, p, ^NSString *(NSString *w, NSArray *g) { return g[0]; });
}
static NSString *StripTypeScript(NSString *s) {
    // interface / type — целиком
    s = ReplaceEach(s, @"^\\s*(?:export\\s+)?interface\\s+\\w+[^{\\n]*\\{[\\s\\S]*?^\\s*\\}\\s*$", ^NSString *(NSString *w, NSArray *g) { return @""; });
    s = ReplaceEach(s, @"^\\s*(?:export\\s+)?type\\s+\\w+(?:<[^>]*>)?\\s*=[^\\n]*$", ^NSString *(NSString *w, NSArray *g) { return @""; });
    // let/const/var x: T
    s = ReplaceEach(s, [NSString stringWithFormat:@"\\b(let|const|var)\\s+([A-Za-z_$][\\w$]*)\\s*:\\s*%@", kTSType],
                    ^NSString *(NSString *w, NSArray *g) { return [NSString stringWithFormat:@"%@ %@", g[0], g[1]]; });
    // function f<T>(a: T, b?: U): R {   и   (a: T): R =>
    s = ReplaceEach(s, [NSString stringWithFormat:@"(function\\s*\\*?\\s*[A-Za-z_$]*\\s*)(?:<[^>()]*>)?\\(([^()]*)\\)(\\s*:\\s*%@)?", kTSType],
                    ^NSString *(NSString *w, NSArray *g) { return [NSString stringWithFormat:@"%@(%@)", g[0], StripParams(g[1])]; });
    s = ReplaceEach(s, [NSString stringWithFormat:@"\\(([^()]*)\\)(\\s*:\\s*%@)?(\\s*=>)", kTSType],
                    ^NSString *(NSString *w, NSArray *g) { return [NSString stringWithFormat:@"(%@)%@", StripParams(g[0]), g[2]]; });
    // методы класса: name(a: T): R {
    s = ReplaceEach(s, [NSString stringWithFormat:@"^(\\s*(?:async\\s+|static\\s+|public\\s+|private\\s+|protected\\s+)*[A-Za-z_$][\\w$]*\\s*)\\(([^()]*)\\)(\\s*:\\s*%@)?(\\s*\\{)", kTSType],
                    ^NSString *(NSString *w, NSArray *g) {
        if ([g[0] rangeOfString:@"\\b(if|for|while|switch|catch|function|return)\\b" options:NSRegularExpressionSearch].location != NSNotFound) return w;
        return [NSString stringWithFormat:@"%@(%@)%@", g[0], StripParams(g[1]), g[3]];
    });
    // модификаторы доступа и поля класса «name: T;»
    s = ReplaceEach(s, @"\\b(?:public|private|protected|readonly)\\s+", ^NSString *(NSString *w, NSArray *g) { return @""; });
    s = ReplaceEach(s, [NSString stringWithFormat:@"^(\\s*[A-Za-z_$][\\w$]*)\\s*[?!]?\\s*:\\s*%@\\s*(;|=)", kTSType],
                    ^NSString *(NSString *w, NSArray *g) { return [g[1] isEqualToString:@"="] ? [g[0] stringByAppendingString:@" ="] : [g[0] stringByAppendingString:@";"]; });
    // x as T, x!
    s = ReplaceEach(s, [NSString stringWithFormat:@"\\s+as\\s+%@", kTSType], ^NSString *(NSString *w, NSArray *g) { return @""; });
    return s;
}

static void RunJS(GXRunJob *job, NSString *src, NSString *stdinText, BOOL typescript, void (^done)(NSAttributedString *, BOOL)) {
    dispatch_queue_t q = dispatch_queue_create("gx.js", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        NSMutableAttributedString *o = [NSMutableAttributedString new];
        NSMutableArray<NSString *> *lines = [[stdinText ?: @"" componentsSeparatedByString:@"\n"] mutableCopy];
        if (lines.count && [lines.lastObject length] == 0) [lines removeLastObject];
        JSContext *ctx = [JSContext new];
        __block BOOL failed = NO;
        // лимит времени — приватная, но давно существующая функция JavaScriptCore; если её нет, работаем без лимита
        void (*setLimit)(JSContextGroupRef, double, GXJSShouldTerminate, void *) = dlsym(RTLD_DEFAULT, "JSContextGroupSetExecutionTimeLimit");
        if (setLimit) setLimit(JSContextGetGroup(ctx.JSGlobalContextRef), kRunTimeout, GXJSTerminate, NULL);
        ctx[@"__gxOut"] = ^(NSString *s, BOOL err) { Append(o, s, err ? UIColor.systemOrangeColor : UIColor.labelColor); };
        ctx[@"readline"] = ^id { if (!lines.count) return [JSValue valueWithNullInContext:JSContext.currentContext]; NSString *l = lines.firstObject; [lines removeObjectAtIndex:0]; return l; };
        ctx.exceptionHandler = ^(JSContext *c, JSValue *ex) {
            failed = YES;
            NSString *line = [ex[@"line"] isUndefined] ? @"?" : [ex[@"line"] toString];
            Append(o, [NSString stringWithFormat:GXL(@"Ошибка (строка %@): %@\n"), line, [ex toString]], UIColor.systemRedColor);
        };
        [ctx evaluateScript:
         @"(function(){"
          "function fmt(a){return Array.prototype.map.call(a,function(x){"
          "if(typeof x==='string')return x;"
          "if(x instanceof Error)return String(x);"
          "try{var j=JSON.stringify(x);return j===undefined?String(x):j;}catch(e){return String(x);}}).join(' ');}"
          "var c={log:function(){__gxOut(fmt(arguments)+'\\n',false);},"
          "error:function(){__gxOut(fmt(arguments)+'\\n',true);}};"
          "c.info=c.log;c.debug=c.log;c.warn=c.error;"
          "this.console=c;this.print=c.log;this.prompt=function(){var l=readline();return l===null?null:l;};"
          "})();"];
        NSDate *t0 = [NSDate date];
        [ctx evaluateScript:typescript ? StripTypeScript(src) : src withSourceURL:[NSURL URLWithString:typescript ? @"main.ts" : @"main.js"]];
        double ms = -[t0 timeIntervalSinceNow] * 1000;
        if (job.cancelled) return;
        if (failed && ms >= kRunTimeout * 1000 - 50) Append(o, [NSString stringWithFormat:GXL(@"⏱ Остановлено: дольше %.0f с\n"), kRunTimeout], UIColor.systemRedColor);
        Append(o, [NSString stringWithFormat:GXL(@"— %@ · %.0f мс · JavaScriptCore (на устройстве)\n"), failed ? GXL(@"ошибка") : GXL(@"готово"), ms],
               failed ? UIColor.systemRedColor : UIColor.systemGreenColor);
        dispatch_async(dispatch_get_main_queue(), ^{ done(o, !failed); });
    });
}

#pragma mark - Lua (встроенный, офлайн)

static void LuaOut(void *ctx, const char *s, size_t n, int is_err) {
    NSMutableAttributedString *o = (__bridge NSMutableAttributedString *)ctx;
    NSString *t = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithBytes:s length:n encoding:NSISOLatin1StringEncoding];
    Append(o, t, is_err ? UIColor.systemOrangeColor : UIColor.labelColor);
}

static void RunLua(GXRunJob *job, NSString *src, NSString *name, NSString *stdinText, void (^done)(NSAttributedString *, BOOL)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableAttributedString *o = [NSMutableAttributedString new];
        char err[1024] = {0};
        NSDate *t0 = [NSDate date];
        int rc = gx_lua_run(src.UTF8String, (name ?: @"main.lua").UTF8String, (stdinText ?: @"").UTF8String,
                            LuaOut, (__bridge void *)o, kRunTimeout, [job cancelFlag], err, sizeof err);
        double ms = -[t0 timeIntervalSinceNow] * 1000;
        if (job.cancelled && rc) return;
        if (rc) Append(o, [NSString stringWithFormat:GXL(@"Ошибка: %s\n"), err], UIColor.systemRedColor);
        Append(o, [NSString stringWithFormat:GXL(@"— %@ · %.0f мс · %s (на устройстве)\n"), rc ? GXL(@"ошибка") : GXL(@"готово"), ms, gx_lua_version()],
               rc ? UIColor.systemRedColor : UIColor.systemGreenColor);
        dispatch_async(dispatch_get_main_queue(), ^{ done(o, rc == 0); });
    });
}

#pragma mark - Точка входа

GXRunJob *GXRunCode(NSDictionary *lang, NSString *source, NSString *fileName, NSString *stdinText,
                    void (^done)(NSAttributedString *output, BOOL ok)) {
    GXRunJob *job = [GXRunJob new];
    switch ([lang[@"kind"] intValue]) {
        case 1: RunJS(job, source, stdinText, [lang[@"id"] isEqualToString:@"typescript"], done); break;
        case 2: RunLua(job, source, fileName, stdinText, done); break;
        default: RunOnline(job, lang, source, stdinText, done); break;
    }
    return job;
}

NSString *GXRunnerStdin(void) { return [GXDefaults() stringForKey:@"gxRunStdin"] ?: @""; }

#pragma mark - Выбор компилятора

@interface GXCEPickerVC () <UISearchResultsUpdating>
@end
@implementation GXCEPickerVC {
    NSDictionary *_lang;
    NSArray<NSDictionary *> *_all, *_shown;
    NSString *_status;
}
- (instancetype)initWithLanguage:(NSDictionary *)lang {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) { _lang = lang; self.title = [NSString stringWithFormat:GXL(@"Компилятор %@"), lang[@"name"]]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
    sc.searchResultsUpdater = self; sc.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = sc;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    [self load:NO];
}
- (void)refresh { [self load:YES]; }
- (void)load:(BOOL)force {
    _status = GXL(@"Загрузка списка…"); [self.tableView reloadData];
    GXCECompilers(_lang[@"id"], force, ^(NSArray *list, NSString *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *sorted = [list sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return CmpVer(SemVer(b), SemVer(a)); }];
            self->_all = sorted ?: @[]; self->_shown = self->_all;
            self->_status = list ? nil : [NSString stringWithFormat:GXL(@"Нет связи: %@"), err ?: @"?"];
            [self.tableView reloadData];
        });
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    _shown = q.length ? [_all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", q]] : _all;
    [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 1 : (_status ? 1 : (NSInteger)_shown.count); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == 1 ? GXL(@"Код компилируется и запускается на сервере Compiler Explorer (godbolt.org), результат возвращается сюда. Нужен интернет.") : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    NSString *cur = [GXDefaults() stringForKey:CEKey(_lang[@"id"])];
    c.detailTextLabel.text = nil; c.textLabel.textColor = UIColor.labelColor; c.accessoryType = UITableViewCellAccessoryNone;
    if (ip.section == 0) {
        c.textLabel.text = GXL(@"Авто — свежий стабильный");
        NSDictionary *a = _all.count ? GXCEAutoCompiler(_all, _lang[@"pref"]) : nil;
        c.detailTextLabel.text = a[@"name"];
        if (!cur) c.accessoryType = UITableViewCellAccessoryCheckmark;
    } else if (_status) {
        c.textLabel.text = _status; c.textLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        NSDictionary *x = _shown[ip.row];
        c.textLabel.text = x[@"name"]; c.detailTextLabel.text = x[@"id"];
        if ([cur isEqualToString:x[@"id"]]) c.accessoryType = UITableViewCellAccessoryCheckmark;
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) [GXDefaults() removeObjectForKey:CEKey(_lang[@"id"])];
    else if (!_status) [GXDefaults() setObject:_shown[ip.row][@"id"] forKey:CEKey(_lang[@"id"])];
    [tv reloadData];
}
@end

#pragma mark - Ввод программы (stdin)

@implementation GXStdinVC { UITextView *_tv; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Ввод (stdin)");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [UITextView new];
    _tv.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv.text = GXRunnerStdin();
    _tv.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *hint = [UILabel new];
    hint.text = GXL(@"Этот текст получит программа как стандартный ввод: cin, input(), Console.ReadLine(), io.read(), readline() и т.п. Каждая строка — отдельный ввод.");
    hint.numberOfLines = 0; hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; hint.textColor = UIColor.secondaryLabelColor;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hint]; [self.view addSubview:_tv];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [hint.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [hint.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [_tv.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:8],
        [_tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [_tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [_tv.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [_tv becomeFirstResponder]; }
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; [GXDefaults() setObject:_tv.text ?: @"" forKey:@"gxRunStdin"]; }
@end

#pragma mark - Экран «Компиляторы» (выбор языка → папка → готовый файл → редактор)

static NSString *LangBadge(NSString *lid) {
    NSDictionary *m = @{@"c++": @"C++", @"csharp": @"C#", @"python": @"Py", @"java": @"Java", @"js": @"JS", @"c": @"C",
        @"kotlin": @"Kt", @"rust": @"Rs", @"go": @"Go", @"swift": @"Swift", @"typescript": @"TS", @"lua": @"Lua",
        @"ruby": @"Rb", @"dart": @"Dart", @"haskell": @"Hs", @"pascal": @"Pas", @"fsharp": @"F#", @"vb": @"VB",
        @"d": @"D", @"zig": @"Zig", @"julia": @"Jl", @"perl": @"Pl", @"ocaml": @"ML", @"fortran": @"F90",
        @"objc": @"ObjC", @"crystal": @"Cr", @"cobol": @"COB", @"ada": @"Ada", @"odin": @"Odin", @"mojo": @"🔥",
        @"raku": @"Raku", @"tcc": @"C→"};
    return m[lid] ?: [lid uppercaseString];
}
static UIColor *Hex(unsigned v) { return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1]; }
static UIColor *LangColor(NSString *lid) {
    NSDictionary *m = @{@"c++": @0x00599C, @"csharp": @0x68217A, @"python": @0x3776AB, @"java": @0xE76F00, @"js": @0xE8C410,
        @"c": @0x5C6BC0, @"kotlin": @0x7F52FF, @"rust": @0xB7410E, @"go": @0x00ADD8, @"swift": @0xF05138,
        @"typescript": @0x3178C6, @"lua": @0x1F2D8A, @"ruby": @0xCC342D, @"dart": @0x0175C2, @"haskell": @0x5E5086,
        @"pascal": @0xC2860E, @"fsharp": @0x378BBA, @"vb": @0x945DB7, @"d": @0xB03931, @"zig": @0xE09117,
        @"julia": @0x9558B2, @"perl": @0x39457E, @"ocaml": @0xEC6813, @"fortran": @0x734F96, @"objc": @0x438EFF,
        @"crystal": @0x333333, @"cobol": @0x005CA5, @"ada": @0x1A8A5A, @"odin": @0x3882D2, @"mojo": @0xFF4C1F,
        @"raku": @0x2B2BCF, @"tcc": @0x16A3A3};
    NSNumber *n = m[lid];
    return n ? Hex(n.unsignedIntValue) : [UIColor colorWithHue:(lid.hash % 360) / 360.0 saturation:0.55 brightness:0.75 alpha:1];
}

@interface GXLangCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *badge, *name, *info;
@end
@implementation GXLangCell
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.contentView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.contentView.layer.cornerRadius = 16;
        _badge = [UILabel new]; _name = [UILabel new]; _info = [UILabel new];
        _badge.textAlignment = NSTextAlignmentCenter; _badge.textColor = UIColor.whiteColor;
        _badge.font = [UIFont systemFontOfSize:17 weight:UIFontWeightHeavy]; _badge.adjustsFontSizeToFitWidth = YES; _badge.minimumScaleFactor = 0.5;
        _badge.layer.cornerRadius = 12; _badge.clipsToBounds = YES;
        _name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]; _name.adjustsFontSizeToFitWidth = YES; _name.minimumScaleFactor = 0.7;
        _info.font = [UIFont systemFontOfSize:12]; _info.textColor = UIColor.secondaryLabelColor; _info.numberOfLines = 2;
        for (UIView *v in @[_badge, _name, _info]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:v]; }
        [NSLayoutConstraint activateConstraints:@[
            [_badge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_badge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [_badge.widthAnchor constraintEqualToConstant:46], [_badge.heightAnchor constraintEqualToConstant:46],
            [_name.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_name.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [_name.topAnchor constraintEqualToAnchor:_badge.bottomAnchor constant:8],
            [_info.leadingAnchor constraintEqualToAnchor:_name.leadingAnchor],
            [_info.trailingAnchor constraintEqualToAnchor:_name.trailingAnchor],
            [_info.topAnchor constraintEqualToAnchor:_name.bottomAnchor constant:2],
        ]];
    }
    return self;
}
@end

@interface GXCompilersVC () <UICollectionViewDataSource, UICollectionViewDelegate>
@end
@implementation GXCompilersVC {
    UICollectionView *_cv;
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_titles;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = GXL(@"Компиляторы");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    NSArray *order = @[@"c++", @"csharp", @"python", @"java", @"js", @"c", @"kotlin", @"rust", @"go", @"swift", @"typescript", @"lua",
                       @"ruby", @"dart", @"haskell", @"pascal", @"fsharp", @"vb", @"d", @"zig", @"julia", @"perl", @"ocaml",
                       @"fortran", @"objc", @"crystal", @"cobol", @"ada", @"odin", @"mojo", @"raku"];
    NSMutableArray *popular = [NSMutableArray array], *more = [NSMutableArray array];
    for (NSString *lid in order) {
        NSDictionary *l = GXCodeLanguageForID(lid);
        if (!l) continue;
        [([order indexOfObject:lid] < 12 ? popular : more) addObject:l];
    }
    _sections = @[popular, more, @[GXCodeLanguageForID(@"tcc")]];
    _titles = @[GXL(@"Популярные"), GXL(@"Ещё языки"), GXL(@"Твики и приложения iOS")];

    UICollectionViewCompositionalLayout *lay = [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger s, id<NSCollectionLayoutEnvironment> env) {
        CGFloat w = env.container.effectiveContentSize.width;
        NSInteger cols = w > 700 ? 5 : (w > 500 ? 4 : 2);
        NSCollectionLayoutItem *it = [NSCollectionLayoutItem itemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0 / cols] heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1]]];
        it.contentInsets = NSDirectionalEdgeInsetsMake(5, 5, 5, 5);
        NSCollectionLayoutGroup *g = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1] heightDimension:[NSCollectionLayoutDimension absoluteDimension:138]] subitems:@[it]];
        NSCollectionLayoutSection *sec = [NSCollectionLayoutSection sectionWithGroup:g];
        sec.contentInsets = NSDirectionalEdgeInsetsMake(4, 11, 14, 11);
        NSCollectionLayoutBoundarySupplementaryItem *h = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1] heightDimension:[NSCollectionLayoutDimension estimatedDimension:30]] elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
        sec.boundarySupplementaryItems = @[h];
        return sec;
    }];
    _cv = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:lay];
    _cv.backgroundColor = UIColor.clearColor;
    _cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _cv.dataSource = self; _cv.delegate = self;
    [_cv registerClass:GXLangCell.class forCellWithReuseIdentifier:@"l"];
    [_cv registerClass:UICollectionReusableView.class forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"h"];
    [self.view addSubview:_cv];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"keyboard"] style:UIBarButtonItemStylePlain target:self action:@selector(editStdin)];
}
- (void)editStdin { [self.navigationController pushViewController:[GXStdinVC new] animated:YES]; }

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv { return _sections.count; }
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return _sections[s].count; }
- (UICollectionReusableView *)collectionView:(UICollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)ip {
    UICollectionReusableView *v = [cv dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"h" forIndexPath:ip];
    UILabel *l = [v viewWithTag:7];
    if (!l) {
        l = [UILabel new]; l.tag = 7; l.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        l.translatesAutoresizingMaskIntoConstraints = NO; [v addSubview:l];
        [NSLayoutConstraint activateConstraints:@[[l.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:6], [l.topAnchor constraintEqualToAnchor:v.topAnchor constant:6], [l.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-2]]];
    }
    l.text = _titles[ip.section];
    return v;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    GXLangCell *c = [cv dequeueReusableCellWithReuseIdentifier:@"l" forIndexPath:ip];
    NSDictionary *l = _sections[ip.section][ip.item];
    NSString *lid = l[@"id"];
    c.badge.text = LangBadge(lid);
    c.badge.backgroundColor = LangColor(lid);
    c.badge.textColor = [lid isEqualToString:@"js"] ? UIColor.blackColor : UIColor.whiteColor;
    int k = [l[@"kind"] intValue];
    c.name.text = k == 0 ? GXL(@"C — твики и IPA") : ([lid isEqualToString:@"c"] ? @"C" : l[@"name"]);
    NSString *where = k == 0 ? GXL(@"на iPhone · TinyCC") : (k == 3 ? GXL(@"онлайн · Compiler Explorer") : GXL(@"офлайн · на iPhone"));
    c.info.text = [NSString stringWithFormat:@".%@ · %@", GXCodeLanguageExt(l), where];
    return c;
}

// Последний файл языка → самый свежий в папке → новый main.<ext> из шаблона
- (NSString *)fileForLang:(NSDictionary *)l {
    NSString *last = [GXDefaults() stringForKey:[@"gxLast." stringByAppendingString:l[@"id"]]];
    if (last && [FM() fileExistsAtPath:last]) return last;
    NSString *dir = GXCodeLanguageDir(l);
    NSString *best = nil; NSDate *bd = nil;
    for (NSString *f in [FM() contentsOfDirectoryAtPath:dir error:nil]) {
        if (![l[@"ext"] containsObject:f.pathExtension.lowercaseString]) continue;
        NSString *p = [dir stringByAppendingPathComponent:f];
        NSDate *d = [[FM() attributesOfItemAtPath:p error:nil] fileModificationDate];
        if (!bd || [d compare:bd] == NSOrderedDescending) { bd = d; best = p; }
    }
    if (best) return best;
    NSString *p = [dir stringByAppendingPathComponent:[@"main" stringByAppendingPathExtension:GXCodeLanguageExt(l)]];
    [GXCodeTemplate(l) writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return p;
}
- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [cv deselectItemAtIndexPath:ip animated:YES];
    NSDictionary *l = _sections[ip.section][ip.item];
    NSString *path = [l[@"kind"] intValue] == 0 ? nil : [self fileForLang:l];
    [self.navigationController pushViewController:[[GXCompilerVC alloc] initWithPath:path] animated:YES];
}
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)pt {
    NSDictionary *l = _sections[ip.section][ip.item];
    if ([l[@"kind"] intValue] == 0) return nil;
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
        UIAction *files = [UIAction actionWithTitle:GXL(@"Все файлы") image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
            [ws.navigationController pushViewController:[[GXBrowserVC alloc] initWithPath:GXCodeLanguageDir(l)] animated:YES];
        }];
        UIAction *nf = [UIAction actionWithTitle:GXL(@"Новый файл…") image:[UIImage systemImageNamed:@"doc.badge.plus"] identifier:nil handler:^(UIAction *a) { [ws newFileForLang:l]; }];
        return [UIMenu menuWithChildren:@[nf, files]];
    }];
}
- (void)newFileForLang:(NSDictionary *)l {
    NSString *ext = GXCodeLanguageExt(l);
    GXPrompt(self, [NSString stringWithFormat:GXL(@"Новый файл · %@"), l[@"name"]], [NSString stringWithFormat:GXL(@"Папка «%@» в «Моих файлах»"), GXCodeLanguageFolder(l)], [@"program" stringByAppendingPathExtension:ext], nil, GXL(@"Создать"), ^(NSString *v) {
        NSString *n = v.length ? v : [@"program" stringByAppendingPathExtension:ext];
        if (![l[@"ext"] containsObject:n.pathExtension.lowercaseString]) n = [n stringByAppendingPathExtension:ext];
        NSString *p = GXUniquePath(GXCodeLanguageDir(l), n);
        [GXCodeTemplate(l) writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self.navigationController pushViewController:[[GXCompilerVC alloc] initWithPath:p] animated:YES];
    });
}
@end

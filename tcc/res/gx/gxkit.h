/*
 * gxkit.h — помощники для твиков на C во встроенном компиляторе GX Files.
 * Objective-C (классы, вызовы методов), строки NSString, лог, алерт,
 * хук методов Objective-C и хук C-функций (перепривязка указателей импорта, как fishhook).
 *
 * Важно для arm64: objc_msgSend нужно вызывать с ТОЧНЫМ прототипом, поэтому
 * макросы GX_MSGn требуют типы аргументов: GX_MSG1(тип_результата, объект, "селектор:", тип1, арг1).
 */
#ifndef GXKIT_H
#define GXKIT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>

/* ---------- геометрия (без подключения CoreGraphics) ---------- */
#ifndef CGGEOMETRY_H_
#define CGGEOMETRY_H_
typedef double CGFloat;
typedef struct CGPoint { CGFloat x, y; } CGPoint;
typedef struct CGSize { CGFloat width, height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;
static inline CGRect CGRectMake(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { CGRect r; r.origin.x = x; r.origin.y = y; r.size.width = w; r.size.height = h; return r; }
static inline CGPoint CGPointMake(CGFloat x, CGFloat y) { CGPoint p; p.x = x; p.y = y; return p; }
static inline CGSize CGSizeMake(CGFloat w, CGFloat h) { CGSize s; s.width = w; s.height = h; return s; }
#endif

/* ---------- Objective-C ---------- */
#define GX_CLS(name)  ((id)objc_getClass(name))
#define GX_SEL(name)  sel_registerName(name)

#define GX_MSG0(R, o, s) \
    ((R (*)(id, SEL))objc_msgSend)((id)(o), sel_registerName(s))
#define GX_MSG1(R, o, s, T1, a1) \
    ((R (*)(id, SEL, T1))objc_msgSend)((id)(o), sel_registerName(s), a1)
#define GX_MSG2(R, o, s, T1, a1, T2, a2) \
    ((R (*)(id, SEL, T1, T2))objc_msgSend)((id)(o), sel_registerName(s), a1, a2)
#define GX_MSG3(R, o, s, T1, a1, T2, a2, T3, a3) \
    ((R (*)(id, SEL, T1, T2, T3))objc_msgSend)((id)(o), sel_registerName(s), a1, a2, a3)
#define GX_MSG4(R, o, s, T1, a1, T2, a2, T3, a3, T4, a4) \
    ((R (*)(id, SEL, T1, T2, T3, T4))objc_msgSend)((id)(o), sel_registerName(s), a1, a2, a3, a4)
#define GX_MSG5(R, o, s, T1, a1, T2, a2, T3, a3, T4, a4, T5, a5) \
    ((R (*)(id, SEL, T1, T2, T3, T4, T5))objc_msgSend)((id)(o), sel_registerName(s), a1, a2, a3, a4, a5)

/* NSString из C-строки (UTF-8, русский тоже) и обратно */
static inline id gx_str(const char *s) {
    return GX_MSG1(id, GX_CLS("NSString"), "stringWithUTF8String:", const char *, s ? s : "");
}
static inline const char *gx_cstr(id s) {
    return s ? GX_MSG0(const char *, s, "UTF8String") : "";
}
/* Имя класса объекта */
static inline const char *gx_classname(id o) { return o ? class_getName(object_getClass(o)) : "nil"; }

/* ---------- NSNumber ---------- */
static inline id gx_num_i(long v) { return GX_MSG1(id, GX_CLS("NSNumber"), "numberWithLongLong:", long long, v); }
static inline id gx_num_d(double v) { return GX_MSG1(id, GX_CLS("NSNumber"), "numberWithDouble:", double, v); }
static inline id gx_num_b(int v) { return GX_MSG1(id, GX_CLS("NSNumber"), "numberWithBool:", BOOL, v ? 1 : 0); }
static inline long gx_int(id n) { return n ? GX_MSG0(long long, n, "longLongValue") : 0; }
static inline double gx_double(id n) { return n ? GX_MSG0(double, n, "doubleValue") : 0; }
static inline int gx_bool(id n) { return n ? (GX_MSG0(BOOL, n, "boolValue") ? 1 : 0) : 0; }

/* ---------- alloc+init и доступ к свойствам по имени (KVC) ---------- */
static inline id gx_alloc(const char *cls) { id o = GX_MSG0(id, GX_CLS(cls), "alloc"); return o ? GX_MSG0(id, o, "init") : 0; }
static inline id gx_prop(id o, const char *key) { return o ? GX_MSG1(id, o, "valueForKey:", id, gx_str(key)) : 0; }
static inline void gx_setprop(id o, const char *key, id value) { if (o) GX_MSG2(void, o, "setValue:forKey:", id, value, id, gx_str(key)); }

/* ---------- лог ---------- */
extern void NSLog(id format, ...);
static void gx_log(const char *fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    NSLog(gx_str("[gx] %s"), buf);
}

/* ---------- главный поток ---------- */
static inline void gx_main(void (*fn)(void *), void *ctx) { dispatch_async_f(dispatch_get_main_queue(), ctx, fn); }
static inline void gx_main_after(double seconds, void (*fn)(void *), void *ctx) {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * 1000000000.0)), dispatch_get_main_queue(), ctx, fn);
}

/* ---------- верхний экран и алерт (вызывать на главном потоке) ---------- */
static id gx_top_vc(void) {
    id app = GX_MSG0(id, GX_CLS("UIApplication"), "sharedApplication");
    id win = app ? GX_MSG0(id, app, "keyWindow") : 0;
    if (!win && app) {
        id wins = GX_MSG0(id, app, "windows");
        win = wins ? GX_MSG0(id, wins, "firstObject") : 0;
    }
    id vc = win ? GX_MSG0(id, win, "rootViewController") : 0;
    while (vc) {
        id p = GX_MSG0(id, vc, "presentedViewController");
        if (!p) break;
        vc = p;
    }
    return vc;
}
static void gx_alert(const char *title, const char *message) {
    id vc = gx_top_vc();
    if (!vc) { gx_log("алерт: нет окна (%s: %s)", title, message); return; }
    id a = GX_MSG3(id, GX_CLS("UIAlertController"), "alertControllerWithTitle:message:preferredStyle:",
                   id, gx_str(title), id, gx_str(message), long, 1);
    id ok = GX_MSG3(id, GX_CLS("UIAlertAction"), "actionWithTitle:style:handler:", id, gx_str("OK"), long, 0, id, 0);
    GX_MSG1(void, a, "addAction:", id, ok);
    GX_MSG3(void, vc, "presentViewController:animated:completion:", id, a, BOOL, 1, id, 0);
}

/* ---------- хук метода Objective-C ----------
 * gx_hook_method("UIViewController", "viewDidAppear:", 0, (IMP)my_imp, (IMP *)&orig);
 * is_class = 1 — для методов класса (+). Возвращает 1 при успехе. */
static int gx_hook_method(const char *cls, const char *sel, int is_class, IMP replacement, IMP *original) {
    Class c = objc_getClass(cls);
    if (!c) { gx_log("хук: нет класса %s", cls); return 0; }
    if (is_class) c = object_getClass((id)c);
    SEL s = sel_registerName(sel);
    Method m = class_getInstanceMethod(c, s);
    if (!m) { gx_log("хук: нет метода %s %s", cls, sel); return 0; }
    /* если метод унаследован — добавляем в сам класс, чтобы не задеть родителя */
    if (class_addMethod(c, s, replacement, method_getTypeEncoding(m))) {
        if (original) *original = method_getImplementation(m);
        return 1;
    }
    IMP old = method_setImplementation(m, replacement);
    if (original) *original = old;
    return 1;
}

/* ---------- хук C-функции (перепривязка указателей импорта во всех загруженных образах) ----------
 * static int (*orig_getpid)(void);
 * static int my_getpid(void) { return orig_getpid(); }
 * gx_rebind("getpid", (void *)my_getpid, (void **)&orig_getpid);
 * Работает для вызовов ЧЕРЕЗ импорт (из других библиотек/приложения), не для вызовов внутри той же библиотеки. */
extern unsigned int mach_task_self_;
#define gx__mach_task_self_ mach_task_self_
extern int vm_protect(unsigned int task, uintptr_t address, uintptr_t size, int set_maximum, int new_protection);
#define gx__vm_protect vm_protect
static int gx__rebind_image(const struct mach_header_64 *mh, intptr_t slide, const char *name, void *repl, void **orig) {
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    const struct segment_command_64 *linkedit = 0;
    const struct symtab_command *symtab = 0;
    const struct dysymtab_command *dysymtab = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, "__LINKEDIT")) linkedit = (const struct segment_command_64 *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)lc;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return 0;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *ind = (const uint32_t *)(base + dysymtab->indirectsymoff);
    int hits = 0;
    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__DATA") && strcmp(seg->segname, "__DATA_CONST")) continue;
        const struct section_64 *sec = (const struct section_64 *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++, sec++) {
            uint32_t type = sec->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **ptrs = (void **)((uintptr_t)slide + sec->addr);
            for (uint64_t j = 0; j < sec->size / sizeof(void *); j++) {
                uint32_t si = ind[sec->reserved1 + j];
                if (si & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                const char *sn = strs + syms[si].n_un.n_strx;
                if (sn[0] != '_' || strcmp(sn + 1, name)) continue;
                if (orig && !*orig && ptrs[j] != repl) *orig = ptrs[j];
                uintptr_t page = (uintptr_t)&ptrs[j] & ~(uintptr_t)0x3FFF;
                if (mprotect((void *)page, 0x4000, PROT_READ | PROT_WRITE) != 0)
                    gx__vm_protect(gx__mach_task_self_, page, 0x4000, 0, 0x1 | 0x2 | 0x10);   /* READ|WRITE|COPY */
                ptrs[j] = repl;
                hits++;
            }
        }
    }
    return hits;
}
static int gx_rebind(const char *name, void *replacement, void **original) {
    if (original && !*original) *original = dlsym(RTLD_DEFAULT, name);
    int hits = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++)
        hits += gx__rebind_image((const struct mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), name, replacement, original);
    if (!hits) gx_log("rebind: %s не найден в импортах", name);
    return hits;
}

/* ---------- память процесса ---------- */
/* Адрес загрузки образа по имени (например "UnityFramework" или имя приложения), 0 если нет */
static uintptr_t gx_image_base(const char *name_part) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (p && strstr(p, name_part)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

#endif /* GXKIT_H */

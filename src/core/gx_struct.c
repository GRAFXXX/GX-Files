// Структурирование псевдокода: линейный код с goto/метками → if/else/while.
// Работает поверх вывода gx_pseudo. Главный принцип — НИКОГДА не менять смысл:
// если участок не укладывается в структуру чисто, соответствующий goto остаётся как есть.
#include "gx_struct.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define MAXB 4000

enum { T_FALL, T_GOTO, T_COND, T_RET, T_END };   // END — нет преемника (goto *, хвостовой возврат)

typedef struct {
    char **stmt; int nst, capst;    // обычные операторы (без управляющего)
    uint64_t label; int haslabel;
    int term;                       // тип завершения
    uint64_t target;                // для GOTO/COND — адрес метки
    int tidx;                       // индекс блока-цели (или -1)
    char cond[512];                 // для COND — условие (ветка «переход взят»)
    char tail[512];                 // текст терминатора, если его оставляем как есть (fallback)
} blk;

#define OUT_LIMIT (8u * 1024 * 1024)   // предел вывода на одну функцию — защита от разрастания
#define DEPTH_LIMIT 300

typedef struct {
    blk b[MAXB]; int n;
    char **dom; int *order;         // доминаторы — битовые маски по словам
    // вспомогательное при рендеринге
    char *out; size_t on, ocap;
    int *used;                      // метка блока ещё нужна (на неё остался goto)
    int bail;                       // превышен предел — откат к исходному тексту
} sx;

static void emit(sx *s, const char *str) {
    if (s->bail) return;
    if (s->on > OUT_LIMIT) { s->bail = 1; return; }
    size_t l = strlen(str);
    if (s->on + l + 1 > s->ocap) { s->ocap = (s->on + l + 64) * 2; s->out = realloc(s->out, s->ocap); }
    memcpy(s->out + s->on, str, l); s->on += l; s->out[s->on] = 0;
}
static void emitf(sx *s, int depth, const char *fmt, ...) {
    char buf[1200]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    for (int i = 0; i < depth; i++) emit(s, "    ");
    emit(s, buf); emit(s, "\n");
}

static void addstmt(blk *b, const char *line) {
    if (b->nst == b->capst) { b->capst = b->capst ? b->capst * 2 : 8; b->stmt = realloc(b->stmt, sizeof(char *) * b->capst); }
    b->stmt[b->nst++] = strdup(line);
}

// левый trim; возвращает указатель внутрь строки
static const char *ltrim(const char *s) { while (*s == ' ' || *s == '\t') s++; return s; }

static int parse_label(const char *l, uint64_t *out) {
    if (strncmp(l, "loc_", 4)) return 0;
    const char *p = l + 4; char *e;
    unsigned long long v = strtoull(p, &e, 16);
    if (e == p || *e != ':') return 0;
    *out = v; return 1;
}

// распарсить тело в блоки. Возвращает 0 при отказе (тогда структурирование не делаем).
static int build(sx *s, const char *body) {
    blk *cur = NULL;
    const char *p = body;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        char line[1400];
        if (len >= sizeof line) len = sizeof line - 1;
        memcpy(line, p, len); line[len] = 0;
        p = nl ? nl + 1 : p + len;

        const char *t = ltrim(line);
        if (!*t) continue;
        uint64_t lbl;
        if (parse_label(t, &lbl)) {
            if (s->n >= MAXB) return 0;
            if (cur && cur->term < 0) cur->term = T_FALL;   // предыдущий блок проваливается сюда
            cur = &s->b[s->n++];
            memset(cur, 0, sizeof *cur); cur->term = -1; cur->tidx = -1;
            cur->label = lbl; cur->haslabel = 1;
            continue;
        }
        if (!cur || cur->term >= 0) {   // начать новый блок без метки
            if (s->n >= MAXB) return 0;
            cur = &s->b[s->n++];
            memset(cur, 0, sizeof *cur); cur->term = -1; cur->tidx = -1;
        }
        // терминаторы
        uint64_t tg;
        if (!strncmp(t, "goto loc_", 9) && sscanf(t + 9, "%llx", (unsigned long long *)&tg) == 1 && strchr(t, '*') == NULL) {
            cur->term = T_GOTO; cur->target = tg;
        } else if (!strncmp(t, "if (", 4)) {
            const char *g = strstr(t, ") goto loc_");
            if (g && sscanf(g + 11, "%llx", (unsigned long long *)&tg) == 1) {
                size_t cl = (size_t)(g - (t + 4));
                if (cl < sizeof cur->cond) { memcpy(cur->cond, t + 4, cl); cur->cond[cl] = 0; cur->term = T_COND; cur->target = tg; }
                else { addstmt(cur, t); continue; }   // слишком длинное — оставить как есть
            } else { addstmt(cur, t); continue; }      // прочие if (...) action; — обычный оператор
        } else if (!strncmp(t, "return", 6) && (t[6] == ' ' || t[6] == ';')) {
            snprintf(cur->tail, sizeof cur->tail, "%s", t); cur->term = T_RET;
        } else if (!strncmp(t, "goto *", 6)) {
            snprintf(cur->tail, sizeof cur->tail, "%s", t); cur->term = T_END;
        } else {
            addstmt(cur, t); continue;
        }
    }
    if (cur && cur->term < 0) cur->term = T_RET;   // конец функции
    if (!s->n) return 0;
    // разрешить метки → индексы
    for (int i = 0; i < s->n; i++) if (s->b[i].term == T_GOTO || s->b[i].term == T_COND) {
        s->b[i].tidx = -1;
        for (int j = 0; j < s->n; j++) if (s->b[j].haslabel && s->b[j].label == s->b[i].target) { s->b[i].tidx = j; break; }
    }
    return 1;
}

// преемники блока i: до двух. Возвращает число.
static int succs(sx *s, int i, int out[2]) {
    blk *b = &s->b[i]; int n = 0;
    switch (b->term) {
        case T_FALL: if (i + 1 < s->n) out[n++] = i + 1; break;
        case T_GOTO: if (b->tidx >= 0) out[n++] = b->tidx; break;
        case T_COND: if (b->tidx >= 0) out[n++] = b->tidx; if (i + 1 < s->n) out[n++] = i + 1; break;
        case T_RET: case T_END: break;
    }
    return n;
}

// ---- доминаторы (итеративно по битовым маскам) ----
static int W(sx *s) { return (s->n + 31) / 32; }
static void dom_compute(sx *s) {
    int w = W(s);
    s->dom = malloc(sizeof(char *) * s->n);
    uint32_t **d = malloc(sizeof(uint32_t *) * s->n);
    for (int i = 0; i < s->n; i++) { d[i] = malloc(4 * w); for (int k = 0; k < w; k++) d[i][k] = i == 0 ? 0 : 0xFFFFFFFFu; }
    d[0][0] = 1;   // dom(0) = {0}
    // предки
    int *npred = calloc(s->n, sizeof(int));
    int **pred = malloc(sizeof(int *) * s->n);
    for (int i = 0; i < s->n; i++) pred[i] = malloc(sizeof(int) * s->n);
    for (int i = 0; i < s->n; i++) { int sc[2], k = succs(s, i, sc); for (int j = 0; j < k; j++) pred[sc[j]][npred[sc[j]]++] = i; }
    int changed = 1;
    while (changed) {
        changed = 0;
        for (int i = 1; i < s->n; i++) {
            uint32_t *tmp = malloc(4 * w);
            for (int k = 0; k < w; k++) tmp[k] = 0xFFFFFFFFu;
            int any = 0;
            for (int pp = 0; pp < npred[i]; pp++) { for (int k = 0; k < w; k++) tmp[k] &= d[pred[i][pp]][k]; any = 1; }
            if (!any) for (int k = 0; k < w; k++) tmp[k] = 0;
            tmp[i / 32] |= 1u << (i % 32);
            if (memcmp(tmp, d[i], 4 * w)) { memcpy(d[i], tmp, 4 * w); changed = 1; }
            free(tmp);
        }
    }
    for (int i = 0; i < s->n; i++) s->dom[i] = (char *)d[i];
    for (int i = 0; i < s->n; i++) free(pred[i]);
    free(pred); free(npred); free(d);
}
static int dominates(sx *s, int a, int b) { return (((uint32_t *)s->dom[b])[a / 32] >> (a % 32)) & 1; }

// ---- информация о циклах ----
static int *loop_end;      // для заголовка: индекс после тела, иначе -1
static int *loop_follow;   // индекс блока-выхода из цикла (или -1)

static void loops_compute(sx *s) {
    loop_end = malloc(sizeof(int) * s->n);
    loop_follow = malloc(sizeof(int) * s->n);
    for (int i = 0; i < s->n; i++) { loop_end[i] = -1; loop_follow[i] = -1; }
    for (int h = 0; h < s->n; h++) {
        int maxlatch = -1;
        for (int u = h; u < s->n; u++) {   // обратное ребро u→h, h доминирует u
            int sc[2], k = succs(s, u, sc);
            for (int j = 0; j < k; j++) if (sc[j] == h && dominates(s, h, u)) maxlatch = u;
        }
        if (maxlatch < 0) continue;
        int end = maxlatch + 1;
        // тело [h,end) должно быть односвязным: всё внутри доминируется h
        int ok = 1;
        for (int x = h; x < end; x++) if (!dominates(s, h, x)) { ok = 0; break; }
        if (!ok) continue;
        // единственный выход
        int follow = -1, multi = 0;
        for (int x = h; x < end; x++) {
            int sc[2], k = succs(s, x, sc);
            for (int j = 0; j < k; j++) if (sc[j] < h || sc[j] >= end) {
                if (follow < 0) follow = sc[j]; else if (follow != sc[j]) multi = 1;
            }
        }
        if (multi) continue;                 // несколько выходов — не структурируем, останутся goto
        if (follow != -1 && follow != end) continue;   // выход не сразу за телом — нерегулярно, оставляем goto
        loop_end[h] = end; loop_follow[h] = follow;   // follow == end (смежный выход) или -1 (бесконечный)
    }
}

// отрицание условия для «if (!взято) { ... }»
static void negate(const char *c, char *out, size_t n) {
    while (*c == ' ') c++;
    if (c[0] == '!' && c[1] == '(') { size_t l = strlen(c); if (l >= 3 && c[l - 1] == ')') { snprintf(out, n, "%.*s", (int)(l - 3), c + 2); return; } }
    if (c[0] == '!') { snprintf(out, n, "%s", c + 1); return; }
    // поиск оператора сравнения на верхнем уровне скобок
    static const char *ops[] = {" == ", " != ", " >= ", " <= ", " > ", " < ", NULL};
    static const char *inv[] = {" != ", " == ", " < ", " > ", " <= ", " >= "};
    int depth = 0;
    for (const char *p = c; *p; p++) {
        if (*p == '(') depth++;
        else if (*p == ')') depth--;
        else if (depth == 0) for (int o = 0; ops[o]; o++) {
            size_t ol = strlen(ops[o]);
            if (!strncmp(p, ops[o], ol)) {
                snprintf(out, n, "%.*s%s%s", (int)(p - c), c, inv[o], p + ol);
                return;
            }
        }
    }
    snprintf(out, n, "!(%s)", c);
}

// участок [a,end) замкнут: вход только в a; выходы только within / join / break / continue
static int closed2(sx *s, int a, int end, int join, int brk, int cont) {
    for (int k = a; k < end; k++) {
        int sc[2], ns = succs(s, k, sc);
        for (int j = 0; j < ns; j++) {
            int t = sc[j];
            if (t >= a && t < end) continue;
            if (t == join || t == brk || t == cont) continue;
            return 0;
        }
    }
    for (int m = 0; m < s->n; m++) {
        if (m >= a && m < end) continue;
        int sc[2], ns = succs(s, m, sc);
        for (int j = 0; j < ns; j++) if (sc[j] > a && sc[j] < end) return 0;   // вход внутрь участка
    }
    return 1;
}

// render возвращает 1, если управление НЕ может «провалиться» на end (все пути ушли через
// break/continue/return/goto), иначе 0. Используется, чтобы добавить break внизу цикла.
static int render(sx *s, int start, int end, int brk, int cont, int merge, int depth, int open_header);

// действие по ребру на цель t; 0 — обычный проход (ничего не печатает), 1 — передал поток
static int edge(sx *s, int t, int brk, int cont, int fall, int merge, int depth) {
    if (t == cont) { emitf(s, depth, "continue;"); return 1; }
    if (t == brk)  { emitf(s, depth, "break;"); return 1; }
    if (t == merge) return 0;   // слияние
    if (t == fall) return 0;    // естественный проход
    char lab[40]; snprintf(lab, sizeof lab, "loc_%llx", (unsigned long long)(t >= 0 && t < s->n ? s->b[t].label : 0));
    if (t >= 0 && t < s->n) s->used[t] = 1;
    emitf(s, depth, "goto %s;", lab);
    return 1;
}

static int render(sx *s, int start, int end, int brk, int cont, int merge, int depth, int open_header) {
    if (s->bail || depth > DEPTH_LIMIT) { s->bail = 1; return 1; }
    int i = start, flowed = 0;   // flowed=1 — текущая точка недостижима проходом (поток уже передан)
    while (i < end) {
        if (s->bail) return 1;
        blk *b = &s->b[i];
        // цикл
        if (i != open_header && loop_end[i] > i && loop_end[i] <= end) {
            int le = loop_end[i], fe = loop_follow[i];   // fe == le (смежный выход) или -1
            if (s->used[i]) { char l[40]; snprintf(l, sizeof l, "loc_%llx:", (unsigned long long)b->label); emitf(s, depth, "%s", l); }
            emitf(s, depth, "while (1) {");
            int tf = render(s, i, le, fe < 0 ? -1 : le, i, -1, depth + 1, i);
            if (!tf) emitf(s, depth + 1, "break;");   // тело может «провалиться» на выход
            emitf(s, depth, "}");
            flowed = 0;
            i = le; continue;   // оставшиеся блоки рендерим по порядку — метки на месте
        }
        if (b->haslabel && s->used[i]) { char l[40]; snprintf(l, sizeof l, "loc_%llx:", (unsigned long long)b->label); emitf(s, depth, "%s", l); }
        for (int k = 0; k < b->nst; k++) emitf(s, depth, "%s", b->stmt[k]);

        if (b->term == T_RET || b->term == T_END) { emitf(s, depth, "%s", b->tail); flowed = 1; i++; continue; }
        if (b->term == T_FALL) { flowed = edge(s, i + 1 < s->n ? i + 1 : -1, brk, cont, i + 1, merge, depth); i++; continue; }
        if (b->term == T_GOTO) {
            if (b->tidx == cont && i + 1 == end) { flowed = 1; i++; continue; }   // естественный виток — continue в конце тела лишний
            flowed = edge(s, b->tidx, brk, cont, i + 1, merge, depth); i++; continue;
        }
        if (b->term == T_COND) {
            int t = b->tidx;
            if (t == brk) { emitf(s, depth, "if (%s) break;", b->cond); flowed = 0; i++; continue; }
            if (t == cont) { emitf(s, depth, "if (%s) continue;", b->cond); flowed = 0; i++; continue; }
            if (t > i + 1 && t <= end) {
                char neg[600]; negate(b->cond, neg, sizeof neg);
                // if-else: последний блок ветки «проход» уходит вперёд за t (в стык E)
                blk *last = &s->b[t - 1];
                int E = (last->term == T_GOTO && last->tidx > t && last->tidx <= end) ? last->tidx : -1;
                if (E >= 0 && closed2(s, i + 1, t, E, brk, cont) && closed2(s, t, E, E, brk, cont)) {
                    emitf(s, depth, "if (%s) {", neg);
                    int t1 = render(s, i + 1, t, brk, cont, E, depth + 1, -1);
                    emitf(s, depth, "} else {");
                    int t2 = render(s, t, E, brk, cont, E, depth + 1, -1);
                    emitf(s, depth, "}");
                    flowed = t1 && t2;
                    i = E; continue;
                }
                // if-then: ветка «проход» [i+1,t) замкнута со стыком t
                if (closed2(s, i + 1, t, t, brk, cont)) {
                    emitf(s, depth, "if (%s) {", neg);
                    render(s, i + 1, t, brk, cont, t, depth + 1, -1);
                    emitf(s, depth, "}");
                    flowed = 0; i = t; continue;
                }
            }
            if (t >= 0 && t < s->n) s->used[t] = 1;
            emitf(s, depth, "if (%s) goto loc_%llx;", b->cond, (unsigned long long)(t >= 0 ? s->b[t].label : b->target));
            flowed = 0; i++; continue;
        }
        i++;
    }
    return flowed;
}

// Полный текст псевдокода (комментарий, сигнатура, { тело }) → с структурированным телом.
// Возвращает malloc-строку или NULL, если не удалось выделить тело (тогда вызывающий оставляет оригинал).
char *gx_pseudo_structure(const char *full) {
    const char *hb = strstr(full, "\n{\n");
    if (!hb) return NULL;
    size_t head_end = (size_t)(hb - full) + 3;    // включая "{\n"
    size_t len = strlen(full);
    size_t foot;
    if (len >= 7 && !strcmp(full + len - 7, "}\n@end\n")) foot = len - 7;
    else if (len >= 2 && !strcmp(full + len - 2, "}\n")) foot = len - 2;
    else return NULL;
    if (foot < head_end) return NULL;
    char *body = malloc(foot - head_end + 1);
    memcpy(body, full + head_end, foot - head_end); body[foot - head_end] = 0;
    char *st = gx_structure(body);
    free(body);
    size_t rl = head_end + strlen(st) + (len - foot) + 1;
    char *r = malloc(rl);
    memcpy(r, full, head_end);
    strcpy(r + head_end, st);
    strcat(r, full + foot);
    free(st);
    return r;
}

char *gx_structure(const char *body) {
    sx *s = calloc(1, sizeof *s);
    if (!build(s, body)) { free(s); return strdup(body); }
    if (s->n >= MAXB) { goto bail; }
    dom_compute(s);
    loops_compute(s);
    s->used = calloc(s->n, sizeof(int));
    // предварительный проход: отметить метки, на которые реально останутся goto,
    // проще — пометить все, затем render уточнит. Здесь пройдёмся render дважды:
    // первый проход заполнит used (куда реально пойдут goto), второй — напечатает метки.
    size_t cap0 = s->ocap; (void)cap0;
    // Проход 1 — только чтобы заполнить used[] (какие метки реально останутся как goto).
    // Решения render не зависят от used[], поэтому проход 2 даст те же goto → все метки на месте.
    render(s, 0, s->n, -1, -1, s->n, 1, -1);
    char *r;
    if (s->bail) r = strdup(body);   // проход не уложился в пределы — безопасный откат к исходному тексту
    else {
        free(s->out); s->out = NULL; s->on = 0; s->ocap = 0;
        render(s, 0, s->n, -1, -1, s->n, 1, -1);
        r = s->bail ? strdup(body) : (s->out ? s->out : strdup(""));
        if (s->bail) free(s->out);
    }
    // страховка: любой goto должен иметь свою метку — иначе откат к исходнику
    for (const char *p = r; (p = strstr(p, "goto loc_")); ) {
        char lab[40]; if (sscanf(p + 5, "%39[^;\n]", lab) == 1) {
            char decl[48]; snprintf(decl, sizeof decl, "%s:", lab);
            if (!strstr(r, decl)) { free(r); r = strdup(body); break; }
        }
        p += 5;
    }

    for (int i = 0; i < s->n; i++) {
        for (int k = 0; k < s->b[i].nst; k++) free(s->b[i].stmt[k]);
        free(s->b[i].stmt);
        free(s->dom[i]);
    }
    free(s->dom); free(loop_end); free(loop_follow); free(s->used); loop_end = loop_follow = NULL;
    free(s);
    return r;
bail:
    free(s);
    return strdup(body);
}

// Встроенный Lua 5.4 (lua/ — исходники Lua.org, лицензия MIT, см. lua/LICENSE).
// Вся Lua собирается здесь одной единицей через lua/onelua.c (MAKE_LIB — без lua.c/main).
#define MAKE_LIB 1
#define LUA_USE_IOS 1          // os.execute без system() — на iOS его нет
#include "../../lua/onelua.c"

#include "gx_lua.h"
#include "gx_tr.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef struct {
    gx_lua_out_fn out; void *ctx;
    const char *in; size_t inlen, inpos;      // stdin программы
    double deadline; volatile int *cancel;
    int timedout, cancelled, exited, exitcode;
} gxl;

#define GX_EXIT_MARK "\x01gx-exit\x01"

static gxl *gxl_G(lua_State *L) { return *(gxl **)lua_getextraspace(L); }
static double gxl_now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

/* ---------- вывод ---------- */
static int gxl_l_print(lua_State *L) {
    gxl *g = gxl_G(L); int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        size_t l; const char *s = luaL_tolstring(L, i, &l);
        if (i > 1) g->out(g->ctx, "\t", 1, 0);
        g->out(g->ctx, s, l, 0);
        lua_pop(L, 1);
    }
    g->out(g->ctx, "\n", 1, 0);
    return 0;
}
static void gxl_write_args(lua_State *L, int from, int is_err) {
    gxl *g = gxl_G(L); int n = lua_gettop(L);
    for (int i = from; i <= n; i++) { size_t l; const char *s = luaL_checklstring(L, i, &l); g->out(g->ctx, s, l, is_err); }
}
static int gxl_l_iowrite(lua_State *L) { gxl_write_args(L, 1, 0); lua_getglobal(L, "io"); lua_getfield(L, -1, "stdout"); return 1; }
static int gxl_l_outwrite(lua_State *L) { gxl_write_args(L, 2, 0); lua_settop(L, 1); return 1; }   // io.stdout:write(...)
static int gxl_l_errwrite(lua_State *L) { gxl_write_args(L, 2, 1); lua_settop(L, 1); return 1; }   // io.stderr:write(...)
static int gxl_l_noop(lua_State *L) { lua_settop(L, 1); return 1; }

/* ---------- ввод (из поля «Ввод» в GX Files) ---------- */
static int gxl_read_line(lua_State *L, gxl *g, int keep_nl) {
    if (g->inpos >= g->inlen) { lua_pushnil(L); return 0; }
    size_t s = g->inpos;
    while (g->inpos < g->inlen && g->in[g->inpos] != '\n') g->inpos++;
    size_t e = g->inpos;
    if (g->inpos < g->inlen) { g->inpos++; if (keep_nl) e++; }
    size_t len = e - s;
    if (!keep_nl && len && g->in[s + len - 1] == '\r') len--;
    lua_pushlstring(L, g->in + s, len);
    return 1;
}
static int gxl_read_number(lua_State *L, gxl *g) {
    while (g->inpos < g->inlen && strchr(" \t\r\n", g->in[g->inpos])) g->inpos++;
    char buf[201]; size_t k = 0;
    while (g->inpos < g->inlen && k < 200 && !strchr(" \t\r\n", g->in[g->inpos])) buf[k++] = g->in[g->inpos++];
    buf[k] = 0;
    if (k && lua_stringtonumber(L, buf)) return 1;
    lua_pushnil(L); return 0;
}
static int gxl_do_read(lua_State *L, int first) {
    gxl *g = gxl_G(L); int n = lua_gettop(L), pushed = 0;
    if (n < first) return gxl_read_line(L, g, 0);
    for (int i = first; i <= n; i++) {
        int ok;
        if (lua_type(L, i) == LUA_TNUMBER) {
            size_t k = (size_t)luaL_checkinteger(L, i), rem = g->inlen - g->inpos;
            if (k > rem) k = rem;
            if (!k && rem == 0) { lua_pushnil(L); ok = 0; }
            else { lua_pushlstring(L, g->in + g->inpos, k); g->inpos += k; ok = 1; }
        } else {
            const char *f = luaL_checkstring(L, i);
            if (*f == '*') f++;
            switch (*f) {
                case 'l': ok = gxl_read_line(L, g, 0); break;
                case 'L': ok = gxl_read_line(L, g, 1); break;
                case 'n': ok = gxl_read_number(L, g); break;
                case 'a': lua_pushlstring(L, g->in + g->inpos, g->inlen - g->inpos); g->inpos = g->inlen; ok = 1; break;
                default: return luaL_argerror(L, i, "invalid format");
            }
        }
        pushed++;
        if (!ok) break;
    }
    return pushed;
}
static int gxl_l_ioread(lua_State *L) { return gxl_do_read(L, 1); }
static int gxl_l_inread(lua_State *L) { return gxl_do_read(L, 2); }   // io.stdin:read(...)
static int gxl_lines_iter(lua_State *L) { return gxl_read_line(L, gxl_G(L), 0); }
static int gxl_l_iolines(lua_State *L) {
    if (lua_gettop(L) == 0) { lua_pushcfunction(L, gxl_lines_iter); return 1; }   // io.lines() — по строкам ввода
    lua_pushvalue(L, lua_upvalueindex(1)); lua_insert(L, 1);                    // io.lines("файл") — как обычно
    lua_call(L, lua_gettop(L) - 1, LUA_MULTRET);
    return lua_gettop(L);
}
static int gxl_l_inlines(lua_State *L) { lua_pushcfunction(L, gxl_lines_iter); return 1; }

/* ---------- os.exit не должен закрывать GX Files ---------- */
static int gxl_l_exit(lua_State *L) {
    gxl *g = gxl_G(L);
    g->exited = 1;
    g->exitcode = lua_isboolean(L, 1) ? !lua_toboolean(L, 1) : (int)luaL_optinteger(L, 1, 0);
    lua_pushstring(L, GX_EXIT_MARK);
    return lua_error(L);
}

/* ---------- лимит времени и «стоп» ---------- */
static void gxl_hook(lua_State *L, lua_Debug *ar) {
    (void)ar; gxl *g = gxl_G(L);
    if (g->cancel && *g->cancel) { g->cancelled = 1; luaL_error(L, "%s", GXT("остановлено")); }
    if (g->deadline > 0 && gxl_now_s() > g->deadline) { g->timedout = 1; luaL_error(L, "%s", GXT("превышен лимит времени")); }
}

static void gxl_handle(lua_State *L, const char *name, lua_CFunction writer, lua_CFunction reader, lua_CFunction lines) {
    lua_newtable(L);
    if (writer) { lua_pushcfunction(L, writer); lua_setfield(L, -2, "write"); }
    if (reader) { lua_pushcfunction(L, reader); lua_setfield(L, -2, "read"); }
    if (lines)  { lua_pushcfunction(L, lines);  lua_setfield(L, -2, "lines"); }
    lua_pushcfunction(L, gxl_l_noop); lua_setfield(L, -2, "flush");
    lua_pushcfunction(L, gxl_l_noop); lua_setfield(L, -2, "setvbuf");
    lua_pushcfunction(L, gxl_l_noop); lua_setfield(L, -2, "close");
    lua_setfield(L, -2, name);
}

const char *gx_lua_version(void) { return LUA_RELEASE; }

int gx_lua_run(const char *code, const char *chunkname, const char *stdin_text,
               gx_lua_out_fn out, void *ctx, double timeout, volatile int *cancel,
               char *err, size_t errlen) {
    if (err && errlen) err[0] = 0;
    gxl g; memset(&g, 0, sizeof g);
    g.out = out; g.ctx = ctx; g.cancel = cancel;
    g.in = stdin_text ? stdin_text : ""; g.inlen = strlen(g.in);
    g.deadline = timeout > 0 ? gxl_now_s() + timeout : 0;

    lua_State *L = luaL_newstate();
    if (!L) { if (err) snprintf(err, errlen, "%s", GXT("не хватает памяти")); return 1; }
    *(gxl **)lua_getextraspace(L) = &g;
    luaL_openlibs(L);

    lua_register(L, "print", gxl_l_print);
    lua_getglobal(L, "io");
    lua_pushcfunction(L, gxl_l_iowrite); lua_setfield(L, -2, "write");
    lua_pushcfunction(L, gxl_l_ioread);  lua_setfield(L, -2, "read");
    lua_getfield(L, -1, "lines"); lua_pushcclosure(L, gxl_l_iolines, 1); lua_setfield(L, -2, "lines");
    gxl_handle(L, "stdout", gxl_l_outwrite, NULL, NULL);
    gxl_handle(L, "stderr", gxl_l_errwrite, NULL, NULL);
    gxl_handle(L, "stdin", NULL, gxl_l_inread, gxl_l_inlines);
    lua_pop(L, 1);
    lua_getglobal(L, "os");
    lua_pushcfunction(L, gxl_l_exit); lua_setfield(L, -2, "exit");
    lua_pop(L, 1);
    lua_sethook(L, gxl_hook, LUA_MASKCOUNT, 20000);

    char cn[256]; snprintf(cn, sizeof cn, "=%s", chunkname && *chunkname ? chunkname : "main.lua");
    int rc = luaL_loadbufferx(L, code, strlen(code), cn, "t");
    if (rc == LUA_OK) rc = lua_pcall(L, 0, 0, 0);
    int result = 0;
    if (rc != LUA_OK) {
        const char *m = lua_tostring(L, -1);
        if (g.exited && m && strcmp(m, GX_EXIT_MARK) == 0) {
            if (g.exitcode != 0) { result = 1; if (err) snprintf(err, errlen, GXT("программа завершилась с кодом %d"), g.exitcode); }
        } else {
            result = 1;
            if (err) snprintf(err, errlen, "%s", m ? m : "error");
        }
    }
    lua_close(L);
    return result;
}

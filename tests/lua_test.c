// Тест встроенного Lua: вывод, ввод, ошибки, лимит времени, os.exit.
#include "core/gx_lua.h"
#include <stdio.h>
#include <string.h>
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static char buf[8192]; static size_t blen;
static void out(void *ctx, const char *s, size_t n, int e) { (void)ctx; if (e) { memcpy(buf + blen, "[E]", 3); blen += 3; } memcpy(buf + blen, s, n); blen += n; buf[blen] = 0; }
static int run(const char *code, const char *in, double t, char *err) { blen = 0; buf[0] = 0; return gx_lua_run(code, "main.lua", in, out, 0, t, 0, err, 256); }
int main(void) {
    char err[256];
    CHECK(run("print('Hello', 42, nil, true)", 0, 5, err) == 0 && !strcmp(buf, "Hello\t42\tnil\ttrue\n"), "print: [%s]", buf);
    CHECK(run("io.write('a', 1, 'b'); io.write('\\n'); io.stdout:write('x'):write('y')", 0, 5, err) == 0 && !strcmp(buf, "a1b\nxy"), "io.write: [%s] %s", buf, err);
    CHECK(run("local n = io.read('n'); local s = io.read(); local l = io.read('l'); print(n * 2, s, l)", "21 rest\nВася\n", 5, err) == 0
          && !strcmp(buf, "42\t rest\tВася\n"), "io.read: [%s] %s", buf, err);
    CHECK(run("for line in io.lines() do io.write('<', line, '>') end", "a\nb\r\nc", 5, err) == 0 && !strcmp(buf, "<a><b><c>"), "io.lines: [%s] %s", buf, err);
    CHECK(run("io.stderr:write('oops')", 0, 5, err) == 0 && !strcmp(buf, "[E]oops"), "stderr: [%s]", buf);
    CHECK(run("local x = 1\nlocal y = nil + x\n", 0, 5, err) == 1 && strstr(err, "main.lua:2:"), "error line: %s", err);
    CHECK(run("print('a'", 0, 5, err) == 1 && strstr(err, "main.lua:1:"), "syntax error: %s", err);
    CHECK(run("while true do end", 0, 0.3, err) == 1 && strstr(err, "лимит"), "timeout: %s", err);
    CHECK(run("print('bye'); os.exit(0); print('no')", 0, 5, err) == 0 && !strcmp(buf, "bye\n"), "exit0: [%s] %s", buf, err);
    CHECK(run("os.exit(3)", 0, 5, err) == 1 && strstr(err, "3"), "exit3: %s", err);
    CHECK(run("print(string.format('%.2f', math.pi), #('привет'), utf8.len('привет'))", 0, 5, err) == 0 && !strcmp(buf, "3.14\t12\t6\n"), "stdlib: [%s]", buf);
    printf("lua test (%s): %s (%d failed)\n", gx_lua_version(), fails ? "FAILED" : "all passed", fails);
    return fails ? 1 : 0;
}

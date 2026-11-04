// Эмулятор ARM64 для изучения функций своих бинарников: пошаговое выполнение в песочнице.
// Память — сегменты файла (только чтение) + слой записанных страниц + стек. Файл не меняется.
#pragma once
#include "gx_bin.h"

enum { GX_EMU_OK = 0, GX_EMU_RETURNED = 1, GX_EMU_STOPPED = 2, GX_EMU_EXTCALL = 3 };

typedef struct { uint64_t addr, val; uint8_t size, write; } gx_emu_mem;

typedef union { uint64_t d[2]; uint32_t w[4]; float s[4]; double f[2]; uint8_t b[16]; } gx_vreg;

typedef struct gx_emu {
    uint64_t x[32];            // x[31] — SP
    uint64_t pc;
    uint32_t nzcv;             // биты N=8 Z=4 C=2 V=1
    gx_vreg v[32];
    uint64_t steps;
    int skip_ext;              // внешние вызовы: 0 — остановиться, 1 — пропустить и вернуть 0
    char reason[256];          // почему остановились / что сделал последний шаг
    gx_emu_mem mem[8]; int nmem;   // обращения к памяти на последнем шаге
    // внутреннее
    const gx_bin *b;
    void *pages;
    const char *handles[256]; int nhandles;
} gx_emu;

#define GX_EMU_RET_MAGIC 0x00000000DEAD0000ull
#define GX_EMU_STACK_TOP 0x00007FF000000000ull
#define GX_EMU_STACK_SIZE (1u << 20)

gx_emu *gx_emu_new(const gx_bin *b, uint64_t entry);
void gx_emu_free(gx_emu *e);
int gx_emu_step(gx_emu *e);                                  // один шаг
int gx_emu_run(gx_emu *e, uint64_t max_steps);               // до возврата / остановки / лимита
void gx_emu_return_from_call(gx_emu *e, uint64_t x0);        // выйти из внешнего вызова: x0 = значение, pc = lr
int gx_emu_read(gx_emu *e, uint64_t addr, void *out, size_t n);        // 1 — прочитано
int gx_emu_write(gx_emu *e, uint64_t addr, const void *in, size_t n);  // 1 — записано

// Дизассемблер ARM64 (основные инструкции) и помощники для патчей
#pragma once
#include <stdint.h>
#include <stddef.h>

enum { GX_A64_NONE = 0, GX_A64_BRANCH = 1, GX_A64_CALL = 2, GX_A64_COND = 3, GX_A64_ADRP = 4, GX_A64_ADR = 5, GX_A64_LIT = 6, GX_A64_RET = 7 };

// Разобрать инструкцию: текст в out. *target — адрес перехода/адреса (если есть), возвращает GX_A64_*
int gx_a64_dis(uint32_t ins, uint64_t pc, char *out, size_t n, uint64_t *target);

// ADRP: страница; ADD imm (Rd, Rn, imm); LDR/STR unsigned imm (Rt, Rn, byte offset). 1 = подходит
int gx_a64_is_adrp(uint32_t ins, uint64_t pc, int *rd, uint64_t *page);
int gx_a64_is_addimm(uint32_t ins, int *rd, int *rn, uint64_t *imm);
int gx_a64_is_ldst_uimm(uint32_t ins, int *rt, int *rn, uint64_t *off);

// Константы в коде: MOVZ/MOVN (целое) 1, FMOV imm 2, MOV верх float 3, CMP/CMN imm 4
int gx_a64_const(uint32_t ins, int *kind, double *value, int *is64);
// Заменить константу в инструкции. 1 = получилось (иначе значение невыразимо этой инструкцией)
int gx_a64_set_const(uint32_t *ins, int kind, double value);

// Готовые шаблоны (пишут до 5 слов в out, возвращают число слов)
int gx_a64_tpl_ret_int(int64_t v, int wide, uint32_t *out);
int gx_a64_tpl_ret_float(float f, uint32_t *out);
int gx_a64_tpl_ret_double(double f, uint32_t *out);
#define GX_A64_NOP 0xD503201Fu
#define GX_A64_RETI 0xD65F03C0u
// Кодировать B/BL на target
int gx_a64_enc_branch(uint64_t pc, uint64_t target, int link, uint32_t *out);

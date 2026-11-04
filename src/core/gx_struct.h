// Структурирование псевдокода: goto/метки → if/else/while, с безопасным откатом к goto.
#pragma once
#include <stdint.h>

// Принимает тело функции (строки с отступом 4 пробела, метки loc_x:, goto/if()goto/return).
// Возвращает malloc-строку со структурированным телом. При любой неоднозначности
// соответствующий goto сохраняется — смысл кода не меняется.
char *gx_structure(const char *body);

// Полный текст из gx_pseudo → с структурированным телом. NULL, если тело выделить не удалось.
char *gx_pseudo_structure(const char *full);

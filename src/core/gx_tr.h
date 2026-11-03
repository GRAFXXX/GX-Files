// Перевод строк C-ядра. GXT("текст") → перевод на текущий язык (или сам текст)
#pragma once
const char *gx_tr(const char *s) __attribute__((format_arg(1)));
#define GXT(s) gx_tr(s)

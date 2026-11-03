#include "gx_tr.h"
// По умолчанию (тесты, сборка без интерфейса) — без перевода. Приложение подменяет своей версией в GXLang.m
__attribute__((weak)) const char *gx_tr(const char *s) { return s; }

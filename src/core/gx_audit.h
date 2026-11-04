// Статический аудит безопасности (SAST) бинарника. Только чтение.
#pragma once
#include "gx_bin.h"

enum {
    GX_SAST_UNSAFE_STR = 0,   // strcpy/strcat/sprintf/gets/scanf — переполнение буфера
    GX_SAST_SYSTEM,           // system/popen/exec — выполнение команд
    GX_SAST_WEAKHASH,         // MD5/SHA1 — слабый хеш
    GX_SAST_WEAKCIPHER,       // DES/RC4 — слабый шифр
    GX_SAST_RANDOM,           // rand/random — непригоден для безопасности
    GX_SAST_ATS,              // отключённая защита транспорта / проверки сертификатов
};

typedef struct {
    uint64_t site;      // адрес вызова (0 — для строковых находок)
    uint64_t func;      // адрес функции, где находка (0 — неизвестно)
    const char *name;   // имя вызываемой функции или строки (указывает внутрь bin — живёт, пока открыт bin)
    int cat;            // GX_SAST_*
    int sev;            // 0 — заметка, 1 — средняя, 2 — высокая
} gx_sast;

// Находит проблемы в бинарнике. *out — malloc-массив (освобождает вызывающий). Возвращает число находок.
int gx_audit(const gx_bin *b, gx_sast **out);

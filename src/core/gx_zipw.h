// Перезапись zip/apk/ipa «на месте»: замена, добавление, удаление и переименование записей без распаковки остального.
// Неизменённые записи копируются как есть (без пересжатия). Старая APK-подпись v2+ отбрасывается.
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    const char *name;      // существующая запись (или новая — при добавлении)
    const char *new_name;  // переименовать (может быть NULL)
    const char *src_path;  // заменить/добавить содержимым файла (NULL — без изменения содержимого)
    const void *src_data;  // либо из памяти
    size_t src_len;
    int del;               // удалить запись
} gxzw_op;

enum { GXZW_ALIGN_NONE = 0, GXZW_ALIGN_APK = 1 };

// Пишет новый архив в out_path (in_path не трогает). Возвращает 1 при успехе.
int gxzw_rewrite(const char *in_path, const char *out_path, const gxzw_op *ops, size_t nops, int align,
                 char *err, size_t errlen, volatile int *cancel, void (*progress)(double, void *), void *pctx);

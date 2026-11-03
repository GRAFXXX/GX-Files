// Дамп классов Objective-C из метаданных Mach-O (как class-dump): заголовки .h, методы с адресами реализаций
#pragma once
#include "gx_bin.h"

typedef struct { char *name; uint64_t imp; int cls_method; char *proto; int retkind; } gx_objc_m;   // name: "-[Class sel:]"; proto: "- (void)sel:(id)a1"; retkind: 1 void, 2 float, 3 значение
typedef struct { char *name; uint64_t slot; uint32_t off; } gx_objc_iv;   // slot — адрес переменной-смещения (OBJC_IVAR_$)
typedef struct { char *name; char *header; gx_objc_m *m; int nm; int is_cat; uint64_t addr; gx_objc_iv *iv; int niv; } gx_objc_cls;

// 1 = ок (классов может быть 0). Всё — malloc, освобождать gx_objc_free
int gx_objc_dump(const gx_bin *b, gx_objc_cls **out, int *n);
void gx_objc_free(gx_objc_cls *c, int n);
// Расшифровать кодировку типа ObjC (например "@\"NSString\"" → "NSString *")
void gx_objc_type(const char *enc, char *out, size_t n);

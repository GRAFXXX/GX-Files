// Разбор бинарников для редактора: Mach-O 64 (thin/fat), ELF64 (Android .so), иначе «сырой» файл.
// Строки (UTF-8 / UTF-16 / CP1251), функции, импорты, ссылки (xrefs), поиск чисел, правка CFString, ad-hoc подпись.
#pragma once
#include <stdint.h>
#include <stddef.h>

enum { GX_SK_NORMAL = 0, GX_SK_CSTRING = 1, GX_SK_USTRING = 2, GX_SK_ZERO = 3, GX_SK_CFSTRING = 4, GX_SK_SKIP = 5 };

typedef struct { char name[40]; uint64_t addr, size; size_t off; uint8_t exec, kind; } gx_sect;
typedef struct { uint64_t vm, vmsize; size_t off, fsize; } gx_seg;
typedef struct { uint64_t addr; const char *name; uint32_t nlen; } gx_name;

typedef struct {
    const uint8_t *d; size_t len;      // весь файл
    size_t base, slen;                 // текущий срез
    int fmt;                           // 0 сырой, 1 Mach-O 64, 2 ELF64
    int arm64;
    char arch[24], type[40];
    gx_sect *s; int ns;
    gx_seg *seg; int nseg;
    gx_name *fn; size_t nfn;           // функции (по возрастанию адреса); name == NULL — без имени
    gx_name *imp; size_t nimp;         // заглушки/PLT/GOT → имя импорта
    uint64_t vmlo, vmhi, image_base;
    size_t sig_off, sig_size;          // LC_CODE_SIGNATURE (абсолютные)
    int encrypted;                     // LC_ENCRYPTION_INFO cryptid != 0
    // привязки к внешним символам
    int chain_fmt;                     // формат указателей chained fixups (0 — старый формат)
    const uint8_t *ch_imports, *ch_syms; uint32_t ch_nimports, ch_impfmt; size_t ch_symsize;
    gx_name *bind; size_t nbind;       // старый формат: адрес слота → символ (по возрастанию)
} gx_bin;

// Срезы fat-файла: имена и смещения. Возвращает количество (1 для thin/ELF/сырого)
int gx_bin_slices(const uint8_t *d, size_t len, char names[][24], size_t *offs, size_t *sizes, int max);
int gx_bin_open(gx_bin *b, const uint8_t *d, size_t len, int slice);
void gx_bin_close(gx_bin *b);

int64_t gx_bin_a2o(const gx_bin *b, uint64_t addr);          // адрес → абсолютное смещение в файле, -1
int gx_bin_o2a(const gx_bin *b, size_t off, uint64_t *addr);  // смещение → адрес
int gx_bin_sect_of_off(const gx_bin *b, size_t off);          // индекс секции или -1
int gx_bin_sect_of_addr(const gx_bin *b, uint64_t addr);
const gx_name *gx_bin_func_of(const gx_bin *b, uint64_t addr); // функция, содержащая адрес
const gx_name *gx_bin_import_at(const gx_bin *b, uint64_t addr);
uint64_t gx_bin_func_end(const gx_bin *b, uint64_t addr);     // начало следующей функции / конец секции

// Прочитать указатель по адресу: 1 — внутренний (*target), 2 — внешний символ (*name/*nlen), 0 — нет
int gx_bin_ptr_at(const gx_bin *b, uint64_t addr, uint64_t *target, const char **name, uint32_t *nlen);
// Описание адреса для комментариев/псевдокода: "строка", @"NSString", @selector(x), класс, импорт. 1 = есть
int gx_bin_describe(const gx_bin *b, uint64_t addr, char *out, size_t n);
// Имя класса Objective-C по адресу структуры класса. 1 = найдено
int gx_bin_objc_class_name(const gx_bin *b, uint64_t cls, const char **name, uint32_t *nl);
// Секция по имени (например "__objc_classlist"), -1
int gx_bin_sect_named(const gx_bin *b, const char *sectname);

enum { GX_ENC_UTF8 = 0, GX_ENC_UTF16 = 1, GX_ENC_CP1251 = 2 };
typedef struct { size_t off; uint32_t blen; uint8_t enc, cf; int16_t sect; } gx_str;
// Все строки (malloc). minlen — минимум символов для обычных секций
int gx_bin_strings(const gx_bin *b, int minlen, gx_str **out, size_t *n);

// Записи __cfstring, указывающие на addr: смещения поля длины (абсолютные). Возвращает количество
int gx_bin_cfstring_lens(const gx_bin *b, uint64_t addr, size_t *len_offs, uint64_t *entry_addrs, int max);

typedef struct { uint64_t from; uint8_t code; uint8_t kind; uint64_t adrp; } gx_xref;   // kind: 1 ADRP+ADD, 2 ADRP+LDR/STR, 3 ADR/переход/литерал, 0 данные; adrp — адрес ADRP
// Ссылки на диапазон [lo, hi): ADRP+ADD/LDR, ADR, LDR literal, B/BL, указатели в данных. malloc
int gx_bin_xrefs(const gx_bin *b, uint64_t lo, uint64_t hi, gx_xref **out, size_t *n, size_t max);

enum { GX_NT_I32 = 0, GX_NT_I64 = 1, GX_NT_F32 = 2, GX_NT_F64 = 3, GX_NT_I16 = 4, GX_NT_I8 = 5 };
typedef struct { size_t off; uint8_t kind; } gx_numhit;   // kind: 0 данные, 1 MOVZ/MOVN, 2 FMOV imm, 3 MOV (верх float), 4 CMP imm
int gx_bin_find_num(const gx_bin *b, int type, double v, int in_code, gx_numhit **out, size_t *n, size_t max);

// Ad-hoc переподпись всех 64-битных срезов (сохраняет entitlements). Новый буфер (malloc) или NULL.
// *signed_slices — сколько срезов подписано (0 — подписи не было, буфер — копия)
uint8_t *gx_adhoc_sign(const uint8_t *d, size_t len, const char *ident, uint32_t flags, size_t *outlen, int *signed_slices, char *err, size_t errlen);

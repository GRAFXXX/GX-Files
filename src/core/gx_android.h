// Разбор бинарных форматов Android: AXML (AndroidManifest.xml и res/*.xml) и resources.arsc.
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    const uint8_t *base;     // начало чанка пула
    size_t len;
    uint32_t count;
    int utf8;
    const uint8_t *offs;
    const uint8_t *strs;
    size_t strs_len;
    char **cache;
} gxa_pool;

const char *gxa_pool_get(gxa_pool *p, uint32_t idx); // "" если нет

enum {
    GXA_T_NULL = 0x00, GXA_T_REF = 0x01, GXA_T_ATTR = 0x02, GXA_T_STRING = 0x03, GXA_T_FLOAT = 0x04,
    GXA_T_DIMEN = 0x05, GXA_T_FRACTION = 0x06, GXA_T_DYN_REF = 0x07, GXA_T_INT_DEC = 0x10, GXA_T_INT_HEX = 0x11,
    GXA_T_BOOL = 0x12, GXA_T_COLOR_ARGB8 = 0x1c, GXA_T_COLOR_RGB8 = 0x1d, GXA_T_COLOR_ARGB4 = 0x1e, GXA_T_COLOR_RGB4 = 0x1f
};

typedef struct {
    const char *ns;
    const char *name;
    uint32_t resid;
    uint8_t type;
    uint32_t data;
    const char *str;      // строковое значение (raw или string)
} gxa_attr;

typedef struct {
    int depth;
    const char *name;
    int nattr;
    gxa_attr *attr;
    int closed_at;        // индекс в списке событий (для текста)
} gxa_elem;

typedef struct {
    gxa_pool pool;
    const uint32_t *resmap;
    size_t nres;
    gxa_elem *el;
    size_t nel;
    // события для текста: >=0 — открытие элемента i, <0 — закрытие элемента (-i-1)
    int *ev;
    size_t nev;
    uint8_t *copy;
    size_t copy_len;
    char *ns_prefix_uri[16];
    char *ns_prefix_name[16];
    int nns;
} gxa_xml;

int  gxa_xml_parse(gxa_xml *x, const uint8_t *d, size_t len); // 1 = ок
void gxa_xml_free(gxa_xml *x);
const gxa_attr *gxa_find_attr(const gxa_elem *e, const char *name, uint32_t resid);

typedef struct gxa_arsc gxa_arsc;

typedef struct {
    uint8_t type;
    uint32_t data;
    const char *str;    // для строк — значение, для файлов — путь
    uint16_t density;
    char lang[4];
    char region[4];
    int version;        // sdkVersion из конфигурации
    int night;          // 1 если ночная тема
} gxa_value;

gxa_arsc *gxa_arsc_parse(const uint8_t *d, size_t len);
void gxa_arsc_free(gxa_arsc *a);
// Все значения ресурса во всех конфигурациях (ссылки не разворачивает). Возвращает количество.
int  gxa_arsc_values(gxa_arsc *a, uint32_t id, gxa_value *out, int max);
// Имя ресурса вида "@mipmap/ic_launcher" в buf
const char *gxa_arsc_name(gxa_arsc *a, uint32_t id, char *buf, size_t n);

// Человекочитаемый XML (с разворачиванием @ссылок, если a != NULL). malloc.
char *gxa_xml_to_text(gxa_xml *x, gxa_arsc *a);
// Формат значения атрибута в buf
const char *gxa_format_value(uint8_t type, uint32_t data, const char *str, gxa_arsc *a, char *buf, size_t n);

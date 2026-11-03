#!/usr/bin/env python3
"""GX Files i18n: оборачивает русские строки в GXL(@"…") (Objective-C) и GXT("…") (C),
собирает их в tools/i18n/source.tsv (id<TAB>текст). Повторный запуск безопасен.
Строка кода с комментарием `noi18n` не трогается.
  python3 tools/i18n/wrap.py          — обернуть и обновить source.tsv
  python3 tools/i18n/wrap.py --check  — только собрать список (ничего не менять)
"""
import re, sys, os, glob
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CYR = re.compile('[А-Яа-яЁё]')
check = '--check' in sys.argv

def unescape(body):
    # значение литерала как ключ: оставляем escape-последовательности как в исходнике
    return body

def scan(src, objc):
    """Возвращает список (start, end, kind, value): kind 'objc' для @"…", 'c' для "…"; уже обёрнутые пропускаются."""
    out = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; continue
        if c == '#' and (i == 0 or src[i-1] == '\n' or src[src.rfind('\n', 0, i)+1:i].strip() == ''):
            # директива препроцессора — до конца строки (с переносами \)
            j = i
            while True:
                k = src.find('\n', j)
                if k < 0: j = n; break
                if src[k-1] == '\\': j = k + 1; continue
                j = k; break
            i = j; continue
        if c == "'":
            j = i + 1
            while j < n and src[j] != "'":
                j += 2 if src[j] == '\\' else 1
            i = j + 1; continue
        if c == '"' or (c == '@' and i + 1 < n and src[i+1] == '"'):
            # серия соседних литералов
            start = i; parts = []; kind = 'objc' if c == '@' else 'c'
            j = i
            while True:
                if src[j] == '@': j += 1
                k = j + 1; buf = []
                while k < n and src[k] != '"':
                    if src[k] == '\\': buf.append(src[k:k+2]); k += 2
                    else: buf.append(src[k]); k += 1
                parts.append(''.join(buf)); end = k + 1
                m = re.match(r'\s*@?"', src[end:])
                if m and not src[end:end+m.end()].count('\n') > 3:
                    # между литералами не должно быть комментариев — достаточно пробелов
                    j = end + m.end() - 1
                    if src[j-1] == '@': j -= 1
                    continue
                break
            val = ''.join(parts)
            pre = src[max(0, start-5):start]
            wrapped = pre.endswith('GXL(') or pre.endswith('GXT(')
            line_s = src.rfind('\n', 0, start) + 1; line_e = src.find('\n', end); line_e = n if line_e < 0 else line_e
            skip = 'noi18n' in src[line_s:line_e]
            if CYR.search(val) and (wrapped or not skip):
                out.append((start, end, kind, val, wrapped))
            i = end; continue
        i += 1
    return out

files = sorted(glob.glob(os.path.join(ROOT, 'src', '*.m')) + glob.glob(os.path.join(ROOT, 'src', 'core', '*.c')))
order = []; seen = set()
for f in files:
    src = open(f, encoding='utf-8').read()
    objc = f.endswith('.m')
    hits = scan(src, objc)
    for (s, e, kind, val, wrapped) in hits:
        if val not in seen: seen.add(val); order.append(val)
    if check: continue
    res = []; last = 0; changed = 0
    for (s, e, kind, val, wrapped) in hits:
        if wrapped: continue
        res.append(src[last:s])
        res.append(('GXL(' if kind == 'objc' else 'GXT(') + src[s:e] + ')')
        last = e; changed += 1
    res.append(src[last:])
    if changed:
        new = ''.join(res)
        if f.endswith('.c') and '#include "gx_tr.h"' not in new:
            new = '#include "gx_tr.h"\n' + new
        open(f, 'w', encoding='utf-8').write(new)
        print(f'{os.path.relpath(f, ROOT)}: обёрнуто {changed}')

# стабильные id: существующие сохраняются, новые добавляются в конец
tsv = os.path.join(ROOT, 'tools', 'i18n', 'source.tsv')
ids = {}; maxid = 0
if os.path.exists(tsv):
    for line in open(tsv, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#'): continue
        k, v = line.split('\t', 1); ids[v] = int(k); maxid = max(maxid, int(k))
for v in order:
    if v not in ids: maxid += 1; ids[v] = maxid
live = set(order)
with open(tsv, 'w', encoding='utf-8') as fo:
    fo.write('# id<TAB>русский текст (ключ). Формат строк (%@, %d, \\n) обязан сохраниться в переводах\n')
    for v, k in sorted(ids.items(), key=lambda x: x[1]):
        if v in live: fo.write(f'{k}\t{v}\n')
print(f'строк: {len(order)} → {os.path.relpath(tsv, ROOT)}')

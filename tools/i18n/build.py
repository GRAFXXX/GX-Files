#!/usr/bin/env python3
"""Собирает переводы i18n/<код>.tsv (id<TAB>перевод) в <выход>/<код>.json ({"русский": "перевод"}).
Проверяет, что форматные спецификаторы (%@, %d, %.1f…) совпадают с оригиналом.
  python3 tools/i18n/build.py <папка-выхода>      — собрать
  python3 tools/i18n/build.py --stats             — сколько переведено в каждом языке
"""
import re, sys, os, json, glob
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC = re.compile(r'%(?:%|[-+#0]*\d*(?:\.\d+)?(?:hh|h|ll|l|z|j|t|L|q)?[@diouxXeEfgGcspaA])')

def unesc(s):
    out = []; i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            c = s[i+1]; out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", 'r': '\r'}.get(c, '\\' + c)); i += 2
        else: out.append(s[i]); i += 1
    return ''.join(out)

def read_tsv(p):
    d = {}
    for n, line in enumerate(open(p, encoding='utf-8'), 1):
        line = line.rstrip('\n')
        if not line.strip() or line.startswith('#'): continue
        sep = '\t' if '\t' in line else '|'
        if sep not in line: print(f'{p}:{n}: нет разделителя'); continue
        k, v = line.split(sep, 1)
        try: d[int(k)] = v
        except ValueError: print(f'{p}:{n}: плохой id')
    return d

src = read_tsv(os.path.join(ROOT, 'tools', 'i18n', 'source.tsv'))
bad = 0; stats = []
outdir = None if '--stats' in sys.argv else (sys.argv[1] if len(sys.argv) > 1 else None)
for p in sorted(glob.glob(os.path.join(ROOT, 'i18n', '*.tsv'))):
    code = os.path.basename(p)[:-4]
    tr = read_tsv(p); res = {}
    for k, v in tr.items():
        if k not in src: continue
        if SPEC.findall(src[k]) != SPEC.findall(v):
            print(f'{code} #{k}: спецификаторы {SPEC.findall(src[k])} ≠ {SPEC.findall(v)}'); bad += 1; continue
        res[unesc(src[k])] = unesc(v)
    stats.append((code, len(res)))
    if outdir:
        os.makedirs(outdir, exist_ok=True)
        json.dump(res, open(os.path.join(outdir, code + '.json'), 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
for code, n in stats: print(f'{code}: {n}/{len(src)} ({100*n//max(1,len(src))}%)')
sys.exit(1 if bad and '--strict' in sys.argv else 0)

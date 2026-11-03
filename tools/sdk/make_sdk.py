#!/usr/bin/env python3
"""Собирает tcc/res/sdk (заголовки + сжатые .tbd) для встроенного компилятора из iPhoneOS SDK.
Файлы Apple SDK не хранятся в репозитории (лицензия Apple), поэтому их нужно сгенерировать:
    python3 tools/sdk/make_sdk.py /путь/к/iPhoneOS.sdk
На macOS путь даёт:  xcrun --sdk iphoneos --show-sdk-path
"""
import json, os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if len(sys.argv) < 2: sys.exit(__doc__)
SDK = sys.argv[1]
OUT = os.path.join(ROOT, 'tcc', 'res', 'sdk')
meta = json.load(open(os.path.join(ROOT, 'tools', 'sdk', 'sdk_files.json'), encoding='utf-8'))

# 1. заголовки (+ защита блоков ^ через #ifdef __BLOCKS__ — TinyCC их не понимает)
def guard_blocks(lines):
    """Оборачивает объявления с блоками (^) в #ifdef __BLOCKS__ — запасной путь для незнакомой версии SDK."""
    spans, start, buf, in_c, btypes = [], None, '', False, set()
    for i, ln in enumerate(lines):
        st = ln.strip()
        if in_c:
            if '*/' in st: in_c = False
            continue
        if start is None:
            if not st or st.startswith('#') or st.startswith('//'): continue
            if st.startswith('/*'):
                if '*/' not in st: in_c = True
                continue
            start, buf = i, ''
        code = re.sub(r'/\*.*?\*/|//.*', '', ln)
        buf += ' ' + code
        if st.startswith('#'):                     # препроцессор посреди объявления — не трогаем
            start = None; continue
        if code.rstrip().endswith(';') or code.rstrip().endswith('}'):
            uses = any(re.search(r'\b' + re.escape(t) + r'\b', buf) for t in btypes)
            if ('(^' in buf or '^)' in buf or uses) and buf.count('{') == buf.count('}'):
                spans.append((start, i))
                m = re.search(r'typedef\b.*?\(\s*\^\s*(\w+)\s*\)', buf)   # typedef void (^Name)(…) — тип блока
                if m: btypes.add(m.group(1))
            start = None
    for a, b in reversed(spans):
        lines[b + 1:b + 1] = ['#endif /* __BLOCKS__ */']
        lines[a:a] = ['#ifdef __BLOCKS__ /* GX Files: blocks are clang-only, TinyCC does not support them */']
    return len(spans)

n = 0
for rel, src in meta['headers']:
    p = os.path.join(SDK, src)
    if not os.path.isfile(p): print('нет в SDK:', src); continue
    lines = open(p, encoding='latin-1').read().split('\n')
    ops = meta['insert'].get(rel, [])
    if ops:
        # место вставки ищем по соседним строкам, а не по номеру — в другой версии SDK строки сдвигаются
        pos, cur = [], 0
        for op in ops:
            k = next((i for i in range(max(cur, 1 if op['prev'] is not None else 0), len(lines) + 1)
                      if (op['prev'] is None or lines[i - 1] == op['prev'])
                      and (op['next'] is None or (i < len(lines) and lines[i] == op['next']))), None)
            if k is None: pos = None; break
            pos.append(k); cur = k + 1
        if pos is None:
            k = guard_blocks(lines)
            print('другая версия SDK: %s — защищено объявлений с блоками: %d' % (rel, k))
        else:
            for k, op in sorted(zip(pos, ops), key=lambda x: -x[0]):
                lines[k:k] = op['add']
    elif rel.endswith('.h') and any(('(^' in l or '^)' in l) for l in lines):
        guard_blocks(lines)                     # блоки в других заголовках (в новых SDK их может быть больше)
    dst = os.path.join(OUT, 'include', rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, 'w', encoding='latin-1').write('\n'.join(lines)); n += 1
for rel, target in meta.get('links', []):
    dst = os.path.join(OUT, 'include', rel)
    if os.path.lexists(dst): os.remove(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    os.symlink(target, dst)
print('заголовков:', n)

# 2. сжатые .tbd: install-name + все экспортируемые символы
libs = {
    'libSystem.tbd': 'usr/lib/libSystem.B.tbd', 'libobjc.tbd': 'usr/lib/libobjc.A.tbd',
    'libz.tbd': 'usr/lib/libz.1.tbd', 'libsqlite3.tbd': 'usr/lib/libsqlite3.tbd',
    'Foundation.tbd': 'System/Library/Frameworks/Foundation.framework/Foundation.tbd',
    'CoreFoundation.tbd': 'System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd',
    'UIKit.tbd': 'System/Library/Frameworks/UIKit.framework/UIKit.tbd',
    'CoreGraphics.tbd': 'System/Library/Frameworks/CoreGraphics.framework/CoreGraphics.tbd',
    'QuartzCore.tbd': 'System/Library/Frameworks/QuartzCore.framework/QuartzCore.tbd',
}
def lists(text, key):
    out = []
    for m in re.finditer(r'\b' + key + r':\s*\[(.*?)\]', text, re.S):
        out += [s.strip().strip("'\"") for s in m.group(1).split(',') if s.strip()]
    return out

def parse_tbd(t):
    """install-name и экспортируемые символы; понимает YAML (tbd v2–v4) и JSON (tbd v5)"""
    syms = set()
    if t.lstrip().startswith('{'):
        j = json.loads(t)
        libs = [j.get('main_library', {})] + j.get('libraries', [])
        inst = libs[0]['install_names'][0]['name']
        for lib in libs:
            for ex in lib.get('exported_symbols', []) + lib.get('reexported_symbols', []):
                for part in ('text', 'data'):
                    sec = ex.get(part, {})
                    for k in ('global', 'weak', 'thread_local'): syms |= set(sec.get(k, []))
                    for c in sec.get('objc_class', []): syms |= {'_OBJC_CLASS_$_' + c, '_OBJC_METACLASS_$_' + c}
                    for c in sec.get('objc_eh_type', []): syms.add('_OBJC_EHTYPE_$_' + c)
                    for v in sec.get('objc_ivar', []): syms.add('_OBJC_IVAR_$_' + v)
        return inst, syms
    inst = re.search(r"install-name:\s*'?([^'\n]+)'?", t).group(1).strip()
    syms = set(lists(t, 'symbols')) | set(lists(t, 'weak-symbols')) | set(lists(t, 'thread-local-symbols'))
    for c in lists(t, 'objc-classes'): syms |= {'_OBJC_CLASS_$_' + c, '_OBJC_METACLASS_$_' + c}
    for c in lists(t, 'objc-eh-types'): syms.add('_OBJC_EHTYPE_$_' + c)
    for v in lists(t, 'objc-ivars'): syms.add('_OBJC_IVAR_$_' + v)
    return inst, syms

os.makedirs(os.path.join(OUT, 'lib'), exist_ok=True)
for name, rel in libs.items():
    src = os.path.realpath(os.path.join(SDK, rel))
    if not os.path.isfile(src): print('нет в SDK:', rel); continue
    try:
        inst, syms = parse_tbd(open(src).read())
    except Exception as e:
        print('не разобрать', rel, e); continue
    syms = sorted(s for s in syms if re.fullmatch(r'[A-Za-z0-9_$.]+', s))
    with open(os.path.join(OUT, 'lib', name), 'w') as f:
        f.write("--- !tapi-tbd\ntbd-version: 4\ntargets: [ arm64-ios ]\n")
        f.write("install-name: '%s'\nexports:\n  - targets: [ arm64-ios ]\n    symbols: [ " % inst)
        f.write(",\n                ".join(syms) + " ]\n...\n")
    print('%-20s %6d символов' % (name, len(syms)))

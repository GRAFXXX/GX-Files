import subprocess, os, re, collections
import os
R=os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','res')
inc=R+'/sdk/include'
hdrs=[]
for root,_,files in os.walk(inc):
    for f in files:
        if f.endswith('.h'): hdrs.append(os.path.relpath(os.path.join(root,f),inc))
hits=collections.defaultdict(set); fails={}
for h in sorted(hdrs):
    open('h.c','w').write('#include <%s>\n'%h)
    p=subprocess.run(['clang','-E','-undef','-nostdinc','-Wno-builtin-macro-redefined','-Wno-macro-redefined','-x','c','-include',os.path.join(os.path.dirname(os.path.abspath(__file__)),'prelude.h'),'-isystem',R+'/include','-isystem',inc,'-I',R+'/gx','h.c'],capture_output=True,text=True)
    if p.returncode: fails[h]=[l for l in p.stderr.splitlines() if 'error' in l][:1]
    cur=None; ln=0
    for line in p.stdout.splitlines():
        m=re.match(r'# (\d+) "([^"]+)"',line)
        if m: cur=m.group(2); ln=int(m.group(1)); continue
        if re.search(r'\(\s*\^|\^\s*\)\s*\(',line) and cur: hits[cur].add(ln)
        ln+=1
print('заголовков:',len(hdrs),' не прошли препроцессор:',len(fails))
for h,e in list(fails.items())[:40]: print('  FAIL',h,e[0][-110:] if e else '')
print('файлы с блоками ^ в активном коде:')
for f,lines in sorted(hits.items()): print('  ',os.path.relpath(f,inc) if f.startswith(inc) else f, sorted(lines)[:12])

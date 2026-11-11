#!/bin/bash
# Lua-интерпретатор и шаблоны приложений (C → исполняемый файл iOS).
set -e
CC="${CLANG:-clang}"
TMP="${TMPDIR:-/tmp}/gx_app_test"; rm -rf "$TMP"; mkdir -p "$TMP"

# Lua (своя обёртка: вывод, ввод, ошибки, лимит времени, os.exit)
$CC -w -Isrc tests/lua_test.c src/core/gx_lua.c src/core/gx_tr.c -o "$TMP/luat" -lm
"$TMP/luat"

# SDK для host-tcc
if [ ! -d tcc/res/sdk/include ]; then
  : "${SDK:=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}"
  [ -n "$SDK" ] && python3 tools/sdk/make_sdk.py "$SDK"
fi
$CC -w -DONE_SOURCE=1 -DTCC_TARGET_ARM64 -DTCC_TARGET_MACHO -Itcc/src -c tcc/src/libtcc.c -o "$TMP/libtcc.o"
cat > "$TMP/drv.c" <<'DRV'
#include "libtcc.h"
#include <stdio.h>
static void er(void*o,const char*m){fprintf(stderr,"%s\n",m);}
int main(int ac,char**av){TCCState*s=tcc_new();tcc_set_error_func(s,0,er);tcc_set_lib_path(s,av[1]);
 tcc_set_options(s,"-nostdinc -nostdlib -Wall");tcc_set_output_type(s,TCC_OUTPUT_EXE);
 char p[600];snprintf(p,sizeof p,"%s/include",av[1]);tcc_add_sysinclude_path(s,p);
 snprintf(p,sizeof p,"%s/sdk/include",av[1]);tcc_add_sysinclude_path(s,p);
 snprintf(p,sizeof p,"%s/gx",av[1]);tcc_add_include_path(s,p);
 if(tcc_add_file(s,av[2])<0)return 1;
 const char*libs[]={"libSystem","libobjc","Foundation","UIKit"};
 for(int i=0;i<4;i++){snprintf(p,sizeof p,"%s/sdk/lib/%s.tbd",av[1],libs[i]);if(tcc_add_file(s,p)<0)return 1;}
 return tcc_output_file(s,av[3])<0;}
DRV
$CC -w -Itcc/src "$TMP/drv.c" "$TMP/libtcc.o" -o "$TMP/tcc"
for t in tcc/res/gx/templates/app_*.c; do
  n=$(basename "$t" .c)
  "$TMP/tcc" tcc/res "$t" "$TMP/$n"
  python3 - "$TMP/$n" "$n" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read(); n=sys.argv[2]; bad=[]
ft,=struct.unpack('<I',d[12:16]); fl,=struct.unpack('<I',d[24:28]); nc,=struct.unpack('<I',d[16:20])
if ft!=2: bad.append("filetype %d"%ft)
if not fl&0x200000: bad.append("no PIE")
off=32; lcs=set(); segs=[]
for _ in range(nc):
    c,s=struct.unpack('<II',d[off:off+8]); lcs.add(c)
    if c==0x19:
        nm=d[off+8:off+24].split(b'\0')[0].decode(); vm,vs,fo,fs=struct.unpack('<QQQQ',d[off+24:off+56]); segs.append((nm,vm,vs,fo,fs))
    if c==0x32:
        plat,=struct.unpack('<I',d[off+8:off+12])
        if plat!=2: bad.append("platform %d (не iOS)"%plat)
    off+=s
for need,name in ((0x80000028,"LC_MAIN"),(0xe,"LC_LOAD_DYLINKER"),(0x32,"LC_BUILD_VERSION"),(0x1b,"LC_UUID"),(0x1d,"LC_CODE_SIGNATURE")):
    if need not in lcs: bad.append("нет "+name)
prev=None
for nm,vm,vs,fo,fs in segs:
    if nm not in ("__LINKEDIT","__PAGEZERO") and (vs==0 or vs%0x4000 or fs%0x4000): bad.append("%s vm/file 0x%x/0x%x не кратны 16К или пустой"%(nm,vs,fs))
    if prev and vm < prev[1]+prev[2]: bad.append("%s перекрывает %s"%(nm,prev[0]))
    prev=(nm,vm,vs)
print("app template %-14s: %s"%(n, "ok" if not bad else "FAILED: "+"; ".join(bad)))
sys.exit(1 if bad else 0)
PY
done
echo "app tests: all passed"

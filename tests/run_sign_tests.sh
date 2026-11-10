#!/bin/bash
# Проверка подписи сертификатом: собрать dylib, подписать тестовым сертификатом,
# проверить CodeDirectory и валидность CMS настоящим openssl.
set -e
CC="${CLANG:-clang}"
TMP="${TMPDIR:-/tmp}/gx_sign_test"; rm -rf "$TMP"; mkdir -p "$TMP"
command -v openssl >/dev/null || { echo "нет openssl — пропуск теста подписи"; exit 0; }

# SDK (для компиляции тестового dylib через host-tcc)
if [ ! -d tcc/res/sdk/include ]; then
  : "${SDK:=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}"
  [ -n "$SDK" ] && python3 tools/sdk/make_sdk.py "$SDK"
fi
# тестовый сертификат (эмулирует Apple Dev cert: OU=TEAMID1234)
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 365 -nodes \
    -subj "/CN=iPhone Developer: test/OU=TEAMID1234/O=Test/C=US" 2>/dev/null
openssl x509 -in "$TMP/cert.pem" -outform DER -out "$TMP/cert.der"

# крошечный dylib из встроенного компилятора (host-tcc)
$CC -w -DONE_SOURCE=1 -DTCC_TARGET_ARM64 -DTCC_TARGET_MACHO -Itcc/src -c tcc/src/libtcc.c -o "$TMP/libtcc.o"
cat > "$TMP/drv.c" <<'DRV'
#include "libtcc.h"
#include <stdio.h>
int main(int ac,char**av){TCCState*s=tcc_new();tcc_set_lib_path(s,av[1]);
 tcc_set_options(s,"-nostdinc -nostdlib -install_name @rpath/t.dylib");tcc_set_output_type(s,TCC_OUTPUT_DLL);
 char p[600];snprintf(p,sizeof p,"%s/include",av[1]);tcc_add_sysinclude_path(s,p);
 snprintf(p,sizeof p,"%s/sdk/include",av[1]);tcc_add_sysinclude_path(s,p);
 if(tcc_add_file(s,av[2])<0)return 1;snprintf(p,sizeof p,"%s/sdk/lib/libSystem.tbd",av[1]);
 if(tcc_add_file(s,p)<0)return 1;return tcc_output_file(s,av[3])<0;}
DRV
$CC -w -Itcc/src "$TMP/drv.c" "$TMP/libtcc.o" -o "$TMP/tcc"
echo 'int gx_test(int a,int b){return a+b;}' > "$TMP/t.c"
"$TMP/tcc" tcc/res "$TMP/t.c" "$TMP/in.dylib"

# подписать + базовые проверки
$CC -w -Isrc tests/sign_cert_test.c src/core/gx_csign.c src/core/gx_sha256.c src/core/gx_tr.c -o "$TMP/sign"
"$TMP/sign" "$TMP/in.dylib" "$TMP/cert.der" "$TMP/key.pem" "$TMP/signed.dylib"

# подбор промежуточного Apple WWDR (цепочка leaf -> WWDR -> Apple Root)
$CC -w -Isrc tests/wwdr_test.c src/core/gx_wwdr.c -o "$TMP/wwdr"
"$TMP/wwdr" tests/fixtures/wwdr/*.cer

# извлечь CMS и CodeDirectory, проверить openssl
python3 - "$TMP/signed.dylib" "$TMP" <<'PY'
import sys,struct,hashlib,subprocess
d=open(sys.argv[1],'rb').read(); OUT=sys.argv[2]; fails=0
nc,=struct.unpack('<I',d[16:20]); off=32; sig=None
for _ in range(nc):
    c,s=struct.unpack('<II',d[off:off+8])
    if c==0x1d: sig=struct.unpack('<II',d[off+8:off+16])
    off+=s
so,_=sig; count,=struct.unpack('>I',d[so+8:so+12]); blobs={}
for i in range(count):
    t,o=struct.unpack('>II',d[so+12+i*8:so+20+i*8]); blobs[t]=so+o
cd=blobs[0]; clen,=struct.unpack('>I',d[cd+4:cd+8]); cdb=d[cd:cd+clen]
flags,=struct.unpack('>I',d[cd+12:cd+16])
if flags&2: print("FAIL: ad-hoc flag set"); fails+=1
# codeLimit должен указывать на начало подписи
hashOff,=struct.unpack('>I',d[cd+16:cd+20]); nCode,=struct.unpack('>I',d[cd+28:cd+32]); codeLimit,=struct.unpack('>I',d[cd+32:cd+36])
if codeLimit!=so: print("FAIL: codeLimit 0x%x != sig dataoff 0x%x"%(codeLimit,so)); fails+=1
# хеши страниц обязаны совпадать с байтами файла (иначе AMFI: code signature invalid)
import hashlib as _h
for i in range(nCode):
    hh=_h.sha256(d[i*4096:min(i*4096+4096,codeLimit)]).digest()
    if hh!=d[cd+hashOff+i*32:cd+hashOff+(i+1)*32]: print("FAIL: page %d hash mismatch"%i); fails+=1
# execSegment обязан покрывать __TEXT (execSegLimit!=0), иначе AMFI отвергает подпись
eb,el,ef=struct.unpack('>QQQ',d[cd+64:cd+88])
toff=tsz=0; o2=32
for _ in range(nc):
    c2,s2=struct.unpack('<II',d[o2:o2+8])
    if c2==0x19 and d[o2+8:o2+14]==b'__TEXT': toff,tsz=struct.unpack('<QQ',d[o2+40:o2+56])
    o2+=s2
if el!=tsz or el==0: print("FAIL: execSegLimit 0x%x != __TEXT filesize 0x%x"%(el,tsz)); fails+=1
if eb!=toff: print("FAIL: execSegBase 0x%x != __TEXT fileoff 0x%x"%(eb,toff)); fails+=1
cw=blobs[0x10000]; wm,wl=struct.unpack('>II',d[cw:cw+8])
if wm!=0xfade0b01: print("FAIL: CMS wrapper magic",hex(wm)); fails+=1
open(OUT+'/cms.der','wb').write(d[cw+8:cw+wl]); open(OUT+'/cd.bin','wb').write(cdb)
r=subprocess.run(["openssl","smime","-verify","-inform","DER","-in",OUT+'/cms.der',"-content",OUT+'/cd.bin',
                  "-noverify","-no_check_time","-out","/dev/null"],capture_output=True,text=True)
if "Verification successful" not in (r.stderr+r.stdout): print("FAIL: openssl verify:",r.stderr.strip()[:200]); fails+=1
print("openssl CMS verify + CodeDirectory:", "ok" if fails==0 else "FAILED")
sys.exit(1 if fails else 0)
PY

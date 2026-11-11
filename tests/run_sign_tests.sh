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
 int exe=ac>4;tcc_set_options(s,exe?"-nostdinc -nostdlib":"-nostdinc -nostdlib -install_name @rpath/t.dylib");tcc_set_output_type(s,exe?TCC_OUTPUT_EXE:TCC_OUTPUT_DLL);
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

# повторная подпись уже подписанного файла (чужой dylib в «Запуске dylib»): старая подпись заменяется, а не копится
"$TMP/sign" "$TMP/signed.dylib" "$TMP/cert.der" "$TMP/key.pem" "$TMP/resigned.dylib"
python3 - "$TMP/signed.dylib" "$TMP/resigned.dylib" <<'PY'
import sys,struct
def sigoff(p):
    d=open(p,'rb').read(); nc,=struct.unpack('<I',d[16:20]); off=32
    for _ in range(nc):
        c,s=struct.unpack('<II',d[off:off+8])
        if c==0x1d: return struct.unpack('<I',d[off+8:off+12])[0], len(d)
        off+=s
a=sigoff(sys.argv[1]); b=sigoff(sys.argv[2])
if a!=b: print("FAIL: re-sign stacked signatures", a, b); sys.exit(1)
print("re-sign replaces old signature: ok")
PY

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

# ---------- подпись приложения (исполняемый файл + энтайтлменты + Info.plist + CodeResources) ----------
printf '#include <stdio.h>\nint main(void){ printf("hi\\n"); return 0; }\n' > "$TMP/app.c"
"$TMP/tcc" tcc/res "$TMP/app.c" "$TMP/app.bin" exe
python3 - "$TMP" <<'PY2'
import sys,plistlib,os
T=sys.argv[1]
ent={"application-identifier":"TEAMID1234.com.gxfiles.test","com.apple.developer.team-identifier":"TEAMID1234",
     "get-task-allow":True,"keychain-access-groups":["TEAMID1234.*"]}
open(T+"/ent.xml","wb").write(plistlib.dumps(ent))
def L(n):
    if n<128: return bytes([n])
    b=n.to_bytes((n.bit_length()+7)//8,'big'); return bytes([0x80|len(b)])+b
def tlv(t,b): return bytes([t])+L(len(b))+b
def val(v):
    if isinstance(v,bool): return tlv(1,b'\xff' if v else b'\x00')
    if isinstance(v,str): return tlv(0x0c,v.encode())
    if isinstance(v,list): return tlv(0x30,b''.join(val(x) for x in v))
    if isinstance(v,dict):
        ks=sorted(v,key=lambda k:k.encode())
        return tlv(0xb0,b''.join(tlv(0x30,tlv(0x0c,k.encode())+val(v[k])) for k in ks))
open(T+"/ent.der","wb").write(tlv(0x70,b'\x02\x01\x01'+val(ent)))
open(T+"/Info.plist","wb").write(plistlib.dumps({"CFBundleExecutable":"app","CFBundleIdentifier":"com.gxfiles.test"}))
open(T+"/CodeResources","wb").write(plistlib.dumps({"files":{},"files2":{}}))
PY2
"$TMP/sign" "$TMP/app.bin" "$TMP/cert.der" "$TMP/key.pem" "$TMP/app.signed" "$TMP/ent.xml" "$TMP/ent.der" "$TMP/Info.plist" "$TMP/CodeResources"
python3 - "$TMP" <<'PY3'
import sys,struct,hashlib,subprocess
T=sys.argv[1]; d=open(T+"/app.signed",'rb').read(); fails=0
def bad(m):
    global fails; fails+=1; print("FAIL:",m)
ft,=struct.unpack('<I',d[12:16]); flags,=struct.unpack('<I',d[24:28])
if ft!=2: bad("filetype %d != MH_EXECUTE"%ft)
if not flags&0x200000: bad("нет MH_PIE")
nc,=struct.unpack('<I',d[16:20]); off=32; so=0; tsz=0; lc=set()
for _ in range(nc):
    c,s=struct.unpack('<II',d[off:off+8]); lc.add(c)
    if c==0x1d: so,=struct.unpack('<I',d[off+8:off+12])
    if c==0x19 and d[off+8:off+14]==b'__TEXT': tsz,=struct.unpack('<Q',d[off+32:off+40])
    off+=s
for need,name in ((0x80000028,"LC_MAIN"),(0xe,"LC_LOAD_DYLINKER"),(0x32,"LC_BUILD_VERSION"),(0x1b,"LC_UUID")):
    if need not in lc: bad("нет "+name)
cnt,=struct.unpack('>I',d[so+8:so+12]); blobs={}
for i in range(cnt):
    t,o=struct.unpack('>II',d[so+12+i*8:so+20+i*8]); blobs[t]=so+o
for t,m in ((0,0xfade0c02),(2,0xfade0c01),(5,0xfade7171),(7,0xfade7172),(0x10000,0xfade0b01)):
    if t not in blobs: bad("нет блоба 0x%x"%t); continue
    mg,=struct.unpack('>I',d[blobs[t]:blobs[t]+4])
    if mg!=m: bad("магия блоба 0x%x = 0x%x"%(t,mg))
cd=blobs[0]; length,=struct.unpack('>I',d[cd+4:cd+8]); hashOff,=struct.unpack('>I',d[cd+16:cd+20])
nsp,=struct.unpack('>I',d[cd+24:cd+28]); ncode,=struct.unpack('>I',d[cd+28:cd+32]); climit,=struct.unpack('>I',d[cd+32:cd+36])
eb,el,ef=struct.unpack('>QQQ',d[cd+64:cd+88])
if nsp!=7: bad("спецслотов %d != 7"%nsp)
if ef!=0x11: bad("execSegFlags 0x%x != 0x11 (MAIN_BINARY|ALLOW_UNSIGNED)"%ef)
if el!=tsz: bad("execSegLimit 0x%x != __TEXT 0x%x"%(el,tsz))
slot=lambda k: d[cd+hashOff-k*32:cd+hashOff-(k-1)*32]
blob=lambda t: d[blobs[t]:blobs[t]+struct.unpack('>I',d[blobs[t]+4:blobs[t]+8])[0]]
sha=lambda b: hashlib.sha256(b).digest()
if slot(1)!=sha(open(T+"/Info.plist",'rb').read()): bad("слот -1 ≠ SHA256(Info.plist)")
if slot(2)!=sha(blob(2)): bad("слот -2 ≠ Requirements")
if slot(3)!=sha(open(T+"/CodeResources",'rb').read()): bad("слот -3 ≠ SHA256(CodeResources)")
if slot(5)!=sha(blob(5)): bad("слот -5 ≠ Entitlements")
if slot(7)!=sha(blob(7)): bad("слот -7 ≠ DER Entitlements")
if slot(4)!=b'\0'*32 or slot(6)!=b'\0'*32: bad("слоты -4/-6 не пустые")
if blob(5)[8:]!=open(T+"/ent.xml",'rb').read(): bad("XML энтайтлменты не совпадают")
if blob(7)[8:]!=open(T+"/ent.der",'rb').read(): bad("DER энтайтлменты не совпадают")
for i in range(ncode):
    if sha(d[i*4096:min(i*4096+4096,climit)])!=d[cd+hashOff+i*32:cd+hashOff+(i+1)*32]: bad("страница %d"%i)
cw=blobs[0x10000]; wl,=struct.unpack('>I',d[cw+4:cw+8])
open(T+'/app.cms','wb').write(d[cw+8:cw+wl]); open(T+'/app.cd','wb').write(d[cd:cd+length])
r=subprocess.run(["openssl","smime","-verify","-inform","DER","-in",T+'/app.cms',"-content",T+'/app.cd',"-noverify","-no_check_time","-out","/dev/null"],capture_output=True,text=True)
if "Verification successful" not in r.stderr+r.stdout: bad("openssl CMS: "+r.stderr.strip()[:200])
print("app signature (exe + entitlements + Info.plist + CodeResources):", "ok" if not fails else "FAILED")
sys.exit(1 if fails else 0)
PY3

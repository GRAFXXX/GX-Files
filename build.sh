#!/bin/bash
# Сборка GX Files.ipa. Работает на macOS (Xcode) и на Linux (clang + lld + iPhoneOS SDK).
#   macOS:  bash build.sh
#   Linux:  SDK=/путь/к/iPhoneOS.sdk bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}"
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
  echo "Не найден iPhoneOS SDK. Укажи путь: SDK=/путь/к/iPhoneOS.sdk bash build.sh" >&2
  exit 1
fi
CLANG="${CLANG:-clang}"
# lld есть в LLVM для Linux; в Xcode используется системный ld64
LDFLAGS_EXTRA=""
if [ "$(uname)" != "Darwin" ]; then LDFLAGS_EXTRA="-fuse-ld=lld"; fi

APP=build/Payload/GXFiles.app
mkdir -p build && find build -mindepth 1 -maxdepth 1 ! -name tcc_cache -exec rm -rf {} + && mkdir -p "$APP" build/obj

# Заголовки и .tbd Apple для встроенного компилятора генерируются из SDK (в репозитории их нет)
if [ ! -d tcc/res/sdk/include ]; then
  echo "Генерирую tcc/res/sdk из $SDK…"
  python3 tools/sdk/make_sdk.py "$SDK"
fi

CF="-target arm64-apple-ios15.0 -isysroot $SDK -O2 -Wall -Wno-unused-variable -Wno-unused-function -Isrc"
for f in src/core/*.c; do "$CLANG" $CF -c "$f" -o build/obj/$(basename "$f").o; done

# встроенный компилятор TinyCC (LGPL) — одна единица трансляции, кэшируется
if [ ! -f build/tcc_cache/libtcc.o ] || [ -n "$(find tcc/src -newer build/tcc_cache/libtcc.o -print -quit 2>/dev/null)" ]; then
  mkdir -p build/tcc_cache
  "$CLANG" $CF -w -DONE_SOURCE=1 -DTCC_TARGET_ARM64 -DTCC_TARGET_MACHO -Itcc/src -c tcc/src/libtcc.c -o build/tcc_cache/libtcc.o
fi
cp build/tcc_cache/libtcc.o build/obj/libtcc.o

for f in src/*.m; do "$CLANG" $CF -fobjc-arc -fmodules -c "$f" -o build/obj/$(basename "$f").o; done

"$CLANG" -target arm64-apple-ios15.0 -isysroot "$SDK" $LDFLAGS_EXTRA -Wl,-adhoc_codesign -Wl,-dead_strip \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework QuickLook -framework QuickLookThumbnailing \
  -framework UniformTypeIdentifiers -framework Security -framework PhotosUI -framework ImageIO -framework CoreText \
  -lz -lsqlite3 -larchive -lobjc -lc++ \
  build/obj/*.o -o "$APP/GXFiles"

cp Info.plist "$APP/Info.plist"
python3 tools/i18n/build.py "$APP/lang"
mkdir -p "$APP/tcc" && cp -R tcc/res/include tcc/res/sdk tcc/res/gx tcc/res/LICENSE-TinyCC.txt "$APP/tcc/"
python3 make_icon.py "$APP"
mv "$APP/icon512.png" build/icon512.png
# На macOS (Xcode) — каталог иконок: светлая, тёмная и тонированная (iOS 18+). Без actool остаются PNG
if xcrun --find actool >/dev/null 2>&1; then
  python3 make_icon.py --xcassets build
  if xcrun actool build/Assets.xcassets --compile "$APP" --platform iphoneos --minimum-deployment-target 15.0 \
       --app-icon AppIcon --target-device iphone --target-device ipad --output-partial-info-plist build/icons.plist >/dev/null; then
    python3 -c "import plistlib,sys;a=plistlib.load(open(sys.argv[1],'rb'));a.update(plistlib.load(open(sys.argv[2],'rb')));plistlib.dump(a,open(sys.argv[1],'wb'))" "$APP/Info.plist" build/icons.plist
    echo "Иконки: Assets.car (светлая / тёмная / тонированная)"
  else
    echo "actool не сработал — оставляю PNG-иконки" >&2
  fi
fi
printf 'APPL????' > "$APP/PkgInfo"
(cd build && rm -f ../GXFiles.ipa && zip -qr -X ../GXFiles.ipa Payload)
ls -la GXFiles.ipa

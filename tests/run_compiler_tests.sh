#!/bin/bash
# Проверка встроенного компилятора: dylib обязан содержать LC_UUID (иначе dyld не грузит).
# Требует сгенерированный tcc/res/sdk (его делает build.sh или tools/sdk/make_sdk.py).
set -e
CC="${CLANG:-clang}"
OBJ="${TMPDIR:-/tmp}/gx_libtcc_host.o"
BIN="${TMPDIR:-/tmp}/gx_compiler_uuid_test"
if [ ! -d tcc/res/sdk/include ]; then
  : "${SDK:=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}"
  [ -n "$SDK" ] && python3 tools/sdk/make_sdk.py "$SDK"
fi
# libtcc как ХОСТОВЫЙ кросс-компилятор под arm64 Mach-O (вывод всё равно iOS arm64)
$CC -w -DONE_SOURCE=1 -DTCC_TARGET_ARM64 -DTCC_TARGET_MACHO -Itcc/src -c tcc/src/libtcc.c -o "$OBJ"
$CC -w -Itcc/src -Isrc tests/compiler_uuid_test.c "$OBJ" \
    src/core/gx_bin.c src/core/gx_sha256.c src/core/gx_tr.c src/core/gx_a64.c \
    -o "$BIN" -lz -lm
"$BIN" tcc/res

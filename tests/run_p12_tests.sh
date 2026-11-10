#!/bin/bash
# Проверка своего разбора PKCS#12 на закоммиченных фикстурах (tests/fixtures/*.p12):
#   modern — OpenSSL 3 по умолчанию (PBES2: PBKDF2-SHA256 + AES-256-CBC) — именно это
#            SecPKCS12Import отвергает с errSecDecode (-26275);
#   aes128 — PBES2 + AES-128-CBC;
#   legacy — 3DES + RC2-40 (как экспорт Keychain/Apple);
#   nopass — пустой пароль.
# Фикстуры детерминированы, поэтому раннеру НЕ нужен openssl для их генерации
# (на macOS это LibreSSL без -legacy/-traditional). Тест просто парсит и сверяет
# извлечённые ключ/сертификат с эталоном побайтово.
# Крипто-бэкенд: CommonCrypto, если доступен (iOS/macOS CI), иначе OpenSSL (хост-Linux).
set -e
CC="${CLANG:-clang}"
F="tests/fixtures"
TMP="${TMPDIR:-/tmp}/gx_p12_test"; rm -rf "$TMP"; mkdir -p "$TMP"

if echo '#include <CommonCrypto/CommonCrypto.h>
int main(){return 0;}' | "$CC" -fsyntax-only -xc - 2>/dev/null; then
    BACKEND="src/core/gx_p12_cc.c"; LIBS=""
    echo "backend: CommonCrypto"
else
    BACKEND="tests/gx_p12_ossl.c"; LIBS="-lcrypto"
    echo "backend: OpenSSL"
fi

$CC -w -Isrc tests/p12_parse_test.c src/core/gx_p12.c "$BACKEND" -o "$TMP/p12t" $LIBS

run() { "$TMP/p12t" "$F/$1.p12" "$2" "$F/expected_key.p1.der" "$F/expected_cert.der" "$1"; }
run modern 1
run aes128 1
run legacy 1
run nopass ""
echo "p12 parse tests: all passed"

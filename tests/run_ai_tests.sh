#!/bin/bash
# Автотесты движка ИИ-помощника (нужен macOS: Foundation). Запуск из корня репозитория.
set -e
PORT=8765
python3 tests/ai_mock_server.py $PORT & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
OUT="${TMPDIR:-/tmp}/gx_ai_test"
clang -fobjc-arc -Wall -Werror -Isrc tests/ai_engine_test.m src/GXAIEngine.m -framework Foundation -framework Security -o "$OUT"
for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 $PORT 2>/dev/null && break; sleep 0.5; done
"$OUT" "http://127.0.0.1:$PORT"

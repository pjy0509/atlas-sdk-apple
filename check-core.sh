#!/bin/sh
# The parity gate. The Foundation-only half compiles and RUNS on macOS against
# a throwaway mock; the UIKit binding is syntax-checked against the real
# iPhoneOS SDK. Tiers as in tools/check-golden.sh.
set -e
cd "$(dirname "$0")"

OUT="${TMPDIR:-/tmp}/atlas-apple-parity"
rm -rf "$OUT"
mkdir -p "$OUT"

# An out-of-process mock, because ObjC has no in-process listener worth
# writing; it answers the ingest shapes and nothing else.
python3 tools/mock_server.py "$OUT/port" "$OUT/envelopes" envelope=200,400,429,500 claim=200 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
    [ -s "$OUT/port" ] && break
    sleep 0.1
done

BASE="http://127.0.0.1:$(cat "$OUT/port")"

SOURCES="Sources/AppAtlasSDK"
clang -fobjc-arc -framework Foundation \
    -I "$SOURCES/include" -I "$SOURCES/Core" -I "$SOURCES/Links" \
    "$SOURCES"/Core/*.m "$SOURCES"/Links/*.m tools/ParityMain.m \
    -o "$OUT/parity"
"$OUT/parity" "$OUT/envelopes" "$BASE"

# The UIKit touch compiles against the device SDK it will really meet.
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -fsyntax-only -fobjc-arc -target arm64-apple-ios12.0 -isysroot "$IOS_SDK" \
    -I "$SOURCES/include" -I "$SOURCES/Core" -I "$SOURCES/Links" \
    "$SOURCES"/Core/*.m "$SOURCES"/Links/*.m
echo "parity: the UIKit binding compiles for ios12"

sh tools/check-golden.sh "$OUT/envelopes" atlas-apple ios clipboard

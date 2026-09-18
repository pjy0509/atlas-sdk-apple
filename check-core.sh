#!/bin/sh
# The parity gate. The Foundation-only half compiles and RUNS on macOS against
# a throwaway mock; the crash gate spawns itself as a victim and dies every
# way the handlers claim to catch; the UIKit binding is syntax-checked against
# the real iPhoneOS SDK. Tiers as in tools/check-golden.sh.
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
INCLUDES="-I $SOURCES/include -I $SOURCES/Core -I $SOURCES/Links -I $SOURCES/Crash"
MODULES="$SOURCES/Core/*.m $SOURCES/Links/*.m $SOURCES/Crash/*.m $SOURCES/Crash/*.c"

# The capture core is C the handlers run: every warning is a bug there.
clang -c -Wall -Wextra -Werror -fno-omit-frame-pointer $INCLUDES "$SOURCES/Crash/atl_crash_capture.c" -o "$OUT/capture.o"

clang -fobjc-arc -framework Foundation $INCLUDES $MODULES tools/ParityMain.m -o "$OUT/parity"
"$OUT/parity" "$OUT/envelopes" "$BASE"

# The crash gate: a victim per way of dying, then the next start over the
# report each one left. It refuses to run under a debugger, as the hooks do.
clang -fobjc-arc -framework Foundation -fno-omit-frame-pointer $INCLUDES $MODULES tools/CrashGateMain.m -o "$OUT/crash-gate"
"$OUT/crash-gate" "$OUT/envelopes" "$BASE"

# The UIKit touch compiles against the device SDK it will really meet.
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
clang -fsyntax-only -fobjc-arc -target arm64-apple-ios12.0 -isysroot "$IOS_SDK" $INCLUDES $MODULES
echo "parity: the UIKit binding and the capture core compile for ios12"

# Swift consumes this as a module; the test target holds that shape. The
# exit code is the verdict — "0 failures" contains the word.
if ! swift test --quiet > "$OUT/swift-test.log" 2>&1; then
    tail -30 "$OUT/swift-test.log" >&2
    exit 1
fi

echo "parity: swift imports the module and reads the shared names"

sh tools/check-golden.sh "$OUT/envelopes" atlas-apple ios clipboard

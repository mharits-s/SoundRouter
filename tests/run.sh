#!/bin/sh
# Tests: headless driver logic, then the end-to-end self test against the installed driver.
# Click "Allow" on permission prompts the first time.
set -e
cd "$(dirname "$0")/.."
./scripts/build.sh >/dev/null
T=build/tests; mkdir -p $T/src
# 1) driver logic without coreaudiod (parsing, live reload, channel-count change, ring stride)
clang -O1 -Wall -Wno-unused-parameter -Wno-unused-function tests/drivertest.c -o $T/drivertest -framework CoreAudio -framework CoreFoundation
$T/drivertest
# 2) self test app (signed .app: reading a virtual device's input needs the Microphone permission)
mk() { A=$T/$1.app; mkdir -p $A/Contents/MacOS; cat > $A/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>$1</string><key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSAudioCaptureUsageDescription</key><string>test</string><key>NSMicrophoneUsageDescription</key><string>test</string></dict></plist>
P
}
mk tonegen com.soundrouter.tonegen; mk selftest com.soundrouter.selftest
cp tests/selftest.swift $T/src/main.swift
swiftc -O -target arm64-apple-macos14.2 tests/tonegen.swift -o $T/tonegen.app/Contents/MacOS/tonegen
swiftc -O -target arm64-apple-macos14.2 $T/src/main.swift app/Engine.swift app/Model.swift app/Logic.swift -o $T/selftest.app/Contents/MacOS/selftest
codesign -s - --force $T/tonegen.app $T/selftest.app >/dev/null 2>&1
if pgrep -x SoundRouter >/dev/null; then   # the app rewrites devices.txt from its config and would disturb the live-reload checks
  echo "SoundRouter is running. Quit it first (this test rewrites devices.txt), then run again."; exit 2
fi
rm -f /tmp/sr-selftest.txt
open -n $T/selftest.app --args "$PWD/$T/tonegen.app/Contents/MacOS/tonegen" ${1:-}
for i in $(seq 1 300); do grep -q RESULT /tmp/sr-selftest.txt 2>/dev/null && break; sleep 1; done
cat /tmp/sr-selftest.txt
grep -q "RESULT: ALL PASSED" /tmp/sr-selftest.txt
# 3) microphone indicator: only a microphone source may make macOS show SoundRouter as using the microphone
[ -n "${1:-}" ] || exec tests/mic-indicator.sh

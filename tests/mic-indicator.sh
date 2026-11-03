#!/bin/sh
# Which sensors does macOS attribute to the engine? Runs the real Engine inside the signed self test app (built by tests/run.sh,
# so it has its permissions) for (a) an app tap + a monitor on the speakers, (b) the same + a monitor on BlackHole 64ch,
# (c) a microphone source, then reads ControlCenter's "Sorted active attributions" log for that app's bundle id.
# Expected: [aud] only for (a) and (b), [mic] for (c).
cd "$(dirname "$0")/.."
T=build/tests
[ -x $T/selftest.app/Contents/MacOS/selftest ] || { echo "Run tests/run.sh first (it builds $T)."; exit 2; }
if pgrep -x SoundRouter >/dev/null; then echo "SoundRouter is running. Quit it first (this test rewrites devices.txt), then run again."; exit 2; fi
rm -f /tmp/sr-selftest.txt
open -n $T/selftest.app --args "$PWD/$T/tonegen.app/Contents/MacOS/tonegen" indicator
for i in $(seq 1 120); do grep -q RESULT /tmp/sr-selftest.txt 2>/dev/null && break; sleep 1; done
cat /tmp/sr-selftest.txt
grep -q "RESULT: ALL PASSED" /tmp/sr-selftest.txt

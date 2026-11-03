#!/bin/zsh
# Real-input UI regression test. Drives the built app with real mouse/keyboard events (CGEvent via the HID tap) and
# checks the result in the app's config.json and in its accessibility tree. It needs Accessibility for the terminal/IDE
# that runs it, brings the test window to the front for a few seconds (your focus is restored afterwards), and refuses
# to send any event unless the test window is frontmost and on top at the click point. The app runs UI-only
# (SR_UI_ONLY=1) in a scratch HOME, so it never touches the real config or the system driver, and it only ever
# quits the instance it started itself (never yours).
#   tests/ui/run.sh [path/to/SoundRouter.app]      (default build/SoundRouter.app)
# Fixed coordinates are for tests/ui/demo-config.json (3 sources: Safari, tonegen, mic) in the default layout;
# everything that moves (Options, sliders, footer buttons) is located through Accessibility.
cd "${0:A:h}/../.." || exit 1
APP=${1:-build/SoundRouter.app}; APP=${APP:A}; T=${TMPDIR:-/tmp}/sr-ui-test; rm -rf $T; mkdir -p $T/home/Library/Application\ Support/SoundRouter
cp tests/ui/demo-config.json "$T/home/Library/Application Support/SoundRouter/config.json"; CFG="$T/home/Library/Application Support/SoundRouter/config.json"
for t in uidrive axdump; do swiftc -O tests/ui/$t.swift -o $T/$t 2>$T/cc.log || { echo "build of $t failed"; cat $T/cc.log; exit 1; }; done
cat > $T/win.swift <<'SW'
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
for w in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]) where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    if (b["Width"] as! Double) > 900 && (b["Height"] as! Double) > 500 && (w[kCGWindowIsOnscreen as String] as? Bool ?? false) { print(w[kCGWindowNumber as String]!); break } }
SW
swiftc -O $T/win.swift -o $T/win 2>/dev/null
fail=0; ok() { echo "PASS $1"; }; bad() { echo "FAIL $1"; fail=1; }
cfg() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1])); d=d['devices'] if isinstance(d,dict) else d
$1" "$CFG"; }
BEFORE=$(pgrep -f "[S]oundRouter.app/Contents/MacOS" | sort)   # instances that were already running (yours): never touched
open -g -n --env CFFIXED_USER_HOME=$T/home --env SR_UI_ONLY=1 "$APP"; sleep 6
PID=$(comm -13 <(echo "$BEFORE") <(pgrep -f "[S]oundRouter.app/Contents/MacOS" | sort) | head -1)   # the one we just launched
WID=$($T/win $PID)
[ -n "$PID" ] && [ -n "$WID" ] || { echo "app/window not found"; exit 1; }
activate() { open "$APP"; for i in {1..15}; do F=$(/usr/bin/lsappinfo info -only pid $(/usr/bin/lsappinfo front) 2>/dev/null | grep -o '[0-9]*$'); [ "$F" = "$PID" ] && return 0; sleep 0.2; done; return 1; }
drive() {
  activate || { echo "SKIPPED: could not bring the test window to the front, no input sent"; kill $PID 2>/dev/null; exit 2; }
  $T/uidrive $PID $WID --hid "$@" >/dev/null || { echo "ABORTED: uidrive failed or its safety check refused to send input"; kill $PID 2>/dev/null; exit 2; }
}
ax() { $T/axdump $PID 14 2>&1; }
# window-relative centre of the first accessibility element whose line contains $1 (and optionally the n-th match)
centre() { ax | python3 -c "
import re,sys
t=sys.stdin.read().splitlines(); needle=sys.argv[1]; n=int(sys.argv[2]) if len(sys.argv)>2 else 0
f=lambda l: [int(v) for v in re.findall(r'\((-?\d+),(-?\d+) (\d+)x(\d+)', l)[-1]]
ox,oy=f(next(l for l in t if 'AXWindow' in l))[:2]
hits=[l for l in t if needle in l]; x,y,w,h=f(hits[n]); print(x-ox+w//2, y-oy+h//2, x-ox, y-oy, w, h)" "$@"; }

echo "--- initial state"
ax | grep -m1 "\[Delete |" | grep -q "{disabled}" && ok "Delete is off while nothing is active" || bad "Delete is off while nothing is active"

echo "--- plain controls"
drive click 439 334 wait 400
[[ "$(cfg "print(d[0]['sources'][1]['muted'])")" == True ]] && ok "pill click toggles the source" || bad "pill click toggles the source"

echo "--- Options"
read CX CY _ <<<"$(centre 'Options | collapsed' 0)"
drive click $CX $CY wait 600
ax | grep -q "Options | expanded" && ok "Options opens with a real click" || bad "Options opens with a real click"
ax | grep -q "Mute when capturing" && ok "Options has \"Mute when capturing\"" || bad "Options has \"Mute when capturing\""
if ax | grep -qE "Reset Routing|Remove Source|Remove Monitor|Also play"; then bad "Options has no Reset Routing / Remove / Also play buttons"; else ok "Options has no Reset Routing / Remove / Also play buttons"; fi
read SCX SCY SX SY SW SH <<<"$(centre 'Safari volume' 0)"
drive drag $((SX + SW - 5)) $SCY $((SX + SW / 2)) $SCY wait 400      # from the right end (100%) to the middle
G=$(cfg "print(round(d[0]['sources'][0]['gain'],2))"); echo "     gain after dragging the slider to the middle: $G"
python3 -c "import sys; sys.exit(0 if 0.35 < $G < 0.65 else 1)" && ok "slider drag changes the volume (and 100% is the top)" || bad "slider drag changes the volume (and 100% is the top)"
drive drag $((SX + SW / 2)) $SCY $((SX + SW + 60)) $SCY wait 400    # far past the right end
G=$(cfg "print(round(d[0]['sources'][0]['gain'],2))"); python3 -c "import sys; sys.exit(0 if $G <= 1.0 else 1)" && ok "volume never exceeds 100% (gain $G)" || bad "volume never exceeds 100% (gain $G)"
read KX KY KL KT _ _ <<<"$(centre 'Mute when capturing' 0)"
H0=$(cfg "print(d[0]['sources'][0]['hearOriginalKeep'])"); drive click $((KL + 8)) $KY wait 400; H1=$(cfg "print(d[0]['sources'][0]['hearOriginalKeep'])")
[[ "$H0" == False && "$H1" == True ]] && ok "\"Mute when capturing\" toggles (checked = muted = hearOriginal False)" || bad "\"Mute when capturing\" toggles ($H0 -> $H1)"
read CX CY _ <<<"$(centre 'Options | expanded' 0)"; drive click $CX $CY wait 500          # fold it again: default layout

echo "--- delete only through the Delete button"
drive click 300 189 wait 300
ax | grep -m1 "\[Delete |" | grep -q "{disabled}" && bad "Delete turns on when a card is active" || ok "Delete turns on when a card is active"
drive key delete wait 500
[[ "$(cfg "print(len(d[0]['sources']))")" == 3 ]] && ok "the keyboard Delete key does nothing" || bad "the keyboard Delete key does nothing"
read DX DY _ <<<"$(centre '[Delete |' 0)"; drive click $DX $DY wait 500
[[ "$(cfg "print([s['title'] for s in d[0]['sources']])")" == "['tonegen (no icon)', 'MacBook Pro Microphone']" ]] && ok "Delete button removes the active card" || bad "Delete button removes the active card"
drive key cmd+z wait 600
[[ "$(cfg "print(len(d[0]['sources']))")" == 3 ]] && ok "Cmd-Z undoes the deletion" || bad "Cmd-Z undoes the deletion"
drive click 300 189 wait 300; read DX DY _ <<<"$(centre '[Delete |' 0)"; drive click $DX $DY wait 500     # delete Safari again for the cable steps
drive click 590 225 wait 300; read DX DY _ <<<"$(centre '[Delete |' 0)"; drive click $DX $DY wait 500
[[ "$(cfg "print(d[0]['sources'][0]['routes'])")" == "[0, 2]" ]] && ok "an active cable is deleted with the Delete button" || bad "an active cable is deleted with the Delete button"

echo "--- cables"
drive hold 456 225 698 261 wait 350 release wait 400
[[ "$(cfg "print(d[0]['sources'][0]['routes'])")" == "[2, 2]" ]] && ok "dragging a cable near a dot snaps and connects" || bad "dragging a cable near a dot snaps and connects"
drive hold 456 225 640 330 wait 350 release wait 400
[[ "$(cfg "print(d[0]['sources'][0]['routes'])")" == "[2, 2]" ]] && ok "dropping on empty space changes nothing" || bad "dropping on empty space changes nothing"
kill $PID 2>/dev/null   # only our own test instance
[ $fail = 0 ] && echo "UI RESULT: ALL PASSED" || echo "UI RESULT: FAILED"; exit $fail

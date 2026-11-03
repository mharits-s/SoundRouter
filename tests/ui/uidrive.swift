// uidrive <pid> <windowID> cmd...   coordinates are in points relative to the window's top-left
//   click X Y | dclick X Y | drag X1 Y1 X2 Y2 | hold X1 Y1 X2 Y2 (press+move, no release) | release | move X Y | key delete|esc|return | wait MS
import AppKit
import CoreGraphics
import Foundation
let prevFront = NSWorkspace.shared.frontmostApplication   // restored at the end so the owner keeps their focus
let src = CGEventSource(stateID: .hidSystemState)
let a = CommandLine.arguments
let pid = pid_t(a[1])!, wid = CGWindowID(a[2])!
func frame() -> CGRect {
    let l = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]]
    let b = l?.first?[kCGWindowBounds as String] as! [String: Any]
    return CGRect(x: b["X"] as! Double, y: b["Y"] as! Double, width: b["Width"] as! Double, height: b["Height"] as! Double)
}
let f = frame()
func g(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: f.minX + x, y: f.minY + y) }
let cursor0 = CGEvent(source: nil)?.location ?? .zero      // owner's pointer, restored at the end
var lastPt = CGPoint.zero
func topWindowIsMine(_ p: CGPoint) -> Bool {
    for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [] {
        guard (w[kCGWindowLayer as String] as? Int) == 0, let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        let r = CGRect(x: b["X"] as! Double, y: b["Y"] as! Double, width: b["Width"] as! Double, height: b["Height"] as! Double)
        if r.contains(p) { return (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) }
    }
    return false
}
func restoreFront() {   // macOS 14+ ignores NSRunningApplication.activate() from another app; LaunchServices is allowed
    CGWarpMouseCursorPosition(cursor0)
    if let b = prevFront?.bundleIdentifier, prevFront?.processIdentifier != pid {
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/open"); t.arguments = ["-b", b]; try? t.run(); t.waitUntilExit()
    }
}
func abortSafe(_ why: String) -> Never {
    print("ABORT (safety):", why); restoreFront(); exit(2)
}
func deliver(_ e: CGEvent, key: Bool = false) {
    guard a.contains("--hid") else { e.postToPid(pid); return }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { abortSafe("test app is not frontmost") }
    if !key && !topWindowIsMine(e.location) { abortSafe("another window is on top at \(e.location)") }
    e.post(tap: .cghidEventTap)
}
func post(_ t: CGEventType, _ p: CGPoint, click: Int64 = 1) {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: click)
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid))
    deliver(e); lastPt = p
}
func sleep(_ ms: Int) { usleep(UInt32(ms * 1000)) }
func moveSteps(_ from: CGPoint, _ to: CGPoint, type: CGEventType, steps: Int = 14) {
    for i in 1...steps { let t = Double(i) / Double(steps); post(type, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)); sleep(12) } }
if a.contains("--activate") { NSRunningApplication(processIdentifier: pid)?.activate(); usleep(500_000) }
var i = 3
func num() -> Double { defer { i += 1 }; return Double(a[i])! }
while i < a.count {
    let c = a[i]; i += 1
    switch c {
    case "--activate", "--hid": break
    case "screen": let out = a[i]; i += 1; let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", out]; try? t.run(); t.waitUntilExit()
    case "shot": let out = a[i]; i += 1; let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", "-o", "-l", String(wid), out]; try? t.run(); t.waitUntilExit()
    case "click": let p = g(num(), num()); post(.mouseMoved, p); sleep(40); post(.leftMouseDown, p); sleep(50); post(.leftMouseUp, p); sleep(120)
    case "dclick": let p = g(num(), num()); post(.mouseMoved, p); sleep(40); post(.leftMouseDown, p); post(.leftMouseUp, p); sleep(60); post(.leftMouseDown, p, click: 2); post(.leftMouseUp, p, click: 2); sleep(150)
    case "drag": let p1 = g(num(), num()), p2 = g(num(), num()); post(.mouseMoved, p1); sleep(40); post(.leftMouseDown, p1); sleep(40)
        moveSteps(p1, p2, type: .leftMouseDragged); sleep(60); post(.leftMouseUp, p2); sleep(150)
    case "hold": let p1 = g(num(), num()), p2 = g(num(), num()); post(.mouseMoved, p1); sleep(40); post(.leftMouseDown, p1); sleep(40); moveSteps(p1, p2, type: .leftMouseDragged); sleep(100)
    case "release": post(.leftMouseUp, lastPt); sleep(150)
    case "move": let p = g(num(), num()); post(.mouseMoved, p); sleep(80)
    case "key":
        let parts = a[i].split(separator: "+").map(String.init); i += 1      // e.g. delete, esc, cmd+z, cmd+shift+z
        let codes: [String: CGKeyCode] = ["delete": 51, "esc": 53, "return": 36, "z": 6]
        var flags: CGEventFlags = []
        for m in parts.dropLast() { if m == "cmd" { flags.insert(.maskCommand) } else if m == "shift" { flags.insert(.maskShift) } }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: codes[parts.last!] ?? 0, keyDown: down)!; e.flags = flags
            deliver(e, key: true); usleep(50_000)
        }; sleep(150)
    case "wait": let ms = Int(num()); sleep(ms)
    default: print("unknown command \(c)")
    }
}
restoreFront()
print("frame:", f, "| front now:", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")

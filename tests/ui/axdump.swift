// axdump <pid> [depth]  -> prints the accessibility tree (role, label/title/value, frame in screen points)
import ApplicationServices
import Foundation
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> String {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute), CFGetTypeID(pv) == AXValueGetTypeID() { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(e, kAXSizeAttribute), CFGetTypeID(sv) == AXValueGetTypeID() { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return "(\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height)))" }
func walk(_ e: AXUIElement, _ d: Int, _ max: Int) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap { attr(e, $0) }.map { "\($0)" }.filter { !$0.isEmpty }.joined(separator: " | ")
    let off = (attr(e, kAXEnabledAttribute) as? Bool) == false ? " {disabled}" : ""
    if !(role == "AXGroup" && label.isEmpty) || d < 2 { print(String(repeating: "  ", count: d) + role, label.isEmpty ? "" : "[\(label)]", frame(e) + off) }
    guard d < max, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
    for k in kids { walk(k, d + 1, max) } }
let pid = pid_t(CommandLine.arguments[1])!, maxD = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 12
print("trusted:", AXIsProcessTrusted())
walk(AXUIElementCreateApplication(pid), 0, maxD)

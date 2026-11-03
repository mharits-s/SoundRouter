// axpress <pid> <label-substring> [index]  -> performs AXPress on the index-th (default 0) matching element
import ApplicationServices
import Foundation
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
var hits: [AXUIElement] = []
let needle = CommandLine.arguments[2]
func walk(_ e: AXUIElement) {
    let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attr(e, $0) as? String }.joined(separator: " | ")
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    if label.contains(needle), role == "AXButton" || role == "AXDisclosureTriangle" || role == "AXGroup" { hits.append(e) }
    for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(k) } }
walk(AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!))
let idx = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 0
guard idx < hits.count else { print("no match (\(hits.count) hits)"); exit(1) }
print("AXPress:", AXUIElementPerformAction(hits[idx], kAXPressAction as CFString).rawValue == 0 ? "ok" : "failed", "| hits:", hits.count)

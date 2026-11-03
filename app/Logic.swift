import AppKit

// Pure UI logic (no SwiftUI): cable geometry, hit-testing, patching, add menus. Unit-tested headless by tests/selftest.swift.

// MARK: - dots
/// A connection point. Keys: "src|<source id>|c", "oin|o", "oout|o", "mon|<monitor id>|j".
struct DotID: Hashable {
    enum Kind: String { case src, oin, oout, mon }
    let kind: Kind, owner: UUID?, ch: Int
    var key: String { [kind.rawValue, owner?.uuidString, String(ch)].compactMap { $0 }.joined(separator: "|") }
    init(_ kind: Kind, _ owner: UUID? = nil, _ ch: Int) { self.kind = kind; self.owner = owner; self.ch = ch }
    init?(_ key: String) {
        let p = key.split(separator: "|").map(String.init)
        guard let k = p.first.flatMap(Kind.init), let c = p.last.flatMap({ Int($0) }) else { return nil }
        kind = k; ch = c
        if k == .src || k == .mon { guard p.count == 3, let u = UUID(uuidString: p[1]) else { return nil }; owner = u } else { owner = nil }
    }
}

/// Closest dot of the given kinds within `radius` of `p`.
func nearestDot(at p: CGPoint, in dots: [String: CGPoint], kinds: Set<DotID.Kind>, radius: CGFloat = 12) -> String? {
    var best: (String, CGFloat)?
    for (k, c) in dots {
        guard let id = DotID(k), kinds.contains(id.kind) else { continue }
        let d = hypot(c.x - p.x, c.y - p.y)
        if d <= radius && d < (best?.1 ?? .infinity) { best = (k, d) }
    }
    return best?.0
}

// MARK: - cable geometry
enum CableGeom {
    static let level: CGFloat = 2.5   // dots closer than this vertically get a dead straight cable
    static func isStraight(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(b.y - a.y) < level || b.x - a.x < 8 }
    /// Flat ends + one S-bend (cubic) centred in the run. Returns (x1, x2) where the bend starts and ends.
    static func bend(_ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGFloat) {
        let w = b.x - a.x, bend = min(w, 170)
        let x1 = a.x + (w - bend) / 2
        return (x1, x1 + bend)
    }
    /// The drawn curve as a polyline (for hit-testing).
    static func points(_ a: CGPoint, _ b: CGPoint, steps: Int = 40) -> [CGPoint] {
        if isStraight(a, b) { let y = (a.y + b.y) / 2; return [CGPoint(x: a.x, y: y), CGPoint(x: b.x, y: y)] }
        let (x1, x2) = bend(a, b), mid = (x1 + x2) / 2
        let p0 = CGPoint(x: x1, y: a.y), c1 = CGPoint(x: mid, y: a.y), c2 = CGPoint(x: mid, y: b.y), p3 = CGPoint(x: x2, y: b.y)
        var r = [a]
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x
            let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y
            r.append(CGPoint(x: x, y: y))
        }
        r.append(b)
        return r
    }
    /// Distance from `p` to the cable a -> b, or nil when `p` is not over the visible part (the ends hide under the cards).
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, hidden: CGFloat = 16) -> CGFloat? {
        guard p.x > a.x + hidden, p.x < b.x - hidden else { return nil }
        let pts = points(a, b)
        var best = CGFloat.infinity
        for i in 1..<pts.count {
            let s = pts[i - 1], e = pts[i], dx = e.x - s.x, dy = e.y - s.y, l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - s.x) * dx + (p.y - s.y) * dy) / l2))
            best = min(best, hypot(p.x - (s.x + t * dx), p.y - (s.y + t * dy)))
        }
        return best
    }
}

// MARK: - patching
struct Link: Hashable { let from: String, to: String; var id: String { from + ">" + to } }

enum Patch {
    /// Every cable of a device: source channel -> output in, output out -> monitor channel.
    static func links(_ d: VDev, monitors: Bool = true) -> [Link] {
        var r: [Link] = []
        for s in d.sources {
            for (c, m) in s.routes.enumerated() where c < s.inCh {
                for o in 0..<d.channels where Routing.has(m, o) { r.append(Link(from: DotID(.src, s.id, c).key, to: DotID(.oin, nil, o).key)) }
            }
        }
        if monitors {
            for m in d.monitors {
                for (j, o) in m.map.enumerated() where o >= 0 && o < d.channels { r.append(Link(from: DotID(.oout, nil, o).key, to: DotID(.mon, m.id, j).key)) }
            }
        }
        return r
    }

    /// Kinds a drag starting at `kind` may end on.
    static func targets(_ kind: DotID.Kind) -> Set<DotID.Kind> {
        switch kind { case .src: [.oin]; case .oin: [.src]; case .oout: [.mon]; case .mon: [.oout] }
    }

    /// Connect two dots (either order). `toggle`: an existing source cable is removed instead.
    /// A monitor channel has exactly one source, so connecting it replaces the previous one. Returns false if incompatible.
    @discardableResult
    static func connect(_ d: inout VDev, _ a: String, _ b: String, toggle: Bool = true) -> Bool {
        guard var x = DotID(a), var y = DotID(b) else { return false }
        if x.kind == .oin || x.kind == .mon { swap(&x, &y) }
        switch (x.kind, y.kind) {
        case (.src, .oin):
            guard let i = d.sources.firstIndex(where: { $0.id == x.owner }), x.ch < d.sources[i].routes.count, y.ch < d.channels else { return false }
            let m = d.sources[i].routes[x.ch]
            d.sources[i].routes[x.ch] = toggle ? Routing.toggle(m, y.ch) : m | (1 << UInt32(y.ch))
        case (.oout, .mon):
            guard let i = d.monitors.firstIndex(where: { $0.id == y.owner }), y.ch < d.monitors[i].map.count, x.ch < d.channels else { return false }
            d.monitors[i].map[y.ch] = x.ch
        default: return false
        }
        return true
    }

    static func remove(_ d: inout VDev, _ l: Link) {
        guard let x = DotID(l.from), let y = DotID(l.to) else { return }
        if x.kind == .src, let i = d.sources.firstIndex(where: { $0.id == x.owner }), x.ch < d.sources[i].routes.count {
            d.sources[i].routes[x.ch] &= ~(1 << UInt32(y.ch))
        } else if y.kind == .mon, let i = d.monitors.firstIndex(where: { $0.id == y.owner }), y.ch < d.monitors[i].map.count {
            d.monitors[i].map[y.ch] = -1
        }
    }

    /// Cable under the pointer (within `tol`), nearest first.
    static func hit(_ p: CGPoint, links: [Link], dots: [String: CGPoint], tol: CGFloat = 6) -> Link? {
        var best: (Link, CGFloat)?
        for l in links {
            guard let a = dots[l.from], let b = dots[l.to], let dist = CableGeom.distance(p, a, b), dist <= tol else { continue }
            if dist < (best?.1 ?? .infinity) { best = (l, dist) }
        }
        return best?.0
    }

    /// What a drag does when released. `start`: dot the drag began on (nil = it began on a cable, see `moving`).
    /// Magnet: a cable end dragged within this many points of a compatible dot snaps onto it (and is dropped there).
    static let snapRadius: CGFloat = 26

    /// The dot a cable end dragged to `p` would snap to, if any. `drop` uses the same rule, so what is shown is what happens.
    static func snapTarget(start: String?, moving: (link: Link, fixed: String)?, at p: CGPoint, dots: [String: CGPoint]) -> String? {
        guard let key = start ?? moving?.fixed, let k = DotID(key)?.kind else { return nil }
        return nearestDot(at: p, in: dots, kinds: targets(k), radius: snapRadius)
    }

    enum Drop: Equatable { case none, connect(String, String), move(Link, String, String), detach(Link) }
    static func drop(start: String?, moving: (link: Link, fixed: String)?, at p: CGPoint, dots: [String: CGPoint]) -> Drop {
        if let start, let k = DotID(start)?.kind {
            guard let t = nearestDot(at: p, in: dots, kinds: targets(k), radius: snapRadius) else { return .none }
            return .connect(start, t)
        }
        if let (l, fixed) = moving, let k = DotID(fixed)?.kind {
            guard let t = nearestDot(at: p, in: dots, kinds: targets(k), radius: snapRadius) else { return .detach(l) }   // pulled off = deleted
            return .move(l, fixed, t)
        }
        return .none
    }

    static func apply(_ d: inout VDev, _ drop: Drop) {
        switch drop {
        case .none: break
        case let .connect(a, b): connect(&d, a, b)
        case let .move(l, fixed, t): remove(&d, l); connect(&d, fixed, t, toggle: false)
        case let .detach(l): remove(&d, l)
        }
    }
}

// MARK: - icons
enum IconCache {
    static var cache: [String: NSImage] = [:]
    /// App icon by bundle id (cached: views redraw 20x/s). Falls back to the generic application icon, never to a mic.
    static func app(_ bundleID: String) -> NSImage {
        if let i = cache[bundleID] { return i }
        let img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[bundleID] = img
        return img
    }
    static func small(_ img: NSImage) -> NSImage {
        let s = img.copy() as! NSImage; s.size = NSSize(width: 16, height: 16); return s
    }
}

// MARK: - add menus (AppKit NSMenu, built at click time from a snapshot: nothing re-renders it while it is open)
final class ActionItem: NSMenuItem {
    var handler: () -> Void = {}
    convenience init(_ title: String, image: NSImage? = nil, enabled: Bool = true, checked: Bool = false, _ handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self; self.handler = handler; self.image = image
        isEnabled = enabled; state = checked ? .on : .off
    }
    @objc func fire() { handler() }
}

struct HWDev: Hashable { let uid: String, name: String; var ch = 2 }
struct RunningApp: Hashable { let bid: String, name: String }

enum AddMenu {
    enum Pick: Equatable { case system, app(RunningApp), input(HWDev) }
    static let ownBundleID = "com.soundrouter.app"

    static func sources(apps: [RunningApp], inputs: [HWDev], used: [SourceCfg], pick: @escaping (Pick) -> Void) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        let usedApps = Set(used.filter { $0.kind == .app }.map(\.ref)), usedMics = Set(used.filter { $0.kind == .mic }.map(\.ref))
        let sysUsed = used.contains { $0.kind == .system }
        m.addItem(.sectionHeader(title: "System"))
        m.addItem(ActionItem("All System Audio", image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil),
                             enabled: !sysUsed, checked: sysUsed) { pick(.system) })
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Applications"))
        let list = apps.filter { $0.bid != ownBundleID }
        if list.isEmpty { m.addItem(ActionItem("No apps running", enabled: false) {}) }
        for a in list {
            let u = usedApps.contains(a.bid)
            m.addItem(ActionItem(a.name, image: IconCache.small(IconCache.app(a.bid)), enabled: !u, checked: u) { pick(.app(a)) })
        }
        m.addItem(.separator())
        m.addItem(.sectionHeader(title: "Input Devices"))
        let devs = inputs.filter { !$0.uid.hasPrefix("soundrouter.") }   // our own devices would feed back
        if devs.isEmpty { m.addItem(ActionItem("No input devices", enabled: false) {}) }
        for dv in devs {
            let u = usedMics.contains(dv.uid)
            m.addItem(ActionItem(dv.name, image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil), enabled: !u, checked: u) { pick(.input(dv)) })
        }
        return m
    }

    static func monitors(outputs: [HWDev], used: [MonitorCfg], pick: @escaping (HWDev) -> Void) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(.sectionHeader(title: "Output Devices"))
        let usedU = Set(used.map(\.uid)), devs = outputs.filter { !$0.uid.hasPrefix("soundrouter.") }
        if devs.isEmpty { m.addItem(ActionItem("No output devices", enabled: false) {}) }
        for o in devs {
            let u = usedU.contains(o.uid)
            m.addItem(ActionItem(o.name, image: NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil), enabled: !u, checked: u) { pick(o) })
        }
        return m
    }

    /// Snapshot of running regular apps, sorted by name.
    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { RunningApp(bid: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}


// MARK: - meter ballistics
/// How a level meter moves: fast attack, smooth release, plus a peak-hold line. Positions are 0...1 on a dB scale
/// (the bottom of the bar is `floorDB`, the top is 0 dBFS), so quiet signals are visible and loud ones don't just pin the bar.
struct Ballistics: Equatable {
    static let floorDB: Float = -54
    static let attack = 0.004      // s: time constant while the level rises (practically instant)
    static let release = 0.10      // s: time constant while it falls: quick enough to feel live, long enough not to flicker
    static let peakFall = 0.30     // s: time constant of the peak line: it starts falling at once, but slower than the bar
    var shown: Float = 0           // bar
    var peak: Float = 0            // peak-hold line

    /// Linear amplitude (1.0 = full scale) -> bar position.
    static func position(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(level) - floorDB) / -floorDB))
    }

    mutating func step(level: Float, dt: Double) {
        let p = Ballistics.position(level)
        let tau = p > shown ? Ballistics.attack : Ballistics.release
        shown += (p - shown) * Float(1 - exp(-dt / tau))
        if p >= peak { peak = p }
        else { peak = max(shown, peak + (shown - peak) * Float(1 - exp(-dt / Ballistics.peakFall))) }
    }
}

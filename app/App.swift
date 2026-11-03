import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

// MARK: - design tokens
enum Theme {
    static let teal = Color(red: 0.20, green: 0.64, blue: 0.60)       // active / connected
    static let tealDeep = Color(red: 0.10, green: 0.34, blue: 0.34)   // selected row
    static let off = Color(red: 0.85, green: 0.27, blue: 0.28)        // switched off
    static let warn = Color(nsColor: NSColor(name: nil) { a in        // needs attention; darker amber in light mode for text contrast
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.96, green: 0.76, blue: 0.20, alpha: 1)
                                                           : NSColor(red: 0.66, green: 0.42, blue: 0.00, alpha: 1) })
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardHeader = Color.primary.opacity(0.07)
    static let stroke = Color.primary.opacity(0.12)
}

// MARK: - store
final class Store: ObservableObject {
    static let namesFile = "/Library/Application Support/SoundRouter/devices.txt"
    let engine = Engine()
    private let cfgURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SoundRouter/config.json")
    @Published var devices: [VDev] { didSet { ConfigFile.save(devices, to: cfgURL); engine.reconcile(devices); scheduleNamesWrite() } }
    @Published var sel: UUID?                  // selected device (shared with the menu commands)
    @Published var deleteAsk = false           // File > Delete Device asks the detail view to confirm
    @Published var renameAsk = 0               // File > Rename Device
    @Published var renaming = false            // a title is being edited (Cmd-Backspace belongs to the text field then)
    static let uiOnly = ProcessInfo.processInfo.environment["SR_UI_ONLY"] != nil
    @Published var ready: Set<Int> = []        // slots the driver publishes with the right name
    /// A slot that is not published yet: quiet at first (a normal change takes < 1 s), "Updating devices…" after ~1.2 s, a warning after ~8 s.
    enum SlotPhase { case updating, failed }
    @Published var phases: [Int: SlotPhase] = [:]
    private var missingSince: [Int: Date] = [:]
    @Published var inputs: [HWDev] = []        // physical devices, refreshed once a second (not per UI frame)
    @Published var outputs: [HWDev] = []
    @Published var driverIssue: String?        // nil = driver installed, current, device list writable
    var needsInstall: Bool { driverIssue != nil }
    static let dir = "/Library/Application Support/SoundRouter"
    static let installedPlist = "/Library/Audio/Plug-Ins/HAL/SoundRouter.driver/Contents/Info.plist"
    private var pendingWrite: DispatchWorkItem?
    @Published var installing = false
    @Published var installError: String?
    private var timer: Timer?
    private var pendingTick: DispatchWorkItem?

    init() {
        defer { Meter.engine = engine }
        let saved = ConfigFile.load(cfgURL)   // an unreadable file is kept as config.json.bak-<time>, never overwritten
        devices = saved.isEmpty ? [VDev(name: "SoundRouter")] : saved
        sel = devices.first?.id
        // the Microphone permission is only needed for input-device sources (monitors no longer read the virtual device)
        if !Self.uiOnly, devices.contains(where: { $0.sources.contains { $0.kind == .mic } }) { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        tick(route: false)   // first routing waits for the next runloop turn: creating a tap can block on the
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.tick() }   // system-audio permission prompt; the window should be up by then
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        // quit: taps and aggregates go away with the process anyway, but stop them in order
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.engine.stopAll() }
        // wake and hot-plug: re-check right away instead of waiting for the next tick
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.soon(1.5) }
        var a = HAL.addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(HAL.sys, &a, .main) { [weak self] _, _ in self?.soon(0.3) }
    }

    /// One tick shortly (coalesces bursts of device-list notifications).
    private func soon(_ t: Double) {
        pendingTick?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.tick() }
        pendingTick = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    /// Once a second: pick up apps that started playing, driver reloads, unplugged devices.
    func tick(route: Bool = true) {
        if route { engine.reconcile(devices) }
        syncNames()
        let all = HAL.devices()
        var virt: [String: (name: String, ch: Int)] = [:]   // uid -> name, channels of the published virtual devices
        for d in all where HAL.isVirtual(d) { virt[HAL.uid(d)] = (HAL.name(d), HAL.channels(d, input: true)) }
        let phys = all.filter { !HAL.isVirtual($0) }
        let ins = phys.compactMap { d in let c = HAL.channels(d, input: true); return c > 0 ? HWDev(uid: HAL.uid(d), name: HAL.name(d), ch: c) : nil }
        let outs = phys.filter { HAL.streams($0, input: false) > 0 }.map { HWDev(uid: HAL.uid($0), name: HAL.name($0)) }
        if ins != inputs { inputs = ins }
        if outs != outputs { outputs = outs }
        if !Self.uiOnly { refreshMicChannels() }
        // UI-only mode never touches the system, so it treats every device as published
        let r = Self.uiOnly ? Set(devices.map(\.slot))
                            : Set(devices.filter { virt[$0.uid]?.name == $0.sysName && virt[$0.uid]?.ch == $0.channels }.map(\.slot))
        let issue = driverProblem()
        let now = Date()
        var ph: [Int: SlotPhase] = [:]
        for dev in devices where !r.contains(dev.slot) {
            let since = missingSince[dev.slot] ?? now
            missingSince[dev.slot] = since
            let age = now.timeIntervalSince(since)
            if age > 8 { ph[dev.slot] = .failed } else if age > 1.2 { ph[dev.slot] = .updating }
        }
        for k in Array(missingSince.keys) where r.contains(k) || !devices.contains(where: { $0.slot == k }) { missingSince[k] = nil }
        if ph != phases { phases = ph }
        if r != ready { ready = r }
        if issue != driverIssue { driverIssue = issue }
    }

    /// A microphone's channel count can change (another device plugged in under the same UID, format change).
    private func refreshMicChannels() {
        var d = devices, changed = false
        for i in d.indices { for j in d[i].sources.indices where d[i].sources[j].kind == .mic {
            guard let hw = inputs.first(where: { $0.uid == d[i].sources[j].ref }) else { continue }
            let n = Routing.clampIn(.mic, hw.ch)
            if n != d[i].sources[j].inCh { d[i].sources[j].inCh = n; d[i].sanitize(); changed = true }
        } }
        if changed { devices = d }
    }

    /// The only reasons to ask for the admin password: driver missing, older than the bundled one, or list not writable.
    /// Names / device count are never a reason: the driver watches devices.txt and updates live.
    func driverProblem() -> String? {
        func version(_ plist: String) -> Int? { (NSDictionary(contentsOfFile: plist)?["CFBundleVersion"] as? String).flatMap { Int($0) } }
        guard let have = version(Self.installedPlist) else { return "The SoundRouter audio driver is not installed." }
        if let res = Bundle.main.resourceURL, let want = version(res.path + "/SoundRouter.driver/Contents/Info.plist"), have < want {
            return "Driver update available."
        }
        if !FileManager.default.isWritableFile(atPath: Self.dir) { return "The device list in \(Self.dir) can't be written." }
        return nil
    }

    /// Write devices.txt when it differs from the config (no admin needed: the folder is world-writable after install).
    func syncNames() {
        guard !Self.uiOnly else { return }   // UI-only/QA mode never touches system files
        let cur = try? String(contentsOfFile: Self.namesFile, encoding: .utf8)
        guard cur?.trimmingCharacters(in: .newlines) != namesText, FileManager.default.isWritableFile(atPath: Self.dir) else { return }
        try? (namesText + "\n").write(toFile: Self.namesFile, atomically: true, encoding: .utf8)   // atomic: the driver never reads half a file
    }

    /// Debounced: typing a name rewrites the list ~0.3 s after the last keystroke; quick re-checks then clear "Updating devices…".
    private func scheduleNamesWrite() {
        pendingWrite?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.syncNames()
            // route too: a channel change removes + re-adds the device, so restart its routes as soon as it is back
            for t in [0.5, 0.8, 1.2, 2.0, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { self?.tick() } }
        }
        pendingWrite = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func isReady(_ slot: Int) -> Bool { ready.contains(slot) }

    /// devices.txt content: line k = "name" or "name<TAB>channels" of slot k, empty line = unused slot.
    var namesText: String {
        let top = devices.map(\.slot).max() ?? 0
        return (0...max(0, top)).map { k in devices.first { $0.slot == k }?.driverLine ?? "" }.joined(separator: "\n")
    }

    func freeName(_ base: String, except id: UUID?) -> String {
        uniqueName(base, taken: Set(devices.filter { $0.id != id }.map(\.sysName)))
    }

    /// New device on a fresh slot; prefers slots above every used one so a just-deleted device's UID isn't reused right away.
    func addDevice() -> UUID? {
        let used = Set(devices.map(\.slot))
        let free = (0..<8).filter { !used.contains($0) }
        guard let slot = free.first(where: { $0 > (used.max() ?? -1) }) ?? free.first else { return nil }
        let d = VDev(name: freeName("SoundRouter \(slot + 1)", except: nil), slot: slot)
        devices.append(d)
        return d.id
    }
    func newDevice() { if let id = addDevice() { sel = id } }

    // MARK: undo (every destructive edit can be taken back: Edit > Undo / Redo)
    @Published private(set) var undoName: String?
    @Published private(set) var redoName: String?
    private var undoStack: [(name: String, state: [VDev])] = []
    private var redoStack: [(name: String, state: [VDev])] = []
    /// Call BEFORE a destructive edit: remembers the current state.
    func remember(_ name: String) {
        undoStack.append((name, devices)); if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll(); undoName = name; redoName = nil
    }
    func undo() {
        guard let u = undoStack.popLast() else { return }
        redoStack.append((u.name, devices)); devices = u.state
        undoName = undoStack.last?.name; redoName = u.name; fixSelection()
    }
    func redo() {
        guard let r = redoStack.popLast() else { return }
        undoStack.append((r.name, devices)); devices = r.state
        undoName = r.name; redoName = redoStack.last?.name; fixSelection()
    }
    private func fixSelection() { if !devices.contains(where: { $0.id == sel }) { sel = devices.first?.id } }

    /// One-time (and on driver updates): writes device names, installs the driver bundle, restarts coreaudiod (one admin prompt).
    func install() {
        guard let res = Bundle.main.resourceURL else { return }
        let names = FileManager.default.temporaryDirectory.appendingPathComponent("sr-names-\(UUID().uuidString).txt")
        try? namesText.write(to: names, atomically: true, encoding: .utf8)
        let cmd = "/bin/sh '\(res.path)/install.sh' '\(names.path)' '\(res.path)/SoundRouter.driver'"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        installing = true; installError = nil
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", script]
            let err = Pipe(); p.standardError = err
            try? p.run(); p.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.installing = false
                if p.terminationStatus != 0 { self.installError = msg.isEmpty ? "Install failed" : msg }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.tick() } }   // coreaudiod needs a moment
            }
        }
    }
}

// MARK: - app
@main struct SoundRouterApp: App {
    @StateObject var store = Store()
    var body: some Scene {
        WindowGroup("SoundRouter") { ContentView().environmentObject(store).frame(minWidth: 1040, idealWidth: Double(ProcessInfo.processInfo.environment["SR_UI_WIDTH"] ?? "") ?? 1180, minHeight: 560, idealHeight: 680) }   // SR_UI_WIDTH is for screenshots/QA
            .windowToolbarStyle(.unified)
            .commands { DeviceCommands(store: store) }
    }
}

struct DeviceCommands: Commands {
    @ObservedObject var store: Store
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Device") { store.newDevice() }.keyboardShortcut("n").disabled(store.devices.count >= 8)
        }
        CommandGroup(after: .newItem) {
            Button("Rename Device") { store.renameAsk += 1 }.disabled(store.sel == nil)
            Button("Delete Device…") { store.deleteAsk = true }
                .disabled(store.devices.count < 2 || store.sel == nil || store.renaming)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(store.undoName.map { "Undo \($0)" } ?? "Undo") { store.undo() }
                .keyboardShortcut("z").disabled(store.undoName == nil || store.renaming)
            Button(store.redoName.map { "Redo \($0)" } ?? "Redo") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(store.redoName == nil || store.renaming)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            Sidebar(sel: $store.sel).navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if store.needsInstall { InstallBanner() }
                if let i = store.devices.firstIndex(where: { $0.id == store.sel }) {
                    let id = store.devices[i].id
                    DeviceDetail(d: $store.devices[i]) {
                        // leave the detail view first, then remove: removing under a live index binding can crash SwiftUI
                        store.remember("Delete Device")
                        store.sel = store.devices.first { $0.id != id }?.id
                        DispatchQueue.main.async { store.devices.removeAll { $0.id == id } }
                    }.id(id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.circle").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("No virtual device selected").font(.headline)
                        Text("Create one with “New Virtual Device”.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { store.sel = store.sel ?? store.devices.first?.id }
        .toolbar {
            ToolbarItem(placement: .principal) {   // app logo next to the name in the title bar
                HStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 20, height: 20)
                    Text("SoundRouter").font(.headline)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .background(HideTitleText())   // the logo + name above replace the plain title text (window title itself is kept)
    }
}

/// Hides the title text in the title bar (keeps the window title for Mission Control / Window menu).
struct HideTitleText: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { v.window?.titleVisibility = .hidden }; return v }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { v.window?.titleVisibility = .hidden } }
}

// MARK: - small components
struct PillToggle: View {
    @Binding var isOn: Bool
    var label = ""
    var body: some View {
        Button { withAnimation(.snappy(duration: 0.15)) { isOn.toggle() } } label: {
            HStack(spacing: 4) {
                if isOn { Text("On"); knob } else { knob; Text("Off") }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 20)
            .background(Capsule().fill(isOn ? Theme.teal : Theme.off))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label).accessibilityValue(isOn ? "On" : "Off")
    }
    private var knob: some View { Circle().fill(.white).frame(width: 12, height: 12) }
}

/// A level meter with ballistics: fast attack, smooth release and a peak-hold line (see `Ballistics`).
/// Each bar animates itself at 60 Hz; the rest of the window is not re-laid out per meter frame (that cost ~30% CPU).
struct LevelBar: View {
    var live = true                 // false: route not running -> no animation at all (idle window costs ~0 CPU)
    let level: () -> Float
    private final class Box { var ball = Ballistics(); var last = Date.distantPast }
    @State private var st = Box()
    var body: some View {
        let on = live || Meter.fake
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !on)) { ctx in
            let (shown, peak) = advance(on, ctx.date)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {   // rounded track, but the fill ends square so its edge sits right on the peak line
                        Rectangle().fill(Color.primary.opacity(0.12))
                        Rectangle().fill(shown > 0.97 ? Theme.off : Theme.teal).frame(width: max(0, w * CGFloat(shown)))
                    }.clipShape(Capsule())
                    if peak > 0.04 {   // the peak-hold line
                        Rectangle().fill(peak > 0.97 ? Theme.off : Color.primary.opacity(0.85)).frame(width: 2, height: 10)
                            .offset(x: min(w - 2, max(0, w * CGFloat(peak) - 1)))
                    }
                }
            }
        }.frame(height: 7)
    }
    private func advance(_ on: Bool, _ now: Date) -> (Float, Float) {
        guard on else { st.ball = Ballistics(); st.last = .distantPast; return (0, 0) }
        let dt = st.last == .distantPast ? 1.0 / 60 : min(0.1, max(0.001, now.timeIntervalSince(st.last)))
        st.last = now
        st.ball.step(level: level(), dt: dt)
        return (st.ball.shown, st.ball.peak)
    }
}

/// One engine snapshot shared by all bars of a frame (snapshot() resets the peaks, so it must be taken once per frame).
enum Meter {
    static var engine: Engine?
    /// SR_FAKE_LEVELS=1: synthetic pulsing levels so screenshots of the UI-only build show moving bars and peak lines.
    static let fake = ProcessInfo.processInfo.environment["SR_FAKE_LEVELS"] != nil
    private static func synth(_ k: Int) -> Float {
        let t = Date().timeIntervalSinceReferenceDate
        return Float(0.03 + 0.9 * pow(max(0, sin(t * 1.3 + Double(k) * 0.9)), 6))
    }
    private static var lv: [UUID: Engine.Levels] = [:], at = Date.distantPast
    private static func fresh() { if Date().timeIntervalSince(at) > 0.03, let e = engine { lv = e.snapshot(); at = Date() } }
    /// Source channel `c` of route `id` (after gain).
    static func inp(_ id: UUID, _ c: Int) -> Float { if fake { return synth(Int(id.uuid.0) + c) }; fresh(); return lv[id].map { c < $0.ins.count ? $0.ins[c] : 0 } ?? 0 }
    /// What route `id` writes to output channel `o`.
    static func out(_ id: UUID, _ o: Int) -> Float { if fake { return synth(Int(id.uuid.1) + o + 3) }; fresh(); return lv[id].map { o < $0.outs.count ? $0.outs[o] : 0 } ?? 0 }
}

/// A connection point. Reports its centre in the "board" coordinate space (used to draw and hit-test cables).
private struct SnapDotKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues { var snapDot: String? { get { self[SnapDotKey.self] } set { self[SnapDotKey.self] = newValue } } }

struct Dot: View {
    let id: DotID
    var active = true
    @Environment(\.snapDot) private var snapDot
    var body: some View {
        let hot = snapDot == id.key        // the cable being dragged would snap here
        Circle().fill(active || hot ? Theme.teal : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .overlay(Circle().stroke(Theme.teal.opacity(hot ? 0.5 : 0), lineWidth: 5).frame(width: 15, height: 15))
            .scaleEffect(hot ? 1.5 : 1).animation(.spring(duration: 0.12), value: hot)
            .help("Drag to another channel to connect a cable")
            .background(GeometryReader { g in
                let f = g.frame(in: .named("board"))
                Color.clear.preference(key: DotPos.self, value: [id.key: CGPoint(x: f.midX, y: f.midY)])
            })
    }
}

struct DotPos: PreferenceKey {
    static var defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) { value.merge(nextValue()) { $1 } }
}

/// Shared vertical metrics so channel rows of all three columns sit on the same y (=> cables between them are straight).
enum Row {
    static let h: CGFloat = 18          // one channel row
    static let gap: CGFloat = 10        // between channel rows
    static let header: CGFloat = 40     // column title block
    static let cardHeader: CGFloat = 34 // card title bar
    static let cardW: CGFloat = 220     // source / monitor card width (fixed)
    static let outW: CGFloat = 200      // output card width (fixed)
    static let minGap: CGFloat = 48     // narrowest cable run between columns
    static var block: CGFloat { h * 2 + gap }
}

/// Cable between two dots: dead straight (on a whole pixel) when they are level, otherwise flat ends joined by one smooth S-bend.
struct Cable: Shape {
    var from: CGPoint, to: CGPoint
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if CableGeom.isStraight(from, to) {
            let y = (((from.y + to.y) / 2) * 2).rounded() / 2
            p.move(to: CGPoint(x: from.x, y: y)); p.addLine(to: CGPoint(x: to.x, y: y))
            return p
        }
        let (x1, x2) = CableGeom.bend(from, to), mid = (x1 + x2) / 2   // S spans the whole gap (its flat ends hide under the cards)
        p.move(to: from)
        p.addLine(to: CGPoint(x: x1, y: from.y))
        p.addCurve(to: CGPoint(x: x2, y: to.y), control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
        p.addLine(to: to)
        return p
    }
}

/// Card with a tinted header (title + optional trailing control) and a padded body.
struct Card<Trailing: View, Body: View>: View {
    let title: String
    var selected = false                 // clicked = active: teal border, ⌫ deletes it
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Body
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(title); Spacer(minLength: 8); trailing }
                .padding(.horizontal, 10).frame(height: Row.cardHeader).background(Theme.cardHeader)
            content.padding(10)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.teal : Theme.stroke, lineWidth: selected ? 3 : 1))   // active = bold border, no glow
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Options" fold-out as a plain Button. A SwiftUI DisclosureGroup stopped reacting to real clicks once the board got its
/// drag gesture (Buttons keep working under it), and a Button is also a proper accessibility element.
struct OptionsDisclosure<Content: View>: View {
    @Binding var open: Bool
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Text("Options")
                    Spacer(minLength: 0)
                }.frame(height: 15).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Options").accessibilityValue(open ? "expanded" : "collapsed")
            if open { content }
        }.font(.callout)
    }
}

/// Drops keyboard focus from any text field (clicking elsewhere should end title editing).
func endEditing() { NSApp.keyWindow?.makeFirstResponder(nil) }

/// The app's own icon for app sources, a tinted tile with a mic for input devices / a speaker for all system audio.
struct SourceIcon: View {
    let s: SourceCfg
    var size: CGFloat = 44
    var body: some View {
        if s.kind == .app {
            Image(nsImage: IconCache.app(s.ref)).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: s.kind == .mic ? "mic.fill" : "speaker.wave.3.fill").font(.system(size: size * 0.42)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22).fill(s.kind == .mic ? Theme.teal.gradient : Color.indigo.gradient))
        }
    }
}

/// "+" that opens an AppKit menu built at click time from a snapshot, at the pointer
/// (a SwiftUI Menu rebuilt by every refresh glitched while open; an NSMenu is never re-rendered while tracking).
struct AddMenuButton: View {
    let label: String
    var help = ""
    let menu: () -> NSMenu
    var body: some View {
        Button { menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } label: {
            Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Theme.teal).frame(width: 26, height: 26).contentShape(Rectangle()).offset(y: -3)
        }.buttonStyle(.plain).help(help).accessibilityLabel(label)
    }
}

/// Inline hint when macOS denies microphone access (needed for input-device sources only: monitors no longer read the virtual device).
struct MicDenied: View {
    var body: some View {
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Microphone access is off", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }.buttonStyle(.link)
            }.font(.caption)
        }
    }
}

// MARK: - sidebar
struct Sidebar: View {
    @EnvironmentObject var store: Store
    @Binding var sel: UUID?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "waveform.circle.fill").foregroundStyle(Theme.teal); Text("Devices").font(.headline); Spacer() }
                .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($store.devices) { $d in
                        DeviceCard(d: $d, selected: sel == d.id, ready: store.isReady(d.slot))
                            .contentShape(Rectangle()).onTapGesture { endEditing(); sel = d.id }
                        Divider()
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    if let id = store.addDevice() { sel = id }
                } label: { Label("New Virtual Device", systemImage: "plus.circle.fill") }
                    .buttonStyle(.plain).disabled(store.devices.count >= 8).help("Up to 8 virtual devices")
                Spacer()
                Button { store.deleteAsk = true } label: { Image(systemName: "minus.circle.fill").font(.title3) }
                    .buttonStyle(.plain).disabled(store.devices.count < 2 || store.sel == nil)
                    .help(store.devices.count < 2 ? "Keep at least one device" : "Delete the selected virtual device…")
                    .accessibilityLabel("Delete the selected virtual device")
            }.padding(12)
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject var store: Store
    @Binding var d: VDev
    let selected: Bool
    let ready: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(d.name).font(.headline).lineLimit(1)
                Spacer()
                PillToggle(isOn: $d.enabled, label: "\(d.name) enabled")
            }
            HStack(spacing: 8) {
                if d.sources.isEmpty {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 30, height: 30)
                } else {
                    HStack(spacing: -6) {
                        ForEach(Array(d.sources.prefix(4).enumerated()), id: \.element.id) { n, src in
                            SourceIcon(s: src, size: 30).opacity(d.enabled && !src.muted ? 1 : 0.4).zIndex(Double(-n))
                        }
                    }
                    if d.sources.count > 4 { Text("+\(d.sources.count - 4)").font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 2) {
                    if d.sources.isEmpty { Text("No sources").font(.caption).opacity(0.7) }
                    if !ready && store.needsInstall {
                        Label("Driver not installed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn)
                    } else if !ready {
                        if store.phases[d.slot] == .updating {
                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Updating devices…") }.font(.caption).opacity(0.7)
                        } else if store.phases[d.slot] == .failed {
                            Label("Device didn't appear", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn)
                                .help("macOS audio did not publish this device. Rename it or restart SoundRouter to try again.")
                        }
                    } else if d.monitors.contains(where: { m in !store.outputs.contains { $0.uid == m.uid } }) {
                        Label("Missing monitor device", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: d.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18).foregroundStyle(.secondary)
                Slider(value: $d.volume, in: 0...1).tint(Theme.teal).accessibilityLabel("\(d.name) volume")
                Text("\(Int(d.volume * 100))%").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
            }
        }
        .padding(12)
        .background(selected ? Theme.tealDeep.opacity(0.85) : Color.clear)
        .foregroundStyle(selected ? Color.white : Color.primary)
    }
}

struct InstallBanner: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            VStack(alignment: .leading) {
                Text(store.driverIssue ?? "").bold()
                Text(store.installError ?? "Installs the driver and restarts macOS audio for a moment (asks for your admin password once). Adding, renaming and deleting devices needs no password afterwards.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer()
            Button(store.installing ? "Working…" : (store.driverIssue == "Driver update available." ? "Update" : "Install")) { store.install() }.disabled(store.installing).buttonStyle(.borderedProminent).tint(Theme.teal)
        }.padding(10).background(Theme.warn.opacity(0.15))
    }
}

// MARK: - detail: sources -> output channels -> monitors
struct DeviceDetail: View {
    @EnvironmentObject var store: Store
    @Binding var d: VDev
    var onDelete: () -> Void
    @State private var showMonitors = true
    @FocusState private var titleFocused: Bool
    @State private var renaming = false
    // patching: dot centres (board coordinates), cable under the pointer, the drag in progress
    @State private var dots: [String: CGPoint] = [:]
    @State private var hover: Link?
    @State private var drag: Drag?
    // selection: a clicked card / cable is "active"; the footer Delete button deletes it (⌫ also deletes an active cable)
    enum Sel: Hashable { case source(UUID), pair(Int), monitor(UUID), cable(String) }
    @State private var sel: Sel?
    @State private var pointerIsHand = false
    struct Drag { var start: String?; var moving: (link: Link, fixed: String)?; var origin: CGPoint; var at: CGPoint; var snap: String? }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if renaming {
                    TextField("Device name", text: $d.name).textFieldStyle(.plain).font(.title.bold()).fixedSize()
                        .focused($titleFocused).onSubmit { stopRename() }
                        .onChange(of: titleFocused) { _, f in if !f { stopRename() } }   // focus lost (click elsewhere) = editing ends
                } else {
                    Text(d.name).font(.title.bold()).lineLimit(1)
                        .onTapGesture(count: 2) { startRename() }
                }
                Button { renaming ? stopRename() : startRename() } label: {
                    Image(systemName: renaming ? "checkmark.circle.fill" : "pencil").foregroundStyle(renaming ? Theme.teal : Color.secondary)
                }.buttonStyle(.plain).help(renaming ? "Done" : "Rename device").accessibilityLabel(renaming ? "Finish renaming" : "Rename device")
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in   // only which routes are live; the bars animate themselves
                let live = Set(store.engine.active.keys)
                ScrollView { board(live).padding(20) }
            }
            Divider()
            HStack {
                Button(role: .destructive) { deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .disabled(!canDelete)
                    .help(canDelete ? "Delete “\(selectionName ?? "")”" : "Click a card or a cable to make it active, then press Delete")
                    .background {   // ⌫ unplugs the active cable (cards still need the Delete button)
                        Button("") { deleteSelection() }.keyboardShortcut(.delete, modifiers: []).opacity(0).accessibilityHidden(true)
                            .disabled({ if case .cable? = sel { return renaming || !canDelete } else { return true } }())
                    }
                Spacer()
                Button { withAnimation { showMonitors.toggle() } } label: {
                    Label(showMonitors ? "Hide Monitors" : "Show Monitors", systemImage: showMonitors ? "eye.slash" : "eye")
                }
            }.padding(10)
            .confirmationDialog("Delete “\(d.name)”?", isPresented: $store.deleteAsk) {
                Button("Delete", role: .destructive, action: onDelete)
            } message: { Text("Its routing is removed and it disappears from the system's audio devices.") }
        }
        .contentShape(Rectangle())
        .onTapGesture { stopRename(); sel = nil }                       // click anywhere else = title and selection no longer active
        .onDisappear { setPointer(over: false) }
        .onChange(of: store.renameAsk) { _, _ in startRename() }
        .onChange(of: renaming) { _, r in store.renaming = r }
    }

    private func select(_ s: Sel?) { stopRename(); endEditing(); sel = s }

    private var selectionName: String? {
        switch sel {
        case .source(let id)?: return d.sources.first { $0.id == id }?.title
        case .monitor(let id)?: return d.monitors.first { $0.id == id }?.name
        case .pair(let p)?: return "Channels \(2 * p + 1) & \(2 * p + 2)"
        case .cable?: return "cable"
        case nil: return nil
        }
    }

    /// The footer Delete button is on only while something deletable is active (the first output pair can't be deleted).
    private var canDelete: Bool {
        switch sel {
        case .source(let id)?: return d.sources.contains { $0.id == id }
        case .monitor(let id)?: return d.monitors.contains { $0.id == id }
        case .pair(let p)?: return p > 0 && p < d.pairs
        case .cable(let id)?: return Patch.links(d, monitors: showMonitors).contains { $0.id == id }
        case nil: return false
        }
    }

    private func deleteSelection() {
        guard canDelete, let s = sel else { return }
        store.remember("Delete \(selectionName ?? "")")
        switch s {
        case .source(let id): d.sources.removeAll { $0.id == id }
        case .monitor(let id): d.monitors.removeAll { $0.id == id }
        case .pair(let p): d.removePair(p)
        case .cable(let id): if let l = Patch.links(d, monitors: showMonitors).first(where: { $0.id == id }) { Patch.remove(&d, l) }
        }
        sel = nil
    }

    private func startRename() { renaming = true; DispatchQueue.main.async { titleFocused = true } }
    private func stopRename() {
        guard renaming else { return }
        renaming = false; titleFocused = false; endEditing()
        let base = d.name.trimmingCharacters(in: .whitespaces).isEmpty ? "SoundRouter" : d.sysName   // never nameless
        let free = store.freeName(base, except: d.id)                                              // never two with one name
        if free != d.name { d.name = free }
    }

    func board(_ live: Set<UUID>) -> some View {
        let links = Patch.links(d, monitors: showMonitors)
        // Cards keep a fixed width; only the gaps stretch with the window, so it is the cables that get longer.
        return HStack(alignment: .top, spacing: 0) {
            sourcesColumn(live).frame(width: Row.cardW)
            Spacer(minLength: Row.minGap)
            outputColumn(live).frame(width: Row.outW)
            if showMonitors {
                Spacer(minLength: Row.minGap)
                monitorsColumn(live).frame(width: Row.cardW)
            }
        }
        .onPreferenceChange(DotPos.self) { dots = $0 }
        .background { cables(links) }
        .overlay { rubberBand.allowsHitTesting(false) }
        .coordinateSpace(name: "board")
        .environment(\.snapDot, drag?.snap)
        // one gesture for click and drag; simultaneous so the cards' own buttons / sliders keep working
        .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in dragChanged(v, links) }
            .onEnded { v in dragEnded(v) })
        .onContinuousHover(coordinateSpace: .local) { ph in
            var h: Link?, overDot = false
            if case .active(let p) = ph, drag == nil {
                h = Patch.hit(p, links: links, dots: dots)
                overDot = nearestDot(at: p, in: dots, kinds: [.src, .oin, .oout, .mon]) != nil
            }
            if h != hover { hover = h }
            setPointer(over: overDot || h != nil)
        }
    }

    /// Hand cursor over a dot or a cable: they can be dragged / clicked.
    private func setPointer(over: Bool) {
        if over && !pointerIsHand { NSCursor.pointingHand.push(); pointerIsHand = true }
        else if !over && pointerIsHand { NSCursor.pop(); pointerIsHand = false }
    }

    private func dragChanged(_ v: DragGesture.Value, _ links: [Link]) {
        if drag != nil { drag?.at = v.location; updateSnap(); return }
        let p = v.startLocation
        if let k = nearestDot(at: p, in: dots, kinds: [.src, .oin, .oout, .mon]) {
            // a plugged dot behaves like a jack: dragging it pulls its cable out (dropped on empty space = unplugged)
            if !NSEvent.modifierFlags.contains(.option), let l = links.last(where: { $0.from == k || $0.to == k }) {   // ⌥ = start a new cable from a plugged dot
                drag = Drag(start: nil, moving: (l, l.from == k ? l.to : l.from), origin: p, at: v.location, snap: nil)
            } else {
                drag = Drag(start: k, moving: nil, origin: p, at: v.location, snap: nil)
            }
        } else if let l = Patch.hit(p, links: links, dots: dots), let a = dots[l.from], let b = dots[l.to] {
            // grabbing a cable: the end nearer the pointer comes loose, the other end stays put
            let fixed = hypot(p.x - a.x, p.y - a.y) > hypot(p.x - b.x, p.y - b.y) ? l.from : l.to
            drag = Drag(start: nil, moving: (l, fixed), origin: p, at: v.location, snap: nil)
        } else {
            drag = Drag(start: nil, moving: nil, origin: p, at: v.location, snap: nil)   // inert (started on a card or empty space)
        }
        hover = nil
    }

    /// Magnet: find the compatible dot near the pointer; light it up and give a trackpad tick when it grabs.
    private func updateSnap() {
        guard let g = drag, g.start != nil || g.moving != nil else { return }
        let t = Patch.snapTarget(start: g.start, moving: g.moving, at: g.at, dots: dots)
        guard t != g.snap else { return }
        drag?.snap = t
        if t != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func dragEnded(_ v: DragGesture.Value) {
        defer { drag = nil }
        guard let g = drag, g.start != nil || g.moving != nil else { return }
        stopRename()
        if hypot(v.location.x - g.origin.x, v.location.y - g.origin.y) < 3 {   // a click, not a drag
            if let m = g.moving, nearestDot(at: g.origin, in: dots, kinds: [.src, .oin, .oout, .mon]) == nil { select(.cable(m.link.id)) }                  // click on a cable = select it (⌫ deletes)
            return
        }
        let drop = Patch.drop(start: g.start, moving: g.moving, at: v.location, dots: dots)
        if drop != .none { store.remember("Edit Cable"); Patch.apply(&d, drop) }
    }

    /// Left-side dot kinds: their cables leave to the right.
    private func leftEnd(_ key: String) -> Bool { [.src, .oout].contains(DotID(key)?.kind) }

    @ViewBuilder var rubberBand: some View {
        if let g = drag, let key = g.start ?? g.moving?.fixed, let a = dots[key],
           hypot(g.at.x - g.origin.x, g.at.y - g.origin.y) >= 3 {
            let end = g.snap.flatMap { dots[$0] } ?? g.at            // snapped: the end sits exactly on the dot
            let (f, t) = leftEnd(key) ? (a, end) : (end, a)
            Cable(from: f, to: t).stroke(Theme.teal, style: StrokeStyle(lineWidth: g.snap != nil ? 3 : 2, lineCap: .round, dash: g.snap != nil ? [] : [5, 3]))
        }
    }

    func cables(_ links: [Link]) -> some View {
        ZStack {
            ForEach(links, id: \.id) { l in
                if let a = dots[l.from], let b = dots[l.to], !(l == drag?.moving?.link && hypot(drag!.at.x - drag!.origin.x, drag!.at.y - drag!.origin.y) >= 3) {
                    let hot = l == hover, picked = sel == .cable(l.id)
                    Cable(from: a, to: b)
                        .stroke(picked ? Color.primary : (hot ? Theme.teal : Theme.teal.opacity(dim(l) ? 0.25 : 0.9)),
                                style: StrokeStyle(lineWidth: picked ? 3.5 : (hot ? 3 : 2), lineCap: .round))
                }
            }
        }
    }

    private func dim(_ l: Link) -> Bool {
        if !d.enabled { return true }
        if let x = DotID(l.from), x.kind == .src { return d.sources.first { $0.id == x.owner }?.muted ?? true }
        if let y = DotID(l.to), y.kind == .mon { return !(d.monitors.first { $0.id == y.owner }?.on ?? false) }
        return false
    }

    func columnHeader<B: View>(_ title: String, _ subtitle: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.title3.bold()); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            button()
        }.frame(height: Row.header, alignment: .top)
    }

    // MARK: sources
    func sourcesColumn(_ live: Set<UUID>) -> some View {
        let n = d.sources.count
        return VStack(alignment: .leading, spacing: 14) {
            columnHeader("Sources", n == 1 ? "1 Source" : "\(n) Sources") {
                AddMenuButton(label: "Add to Sources", help: "Add an app, an input device or all system audio") {
                    AddMenu.sources(apps: AddMenu.runningApps(), inputs: store.inputs, used: d.sources) { add($0) }
                }
            }
            if d.sources.isEmpty { EmptyHint(text: "Add an app or input device\nwith the + button") }
            ForEach($d.sources) { $s in
                SourceCard(s: $s, live: live.contains(s.id), ready: store.isReady(d.slot) && d.enabled, selected: sel == .source(s.id))
                    .simultaneousGesture(TapGesture().onEnded { select(.source(s.id)) })   // alongside the card's own controls (Options, pills, sliders), never instead of them
                    .accessibilityAction(named: "Select") { select(.source(s.id)) }
            }
        }
    }

    private func add(_ p: AddMenu.Pick) {
        switch p {
        case .system: d.sources.append(SourceCfg(kind: .system, ref: "system", title: "All System Audio"))
        case .app(let a): d.sources.append(SourceCfg(kind: .app, ref: a.bid, title: a.name))
        case .input(let dev):
            if !Store.uiOnly { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
            d.sources.append(SourceCfg(kind: .mic, ref: dev.uid, title: dev.name, inCh: dev.ch))
        }
    }

    // MARK: output
    func outputColumn(_ live: Set<UUID>) -> some View {
        let ids = d.sources.filter { !$0.muted && live.contains($0.id) }.map(\.id), on = d.enabled   // level = sum of what the live sources write
        let full = d.pairs >= VDev.maxPairs
        return VStack(alignment: .leading, spacing: 14) {
            columnHeader("Output Channels", "\(d.channels) Channels") {
                Button { d.pairs += 1 } label: { Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(full ? Color.secondary : Theme.teal).frame(width: 26, height: 26).contentShape(Rectangle()).offset(y: -3) }
                    .buttonStyle(.plain).disabled(full)
                    .help(full ? "At most \(VDev.maxPairs * 2) channels" : "Add Channels \(d.channels + 1) & \(d.channels + 2)")
                    .accessibilityLabel("Add to Output Channels")
            }
            ForEach(0..<d.pairs, id: \.self) { p in
                Card(title: "Channels \(2 * p + 1) & \(2 * p + 2)", selected: sel == .pair(p)) {
                    EmptyView()
                } content: {
                    VStack(spacing: Row.gap) {
                        ForEach(2 * p..<2 * p + 2, id: \.self) { o in
                            HStack(spacing: 8) {
                                Dot(id: DotID(.oin, nil, o), active: d.enabled)
                                Text("Channel \(o + 1)" + (p == 0 ? (o == 0 ? " (L)" : " (R)") : "")).font(.caption).lineLimit(1)
                                LevelBar(live: on && !ids.isEmpty) { on ? min(1, ids.reduce(0) { $0 + Meter.out($1, o) }) : 0 }
                                Dot(id: DotID(.oout, nil, o), active: d.enabled)
                            }.frame(height: Row.h)
                        }
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { select(.pair(p)) })   // alongside the card's own controls (Options, pills, sliders), never instead of them
                .accessibilityAction(named: "Select") { select(.pair(p)) }
            }
        }
    }

    // MARK: monitors
    func monitorsColumn(_ live: Set<UUID>) -> some View {
        let n = d.monitors.count
        return VStack(alignment: .leading, spacing: 14) {
            columnHeader("Monitors", n == 1 ? "1 Device" : "\(n) Devices") {
                AddMenuButton(label: "Add to Monitors", help: "Listen to this device on an output") {
                    AddMenu.monitors(outputs: store.outputs, used: d.monitors) { o in d.monitors.append(MonitorCfg(uid: o.uid, name: o.name, gain: 1)) }
                }
            }
            if d.monitors.isEmpty { EmptyHint(text: "Add an output to listen to this mix (use headphones to avoid feedback)") }
            ForEach($d.monitors) { $m in
                MonitorCard(m: $m, live: live.contains(m.id), connected: store.outputs.contains { $0.uid == m.uid }, selected: sel == .monitor(m.id))
                    .simultaneousGesture(TapGesture().onEnded { select(.monitor(m.id)) })   // alongside the card's own controls (Options, pills, sliders), never instead of them
                    .accessibilityAction(named: "Select") { select(.monitor(m.id)) }
            }
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(18)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

struct SourceCard: View {
    @Binding var s: SourceCfg
    let live: Bool
    let ready: Bool
    var selected = false
    @State private var open = false

    private var waitingHint: String {
        switch s.kind {
        case .app: return "Waiting for this app to play audio. If it never starts, allow SoundRouter under System Settings › Privacy & Security › System Audio Recording."
        case .system: return "Waiting for audio. Allow SoundRouter under System Settings › Privacy & Security › System Audio Recording."
        case .mic: return "This input device is not available right now."
        }
    }

    private func label(_ c: Int) -> String { s.inCh == 2 ? (c == 0 ? "1 (L)" : "2 (R)") : "\(c + 1)" }

    var body: some View {
        Card(title: s.title, selected: selected) {
            PillToggle(isOn: Binding(get: { !s.muted }, set: { s.muted = !$0 }), label: "\(s.title) enabled")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    SourceIcon(s: s, size: 44).opacity(s.muted ? 0.4 : 1)
                        .help(ready && !live && !s.muted ? waitingHint : "")   // no permanent status text; the hint lives in a tooltip
                    VStack(spacing: Row.gap) {
                        ForEach(0..<s.inCh, id: \.self) { c in
                            HStack(spacing: 8) {
                                Text(label(c)).font(.caption).frame(width: 30, alignment: .trailing)
                                LevelBar(live: live && !s.muted) { [id = s.id] in Meter.inp(id, c) }
                                Dot(id: DotID(.src, s.id, c), active: live && !s.muted)
                            }.frame(height: Row.h)
                        }
                    }
                }.frame(minHeight: Row.block, alignment: .top)
                if s.kind == .mic && !s.muted { MicDenied() }
                OptionsDisclosure(open: $open) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                            Slider(value: $s.gain, in: 0...1).tint(Theme.teal).accessibilityLabel("\(s.title) volume")
                            Text("\(Int(s.gain * 100))%").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        }
                        if s.kind == .app {
                            Toggle("Mute when capturing", isOn: Binding(get: { !s.hearOriginal }, set: { s.hearOriginal = !$0 })).toggleStyle(.checkbox)
                                .help("Silence this app on your speakers while SoundRouter captures it")
                        }
                    }.padding(.top, 6)
                }
            }
        }
    }
}

struct MonitorCard: View {
    @Binding var m: MonitorCfg
    let live: Bool
    let connected: Bool
    var selected = false
    @State private var open = false
    @State private var vol: Float?   // the output device's own volume: the slider is the system volume, no second gain stage
    private let poll = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        Card(title: m.name, selected: selected) {
            PillToggle(isOn: $m.on, label: "\(m.name) monitoring")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: Row.gap) {
                    ForEach(0..<2, id: \.self) { j in
                        HStack(spacing: 8) {
                            Dot(id: DotID(.mon, m.id, j), active: live && m.on && m.map[j] >= 0)
                            LevelBar(live: live && m.on) { [id = m.id] in Meter.out(id, j) }
                            Text(j == 0 ? "1 (L)" : "2 (R)").font(.caption).lineLimit(1)
                        }.frame(height: Row.h)
                    }
                }
                if !connected { Label("Device not connected", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn) }
                OptionsDisclosure(open: $open) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                            Slider(value: Binding(get: { vol ?? 0 }, set: { vol = $0; HAL.setVolume(m.uid, $0) }), in: 0...1)
                                .tint(Theme.teal).disabled(vol == nil).accessibilityLabel("\(m.name) volume")
                            Text(vol.map { "\(Int($0 * 100))%" } ?? "–").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                        }
                    }.padding(.top, 6)
                }
            }
            .onAppear { vol = HAL.volume(m.uid); if m.gain != 1 { m.gain = 1 } }
            .onReceive(poll) { _ in if !Store.uiOnly { let v = HAL.volume(m.uid); if v != vol { vol = v } } }
        }
    }
}

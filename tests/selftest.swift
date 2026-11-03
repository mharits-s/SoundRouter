// End-to-end check using the real Engine: tonegen -> tap -> virtual device -> loopback -> measured at its input,
// plus headless checks of the pure UI logic (routing, cable hit-testing, config migration, add menus).
// Modes: selftest <tonegen>            everything (needs the installed driver + permissions)
//        selftest <tonegen> logic      only the headless logic checks
import AVFoundation
import AppKit
import CoreAudio

var log = ""
func say(_ s: String) { print(s); log += s + "\n"; try? log.write(toFile: "/tmp/sr-selftest.txt", atomically: true, encoding: .utf8) }
var failed = false
func check(_ ok: Bool, _ s: String) { say((ok ? "PASS " : "FAIL ") + s); if !ok { failed = true } }
func near(_ v: Float, _ want: Float, _ tol: Float = 0.06) -> Bool { abs(v - want) <= tol }
func fmt(_ a: [Float]) -> String { "[" + a.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]" }

/// per-channel peaks of a buffer list (channels of all buffers in order)
func chPeaks(_ i: UnsafePointer<AudioBufferList>, into pk: inout [Float]) {
    var ch = 0
    for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: i)) {
        let n = Int(b.mNumberChannels); guard n > 0, let m = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
        if pk.count < ch + n { pk += [Float](repeating: 0, count: ch + n - pk.count) }
        for k in 0..<Int(b.mDataByteSize) / 4 { pk[ch + k % n] = max(pk[ch + k % n], abs(m[k])) }
        ch += n
    }
}

/// per-channel peaks seen on the virtual device's input over `secs` (needs mic permission)
func measure(_ uid: String, _ secs: Double) -> [Float] {
    guard let d = HAL.device(uid: uid) else { return [-1] }
    var pk: [Float] = []; var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, i, _, _, _ in chPeaks(i, into: &pk) }
    AudioDeviceStart(d, proc!); Thread.sleep(forTimeInterval: secs); AudioDeviceStop(d, proc!); AudioDeviceDestroyIOProcID(d, proc!)
    return pk.isEmpty ? [0] : pk
}

/// keeps reading a virtual device's input (like a real recording app) so tests see what happens mid-stream
final class Listener {
    var pk: [Float] = []; var proc: AudioDeviceIOProcID?; let d: AudioObjectID
    init?(_ uid: String) {
        guard let d = HAL.device(uid: uid) else { return nil }; self.d = d
        AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { [unowned self] _, i, _, _, _ in chPeaks(i, into: &self.pk) }
        AudioDeviceStart(d, proc!)
    }
    func peaks(_ secs: Double) -> [Float] { pk = pk.map { _ in 0 }; Thread.sleep(forTimeInterval: secs); return pk.isEmpty ? [0] : pk }
    func peak(_ secs: Double) -> Float { peaks(secs).max() ?? 0 }
    func stop() { AudioDeviceStop(d, proc!); AudioDeviceDestroyIOProcID(d, proc!) }
}

func startGen(_ args: [String] = []) -> Process {
    let gen = Process(); gen.executableURL = URL(fileURLWithPath: CommandLine.arguments[1]); gen.arguments = args; try! gen.run()
    for _ in 0..<20 { if HAL.processes().contains(where: { $0.bid == "com.soundrouter.tonegen" }) { break }; Thread.sleep(forTimeInterval: 0.5) }
    return gen
}

let bhUID = "BlackHole64ch_UID"   // BlackHole 64ch: a monitor target whose input we can measure
let namesFile = "/Library/Application Support/SoundRouter/devices.txt"
let origNames = (try? String(contentsOfFile: namesFile, encoding: .utf8)) ?? "SoundRouter\n"
let testNames = "SoundRouter\nSoundRouter 2\n"
func setNames(_ t: String) { try? t.write(toFile: namesFile, atomically: true, encoding: .utf8) }
func waitFor(_ limit: Double = 3, _ ok: () -> Bool) -> Double {   // seconds until ok, or -1 after `limit` s
    let t0 = Date(); while Date().timeIntervalSince(t0) < limit { if ok() { return Date().timeIntervalSince(t0) }; Thread.sleep(forTimeInterval: 0.1) }; return -1
}

// MARK: - headless logic checks
func logicTests() {
    let sid = UUID(), mid = UUID()
    // dot keys
    check(DotID(DotID(.src, sid, 3).key) == DotID(.src, sid, 3) && DotID(DotID(.oin, nil, 5).key) == DotID(.oin, nil, 5)
          && DotID("src|x|1") == nil && DotID("bogus") == nil, "logic: dot keys round-trip, bad keys rejected")
    // nearestDot
    let dots = ["oin|0": CGPoint(x: 300, y: 100), "oin|1": CGPoint(x: 300, y: 128), DotID(.src, sid, 0).key: CGPoint(x: 200, y: 100),
                DotID(.src, sid, 1).key: CGPoint(x: 200, y: 128), "oout|0": CGPoint(x: 460, y: 100), "oout|1": CGPoint(x: 460, y: 128),
                DotID(.mon, mid, 0).key: CGPoint(x: 600, y: 100), DotID(.mon, mid, 1).key: CGPoint(x: 600, y: 128)]
    check(nearestDot(at: CGPoint(x: 305, y: 120), in: dots, kinds: [.oin]) == "oin|1"
          && nearestDot(at: CGPoint(x: 305, y: 120), in: dots, kinds: [.src]) == nil
          && nearestDot(at: CGPoint(x: 330, y: 100), in: dots, kinds: [.oin]) == nil, "logic: nearestDot picks the closest dot of the wanted kind within the radius")
    // cable geometry
    let a = CGPoint(x: 200, y: 100), b = CGPoint(x: 300, y: 100), c = CGPoint(x: 300, y: 128)
    check(CableGeom.distance(CGPoint(x: 250, y: 100), a, b) == 0 && CableGeom.distance(CGPoint(x: 250, y: 105), a, b) == 5
          && CableGeom.distance(CGPoint(x: 205, y: 100), a, b) == nil, "logic: straight cable distance, hidden ends ignored")
    let midS = CableGeom.distance(CGPoint(x: 250, y: 114), a, c) ?? 99, offS = CableGeom.distance(CGPoint(x: 250, y: 140), a, c) ?? 0
    check(midS < 1 && offS > 6 && CableGeom.isStraight(a, CGPoint(x: 300, y: 102)) && !CableGeom.isStraight(a, c),
          "logic: S-curve hit-test (centre \(midS), 26 pt away \(offS)), straight when < 2.5 pt apart")
    // routing masks
    check(Routing.defaults(2) == [1, 2] && Routing.defaults(1) == [3] && Routing.defaults(4) == [1, 2, 0, 0]
          && Routing.toggle(1, 2) == 5 && Routing.toggle(5, 2) == 1, "logic: default routing and mask toggle")
    check(Routing.dropPair(0b111111, 1) == 0b1111 && Routing.dropPair(0b100, 1) == 0 && Routing.dropPair(map: 3, 1) == -1
          && Routing.dropPair(map: 5, 1) == 3 && Routing.dropPair(map: 1, 1) == 1, "logic: removing a pair drops its bits and shifts higher channels")
    var v = VDev(name: "T"); v.pairs = 3
    var s = SourceCfg(kind: .app, ref: "x", title: "x"); s.id = sid; s.routes = [0b100, 0b10000]
    var m = MonitorCfg(uid: "spk", name: "spk"); m.id = mid; m.map = [4, 2]
    v.sources = [s]; v.monitors = [m]
    v.removePair(1)
    check(v.pairs == 2 && v.sources[0].routes == [0, 0b100] && v.monitors[0].map == [2, -1], "logic: removePair clears routes into it and clamps monitor maps")
    v.pairs = 1; v.sources[0].routes = [0b1100, 1]; v.monitors[0].map = [3, 1]
    v.sources.append(SourceCfg(kind: .mic, ref: "soundrouter.1", title: "loop"))
    var m4 = SourceCfg(kind: .mic, ref: "mic4", title: "m", inCh: 4); m4.routes = [1]
    v.sources.append(m4); v.monitors.append(MonitorCfg(uid: "soundrouter.2", name: "loop"))
    v.sanitize()
    check(v.sources.count == 2 && v.sources[0].routes == [0, 1] && v.sources[1].routes == [1, 2, 0, 0] && v.monitors.count == 1 && v.monitors[0].map == [-1, 1],
          "logic: sanitize clamps masks/maps to the channel count, pads routes, drops SoundRouter devices as mic/monitor")
    // patching
    var p = VDev(name: "P"); p.pairs = 2
    var ps = SourceCfg(kind: .app, ref: "x", title: "x"); ps.id = sid; p.sources = [ps]
    var pm = MonitorCfg(uid: "spk", name: "spk"); pm.id = mid; p.monitors = [pm]
    check(Patch.links(p).count == 4, "logic: default links = 2 source cables + 2 monitor cables")
    Patch.connect(&p, DotID(.src, sid, 0).key, "oin|2")
    Patch.connect(&p, "oin|3", DotID(.src, sid, 1).key)   // reversed drag
    check(p.sources[0].routes == [0b101, 0b1010], "logic: connect adds cables (both drag directions), one channel may feed several outputs")
    Patch.connect(&p, DotID(.src, sid, 0).key, "oin|2")
    check(p.sources[0].routes == [0b001, 0b1010], "logic: connecting an existing cable again toggles it off")
    check(!Patch.connect(&p, DotID(.src, sid, 0).key, "oout|1") && !Patch.connect(&p, "oin|0", "oin|1"), "logic: incompatible dots are refused")
    Patch.connect(&p, "oout|3", DotID(.mon, mid, 0).key)
    check(p.monitors[0].map == [3, 1], "logic: output -> monitor sets that monitor channel's source")
    let l = Link(from: DotID(.src, sid, 1).key, to: "oin|3")
    Patch.remove(&p, l)
    check(p.sources[0].routes == [0b001, 0b0010], "logic: remove deletes exactly one cable")
    check(Patch.hit(CGPoint(x: 250, y: 102), links: Patch.links(p), dots: dots)?.id == Link(from: DotID(.src, sid, 0).key, to: "oin|0").id
          && Patch.hit(CGPoint(x: 250, y: 160), links: Patch.links(p), dots: dots) == nil, "logic: click hit-test finds the cable under the pointer")
    let d1 = Patch.drop(start: DotID(.src, sid, 1).key, moving: nil, at: CGPoint(x: 302, y: 99), dots: dots)
    let d2 = Patch.drop(start: DotID(.src, sid, 1).key, moving: nil, at: CGPoint(x: 250, y: 50), dots: dots)
    let mv = Link(from: DotID(.src, sid, 0).key, to: "oin|0")
    let d3 = Patch.drop(start: nil, moving: (mv, mv.from), at: CGPoint(x: 299, y: 129), dots: dots)
    let d4 = Patch.drop(start: nil, moving: (mv, mv.from), at: CGPoint(x: 250, y: 50), dots: dots)
    check(d1 == .connect(DotID(.src, sid, 1).key, "oin|0") && d2 == .none && d3 == .move(mv, mv.from, "oin|1") && d4 == .detach(mv),
          "logic: drop on a dot connects, on empty space does nothing; a grabbed cable moves or is pulled off")
    // magnet: within the radius the dragged end snaps to the nearest COMPATIBLE dot; the drop uses the very same rule
    let s0 = DotID(.src, sid, 0).key, near = CGPoint(x: 280, y: 110)
    check(Patch.snapTarget(start: s0, moving: nil, at: near, dots: dots) == "oin|0"                       // 22 pt from oin|0, 28 pt from oin|1
          && Patch.snapTarget(start: s0, moving: nil, at: CGPoint(x: 260, y: 100), dots: dots) == nil     // 40 pt: out of range
          && Patch.snapTarget(start: s0, moving: nil, at: CGPoint(x: 300, y: 130), dots: dots) == "oin|1" // right on the other dot
          && Patch.snapTarget(start: nil, moving: nil, at: near, dots: dots) == nil,                      // no cable being dragged
          "logic: magnet snaps a dragged cable end to the nearest compatible dot within \(Int(Patch.snapRadius)) pt")
    check(Patch.drop(start: s0, moving: nil, at: near, dots: dots) == .connect(s0, "oin|0")
          && Patch.drop(start: nil, moving: (mv, mv.from), at: near, dots: dots) == .move(mv, mv.from, "oin|0"),
          "logic: what the magnet shows is what releasing the mouse does (new connection and moved cable)")
    Patch.apply(&p, d3)
    check(p.sources[0].routes == [0b010, 0b0010], "logic: moving a cable re-plugs it (old end removed, new end added)")
    // names + config file
    check(uniqueName("A", taken: ["A", "A 2"]) == "A 3" && uniqueName("B", taken: ["A"]) == "B", "logic: duplicate names get a suffix")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-cfg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("config.json")
    try? #"[{"name":"Old","slot":0,"sources":[{"kind":"app","ref":"com.x","title":"X"}],"monitors":[{"uid":"spk","name":"S"}]},{"name":"Old","slot":1}]"#
        .write(to: url, atomically: true, encoding: .utf8)
    let mig = ConfigFile.load(url)
    check(mig.count == 2 && mig[0].sources[0].routes == [1, 2] && mig[0].sources[0].inCh == 2 && mig[0].monitors[0].map == [0, 1]
          && mig[0].pairs == 1 && mig[1].name == "Old 2", "logic: version-1 config migrates (routes/inCh/map/pairs defaults, duplicate name suffixed)")
    ConfigFile.save(mig, to: url)
    let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
    check(saved?["version"] as? Int == 2 && ConfigFile.load(url).map(\.name) == ["Old", "Old 2"], "logic: saved file has version 2 and loads back")
    try? "{ not json".write(to: url, atomically: true, encoding: .utf8)
    let bad = ConfigFile.load(url)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(bad.isEmpty && !files.contains("config.json") && files.contains { $0.hasPrefix("config.json.bak-") },
          "logic: an unreadable config is kept as config.json.bak-<time> instead of being overwritten (\(files))")
    try? FileManager.default.removeItem(at: dir)
    // add menus (AppKit, headless)
    var picked: AddMenu.Pick?
    let apps = [RunningApp(bid: "com.apple.Safari", name: "Safari"), RunningApp(bid: "com.soundrouter.app", name: "SoundRouter"),
                RunningApp(bid: "com.x.music", name: "Music")]
    let ins = [HWDev(uid: "mic1", name: "Mic", ch: 1), HWDev(uid: "soundrouter.0", name: "SoundRouter", ch: 2)]
    let menu = AddMenu.sources(apps: apps, inputs: ins, used: [SourceCfg(kind: .app, ref: "com.x.music", title: "Music")]) { picked = $0 }
    let items = menu.items
    let headers = items.filter(\.isSectionHeader).map(\.title)
    let titled = Dictionary(items.filter { !$0.isSectionHeader && !$0.isSeparatorItem }.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
    check(headers == ["System", "Applications", "Input Devices"] && titled["SoundRouter"] == nil && titled.count == 4
          && titled["Safari"]?.isEnabled == true && titled["Safari"]?.image?.size.width == 16
          && titled["Music"]?.isEnabled == false && titled["Music"]?.state == .on && titled["Mic"]?.image != nil,
          "logic: Sources menu = one flat list with System / Applications / Input Devices sections, own app and own devices excluded, used app disabled+checked (\(items.map(\.title)))")
    if let i = items.firstIndex(where: { $0.title == "Mic" }) { menu.performActionForItem(at: i) }
    if let i = items.firstIndex(where: { $0.title == "All System Audio" }) { menu.performActionForItem(at: i) }
    let gotMic = picked
    if let i = items.firstIndex(where: { $0.title == "Mic" }) { menu.performActionForItem(at: i) }
    check(gotMic == .system && picked == .input(ins[0]), "logic: choosing a menu item calls back with that source")
    let mm = AddMenu.monitors(outputs: [HWDev(uid: "spk", name: "Speakers"), HWDev(uid: "hp", name: "Headphones")],
                              used: [MonitorCfg(uid: "spk", name: "Speakers")]) { _ in }
    check(mm.items.first?.isSectionHeader == true && mm.items.count == 3 && mm.items[1].isEnabled == false && mm.items[2].isEnabled,
          "logic: Monitors menu lists outputs, the used one disabled")
}

// MARK: - microphone indicator (tests/mic-indicator.sh)
/// Runs the real Engine for a few scenarios and reads which sensors ControlCenter attributes to this app
/// ("[aud]" = system audio recording, "[mic]" = microphone). Only a microphone source may give "[mic]".
func indicator() -> Never {
    setNames(testNames)
    _ = waitFor(10) { HAL.device(uid: "soundrouter.0") != nil }
    let gen = startGen([bhUID])   // tonegen plays into BlackHole: inaudible
    let e = Engine()
    let spk = HAL.devices().first(where: { !HAL.isVirtual($0) && HAL.streams($0, input: false) > 0 && HAL.name($0).contains("Speakers") })
    let micDev = HAL.devices().first(where: { !HAL.isVirtual($0) && HAL.streams($0, input: true) > 0 && HAL.name($0).contains("Microphone") })
    let app = SourceCfg(kind: .app, ref: "com.soundrouter.tonegen", title: "tonegen")
    let spkMon = spk.map { [MonitorCfg(uid: HAL.uid($0), name: HAL.name($0), gain: 0.02)] } ?? []
    var wins: [(name: String, t0: Date, t1: Date, mic: Bool)] = []
    func scenario(_ name: String, _ srcs: [SourceCfg], _ mons: [MonitorCfg], mic: Bool) {
        var d = VDev(name: "SoundRouter"); d.sources = srcs; d.monitors = mons
        DispatchQueue.main.sync { e.reconcile([d]) }
        check(srcs.allSatisfy { e.active[$0.id] != nil } && mons.allSatisfy { e.active[$0.id] != nil },
              "indicator \(name): \(srcs.count) source route(s) and \(mons.count) monitor(s) running")
        let t0 = Date(); Thread.sleep(forTimeInterval: 10); let t1 = Date()
        DispatchQueue.main.sync { e.stopAll() }
        wins.append((name, t0, t1, mic)); Thread.sleep(forTimeInterval: 8)
    }
    scenario("(a) app tap + monitor on the speakers", [app], spkMon, mic: false)
    scenario("(b) (a) + monitor on BlackHole 64ch", [app], spkMon + [MonitorCfg(uid: bhUID, name: "BlackHole", gain: 0.5)], mic: false)
    if let m = micDev { scenario("(c) microphone source", [SourceCfg(kind: .mic, ref: HAL.uid(m), title: "mic", inCh: HAL.channels(m, input: true))], [], mic: true) }
    gen.terminate(); setNames(origNames)
    Thread.sleep(forTimeInterval: 3)
    // ControlCenter logs the full attribution list whenever it changes; the state at time x is the last line before x
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["show", "--predicate", #"process == "ControlCenter" AND eventMessage CONTAINS "Sorted active attributions""#,
                   "--start", f.string(from: wins[0].t0.addingTimeInterval(-60)), "--end", f.string(from: Date())]
    p.standardOutput = pipe; try? p.run()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let me = Bundle.main.bundleIdentifier ?? "com.soundrouter.selftest"
    let rx = try! NSRegularExpression(pattern: #"\[(\w+)\] [^\[\]]*?\("# + NSRegularExpression.escapedPattern(for: me) + #"\)"#)
    let lines: [(Date, Set<String>)] = text.split(separator: "\n").compactMap { l in
        guard l.count > 19, let t = f.date(from: String(l.prefix(19))), let r = l.range(of: "update: ") else { return nil }
        let s = String(l[r.upperBound...])
        return (t, Set(rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }))
    }
    for w in wins {
        let from = w.t0.addingTimeInterval(3)   // let the indicators settle
        var seen = lines.last(where: { $0.0 <= from })?.1 ?? []
        for (t, s) in lines where t > from && t <= w.t1 { seen.formUnion(s) }
        let ok = w.mic ? seen.contains("mic") : seen.contains("aud") && !seen.contains("mic")
        check(ok, "indicator \(w.name): ControlCenter attributes \(seen.sorted().map { "[\($0)]" }) to \(me) (expect \(w.mic ? "[mic]" : "[aud] only, no [mic]"))")
    }
    say(failed ? "RESULT: FAILED" : "RESULT: ALL PASSED")
    exit(failed ? 1 : 0)
}

// MARK: - audio, against the installed driver
func run() {
    let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
    if mode == "measure" {   // measure-only mode, used to check the real app from outside
        let sem = DispatchSemaphore(value: 0); AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }; sem.wait()
        say("measured soundrouter.0 peaks \(fmt(measure("soundrouter.0", 1.5))); soundrouter.1 peaks \(fmt(measure("soundrouter.1", 0.7)))"); exit(0)
    }
    if mode == "tapkill" {   // child for the SIGKILL check: taps tonegen with mutedWhenTapped and waits to be killed
        let e = Engine(); var d = VDev(name: "SoundRouter"); d.sources = [SourceCfg(kind: .app, ref: "com.soundrouter.tonegen", title: "t")]
        DispatchQueue.main.sync { e.reconcile([d]) }
        try? (e.active.isEmpty ? "fail" : "ready").write(toFile: "/tmp/sr-tapkill.txt", atomically: true, encoding: .utf8)
        while true { Thread.sleep(forTimeInterval: 1) }
    }
    if mode == "indicator" { indicator() }
    logicTests()
    if mode == "logic" { say(failed ? "RESULT: FAILED" : "RESULT: ALL PASSED"); exit(failed ? 1 : 0) }

    let sem = DispatchSemaphore(value: 0); var mic = false
    AVCaptureDevice.requestAccess(for: .audio) { mic = $0; sem.signal() }; sem.wait()
    check(mic, "microphone permission granted")
    // the tests use soundrouter.0 + soundrouter.1; create them through the driver's live reload, restore the owner's list at the end
    setNames(testNames)
    let tPub = waitFor(10) { HAL.device(uid: "soundrouter.0").map { HAL.channels($0, input: true) } == 2 && HAL.device(uid: "soundrouter.1") != nil }
    check(tPub >= 0, "test devices soundrouter.0/.1 published (\(tPub) s)")
    let speakers = HAL.devices().first(where: { !HAL.isVirtual($0) && HAL.streams($0, input: false) > 0 && HAL.name($0).contains("Speakers") })
    check(HAL.device(uid: bhUID) != nil, "BlackHole 64ch (\(bhUID)) is installed: monitors are measured on its input")

    // start tonegen
    var gen = startGen()
    check(HAL.processes().contains(where: { $0.bid == "com.soundrouter.tonegen" }), "tonegen appears as an audio process")

    let engine = Engine()
    var src = SourceCfg(kind: .app, ref: "com.soundrouter.tonegen", title: "tonegen"); src.gain = 1
    var dev = VDev(name: "SoundRouter"); dev.sources = [src]
    DispatchQueue.main.sync { engine.reconcile([dev]) }
    check(engine.active[src.id] != nil, "engine started the app route (tap + aggregate)")
    Thread.sleep(forTimeInterval: 1)
    let p1 = measure("soundrouter.0", 1.5)
    check(p1.count == 2 && near(p1[0], 0.5) && near(p1[1], 0.25), "app audio arrives at virtual device input, L/R peaks \(fmt(p1)) (expect 0.5 / 0.25)")

    // stream usage: in an aggregate like the engine's (virtual device + a monitor device + tap) with only the tap's input on,
    // the IOProc still gets one buffer per stream (switched-off ones without data), so the tap index and output offsets hold
    if HAL.device(uid: bhUID) != nil, let tapObj = HAL.processes().first(where: { $0.bid == "com.soundrouter.tonegen" })?.obj {
        final class Shape { var ins: [String] = [], outs: [Int] = [], pk = [Float](repeating: 0, count: 8), done = false }
        let sh = Shape(), subs = ["soundrouter.0", bhUID]
        let io = Engine.offsets(subs, input: true), oo = Engine.offsets(subs, input: false)
        let t = CATapDescription(stereoMixdownOfProcesses: [tapObj]); t.muteBehavior = .unmuted
        let pr = Active()
        let ok = Engine.start(main: subs[0], subs: [[kAudioSubDeviceUIDKey: subs[0]], [kAudioSubDeviceUIDKey: subs[1], kAudioSubDeviceDriftCompensationKey: true]],
                              tap: t, keep: io.last!..<Int.max, pr) { _, i, _, o, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: i))
            if !sh.done {
                sh.ins = ins.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B/\($0.mData == nil ? "nil" : "data")" }
                sh.outs = UnsafeMutableAudioBufferListPointer(o).map { Int($0.mNumberChannels) }; sh.done = true
            }
            for (b, buf) in ins.prefix(8).enumerated() {
                guard let m = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for k in 0..<Int(buf.mDataByteSize) / 4 { sh.pk[b] = max(sh.pk[b], abs(m[k])) }
            }
        }
        Thread.sleep(forTimeInterval: 1); pr.stop()
        // the engine's route keeps playing 0.5 into soundrouter.0: its input buffer here stays silent only because it is not read
        check(ok && sh.ins.count == io.last! + 1 && sh.pk[0] == 0 && near(sh.pk[io.last!], 0.5) && sh.outs.count == oo.last! && sh.outs[oo[1]] == 64,
              "input stream usage: switched-off inputs are not read (virtual device input peak \(sh.pk[0]) while it carries 0.5), the tap stays at buffer \(io.last!) (peak \(sh.pk[io.last!])); output buffers \(sh.outs) = [virtual, BlackHole] in sub-device order; inputs \(sh.ins)")
    }

    dev.sources[0].gain = 0.5
    DispatchQueue.main.sync { engine.reconcile([dev]) }
    let p2 = measure("soundrouter.0", 1.0).max()!
    check(p2 > 0.2 && p2 < 0.3, "gain 0.5 halves it, peak \(p2) (expect ~0.25)")

    dev.sources[0].muted = true
    DispatchQueue.main.sync { engine.reconcile([dev]) }
    Thread.sleep(forTimeInterval: 0.5)
    say("     after mute: active routes = \(engine.active.count)")
    let p3a = measure("soundrouter.0", 0.4).max()!, p3b = measure("soundrouter.0", 0.4).max()!
    say("     peaks after mute, 2 consecutive windows: \(p3a) \(p3b)")
    check(p3b < 0.001 && engine.active[src.id] == nil, "mute stops the route and silences it, peak \(p3b)")

    // monitoring on the speakers (very quiet): the source route carries it, the monitor shows as live with a level
    dev.sources[0].muted = false; dev.sources[0].gain = 1
    if let out = speakers {
        dev.monitors = [MonitorCfg(uid: HAL.uid(out), name: HAL.name(out), gain: 0.02)]
        DispatchQueue.main.sync { engine.reconcile([dev]) }
        Thread.sleep(forTimeInterval: 1.5)   // you may hear a very quiet 440 Hz tone
        _ = engine.snapshot(); Thread.sleep(forTimeInterval: 0.3)
        let lv = engine.snapshot()[dev.monitors[0].id]?.outs ?? []
        check(engine.active[dev.monitors[0].id] != nil && engine.active[src.id] != nil && lv.count == 2 && near(lv[0], 0.01, 0.004) && near(lv[1], 0.005, 0.003),
              "monitor on \(HAL.name(out)) runs inside the source route, meter L/R \(fmt(lv)) (expect 0.01 / 0.005)")
    }

    // mixing: two sources into one device must sum (0.5 + 0.5)
    dev.monitors = []
    var src2 = src; src2.id = UUID(); src2.muted = false; src2.gain = 1; dev.sources[0].muted = false
    dev.sources.append(src2)
    DispatchQueue.main.sync { engine.reconcile([dev]) }
    Thread.sleep(forTimeInterval: 1)
    say("     before mix: active routes = \(engine.active.count)")
    let pm = measure("soundrouter.0", 1.2).max()!
    // the two taps are not sample-aligned (phase offset varies per run: 0.90..1.0 seen), so only require "louder than one source"
    check(pm > 0.6 && pm < 1.1, "two sources are mixed (summed), peak \(pm) (expect 0.6...1.0, one source alone = 0.5)")

    // microphone source starts alongside, with the device's real channel count
    if let micDev = HAL.devices().first(where: { !HAL.isVirtual($0) && HAL.streams($0, input: true) > 0 && HAL.name($0).contains("Microphone") }) {
        let hwCh = HAL.channels(micDev, input: true)
        let ms = SourceCfg(kind: .mic, ref: HAL.uid(micDev), title: "mic", inCh: hwCh)
        dev.sources = [ms]
        DispatchQueue.main.sync { engine.reconcile([dev]) }
        check(engine.active[ms.id] != nil && ms.inCh == min(8, hwCh) && ms.routes.count == ms.inCh,
              "microphone source route started (\(HAL.name(micDev)), inCh \(ms.inCh) from the device's \(hwCh) channels)")
        Thread.sleep(forTimeInterval: 1)
        say("     mic level on virtual input: \(fmt(measure("soundrouter.0", 1.0))) (any value is fine; proves the path runs)")
    }
    dev.sources = []

    // two devices at once, independent
    var d2 = VDev(name: "SoundRouter 2", slot: 1); d2.sources = []
    DispatchQueue.main.sync { engine.reconcile([dev, d2]) }
    let q = measure("soundrouter.1", 0.7).max()!
    check(q < 0.001, "second virtual device stays silent (no crosstalk), peak \(q)")

    // ---- mid-stream checks with a recorder that keeps running
    let L = Listener("soundrouter.0")!
    func apply() { DispatchQueue.main.sync { engine.reconcile([dev, d2]) } }
    src.gain = 1; src.muted = false; dev.sources = [src]; dev.monitors = []; apply()
    Thread.sleep(forTimeInterval: 1)
    let base = L.peak(0.6)
    check(base > 0.4 && base < 0.6, "listener hears the route, peak \(base)")

    dev.sources = []; apply(); Thread.sleep(forTimeInterval: 0.1)
    let tail = L.peak(0.5)
    check(tail < 0.001, "removing a source while recording goes silent at once (no stale ring replay), peak \(tail)")

    dev.sources = [src]; dev.volume = 0.5; apply(); Thread.sleep(forTimeInterval: 1)
    let pv = L.peak(0.6)
    check(pv > 0.2 && pv < 0.3, "device master volume 50% halves it, peak \(pv)")
    dev.volume = 0; apply(); Thread.sleep(forTimeInterval: 0.2)
    let pv0 = L.peak(0.5)
    check(pv0 < 0.001, "device master volume 0 silences it, peak \(pv0)")
    dev.volume = 1; dev.enabled = false; apply(); Thread.sleep(forTimeInterval: 0.2)
    let pe = L.peak(0.5)
    check(pe < 0.001 && engine.active.isEmpty, "device Off stops its routes and silences it, peak \(pe)")
    dev.enabled = true; apply()

    // the routed app quits and starts again: the next reconcile (the app's 1 s tick) picks it up
    gen.terminate(); gen.waitUntilExit(); Thread.sleep(forTimeInterval: 1); apply()
    check(engine.active[src.id] == nil, "route dropped while the app is not running")
    gen = startGen(); Thread.sleep(forTimeInterval: 0.5); apply(); Thread.sleep(forTimeInterval: 1)
    let pr = L.peak(0.6)
    check(engine.active[src.id] != nil && pr > 0.4 && pr < 0.6, "restarted app is routed again, peak \(pr)")

    // ---- monitors: the source routes write into the monitor devices (nothing reads the virtual device's input).
    // Measured on BlackHole 64ch's input; SoundRouter 2 stands in for a monitor device that can be unplugged (engine level only:
    // the app never offers its own devices as monitors).
    let BH = Listener(bhUID)!
    let bh0 = BH.peak(0.5)
    var bhMon = MonitorCfg(uid: bhUID, name: "BlackHole 64ch", gain: 0.5)
    dev.monitors = [bhMon]; apply(); Thread.sleep(forTimeInterval: 1.5)
    let aMon = engine.active[src.id]
    let pb = BH.peaks(0.8)
    _ = engine.snapshot(); Thread.sleep(forTimeInterval: 0.3)
    let lvb = engine.snapshot()[bhMon.id]?.outs ?? []
    check(bh0 < 0.001 && engine.active[bhMon.id] != nil && pb.count == 64 && near(pb[0], 0.25, 0.04) && near(pb[1], 0.125, 0.03) && pb[2...].max()! < 0.001,
          "monitor on BlackHole at gain 0.5 carries the device's mix: L/R \(fmt(Array(pb.prefix(3)))) (expect 0.25 / 0.125, ch 3-64 silent; idle before \(bh0))")
    check(lvb.count == 2 && near(lvb[0], 0.25, 0.04) && near(lvb[1], 0.125, 0.03), "monitor meter level = what the sources feed it: \(fmt(lvb))")
    let pvd = L.peaks(0.4)
    check(near(pvd[0], 0.5) && near(pvd[1], 0.25), "the virtual device keeps its full level while monitored: \(fmt(pvd))")
    dev.monitors[0].map = [1, 0]; apply(); Thread.sleep(forTimeInterval: 0.2)
    let pswap = BH.peaks(0.3)
    check(engine.active[src.id] === aMon && near(pswap[0], 0.125, 0.03) && near(pswap[1], 0.25, 0.04),
          "monitor map [2,1] swaps L/R live without restarting the route: \(fmt(Array(pswap.prefix(2))))")
    dev.monitors[0].map = [0, 1]; dev.monitors[0].gain = 0.25; apply(); Thread.sleep(forTimeInterval: 0.2)
    let pmg = BH.peaks(0.3)
    check(engine.active[src.id] === aMon && near(pmg[0], 0.125, 0.02) && near(pmg[1], 0.0625, 0.015),
          "monitor gain 0.25 applies live: \(fmt(Array(pmg.prefix(2)))) (expect 0.125 / 0.0625)")
    dev.sources[0].gain = 0.5; apply(); Thread.sleep(forTimeInterval: 0.2)
    let psg = BH.peaks(0.3)
    check(near(psg[0], 0.0625, 0.015) && near(psg[1], 0.03125, 0.01), "source gain 0.5 also scales the monitor: \(fmt(Array(psg.prefix(2)))) (expect 0.0625 / 0.031)")
    dev.sources[0].gain = 1; dev.monitors[0].gain = 0.5
    // three monitors at once: BlackHole, SoundRouter 2, the speakers (very quiet)
    let L2 = Listener("soundrouter.1")!
    let srMon = MonitorCfg(uid: "soundrouter.1", name: "SoundRouter 2", gain: 1)
    dev.monitors = [dev.monitors[0], srMon]
    if let out = speakers { dev.monitors.append(MonitorCfg(uid: HAL.uid(out), name: HAL.name(out), gain: 0.02)) }
    apply(); Thread.sleep(forTimeInterval: 1.5)
    let p3m = BH.peaks(0.6), p3s = L2.peaks(0.6)
    check(dev.monitors.allSatisfy { engine.active[$0.id] != nil } && engine.active[src.id] !== aMon
          && near(p3m[0], 0.25, 0.04) && near(p3m[1], 0.125, 0.03) && near(p3s[0], 0.5) && near(p3s[1], 0.25),
          "\(dev.monitors.count) monitors at once (adding one rebuilds the route): BlackHole \(fmt(Array(p3m.prefix(2)))), SoundRouter 2 \(fmt(p3s))")
    dev.monitors[0].on = false; apply(); Thread.sleep(forTimeInterval: 0.5)
    let poff = BH.peak(0.5), pon = L2.peaks(0.5)
    check(poff < 0.001 && engine.active[bhMon.id] == nil && near(pon[0], 0.5), "monitor Off = silence on it (\(poff)), the other monitor keeps playing \(fmt(pon))")
    // unplug / replug the monitor device (SoundRouter 2 removed from / re-added to the driver's list)
    setNames("SoundRouter\n")
    let tUn = waitFor(5) { HAL.device(uid: "soundrouter.1") == nil }
    apply(); Thread.sleep(forTimeInterval: 0.8)
    let pun = L.peak(0.5)
    check(tUn >= 0 && engine.active[srMon.id] == nil && engine.active[src.id] != nil && pun > 0.4 && pun < 0.6,
          "monitor device unplugged: its monitor stops, the source keeps playing (peak \(pun))")
    L2.stop()
    setNames(testNames)
    let tRe = waitFor(5) { HAL.device(uid: "soundrouter.1") != nil }
    apply(); Thread.sleep(forTimeInterval: 1.5)
    let L2b = Listener("soundrouter.1")!
    let pre = L2b.peaks(0.6)
    check(tRe >= 0 && engine.active[srMon.id] != nil && near(pre[0], 0.5) && near(pre[1], 0.25), "monitor device plugged back in: the monitor recovers \(fmt(pre))")
    dev.sources = []; apply(); Thread.sleep(forTimeInterval: 0.2)
    let prm = L2b.peak(0.5)
    check(prm < 0.001 && engine.active[srMon.id] == nil, "removing the only source silences its monitors and they show as not live (peak \(prm))")
    L2b.stop()
    bhMon.on = true
    dev.sources = [src]; dev.monitors = []; apply(); Thread.sleep(forTimeInterval: 1)

    // live device list: the driver watches devices.txt, no coreaudiod restart. The route on device 0 must keep playing.
    setNames("SoundRouter\nSoundRouter 2\nSR Live Test\n")
    let tAdd = waitFor { HAL.device(uid: "soundrouter.2").map(HAL.name) == "SR Live Test" }
    check(tAdd >= 0, "live add: soundrouter.2 appears without restart (\(tAdd) s)")
    let pAdd = L.peak(0.5)
    setNames("SoundRouter\nSoundRouter 2\nSR Live Renamed\n")
    let tRen = waitFor { HAL.device(uid: "soundrouter.2").map(HAL.name) == "SR Live Renamed" }
    check(tRen >= 0, "live rename: name changes without restart (\(tRen) s)")
    setNames("SoundRouter\n\nSR Live Renamed\n")
    let tDel = waitFor { HAL.device(uid: "soundrouter.1") == nil && HAL.device(uid: "soundrouter.2") != nil }
    check(tDel >= 0, "live delete of slot 1 keeps slot 2's UID (\(tDel) s)")
    setNames(testNames)
    let tBack = waitFor { HAL.device(uid: "soundrouter.1") != nil && HAL.device(uid: "soundrouter.2") == nil }
    check(tBack >= 0, "device list restored (\(tBack) s)")
    let pAfter = L.peak(0.6)
    check(pAdd > 0.4 && pAdd < 0.6 && pAfter > 0.4 && pAfter < 0.6 && engine.active[src.id] != nil,
          "route on device 0 keeps playing while other devices are added/removed, peaks \(pAdd) / \(pAfter)")
    L.stop()

    // ---- multi-channel devices + routing matrix
    setNames("SoundRouter\t4\nSoundRouter 2\n")
    let t4 = waitFor(5) { HAL.device(uid: "soundrouter.0").map { HAL.channels($0, input: true) } == 4 }
    let o4 = HAL.device(uid: "soundrouter.0").map { HAL.channels($0, input: false) } ?? 0
    check(t4 >= 0 && o4 == 4, "4-channel device (2 pairs) is published with 4 input and \(o4) output channels (\(t4) s)")
    dev.pairs = 2
    dev.sources[0].routes = [1 << 2, 1 << 3]   // L -> out 3, R -> out 4
    _ = waitFor(3) { apply(); return engine.active[src.id] != nil }
    Thread.sleep(forTimeInterval: 1)
    let L4 = Listener("soundrouter.0")!
    let m34 = L4.peaks(0.8)
    check(m34.count == 4 && m34[0] < 0.001 && m34[1] < 0.001 && near(m34[2], 0.5) && near(m34[3], 0.25),
          "app L -> out ch 3, R -> out ch 4; channels 1/2 stay silent: \(fmt(m34))")
    bhMon.map = [2, 3]; dev.monitors = [bhMon]; apply(); Thread.sleep(forTimeInterval: 1.5)
    let pb34 = BH.peaks(0.6)
    check(near(pb34[0], 0.25, 0.04) && near(pb34[1], 0.125, 0.03), "monitor of channels 3/4 carries what the sources feed there: \(fmt(Array(pb34.prefix(2))))")
    dev.monitors = []; _ = waitFor(3) { apply(); return engine.active[src.id] != nil }; Thread.sleep(forTimeInterval: 1)
    BH.stop()
    let a0 = engine.active[src.id]
    dev.sources[0].routes = [0b0101, 0]   // L feeds channels 1 and 3, R nowhere
    let tLive = Date(); apply()
    Thread.sleep(forTimeInterval: 0.15)
    let mFan = L4.peaks(0.3)
    let dLive = Date().timeIntervalSince(tLive)
    check(engine.active[src.id] === a0 && near(mFan[0], 0.5) && mFan[1] < 0.001 && near(mFan[2], 0.5) && mFan[3] < 0.001,
          "live routing change (same route object, measured within \(String(format: "%.2f", dLive)) s): one source channel feeds two outputs \(fmt(mFan))")
    dev.sources[0].routes = [1, 1]   // L + R summed into channel 1
    apply(); Thread.sleep(forTimeInterval: 0.15)
    let mSum = L4.peaks(0.3)
    check(engine.active[src.id] === a0 && near(mSum[0], 0.65, 0.05) && mSum[1] < 0.001 && mSum[2] < 0.001 && mSum[3] < 0.001,
          "two source channels summed into one output channel: \(fmt(mSum)) (0.5·sin x + 0.25·sin 2x peaks at 0.65)")
    L4.stop()
    // back to 1 pair: the driver removes + re-adds soundrouter.0 with 2 channels, the engine rebuilds the route
    dev.sources[0].routes = Routing.defaults(2)
    dev.removePair(1)
    setNames(testNames)
    let t2 = waitFor(5) { HAL.device(uid: "soundrouter.0").map { HAL.channels($0, input: true) } == 2 }
    _ = waitFor(3) { apply(); return engine.active[src.id] != nil && engine.active[src.id] !== a0 }
    Thread.sleep(forTimeInterval: 1)
    let mBack = measure("soundrouter.0", 0.8)
    check(t2 >= 0 && engine.active[src.id] !== a0 && mBack.count == 2 && near(mBack[0], 0.5) && near(mBack[1], 0.25),
          "2 pairs -> 1 pair: device re-published with 2 channels (\(t2) s), route rebuilt and playing \(fmt(mBack))")

    // ---- All System Audio: a global tap that leaves SoundRouter's own process out (else our output would feed back)
    let me = HAL.ownProcess()
    let sys = SourceCfg(kind: .system, ref: "system", title: "All System Audio")
    dev.sources = [sys]; apply(); Thread.sleep(forTimeInterval: 1)
    let s1 = measure("soundrouter.0", 1.0), s2 = measure("soundrouter.0", 1.0)
    check(me != 0 && engine.active[sys.id] != nil && (s1.max() ?? 0) > 0.4 && (s2.max() ?? 9) < 0.95 && (s2.max() ?? 9) < (s1.max() ?? 0) + 0.1,
          "All System Audio route runs (own process object \(me) excluded): tonegen heard, no feedback build-up \(fmt(s1)) -> \(fmt(s2))")

    DispatchQueue.main.sync { engine.stopAll() }
    gen.terminate(); gen.waitUntilExit()

    // ---- SIGKILL cleanliness: a killed SoundRouter must not leave the tapped app muted
    let g2 = startGen(["soundrouter.1"])   // plays straight into SoundRouter 2, so its own output is measurable
    _ = waitFor(5) { measure("soundrouter.1", 0.3).max()! > 0.4 }   // tonegen needs a moment to start playing
    let before = measure("soundrouter.1", 0.6).max()!
    try? FileManager.default.removeItem(atPath: "/tmp/sr-tapkill.txt")
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = [CommandLine.arguments[1], "tapkill"]; try! child.run()
    _ = waitFor(10) { FileManager.default.fileExists(atPath: "/tmp/sr-tapkill.txt") }
    let ready = (try? String(contentsOfFile: "/tmp/sr-tapkill.txt", encoding: .utf8)) == "ready"
    Thread.sleep(forTimeInterval: 1)
    let muted = measure("soundrouter.1", 0.6).max()!
    kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
    let tHeal = waitFor(5) { measure("soundrouter.1", 0.3).max()! > 0.4 }
    check(near(before, 0.5) && ready && muted < 0.001 && tHeal >= 0,
          "SIGKILL of a process holding a mutedWhenTapped tap un-mutes the app: \(before) -> muted \(muted) -> heard again after \(String(format: "%.1f", tHeal)) s")
    g2.terminate()
    try? FileManager.default.removeItem(atPath: "/tmp/sr-tapkill.txt")

    setNames(origNames)
    say(failed ? "RESULT: FAILED" : "RESULT: ALL PASSED")
    exit(failed ? 1 : 0)
}
NSApplication.shared.setActivationPolicy(.accessory)
DispatchQueue.global().async { run() }
NSApplication.shared.run()

import AVFoundation
import AppKit
import CoreAudio

// MARK: - tiny HAL helpers
enum HAL {
    static let sys = AudioObjectID(kAudioObjectSystemObject)
    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = addr(sel, scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return [] }
        var r = [AudioObjectID](repeating: 0, count: Int(size) / 4)
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &r)
        return r
    }
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var a = addr(sel); var v: CFString = "" as CFString; var size = UInt32(MemoryLayout<CFString>.size)
        withUnsafeMutablePointer(to: &v) { _ = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return v as String
    }
    static func pid(_ obj: AudioObjectID) -> pid_t {
        var a = addr(kAudioProcessPropertyPID); var v: pid_t = 0; var size = UInt32(4)
        AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v); return v
    }
    static func devices() -> [AudioObjectID] { ids(sys, kAudioHardwarePropertyDevices) }
    static func name(_ d: AudioObjectID) -> String { string(d, kAudioObjectPropertyName) }
    static func uid(_ d: AudioObjectID) -> String { string(d, kAudioDevicePropertyDeviceUID) }
    static func streams(_ d: AudioObjectID, input: Bool) -> Int {
        ids(d, kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput).count
    }
    static func device(uid: String) -> AudioObjectID? { devices().first { self.uid($0) == uid } }
    static func processes() -> [(obj: AudioObjectID, bid: String)] {
        ids(sys, kAudioHardwarePropertyProcessObjectList).map { ($0, string($0, kAudioProcessPropertyBundleID)) }
    }
    /// A device's real output volume (0...1), the same one the menu-bar slider moves. nil if it has none (HDMI, some USB).
    static func volume(_ uid: String) -> Float? {
        guard let d = device(uid: uid) else { return nil }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var v: Float32 = 0; var size = UInt32(4)
        return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    static func setVolume(_ uid: String, _ v: Float) {
        guard let d = device(uid: uid) else { return }
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var x = Float32(min(1, max(0, v)))
        AudioObjectSetPropertyData(d, &a, 0, nil, 4, &x)
    }
    static func isVirtual(_ d: AudioObjectID) -> Bool { uid(d).hasPrefix("soundrouter.") }
    /// Total channels of a device's input or output streams.
    static func channels(_ d: AudioObjectID, input: Bool) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    /// This process's HAL process object (to keep our own output out of a system-wide tap).
    static func ownProcess() -> AudioObjectID {
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject); var pid = getpid(); var obj = AudioObjectID(0)
        var size = UInt32(4)
        AudioObjectGetPropertyData(sys, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return obj
    }
}

// MARK: - one running source route (or a monitor marker)
/// Shared between the UI thread and the IOProc through fixed buffers: no locks, no allocation on the audio thread.
/// (Unsynchronised UInt32 / Float loads and stores are single instructions on arm64: never torn, at worst one cycle late.)
final class Active {
    static let maxCh = 16, maxMon = 8
    var gain: Float = 1
    let masks = UnsafeMutablePointer<UInt32>.allocate(capacity: maxCh)   // input channel -> output channel bits; UI writes, IOProc reads
    let inPk = UnsafeMutablePointer<Float>.allocate(capacity: maxCh)     // per input channel peak (after gain); IOProc max-es, UI resets
    let outPk = UnsafeMutablePointer<Float>.allocate(capacity: maxCh)    // per output channel peak, measured at the write
    // Monitors fed by this route (the physical outputs are sub-devices of its aggregate). Set before the IOProc starts:
    var monIDs: [UUID] = []                                                          // UI thread only
    var monCount = 0
    let monBuf = UnsafeMutablePointer<Int>.allocate(capacity: maxMon)       // aggregate output buffer of monitor k (fixed)
    // live, like the masks:
    let monMap = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * maxMon) // monitor k, side j <- device output channel (-1 = none)
    let monGain = UnsafeMutablePointer<Float>.allocate(capacity: maxMon)
    let monPk = UnsafeMutablePointer<Float>.allocate(capacity: 2 * maxMon)  // what this route wrote to monitor k, side j
    var stop: () -> Void = {}
    var alive: () -> Bool = { true }   // false once the aggregate is gone (e.g. coreaudiod restarted by Apply)
    var sig = ""
    init() {
        for p in [inPk, outPk] { p.initialize(repeating: 0, count: Self.maxCh) }; masks.initialize(repeating: 0, count: Self.maxCh)
        monBuf.initialize(repeating: 0, count: Self.maxMon); monGain.initialize(repeating: 0, count: Self.maxMon)
        monMap.initialize(repeating: -1, count: 2 * Self.maxMon); monPk.initialize(repeating: 0, count: 2 * Self.maxMon)
    }
    deinit { masks.deallocate(); inPk.deallocate(); outPk.deallocate(); monBuf.deallocate(); monMap.deallocate(); monGain.deallocate(); monPk.deallocate() }   // after stop(): the IOProc block holds a strong ref until destroyed
    func setMasks(_ m: [UInt32]) { for c in 0..<Self.maxCh { let v = c < m.count ? m[c] : 0; if masks[c] != v { masks[c] = v } } }
    func setMons(_ ms: [MonitorCfg]) {
        for (k, m) in ms.prefix(monCount).enumerated() {
            monGain[k] = m.gain
            for j in 0..<2 { monMap[2 * k + j] = Int32(j < m.map.count ? m.map[j] : -1) }
        }
    }
}

/// Mix the input channels (starting at buffer `first`, at most `maxIn` channels, possibly spread over several streams)
/// into output buffer `outIndex` through the routing matrix: dst[o] += src[c] * gain for every bit o of masks[c].
/// The HAL sums the output of every aggregate that targets the same virtual device = the mix.
/// Monitors: physical L / R (the first stream's channels 1-2 of monitor k) = what this route fed to device channel monMap,
/// times the monitor gain. The HAL sums all routes that feed the same physical device, so a monitor carries the device's mix.
private func routeMatrix(_ a: Active, _ inData: UnsafePointer<AudioBufferList>, first: Int, maxIn: Int,
                         _ outData: UnsafeMutablePointer<AudioBufferList>, outIndex: Int) {
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outs = UnsafeMutableAudioBufferListPointer(outData)
    for o in outs { if let p = o.mData { memset(p, 0, Int(o.mDataByteSize)) } }
    guard outIndex < outs.count, let dst = outs[outIndex].mData?.assumingMemoryBound(to: Float.self) else { return }
    let oc = min(Int(outs[outIndex].mNumberChannels), Active.maxCh)
    guard oc > 0 else { return }
    let ostride = Int(outs[outIndex].mNumberChannels)
    let g = a.gain
    var touched: UInt32 = 0
    var ch = 0, b = first
    while b < ins.count && ch < maxIn {
        let buf = ins[b]; b += 1
        let ic = Int(buf.mNumberChannels)
        guard ic > 0, let src = buf.mData?.assumingMemoryBound(to: Float.self) else { ch += ic; continue }
        let n = min(Int(buf.mDataByteSize) / (4 * ic), Int(outs[outIndex].mDataByteSize) / (4 * ostride))
        for c in 0..<ic where ch + c < maxIn {
            let m = a.masks[ch + c] & (oc >= 32 ? ~0 : (1 << UInt32(oc)) - 1)
            var pk: Float = 0
            for f in 0..<n { pk = max(pk, abs(src[f * ic + c])) }
            a.inPk[ch + c] = max(a.inPk[ch + c], pk * g)
            guard m != 0, g != 0 else { continue }
            touched |= m
            for o in 0..<oc where m & (1 << UInt32(o)) != 0 {
                for f in 0..<n { dst[f * ostride + o] += src[f * ic + c] * g }
            }
        }
        ch += ic
    }
    let n = Int(outs[outIndex].mDataByteSize) / (4 * ostride)
    for o in 0..<oc where touched & (1 << UInt32(o)) != 0 {
        var pk: Float = 0
        for f in 0..<n { pk = max(pk, abs(dst[f * ostride + o])) }
        a.outPk[o] = max(a.outPk[o], pk)
    }
    for k in 0..<a.monCount {
        let bi = a.monBuf[k]
        guard bi < outs.count, let md = outs[bi].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let mc = Int(outs[bi].mNumberChannels)
        guard mc > 0 else { continue }
        let mn = min(n, Int(outs[bi].mDataByteSize) / (4 * mc)), mg = a.monGain[k]
        for j in 0..<min(2, mc) {
            let c = Int(a.monMap[2 * k + j])
            guard c >= 0, c < oc, touched & (1 << UInt32(c)) != 0, mg != 0 else { continue }
            var pk: Float = 0
            for f in 0..<mn { let v = dst[f * ostride + c] * mg; md[f * mc + j] = v; pk = max(pk, abs(v)) }
            a.monPk[2 * k + j] = max(a.monPk[2 * k + j], pk)
        }
    }
}

// MARK: - engine
final class Engine {
    private var routes: [UUID: Active] = [:]    // source id -> running route
    private var markers: [UUID: Active] = [:]   // monitor id -> marker (no audio of its own: the source routes feed the monitor)
    /// Everything live, by source / monitor id (the UI shows a card as live when its id is here).
    var active: [UUID: Active] { routes.merging(markers) { a, _ in a } }

    struct Levels { var ins: [Float]; var outs: [Float] }
    /// Per-channel peaks of every live route since the previous call. Call once per UI frame.
    /// A monitor's outs[j] = clamped sum of what the live sources wrote to its side j.
    func snapshot() -> [UUID: Levels] {
        var r: [UUID: Levels] = [:]
        for k in markers.keys { r[k] = Levels(ins: [], outs: [0, 0]) }
        for (k, a) in routes {
            r[k] = Levels(ins: (0..<Active.maxCh).map { a.inPk[$0] }, outs: (0..<Active.maxCh).map { a.outPk[$0] })
            for c in 0..<Active.maxCh { a.inPk[c] = 0; a.outPk[c] = 0 }
            for (i, id) in a.monIDs.enumerated() where r[id] != nil {
                for j in 0..<2 { r[id]!.outs[j] = min(1, r[id]!.outs[j] + a.monPk[2 * i + j]); a.monPk[2 * i + j] = 0 }
            }
        }
        return r
    }

    private func match(_ bid: String, _ ref: String) -> Bool {
        let aliases = ["com.apple.Safari": "com.apple.WebKit"]   // Safari plays audio from WebKit helper processes
        return bid == ref || bid.hasPrefix(ref + ".") || (aliases[ref].map { bid.hasPrefix($0) } ?? false)
    }

    /// Make the running audio graph match the config. Cheap to call often; only changed pieces are restarted.
    func reconcile(_ devs: [VDev]) {
        guard ProcessInfo.processInfo.environment["SR_UI_ONLY"] == nil else { return }   // UI-only mode: no taps, no permission prompts (for screenshots/QA)
        let procs = HAL.processes()
        let me = HAL.ownProcess()
        var want: [UUID: (sig: String, gain: Float, masks: [UInt32], mons: [MonitorCfg], make: (Active) -> Bool)] = [:]

        for vd in devs {
            let destUID = vd.uid
            guard vd.enabled, vd.slot >= 0, let dest = HAL.device(uid: destUID) else { continue }
            let vCh = HAL.channels(dest, input: false)  // the published channel count: a change re-creates the routes
            // monitors = extra sub-devices of every source route of this device; their set is part of the signature
            let mons = vd.monitors.filter { $0.on && $0.uid != destUID && HAL.device(uid: $0.uid) != nil }
            let monUIDs = mons.map(\.uid)
            for s in vd.sources where !s.muted {   // Off = not routed at all (no tap, no indicator)
                let inCh = s.inCh
                let base = "\(destUID)|\(vCh)|\(inCh)|mon:\(monUIDs)"
                switch s.kind {
                case .app, .system:
                    let tap: CATapDescription, sig: String
                    if s.kind == .app {
                        let objs = procs.filter { match($0.bid, s.ref) }.map(\.obj)
                        if objs.isEmpty { continue }
                        tap = CATapDescription(stereoMixdownOfProcesses: objs)
                        tap.muteBehavior = s.hearOriginal ? .unmuted : .mutedWhenTapped
                        sig = "app|\(base)|\(objs)|\(s.hearOriginal)"
                    } else {
                        // everything except SoundRouter itself: our own monitors / routes in the tap would feed back
                        guard me != 0 else { continue }
                        tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
                        tap.muteBehavior = .unmuted
                        sig = "sys|\(base)|\(me)"
                    }
                    want[s.id] = (sig, s.gain * vd.volume, s.routes, mons, { a in
                        Self.start(subs: [destUID] + monUIDs, input: nil, tap: tap, inCh: inCh, mons: monUIDs, a)
                    })
                case .mic:
                    // feedback guard: never read a SoundRouter device as a microphone
                    guard !s.ref.hasPrefix("soundrouter."), HAL.device(uid: s.ref) != nil else { continue }
                    let micUID = s.ref
                    want[s.id] = ("mic|\(base)|\(micUID)", s.gain * vd.volume, s.routes, mons, { a in
                        Self.start(subs: [destUID, micUID] + monUIDs.filter { $0 != micUID }, input: micUID, tap: nil, inCh: inCh, mons: monUIDs, a)
                    })
                }
            }
        }

        for (k, a) in routes where want[k]?.sig != a.sig || !a.alive() { a.stop(); routes[k] = nil }
        for (k, w) in want {
            if let a = routes[k] { a.gain = w.gain; a.setMasks(w.masks); a.setMons(w.mons); continue }   // live: no restart for gain / routing / monitor map+gain
            let a = Active(); a.sig = w.sig; a.gain = w.gain; a.setMasks(w.masks)
            a.monIDs = w.mons.map(\.id)
            if w.make(a) { a.setMons(w.mons); routes[k] = a }
        }
        // a monitor is live while at least one running source route feeds it
        let fed = Set(routes.values.flatMap(\.monIDs))
        markers = markers.filter { fed.contains($0.key) }
        for id in fed where markers[id] == nil { markers[id] = Active() }
    }

    func stopAll() { routes.values.forEach { $0.stop() }; routes = [:]; markers = [:] }

    /// First stream index of each sub-device in an aggregate made of `subs` (the HAL lists streams in sub-device order), plus the total.
    static func offsets(_ subs: [String], input: Bool) -> [Int] {
        subs.reduce(into: [0]) { r, u in r.append(r.last! + (HAL.device(uid: u).map { HAL.streams($0, input: input) } ?? 0)) }
    }

    /// Turn an IOProc's input streams on / off (`on[i]` per input stream of `dev`). A stream that is off is not read at all,
    /// so reading nothing from a device's input does not count as recording (no microphone indicator).
    @discardableResult
    static func setInputUsage(_ dev: AudioObjectID, _ proc: AudioDeviceIOProcID, _ on: [Bool]) -> OSStatus {
        var a = HAL.addr(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + 4 * max(0, on.count - 1)
        let p = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8); defer { p.deallocate() }
        memset(p, 0, size)
        let u = p.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        u.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        u.pointee.mNumberStreams = UInt32(on.count)
        let flags = p.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).bindMemory(to: UInt32.self, capacity: on.count)
        for (i, v) in on.enumerated() { flags[i] = v ? 1 : 0 }
        return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(size), p)
    }

    /// Private aggregate: subs[0] (the virtual device) is the clock, the others are drift-compensated. Only the source's input
    /// streams are read (the mic sub-device `input`, or the tap when nil); output buffer 0 is the virtual device, the monitors'
    /// first output streams follow at their sub-device offsets.
    static func start(subs: [String], input: String?, tap: CATapDescription?, inCh: Int, mons: [String], _ a: Active) -> Bool {
        let ins = offsets(subs, input: true), outs = offsets(subs, input: false)
        let keep = input.flatMap { subs.firstIndex(of: $0) }.map { ins[$0]..<ins[$0 + 1] } ?? ins.last!..<Int.max
        a.monCount = min(mons.count, Active.maxMon)
        for (k, u) in mons.prefix(a.monCount).enumerated() { a.monBuf[k] = outs[subs.firstIndex(of: u)!] }
        let first = keep.lowerBound
        if start(main: subs[0], subs: subs.enumerated().map { i, u in
            i == 0 ? [kAudioSubDeviceUIDKey: u] : [kAudioSubDeviceUIDKey: u, kAudioSubDeviceDriftCompensationKey: true]
        }, tap: tap, keep: keep, a, { _, i, _, o, _ in routeMatrix(a, i, first: first, maxIn: inCh, o, outIndex: 0) }) { return true }
        guard !mons.isEmpty else { return false }
        // a monitor device that can't join must not take the source down: run it without monitors (retried when the config changes)
        NSLog("SoundRouter: route with monitors \(mons) failed, starting it without")
        a.monIDs = []; a.monCount = 0
        return start(subs: subs.filter { !mons.contains($0) || $0 == input }, input: input, tap: tap, inCh: inCh, mons: [], a)
    }

    static func start(main: String, subs: [[String: Any]], tap: CATapDescription?, keep: Range<Int>, _ a: Active, _ body: @escaping AudioDeviceIOBlock) -> Bool {
        var tapID = AudioObjectID(0)
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundRouter route", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: main, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subs,
        ]
        if let tap {
            guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr else { return false }
            dict[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        }
        var agg = AudioObjectID(0)
        var proc: AudioDeviceIOProcID?
        func teardown() {
            if let proc, agg != 0 { AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc) }
            if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
            if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        }
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr,
              AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, body) == noErr, let p = proc else { teardown(); return false }
        let n = HAL.streams(agg, input: true)
        if n > 0, setInputUsage(agg, p, (0..<n).map { keep.contains($0) }) != noErr { NSLog("SoundRouter: input stream usage not set") }
        guard AudioDeviceStart(agg, p) == noErr else { teardown(); return false }
        a.stop = teardown
        a.alive = {
            var ad = HAL.addr(kAudioDevicePropertyDeviceIsAlive); var v: UInt32 = 0; var size = UInt32(4)
            return AudioObjectGetPropertyData(agg, &ad, 0, nil, &size, &v) == noErr && v != 0
        }
        return true
    }
}

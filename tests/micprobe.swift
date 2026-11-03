// Which SoundRouter audio paths make macOS list the process as using the MICROPHONE?
// Runs variants one after another; ControlCenter's log ("[mic] <app>") is read afterwards for each time window.
import AppKit
import CoreAudio
import Foundation

let sys = AudioObjectID(kAudioObjectSystemObject)
func ids(_ o: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain); var n: UInt32 = 0
    AudioObjectGetPropertyDataSize(o, &a, 0, nil, &n); var r = [AudioObjectID](repeating: 0, count: Int(n) / 4); AudioObjectGetPropertyData(o, &a, 0, nil, &n, &r); return r }
func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: CFString = "" as CFString; var n = UInt32(8); withUnsafeMutablePointer(to: &v) { _ = AudioObjectGetPropertyData(o, &a, 0, nil, &n, $0) }; return v as String }
func dev(_ uid: String) -> AudioObjectID? { ids(sys, kAudioHardwarePropertyDevices).first { str($0, kAudioDevicePropertyDeviceUID) == uid } }
func procObj(named bid: String) -> AudioObjectID? { ids(sys, kAudioHardwarePropertyProcessObjectList).first { str($0, kAudioProcessPropertyBundleID) == bid } }

/// Turn input streams of an IOProc on/off (kAudioDevicePropertyIOProcStreamUsage). `on[i]` per input stream of the device.
func streamUsage(_ d: AudioObjectID, _ proc: AudioDeviceIOProcID, input on: [Bool]) -> OSStatus {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    let size = 16 + 4 * max(0, on.count - 1)
    let p = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8); defer { p.deallocate() }
    memset(p, 0, size)
    p.storeBytes(of: unsafeBitCast(proc, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
    p.storeBytes(of: UInt32(on.count), toByteOffset: 8, as: UInt32.self)
    for (i, v) in on.enumerated() { p.storeBytes(of: v ? 1 : 0, toByteOffset: 12 + 4 * i, as: UInt32.self) }
    return AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(size), p)
}

struct Run { let name: String; let make: () -> (stop: () -> Void, note: String)? }
let destUID = "soundrouter.0"
let spkUID = "BuiltInSpeakerDevice"
var tapOwner: AudioObjectID? { procObj(named: "com.soundrouter.tonegen") }

func aggregate(main: String, subs: [[String: Any]], tap: CATapDescription?, usage: ((AudioObjectID, AudioDeviceIOProcID) -> String)? = nil) -> (stop: () -> Void, note: String)? {
    var tapID = AudioObjectID(0)
    var dict: [String: Any] = [kAudioAggregateDeviceNameKey: "probe", kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceMainSubDeviceKey: main,
                               kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceSubDeviceListKey: subs]
    if let tap { guard AudioHardwareCreateProcessTap(tap, &tapID) == noErr else { return (stop: {}, note: "tap creation failed (permission?)") }
        dict[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: tap.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]] }
    var agg = AudioObjectID(0); var proc: AudioDeviceIOProcID?
    guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg) == noErr,
          AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { _, _, _, _, _ in }) == noErr, let p = proc else { return (stop: {}, note: "aggregate failed") }
    let note = usage?(agg, p) ?? ""
    let st = AudioDeviceStart(agg, p)
    return (stop: { AudioDeviceStop(agg, p); AudioDeviceDestroyIOProcID(agg, p); AudioHardwareDestroyAggregateDevice(agg); if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) } },
            note: note + " start=\(st)")
}
func tapDesc() -> CATapDescription? { tapOwner.map { let d = CATapDescription(stereoMixdownOfProcesses: [$0]); d.muteBehavior = .unmuted; return d } }
func inputStreams(_ d: AudioObjectID) -> Int { ids(d, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).count }

let runs: [Run] = [
    Run(name: "V0 baseline (nothing running)") { (stop: {}, note: "") },
    Run(name: "V1 tap + virtual device as sub-device (what SoundRouter does now)") {
        guard let t = tapDesc() else { return nil }; return aggregate(main: destUID, subs: [[kAudioSubDeviceUIDKey: destUID]], tap: t) },
    Run(name: "V2 same, virtual device's INPUT stream switched off (stream usage)") {
        guard let t = tapDesc(), let d = dev(destUID) else { return nil }
        let n = inputStreams(d)
        return aggregate(main: destUID, subs: [[kAudioSubDeviceUIDKey: destUID]], tap: t) { agg, p in
            let total = inputStreams(agg); let on = (0..<total).map { $0 >= n }   // sub-device streams first, tap stream(s) after
            return "usage=\(streamUsage(agg, p, input: on)) streams=\(total)" } },
    Run(name: "V3 tap + physical speakers only (no virtual device)") {
        guard let t = tapDesc() else { return nil }; return aggregate(main: spkUID, subs: [[kAudioSubDeviceUIDKey: spkUID]], tap: t) },
    Run(name: "V4 monitor: virtual device read, physical output clock (what monitors do now)") {
        aggregate(main: spkUID, subs: [[kAudioSubDeviceUIDKey: destUID, kAudioSubDeviceDriftCompensationKey: true], [kAudioSubDeviceUIDKey: spkUID]], tap: nil) },
    Run(name: "V5 monitor with the virtual device's INPUT stream switched off") {
        guard let d = dev(destUID) else { return nil }; let n = inputStreams(d)
        return aggregate(main: spkUID, subs: [[kAudioSubDeviceUIDKey: destUID, kAudioSubDeviceDriftCompensationKey: true], [kAudioSubDeviceUIDKey: spkUID]], tap: nil) { agg, p in
            let total = inputStreams(agg); let on = (0..<total).map { $0 >= n }
            return "usage=\(streamUsage(agg, p, input: on)) streams=\(total)" } },
    Run(name: "V6 direct IOProc on the virtual device (inputs on)") {
        guard let d = dev(destUID) else { return nil }; var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil, { _, _, _, _, _ in }) == noErr, let p = proc else { return nil }
        AudioDeviceStart(d, p); return (stop: { AudioDeviceStop(d, p); AudioDeviceDestroyIOProcID(d, p) }, note: "") },
    Run(name: "V7 direct IOProc on the virtual device, INPUT stream usage off (output-only client)") {
        guard let d = dev(destUID) else { return nil }; var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil, { _, _, _, _, _ in }) == noErr, let p = proc else { return nil }
        let u = streamUsage(d, p, input: Array(repeating: false, count: inputStreams(d))); AudioDeviceStart(d, p)
        return (stop: { AudioDeviceStop(d, p); AudioDeviceDestroyIOProcID(d, p) }, note: "usage=\(u)") },
]

func ts() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date()) }
var out = ""
func say(_ s: String) { out += s + "\n"; try? out.write(toFile: "/tmp/sr-probe.txt", atomically: true, encoding: .utf8) }
NSApplication.shared.setActivationPolicy(.accessory)
DispatchQueue.global().async {
    say("PROBE START \(ts()) bundle=\(Bundle.main.bundleIdentifier ?? "?")")
    for r in runs {
        let t0 = ts(); let h = r.make()
        say("RUN|\(r.name)|\(t0)|\(h == nil ? "could not start" : h!.note)")
        Thread.sleep(forTimeInterval: 9)
        h?.stop.self(); Thread.sleep(forTimeInterval: 5)
        say("END|\(r.name)|\(ts())")
    }
    say("PROBE DONE \(ts())"); exit(0)
}
NSApplication.shared.run()

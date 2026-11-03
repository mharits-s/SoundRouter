// test helper app: plays 440 Hz at 0.5 on L and a phase-locked 880 Hz at 0.25 on R (so channels are distinguishable).
// Optional argument: output device UID (default: the system's default output).
import AVFoundation
import AppKit
import CoreAudio
let engine = AVAudioEngine()
if CommandLine.arguments.count > 1 {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0; AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    for d in ids {
        var u = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: CFString = "" as CFString; var sz = UInt32(MemoryLayout<CFString>.size)
        withUnsafeMutablePointer(to: &s) { _ = AudioObjectGetPropertyData(d, &u, 0, nil, &sz, $0) }
        if s as String == CommandLine.arguments[1] { try! engine.outputNode.auAudioUnit.setDeviceID(d) }
    }
}
var phase = 0.0
let src = AVAudioSourceNode { _, _, n, abl in
    let b = UnsafeMutableAudioBufferListPointer(abl)
    for f in 0..<Int(n) {
        let l = Float(sin(phase)) * 0.5, r = Float(sin(2 * phase)) * 0.25
        phase += 2 * .pi * 440 / 48000; if phase > 2 * .pi { phase -= 2 * .pi }
        if b.count >= 2 {   // deinterleaved: one buffer per channel
            b[0].mData!.assumingMemoryBound(to: Float.self)[f] = l; b[1].mData!.assumingMemoryBound(to: Float.self)[f] = r
        } else if let p = b[0].mData?.assumingMemoryBound(to: Float.self) {
            let c = Int(b[0].mNumberChannels); p[f * c] = l; if c > 1 { p[f * c + 1] = r }
        }
    }
    return noErr }
engine.attach(src); engine.connect(src, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
try! engine.start()
NSApplication.shared.setActivationPolicy(.prohibited); NSApplication.shared.run()

// Headless tests of the meter ballistics (app/Logic.swift). Build + run: tests/ui/logic.sh
import Foundation
var failed = false
func check(_ ok: Bool, _ s: String) { print((ok ? "PASS " : "FAIL ") + s); if !ok { failed = true } }

// dB position
check(Ballistics.position(1) == 1 && Ballistics.position(0) == 0 && Ballistics.position(0.00001) == 0, "position: full scale = 1, silence and -100 dB = 0")
check(abs(Ballistics.position(0.5) - (54 - 6.0206) / 54) < 0.002 && abs(Ballistics.position(0.25) - (54 - 12.041) / 54) < 0.002, "position: 0.5 = -6 dB, 0.25 = -12 dB on a 54 dB scale")
check(Ballistics.position(0.01) > 0.2 && Ballistics.position(0.01) < Ballistics.position(0.1), "position: quiet signals are visible and the scale is monotonic")

// attack is practically instant, release is quick but not a flicker
var b = Ballistics(); b.step(level: 1, dt: 1.0 / 60)
check(b.shown > 0.95 && b.peak == 1, "attack: one 60 Hz frame of full scale already shows > 95% (\(b.shown))")
var frames: [Float] = []
for _ in 0..<60 { b.step(level: 0, dt: 1.0 / 60); frames.append(b.shown) }
check(frames[0] > 0.8, "release: no collapse in the first frame (\(frames[0]))")
check(zip(frames, frames.dropFirst()).allSatisfy { $0 >= $1 }, "release: monotonic fall, no jitter")
check(frames[5] > 0.35 && frames[5] < 0.65, "release: ~0.1 s after the signal stops it is at roughly 40-60% (\(frames[5]))")
check(frames[29] < 0.05, "release: essentially gone after 0.5 s (\(frames[29]))")

// peak line: starts falling at once, slower than the bar, never below it
var p = Ballistics(); p.step(level: 0.8, dt: 1.0 / 60); let top = p.peak
var bar = p
for _ in 0..<6 { p.step(level: 0, dt: 1.0 / 60) }            // 0.1 s of silence
check(p.peak < top - 0.01, "peak line: no hold, already falling after 0.1 s (\(top) -> \(p.peak))")
check(p.peak > p.shown, "peak line: falls slower than the bar (\(p.peak) > \(p.shown))")
for _ in 0..<150 { p.step(level: 0, dt: 1.0 / 60) }          // 2.5 s more
check(p.peak < 0.05, "peak line: gone after ~2.6 s (\(p.peak))")
p.step(level: 1, dt: 1.0 / 60)
check(p.peak == 1, "peak line: a new louder peak lifts it at once")

// the peak line is never below the bar, over a noisy sequence
var q = Ballistics(); var ok = true; var seed: UInt64 = 7
for _ in 0..<2000 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; let v = Float(seed >> 40) / Float(1 << 24); q.step(level: v * v, dt: 1.0 / 60); if q.peak + 1e-6 < q.shown { ok = false } }
check(ok, "invariant: the peak line is never below the bar")

// frame-rate independence: 0.1 s of release in one step or in six
var one = Ballistics(); one.step(level: 1, dt: 0.017); var nine = one
one.step(level: 0, dt: 0.1); for _ in 0..<6 { nine.step(level: 0, dt: 0.1 / 6) }
check(abs(one.shown - nine.shown) < 0.02, "release does not depend on the frame rate (\(one.shown) vs \(nine.shown))")
print(failed ? "LOGIC RESULT: FAILED" : "LOGIC RESULT: ALL PASSED"); exit(failed ? 1 : 0)

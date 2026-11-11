// AGENT HEADER - Tests/NeveCoreTests/MusicTests.swift  (BeatDetector finds 2 beats/s at 120 bpm from a synthetic 100 Hz burst signal in 512-frame blocks, silence is exactly 0; SnowField.stepMusic: silent music changes nothing, beats kick the wind within bounds and alternate, ignored under economy. Related: Music.swift.)

import Foundation
import Testing
@testable import NeveCore

/// Mono-in-stereo test signal: a 100 Hz burst of `burst` s every `period` s, fed in 512-frame blocks. Returns beats fired.
private func beats(period: Float, burst: Float = 0.06, seconds: Float, amp: Float = 0.6, sr: Float = 48000) -> Int {
    var d = BeatDetector(), n = 0
    let frames = 512, total = Int(seconds * sr) / frames
    var buf = [Float](repeating: 0, count: frames * 2)
    for b in 0..<total {
        for i in 0..<frames {
            let t = Float(b * frames + i) / sr, v = t.truncatingRemainder(dividingBy: period) < burst ? amp * sin(2 * .pi * 100 * t) : 0
            buf[2 * i] = v; buf[2 * i + 1] = v
        }
        if buf.withUnsafeBufferPointer({ d.process($0.baseAddress!, frames: frames, channels: 2, sampleRate: sr) }) { n += 1 }
    }
    return n
}

@Test func beatDetectorFindsTwoBeatsPerSecondAt120bpm() {
    let n = beats(period: 0.5, seconds: 10)
    #expect((18...21).contains(n), "beats \(n)")
}

@Test func beatDetectorSilenceIsExactlyZero() {
    var d = BeatDetector()
    let z = [Float](repeating: 0, count: 1024)
    for _ in 0..<200 { z.withUnsafeBufferPointer { _ = d.process($0.baseAddress!, frames: 512, channels: 2, sampleRate: 48000) } }
    #expect(d.out == .silent)
}

private func run(_ f: SnowField, steps: Int, music: (Int) -> MusicInput?) -> [Float] {
    var w: [Float] = []
    for i in 0..<steps { if let m = music(i) { f.music = m }; f.step(dt: 1.0 / 60); w.append(f.wind) }
    return w
}

@Test func silentMusicChangesNothing() {
    let a = makeField(flakes: 300, seed: 5), b = makeField(flakes: 300, seed: 5)
    _ = run(a, steps: 300) { _ in nil }
    _ = run(b, steps: 300) { _ in .silent }
    #expect(a.flakes.map(\.pos) == b.flakes.map(\.pos))
    #expect(a.glints.count == b.glints.count)
}

@Test func beatKicksTheWindWithinBoundsAndAlternates() {
    let a = makeField(flakes: 300, seed: 5), b = makeField(flakes: 300, seed: 5)
    let base = run(a, steps: 240) { _ in nil }
    // Two beats, 1 s apart: pulse high for 6 frames.
    let w = run(b, steps: 240) { i in MusicInput(level: 0.5, bass: 0.5, beat: (60..<66).contains(i) || (120..<126).contains(i) ? 1 : 0) }
    let d = zip(w, base).map { $0 - $1 }
    #expect(d[..<60].allSatisfy { abs($0) < 0.001 })   // level alone does not touch the wind
    let k1 = d[60..<100].max(by: { abs($0) < abs($1) })!, k2 = d[120..<160].max(by: { abs($0) < abs($1) })!
    #expect(abs(k1) > 10 && abs(k1) <= SnowField.musicGust + 0.01)
    #expect(k1 * k2 < 0)
    #expect(abs(d[239]) < 1)   // settled
    #expect(b.musicBoost <= 1.4 + 1e-5)
}

@Test func musicIsIgnoredWhenEconomy() {
    let b = makeField(flakes: 300, seed: 5)
    b.economy = true
    _ = run(b, steps: 120) { _ in MusicInput(level: 1, bass: 1, beat: 1) }
    #expect(b.musicKick == 0 && b.musicBoost == 1)
}

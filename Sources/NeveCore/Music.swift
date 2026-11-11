// AGENT HEADER - Sources/NeveCore/Music.swift  (beat detection + how music moves the snow)
// Role: `MusicInput` (level, bass, beat 0...1; beat jumps to 1 on an onset and decays in ~150 ms), `BeatDetector` (runs ON THE AUDIO THREAD: no allocation, no locks; per block RMS envelope, bass RMS through a ~150 Hz one-pole low-pass, onset = bass energy vs a ~1 s running mean with a 0.25 s
//   refractory) and SnowField.stepMusic: beats kick the wind (musicGust 30 pt/s, alternating sides, decays ~0.3 s), level adds sway and up to +40 % flakes (musicBoost), bass quickens the crest glints. Silence / Reduce Motion / economy / Low Power leave every factor at exactly 1 / 0.
// Data path: Sources/Neve/MusicTap.swift feeds the detector and publishes one 64-bit word; Overlay.tick reads `MusicTap.shared.read()` into `field.music` when Pref.music is on. Tests: MusicTests.

import Foundation

/// What the app hears, already smoothed: `level` and `bass` 0...1, `beat` a pulse that jumps to 1 on an onset and decays in ~150 ms.
public struct MusicInput: Equatable, Sendable {
    public var level: Float, bass: Float, beat: Float
    public init(level: Float = 0, bass: Float = 0, beat: Float = 0) { self.level = level; self.bass = bass; self.beat = beat }
    public static let silent = MusicInput()
}

/// Tiny audio analysis (called on the audio thread: no allocation, no locks). Per block: RMS envelope, bass RMS through a one-pole
/// low-pass (~150 Hz) and an onset test (bass energy vs a ~1 s running mean, 0.25 s refractory).
public struct BeatDetector: Sendable {
    public private(set) var out = MusicInput.silent
    private var lp: Float = 0, mean: Float = 0, sinceBeat: Float = 1
    public init() {}

    /// `samples`: interleaved, `frames` x `channels`. Returns (and stores in `out`) the smoothed state; `beatFired` is true on an onset block.
    @discardableResult
    public mutating func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Float) -> Bool {
        guard frames > 0, channels > 0, sampleRate > 0 else { return false }
        let dt = Float(frames) / sampleRate
        let a = 1 - exp(-2 * .pi * 150 / sampleRate)
        var e: Float = 0, eb: Float = 0
        var i = 0
        for _ in 0..<frames {
            var x: Float = 0
            for c in 0..<channels { x += samples[i + c] }
            x /= Float(channels); i += channels
            lp += a * (x - lp)
            e += x * x; eb += lp * lp
        }
        let rms = (e / Float(frames)).squareRoot(), bassRms = (eb / Float(frames)).squareRoot()
        sinceBeat += dt
        var fired = false
        if bassRms > 0.01, bassRms > 1.5 * mean, sinceBeat > 0.25 { fired = true; sinceBeat = 0 }
        mean += (bassRms - mean) * (1 - exp(-dt / 1.0))
        func follow(_ cur: Float, _ target: Float) -> Float {
            let v = cur + (target - cur) * (1 - exp(-dt / (target > cur ? 0.05 : 0.4)))
            return v < 0.003 ? 0 : v
        }
        out.level = follow(out.level, min(1, rms * 5))
        out.bass = follow(out.bass, min(1, bassRms * 6))
        out.beat = fired ? 1 : (out.beat * exp(-dt / 0.15) < 0.01 ? 0 : out.beat * exp(-dt / 0.15))
        return fired
    }
}

extension SnowField {
    static let musicGust: Float = 30   // pt/s peak sideways kick of a beat (a Nevasca gust peaks at 100)

    /// Beats kick the wind (alternating sides, decaying in ~0.3 s), level adds sway and up to +40% flakes, bass quickens the crest sparkles.
    /// Silence (or Reduce Motion / economy / Low Power) leaves every factor at exactly 1 / 0.
    func stepMusic(dt: Float) {
        let m = (calm || economy || lowPower || quiet) ? MusicInput.silent : music
        let level = min(max(m.level, 0), 1), bass = min(max(m.bass, 0), 1)
        if m.beat > 0.6, !musicEdge { musicEdge = true; musicDir = -musicDir; musicKick = musicDir * Self.musicGust * min(1, m.beat) }
        else if m.beat < 0.3 { musicEdge = false }
        musicKick = abs(musicKick) < 0.05 ? 0 : musicKick * exp(-dt * 3)
        musicSway = 1 + 0.5 * level
        musicGlint = 1 + 3 * bass
        let boost = 1 + 0.4 * (level * 10).rounded() / 10
        if boost != musicBoost { musicBoost = boost; setIntensity(intensity) }
    }
}

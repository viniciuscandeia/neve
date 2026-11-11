// AGENT HEADER - Sources/Neve/MusicTap.swift  (system-audio tap for "Neve dança com a música")
// Role: `MusicTap.shared` (@unchecked Sendable singleton) creates a global Core Audio process tap (macOS 14.2+, `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, excluding Neve's own process) + a private aggregate
//   device clocked by the default output device, with an IOProc that feeds `BeatDetector` (NeveCore/Music.swift; no allocation on the audio thread) and publishes level/bass/beat (3 x 16-bit, quantised to 0...65535)
//   into ONE aligned UInt64 (`word`): single writer = audio thread, single reader = Overlay.tick via read() -> MusicInput. No locks/atomics by design (see the ponytail comment).
// API: start() -> Bool (false on old macOS / permission refused / no output device / any Core Audio failure; it then tears everything down via fail()); stop() destroys IOProc, aggregate and tap (zero cost off); running; supported.
// Permission: NSAudioCaptureUsageDescription (Info.plist written by scripts/make-app.sh). Callers: AppController.syncMusic (main.swift) decides when it may run (option on, not Reduce Motion / economy / Low Power / scene).
// Gotcha: never retain anything the IOProc block allocates per call; the output format is assumed Float32 interleaved/first buffer only. If the default output device changes the tap is NOT rebuilt until stop()/start().

import CoreAudio
import AudioToolbox
import Foundation
import NeveCore

/// "Neve dança com a música": a global Core Audio process tap (macOS 14.2+) on everything the Mac plays, minus Neve itself.
/// The IOProc runs `BeatDetector` (no allocation) and publishes level / bass / beat packed in one aligned 64-bit word.
/// `stop()` destroys the IOProc, aggregate device and tap: zero cost when off.
final class MusicTap: @unchecked Sendable {
    static let shared = MusicTap()
    static var supported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    // ponytail: one aligned UInt64 written by the audio thread, read by the render tick (no Atomics module before macOS 15).
    // Single writer, single reader; a torn read is impossible for an aligned 64-bit access on arm64 / x86-64.
    private let word = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private var detector = BeatDetector()
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Float = 48000
    var running: Bool { procID != nil }

    private init() { word.initialize(to: 0) }

    func read() -> MusicInput {
        let w = word.pointee
        return MusicInput(level: Float(w & 0xFFFF) / 65535, bass: Float((w >> 16) & 0xFFFF) / 65535, beat: Float((w >> 32) & 0xFFFF) / 65535)
    }

    private func publish() {
        let o = detector.out
        func q(_ v: Float) -> UInt64 { UInt64(min(max(v, 0), 1) * 65535) }
        word.pointee = q(o.level) | q(o.bass) << 16 | q(o.beat) << 32
    }

    /// False when the tap cannot be created (old macOS, permission refused, no output device).
    @discardableResult
    func start() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        guard !running else { return true }
        var pid = getpid(), own = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &own)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        desc.name = "Neve"; desc.muteBehavior = .unmuted; desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return fail() }

        // Output device UID: the aggregate needs a clock source.
        var dev = AudioObjectID(kAudioObjectUnknown)
        addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return fail() }
        var uid: Unmanaged<CFString>?
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let outUID = uid?.takeRetainedValue() as String? else { return fail() }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Neve music",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID) == noErr else { return fail() }

        var fmt = AudioStreamBasicDescription()
        addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 { sampleRate = Float(fmt.mSampleRate) }

        detector = BeatDetector()
        word.pointee = 0
        let block: AudioDeviceIOBlock = { [self] _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { return }
            let ch = Int(b.mNumberChannels)
            detector.process(p, frames: Int(b.mDataByteSize) / (4 * ch), channels: ch, sampleRate: sampleRate)
            publish()
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, block) == noErr, let procID, AudioDeviceStart(aggID, procID) == noErr else { return fail() }
        return true
    }

    private func fail() -> Bool { stop(); return false }

    func stop() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        word.pointee = 0
    }
}

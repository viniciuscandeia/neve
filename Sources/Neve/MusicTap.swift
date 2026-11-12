// AGENT HEADER - Sources/Neve/MusicTap.swift  (system-audio tap for "Neve dança com a música")
// Role: `MusicTap.shared` (@unchecked Sendable singleton) creates a global Core Audio process tap (macOS 14.2+, `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, excluding Neve's own process) + a private aggregate
//   device clocked by the default output device, with an IOProc that feeds `BeatDetector` (NeveCore/Music.swift; no allocation on the audio thread) and publishes level/bass/beat (3 x 16-bit, quantised to 0...65535)
//   into ONE UInt64 (`word`, an OSAllocatedUnfairLock<UInt64>): writer = audio thread (+ start/stop reset on main), reader = Overlay.tick via read() -> MusicInput.
// API: start() -> Bool (false on old macOS / permission refused / no output device / any Core Audio failure; it then tears everything down via fail()); stop() destroys IOProc, aggregate and tap (zero cost off); running; supported.
// Permission: NSAudioCaptureUsageDescription (Info.plist written by scripts/make-app.sh). Callers: AppController.syncMusic (main.swift) decides when it may run (option on, snow rendering, not Reduce Motion / economy / Low Power / scene).
// Gotcha: never retain anything the IOProc block allocates per call; the output format is assumed Float32 interleaved/first buffer only. A listener on the default system output device (main queue, installed while running, removed in stop()) restarts the capture (debounced 0.3 s) when the output changes.

import CoreAudio
import AudioToolbox
import Foundation
import NeveCore
import os

/// "Neve dança com a música": a global Core Audio process tap (macOS 14.2+) on everything the Mac plays, minus Neve itself.
/// The IOProc runs `BeatDetector` (no allocation) and publishes level / bass / beat packed in one aligned 64-bit word.
/// `stop()` destroys the IOProc, aggregate device and tap: zero cost when off.
final class MusicTap: @unchecked Sendable {
    static let shared = MusicTap()
    static var supported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    // The packed word is written by the audio thread and read by the render tick / reset by start()/stop() on main: guarded by an unfair lock (allocation-free, held for one 64-bit store/load).
    private let word = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private var detector = BeatDetector()
    private var tapID = AudioObjectID(kAudioObjectUnknown), aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Float = 48000
    var running: Bool { procID != nil }

    private var outListener: AudioObjectPropertyListenerBlock?
    private var restartWork: DispatchWorkItem?
    private static var outAddr: AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain) }

    private init() {}

    /// The aggregate is clocked by the output device chosen at start(): when it changes, rebuild (debounced; stop() cancels a pending one).
    private func watchOutput() {
        let l: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.restartWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                self.stop(); self.start()
            }
            self.restartWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
        outListener = l
        var a = Self.outAddr
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l)
    }

    func read() -> MusicInput {
        let w = word.withLock { $0 }
        return MusicInput(level: Float(w & 0xFFFF) / 65535, bass: Float((w >> 16) & 0xFFFF) / 65535, beat: Float((w >> 32) & 0xFFFF) / 65535)
    }

    private func publish() {
        let o = detector.out
        func q(_ v: Float) -> UInt64 { UInt64(min(max(v, 0), 1) * 65535) }
        let packed = q(o.level) | q(o.bass) << 16 | q(o.beat) << 32
        word.withLock { $0 = packed }
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
        word.withLock { $0 = 0 }
        let block: AudioDeviceIOBlock = { [self] _, input, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { return }
            let ch = Int(b.mNumberChannels)
            detector.process(p, frames: Int(b.mDataByteSize) / (4 * ch), channels: ch, sampleRate: sampleRate)
            publish()
        }
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, block) == noErr, let procID, AudioDeviceStart(aggID, procID) == noErr else { return fail() }
        if outListener == nil { watchOutput() }
        return true
    }

    private func fail() -> Bool { stop(); return false }

    func stop() {
        restartWork?.cancel(); restartWork = nil
        if let l = outListener { var a = Self.outAddr; AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, l); outListener = nil }
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        word.withLock { $0 = 0 }
    }
}

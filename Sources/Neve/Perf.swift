// AGENT HEADER - Sources/Neve/Perf.swift  (NEVE_PERF instrumentation: per-overlay meters, poll cost, signposts)
// Role: `Perf` namespace + `Perf.Meter` (one per Overlay, created only when NEVE_PERF=1). Every 5 s each meter prints one line to stderr and appends it to $NEVE_PERF_LOG: `[screenN WxH] ticks/s presents/s`, per-slot cost
//   (step input drag pile actors write encode: ms per presented frame `/f`, CPU ms per wall second `/s`, max, n), pile.ease/contour/join ms per write, flakesim ms, hitch ms/s + drops/s (HitchMeter, NeveCore), gpu ms
//   (from the command-buffer completion handler), cpu %, main %, counters (skipSize/skipSlot/skipCmd...), busy reasons, entity counts, truncation (prims/piles). A separate `poll n=... ms/call` line covers pollWindows.
// Hitch bursts: `[hitch-sec ...]` lines (one per second with > 8 ms late presents: max tick gap, slot peaks, poll, tick/pileWrites/fast/flips deltas); counters fast (cursor asked for 60 fps) and flips (30/60 range switches).
// Consumers: scripts/perf.sh parses the `[screen...]` lines (keys ticks/s, step, flakesim, gpu, hitch) - renaming a field breaks perf.sh / perf-suite.sh.
// Cost when off: every entry is one branch on a static let (`Perf.on`); Perf.now() returns 0; no allocation. Signposts (`Perf.signposter`, subsystem io.github.viniciuscandeia.neve, category frame: "sim", "encode") are free unless Instruments records.
// Threading: Meter state is main-thread, except `gpu` and `hitch` (OSAllocatedUnfairLock) written from Metal completion / presented handlers on other threads - hence @unchecked Sendable.
// Env: NEVE_PERF=1, NEVE_PERF_LOG=<file>. Injects Perf.seconds into SnowField.timer for flake/pile sub-timings. Callers: Overlay.tick/render, AppController.pollWindows (addPoll).

import Darwin
import Foundation
import NeveCore
import Metal
import os

/// NEVE_PERF=1: one line per overlay (monitor) every 5 s to stderr (and appended to $NEVE_PERF_LOG), plus one `poll` line.
/// Slot costs are ms per presented frame (`/f`), CPU ms per wall second (`/s`) and worst sample; counters show where ticks went.
/// Off: every entry point is a single branch on a static let, no allocation.
enum Perf {
    enum Slot: Int, CaseIterable { case step, input, drag, pile, actors, write, encode }
    static let slotNames = ["step", "input", "drag", "pile", "actors", "write", "encode"]

    nonisolated static let on = ProcessInfo.processInfo.environment["NEVE_PERF"] == "1"
    nonisolated static let logPath = ProcessInfo.processInfo.environment["NEVE_PERF_LOG"]

    /// Signposts for Instruments (zero cost when no trace is recording).
    nonisolated static let signposter = OSSignposter(subsystem: "io.github.viniciuscandeia.neve", category: "frame")

    @inline(__always) static func now() -> UInt64 { on ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0 }

    /// Seconds clock injected into `SnowField.timer` (only when NEVE_PERF=1).
    static func seconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    static func emit(_ line: String) {
        FileHandle.standardError.write(Data(line.utf8))
        if let p = logPath, let h = FileHandle(forWritingAtPath: p) ?? { FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p) }() {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        }
    }

    // Window poll (global, main thread): its own 5 s window.
    @MainActor private static var poll = PerfStat()
    @MainActor private static var pollStart: UInt64 = 0
    @MainActor fileprivate static var pollSecN = 0, pollSecMax: UInt64 = 0   // poll calls / worst call in the current second (Meter's hitch-burst line)
    @MainActor static func addPoll(_ t0: UInt64) {
        guard on else { return }
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        poll.add(t &- t0); pollSecN += 1; pollSecMax = max(pollSecMax, t &- t0)
        if pollStart == 0 { pollStart = t }
        if t &- pollStart >= 5_000_000_000 {
            let wall = Double(t &- pollStart) / 1e9
            emit(String(format: "poll n=%d %.3fms/call %.3fms/s max=%.3fms\n", poll.n, poll.msPerFrame(poll.n), poll.msPerSecond(wall), poll.peakMs))
            poll = PerfStat(); pollStart = t
        }
    }

    /// One per overlay. Main-thread state except `gpu`, written from the command buffer completion handler.
    final class Meter: @unchecked Sendable {
        enum Count: Int, CaseIterable { case ticks, hidden, renders, skipSize, skipSlot, skipCmd, commits, pileWrites, pileHits, fast, flips }
        private static let countNames = ["ticks", "hidden", "renders", "skipSize", "skipSlot", "skipCmd", "commits", "pileWrites", "pileHits", "fast", "flips"]
        let label: String
        private var stat = [PerfStat](repeating: PerfStat(), count: Slot.allCases.count)
        private var count = [Int](repeating: 0, count: Count.allCases.count)
        private var busy = [Int](repeating: 0, count: BusyReasons.names.count), busyFrames = 0
        func busyNow(_ r: BusyReasons) { if !r.isEmpty { busyFrames += 1 }; for (i, e) in BusyReasons.names.enumerated() where r.contains(e.0) { busy[i] += 1 } }
        private var instances = 0, truncPrims = 0, truncPiles = 0, segs = 0
        private var winStart: UInt64 = 0, cpuStart = 0.0
        private let gpu = OSAllocatedUnfairLock(initialState: (sum: 0.0, count: 0))
        private let hitch = OSAllocatedUnfairLock(initialState: HitchMeter())
        /// Presented handler of the frame's drawable (any thread); `target` is the tick's own target timestamp, captured when it was encoded.
        func presented(_ at: Double, target: Double) {
            let d = hitch.withLock { m -> (Double, Int) in let h = m.hitchMs, n = m.drops; m.present(at: at, target: target); return (m.hitchMs - h, m.drops - n) }
            if d.1 > 0 { hitchSec.withLock { $0.ms += d.0; $0.drops += d.1 } }
        }
        private let hitchSec = OSAllocatedUnfairLock(initialState: (ms: 0.0, drops: 0))
        // Per-second context for the hitch-burst line (`[hitch-sec]`): worst tick gap, worst slot samples, count deltas, poll.
        private var secStart: UInt64 = 0, lastTick: UInt64 = 0, secGap: UInt64 = 0, secBase = [Int](repeating: 0, count: Count.allCases.count), secPeak = [UInt64](repeating: 0, count: Slot.allCases.count)
        var secSlow = false
        init(label: String) { self.label = label }

        func add(_ s: Slot, _ t0: UInt64) { let d = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0; stat[s.rawValue].add(d); if d > secPeak[s.rawValue] { secPeak[s.rawValue] = d } }
        func bump(_ c: Count) { count[c.rawValue] += 1 }
        func truncated(prims: Int = 0, piles: Int = 0) { truncPrims += prims; truncPiles += piles }
        func setInstances(_ c: Int) { instances = c }
        func setSegs(_ c: Int) { segs = c }

        /// Completion handler of the frame's command buffer (any thread).
        func gpuDone(_ cmd: any MTLCommandBuffer) {
            let d = cmd.gpuEndTime - cmd.gpuStartTime
            if d > 0 { gpu.withLock { $0.sum += d; $0.count += 1 } }
        }

        private static func cpu() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
        }

        /// Once per tick (end): emits the report every 5 s. `extra` is state only the overlay knows (paused, occluded).
        @MainActor func frame(_ field: SnowField, _ extra: @autoclosure () -> String) {
            let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if lastTick != 0 { secGap = max(secGap, t &- lastTick) }
            lastTick = t
            if secStart == 0 { secStart = t; secBase = count } else if t &- secStart >= 1_000_000_000 { secReport(field, t) }
            if winStart == 0 { winStart = t; cpuStart = Self.cpu(); return }
            if t &- winStart >= 5_000_000_000 { report(field, t, extra()) }
        }

        /// Once per second: when the second had late presents (> 8 ms), one line saying what else happened in it. A tick gap near the hitch = our main thread stalled (see slot peaks / poll);
        /// small gaps with a hitch = compositor / GPU side. Counts are deltas for the second: fast (60 fps requested by the cursor), flips (30/60 range switches), pileWrites, ticks.
        @MainActor private func secReport(_ field: SnowField, _ t: UInt64) {
            let h = hitchSec.withLock { let v = $0; $0 = (0, 0); return v }
            if h.ms > 8 {
                var line = String(format: "[hitch-sec %@] hitch=%.1fms drops=%d maxTickGap=%.1fms poll(n=%d max=%.2fms) peaks:", label, h.ms, h.drops, Double(secGap) / 1e6, Perf.pollSecN, Double(Perf.pollSecMax) / 1e6)
                for (i, nm) in Perf.slotNames.enumerated() { line += String(format: " %@=%.2f", nm, Double(secPeak[i]) / 1e6) }
                for c in [Count.ticks, .pileWrites, .fast, .flips] { line += " \(Self.countNames[c.rawValue])=\(count[c.rawValue] - secBase[c.rawValue])" }
                let why = BusyReasons.names.filter { field.busyReasons.contains($0.0) }.map { $0.1 }.joined(separator: "+")
                line += " busyNow=\(why.isEmpty ? "-" : why) debris=\(field.debris.count) slow=\(secSlow)\n"
                Perf.emit(line)
            }
            secStart = t; secGap = 0; secBase = count; for i in secPeak.indices { secPeak[i] = 0 }
            Perf.pollSecN = 0; Perf.pollSecMax = 0
        }

        @MainActor private func report(_ field: SnowField, _ t: UInt64, _ extra: String) {
            let wall = Double(t &- winStart) / 1e9
            let c = Self.cpu()
            let g = gpu.withLock { let v = $0; $0 = (0, 0); return v }
            let h = hitch.withLock { $0.take(wall: wall) }
            let presents = count[Count.commits.rawValue], writes = count[Count.pileWrites.rawValue]
            var line = String(format: "[%@] ticks/s=%.1f presents/s=%.1f", label, Double(count[0]) / wall, Double(presents) / wall)
            var mainNs: UInt64 = 0
            for (i, st) in stat.enumerated() {
                line += String(format: " %@=%.3f/f %.2f/s max%.2f(n=%d)", Perf.slotNames[i], st.msPerFrame(presents), st.msPerSecond(wall), st.peakMs, st.n)
                mainNs &+= st.sum
            }
            let ps = field.pileSeconds, per = writes == 0 ? 0 : 1000 / Double(writes)
            line += String(format: " pile.ease=%.3f pile.contour=%.3f pile.join=%.3f ms/write", ps.ease * per, ps.contour * per, ps.join * per)
            field.pileSeconds = (0, 0, 0)
            let debris = field.debris.count
            let fl = field.flakeSteps == 0 ? 0 : field.flakeSeconds / Double(field.flakeSteps) * 1000
            line += String(format: " flakesim=%.3fms(n=%d)", fl, field.flakeSteps)
            field.flakeSeconds = 0; field.flakeSteps = 0
            line += String(format: " hitch=%.2f drops=%.2f", h.msPerSecond, h.dropsPerSecond)
            line += String(format: " gpu=%.3fms(n=%d) cpu=%.1f%% main=%.1f%%", g.count == 0 ? 0 : g.sum / Double(g.count) * 1000, g.count, (c - cpuStart) / wall * 100, Double(mainNs) / 1e9 / wall * 100)
            for (i, nm) in Self.countNames.enumerated() { line += " \(nm)=\(count[i])" }
            line += " busy=\(busyFrames)[" + BusyReasons.names.enumerated().map { "\($1.1)=\(busy[$0])" }.joined(separator: " ") + "]"
            line += " segs=\(segs) \(extra) flakes=\(max(instances - debris, 0)) debris=\(debris) balls=\(field.balls.count) figures=\(field.figures.count) fights=\(field.fights.count) shots=\(field.shots.count) trunc=prims:\(truncPrims)/piles:\(truncPiles)\n"
            Perf.emit(line)
            for i in stat.indices { stat[i] = PerfStat() }
            for i in count.indices { count[i] = 0 }
            truncPrims = 0; truncPiles = 0; busyFrames = 0; for i in busy.indices { busy[i] = 0 }
            winStart = t; cpuStart = c
        }
    }
}

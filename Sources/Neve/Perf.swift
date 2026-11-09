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
    @MainActor static func addPoll(_ t0: UInt64) {
        guard on else { return }
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        poll.add(t &- t0)
        if pollStart == 0 { pollStart = t }
        if t &- pollStart >= 5_000_000_000 {
            let wall = Double(t &- pollStart) / 1e9
            emit(String(format: "poll n=%d %.3fms/call %.3fms/s max=%.3fms\n", poll.n, poll.msPerFrame(poll.n), poll.msPerSecond(wall), poll.peakMs))
            poll = PerfStat(); pollStart = t
        }
    }

    /// One per overlay. Main-thread state except `gpu`, written from the command buffer completion handler.
    final class Meter: @unchecked Sendable {
        enum Count: Int, CaseIterable { case ticks, hidden, renders, skipSize, skipSlot, skipCmd, commits, pileWrites, pileHits }
        private static let countNames = ["ticks", "hidden", "renders", "skipSize", "skipSlot", "skipCmd", "commits", "pileWrites", "pileHits"]
        let label: String
        private var stat = [PerfStat](repeating: PerfStat(), count: Slot.allCases.count)
        private var count = [Int](repeating: 0, count: Count.allCases.count)
        private var busy = [Int](repeating: 0, count: BusyReasons.names.count), busyFrames = 0
        func busyNow(_ r: BusyReasons) { if !r.isEmpty { busyFrames += 1 }; for (i, e) in BusyReasons.names.enumerated() where r.contains(e.0) { busy[i] += 1 } }
        private var instances = 0, truncPrims = 0, truncPiles = 0, segs = 0
        private var winStart: UInt64 = 0, cpuStart = 0.0
        private let gpu = OSAllocatedUnfairLock(initialState: (sum: 0.0, count: 0))
        init(label: String) { self.label = label }

        func add(_ s: Slot, _ t0: UInt64) { stat[s.rawValue].add(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0) }
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
            if winStart == 0 { winStart = t; cpuStart = Self.cpu(); return }
            if t &- winStart >= 5_000_000_000 { report(field, t, extra()) }
        }

        @MainActor private func report(_ field: SnowField, _ t: UInt64, _ extra: String) {
            let wall = Double(t &- winStart) / 1e9
            let c = Self.cpu()
            let g = gpu.withLock { let v = $0; $0 = (0, 0); return v }
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

import Darwin
import Foundation
import NeveCore
import Metal
import os

/// NEVE_PERF=1: per-slot main-thread timings, GPU time and process CPU, one line every 5 s to stderr
/// (and appended to $NEVE_PERF_LOG). Off: every entry point is a single branch on a static let, no allocation.
@MainActor
enum Perf {
    enum Slot: Int, CaseIterable { case step, input, pile, actors, write, encode, poll }
    private static let names = ["step", "input", "pile", "actors", "write", "encode", "poll"]

    nonisolated static let on = ProcessInfo.processInfo.environment["NEVE_PERF"] == "1"
    /// Written from the command buffer completion handler (off-main), read on main.
    nonisolated private static let gpu = OSAllocatedUnfairLock(initialState: (sum: 0.0, count: 0))

    private static var sum = [UInt64](repeating: 0, count: 7)
    private static var peak = [UInt64](repeating: 0, count: 7)
    private static var n = [Int](repeating: 0, count: 7)
    private static var frames = 0
    private static var instances = 0
    private static var winStart: UInt64 = 0
    private static var cpuStart = 0.0

    @inline(__always) static func now() -> UInt64 { on ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0 }

    @inline(__always) static func add(_ s: Slot, _ t0: UInt64) {
        guard on else { return }
        let d = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- t0
        sum[s.rawValue] &+= d
        n[s.rawValue] += 1
        if d > peak[s.rawValue] { peak[s.rawValue] = d }
    }

    @inline(__always) static func setInstances(_ c: Int) { if on { instances = c } }

    /// Completion handler of the frame's command buffer (any thread).
    nonisolated static func gpuDone(_ cmd: any MTLCommandBuffer) {
        guard on else { return }
        let d = cmd.gpuEndTime - cmd.gpuStartTime
        if d > 0 { gpu.withLock { $0.sum += d; $0.count += 1 } }
    }

    private static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// Once per tick: counts the frame and, every 5 s, emits the report.
    @inline(__always) static func frame(_ field: SnowField) {
        guard on else { return }
        frames += 1
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if winStart == 0 { winStart = t; cpuStart = cpu(); return }
        if t &- winStart >= 5_000_000_000 { report(field, t) }
    }

    private static func report(_ field: SnowField, _ t: UInt64) {
        let wall = Double(t &- winStart) / 1e9
        let c = cpu()
        let g = gpu.withLock { let v = $0; $0 = (0, 0); return v }
        var line = String(format: "fps=%.1f", Double(frames) / wall)
        var mainNs: UInt64 = 0
        for i in 0..<7 {
            let avg = n[i] == 0 ? 0 : Double(sum[i]) / Double(n[i]) / 1e6
            line += String(format: " %@=%.3f/%.3fms(n=%d)", names[i], avg, Double(peak[i]) / 1e6, n[i])
            mainNs &+= sum[i]
            sum[i] = 0; peak[i] = 0; n[i] = 0
        }
        let debris = field.debris.count
        line += String(format: " gpu=%.3fms(n=%d) cpu=%.1f%% main=%.1f%%", g.count == 0 ? 0 : g.sum / Double(g.count) * 1000, g.count, (c - cpuStart) / wall * 100, Double(mainNs) / 1e9 / wall * 100)
        line += " flakes=\(max(instances - debris, 0)) debris=\(debris) balls=\(field.balls.count) snowman=\(field.snowman == nil ? 0 : 1) fights=\(field.walk.fights.count) shots=\(field.walk.shots.count)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let p = ProcessInfo.processInfo.environment["NEVE_PERF_LOG"], let h = FileHandle(forWritingAtPath: p) ?? { FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p) }() {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        }
        frames = 0; winStart = t; cpuStart = c
    }
}

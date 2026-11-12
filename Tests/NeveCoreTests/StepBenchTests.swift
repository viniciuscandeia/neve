// AGENT HEADER - Tests/NeveCoreTests/StepBenchTests.swift  (headless step-cost / frame-rate benchmark; runs only with NEVE_BENCH=1)
// `NEVE_BENCH=1 Tests/run.sh -r StepBench` replays the on-screen perf-suite scenarios (scripts/perf-suite.sh) without a screen: a 1440x900 field (400 flakes, Dock ground 90) with two Finder-sized windows
//   (CG 100,100-700,500 and 760,160-1360,560) and a floating Dock bar, Media (intensity 1) or Nevasca (3), figures off. Overlay.tick is mirrored: adaptive rate (30 fps quiet, 60 for NEVE_HOLD = 2.5 s after
//   a busy frame or a fast cursor over snow), one step per frame, the cursor sweep (scripts/cursor-sweep.swift: 4 s per segment, sinusoidal, 600 pt/s peak, y wobble 4..8 pt above the edge) via SnowField.sweep.
//   Scenarios: quiet (cursor parked), mounds (sweep over both window tops + the ground edge, pointer on), void (sweep over empty space, pointer off). Warm-up NEVE_WARM s (default 30, cursor parked), measure NEVE_SECS (default 60).
//   Output per scenario: step ms per frame (mean / p99 / max), per-section ms per frame (SnowField.lap hook), sim ms per wall second (~ CPU of the sim alone), fraction of frames at 60 fps, isBusy fraction and reasons,
//   debris count distribution, ms/s spent in frames over 8 ms (hitch proxy). Deterministic (seeded; CPU-time clock). Run it at two commits to compare: copy this file + the `lap` hook (SnowField.step) there.

import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import NeveCore

private func cpuNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) }
private func env(_ k: String, _ d: Double) -> Double { ProcessInfo.processInfo.environment[k].flatMap(Double.init) ?? d }

private struct BenchResult {
    var frames = 0, fast = 0, busy = 0, wall = 0.0
    var steps: [Double] = [], debris: [Int] = []
    var laps: [String: Double] = [:], reasons = [Int](repeating: 0, count: BusyReasons.names.count)
    var sweepMs = 0.0, spikeMs = 0.0, renderMs = 0.0, renderPeak = 0.0, pileWrites = 0
    var frame: [Double] = []   // step + input + render per frame
    var kinds: [String: Int] = [:]   // debris by shape (+ v = carries volume, o = origin is a window, i.e. shed/overflow rather than sweep/ground)
}

private func runBench(_ name: String, nevasca: Bool, sweep: Bool, pointer: Bool) {
    if let only = ProcessInfo.processInfo.environment["NEVE_ONLY"], !name.contains(only) { return }   // e.g. NEVE_ONLY="nevasca mounds"
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 876, flakeCount: 400, seed: UInt64(env("NEVE_SEED", 7)))
    f.setIntensity(nevasca ? .nevasca : .media, immediate: true)
    f.snowmanEnabled = false; f.walkEnabled = false; f.visitorsEnabled = false; f.sleighEnabled = false; f.pointerPush = pointer; f.lightsEnabled = true   // the app default (Christmas lights): lightCode runs per flake in writeInstances
    let dock = WindowInfo(number: 0, frame: CGRect(x: 420, y: 10, width: 600, height: 84), radius: 25.2)
    f.update(windows: [dock, win(1, 100, 400, 600, 400), win(2, 760, 340, 600, 400)], now: 0)
    // CG segments (x0, x1, y); AppKit y = 900 - y.
    let segs: [(Double, Double, Double)] = pointer ? [(130, 670, 100), (790, 1330, 160), (120, 1320, 900 - 90)] : [(300, 1100, 620)]
    var res = BenchResult()
    let pcap = f.pileSegDemand + 2000, piles = UnsafeMutablePointer<PileSeg>.allocate(capacity: pcap), inst = UnsafeMutablePointer<Instance>.allocate(capacity: f.capacity)
    defer { piles.deallocate(); inst.deallocate() }
    var cur: [String: UInt64] = [:], peak: [String: UInt64] = [:], t0: UInt64 = 0
    var now = 0.0, slow = false, fastUntil = 0.0, last: CGPoint? = nil
    let warm = env("NEVE_WARM", 30), secs = env("NEVE_SECS", 60)
    var measureStart = -1.0
    while true {
        let fps = slow ? 30.0 : 60.0, dt = 1 / fps
        now += dt
        let measuring = now >= warm
        if measuring && measureStart < 0 { measureStart = now }
        if measuring && now - measureStart >= secs { break }
        var here: CGPoint? = nil
        if sweep && measuring {
            let t = now - measureStart
            let (x0, x1, y) = segs[Int(t / 4) % segs.count]
            let half = (x1 - x0) / 2
            here = CGPoint(x: (x0 + x1) / 2 + half * sin(t * 600 / max(half, 1)), y: 900 - (y - 4 - 4 * sin(t * 3.1)))
        }
        let tFrame = cpuNs()
        var sweptNear = false
        if let h = here, let l = last {
            f.sweep(from: l, to: h, dt: Float(dt))
            sweptNear = f.snowNear(from: l, to: h)
        }
        f.setPointer(here.map { SIMD2(Float($0.x), Float($0.y)) }, velocity: .zero)
        var fastCursor = false
        if let h = here, let l = last {
            let v = hypot(h.x - l.x, h.y - l.y) / dt
            fastCursor = v > 60 && (pointer || sweptNear)
        }
        last = here
        let tInput = cpuNs()
        if measuring { f.lap = { n in let t = cpuNs(), d = t &- t0; cur["\(n)", default: 0] += d; peak["\(n)"] = max(peak["\(n)"] ?? 0, d); t0 = t } } else { f.lap = nil }
        t0 = cpuNs()
        f.step(dt: Float(dt))
        let tEnd = cpuNs()
        let wrote = f.writePiles(to: piles, capacity: pcap, dt: Float(dt)) != nil
        _ = f.writeInstances(to: inst, lag: 0)
        let tRender = cpuNs()
        if measuring {
            let ms = Double(tEnd &- tInput) / 1e6, input = Double(tInput &- tFrame) / 1e6
            let rms = Double(tRender &- tEnd) / 1e6
            res.renderMs += rms; res.renderPeak = max(res.renderPeak, rms); if wrote { res.pileWrites += 1 }; res.frame.append(ms + input + rms)
            res.frames += 1; res.steps.append(ms + input); res.sweepMs += input; res.wall += dt
            if ms + input > 8 { res.spikeMs += ms + input }
            res.debris.append(f.debris.count)
            for d in f.debris { res.kinds["s\(d.shape)\(d.vol > 0 ? "v" : "")\(d.amp > 0 ? "A" : "")", default: 0] += 1 }
            if !slow { res.fast += 1 }
            let r = f.busyReasons
            if !r.isEmpty { res.busy += 1; if ProcessInfo.processInfo.environment["NEVE_TRACE"] != nil { print("BUSY t=\(String(format: "%.1f", now)) slabs=\(f.debris.filter { $0.amp > 0 }.count) clumps=\(f.debris.filter { $0.shape == 1 }.count) dots=\(f.debris.filter { $0.shape == 0 }.count) slabsizes=\(f.debris.filter { $0.amp > 0 }.map { Int($0.size) })") } }
            for (i, e) in BusyReasons.names.enumerated() where r.contains(e.0) { res.reasons[i] += 1 }
        }
        let busy = f.isBusy
        if fastCursor || busy { fastUntil = now + 2.5 }
        slow = now > fastUntil
    }
    for (k, v) in cur { res.laps[k] = v > 0 ? Double(v) / 1e6 : 0 }
    let n = Double(res.frames), sorted = res.steps.sorted(), ds = res.debris.sorted()
    func p(_ a: [Double], _ q: Double) -> Double { a[min(a.count - 1, Int(Double(a.count) * q))] }
    let mean = res.steps.reduce(0, +) / n
    var out = "STEPBENCH \(name): frames=\(res.frames) fps60=\(String(format: "%.2f", Double(res.fast) / n)) busy=\(String(format: "%.2f", Double(res.busy) / n)) "
    out += "step ms mean=\(String(format: "%.3f", mean)) p99=\(String(format: "%.2f", p(sorted, 0.99))) max=\(String(format: "%.2f", sorted.last ?? 0)) sim ms/s=\(String(format: "%.1f", mean * n / res.wall)) spike ms/s=\(String(format: "%.2f", res.spikeMs / res.wall)) "
    out += "input ms=\(String(format: "%.3f", res.sweepMs / n)) debris mean=\(String(format: "%.1f", Double(res.debris.reduce(0, +)) / n)) p50=\(ds[ds.count / 2]) p95=\(ds[Int(n * 0.95)]) max=\(ds.last ?? 0)\n"
    let fs = res.frame.sorted()
    out += "  render (writePiles+writeInstances) ms mean=\(String(format: "%.3f", res.renderMs / n)) max=\(String(format: "%.2f", res.renderPeak)) pileWrites=\(String(format: "%.2f", Double(res.pileWrites) / n)) | step+input+render ms mean=\(String(format: "%.3f", res.frame.reduce(0, +) / n)) p99=\(String(format: "%.2f", p(fs, 0.99))) max=\(String(format: "%.2f", fs.last ?? 0)) frames>1ms=\(fs.filter { $0 > 1 }.count)\n"
    out += "  reasons: " + BusyReasons.names.enumerated().filter { res.reasons[$0.offset] > 0 }.map { "\($0.element.1)=\(String(format: "%.2f", Double(res.reasons[$0.offset]) / n))" }.joined(separator: " ") + "\n"
    out += "  debris mean by kind (shape, v=volume, A=intact slab): " + res.kinds.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\(String(format: "%.1f", Double($0.value) / n))" }.joined(separator: " ") + "\n"
    out += "  section PEAK ms: " + peak.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key)=\(String(format: "%.3f", Double($0.value) / 1e6))" }.joined(separator: " ") + "\n"
    out += "  sections ms/frame: " + res.laps.sorted { $0.value > $1.value }.filter { $0.value / n > 0.002 }.map { "\($0.key)=\(String(format: "%.3f", $0.value / n))" }.joined(separator: " ")
    print(out)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NEVE_BENCH"] == "1"))
func stepBench() {
    for (label, nev) in [("media", false), ("nevasca", true)] {
        runBench("\(label) quiet", nevasca: nev, sweep: false, pointer: true)
        runBench("\(label) mounds", nevasca: nev, sweep: true, pointer: true)
        runBench("\(label) void", nevasca: nev, sweep: true, pointer: false)
    }
}

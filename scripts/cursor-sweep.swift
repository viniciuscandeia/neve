// AGENT HEADER - scripts/cursor-sweep.swift
// Role: standalone tool (compiled by scripts/perf.sh with swiftc -O into build/cursor-sweep) that drives the REAL cursor via CGWarpMouseCursorPosition for a perf scenario.
// Usage: cursor-sweep <secs> <x0,x1,y> [<x0,x1,y> ...] in CG coordinates (top-left origin, pt). 4 s per segment, sinusoidal sweep with peak speed ~600 pt/s regardless of length,
// 8 ms steps, y wobbles 4..8 pt above the segment so the cursor cuts through the snow resting on that edge (exercises the pointer push / CursorThrow paths).
// Restores the original cursor position on normal exit and on SIGTERM/SIGINT. Moves the user's real pointer: only run under the screen lock.

import CoreGraphics
import Foundation

let args = CommandLine.arguments.dropFirst()
guard let secs = args.first.flatMap(Double.init), args.count > 1 else {
    FileHandle.standardError.write(Data("usage: cursor-sweep <secs> <x0,x1,y>...\n".utf8)); exit(2)
}
let segs: [(Double, Double, Double)] = args.dropFirst().compactMap {
    let v = $0.split(separator: ",").compactMap { Double($0) }
    return v.count == 3 ? (v[0], v[1], v[2]) : nil
}
let start = CGEvent(source: nil)?.location ?? .zero
// SIGTERM/SIGINT: put the cursor back (the sweep loop runs off the main queue so the handler can fire).
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { CGWarpMouseCursorPosition(start); exit(0) }
    src.resume()
    sources.append(src)
}
let t0 = Date()
DispatchQueue.global().async {
while true {
    let t = Date().timeIntervalSince(t0)
    if t >= secs { break }
    let k = Int(t / 4) % segs.count   // 4 s per segment
    let (x0, x1, y) = segs[k]
    let mid = (x0 + x1) / 2, half = (x1 - x0) / 2
    let x = mid + half * sin(t * 600 / max(half, 1))   // peak speed 600 pt/s whatever the length
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y - 4 - 4 * sin(t * 3.1)))   // inside the snow just above the edge
    usleep(8000)
}
CGWarpMouseCursorPosition(start)
exit(0)
}
dispatchMain()

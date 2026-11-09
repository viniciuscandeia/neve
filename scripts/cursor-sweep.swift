// Moves the real cursor back and forth along horizontal segments for a while, then puts it back (scripts/perf.sh --sweep).
// Usage: cursor-sweep <secs> <x0,x1,y> [<x0,x1,y> ...]   (CoreGraphics coordinates: top-left origin, points)
// Peak speed ~600 pt/s with a small vertical wobble, so the cursor cuts through the snow sitting on each segment.
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
let t0 = Date()
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

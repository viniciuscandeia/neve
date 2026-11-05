import CoreGraphics
import Foundation

public func runSelfTest() {
    // CG -> AppKit
    let r = appKitFrame(fromCG: CGRect(x: 100, y: 50, width: 300, height: 200), primaryHeight: 900)
    precondition(r == CGRect(x: 100, y: 650, width: 300, height: 200), "coord conversion")

    // Pile
    var p = Pile(columns: 50, inset: 12)
    p.deposit(bin: 25, volume: 5)
    precondition(p.heights[25] > 0, "deposit increases height")
    for _ in 0..<5 { p.deposit(bin: 25, volume: 8) }
    precondition(p.heights[24] > 0 && p.heights[26] > 0, "relaxation spreads")
    for _ in 0..<300 { p.deposit(bin: 25, volume: 5) }
    precondition(p.heights.max()! <= Tuning.maxPileHeight + 0.001, "max height")

    // Surface map + knock-off
    let field = SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: 10)
    let dock = WindowInfo(number: 0, frame: CGRect(x: 500, y: 20, width: 400, height: 60), radius: 18)
    let back = WindowInfo(number: 1, frame: CGRect(x: 100, y: 200, width: 300, height: 200))
    let front = WindowInfo(number: 2, frame: CGRect(x: 200, y: 300, width: 300, height: 300))
    field.update(windows: [dock, front, back])
    precondition(!field.edgeVisible(id: 1, x: 300), "back edge hidden under front window")
    precondition(field.edgeVisible(id: 1, x: 150), "back edge visible elsewhere")
    precondition(field.edgeVisible(id: 2, x: 300), "front edge visible")
    precondition(field.edgeVisible(id: 0, x: 700), "dock visible")
    precondition(!field.edgeVisible(id: 0, x: 200), "no snow surface outside the dock bar")

    let idx = field.surfaces.firstIndex { $0.id == 1 }!
    let c0 = field.surfaces[idx].c0
    for _ in 0..<20 { field.deposit(surface: idx, bin: 150 / 2 - c0, volume: 4) }
    precondition(field.pile(id: 1)!.heights.max()! > 1, "pile built")
    let n = field.update(windows: [dock, front, WindowInfo(number: 1, frame: back.frame.offsetBy(dx: 400, dy: 0))], dt: 0.1)   // 4000 pt/s (2500 after smoothing): everything shakes off
    precondition(n > 0 && field.debris.count == n, "knock-off spawns debris")
    precondition(field.pile(id: 1)!.heights.max()! == 0, "knock-off clears pile")

    // Window disappears (minimize / close / hide): all its snow falls.
    field.clear()
    let idx2 = field.surfaces.firstIndex { $0.id == 1 }!
    for _ in 0..<20 { field.deposit(surface: idx2, bin: 10, volume: 4) }
    let m = field.update(windows: [dock, front])
    precondition(m > 0 && field.debris.count == m && field.pile(id: 1) == nil, "vanished window drops snow as debris")
    for _ in 0..<5 { field.step(dt: 0.01) }   // nothing below: debris must have gained gravity * t
    precondition(field.debris.count == m && field.debris.allSatisfy { $0.fall >= 0.9 * Tuning.debrisGravity * 0.05 }, "debris accelerates")

    // Space switch: piles dropped silently.
    let idx3 = field.surfaces.firstIndex { $0.id == 2 }!
    field.clear()
    for _ in 0..<20 { field.deposit(surface: idx3, bin: 40, volume: 4) }
    field.dropPiles()
    precondition(field.update(windows: []) == 0 && field.debris.isEmpty, "space switch makes no avalanche")

    // Rounded corner: baseline drops at the ends and snow slides off as debris.
    var p2 = Pile(columns: 100, inset: Tuning.cornerInset)
    p2.round(radius: 20, c0: 0, minX: 0, maxX: 200)
    precondition(p2.base[0] < -10 && p2.base[50] == 0, "baseline follows corner arc")
    for _ in 0..<200 { p2.deposit(bin: 1, volume: 5) }
    precondition(p2.spillL > 0, "snow slides off the corner")
    print("selftest ok")
}

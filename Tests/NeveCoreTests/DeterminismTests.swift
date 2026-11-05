import CoreGraphics
import Testing
@testable import NeveCore

/// No clock, no I/O: the same seed + the same steps / window updates (explicit dt) give the same world.
@Test func sameSeedSameInputsGiveIdenticalWorlds() {
    func world() -> SnowField {
        let f = makeField(flakes: 300, seed: 42)
        for i in 0..<600 {
            if i % 20 == 0 {
                let k = CGFloat(i / 20)
                f.update(windows: [win(1, 200 + 6 * k, 300, 400, 200), win(2, 700, 100 + 3 * k, 200, 150)], dt: 0.1)
            }
            if i == 300 { f.dropPiles() }
            f.step(dt: 1 / 60)
        }
        return f
    }
    let a = world(), b = world()
    #expect(a.surfaces.map(\.pile.heights) == b.surfaces.map(\.pile.heights))
    #expect(a.flakes.map(\.pos) == b.flakes.map(\.pos))
    #expect(a.debris.map(\.pos) == b.debris.map(\.pos))
    #expect(a.surfaces.map(\.pile.heights).joined().reduce(0, +) > 0)
}

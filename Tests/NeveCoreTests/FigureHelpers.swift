import CoreGraphics
import Testing
@testable import NeveCore

/// A resting 3-ball stack (radii 20 / 14 / 10) on surface `sid`; returns the bottom ball id.
@discardableResult
func stackBalls(_ f: SnowField, x: Float, on sid: Int = Tuning.groundID, radii: [Float] = [20, 14, 10]) -> Int {
    var parent: Int?
    var first = 0
    for (n, r) in radii.enumerated() {
        var b = Snowball(id: f.nextBallID, pos: SIMD2(x, 40 + Float(n) * 30), radius: r, surfaceID: sid)
        f.nextBallID += 1
        b.state = .resting; b.parent = parent; parent = b.id
        if n == 0 { first = b.id }
        f.balls.append(b)
    }
    return first
}

/// A finished user-built snowman (stack promoted to a figure); returns the figure id.
@discardableResult
func stand(_ f: SnowField, x: Float, on sid: Int = Tuning.groundID) -> Int {
    f.promote(bottomBall: stackBalls(f, x: x, on: sid))!
}

/// A complete auto snowman (as the builder makes it) standing at x; returns the figure id.
@discardableResult
func standAuto(_ f: SnowField, x: Float, on sid: Int = Tuning.groundID, built: Int = Snowman.stageCount) -> Int {
    let s = f.snowmanScale
    let id = f.addFigure(fromBalls: false, radii: SIMD3(11.5, 8.5, 6.5) * s, built: built, surface: sid, x: x)!
    f.figures[f.figureIndex(id)!].stageAge = 1
    return id
}

func fig(_ f: SnowField, _ id: Int) -> Figure { f.figures.first { $0.id == id }! }
func ball(_ f: SnowField, _ id: Int) -> Snowball { f.balls.first { $0.id == id }! }
func advance(_ f: SnowField, _ seconds: Float, fps: Float = 60) { for _ in 0..<Int(seconds * fps) { f.step(dt: 1 / fps) } }

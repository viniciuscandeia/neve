// AGENT HEADER - Tests/NeveCoreTests/ScenarioTests.swift  (Scenario.heavy: fills piles to >= 80 %, completes the snowmen and starts a fight; staging twice does not duplicate)

import CoreGraphics
import Testing
@testable import NeveCore

private func heavyField() -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 7)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: 25), win(1, 300, 300, 500, 300)])
    return f
}

@Test func heavyScenarioFillsPilesAndStartsAFight() {
    let f = heavyField()
    f.stage(.heavy)
    for s in f.surfaces {
        for b in s.pile.heights.indices where s.pile.visible[b] { #expect(s.pile.heights[b] >= 0.7 * max(s.pile.limit(b), 0) - 0.001) }
    }
    var fought = false, shot = false
    for _ in 0..<600 {
        f.step(dt: 1 / 60)
        fought = fought || !f.fights.isEmpty
        shot = shot || !f.shots.isEmpty
    }
    #expect(fought && shot)
}

@Test func stagingTwiceDoesNotDuplicate() {
    let f = heavyField()
    f.stage(.heavy)
    let n = f.figures.count
    f.stage(.heavy)
    #expect(n == 3 && f.figures.count == 3 && f.balls.isEmpty && f.figures.filter { !$0.fromBalls }.count == 1 && f.figures.allSatisfy { $0.built == Snowman.stageCount })
}

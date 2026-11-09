import CoreGraphics
import Testing
@testable import NeveCore

let sceneVF = CGRect(x: 0, y: 80, width: 1512, height: 790)

/// A 1512x900 screen playing the demo scene: windows follow `DemoScene.windows` at 60 Hz like the app's frame timer.
func demoField(seed: UInt64 = 7) -> SnowField {
    let f = SnowField(size: CGSize(width: 1512, height: 900), origin: .zero, groundY: 80, visibleTop: 870, flakeCount: 0, seed: seed)
    f.visitorsEnabled = true; f.sleighEnabled = true
    f.update(windows: demoWindows(0))
    f.beginScene(.demo)
    return f
}
func demoWindows(_ t: Float) -> [WindowInfo] { DemoScene.windows(in: sceneVF, t: t).enumerated().map { WindowInfo(number: $0.offset + 1, frame: $0.element.frame) } }

/// Steps the demo (windows following the script) until scene time `t`.
func demoRun(_ f: SnowField, to t: Float, peak: ((SnowField) -> Void)? = nil) {
    while (f.sceneTime ?? 0) < t {
        f.update(windows: demoWindows(f.sceneTime ?? 0), dt: 1 / 60)
        f.step(dt: 1 / 60)
        peak?(f)
    }
}

@Test func demoSceneRunsItsTimeline() {
    let f = demoField()
    #expect(f.figures.count == 1 && f.figures[0].fromBalls == false && f.figures[0].phase != .building)
    let ground = f.surfaces.first { $0.id == Tuning.groundID }!, top = f.surfaces.first { $0.id == 3 }!
    #expect(ground.pile.heights.max()! > 0 && top.pile.heights.filter { $0 > 0 }.count > 20)   // piles pre-filled
    demoRun(f, to: 5.9)
    #expect(f.figures.count == 1 && f.fights.isEmpty)
    demoRun(f, to: 8)                                           // a user snowman appears next to it: they fight
    #expect(f.figures.count >= 2 && f.fights.count == 1)
    demoRun(f, to: 12.9)
    let loser = f.figures.first { $0.headless }, winner = f.figures.first { $0.motion.cheer > 0 }
    #expect(loser != nil && winner != nil && loser!.id != winner!.id)   // head popped, winner cheers
    #expect(f.balls.contains { $0.parent == nil && $0.face != 0 })
    demoRun(f, to: 17.2)
    #expect(f.figures.allSatisfy { !$0.headless } && f.balls.isEmpty)   // re-stacked by script
    demoRun(f, to: 18.5)
    #expect(f.figures.contains { $0.kind == .robin && !$0.robin.flying })               // landed on the top window
    #expect(f.figures.contains { $0.kind == .snowman && !$0.carrot })                    // the rabbit has the carrot
    var avalanched = false, burst = 0
    demoRun(f, to: 21) { avalanched = avalanched || $0.avalancheActive }
    #expect(avalanched && f.chain.started == 1)
    demoRun(f, to: 25.8) { burst = max(burst, $0.debris.count) }   // Fotos slides away fast at 25 s
    #expect(burst > 6)   // wavy ceilings: the sliding window may carry a lower stretch of pile
    demoRun(f, to: 29.5)
    #expect(f.figures.contains { $0.kind == .sleigh } || !f.gifts.isEmpty)
    demoRun(f, to: 29.9)
    for _ in 0..<36 { f.update(windows: demoWindows(f.sceneTime ?? 0), dt: 1 / 60); f.step(dt: 1 / 60) }   // 0.6 s across the 30 s mark: loop, back to the start
    #expect((f.sceneTime ?? 99) < 0.8 && f.figures.count == 1 && f.balls.isEmpty && f.gifts.isEmpty, "t \(String(describing: f.sceneTime)) figs \(f.figures.map(\.kind)) balls \(f.balls.count) gifts \(f.gifts.count)")
}

@Test func demoSceneIsDeterministic() {
    func fingerprint() -> [Float] {
        let f = demoField()
        demoRun(f, to: 21)
        return f.figures.flatMap { [$0.foot.x, $0.foot.y] } + [Float(f.debris.count), Float(f.chain.started)]
    }
    #expect(fingerprint() == fingerprint())
}

@Test func sceneWindowFilterKeepsOnlyTheSceneWindows() {
    let raw = [RawWindow(number: 10, pid: 5, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 200)),   // Neve's own scene window
               RawWindow(number: 11, pid: 5, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 900)),   // Neve's overlay
               RawWindow(number: 12, pid: 99, layer: 0, bounds: CGRect(x: 0, y: 0, width: 300, height: 200))]   // someone else's app
    #expect(filterWindows(raw, exclude: [11], primaryHeight: 900).map(\.number) == [10, 12])   // own Ajustes window (10) kept, overlay (11) dropped
    #expect(filterWindows(raw, exclude: [11], primaryHeight: 900, scene: [10]).map(\.number) == [10])
}

func fightField(seed: UInt64 = 4) -> SnowField {
    let f = SnowField(size: CGSize(width: 1512, height: 900), origin: .zero, groundY: 80, visibleTop: 870, flakeCount: 0, seed: seed)
    f.update(windows: [])
    f.beginScene(.fight)
    return f
}
func fightRun(_ f: SnowField, to t: Float, _ each: ((SnowField) -> Void)? = nil) { while (f.sceneTime ?? 0) < t { f.step(dt: 1 / 60); each?(f) } }

@Test func fightSceneHasTwoSnowmen150ApartAndTheThirdHitAtT() {
    let f = fightField()
    #expect(f.figures.count == 2 && abs(abs(f.figures[0].foot.x - f.figures[1].foot.x) - 150) < 1)
    var popped: Float?
    fightRun(f, to: 6) { if popped == nil, $0.figures.contains(where: \.headless) { popped = $0.sceneTime } }
    #expect(popped != nil && abs(popped! - FightScene.fightT) < 0.02, "popped \(String(describing: popped))")
}

@Test func fightSceneCelebrationAndRestack() {
    let f = fightField()
    fightRun(f, to: FightScene.fightT + 0.3)
    let loser = f.figures.first { $0.headless }!, winner = f.figures.first { $0.id != loser.id }!
    #expect(winner.pose.flutter.up > 0.99)                                          // arms in a V
    #expect(loser.droop > 0.3)                                                      // loser's arms falling
    let head = f.balls.first { $0.parent == nil }!
    #expect(head.state == .falling && head.face != 0, "state \(head.state) face \(head.face) pos \(head.pos)")                             // head airborne, with its face
    fightRun(f, to: FightScene.fightT + 2.2)
    #expect(f.figures.first { $0.id == winner.id }!.pose.flutter.up == 0)            // arms lowered
    #expect(f.figures.first { $0.id == loser.id }!.droop > 0.99)
    // The script carries the head back at 7 s: the figure whole again, arms up in 0.3 s, then walking.
    var whole: Float?
    fightRun(f, to: 9) { if whole == nil, !$0.figures.contains(where: \.headless), $0.balls.isEmpty { whole = $0.sceneTime } }
    let w = whole!
    #expect(w > FightScene.restack)
    fightRun(f, to: w + 0.12)
    #expect(f.figures.first { $0.id == loser.id }!.droop < 0.7)
    fightRun(f, to: w + 0.35)
    #expect(f.figures.first { $0.id == loser.id }!.droop < 0.01)
    var walked = false
    fightRun(f, to: w + 6) { walked = walked || $0.figures.first { $0.id == loser.id }!.phase == .walking }
    #expect(walked)
}

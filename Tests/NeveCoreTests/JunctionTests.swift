import CoreGraphics
import Testing
@testable import NeveCore

// Overlapping windows whose tops are close: the two piles read as one snow mass (no vertical cut, no front corner shoulder drawn over the back snow).
// Back window 1: x 100...400, top 400. Front window 2 from x 300 (radius 22) overlaps its right part.
private func scene(frontTop: CGFloat, frontRounds: Int, mirrored: Bool = false) -> SnowField {   // mirrored: back x 300...600, front x 100...400 (its right end over the back)
    let f = makeField()
    f.update(windows: [win(2, mirrored ? 100 : 300, frontTop - 150, 300, 150), win(1, mirrored ? 300 : 100, 200, 300, 200)])
    pileUp(f, id: 1, rounds: 40)
    pileUp(f, id: 2, rounds: frontRounds)
    return f
}
/// Highest drawn top over x (nil: nothing drawn there).
private func topAt(_ s: [PileSeg], _ x: Float) -> Float? {
    s.filter { $0.x0 <= x && x <= $0.x1 }.map { $0.top0 + ($0.top1 - $0.top0) * (x - $0.x0) / max($0.x1 - $0.x0, 1e-3) }.max()
}
private func continuous(_ s: [PileSeg], _ a: Float, _ b: Float) -> String? {
    var prev: Float?
    for x in stride(from: a, through: b, by: 0.5) {
        guard let t = topAt(s, x) else { return "gap at \(x)" }
        if let p = prev, abs(t - p) > 1 { return "step \(t - p) at \(x)" }
        prev = t
    }
    return nil
}

@Test func backPileContinuesBehindALowerFrontTop() {
    // Case 1: the front top is 4pt above the back one, the front pile is almost bare, the back one full.
    for (rounds, mirrored) in [(1, false), (0, false), (1, true)] {
        let s = pileSegs(scene(frontTop: 404, frontRounds: rounds, mirrored: mirrored))
        let m = { (x: Float) in mirrored ? 700 - x : x }   // the same spots seen from the other side
        let c = continuous(s, min(m(270), m(380)), max(m(270), m(380)))
        #expect(c == nil, "rounds \(rounds) mirrored \(mirrored): \(c ?? "")")
        for x in stride(from: Float(300), through: 380, by: 4) { #expect((topAt(s, m(x)) ?? 0) > 410, "back snow above the front top at \(m(x))") }
        // What the front window covers stays hidden: nothing drawn below its top inside its straight part.
        let inner: ClosedRange<Float> = mirrored ? 122...378 : 322...578
        for g in s where inner.contains(g.x0) && inner.contains(g.x1) { #expect(min(g.base0, g.base1) >= 403 - 0.01, "drawn under the front top: \(g)") }
    }
}

@Test func equalTopsJoinWithoutTheFrontShoulder() {
    for (top, rounds, mirrored) in [(CGFloat(400), 40, false), (401, 40, false), (403, 40, false), (403, 6, false), (399, 40, false), (400, 40, true), (403, 40, true)] {
        let s = pileSegs(scene(frontTop: top, frontRounds: rounds, mirrored: mirrored))
        let a: Float = mirrored ? 340 : 270, b: Float = mirrored ? 430 : 360, j: ClosedRange<Float> = mirrored ? 370...410 : 290...330   // around the junction
        let c = continuous(s, a, b)
        #expect(c == nil, "top \(top) rounds \(rounds) mirrored \(mirrored): \(c ?? "")")
        // No crest inside the mass: every slice around the junction draws its top on the outline (the front corner's shoulder is not drawn over the back snow).
        for g in s where g.x1 >= j.lowerBound && g.x0 <= j.upperBound {
            for (x, t) in [(g.x0, g.top0), (g.x1, g.top1)] { #expect(t >= (topAt(s, x) ?? t) - 1, "top \(top) rounds \(rounds) mirrored \(mirrored): inner crest at \(x): \(t) vs \(topAt(s, x)!)") }
        }
    }
}

@Test func junctionSurvivesADrag() {
    let f = scene(frontTop: 404, frontRounds: 1)
    f.update(windows: [win(2, 330, 254, 300, 150), win(1, 100, 200, 300, 200)], dt: 0.5)   // front window dragged 30pt right
    pileUp(f, id: 1, rounds: 40)   // the uncovered strip fills up (it held no snow while hidden)
    let s = pileSegs(f)
    #expect(continuous(s, 300, 390) == nil, "\(continuous(s, 300, 390) ?? "")")
}

// On-screen report: a spike at the junction (front 4pt higher) and a 5-8pt vertical step (front 1pt lower, back crest higher). The crest crosses the
// front window's edge as one smooth curve: at most 1pt per bin (2pt) within 24pt of it, for front tops above and below the back one.
@Test func crestCrossesTheJunctionSmoothly() {
    for (top, rounds, mirrored) in [(CGFloat(404), 40, false), (404, 10, false), (399, 40, false), (399, 8, false), (397, 40, false), (394, 40, false), (404, 40, true), (399, 8, true)] {
        let s = pileSegs(scene(frontTop: top, frontRounds: rounds, mirrored: mirrored))
        let xj: Float = mirrored ? 400 : 300
        var prev: Float?
        for x in stride(from: xj - 24, through: xj + 24, by: 2) {
            guard let t = topAt(s, x) else { Issue.record("top \(top) rounds \(rounds) mirrored \(mirrored): gap at \(x)"); break }
            if let p = prev { #expect(abs(t - p) <= 1, "top \(top) rounds \(rounds) mirrored \(mirrored): crest step \(t - p) at \(x)") }
            prev = t
        }
    }
}

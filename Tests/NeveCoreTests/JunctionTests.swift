// AGENT HEADER - Tests/NeveCoreTests/JunctionTests.swift  (overlapping windows with close tops read as ONE snow mass)
// Back window 1 x 100...400 top 400, front window 2 overlapping it (also `mirrored`: front on the left). Checks on the Render.writePiles output (`pileSegs`): the back pile continues behind a lower front top and nothing is drawn under the front top, equal
//   tops join without the front shoulder, the junction survives a drag, the crest crosses it smoothly (<= 1 pt per 2 pt step within 24 pt and over the whole region where the crests differ: Contour.swift's slope limit). Phase 4 removed the
//   back snow continuing behind a lower front top and the tint-reference test (no more merged slices / flag 4). Related: SurfaceMap.computeSeams, Contour.swift.

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
/// x of the junction: the side edge of the HIGHER window (ties: window 1, the back one) lying inside the other, whatever the stacking order.
private func junctionX(frontTop: CGFloat, mirrored: Bool) -> Float {
    let frontHigher = frontTop > 400
    switch (frontHigher, mirrored) { case (true, false): return 300; case (true, true): return 400; case (false, false): return 400; case (false, true): return 300 }
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

// Front top 4pt above the back one, the front pile almost bare, the back one full. Phase 4: the back snow is NOT drawn over the front window's span any more (that span belongs to the front pile; before, `junctions` merged the back crest
// into the front slices and drew it continuing behind the lower front top). The back crest meets the front snow: where the front has snow the contour crosses the wall in a ramp (<= 1pt per 2pt), where it is bare the back snow ends at the wall.
@Test func backCrestMeetsAYoungFrontPileAtTheWall() {
    for (rounds, mirrored) in [(1, false), (0, false), (1, true)] {
        let f = scene(frontTop: 404, frontRounds: rounds, mirrored: mirrored), s = pileSegs(f)
        let m = { (x: Float) in mirrored ? 700 - x : x }   // the same spots seen from the other side
        if rounds > 0 {
            let c = continuous(s, min(m(270), m(330)), max(m(270), m(330)))
            #expect(c == nil, "rounds \(rounds) mirrored \(mirrored): \(c ?? "")")
        }
        #expect((topAt(s, m(285)) ?? 0) > 410, "back snow beside the wall")
        // What the front window covers stays hidden: every slice point inside its straight part is clipped by the front occluder (z 0) (the back snow only lies beside it).
        let o = f.occluders[0]
        for g in s where g.z == 1 {
            for u in stride(from: Float(0), through: 1, by: 0.5) {
                let x = g.x0 + (g.x1 - g.x0) * u, top = g.top0 + (g.top1 - g.top0) * u, base = g.base0 + (g.base1 - g.base0) * u
                guard x > o.rect.x + 0.5, x < o.rect.z - 0.5 else { continue }
                for y in stride(from: base, through: min(top, o.rect.w - o.radius - 0.5), by: 1) { #expect(o.hides(x: x, y: y), "back snow visible at \(x),\(y)") }
            }
        }
    }
}

@Test func equalTopsJoinWithoutTheFrontShoulder() {
    for (top, rounds, mirrored) in [(CGFloat(400), 40, false), (401, 40, false), (403, 40, false), (403, 6, false), (399, 40, false), (400, 40, true), (403, 40, true)] {
        let s = pileSegs(scene(frontTop: top, frontRounds: rounds, mirrored: mirrored))
        let xj = junctionX(frontTop: top, mirrored: mirrored), a = xj - 40, b = xj + 60, j = (xj - 30)...(xj + 30)   // around the junction
        let c = continuous(s, a, b)
        #expect(c == nil, "top \(top) rounds \(rounds) mirrored \(mirrored): \(c ?? "")")
        // No crest inside the mass: every slice around the junction draws its top on the outline (the front corner's shoulder is not drawn over the back snow).
        for g in s where g.x1 >= j.lowerBound && g.x0 <= j.upperBound {
            for (x, t) in [(g.x0, g.top0), (g.x1, g.top1)] {
                // a lower window's own corner snow buried inside the mass (covered by a slice reaching above it) is no crest
                let buried = s.contains { $0.x0 <= x && x <= $0.x1 && $0.base0 <= t && $0.base1 <= t && min($0.top0, $0.top1) > t + 1 }
                #expect(buried || t >= (topAt(s, x) ?? t) - 1, "top \(top) rounds \(rounds) mirrored \(mirrored): inner crest at \(x): \(t) vs \(topAt(s, x)!)") }
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
        let xj = junctionX(frontTop: top, mirrored: mirrored)
        var prev: Float?
        for x in stride(from: xj - 24, through: xj + 24, by: 2) {
            guard let t = topAt(s, x) else { Issue.record("top \(top) rounds \(rounds) mirrored \(mirrored): gap at \(x)"); break }
            if let p = prev { #expect(abs(t - p) <= 1, "top \(top) rounds \(rounds) mirrored \(mirrored): crest step \(t - p) at \(x)") }
            prev = t
        }
    }
}

@Test func crestSlopeBoundedWhereCrestsDiffer() {
    for (top, rounds, mirrored) in [(CGFloat(404), 40, false), (404, 10, false), (399, 40, false), (399, 8, false), (397, 40, false), (397, 8, false), (394, 40, false), (394, 8, false), (404, 40, true), (399, 8, true), (397, 40, true), (394, 8, true)] {
        let s = pileSegs(scene(frontTop: top, frontRounds: rounds, mirrored: mirrored))
        let xj = junctionX(frontTop: top, mirrored: mirrored)
        var prev: Float?
        let reach = max(16, 6 * abs(Float(400 - top))) + 8   // blend half-width + margin
        for x in stride(from: xj - reach, through: xj + reach, by: 2) {
            guard let t = topAt(s, x) else { Issue.record("top \(top) rounds \(rounds) mirrored \(mirrored): gap at \(x)"); break }
            if let p = prev { #expect(abs(t - p) <= 1, "top \(top) rounds \(rounds) mirrored \(mirrored): crest step \(t - p) at \(x - xj)") }
            prev = t
        }
    }
}

// Review M2/L1: a pushed heap 30 pt from an overlap junction keeps its height in the drawing (the blend window is capped and never lowers a heap).
@Test func aTallHeapNearAJunctionKeepsItsHeight() {
    let f = scene(frontTop: 404, frontRounds: 40)
    let si = f.index[1]!   // heap centre: global x 270 (30 pt left of the junction at 300)
    let b = Int(270 / Tuning.binWidth) - f.surfaces[si].c0
    f.surfaces[si].pile.mound = [Float](repeating: 0, count: f.surfaces[si].pile.heights.count)
    for k in (b - 6)...(b + 6) { f.surfaces[si].pile.heights[k] = 100; f.surfaces[si].pile.mound[k] = 100 }
    f.pilesDirty = true
    let top = topAt(pileSegs(f), 270) ?? 0
    #expect(top - f.surfaces[si].edgeY >= 95, "heap drawn at \(top - f.surfaces[si].edgeY) of 100")
}

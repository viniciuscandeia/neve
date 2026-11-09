import CoreGraphics
import Foundation
import Testing
@testable import NeveCore

// Field 1000x800 at origin (0,0): ground (dock top) at y=90, menu-bar area starts at y=780.
func makeField(flakes: Int = 0, seed: UInt64 = 1) -> SnowField {
    SnowField(size: CGSize(width: 1000, height: 800), origin: .zero, groundY: 90, visibleTop: 780, flakeCount: flakes, seed: seed)
}

func win(_ n: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> WindowInfo {
    WindowInfo(number: n, frame: CGRect(x: x, y: y, width: w, height: h))
}

/// Builds window `id`'s pile directly (no snowfall): `rounds` deposits in every bin; hidden / roofed columns take none.
func pileUp(_ f: SnowField, id: Int, rounds: Int = 12, volume: Float = 4) {
    let i = f.surfaces.firstIndex { $0.id == id }!
    for _ in 0..<rounds { for b in f.surfaces[i].pile.heights.indices { f.deposit(surface: i, bin: b, volume: volume) } }
}

/// Integration helper: steps a snowing field until window `id` carries a pile at least `height` tall.
@discardableResult
func snowUntilPiled(_ f: SnowField, id: Int, height: Float = 8) -> Bool {
    for _ in 0..<6000 {
        f.step(dt: 1 / 60)
        if (f.pile(id: id)?.heights.max() ?? 0) >= height { return true }
    }
    return false
}

// Back window top edge y=400 (x 100...400); front window covers x 200...500, y 300...600.
let back = win(1, 100, 200, 300, 200)
let front = win(2, 200, 300, 300, 300)

@Test func frontWindowHidesBackWindowEdgeOnlyWhereTheyOverlap() {
    let f = makeField()
    f.update(windows: [front, back])
    #expect(!f.edgeVisible(id: 1, x: 300))   // under the front window
    #expect(f.edgeVisible(id: 1, x: 150))    // left of it
    #expect(f.edgeVisible(id: 2, x: 300))    // the front window's own edge is never hidden
}

@Test func windowListOrderDecidesWhoIsInFront() {
    let f = makeField()
    f.update(windows: [back, front])   // back now in front, and its rect does not reach y=601
    #expect(f.edgeVisible(id: 2, x: 300))
    #expect(f.edgeVisible(id: 1, x: 300))
}

@Test func windowWiderThanScreenIsClippedToScreen() {
    let f = makeField()
    f.update(windows: [win(1, -100, 200, 300, 200), win(2, 900, 200, 300, 200)])
    // x -100...200 shows 0...200 = 100 bins of 2pt; x 900...1200 shows 900...1000 = 50 bins.
    #expect(f.pile(id: 1)?.heights.count == 100)
    #expect(f.pile(id: 2)?.heights.count == 50)
    #expect(f.edgeVisible(id: 1, x: 5))
    #expect(f.edgeVisible(id: 2, x: 995))
}

@Test func windowEntirelyOffScreenGetsNoSurface() {
    let f = makeField()
    f.update(windows: [win(1, 1100, 200, 300, 200), win(2, -400, 200, 300, 200)])
    #expect(f.pile(id: 1) == nil)
    #expect(f.pile(id: 2) == nil)
}

@Test func edgeInMenuBarAreaGetsNoSurface() {
    let f = makeField()
    f.update(windows: [win(1, 100, 500, 300, 290), win(2, 500, 500, 300, 240)])   // tops at 790 and 740
    #expect(f.pile(id: 1) == nil)
    #expect(f.pile(id: 2) != nil)
}

@Test func windowTopAtOrBelowGroundGetsNoSurface() {
    let f = makeField()
    f.update(windows: [win(1, 100, 20, 300, 70)])   // top at 90 = ground
    #expect(f.pile(id: 1) == nil)
}

@Test func dockSurfaceExistsOnlyOverTheDockBar() {
    let f = makeField()
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 500, y: 20, width: 400, height: 60), radius: 18)])
    #expect(f.edgeVisible(id: 0, x: 700))
    #expect(!f.edgeVisible(id: 0, x: 200))
    #expect(!f.edgeVisible(id: 0, x: 950))
}

@Test func offscreenHiddenDockGetsNoSurface() {
    let f = makeField()
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 500, y: -60, width: 400, height: 60), radius: 18)])
    #expect(f.pile(id: 0) == nil)
}

/// Lone window 1 (x 100...400, top y=400) with a deterministic pile: 12 deposits in every bin.
func pileOnLoneWindow(_ f: SnowField, width: CGFloat = 300) {
    f.update(windows: [win(1, 100, 200, width, 200)])
    for b in 0..<f.surfaces[0].pile.heights.count { for _ in 0..<12 { f.deposit(surface: 0, bin: b, volume: 4) } }
}
func total(_ f: SnowField, id: Int = 1) -> Float { f.pile(id: id)!.heights.reduce(0, +) }

@Test func slowMoveCarriesThePileAlongWithoutShedding() {
    let f = makeField()
    pileOnLoneWindow(f)
    let old = f.pile(id: 1)!.heights, spilled = f.debris.count   // deposits at the rounded ends already spilled some
    #expect(old.max()! > 10)
    // +60 pt in 0.2 s = 300 pt/s < 400: nothing falls; 60 pt = 30 bins, so new bin b holds old bin b.
    #expect(f.update(windows: [win(1, 160, 200, 300, 200)], dt: 0.2) == 0)
    #expect(f.debris.count == spilled)
    #expect(zip(f.pile(id: 1)!.heights, old).dropFirst(3).dropLast(3).allSatisfy { abs($0 - $1) < 0.01 })   // ends are re-tapered
    #expect(f.pile(id: 1)!.c0 == 80)               // pile now sits over x 160...460
    #expect(f.edgeVisible(id: 1, x: 300) && !f.edgeVisible(id: 1, x: 120))
    #expect(f.draggingID == 1)
    f.update(windows: [win(1, 160, 200, 300, 200)])   // window rests: drag ends
    #expect(f.draggingID == nil)
}

@Test func veryFastMoveShedsMostOfThePileAsDebris() {
    let f = makeField()
    pileOnLoneWindow(f)
    let before = total(f), spilled = f.debris.count
    // +100 pt in 0.05 s = 2000 pt/s, but velocity is smoothed from rest over ~0.1 s (60% of raw here): ~1200 pt/s is not enough.
    // +200 pt in 0.1 s: 2000 pt/s raw, 63% -> 1260; use +400 pt (4000 raw, 2500 smoothed): everything falls.
    let n = f.update(windows: [win(1, 500, 200, 300, 200)], dt: 0.1)
    #expect(n > 0 && f.debris.count == spilled + n)
    #expect(total(f) < 0.2 * before)
    // (no residue check: the sub-0.5pt smear the old relax left at the ends is gone, bare edges now hold no snow below the speck floor)
}

@Test func shedFractionGrowsWithSpeedDirectionAndShakes() {
    let z = SIMD2<Float>.zero
    #expect(SnowField.shedFraction(v: [300, 0], prev: z) == 0)
    #expect(SnowField.shedFraction(v: [400, 0], prev: z) == 0)
    #expect(SnowField.shedFraction(v: [2500, 0], prev: z) == 1)
    let mid = SnowField.shedFraction(v: [1450, 0], prev: z)
    #expect(abs(mid - 0.5) < 0.01)
    let up = SnowField.shedFraction(v: [0, 1500], prev: z)
    let side = SnowField.shedFraction(v: [1500, 0], prev: z)
    let down = SnowField.shedFraction(v: [0, -1500], prev: z)
    #expect(up < side && side < down)
    // 600 pt/s sheds nothing on its own, but reversing 600 -> -600 is a 1200 pt/s jolt.
    #expect(SnowField.shedFraction(v: [-600, 0], prev: z) < 0.05)
    #expect(SnowField.shedFraction(v: [-600, 0], prev: [600, 0]) > SnowField.shedFraction(v: [-600, 0], prev: [-600, 0]))
}

@Test func resizingNarrowerKeepsThePileAndDropsOnlyTheOverhang() {
    let f = makeField()
    pileOnLoneWindow(f)
    let old = f.pile(id: 1)!.heights, spilled = f.debris.count
    let n = f.update(windows: [win(1, 100, 200, 200, 200)], dt: 0.1)   // right edge 400 -> 300
    #expect(f.pile(id: 1)!.heights.count == 100)
    #expect(zip(f.pile(id: 1)!.heights[3..<90], old[3..<90]).allSatisfy { abs($0 - $1) < 0.01 })   // left part (clear of the new right taper) untouched
    #expect(n > 0 && f.debris.count == spilled + n)
    #expect(f.debris[spilled...].allSatisfy { $0.pos.x >= 296 })          // only snow from x 300...400 falls
    #expect(f.draggingID == nil)
    // Widening again starts the new part empty.
    f.update(windows: [win(1, 100, 200, 300, 200)], dt: 0.1)
    #expect(f.pile(id: 1)!.heights[110...].allSatisfy { $0 == 0 })
}

@Test func unchangedWindowKeepsItsPileAndSpawnsNothing() {
    let f = makeField()
    f.update(windows: [front, back])
    pileUp(f, id: 1)
    let before = f.debris.count
    let tall = f.pile(id: 1)!.heights.max()!
    #expect(f.update(windows: [front, back, win(3, 600, 200, 100, 100)]) == 0)   // another window appears
    #expect(f.debris.count == before)
    #expect(f.pile(id: 1)!.heights.max()! == tall)
}

@Test func changingBoundsInPlaceKeepsPilesAndMovesCutoffs() {
    let f = makeField()
    f.update(windows: [front, back])
    pileUp(f, id: 1)
    let tall = f.pile(id: 1)!.heights.max()!
    f.setBounds(groundY: 90, visibleTop: 780)   // no-op
    f.setBounds(groundY: 60, visibleTop: 750)   // menu bar grew, Dock shrank
    #expect(f.update(windows: [front, back]) == 0)
    #expect(f.pile(id: 1)!.heights.max()! == tall)
    #expect(f.pile(id: 2) != nil)
    f.setBounds(groundY: 90, visibleTop: 550)   // front window's top (y=600) now in the menu-bar area
    f.update(windows: [front, back])
    #expect(f.pile(id: 2) == nil)
    #expect(f.pile(id: 1)!.heights.max()! == tall)
    f.setBounds(groundY: 450, visibleTop: 780)  // back window's top (y=400) now below ground
    f.update(windows: [front, back])
    #expect(f.pile(id: 1) == nil)
}

@Test func vanishedWindowDropsItsSnowAsDebrisAndLosesItsSurface() {
    let f = makeField()
    f.update(windows: [front, back])
    pileUp(f, id: 1)
    let before = f.debris.count
    let n = f.update(windows: [front])
    #expect(n > 0)
    #expect(f.debris.count == before + n)
    #expect(f.pile(id: 1) == nil)
}

@Test func spaceSwitchDropsPilesWithoutDebris() {
    let f = makeField()
    f.update(windows: [front, back])
    pileUp(f, id: 1)
    f.dropPiles()
    #expect(f.pile(id: 1)!.heights.max()! == 0)
    pileUp(f, id: 1, rounds: 2)   // snow keeps landing on the not-yet-removed windows
    #expect(f.pile(id: 1)!.heights.max()! > 0.5)
    let before = f.debris.count
    #expect(f.update(windows: []) == 0)   // windows vanish in the same switch: no avalanche
    #expect(f.debris.count == before)
}

// MARK: - Review fixes

// Back window top edge y=400 (x 100...400); the front window starts at y=410, only 10 pt above it,
// and covers x 200...500. Point y=401 is free, so the edge counts as visible under the front window.
@Test func pileCannotGrowIntoAFrontWindowThatStartsJustAboveTheEdge() {
    let f = makeField()
    f.update(windows: [win(2, 200, 410, 300, 290), win(1, 100, 200, 300, 200)])
    // Bin b centre x = 101 + 2b: bins 0...49 are left of the front window, 50...149 under it.
    pileUp(f, id: 1, rounds: 40)
    let free = f.pile(id: 1)!.heights[0..<45].max()!
    #expect(free >= 14)   // the open part really grew tall, so the cap below is what limits the rest
    let under = f.pile(id: 1)!.heights[50..<150]
    #expect(under.max()! <= 10.001)
}

@Test func windowOverTheScreenEdgeGetsNoArtificialTaperThere() {
    let f = makeField()
    f.update(windows: [win(1, 800, 200, 400, 200), win(2, 600, 200, 400, 200)])   // 1 crosses the right edge, 2 ends on it
    for s in f.surfaces.indices { for _ in 0..<60 { f.deposit(surface: s, bin: f.surfaces[s].pile.heights.count - 1, volume: 4) } }
    #expect(f.pile(id: 1)!.heights.last! >= 0.85 * f.pile(id: 1)!.limit(f.pile(id: 1)!.heights.count - 1))    // snow piles to full height right at the screen edge
    #expect(f.pile(id: 2)!.heights.last! < 5)      // a real end still tapers
}

@Test(arguments: 1...12 as ClosedRange<UInt64>)
func debrisCountIsTruthfulAtThePoolLimit(seed: UInt64) {
    // A pile worth ~2600 debris knocked off into a 1200 pool: the cap is hit mid-clump for some seeds.
    let f = makeField(seed: seed)
    f.update(windows: [win(1, 0, 200, 1000, 200)])
    for b in 30..<470 { for _ in 0..<10 { f.deposit(surface: 0, bin: b, volume: 4) } }
    for _ in 0..<(Tuning.maxDebris - 40) { f.addDebris(x: 5, y: 700, vx: 0, fall: 0) }   // slabs are few: nearly fill the pool first
    let before = f.debris.count
    let n = f.update(windows: [win(1, 400, 200, 1000, 200)], dt: 0.1)   // 4000 pt/s (velocity is smoothed over ~0.1 s)
    #expect(f.debris.count == Tuning.maxDebris)
    #expect(n == f.debris.count - before)
    // Pool already full: a second avalanche reports nothing.
    for b in 30..<470 { for _ in 0..<10 { f.deposit(surface: 0, bin: b, volume: 4) } }
    #expect(f.update(windows: [win(1, 800, 200, 1000, 200)], dt: 0.1) == 0)
}

@Test func windowTopWithoutHeadroomBelowMenuBarGetsNoSurface() {
    let f = makeField()   // visibleTop 780
    f.update(windows: [win(1, 100, 575, 300, 200), win(2, 500, 540, 300, 200)])   // tops 775 (5pt) and 740 (40pt)
    #expect(f.pile(id: 1) == nil)
    #expect(f.pile(id: 2) != nil)
}

@Test func columnUnderFrontWindowWithTwoPointsClearanceGetsNoDeposit() {
    var p = Pile(columns: 50, inset: 0)
    for b in 20..<30 { p.cap[b] = 2 }
    let first = p.deposit(bin: 25, volume: 5)
    #expect(!first)
    #expect(p.heights.allSatisfy { $0 == 0 })
    p.cap[25] = 10
    let second = p.deposit(bin: 25, volume: 5)
    #expect(second)
}

@Test func heightsNeverExceedLimitAfterManyDepositsNearAnEnd() {
    var p = Pile(columns: 100, inset: Tuning.cornerInset, c0: 0, x0: 0, x1: 200)
    for n in 0..<400 { p.deposit(bin: 3 + n % 4, volume: 3); p.deposit(bin: 96 - n % 4, volume: 3) }
    for b in p.heights.indices { #expect(p.heights[b] <= p.limit(b) + 1e-4) }
}

@Test func knockedOffSnowAppearsAtFullAlphaImmediately() {
    let f = makeField()
    f.update(windows: [front, back])
    pileUp(f, id: 1)
    let n = f.update(windows: [front])
    #expect(n > 0)
    let b = UnsafeMutablePointer<Instance>.allocate(capacity: f.capacity); defer { b.deallocate() }
    let total = f.writeInstances(to: b)
    for k in (total - n)..<total { #expect(b[k].alpha == 0.95) }
}

// MARK: - Ground (screen bottom)

@Test func groundExistsWithNoWindowsAndCollectsSnow() {
    let f = makeField(flakes: 900)
    #expect(f.pile(id: Tuning.groundID) != nil)
    #expect(snowUntilPiled(f, id: Tuning.groundID, height: 6))
    #expect(f.pile(id: Tuning.groundID)!.heights.max()! <= Tuning.groundMaxHeight)
}

@Test func groundUnderDockBarFillsUpToItsBottomEdgeAndDockPileStays() {
    let f = makeField()
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 400, y: 10, width: 200, height: 70), radius: 18)])
    pileUp(f, id: 0)
    pileUp(f, id: Tuning.groundID)
    #expect(f.pile(id: 0)!.heights.max()! > 4)
    let g = f.pile(id: Tuning.groundID)!
    for b in 210..<290 { #expect(g.visible[b]); #expect(g.heights[b] > 0 && g.heights[b] <= 10 + 1e-4) }
    #expect(g.heights[10] > 4)
}

@Test func coveredGroundColumnsKeepSnowHiddenAndShowItAgain() {
    let f = makeField()
    for b in 0..<500 { for _ in 0..<12 { f.deposit(surface: 0, bin: b, volume: 4) } }
    let h = f.pile(id: Tuning.groundID)!.heights[250]
    #expect(h > 5)
    f.update(windows: [win(7, 400, 0, 200, 70)])
    #expect(!f.pile(id: Tuning.groundID)!.visible[250])
    #expect(f.pile(id: Tuning.groundID)!.heights[250] == h)
    f.update(windows: [])
    #expect(f.pile(id: Tuning.groundID)!.visible[250])
    #expect(f.pile(id: Tuning.groundID)!.heights[250] == h)
}

@Test func groundSurvivesSpaceSwitchDropButWindowsDoNot() {
    let f = makeField()
    f.update(windows: [back])
    pileUp(f, id: Tuning.groundID)
    pileUp(f, id: 1)
    f.dropPiles()
    #expect(f.pile(id: 1)!.heights.max()! == 0)
    #expect(f.pile(id: Tuning.groundID)!.heights.max()! >= 4)
}

@Test func clearEmptiesGround() {
    let f = makeField()
    pileUp(f, id: Tuning.groundID)
    #expect(f.pile(id: Tuning.groundID)!.heights.max()! > 4)
    f.clear()
    #expect(f.pile(id: Tuning.groundID)!.heights.max()! == 0)
}

// MARK: - Ground snowbank beside a bottom Dock bar (1440x900, Dock (171,10,1098,84): dockTop 94, groundY 90)

private func bankField() -> SnowField {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 90, visibleTop: 880, flakeCount: 0, seed: 1)
    f.update(windows: [dockBar])
    fillBankLevel(f)   // a fully grown bank (the level rises with snowfall: see DockPushTests)
    return f
}
/// Jumps the ground bank's ramp level to its maximum: a level shelf flush with the Dock top across the gap.
func fillBankLevel(_ f: SnowField) {
    f.bankLevel = (1000, 1000)
    if let i = f.surfaces.firstIndex(where: { $0.id == Tuning.groundID }), let d = f.surfaces.first(where: { $0.id == 0 }) { f.surfaces[i].pile.maxes = f.bankMaxes([d.frame]) }
}
private let dockBar = WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: 25.2)   // the app's 0.3 * height

/// Piles a surface up to its limit (400 rounds of deposits over every bin: ~300k relaxations, slow in a debug build). The result depends only on
/// the pile it starts from, so it is computed once per distinct starting pile and process and copied into later fields.
private func heavy(_ f: SnowField, id: Int) {
    let i = f.surfaces.firstIndex { $0.id == id }!
    let p = f.surfaces[i].pile
    var h = Hasher()
    h.combine(p.heights); h.combine(p.visible); h.combine(p.base); h.combine(p.cap); h.combine(p.maxes); h.combine(p.boost)
    h.combine(p.c0); h.combine(p.x0); h.combine(p.x1); h.combine(p.maxHeight); h.combine(p.supportL); h.combine(p.supportR)
    let key = h.finalize()
    if let done = heavyCache.get(key) { f.surfaces[i].pile = done; f.pilesDirty = true; return }
    for _ in 0..<400 { for b in f.surfaces[i].pile.heights.indices { f.deposit(surface: i, bin: b, volume: 4) } }
    heavyCache.set(key, f.surfaces[i].pile)
}
private let heavyCache = HeavyCache()
private final class HeavyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var piles: [Int: Pile] = [:]
    func get(_ k: Int) -> Pile? { lock.lock(); defer { lock.unlock() }; return piles[k] }
    func set(_ k: Int, _ p: Pile) { lock.lock(); piles[k] = p; lock.unlock() }
}

@Test func groundBankRisesToDockTopNextToTheBarAndFillsUnderIt() {
    let f = bankField()
    heavy(f, id: Tuning.groundID)
    let g = f.pile(id: Tuning.groundID)!
    #expect(g.heights[84] >= 94 - 2 && g.heights[84] <= 94.01)    // x 169, left of the bar: reaches the Dock top (94)
    #expect(g.heights[635] >= 94 - 2 && g.heights[635] <= 94.01)  // x 1269, right of the bar
    #expect(g.heights[5] <= 94.01)   // screen edge, 160pt from the bar: the shelf is flush with the Dock top
    for b in 85..<634 { #expect(g.visible[b] && g.heights[b] <= barBottom(x: Float(b) * 2 + 1) + 1e-3) }   // never inside the bar's rounded silhouette
    #expect(g.heights[300] > 5)                              // snow fills the gap under the bar
}

@Test func groundBankNoDockKeepsTheOldMaximum() {
    let f = makeField()
    f.update(windows: [])
    heavy(f, id: Tuning.groundID)
    #expect(f.pile(id: Tuning.groundID)!.heights.max()! <= Tuning.groundMaxHeight)
}

@Test func snowBesideTheDockSpreadsUnderTheBarWithoutLoss() {
    let f = bankField()
    let i = f.surfaces.firstIndex { $0.id == Tuning.groundID }!
    for b in 70..<85 { f.surfaces[i].pile.heights[b] = 20 }
    let before = f.pile(id: Tuning.groundID)!.heights.reduce(0, +)
    for _ in 0..<300 { f.deposit(surface: i, bin: 80, volume: 0.001) }
    let g = f.pile(id: Tuning.groundID)!
    #expect(abs(g.heights.reduce(0, +) - before) < 1)
    #expect(g.heights[86...88].allSatisfy { $0 > 0 && $0 <= 35.3 - Tuning.barMargin })
}

@Test func groundBankLimitSlopesDownFromTheDock() {
    let p = bankField().pile(id: Tuning.groundID)!
    #expect(abs(p.limit(84) - 94) < 3)               // the Dock top at the bar end
    #expect(p.limit(0) >= Tuning.groundMaxHeight)      // the soft tail
    for b in 1..<80 { #expect(p.limit(b - 1) <= p.limit(b) + 1e-4) }   // monotone up to the bar end
    #expect(abs(p.limit(0) - 94) < 0.01)               // grown bank: a level shelf across the 171pt gap, flush with the Dock top
    for b in 1..<85 { #expect(p.limit(b) - p.limit(b - 1) <= Tuning.slope + 1e-3) }
}

@Test func groundAndDockPilesMergeIntoOneBankContourWhereTheyMeet() {
    let f = SnowField(size: CGSize(width: 1440, height: 900), origin: .zero, groundY: 94, visibleTop: 880, flakeCount: 0, seed: 1)
    f.update(windows: [WindowInfo(number: 0, frame: CGRect(x: 171, y: 10, width: 1098, height: 84), radius: 0)])
    heavy(f, id: Tuning.groundID)
    heavy(f, id: 0)
    // Contiguous chains of segments (end of one = start of the next, within 1pt): bank + Dock + bank are one, plus the under-bar run.
    let segs = pileSegs(f).sorted { $0.x0 < $1.x0 }
    var chains = 0, end = -Float.infinity
    for g in segs { if g.x0 - end > 1 { chains += 1 }; end = max(end, g.x1) }
    #expect(chains <= 2)
}

@Test func dockShrinkingShedsGroundSnowAsDebrisNotSilently() {
    let f = bankField()
    heavy(f, id: Tuning.groundID)
    var n = f.update(windows: [win(0, 600, 10, 240, 84)])   // the ends travel there at Tuning.dockSpeed: the shed happens along the way
    for _ in 0..<60 { f.step(dt: 1 / 60); n += f.debris.count }
    #expect(n > 0)
}

// MARK: - Stability (the bank must not reshape by itself)

@Test func repeatedIdenticalUpdatesKeepTheBankIdentical() {
    let f = bankField()
    heavy(f, id: Tuning.groundID)
    let h = f.pile(id: Tuning.groundID)!.heights
    for _ in 0..<5 { f.update(windows: [dockBar]); f.boundsDirty = true }
    #expect(f.pile(id: Tuning.groundID)!.heights == h)
}

@Test func dockDebounceIgnoresJitterAndTransientMisses() {
    var d = DockDebounce()
    let r = CGRect(x: 171, y: 10, width: 1098, height: 76)
    #expect(d.feed(r).changed && d.frame == r)
    #expect(!d.feed(r.offsetBy(dx: 1, dy: 1.5)).changed && d.frame == r)       // jitter
    for _ in 0..<3 { let x = d.feed(nil); #expect(!x.changed && x.retry && d.frame == r) }   // grace
    #expect(!d.feed(r).changed)                                                  // a good read resets the count
    for _ in 0..<3 { _ = d.feed(nil) }
    let gone = d.feed(nil)
    #expect(gone.changed && d.frame == nil)                                      // really gone
    #expect(d.feed(r.insetBy(dx: -20, dy: 0)).changed)
}

@Test func noGroundContourInsideTheDockBarRect() {
    let f = bankField()
    heavy(f, id: Tuning.groundID)
    for g in pileSegs(f) where g.base0 < 1 && g.x0 >= 172 && g.x1 <= 1268 { #expect(max(g.top0, g.top1) <= 10 + 25.2 + 1e-3) }
}

/// Bottom of the bar's rounded silhouette at x (inf outside it).
private func barBottom(x: Float) -> Float { Tuning.barUnderside(x: x, minX: 171, maxX: 1269, minY: 10, radius: 25.2) ?? .infinity }

@Test func underBarGroundContourFollowsTheRoundedUndersideAndTheBankRisesBesideIt() {
    let f = bankField()
    heavy(f, id: Tuning.groundID)
    var pts: [(x: Float, y: Float)] = []
    for g in pileSegs(f) where g.base0 < 1 && g.x0 >= 172 && g.x1 <= 1268 {   // under the bar, off the 2pt bins of the bar's end walls
        for k in 0...8 { let t = Float(k) / 8; pts.append((g.x0 + (g.x1 - g.x0) * t, g.top0 + (g.top1 - g.top0) * t)) }
    }
    #expect(!pts.isEmpty)
    for p in pts { #expect(p.y <= barBottom(x: p.x) + 0.3, "contour (\(p.x), \(p.y)) inside the bar") }
    #expect(pileSegs(f).filter { $0.x1 < 171 && $0.base0 < 1 }.map { max($0.top0, $0.top1) }.max()! > 94 - 3.5)   // the bank beside the end reaches the Dock top
}

@Test func dockGlassMapsFromTheAXListFrame() {
    // Measured: AX list y 806..890 (CG), visible glass y 811..895 on a 900pt screen -> AppKit y 5..89, snow base (maxY) 89.
    let ax = CGRect(x: 171, y: 806, width: 1098, height: 84)
    let g = appKitFrame(fromCG: Tuning.dockGlass(fromAX: ax), primaryHeight: 900)
    #expect(g == CGRect(x: 171, y: 5, width: 1098, height: 84))
}

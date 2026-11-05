import NeveCore
import AppKit
import QuartzCore

/// Layers for the snowballs the user rolls and for the snowmen made of them (`Figure`s with fromBalls): a pool of ball
/// groups (drawn once at radius 20, scaled per ball) and one accessory set per figure. Rebuilt from state only when the
/// field's `ballsVersion` / `figuresVersion` changes (this renderer goes away with the Metal rig).
@MainActor
final class BallLayers {
    let root = CALayer()
    private static let big: CGFloat = 20   // radius the shared paths are drawn at
    private struct Group { let layer: CALayer, speckles: CALayer, body: CAShapeLayer }
    private struct Accessories { let arms: CAShapeLayer, mid: CAShapeLayer, head: CAShapeLayer, armLR: [CAShapeLayer], tails: [CAShapeLayer] }
    private var groups: [Group] = []
    private var sets: [Accessories] = []
    private var shown = -1, shownFigs = -1, keys: [Int] = [], shownPoses: [Flutter] = [], lastFlutter = 0.0   // per set: figure id, applied pose

    private func shape(_ path: CGPath?, fill: CGColor?, extent: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.bounds = CGRect(x: -extent, y: -extent, width: 2 * extent, height: 2 * extent)
        l.position = .zero
        l.path = path
        l.fillColor = fill
        return l
    }

    private func dots(_ pts: [(CGFloat, CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        for (x, y, r) in pts { p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        return p
    }

    init() {
        let R = BallLayers.big
        let circle = CGPath(ellipseIn: CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R), transform: nil)
        let snow = CGColor(red: 0.84, green: 0.90, blue: 0.98, alpha: 1)
        let speckle = CGColor(red: 0.60, green: 0.70, blue: 0.86, alpha: 0.85)
        let specks = dots([(0.55 * R * cos(0.5), 0.55 * R * sin(0.5), 1.9), (0.72 * R * cos(2.4), 0.72 * R * sin(2.4), 2.4),
                           (0.3 * R * cos(4.0), 0.3 * R * sin(4.0), 1.6), (0.8 * R * cos(5.3), 0.8 * R * sin(5.3), 2.0),
                           (0.45 * R * cos(3.0), 0.45 * R * sin(3.0), 1.4), (0.62 * R * cos(1.5), 0.62 * R * sin(1.5), 1.3)])
        for _ in 0..<(Tuning.maxBalls + 3 * Tuning.maxFigures) {
            let g = CALayer()
            g.bounds = CGRect(x: -R, y: -R, width: 2 * R, height: 2 * R)
            let body = shape(circle, fill: snow, extent: R)
            body.shadowPath = circle
            body.shadowColor = CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
            body.shadowOpacity = 0.45
            body.shadowRadius = 3
            body.shadowOffset = CGSize(width: 0, height: -1.5)
            body.lineWidth = 1
            g.addSublayer(body)
            g.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -R + 1.2, y: -R + 2.6, width: 2 * R - 2.4, height: 2 * R - 2.4), transform: nil),
                                fill: CGColor(red: 0.90, green: 0.94, blue: 0.995, alpha: 1), extent: R))
            let sp = shape(specks, fill: speckle, extent: R)
            g.addSublayer(sp)
            g.addSublayer(shape(CGPath(ellipseIn: CGRect(x: -0.7 * R, y: 0.05 * R, width: 0.85 * R, height: 0.7 * R), transform: nil),
                                fill: CGColor(gray: 1, alpha: 0.85), extent: R))
            g.isHidden = true
            groups.append(Group(layer: g, speckles: sp, body: body))
        }
        let coal = CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        for _ in 0..<Tuning.maxFigures {
            // Arms (unit = middle ball radius), drawn under every ball.
            let arms = shape(nil, fill: nil, extent: 3)
            arms.strokeColor = CGColor(red: 0.38, green: 0.25, blue: 0.14, alpha: 1)
            arms.lineWidth = 0.15
            arms.lineCap = .round
            var armLR: [CAShapeLayer] = []
            for s: CGFloat in [-1, 1] {   // one layer per arm, rotated about its shoulder
                let a = CGMutablePath()
                a.move(to: CGPoint(x: s * 0.7, y: -0.12)); a.addLine(to: CGPoint(x: s * 2.0, y: 0.7))
                a.move(to: CGPoint(x: s * 1.47, y: 0.34)); a.addLine(to: CGPoint(x: s * 1.59, y: 0.88))
                a.move(to: CGPoint(x: s * 1.76, y: 0.55)); a.addLine(to: CGPoint(x: s * 2.21, y: 0.93))
                let arm = shape(a, fill: nil, extent: 3)
                arm.strokeColor = arms.strokeColor
                arm.lineWidth = arms.lineWidth
                arm.lineCap = .round
                arms.addSublayer(arm)
                armLR.append(arm)
            }
            // Buttons on the middle ball.
            let mid = shape(dots([(0, 0.44, 0.11), (0, 0.01, 0.11), (0, -0.41, 0.11)]), fill: coal, extent: 3)
            // Head (unit = head radius): eyes, smile, carrot, scarf.
            let head = shape(nil, fill: coal, extent: 3)
            let h = CGMutablePath()
            h.addPath(dots([(-0.38, 0.26, 0.146), (0.38, 0.26, 0.146), (-0.4, -0.29, 0.07), (-0.2, -0.4, 0.07), (0, -0.43, 0.07), (0.2, -0.4, 0.07), (0.4, -0.29, 0.07)]))
            head.path = h
            let nose = shape(nil, fill: CGColor(red: 0.96, green: 0.52, blue: 0.12, alpha: 1), extent: 3)
            let n = CGMutablePath()
            n.move(to: CGPoint(x: 0.09, y: 0.11)); n.addLine(to: CGPoint(x: 1.23, y: -0.09)); n.addLine(to: CGPoint(x: 0.09, y: -0.23)); n.closeSubpath()
            nose.path = n
            let scarf = shape(nil, fill: CGColor(red: 0.82, green: 0.17, blue: 0.20, alpha: 1), extent: 3)
            let sc = CGMutablePath()
            sc.addRoundedRect(in: CGRect(x: -1.14, y: -1.31, width: 2.28, height: 0.56), cornerWidth: 0.28, cornerHeight: 0.28)
            scarf.path = sc
            let red = CGColor(red: 0.82, green: 0.17, blue: 0.20, alpha: 1)
            let tail = CGMutablePath(), tail2 = CGMutablePath()   // two segments, split at y = -1.765; the lower overlaps a little
            tail.move(to: CGPoint(x: 0.49, y: -1.15)); tail.addLine(to: CGPoint(x: 1.08, y: -1.15)); tail.addLine(to: CGPoint(x: 1.17, y: -1.765)); tail.addLine(to: CGPoint(x: 0.585, y: -1.765)); tail.closeSubpath()
            tail2.move(to: CGPoint(x: 0.58, y: -1.70)); tail2.addLine(to: CGPoint(x: 1.16, y: -1.70)); tail2.addLine(to: CGPoint(x: 1.26, y: -2.38)); tail2.addLine(to: CGPoint(x: 0.68, y: -2.38)); tail2.closeSubpath()
            let t1 = shape(tail, fill: red, extent: 3), t2 = shape(tail2, fill: red, extent: 3)
            t1.addSublayer(t2)
            scarf.addSublayer(t1)
            let stripes = shape(nil, fill: CGColor(red: 0.98, green: 0.88, blue: 0.86, alpha: 0.9), extent: 3)
            let st = CGMutablePath()
            st.addRect(CGRect(x: -0.54, y: -1.31, width: 0.2, height: 0.56)); st.addRect(CGRect(x: 0.12, y: -1.31, width: 0.2, height: 0.56))
            stripes.path = st
            scarf.addSublayer(stripes)
            head.addSublayer(nose)
            head.addSublayer(scarf)
            for l in [arms, mid, head] { l.isHidden = true }
            sets.append(Accessories(arms: arms, mid: mid, head: head, armLR: armLR, tails: [t1, t2]))
        }
        keys = Array(repeating: -1, count: sets.count); shownPoses = Array(repeating: Flutter(), count: sets.count)
        for s in sets { root.addSublayer(s.arms) }
        for g in groups { root.addSublayer(g.layer) }
        for s in sets { root.addSublayer(s.mid); root.addSublayer(s.head) }
    }

    func setContrast(_ on: Bool) {
        for g in groups {
            g.body.shadowOpacity = on ? 0.8 : 0.45
            g.body.shadowColor = on ? CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1) : CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
            g.body.strokeColor = on ? CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1) : nil
        }
    }

    private func place(_ l: CALayer, at p: SIMD2<Float>, radius: Float, alpha: Float = 1, grow: Float = 1, flip: CGFloat = 1) {
        l.position = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        let k = CGFloat(radius * grow)
        l.transform = CATransform3DMakeScale(k * flip, k, 1)
        l.opacity = alpha
        l.isHidden = false
    }

    /// Scarf tail and arm transforms of set `i` (skipped when unchanged).
    private func pose(_ i: Int, _ p: Flutter, facing: Float, force: Bool = false) {
        guard force || p != shownPoses[i] else { return }
        shownPoses[i] = p
        let f = CGFloat(facing)   // the head is mirrored when facing left
        spin(sets[i].tails[0], CGFloat(p.scarf) * f, about: CGPoint(x: 0.8, y: -1.15))
        spin(sets[i].tails[1], CGFloat(p.wave) * f, about: CGPoint(x: 0.88, y: -1.765))
        for (k, arm) in sets[i].armLR.enumerated() {
            let side: Float = k == 0 ? -1 : 1
            spin(arm, CGFloat(p.arm(side: side)), about: CGPoint(x: CGFloat(side) * 0.7, y: -0.12))
        }
    }

    private func spin(_ l: CALayer, _ a: CGFloat, about p: CGPoint) {
        l.setAffineTransform(CGAffineTransform(translationX: p.x, y: p.y).rotated(by: a).translatedBy(x: -p.x, y: -p.y))
    }

    private func put(_ g: Group, at p: SIMD2<Float>, radius: Float, rotation: Float = 0, alpha: Float = 1) {
        g.layer.position = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        let k = CGFloat(radius) / BallLayers.big
        g.layer.transform = CATransform3DMakeScale(k, k, 1)
        g.layer.opacity = alpha
        g.speckles.transform = CATransform3DMakeRotation(CGFloat(rotation), 0, 0, 1)
        g.layer.isHidden = false
    }

    /// Called every frame; does real work only when the field's balls or figures changed.
    func update(_ field: SnowField, reduceMotion: Bool) {
        guard field.ballsVersion != shown || field.figuresVersion != shownFigs else {   // nothing moved: only the scarf / arms flutter, at most 30 Hz
            let now = CACurrentMediaTime()
            guard now - lastFlutter >= 1 / 30 else { return }
            lastFlutter = now
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for i in sets.indices where keys[i] >= 0 {
                guard let f = field.figures.first(where: { $0.id == keys[i] }) else { continue }
                pose(i, reduceMotion ? Flutter() : f.pose.flutter, facing: f.facing)
            }
            CATransaction.commit()
            return
        }
        shown = field.ballsVersion; shownFigs = field.figuresVersion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var gi = 0
        for b in field.balls where gi < groups.count {
            put(groups[gi], at: b.pos, radius: b.radius, rotation: b.rotation, alpha: b.fade)
            gi += 1
        }
        var k = 0
        for f in field.figures where f.fromBalls && f.phase != .hidden && k < sets.count {
            let l = field.look(of: f)
            let e = reduceMotion ? 1 : l.newest, grow = 0.85 + 0.15 * e
            for (c, r) in [(l.centers.0, l.radii.x), (l.centers.1, l.radii.y), (l.centers.2, l.radii.z)].prefix(l.headless ? 2 : 3) where gi < groups.count {
                put(groups[gi], at: c, radius: r)
                gi += 1
            }
            place(sets[k].arms, at: l.centers.1, radius: l.radii.y, alpha: e, grow: grow)
            place(sets[k].mid, at: l.centers.1, radius: l.radii.y, alpha: e, grow: grow)
            if l.headless { sets[k].head.isHidden = true } else {
                place(sets[k].head, at: l.centers.2, radius: l.radii.z, alpha: e, grow: grow, flip: CGFloat(l.facing))   // faces its foe
            }
            keys[k] = f.id
            pose(k, reduceMotion ? Flutter() : l.pose.flutter, facing: l.facing, force: true)
            k += 1
        }
        for g in groups[gi...] { g.layer.isHidden = true }
        for i in k..<sets.count { keys[i] = -1 }
        for s in sets[k...] { s.arms.isHidden = true; s.mid.isHidden = true; s.head.isHidden = true }
        CATransaction.commit()
    }
}

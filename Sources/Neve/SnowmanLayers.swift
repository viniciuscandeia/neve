import NeveCore
import AppKit
import QuartzCore

/// Layer tree for the snowman. All paths are built once (local coordinates: origin = centre of the base, y up, scale 1);
/// per frame it only toggles visibility / ease-in while a stage is appearing, and moves when the pile under it changes.
@MainActor
final class SnowmanLayers {
    let root = CALayer()
    private var elements: [CALayer] = []      // index = stage - 1: base, middle, head, coal, nose, arms, scarf
    private var bodies: [CAShapeLayer] = []
    private var shown = -1, shownCollapsing = false, shownPos = SIMD2<Float>(-1e9, -1e9), shownScale: Float = 0
    private let box = CGRect(x: -30, y: 0, width: 60, height: 60)

    private func local(_ build: (CGMutablePath) -> Void) -> CGPath {   // path in `box` coordinates
        let p = CGMutablePath()
        build(p)
        var t = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        return p.copy(using: &t) ?? p
    }

    private func shape(_ path: CGPath, _ fill: CGColor, in frame: CGRect) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.frame = frame
        l.path = path
        l.fillColor = fill
        return l
    }

    init() {
        let snow = CGColor(red: 0.84, green: 0.90, blue: 0.98, alpha: 1)
        let lift = CGColor(red: 0.90, green: 0.94, blue: 0.995, alpha: 1)
        // Arms first so they come out from behind the middle ball.
        let arms = CAShapeLayer()
        arms.frame = box
        arms.fillColor = nil
        arms.strokeColor = CGColor(red: 0.38, green: 0.25, blue: 0.14, alpha: 1)
        arms.lineWidth = 1.3
        arms.lineCap = .round
        arms.path = local { p in
            for s: CGFloat in [-1, 1] {
                p.move(to: CGPoint(x: s * 6, y: 29.5)); p.addLine(to: CGPoint(x: s * 17, y: 36.5))      // arm
                p.move(to: CGPoint(x: s * 12.5, y: 33.4)); p.addLine(to: CGPoint(x: s * 13.5, y: 38))   // twigs
                p.move(to: CGPoint(x: s * 15, y: 35.2)); p.addLine(to: CGPoint(x: s * 18.8, y: 38.4))
            }
        }
        root.addSublayer(arms)
        for (cy, r) in Snowman.balls {
            let c = CGFloat(cy), r = CGFloat(r)
            let g = CALayer()
            g.frame = CGRect(x: -r, y: c - r, width: 2 * r, height: 2 * r)
            let f = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            let circle = CGPath(ellipseIn: f, transform: nil)
            let body = shape(circle, snow, in: f)
            body.shadowPath = circle
            body.shadowColor = CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
            body.shadowOpacity = 0.45
            body.shadowRadius = 2
            body.shadowOffset = CGSize(width: 0, height: -1)
            body.strokeColor = nil
            body.lineWidth = 0.8
            g.addSublayer(body)
            // Lit side: a lighter, slightly lifted disc and a white crest, like the piles' highlight + crest.
            g.addSublayer(shape(CGPath(ellipseIn: f.insetBy(dx: 0.6, dy: 0.6).offsetBy(dx: -0.3, dy: 1.1), transform: nil), lift, in: f))
            g.addSublayer(shape(CGPath(ellipseIn: CGRect(x: r * 0.3, y: r * 1.05, width: r * 0.85, height: r * 0.7), transform: nil),
                                CGColor(gray: 1, alpha: 0.85), in: f))
            root.addSublayer(g)
            elements.append(g)
            bodies.append(body)
        }
        let coalColor = CGColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        let coal = shape(local { p in
            for (x, y): (CGFloat, CGFloat) in [(-2.5, 46.2), (2.5, 46.2), (0, 34.2), (0, 30.6), (0, 27)] {
                p.addEllipse(in: CGRect(x: x - 0.95, y: y - 0.95, width: 1.9, height: 1.9))
            }
            for (x, y): (CGFloat, CGFloat) in [(-2.6, 42.6), (-1.3, 41.9), (0, 41.7), (1.3, 41.9), (2.6, 42.6)] {   // smile
                p.addEllipse(in: CGRect(x: x - 0.45, y: y - 0.45, width: 0.9, height: 0.9))
            }
        }, coalColor, in: box)
        let nose = shape(local { p in
            p.move(to: CGPoint(x: 0.6, y: 45.2)); p.addLine(to: CGPoint(x: 8, y: 43.9)); p.addLine(to: CGPoint(x: 0.6, y: 43)); p.closeSubpath()
        }, CGColor(red: 0.96, green: 0.52, blue: 0.12, alpha: 1), in: box)
        let scarf = shape(local { p in
            p.addRoundedRect(in: CGRect(x: -7.4, y: 36, width: 14.8, height: 3.6), cornerWidth: 1.8, cornerHeight: 1.8)
            p.move(to: CGPoint(x: 3.2, y: 37)); p.addLine(to: CGPoint(x: 7, y: 37)); p.addLine(to: CGPoint(x: 8.2, y: 29)); p.addLine(to: CGPoint(x: 4.4, y: 29)); p.closeSubpath()
        }, CGColor(red: 0.82, green: 0.17, blue: 0.20, alpha: 1), in: box)
        scarf.addSublayer(shape(local { p in
            p.addRect(CGRect(x: -3.5, y: 36, width: 1.3, height: 3.6)); p.addRect(CGRect(x: 0.8, y: 36, width: 1.3, height: 3.6))
        }, CGColor(red: 0.98, green: 0.88, blue: 0.86, alpha: 0.9), in: CGRect(origin: .zero, size: box.size)))
        for l in [coal, nose, scarf] { root.addSublayer(l); elements.append(l) }
        elements.insert(arms, at: 5)   // stage 6 = arms; the arms layer sits at the bottom of the z-order
        // elements is now [base, middle, head, coal, nose, arms, scarf] in stage order
        root.isHidden = true
        for l in elements { l.isHidden = true }
    }

    /// Increase Contrast: stronger shadow and a dark-blue outline on the balls.
    func setContrast(_ on: Bool) {
        for b in bodies {
            b.shadowOpacity = on ? 0.8 : 0.45
            b.shadowColor = on ? CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1) : CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
            b.strokeColor = on ? CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1) : nil
        }
    }

    /// Called every frame; does real work only on a stage / position change, a collapse, or during the 0.3 s ease-in.
    func update(_ field: SnowField, reduceMotion: Bool) {
        guard let m = field.snowman, let pos = field.snowmanPlacement() else {
            if !root.isHidden { root.isHidden = true; shown = -1 }
            return
        }
        let easing = !reduceMotion && m.stageAge < 0.35
        guard m.stage != shown || m.collapsing != shownCollapsing || m.collapsing || easing || pos != shownPos || root.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pos != shownPos || m.scale != shownScale || root.isHidden {
            root.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            root.setAffineTransform(CGAffineTransform(scaleX: CGFloat(m.scale), y: CGFloat(m.scale)))
            shownPos = pos; shownScale = m.scale
        }
        root.isHidden = false
        for (i, l) in elements.enumerated() {
            let present = m.stage > i && !(m.collapsing && i < 3)   // balls turn into debris at once
            l.isHidden = !present
            guard present else { continue }
            var alpha: Float = m.collapsing ? m.fade : 1, grow: Float = 1
            if i == m.stage - 1, easing {   // newest stage: short ease-out in
                let t = min(m.stageAge / 0.3, 1), e = t * (2 - t)
                alpha = e
                grow = (i < 3 ? 0.3 : 0.85) + (i < 3 ? 0.7 : 0.15) * e
            }
            l.opacity = alpha
            l.transform = grow == 1 ? CATransform3DIdentity : CATransform3DMakeScale(CGFloat(grow), CGFloat(grow), 1)
        }
        shown = m.stage; shownCollapsing = m.collapsing
        CATransaction.commit()
    }
}

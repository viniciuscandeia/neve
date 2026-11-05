import NeveCore
import AppKit
import QuartzCore

/// The snowballs thrown in a snowball fight: a small pool of round layers, positioned from `field.shots`.
/// Does nothing (no layer work) while nothing is in the air.
@MainActor
final class FightLayers {
    let root = CALayer()
    private var pool: [CAShapeLayer] = []
    private var visible = 0

    init() {
        let r: CGFloat = 3.6
        let circle = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        for _ in 0..<6 {
            let l = CAShapeLayer()
            l.path = circle
            l.fillColor = CGColor(red: 0.93, green: 0.96, blue: 1, alpha: 1)
            l.shadowPath = circle
            l.shadowColor = CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
            l.shadowOpacity = 0.5
            l.shadowRadius = 1.5
            l.shadowOffset = CGSize(width: 0, height: -1)
            l.isHidden = true
            root.addSublayer(l)
            pool.append(l)
        }
    }

    /// Called every frame.
    func update(_ field: SnowField) {
        let shots = field.shots
        guard !shots.isEmpty || visible > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in pool.enumerated() {
            guard i < shots.count else { l.isHidden = true; continue }
            l.position = CGPoint(x: CGFloat(shots[i].pos.x), y: CGFloat(shots[i].pos.y))
            l.isHidden = false
        }
        CATransaction.commit()
        visible = min(shots.count, pool.count)
    }
}

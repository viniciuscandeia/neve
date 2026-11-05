import AppKit
import QuartzCore

/// Layers of one snow pile set: bluish body with soft shadow, a white copy lifted 1.5pt (leaves a thin shaded band
/// at the bottom edge) and a pure-white crest masked to a ~3pt sliver along the top. Used for the normal piles and
/// for the pile of a window being dragged (slid with the mouse between polls).
@MainActor
final class PileLayers {
    private let body = CAShapeLayer(), highlight = CAShapeLayer(), crest = CAShapeLayer(), mask = CAShapeLayer()
    private var all: [CAShapeLayer] { [body, highlight, crest] }

    init(in root: CALayer, bounds: CGRect) {
        body.frame = bounds
        body.fillColor = CGColor(red: 0.84, green: 0.90, blue: 0.98, alpha: 0.97)
        body.shadowRadius = 3
        body.shadowOffset = CGSize(width: 0, height: -1.5)
        highlight.frame = bounds.offsetBy(dx: 0, dy: 1.5)
        highlight.fillColor = CGColor(red: 0.88, green: 0.93, blue: 0.99, alpha: 0.97)
        crest.frame = bounds
        crest.fillColor = CGColor(gray: 1, alpha: 0.95)
        mask.frame = crest.bounds
        mask.fillColor = CGColor(gray: 0, alpha: 1)
        mask.fillRule = .evenOdd
        crest.mask = mask
        for l in all { root.addSublayer(l) }
        setContrast(false)
    }

    /// Increase Contrast: darker, stronger shadow under the pile.
    func setContrast(_ on: Bool) {
        body.shadowOpacity = on ? 0.8 : 0.45
        body.shadowColor = on ? CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1) : CGColor(red: 0.25, green: 0.4, blue: 0.65, alpha: 1)
    }

    /// Runs only when the path changes. The crest mask is the path minus itself shifted down 3pt.
    func set(path: CGPath?) {
        body.path = path
        body.shadowPath = path
        highlight.path = path
        crest.path = path
        guard let path else { mask.path = nil; return }
        let q = CGMutablePath()
        q.addPath(path)
        q.addPath(path, transform: CGAffineTransform(translationX: 0, y: -3))
        mask.path = q
    }

    func setTransform(_ t: CGAffineTransform) { for l in all { l.setAffineTransform(t) } }
}

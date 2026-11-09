import CoreGraphics

/// Where the menu-bar panel goes: `gap` below the status item, left edge aligned to it, clamped inside the screen's visible frame.
public func panelFrame(size: CGSize, anchor: CGRect, visible: CGRect, gap: CGFloat = 5, margin: CGFloat = 4) -> CGRect {
    let maxX = visible.maxX - margin - size.width, minX = visible.minX + margin
    let x = max(minX, min(anchor.minX, maxX))
    let y = max(visible.minY + margin, anchor.minY - gap - size.height)
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

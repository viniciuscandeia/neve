import CoreGraphics
import Foundation

public struct WindowInfo: Equatable, Sendable {
    public let number: Int     // 0 = Dock bar
    public let frame: CGRect   // global AppKit coordinates (y up)
    public var radius: CGFloat = Tuning.defaultWindowRadius
    public init(number: Int, frame: CGRect, radius: CGFloat = Tuning.defaultWindowRadius) {
        self.number = number; self.frame = frame; self.radius = radius
    }
}

/// CG (origin top-left of primary screen, y down) -> AppKit (y up).
public func appKitFrame(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
}

/// One raw window-server entry as plain values (nil = key missing). `alpha` defaults to 1 when absent.
public struct RawWindow {
    public var number: Int?, pid: Int?, layer: Int?
    public var alpha: Double
    public var bounds: CGRect?   // CG coordinates
    public init(number: Int?, pid: Int?, layer: Int?, alpha: Double = 1, bounds: CGRect?) {
        self.number = number; self.pid = pid; self.layer = layer; self.alpha = alpha; self.bounds = bounds
    }
}

/// Keeps layer-0, visible, foreign, at-least-40x20 windows; converts bounds to AppKit coordinates. Order preserved.
public func filterWindows(_ raw: [RawWindow], ownPID: Int, primaryHeight: CGFloat, radius: CGFloat = Tuning.defaultWindowRadius) -> [WindowInfo] {
    raw.compactMap { w in
        guard w.layer == 0, w.pid != ownPID, w.alpha > 0, let number = w.number, let r = w.bounds,
              r.width >= 40, r.height >= 20 else { return nil }
        return WindowInfo(number: number, frame: appKitFrame(fromCG: r, primaryHeight: primaryHeight), radius: radius)
    }
}

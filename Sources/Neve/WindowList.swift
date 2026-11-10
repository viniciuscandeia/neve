import AppKit
import CoreGraphics
import Foundation
import NeveCore

/// Screen frames in CG coordinates, cached: refreshed only on didChangeScreenParameters (NSScreen.screens is costly on every poll).
@MainActor private enum ScreenCache {
    static var frames: [CGRect]?
    static var observer: NSObjectProtocol?
    static func get(primaryHeight: CGFloat) -> [CGRect] {
        if observer == nil { observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in MainActor.assumeIsolated { frames = nil } } }
        if let f = frames { return f }
        let f = NSScreen.screens.map { appKitFrame(fromCG: $0.frame, primaryHeight: primaryHeight) }   // the flip is its own inverse
        frames = f
        return f
    }
}

/// On-screen normal windows, front to back. Bounds need no Screen Recording permission.
@MainActor public func readWindows(primaryHeight: CGFloat, exclude: Set<Int> = [], scene: Set<Int>? = nil) -> [WindowInfo]? {
    readWindowsAndMC(primaryHeight: primaryHeight, exclude: exclude, scene: scene)?.windows
}

/// `missionControl`: the Dock shows its full-screen overlay (Mission Control / Exposé), see `isMissionControl`.
@MainActor public func readWindowsAndMC(primaryHeight: CGFloat, exclude: Set<Int> = [], scene: Set<Int>? = nil) -> (windows: [WindowInfo], missionControl: Bool)? {   // nil = CGWindowList failed (distinct from a valid empty list)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return nil }
    // Read CF values directly: bridging every dictionary to Swift costs more than the call itself.
    func int(_ d: CFDictionary, _ k: CFString) -> Int? {
        guard let v = CFDictionaryGetValue(d, Unmanaged.passUnretained(k).toOpaque()) else { return nil }
        var n = 0
        return CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .longType, &n) ? n : nil
    }
    func str(_ d: CFDictionary, _ k: CFString) -> String? {
        CFDictionaryGetValue(d, Unmanaged.passUnretained(k).toOpaque()).map { unsafeBitCast($0, to: CFString.self) as String }
    }
    let screens = ScreenCache.get(primaryHeight: primaryHeight)
    var raw: [RawWindow] = []
    for i in 0..<CFArrayGetCount(list) {
        let w = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
        var alpha = 1.0
        if let a = CFDictionaryGetValue(w, Unmanaged.passUnretained(kCGWindowAlpha).toOpaque()) {
            CFNumberGetValue(unsafeBitCast(a, to: CFNumber.self), .doubleType, &alpha)
        }
        var bounds: CGRect?
        if let b = CFDictionaryGetValue(w, Unmanaged.passUnretained(kCGWindowBounds).toOpaque()) {
            bounds = CGRect(dictionaryRepresentation: unsafeBitCast(b, to: CFDictionary.self))
        }
        let layer = int(w, kCGWindowLayer)
        // Owner name (a CFString bridge) only where it matters: non-zero layers (system owners, Dock); layer 0 never needs it.
        raw.append(RawWindow(number: int(w, kCGWindowNumber), pid: int(w, kCGWindowOwnerPID), layer: layer, alpha: alpha, bounds: bounds, owner: layer == 0 ? nil : str(w, kCGWindowOwnerName)))
    }
    let mc = scene == nil && isMissionControl(raw, screens: screens)
    return (filterWindows(raw, exclude: exclude, primaryHeight: primaryHeight, radius: osWindowRadius, scene: scene, ownPID: Int(getpid()), screens: screens), mc)
}

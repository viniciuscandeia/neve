import AppKit
import CoreGraphics
import Foundation
import NeveCore

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
        raw.append(RawWindow(number: int(w, kCGWindowNumber), pid: int(w, kCGWindowOwnerPID), layer: int(w, kCGWindowLayer), alpha: alpha, bounds: bounds, owner: str(w, kCGWindowOwnerName)))
    }
    let mc = scene == nil && isMissionControl(raw, screens: NSScreen.screens.map { appKitFrame(fromCG: $0.frame, primaryHeight: primaryHeight) })   // the flip is its own inverse
    return (filterWindows(raw, exclude: exclude, primaryHeight: primaryHeight, radius: osWindowRadius, scene: scene, ownPID: Int(getpid())), mc)
}

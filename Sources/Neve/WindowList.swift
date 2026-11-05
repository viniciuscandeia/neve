import CoreGraphics
import Foundation
import NeveCore

/// On-screen normal windows, front to back. Bounds need no Screen Recording permission.
public func readWindows(primaryHeight: CGFloat) -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return [] }
    // Read CF values directly: bridging every dictionary to Swift costs more than the call itself.
    func int(_ d: CFDictionary, _ k: CFString) -> Int? {
        guard let v = CFDictionaryGetValue(d, Unmanaged.passUnretained(k).toOpaque()) else { return nil }
        var n = 0
        return CFNumberGetValue(unsafeBitCast(v, to: CFNumber.self), .longType, &n) ? n : nil
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
        raw.append(RawWindow(number: int(w, kCGWindowNumber), pid: int(w, kCGWindowOwnerPID), layer: int(w, kCGWindowLayer), alpha: alpha, bounds: bounds))
    }
    return filterWindows(raw, ownPID: Int(getpid()), primaryHeight: primaryHeight)
}

// AGENT HEADER - Sources/Neve/AppearanceWatcher.swift  (system light/dark -> Palette)
// Role: `AppearanceWatcher` (@MainActor): mirrors the system light/dark appearance into Palette.darkTarget (fade ~0.5 s eased by Palette.tick per frame) and posts `changed` so paused (still) overlays wake. Started once by Overlay.sharedGpu (before the Gpu is built).
// Stays in the app (AppKit): NeveRender has no appearance observers. Related: NeveCore/Palette.swift.

import AppKit
import NeveCore

/// Follows the system appearance: `Palette.darkTarget` is 1 under Dark Aqua; the overlays ease `Palette.dark` toward it.
@MainActor enum AppearanceWatcher {
    private static var started = false
    static let changed = Notification.Name("NeveAppearanceTargetChanged")
    /// A new target wakes every overlay (a still-paused one would never run the blend) and restarts the palette clock: the fade is a smooth 0.5 s.
    static func read() {
        let t: Float = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0
        guard t != Palette.darkTarget else { return }
        Palette.darkTarget = t
        Palette.resetClock()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func start() {
        guard !started else { return }
        started = true
        read(); Palette.dark = Palette.darkTarget   // first value without a fade
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { read() } }   // effectiveAppearance settles just after the notification
        }
    }
}

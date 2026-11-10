import Testing
import CoreGraphics
import Foundation
@testable import NeveCore

@Test func takeOnceFiresOnce() {
    let d = UserDefaults(suiteName: "neve.test.once")!; d.removePersistentDomain(forName: "neve.test.once")
    #expect(takeOnce("firstRun", in: d)); #expect(!takeOnce("firstRun", in: d)); #expect(takeOnce("other", in: d))
}

@Test func restoreDefaultsReturnsToPrefDefaults() {
    let d = UserDefaults(suiteName: "neve.test.reset")!; d.removePersistentDomain(forName: "neve.test.reset")
    for p in Pref.allCases { d.set(!p.defaultValue, forKey: p.rawValue) }
    d.set(3, forKey: Intensity.key); d.set("main", forKey: "snowOn")
    restoreDefaults(in: d)
    for p in Pref.allCases { #expect(OverlayPrefs({ d.object(forKey: $0.rawValue) as? Bool ?? $0.defaultValue }) == OverlayPrefs()) ; #expect(d.object(forKey: p.rawValue) == nil) }
    #expect(d.object(forKey: Intensity.key) == nil && d.string(forKey: "snowOn") == nil)
}

@Test func screenLabelsDisambiguateAndMarkTheMain() {
    let a = CGSize(width: 1920, height: 1080), b = CGSize(width: 2560, height: 1440)
    #expect(screenLabels(names: ["Dell", "Dell"], sizes: [a, b]) == ["Dell (1920×1080) (\(tr("principal")))", "Dell (2560×1440)"])
    #expect(screenLabels(names: ["Dell", "Dell"], sizes: [a, a]) == ["Dell (1920×1080) (\(tr("principal")))", "Dell (1920×1080)"])
    #expect(screenLabels(names: ["Mac", "LG"], sizes: [a, b]) == ["Mac (\(tr("principal")))", "LG"])
}

@Test func loginNoteAndSteppedLevel() {
    #expect(loginNote(requiresApproval: true, failed: false) == tr("Aprove em Ajustes do Sistema › Itens de Início."))
    #expect(!loginNote(requiresApproval: false, failed: true).isEmpty)
    #expect(loginNote(requiresApproval: false, failed: false) == "")
    #expect(steppedLevel(3, by: 1) == 3 && steppedLevel(0, by: -1) == 0 && steppedLevel(1, by: 1) == 2)
}

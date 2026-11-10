import Testing
import CoreGraphics
@testable import NeveCore

@Test func panelSitsBelowAnchorAndClampsToScreen() {
    let vis = CGRect(x: 0, y: 0, width: 1000, height: 780), size = CGSize(width: 280, height: 200)
    let mid = panelFrame(size: size, anchor: CGRect(x: 500, y: 780, width: 30, height: 24), visible: vis)
    #expect(mid.minX == 500 && mid.maxY == 775)
    let edge = panelFrame(size: size, anchor: CGRect(x: 980, y: 780, width: 30, height: 24), visible: vis)
    #expect(edge.maxX == 996)
    #expect(panelFrame(size: size, anchor: CGRect(x: -50, y: 780, width: 30, height: 24), visible: vis).minX == 4)
}

@Test func screenLabelsDisambiguateAndMarkTheMain() {
    let a = CGSize(width: 1920, height: 1080), b = CGSize(width: 2560, height: 1440)
    #expect(screenLabels(names: ["Dell", "Dell"], sizes: [a, b]) == ["Dell (1920×1080) (principal)", "Dell (2560×1440)"])
    #expect(screenLabels(names: ["Dell", "Dell"], sizes: [a, a]) == ["Dell (1920×1080) (principal)", "Dell (1920×1080)"])
    #expect(screenLabels(names: ["Mac", "LG"], sizes: [a, b]) == ["Mac (principal)", "LG"])
}

@Test func loginNoteAndSteppedLevel() {
    #expect(loginNote(requiresApproval: true, failed: false).contains("Itens de Início"))
    #expect(loginNote(requiresApproval: false, failed: true).contains("Aplicativos"))
    #expect(loginNote(requiresApproval: false, failed: false) == "")
    #expect(steppedLevel(3, by: 1) == 3 && steppedLevel(0, by: -1) == 0 && steppedLevel(1, by: 1) == 2)
}

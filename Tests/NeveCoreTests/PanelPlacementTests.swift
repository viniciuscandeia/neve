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

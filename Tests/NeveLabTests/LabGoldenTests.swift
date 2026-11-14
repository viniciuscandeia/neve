// AGENT HEADER - Tests/NeveLabTests/LabGoldenTests.swift
// Role: golden-image regression tests of the Neve Lab. Each Tests/LabScenes/<name>.json = {about, config{seed,size "WxH",dock,icons,appearance,intensity,prefs{name:bool}}, actions[...]} (actions are Lab actions sent as-is, plus the
// runner-only {"type":"capture","name":N}; with no capture action one final capture is taken). The scene is built through the REAL NeveLab binary (create/send/capture/stop, the same Metal capture as the CLI) and each PNG is compared BYTE-EXACT
// with Tests/LabGolden/<fingerprint>/<scene>[.<capture>].png. Fingerprint = GPU name + macOS major (goldens may differ across GPUs / OS versions); no golden dir for this machine = the test prints a SKIP message and passes.
// Mismatch: writes build/lab-golden-failures/<name>.actual.png + .diff.png (|a-b| x8) and reports differing pixel count + max channel diff. Update: env NEVE_GOLDEN_UPDATE=1 (all) or =<scene> rewrites goldens and prints UPDATED/UNCHANGED/NEW
// per file (use scripts/lab-golden.sh --update [scene]). The binary sits next to NevePackageTests.xctest (.build/<cfg>/NeveLab), like LabRealWorldTests.
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
@testable import NeveLabKit

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func exePath() -> String? {
    var d = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/nonexistent")
    for _ in 0..<6 { d.deleteLastPathComponent(); let p = d.appendingPathComponent("NeveLab").path; if FileManager.default.isExecutableFile(atPath: p) { return p } }
    return nil
}

private func fingerprint() -> String {
    let gpu = MTLCreateSystemDefaultDevice()?.name ?? "nogpu"
    let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return (gpu + "-macos\(os)").map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "" }.joined()
}

private func run(_ exe: String, _ a: [String]) throws -> JSON? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = a
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try p.run(); let data = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    let j = try? JSON.parse(data)
    if p.terminationStatus != 0 { Issue.record("NeveLab \(a.prefix(2).joined(separator: " ")) failed: \(j?.text ?? "?")") }
    return j
}

private func rgba(_ png: Data) -> (w: Int, h: Int, px: [UInt8])? {
    guard let s = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
    let w = img.width, h = img.height; var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) != nil }
    return ok ? (w, h, px) : nil
}

private func writePNG(_ px: [UInt8], _ w: Int, _ h: Int, to url: URL) {
    var px = px
    guard let ctx = px.withUnsafeMutableBytes({ CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) }),
          let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

/// Failure report: actual + amplified abs-diff PNG under build/lab-golden-failures; returns the message.
private func report(_ name: String, golden: Data, actual: Data) -> String {
    let dir = root.appendingPathComponent("build/lab-golden-failures")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? actual.write(to: dir.appendingPathComponent("\(name).actual.png"))
    guard let g = rgba(golden), let a = rgba(actual), g.w == a.w, g.h == a.h else { return "\(name): size/format differs from golden (actual: \(dir.path)/\(name).actual.png)" }
    var diff = [UInt8](repeating: 255, count: g.px.count), count = 0, maxD = 0
    for i in stride(from: 0, to: g.px.count, by: 4) {
        var d = 0
        for c in 0..<3 { let v = abs(Int(g.px[i + c]) - Int(a.px[i + c])); d = max(d, v); diff[i + c] = UInt8(min(255, v * 8)) }
        if d > 0 { count += 1; maxD = max(maxD, d) }
    }
    writePNG(diff, g.w, g.h, to: dir.appendingPathComponent("\(name).diff.png"))
    return "\(name): \(count) pixels differ, max channel diff \(maxD); see \(dir.path)/\(name).actual.png and \(name).diff.png"
}

/// Builds the scene in a real NeveLab session; returns [(capture name, png bytes)].
private func render(_ exe: String, scene: String, _ def: [String: Any]) throws -> [(String, Data)] {
    let c = def["config"] as? [String: Any] ?? [:]
    let id = "gd" + String(UUID().uuidString.prefix(6)), dir = NSTemporaryDirectory() + "ngd-\(UUID().uuidString.prefix(8))"
    let created = try run(exe, ["create", "--id", id, "--seed", "\(c["seed"] as? Int ?? 1)", "--size", c["size"] as? String ?? "640x400", "--dir", dir, "--dock", c["dock"] as? String ?? "bottom",
                                "--dock-icons", "\(c["icons"] as? Int ?? 12)", "--appearance", c["appearance"] as? String ?? "light"])
    guard created != nil else { return [] }
    defer { _ = try? run(exe, ["stop", "--id", id]) }
    func send(_ a: [String: Any]) throws { _ = try run(exe, ["send", "--id", id, String(data: JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]), encoding: .utf8)!]) }
    if let l = c["intensity"] as? String { try send(["type": "set_intensity", "level": l]) }
    for (k, v) in (c["prefs"] as? [String: Bool] ?? [:]).sorted(by: { $0.key < $1.key }) { try send(["type": "set_pref", "pref": k, "value": v]) }
    var shots: [(String, Data)] = []
    func capture(_ name: String) throws {
        let r = try run(exe, ["capture", "--id", id, "--dir", dir + "/out"])
        if case .array(let fs)? = r?["result"]?["files"], let f = fs.compactMap({ $0.string }).first(where: { $0.hasSuffix(".png") }) { shots.append((name, try Data(contentsOf: URL(fileURLWithPath: f)))) }
        else { Issue.record("\(scene): capture returned no png") }
    }
    let actions = def["actions"] as? [[String: Any]] ?? []
    for a in actions { if a["type"] as? String == "capture" { try capture(a["name"] as? String ?? "") } else { try send(a) } }
    if !actions.contains(where: { $0["type"] as? String == "capture" }) { try capture("") }
    return shots
}

@Suite(.serialized) struct LabGoldenTests {
    @Test func scenesMatchGoldens() throws {
        let exe = try #require(exePath(), "NeveLab binary not found next to the test bundle")
        let fp = fingerprint(), upd = ProcessInfo.processInfo.environment["NEVE_GOLDEN_UPDATE"]
        let goldDir = root.appendingPathComponent("Tests/LabGolden/\(fp)")
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Tests/LabScenes").path).filter { $0.hasSuffix(".json") }.sorted().map { String($0.dropLast(5)) }
        #expect(!names.isEmpty)
        if upd == nil, !fm.fileExists(atPath: goldDir.path) {
            print("LAB-GOLDEN SKIP: no goldens for this machine (\(fp)); create them with scripts/lab-golden.sh --update"); return
        }
        var failures: [String] = []
        for scene in names where upd == nil || upd == "1" || upd == scene {
            let def = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/LabScenes/\(scene).json"))) as? [String: Any])
            for (cap, png) in try render(exe, scene: scene, def) {
                let name = cap.isEmpty ? scene : "\(scene).\(cap)", url = goldDir.appendingPathComponent("\(name).png")
                let old = try? Data(contentsOf: url)
                if upd != nil {
                    try fm.createDirectory(at: goldDir, withIntermediateDirectories: true)
                    if old != png { try png.write(to: url) }
                    print("LAB-GOLDEN \(old == nil ? "NEW" : old == png ? "UNCHANGED" : "UPDATED") \(name)")
                } else if let old { if old != png { failures.append(report(name, golden: old, actual: png)) } }
                else { failures.append("\(name): golden missing in \(goldDir.path) (scripts/lab-golden.sh --update \(scene))") }
            }
        }
        for f in failures { Issue.record(Comment(rawValue: "LAB-GOLDEN MISMATCH " + f)) }
    }
}

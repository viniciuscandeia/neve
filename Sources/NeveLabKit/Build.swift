// AGENT HEADER - Sources/NeveLabKit/Build.swift
// Role: build identity recorded in a session's config.json (git commit + dirty flag of the checkout the binary runs from, via `git` with cwd = the executable's directory; "unknown" if git fails),
// and `LabConfigFile.read` for loading a session dir's config.json (used by replay).
import Foundation

public enum BuildIdentity {
    public static func current(from exe: String = CommandLine.arguments[0]) -> [String: String] {
        let cwd = (URL(fileURLWithPath: exe).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
        func git(_ a: [String]) -> String? {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + a; p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        guard let c = git(["rev-parse", "HEAD"]) else { return ["commit": "unknown", "dirty": "unknown"] }
        return ["commit": c, "dirty": (git(["status", "--porcelain"]) ?? "").isEmpty ? "false" : "true"]
    }
}

public enum LabConfigFile {
    public static func read(dir: String) throws -> SessionConfig {
        try JSONDecoder().decode(SessionConfig.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/config.json")))
    }
}

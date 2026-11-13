// AGENT HEADER - Sources/NeveLabKit/Wire.swift
// Role: Darwin Unix-socket plumbing and line framing for Neve Lab. One JSON value per line ("\n" terminated, 16 MB cap). `LineReader` buffers reads from an fd; `writeLine` writes a whole line.
// `LabClient.request` is the only client call: connect, send one line, read one line, with a receive timeout; a timeout throws and is NEVER retried (the action may or may not have run: check `state`).
// Socket paths: `LabPaths.socket(id)` = $TMPDIR/neve-lab/<id>.sock (sun_path limit 104 bytes, checked); ids are [A-Za-z0-9_-]{1,32}.
import Foundation
import Darwin

public enum LabPaths {
    public static func validate(id: String) throws {
        guard !id.isEmpty, id.count <= 32, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw SessionError.invalid("bad id (use A-Za-z0-9_-, max 32)") }
    }
    public static func socket(id: String) throws -> String {
        try validate(id: id)
        let t = (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let p = "/\(t)/neve-lab/\(id).sock"
        guard p.utf8.count < 104 else { throw SessionError.invalid("socket path too long (set a shorter TMPDIR): \(p)") }
        return p
    }
}

func sockAddr(_ path: String) throws -> sockaddr_un {
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: a.sun_path) else { throw SessionError.invalid("socket path too long") }
    withUnsafeMutableBytes(of: &a.sun_path) { b in for (i, c) in path.utf8.enumerated() { b[i] = c }; b[path.utf8.count] = 0 }
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return a
}

func makeSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SessionError.io("socket: \(String(cString: strerror(errno)))") }
    var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

public final class LineReader {
    let fd: Int32; var buf = Data(); static let cap = 16 << 20
    public init(fd: Int32) { self.fd = fd }
    /// Next line without the newline; nil at EOF with nothing buffered. Throws .timeout on receive timeout.
    public func readLine() throws -> Data? {
        while true {
            if let i = buf.firstIndex(of: 10) { let l = buf[buf.startIndex..<i]; buf = Data(buf[(i + 1)...]); return Data(l) }
            guard buf.count < Self.cap else { throw SessionError.invalid("line too long") }
            var tmp = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &tmp, tmp.count)
            if n > 0 { buf.append(contentsOf: tmp[0..<n]) }
            else if n == 0 { if buf.isEmpty { return nil }; let l = buf; buf = Data(); return l }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { throw SessionError.timeout }
            else { throw SessionError.io("read: \(String(cString: strerror(errno)))") }
        }
    }
}

public func writeLine(_ fd: Int32, _ d: Data) throws {
    var out = d; out.append(10)
    try out.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress! + off, p.count - off)
            if n < 0 { if errno == EINTR { continue }; throw SessionError.io("write: \(String(cString: strerror(errno)))") }
            off += n
        }
    }
}

public enum LabClient {
    public static func connect(socket path: String) throws -> Int32 {
        let fd = try makeSocket(); var a = try sockAddr(path)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { let e = String(cString: strerror(errno)); close(fd); throw SessionError.io("connect \(path): \(e)") }
        return fd
    }
    public static func request(socket path: String, _ req: JSON, timeout: TimeInterval = 30) throws -> JSON {
        let fd = try connect(socket: path); defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try writeLine(fd, req.data())
        guard let line = try LineReader(fd: fd).readLine() else { throw SessionError.io("connection closed without a response") }
        return try JSON.parse(line)
    }
}

// AGENT HEADER - scripts/make-icon.swift
// Role: draws the 1024x1024 app icon PNG with CoreGraphics (superellipse squircle with ~100 pt margins, blue gradient, white six-arm snowflake with two V branches per arm).
// Usage: swift scripts/make-icon.swift out.png (CG y-up, origin bottom-left). Driven by scripts/make-icon.sh, which builds Resources/Neve.icns. Not part of the app target.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S = 1024.0
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Body: 824pt squircle (superellipse, exponent 5 approximates the continuous corner), centred: 100pt margin all round.
let r = 412.0, c = S / 2
let body = CGMutablePath()
for i in 0...720 {
    let t = Double(i) / 720 * 2 * .pi
    let ct = cos(t), st = sin(t)
    let p = CGPoint(x: c + r * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / 5), y: c + r * (st < 0 ? -1 : 1) * pow(abs(st), 2 / 5))
    i == 0 ? body.move(to: p) : body.addLine(to: p)
}
body.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(body); ctx.setFillColor(CGColor(red: 0.4, green: 0.65, blue: 0.95, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(body); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
    CGColor(red: 0.30, green: 0.58, blue: 0.96, alpha: 1), CGColor(red: 0.80, green: 0.91, blue: 1.0, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: c, y: c + r), end: CGPoint(x: c, y: c - r), options: [])
ctx.restoreGState()

// Snowflake: six arms, each with two V branches.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 0.35))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.translateBy(x: c, y: c)
let arm = 270.0
for k in 0..<6 {
    ctx.saveGState()
    ctx.rotate(by: Double(k) * .pi / 3)
    ctx.setLineWidth(34)
    ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 0, y: arm)); ctx.strokePath()
    ctx.setLineWidth(26)
    for (y, len) in [(150.0, 90.0), (225.0, 60.0)] {
        for side in [-1.0, 1.0] {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: side * len * 0.7, y: y + len * 0.7))
            ctx.strokePath()
        }
    }
    ctx.restoreGState()
}
ctx.restoreGState()

let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }

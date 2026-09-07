// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 rishabhraaj17 (Vitals fork)

// Generates this fork's brand masters, which Tools/MakeIcon.swift then turns
// into the iconset, the .icns and the menu bar glyph:
//
//   Resources/Brand/AppIcon-Default.png  the finished 1024x1024 app icon,
//                                        squircle background baked in, because
//                                        MakeIcon draws this master 1:1
//   Resources/Brand/logo.png             the bare mark on transparency. This
//                                        becomes a menu bar TEMPLATE image, so
//                                        only its alpha survives — the mark is
//                                        drawn opaque and its colour is thrown
//                                        away by the system.
//
// Run: swift Tools/MakeBrand.swift [outputDirectory]
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Brand"

// A pulse trace, in a unit box: x left to right, y with 0.5 as the baseline and
// larger values higher. Two beats would crowd the 12.5pt menu bar height, so
// this is deliberately one beat with a short lead-in and lead-out.
let pulse: [(CGFloat, CGFloat)] = [
    (0.00, 0.50), (0.22, 0.50),
    (0.30, 0.61), (0.38, 0.50),
    (0.47, 0.90), (0.55, 0.12),
    (0.63, 0.50), (0.71, 0.57),
    (0.78, 0.50), (1.00, 0.50),
]

func pulsePath(in rect: CGRect, lineWidth: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for (index, point) in pulse.enumerated() {
        let p = NSPoint(x: rect.minX + point.0 * rect.width,
                        y: rect.minY + point.1 * rect.height)
        index == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.lineWidth = lineWidth
    // Round joins keep the spike tips from growing spurs that alias badly once
    // the mark is scaled down to 16px.
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

func canvas(_ px: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)
}

func write(_ rep: NSBitmapImageRep, to name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("could not encode \(name)"); exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    do { try data.write(to: url) } catch {
        print("could not write \(url.path): \(error)"); exit(1)
    }
    print("wrote \(url.path)")
}

// MARK: - App icon

// Apple's macOS icon grid: the rounded square occupies 824 of 1024 points, with
// a 185.4 corner radius. Drawing to those numbers is what makes the icon sit at
// the same visual size as the system's own in the Dock.
func renderAppIcon() {
    let px = 1024
    guard let rep = canvas(px), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let inset: CGFloat = (1024 - 824) / 2
    let square = CGRect(x: inset, y: inset, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: square, xRadius: 185.4, yRadius: 185.4)

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.22, green: 0.71, blue: 0.94, alpha: 1),   // sky
        NSColor(srgbRed: 0.05, green: 0.29, blue: 0.51, alpha: 1),   // deep blue
    ])
    gradient?.draw(in: square, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The trace sits on the optical centre line and spans most of the width;
    // the beat's peaks stay inside the squircle's corner radius.
    let trace = CGRect(x: square.minX + 96, y: square.midY - 150,
                       width: square.width - 192, height: 300)
    NSColor.white.setStroke()
    pulsePath(in: trace, lineWidth: 46).stroke()

    NSGraphicsContext.restoreGraphicsState()
    write(rep, to: "AppIcon-Default.png")
}

// MARK: - Mark

// MakeIcon trims this to its non-transparent bounds, so the padding here only
// keeps the round caps from touching the edge. Opaque black: the menu bar
// renders it as a template and keeps nothing but the alpha.
func renderLogo() {
    let px = 1024
    guard let rep = canvas(px), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // MakeIcon sizes this glyph from a fixed 12.5pt HEIGHT and lets the width
    // follow, into a 26pt-wide canvas — so the trimmed mark must stay under
    // about 2:1 or it overflows. Trimmed bounds here are roughly 950x507
    // (1.87:1), which lands near 23pt wide with room to spare.
    let trace = CGRect(x: 72, y: 232, width: 880, height: 560)
    NSColor.black.setStroke()
    pulsePath(in: trace, lineWidth: 70).stroke()

    NSGraphicsContext.restoreGraphicsState()
    write(rep, to: "logo.png")
}

renderAppIcon()
renderLogo()

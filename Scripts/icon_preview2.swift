import AppKit

// Icon candidates v2 — pro-tool look: dark graphite squircles, and glyphs
// that represent what the app IS (a table of apps + permission states).
// Usage: swift Scripts/icon_preview2.swift <outdir>

let outdir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "design/icon-options-v3"
let px: CGFloat = CommandLine.arguments.count > 2
    ? CGFloat(Double(CommandLine.arguments[2]) ?? 512) : 512
try? FileManager.default.createDirectory(atPath: outdir, withIntermediateDirectories: true)

func save(_ img: NSImage, _ name: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: "\(outdir)/\(name).png"))
}

func squircle(_ r: NSRect, _ frac: CGFloat = 0.2237) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: r.width * frac, yRadius: r.height * frac)
}

func icon(_ name: String, top: NSColor, bottom: NSColor,
          draw: @escaping (NSRect) -> Void) {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { full in
        let r = full.insetBy(dx: px * 0.04, dy: px * 0.04)
        top.set()
        squircle(r).fill()
        draw(r)
        return true
    }
    save(img, name)
}

// MARK: shared pieces

/// One mini table row: app-icon chip, title line, status pill.
func miniRow(_ r: NSRect, chip: NSColor, pill: NSColor, textW: CGFloat) {
    let chipSide = r.height * 0.78
    squircle(NSRect(x: r.minX, y: r.minY + (r.height - chipSide) / 2,
                    width: chipSide, height: chipSide), 0.28).apply {
        chip.set(); $0.fill()
    }
    let textX = r.minX + chipSide + r.height * 0.22
    NSColor.white.withAlphaComponent(0.75).set()
    NSBezierPath(roundedRect: NSRect(x: textX, y: r.midY - r.height * 0.10,
                                     width: textW, height: r.height * 0.20),
                 xRadius: r.height * 0.10, yRadius: r.height * 0.10).fill()
    let pw = r.height * 0.95, ph = r.height * 0.42
    pill.set()
    NSBezierPath(roundedRect: NSRect(x: r.maxX - pw, y: r.midY - ph / 2,
                                     width: pw, height: ph),
                 xRadius: ph / 2, yRadius: ph / 2).fill()
}

extension NSBezierPath {
    func apply(_ f: (NSBezierPath) -> Void) { f(self) }
}

let graphite = (NSColor.black,
                NSColor.black)
let deepBlue = (NSColor.black,
                NSColor.black)
let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
let red = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
let amber = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)

// MARK: A — "the app itself": mini permission table on graphite
icon("a-mini-table", top: graphite.0, bottom: graphite.1) { r in
    let inner = r.insetBy(dx: r.width * 0.14, dy: r.height * 0.17)
    let rh = inner.height / 3 * 0.62, gap = inner.height / 3 * 0.38
    let chips: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1), // muted blue app
        NSColor(srgbRed: 0.55, green: 0.60, blue: 0.68, alpha: 1), // gray app
        NSColor(srgbRed: 0.45, green: 0.45, blue: 0.75, alpha: 1), // muted purple app
    ]
    let pills = [green, red, green]
    for i in 0..<3 {
        let y = inner.maxY - rh * (CGFloat(i) + 1) - gap * CGFloat(i)
        miniRow(NSRect(x: inner.minX, y: y, width: inner.width, height: rh),
                chip: chips[i], pill: pills[i], textW: inner.width * (0.42 - CGFloat(i) * 0.08))
    }
}

// MARK: B — permission slip: paper document with checkmarks + badge
icon("b-permission-slip", top: graphite.0, bottom: graphite.1) { r in
    let doc = r.insetBy(dx: r.width * 0.20, dy: r.height * 0.15)
    // page with subtle shadow
    NSColor.black.withAlphaComponent(0.35).set()
    squircle(doc.offsetBy(dx: 0, dy: -6), 0.10).fill()
    NSColor(srgbRed: 0.94, green: 0.94, blue: 0.92, alpha: 1).set()
    squircle(doc, 0.10).fill()
    // check + line rows
    let rowY = [0.72, 0.50, 0.28] as [CGFloat]
    let marks: [NSColor] = [green, red, green]
    for (i, fy) in rowY.enumerated() {
        let cy = doc.minY + doc.height * fy
        // circle mark
        let d = doc.height * 0.11
        let c = NSRect(x: doc.minX + doc.width * 0.10, y: cy - d / 2, width: d, height: d)
        marks[i].set()
        NSBezierPath(ovalIn: c).fill()
        // text line
        NSColor.black.withAlphaComponent(0.35).set()
        NSBezierPath(roundedRect: NSRect(x: c.maxX + doc.width * 0.07, y: cy - d * 0.24,
                                         width: doc.width * (0.52 - CGFloat(i) * 0.10), height: d * 0.48),
                     xRadius: d * 0.24, yRadius: d * 0.24).fill()
    }
}

// MARK: C — shield built from list rows (white outline, graphite bg)
icon("c-shield-list", top: deepBlue.0, bottom: deepBlue.1) { r in
    let s = r.insetBy(dx: r.width * 0.24, dy: r.height * 0.18)
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: s.midX, y: s.minY))
    shield.curve(to: NSPoint(x: s.minX, y: s.minY + s.height * 0.62),
                 controlPoint1: NSPoint(x: s.minX, y: s.minY + s.height * 0.18),
                 controlPoint2: NSPoint(x: s.minX, y: s.minY + s.height * 0.40))
    shield.line(to: NSPoint(x: s.minX, y: s.maxY - s.height * 0.12))
    shield.curve(to: NSPoint(x: s.midX, y: s.maxY),
                 controlPoint1: NSPoint(x: s.minX, y: s.maxY),
                 controlPoint2: NSPoint(x: s.midX - s.width * 0.10, y: s.maxY))
    shield.curve(to: NSPoint(x: s.maxX, y: s.maxY - s.height * 0.12),
                 controlPoint1: NSPoint(x: s.midX + s.width * 0.10, y: s.maxY),
                 controlPoint2: NSPoint(x: s.maxX, y: s.maxY))
    shield.line(to: NSPoint(x: s.maxX, y: s.minY + s.height * 0.62))
    shield.curve(to: NSPoint(x: s.midX, y: s.minY),
                 controlPoint1: NSPoint(x: s.maxX, y: s.minY + s.height * 0.40),
                 controlPoint2: NSPoint(x: s.maxX, y: s.minY + s.height * 0.18))
    shield.close()
    NSColor.white.withAlphaComponent(0.92).set()
    shield.lineWidth = s.width * 0.075
    shield.stroke()
    // three list rows inside the shield
    let rw = s.width * 0.52, rh = s.height * 0.055
    for i in 0..<3 {
        let y = s.minY + s.height * (0.60 - CGFloat(i) * 0.17)
        let x = s.midX - rw / 2
        // status dot
        [green, red, amber][i].set()
        NSBezierPath(ovalIn: NSRect(x: x, y: y - rh * 0.15, width: rh * 1.3, height: rh * 1.3)).fill()
        // line
        NSColor.white.withAlphaComponent(0.85).set()
        NSBezierPath(roundedRect: NSRect(x: x + rh * 1.9, y: y, width: rw - rh * 1.9, height: rh),
                     xRadius: rh / 2, yRadius: rh / 2).fill()
    }
}

// MARK: D — near-black "pro tool": monochrome shield-check, minimal
icon("d-mono-shield", top: NSColor.black,
     bottom: NSColor.black) { r in
    guard let glyph = NSImage(systemSymbolName: "checkmark.shield",
                              accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 300, weight: .light)) else { return }
    let k = min(r.width * 0.62 / glyph.size.width, r.height * 0.62 / glyph.size.height)
    let sz = NSSize(width: glyph.size.width * k, height: glyph.size.height * k)
    let tinted = NSImage(size: sz, flipped: false) { rr in
        glyph.draw(in: rr)
        NSColor(srgbRed: 0.85, green: 0.87, blue: 0.90, alpha: 1).set()
        rr.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2,
                           width: sz.width, height: sz.height))
}
print("wrote v2 icons to \(outdir)")

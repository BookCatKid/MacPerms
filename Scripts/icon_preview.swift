import AppKit

// Renders icon candidates: macOS-style squircle + vertical gradient + glyph.
// Usage: swift Scripts/icon_preview.swift <outdir>

let outdir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "design/icon-options"
try? FileManager.default.createDirectory(atPath: outdir, withIntermediateDirectories: true)

func save(_ img: NSImage, _ name: String) {
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: "\(outdir)/\(name).png"))
}

func squircle(_ r: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.height * 0.2237)
}

func drawSymbol(_ name: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight = .medium) {
    guard let glyph = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight)) else { return }
    let k = min(rect.width / glyph.size.width, rect.height / glyph.size.height)
    let target = NSSize(width: glyph.size.width * k, height: glyph.size.height * k)
    // Tint in a fresh context — sourceAtop against the already-drawn
    // squircle would fill the whole rect white.
    let tinted = NSImage(size: target, flipped: false) { r in
        glyph.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(x: rect.midX - target.width / 2,
                           y: rect.midY - target.height / 2,
                           width: target.width, height: target.height))
}

func icon(_ name: String, top: NSColor, bottom: NSColor,
          draw: @escaping (NSRect) -> Void) {
    let img = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { full in
        let r = full.insetBy(dx: 20, dy: 20)
        NSGradient(colors: [top, bottom])!.draw(in: squircle(r), angle: -90)
        draw(r.insetBy(dx: 60, dy: 60))
        return true
    }
    save(img, name)
}

let blue = (NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.30, blue: 0.80, alpha: 1))
let indigo = (NSColor(srgbRed: 0.50, green: 0.40, blue: 0.95, alpha: 1),
              NSColor(srgbRed: 0.30, green: 0.20, blue: 0.75, alpha: 1))
let teal = (NSColor(srgbRed: 0.15, green: 0.75, blue: 0.75, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.45, blue: 0.55, alpha: 1))
let slate = (NSColor(srgbRed: 0.45, green: 0.50, blue: 0.60, alpha: 1),
             NSColor(srgbRed: 0.20, green: 0.25, blue: 0.35, alpha: 1))
let amber = (NSColor(srgbRed: 0.95, green: 0.65, blue: 0.25, alpha: 1),
             NSColor(srgbRed: 0.80, green: 0.40, blue: 0.10, alpha: 1))

// A: shield + check — the "permission granted" motif
icon("a-shield-check", top: blue.0, bottom: blue.1) {
    drawSymbol("checkmark.shield.fill", in: $0, size: 300)
}
// B: lock — privacy/locked-down stores
icon("b-lock-shield", top: indigo.0, bottom: indigo.1) {
    drawSymbol("lock.shield.fill", in: $0, size: 300)
}
// C: key — permission grants as keys
icon("c-key", top: teal.0, bottom: teal.1) {
    drawSymbol("key.fill", in: $0, size: 280)
}
// D: checklist — the app is literally a list of consents
icon("d-checklist", top: slate.0, bottom: slate.1) {
    drawSymbol("checklist", in: $0, size: 280)
}
// E: hand raised — the macOS Privacy/consent motif
icon("e-hand", top: amber.0, bottom: amber.1) {
    drawSymbol("hand.raised.fill", in: $0, size: 300)
}
// F: toggle grid — custom-drawn, "permission switches"
icon("f-toggles", top: blue.0, bottom: blue.1) { r in
    let rowH = r.height / 3.6
    for (i, on) in [true, false, true].enumerated() {
        let y = r.maxY - rowH * (CGFloat(i) * 1.45 + 1)
        let pill = NSBezierPath(roundedRect: NSRect(x: r.minX, y: y, width: r.width, height: rowH),
                                xRadius: rowH / 2, yRadius: rowH / 2)
        NSColor.white.withAlphaComponent(0.35).set(); pill.fill()
        let d = rowH * 0.72
        let knob = NSBezierPath(ovalIn: NSRect(
            x: on ? r.maxX - d - rowH * 0.14 : r.minX + rowH * 0.14,
            y: y + rowH * 0.14, width: d, height: d))
        NSColor.white.set(); knob.fill()
    }
}
print("wrote icons to \(outdir)")

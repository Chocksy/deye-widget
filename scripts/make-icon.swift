// Renders a 1024x1024 app-icon master PNG: a yellow SF-Symbol bolt on a dark
// rounded-rect card. Usage: swift make-icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    let r = NSRect(origin: .zero, size: image.size)
    image.draw(in: r)
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Dark rounded-rect card with a subtle vertical gradient (macOS-style padding).
let inset = size * 0.06
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let card = NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
])
gradient?.draw(in: card, angle: -90)

// Yellow bolt, centered.
if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .bold)
    if let configured = bolt.withSymbolConfiguration(cfg) {
        let yellow = tinted(configured, NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.15, alpha: 1))
        let bs = yellow.size
        let scale = (size * 0.5) / max(bs.width, bs.height)
        let dw = bs.width * scale, dh = bs.height * scale
        let boltRect = NSRect(x: (size - dw) / 2, y: (size - dh) / 2, width: dw, height: dh)
        yellow.draw(in: boltRect)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to render icon\n".data(using: .utf8)!)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

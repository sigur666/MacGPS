// Renders Icons/svg/*.svg to 1024 px PNGs and an .icns per icon, plus a contact sheet.
// Usage: swift Icons/render.swift   (from the repository root)
import AppKit

let root = URL(fileURLWithPath: "Icons")
let svgDir = root.appendingPathComponent("svg")
let pngDir = root.appendingPathComponent("png")
let icnsDir = root.appendingPathComponent("icns")
let fm = FileManager.default
try? fm.createDirectory(at: pngDir, withIntermediateDirectories: true)
try? fm.createDirectory(at: icnsDir, withIntermediateDirectories: true)

func render(_ image: NSImage, size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let svgs = try fm.contentsOfDirectory(at: svgDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "svg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var images: [(String, NSImage)] = []

for svg in svgs {
    let name = svg.deletingPathExtension().lastPathComponent
    guard let img = NSImage(contentsOf: svg) else { print("Error: \(name)"); continue }
    images.append((name, img))
    try png(render(img, size: 1024), to: pngDir.appendingPathComponent("\(name).png"))

    // .iconset → .icns
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).iconset")
    try? fm.removeItem(at: set)
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try png(render(img, size: base), to: set.appendingPathComponent("icon_\(base)x\(base).png"))
        try png(render(img, size: base * 2), to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", set.path, "-o", icnsDir.appendingPathComponent("\(name).icns").path]
    try p.run(); p.waitUntilExit()
    print("✓ \(name)")
}

// Contact sheet: icons in a row, with labels, on light and dark background
let cell = 300, pad = 30
let w = images.count * cell + pad * 2, h = cell * 2 + 80
let sheet = NSImage(size: NSSize(width: w, height: h))
sheet.lockFocus()
NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: h / 2, width: w, height: h / 2).fill()
NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h / 2).fill()
for (i, (name, img)) in images.enumerated() {
    let x = pad + i * cell
    img.draw(in: NSRect(x: x + 25, y: h / 2 + 60, width: 250, height: 250))
    img.draw(in: NSRect(x: x + 25, y: 60, width: 250, height: 250))
    for (y, color) in [(h / 2 + 20, NSColor.black), (20, NSColor.white)] {
        let label = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: color])
        label.draw(at: NSPoint(x: x + 150 - Int(label.size().width) / 2, y: y))
    }
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try png(rep, to: root.appendingPathComponent("overview.png"))
print("✓ Icons/overview.png")

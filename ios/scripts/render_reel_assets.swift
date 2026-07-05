// Renders the reel's static overlays (a gradient background + one transparent
// caption card per segment) with AppKit, so ios/make_reel.sh needs no ffmpeg
// text support (this Homebrew ffmpeg ships without drawtext).
//
// Usage: swift render_reel_assets.swift <outdir> <caption1> [caption2 ...]
//        "\n" inside a caption becomes a line break. A "FitTrack" wordmark is
//        added to every caption card. Outputs bg.png and cap_01.png…cap_NN.png.

import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: render_reel_assets <outdir> <caption...>\n", stderr); exit(1) }
let outDir = args[1]
let captions = Array(args.dropFirst(2))
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let W = 1080, H = 1920

func canvas() -> (CGContext, NSBitmapImageRep) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    return (NSGraphicsContext(bitmapImageRep: rep)!.cgContext, rep)
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func font(_ path: String, _ size: CGFloat) -> NSFont {
    let url = URL(fileURLWithPath: path) as CFURL
    if let d = (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first {
        return CTFontCreateWithFontDescriptor(d, size, nil)
    }
    return NSFont.boldSystemFont(ofSize: size)
}
let fontPath = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"

// Gradient background (opaque, teal → near-black, top to bottom)
do {
    let (cg, rep) = canvas()
    let ns = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.27, blue: 0.26, alpha: 1),
                        NSColor(srgbRed: 0.03, green: 0.06, blue: 0.09, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    save(rep, "\(outDir)/bg.png")
}

let titleFont = font(fontPath, 78)
let markFont = font(fontPath, 44)

for (i, cap) in captions.enumerated() {
    let (cg, rep) = canvas()
    cg.clear(CGRect(x: 0, y: 0, width: W, height: H))
    let ns = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -3)

    let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 6
    let text = cap.replacingOccurrences(of: "\\n", with: "\n")
    NSAttributedString(string: text, attributes: [
        .font: titleFont, .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: shadow,
    ]).draw(in: NSRect(x: 60, y: H - 340, width: W - 120, height: 260))

    let mpara = NSMutableParagraphStyle(); mpara.alignment = .center
    NSAttributedString(string: "▲  FitTrack", attributes: [
        .font: markFont, .foregroundColor: NSColor(srgbRed: 0.15, green: 0.85, blue: 0.75, alpha: 1),
        .paragraphStyle: mpara, .shadow: shadow,
    ]).draw(in: NSRect(x: 0, y: 52, width: W, height: 64))

    NSGraphicsContext.restoreGraphicsState()
    save(rep, "\(outDir)/cap_\(String(format: "%02d", i + 1)).png")
}
print("OK \(captions.count) captions")

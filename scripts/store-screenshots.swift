// Composes Mac App Store screenshots (2880 × 1800, 16:10) from the preview renders.
//   swift scripts/store-screenshots.swift <renders dir> <output dir>
// Renders come from: .build/debug/Notch --render-previews <renders dir> --store
// Each screenshot: a soft background, one headline, one line under it, and the app below.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: store-screenshots.swift <renders> <out>"); exit(1) }
let renders = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let width = 2880, height = 1800
let ink = NSColor(srgbRed: 0.114, green: 0.106, blue: 0.106, alpha: 1)

struct Shot {
    let file: String          // output name
    let source: String        // render file name
    let crop: CGFloat?        // keep only the top N points of the render (notch scenes)
    let headline: String
    let line: String
}

let shots = [
    Shot(file: "1-open", source: "17-open-keeps-the-glance.png", crop: 640,
         headline: "Your day, in the notch.", line: "What you're doing now, and everything ahead in one list."),
    Shot(file: "2-glance", source: "closed", crop: nil,
         headline: "Glance. Don't switch.", line: "Up next on the left, now on the right, without opening a thing."),
    Shot(file: "3-focus", source: "02-open-focus-mode.png", crop: 640,
         headline: "Focus that means it.", line: "Pomodoro rounds. Reminders wait for the break."),
    Shot(file: "4-plan", source: "w4-planner-morning.png", crop: 780,
         headline: "Plan your day in two minutes.", line: "Pick up to three, against the time your calendar actually leaves."),
    Shot(file: "5-board", source: "w3-board.png", crop: nil,
         headline: "A board for everything else.", line: "To Do, Doing, Done, with projects, subtasks and reminders."),
]

func image(_ name: String) -> CGImage? {
    NSImage(contentsOf: renders.appendingPathComponent(name))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// The closed notch in four states, each cropped to just the black shape, with a caption.
let glances: [(file: String, caption: String)] = [
    ("16-wings-meeting-before-task.png", "The next meeting, and the card in Doing"),
    ("06-wings-late-and-meeting.png", "In a meeting, 24 minutes left"),
    ("08-wings-focus-task.png", "A focus round, with its progress line"),
    ("10-wings-break.png", "A break, with the next task waiting"),
]

/// The closed notch, cropped to the menu bar's height, with a little menu bar on each side.
/// Measured from the pixels: the camera housing at the center is black from the top edge down,
/// and the black shape's sides are the first black pixels in from the edges.
func notchPill(_ name: String) -> CGImage? {
    guard let img = image(name) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let bitmap = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    bitmap.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    func black(_ x: Int, _ y: Int) -> Bool {
        let i = (y * w + x) * 4
        return px[i] < 24 && px[i + 1] < 24 && px[i + 2] < 24
    }
    var notchHeight = 0
    while notchHeight < h && black(w / 2, notchHeight) { notchHeight += 1 }
    let row = notchHeight / 2
    guard notchHeight > 0, let left = (0..<w).first(where: { black($0, row) }),
          let right = (0..<w).reversed().first(where: { black($0, row) }) else { return nil }
    let margin = 84
    let x0 = max(0, left - margin), x1 = min(w, right + 1 + margin)
    return img.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: notchHeight))
}

func drawGlances(in ctx: CGContext) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let pills = glances.compactMap { g in notchPill(g.file).map { (pill: $0, caption: g.caption) } }
    guard let widest = pills.map({ $0.pill.width }).max(), let tallest = pills.map({ $0.pill.height }).max() else { return }
    let cellW = 1220.0, gapX = 140.0, gapY = 150.0, captionGap = 44.0, captionH = 64.0
    let scale = min(1.7, cellW / Double(widest))
    let pillH = Double(tallest) * scale
    let rowH = pillH + captionGap + captionH
    // Centered in the space under the line of text.
    let areaTop = Double(height) - 520, areaBottom = 140.0
    let blockH = rowH * 2 + gapY
    let top = (areaTop + areaBottom) / 2 + blockH / 2
    for (i, g) in pills.enumerated() {
        let col = i % 2, row = i / 2
        let cx = Double(width) / 2 + (Double(col) - 0.5) * (cellW + gapX)
        let y = top - Double(row) * (rowH + gapY)
        let size = CGSize(width: Double(g.pill.width) * scale, height: Double(g.pill.height) * scale)
        let rect = CGRect(x: cx - size.width / 2, y: y - size.height, width: size.width, height: size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.clip()
        ctx.draw(g.pill, in: rect)
        ctx.restoreGState()
        let caption = NSAttributedString(string: g.caption, attributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.72), .paragraphStyle: para,
        ])
        caption.draw(in: CGRect(x: cx - cellW / 2, y: rect.minY - captionGap - captionH, width: cellW, height: captionH))
    }
}

for shot in shots {
    var img = image(shot.source)
    if shot.source != "closed" && img == nil { print("missing \(shot.source)"); continue }
    if let crop = shot.crop, let full = img, let cut = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: min(full.height, Int(crop * 2)))) {
        img = cut
    }

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Background: soft white into a warm grey, lit from above.
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                        colors: [NSColor(srgbRed: 0.988, green: 0.988, blue: 0.992, alpha: 1).cgColor,
                                 NSColor(srgbRed: 0.918, green: 0.906, blue: 0.898, alpha: 1).cgColor] as CFArray,
                        locations: nil)!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    // Headline and line, centered near the top.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let headline = NSAttributedString(string: shot.headline, attributes: [
        .font: NSFont.systemFont(ofSize: 112, weight: .semibold), .foregroundColor: ink, .paragraphStyle: para, .kern: -2.2,
    ])
    let line = NSAttributedString(string: shot.line, attributes: [
        .font: NSFont.systemFont(ofSize: 48, weight: .regular), .foregroundColor: ink.withAlphaComponent(0.64), .paragraphStyle: para,
    ])
    headline.draw(in: CGRect(x: 120, y: height - 330, width: width - 240, height: 150))
    line.draw(in: CGRect(x: 120, y: height - 420, width: width - 240, height: 70))

    if shot.source == "closed" {
        drawGlances(in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        let url = out.appendingPathComponent("\(shot.file).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        print("wrote \(url.lastPathComponent)")
        continue
    }
    guard let img else { continue }

    // The app, as large as fits below the text, with a soft shadow.
    let area = CGRect(x: 160, y: 110, width: width - 320, height: height - 600)
    let scale = min(area.width / CGFloat(img.width), area.height / CGFloat(img.height))
    let size = CGSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
    let rect = CGRect(x: area.midX - size.width / 2, y: area.maxY - size.height, width: size.width, height: size.height)
    let clip = CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(clip)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    ctx.draw(img, in: rect)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    let url = out.appendingPathComponent("\(shot.file).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent)")
}

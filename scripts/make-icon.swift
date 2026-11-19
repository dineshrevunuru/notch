// Draws the Notch app icon.
//
//   swift scripts/make-icon.swift --explore out.png [--all]  directions side by side
//   swift scripts/make-icon.swift --style studio --icns Resources/AppIcon.icns
//
// Styles:
//   aurora       (default) one mark: the notch opening, as three stacked layers of glass on a
//                warm orange tile, with the black notch at the core
//   ember        the same mark in glowing orange on graphite
//   mono         the same mark in greys on white, with an orange dot
//   studio       the board idea, drawn the way Mac app icons are: a lit tile, a glossy
//                notch with its camera, raised cards, the Doing card glowing orange
//   studio-dark  the same on a graphite tile, with a rim light so the black notch still reads
//   focus        the notch hanging from the top edge, with the orange focus line beneath it
//   board        flat: the notch over three Kanban columns, Doing in orange
//   timer        a dark tile: the open notch above an orange Pomodoro ring
//
// Colors: soft white, warm near-black, and one warm orange (#D97757).

import AppKit

let softWhite = CGColor(srgbRed: 0.988, green: 0.988, blue: 0.992, alpha: 1)
let warmInk = CGColor(srgbRed: 0.114, green: 0.106, blue: 0.106, alpha: 1)    // #1d1b1b
let pureBlack = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
let warmOrange = CGColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757
let inkSoft = CGColor(srgbRed: 0.114, green: 0.106, blue: 0.106, alpha: 0.16)

/// macOS icon grid: an 824-point tile centered on a 1024 canvas.
let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The notch: flat top flush with the tile's top edge, rounded bottom corners.
func notchPath(centerX: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let left = centerX - width / 2, right = centerX + width / 2, bottom = top - height
    path.move(to: CGPoint(x: left, y: top))
    path.addLine(to: CGPoint(x: left, y: bottom + radius))
    path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
    path.addLine(to: CGPoint(x: right - radius, y: bottom))
    path.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
    path.addLine(to: CGPoint(x: right, y: top))
    path.closeSubpath()
    return path
}

func drawTile(_ ctx: CGContext, fill: CGColor) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(roundedPath(tile, tileRadius))
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.restoreGState()
    // A hairline edge so a white tile still reads on a white Dock.
    ctx.addPath(roundedPath(tile.insetBy(dx: 1.5, dy: 1.5), tileRadius - 1.5))
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func clipToTile(_ ctx: CGContext) {
    ctx.addPath(roundedPath(tile, tileRadius))
    ctx.clip()
}

// MARK: Studio style helpers

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: locations)!
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// Fills `path` with a vertical gradient, top color first.
func fill(_ ctx: CGContext, _ path: CGPath, top: CGColor, bottom: CGColor) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

/// A raised card: soft shadow, gradient body, a one-pixel light edge on top, placeholder lines.
func card(_ ctx: CGContext, _ rect: CGRect, top: CGColor, bottom: CGColor, shadow: CGColor, lines: CGColor, rim: CGColor) {
    let path = roundedPath(rect, 40)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: shadow)
    ctx.addPath(path)
    ctx.setFillColor(bottom)
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, path, top: top, bottom: bottom)
    // Light catching the top edge.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.addPath(roundedPath(rect.insetBy(dx: 1.5, dy: 1.5).offsetBy(dx: 0, dy: -2), 39))
    ctx.setStrokeColor(rim)
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
    // Two lines of "text" near the top, so the shape reads as a card.
    for (i, width) in [0.62, 0.40].enumerated() {
        let line = CGRect(x: rect.minX + 30, y: rect.maxY - 54 - CGFloat(i) * 34, width: (rect.width - 60) * width, height: 16)
        ctx.addPath(roundedPath(line, 8))
        ctx.setFillColor(lines)
        ctx.fillPath()
    }
}

func drawStudio(_ ctx: CGContext, dark: Bool) {
    let midX = tile.midX
    let top = tile.maxY
    let tilePath = roundedPath(tile, tileRadius)

    // Tile: lit from above.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: dark ? 0.45 : 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(dark ? rgb(0x1a1a1e) : rgb(0xeceef2))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, tilePath, top: dark ? rgb(0x34343b) : rgb(0xffffff), bottom: dark ? rgb(0x141417) : rgb(0xdfe1e7))

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // A soft glow behind the Doing card, so it sits in its own light.
    let glowCenter = CGPoint(x: midX, y: top - 450)
    ctx.drawRadialGradient(
        gradient([rgb(0xe8845f, dark ? 0.38 : 0.22), rgb(0xe8845f, 0)]),
        startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 360, options: []
    )

    // The notch: glossy black, hanging from the top edge, with its camera.
    let notch = notchPath(centerX: midX, top: top + 2, width: 420, height: 150, radius: 66)
    if dark {
        // Rim light so black still reads on graphite.
        ctx.saveGState()
        ctx.addPath(notch)
        ctx.setStrokeColor(rgb(0xffffff, 0.16))
        ctx.setLineWidth(5)
        ctx.strokePath()
        ctx.restoreGState()
    }
    fill(ctx, notch, top: rgb(0x2b2b30), bottom: rgb(0x000000))
    ctx.saveGState()
    ctx.addPath(notch)
    ctx.clip()
    let sheen = CGRect(x: midX - 150, y: top - 150 + 18, width: 300, height: 6)
    ctx.addPath(roundedPath(sheen, 3))
    ctx.setFillColor(rgb(0xffffff, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    let lens = CGPoint(x: midX, y: top - 72)
    ctx.drawRadialGradient(
        gradient([rgb(0x3b4a74), rgb(0x10131d), rgb(0x050506)], [0, 0.55, 1]),
        startCenter: CGPoint(x: lens.x - 4, y: lens.y + 4), startRadius: 0, endCenter: lens, endRadius: 20, options: []
    )
    ctx.addEllipse(in: CGRect(x: lens.x - 9, y: lens.y + 2, width: 7, height: 7))
    ctx.setFillColor(rgb(0xffffff, 0.55))
    ctx.fillPath()

    // The board: To Do, Doing (raised, orange), Done, filling the space under the notch.
    let width: CGFloat = 172, gap: CGFloat = 30
    let cardTop = top - 210
    let sideTop = dark ? rgb(0x3d3d45) : rgb(0xffffff)
    let sideBottom = dark ? rgb(0x2a2a31) : rgb(0xf1f2f6)
    let sideLines = dark ? rgb(0xffffff, 0.16) : rgb(0x1d1b1b, 0.12)
    let sideRim = dark ? rgb(0xffffff, 0.10) : rgb(0xffffff, 0.9)
    card(ctx, CGRect(x: midX - width * 1.5 - gap, y: cardTop - 380, width: width, height: 380),
         top: sideTop, bottom: sideBottom, shadow: rgb(0x000000, dark ? 0.45 : 0.14), lines: sideLines, rim: sideRim)
    card(ctx, CGRect(x: midX + width * 0.5 + gap, y: cardTop - 290, width: width, height: 290),
         top: sideTop, bottom: sideBottom, shadow: rgb(0x000000, dark ? 0.45 : 0.14), lines: sideLines, rim: sideRim)
    card(ctx, CGRect(x: midX - width / 2, y: cardTop - 470, width: width, height: 470),
         top: rgb(0xf09a78), bottom: rgb(0xcf5c3a), shadow: rgb(0xc4532f, dark ? 0.7 : 0.5), lines: rgb(0xffffff, 0.55), rim: rgb(0xffffff, 0.45))

    ctx.restoreGState()

    // Edge: a hairline, so the tile holds its shape on any wallpaper or Dock.
    ctx.addPath(roundedPath(tile.insetBy(dx: 1, dy: 1), tileRadius - 1))
    ctx.setStrokeColor(dark ? rgb(0xffffff, 0.10) : rgb(0x000000, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

// MARK: Layered styles (one idea: the notch opening, as three nested layers)

struct IconLayer {
    let width: CGFloat, height: CGFloat, radius: CGFloat
    let top: CGColor, bottom: CGColor
    let rim: CGColor
    let shadow: CGColor
}

/// One mark, drawn the way current Apple icons are: a rich gradient tile, and a single shape
/// built from stacked translucent layers. The layers are the notch's three states —
/// closed, glance, open — each hanging from the top edge.
func drawLayered(
    _ ctx: CGContext,
    tileTop: CGColor, tileBottom: CGColor,
    sheen: CGColor?, glow: CGColor?,
    layers: [IconLayer], lens: CGColor?, edge: CGColor
) {
    let midX = tile.midX
    let top = tile.maxY
    let tilePath = roundedPath(tile, tileRadius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(tileBottom)
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, tilePath, top: tileTop, bottom: tileBottom)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    if let sheen {
        // Light from the upper left, as on a physical tile.
        let center = CGPoint(x: tile.minX + 180, y: top - 60)
        let clear = sheen.copy(alpha: 0) ?? sheen
        ctx.drawRadialGradient(gradient([sheen, clear]), startCenter: center, startRadius: 0, endCenter: center, endRadius: 640, options: [])
    }
    if let glow {
        let center = CGPoint(x: midX, y: top - 180)
        let clear = glow.copy(alpha: 0) ?? glow
        ctx.drawRadialGradient(gradient([glow, clear]), startCenter: center, startRadius: 0, endCenter: center, endRadius: 560, options: [])
    }

    for layer in layers {
        let path = notchPath(centerX: midX, top: top + 6, width: layer.width, height: layer.height, radius: layer.radius)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: layer.shadow)
        ctx.addPath(path)
        ctx.setFillColor(layer.bottom)
        ctx.fillPath()
        ctx.restoreGState()
        fill(ctx, path, top: layer.top, bottom: layer.bottom)
        // The rim: light caught along the layer's edge.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.addPath(path)
        ctx.setStrokeColor(layer.rim)
        ctx.setLineWidth(7)
        ctx.strokePath()
        ctx.restoreGState()
    }

    if let lens, let core = layers.last {
        let center = CGPoint(x: midX, y: top - core.height / 2 + 4)
        let clear = lens.copy(alpha: 0) ?? lens
        ctx.drawRadialGradient(gradient([lens.copy(alpha: 0.55) ?? lens, clear]), startCenter: center, startRadius: 0, endCenter: center, endRadius: 56, options: [])
        ctx.addEllipse(in: CGRect(x: center.x - 17, y: center.y - 17, width: 34, height: 34))
        ctx.setFillColor(lens)
        ctx.fillPath()
    }
    ctx.restoreGState()

    ctx.addPath(roundedPath(tile.insetBy(dx: 1, dy: 1), tileRadius - 1))
    ctx.setStrokeColor(edge)
    ctx.setLineWidth(2)
    ctx.strokePath()
}

/// The three layer sizes shared by every layered style.
func layerSizes() -> [(width: CGFloat, height: CGFloat, radius: CGFloat)] {
    [(668, 618, 168), (492, 424, 124), (316, 226, 82)]
}

func drawAurora(_ ctx: CGContext) {
    let s = layerSizes()
    drawLayered(
        ctx,
        tileTop: rgb(0xffa574), tileBottom: rgb(0xd44a26),
        sheen: rgb(0xffffff, 0.30), glow: nil,
        layers: [
            IconLayer(width: s[0].width, height: s[0].height, radius: s[0].radius,
                      top: rgb(0xffffff, 0.14), bottom: rgb(0xffffff, 0.26), rim: rgb(0xffffff, 0.30), shadow: rgb(0x7a2208, 0.22)),
            IconLayer(width: s[1].width, height: s[1].height, radius: s[1].radius,
                      top: rgb(0xffffff, 0.26), bottom: rgb(0xffffff, 0.46), rim: rgb(0xffffff, 0.50), shadow: rgb(0x7a2208, 0.26)),
            IconLayer(width: s[2].width, height: s[2].height, radius: s[2].radius,
                      top: rgb(0x2e2e33), bottom: rgb(0x000000), rim: rgb(0xffffff, 0.10), shadow: rgb(0x000000, 0.40)),
        ],
        lens: nil, edge: rgb(0x000000, 0.10)
    )
}

func drawEmber(_ ctx: CGContext) {
    let s = layerSizes()
    drawLayered(
        ctx,
        tileTop: rgb(0x2e2e35), tileBottom: rgb(0x0a0a0c),
        sheen: rgb(0xffffff, 0.06), glow: rgb(0xe8703f, 0.42),
        layers: [
            IconLayer(width: s[0].width, height: s[0].height, radius: s[0].radius,
                      top: rgb(0xee8a62, 0.10), bottom: rgb(0xee8a62, 0.20), rim: rgb(0xffb894, 0.16), shadow: rgb(0x000000, 0.35)),
            IconLayer(width: s[1].width, height: s[1].height, radius: s[1].radius,
                      top: rgb(0xee8a62, 0.26), bottom: rgb(0xee8a62, 0.46), rim: rgb(0xffc4a4, 0.28), shadow: rgb(0x000000, 0.35)),
            IconLayer(width: s[2].width, height: s[2].height, radius: s[2].radius,
                      top: rgb(0xffb48c), bottom: rgb(0xdd5b33), rim: rgb(0xffffff, 0.40), shadow: rgb(0xe0562c, 0.75)),
        ],
        lens: nil, edge: rgb(0xffffff, 0.10)
    )
}

func drawMono(_ ctx: CGContext) {
    let s = layerSizes()
    drawLayered(
        ctx,
        tileTop: rgb(0xffffff), tileBottom: rgb(0xe4e6ec),
        sheen: nil, glow: nil,
        layers: [
            IconLayer(width: s[0].width, height: s[0].height, radius: s[0].radius,
                      top: rgb(0x1d1b1b, 0.04), bottom: rgb(0x1d1b1b, 0.09), rim: rgb(0xffffff, 0.85), shadow: rgb(0x000000, 0.08)),
            IconLayer(width: s[1].width, height: s[1].height, radius: s[1].radius,
                      top: rgb(0x1d1b1b, 0.09), bottom: rgb(0x1d1b1b, 0.18), rim: rgb(0xffffff, 0.75), shadow: rgb(0x000000, 0.12)),
            IconLayer(width: s[2].width, height: s[2].height, radius: s[2].radius,
                      top: rgb(0x2e2e33), bottom: rgb(0x000000), rim: rgb(0xffffff, 0.10), shadow: rgb(0x000000, 0.35)),
        ],
        lens: rgb(0xe8703f), edge: rgb(0x000000, 0.08)
    )
}

func draw(style: String, in ctx: CGContext) {
    let midX = tile.midX
    let top = tile.maxY
    switch style {
    case "aurora":
        drawAurora(ctx)

    case "ember":
        drawEmber(ctx)

    case "mono":
        drawMono(ctx)

    case "studio":
        drawStudio(ctx, dark: false)

    case "studio-dark":
        drawStudio(ctx, dark: true)

    case "board":
        drawTile(ctx, fill: softWhite)
        ctx.saveGState(); clipToTile(ctx)
        ctx.addPath(notchPath(centerX: midX, top: top, width: 360, height: 128, radius: 56))
        ctx.setFillColor(pureBlack); ctx.fillPath()
        // Three columns hanging below, like cards on a board; Doing in the middle, in orange.
        let columns: [(x: CGFloat, height: CGFloat, color: CGColor)] = [
            (midX - 190, 300, inkSoft), (midX, 380, warmOrange), (midX + 190, 220, inkSoft),
        ]
        for column in columns {
            let rect = CGRect(x: column.x - 70, y: top - 200 - column.height, width: 140, height: column.height)
            ctx.addPath(roundedPath(rect, 44))
            ctx.setFillColor(column.color); ctx.fillPath()
        }
        ctx.restoreGState()

    case "timer":
        drawTile(ctx, fill: warmInk)
        ctx.saveGState(); clipToTile(ctx)
        ctx.addPath(notchPath(centerX: midX, top: top, width: 420, height: 150, radius: 64))
        ctx.setFillColor(pureBlack); ctx.fillPath()
        // The Pomodoro ring, three quarters through.
        let center = CGPoint(x: midX, y: tile.minY + 330)
        ctx.setLineCap(.round)
        ctx.setLineWidth(58)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.addArc(center: center, radius: 170, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(warmOrange)
        ctx.addArc(center: center, radius: 170, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 1.5, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()

    default: // "focus"
        drawTile(ctx, fill: softWhite)
        ctx.saveGState(); clipToTile(ctx)
        ctx.addPath(notchPath(centerX: midX, top: top, width: 440, height: 168, radius: 72))
        ctx.setFillColor(pureBlack); ctx.fillPath()
        // The focus line: the same orange line that fills along the notch during a focus round.
        let track = CGRect(x: midX - 250, y: tile.minY + 300, width: 500, height: 56)
        ctx.addPath(roundedPath(track, 28))
        ctx.setFillColor(inkSoft); ctx.fillPath()
        let fill = CGRect(x: track.minX, y: track.minY, width: track.width * 0.62, height: track.height)
        ctx.addPath(roundedPath(fill, 28))
        ctx.setFillColor(warmOrange); ctx.fillPath()
        ctx.restoreGState()
    }
}

func image(style: String, size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    draw(style: style, in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

if let out = value("--explore") {
    // Each direction large, plus Dock-size and menu-size copies, since an icon has to work at 32px too.
    let styles = args.contains("--all") ? ["aurora", "ember", "mono", "studio", "studio-dark", "board", "focus", "timer"] : ["aurora", "ember", "mono"]
    let cell: CGFloat = 560, small: CGFloat = 64, tiny: CGFloat = 32
    let width = cell * CGFloat(styles.count)
    let height = cell + 120
    let ctx = CGContext(
        data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (i, style) in styles.enumerated() {
        let x = CGFloat(i) * cell
        ctx.draw(image(style: style, size: 1024), in: CGRect(x: x + 20, y: 120, width: cell - 40, height: cell - 40))
        ctx.draw(image(style: style, size: 128), in: CGRect(x: x + cell / 2 - small - 10, y: 30, width: small, height: small))
        ctx.draw(image(style: style, size: 64), in: CGRect(x: x + cell / 2 + 10, y: 46, width: tiny, height: tiny))
    }
    writePNG(ctx.makeImage()!, to: out)
    print("wrote \(out)")
} else if let icns = value("--icns") {
    let style = value("--style") ?? "aurora"
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        writePNG(image(style: style, size: base), to: set.appendingPathComponent("icon_\(base)x\(base).png").path)
        writePNG(image(style: style, size: base * 2), to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png").path)
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", set.path, "-o", icns]
    try! task.run()
    task.waitUntilExit()
    try? FileManager.default.removeItem(at: set)
    print(task.terminationStatus == 0 ? "wrote \(icns) (\(style))" : "iconutil failed")
} else {
    print("usage: make-icon.swift --explore out.png | --style focus|board|timer --icns out.icns")
}

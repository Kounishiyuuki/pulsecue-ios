// Deterministic App Store marketing composer for Pulse Cue.
// Uses the real screenshots unchanged (uniform scale only) and adds
// background, headline and subtitle. No external dependencies.
//
//   swift Scripts/AppStore/compose.swift <screenshots-root> <output-root>
//
// <screenshots-root> is the capture-app-store-screenshots.sh output root
// containing iphone-17-pro/ and iphone-17-pro-max/.

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

struct Slide {
    let source: String
    let output: String
    let headline: String
    let subtitle: String
    let accent: (CGFloat, CGFloat, CGFloat)
    /// Shrinks the screen so it ends above the canvas edge instead of
    /// bleeding off it — for screens whose bottom bar would otherwise be cut.
    var fitsWholeScreen = false
}

let blue = (CGFloat(0.37), CGFloat(0.45), CGFloat(1.0))
let violet = (CGFloat(0.58), CGFloat(0.44), CGFloat(1.0))

let slides = [
    Slide(source: "01-home.png", output: "01-home.png",
          headline: "今日を、ひと目で。",
          subtitle: "トレーニングも食事も、今日の状態をまとめて確認。", accent: blue),
    Slide(source: "02-weekly-plan.png", output: "02-weekly-plan.png",
          headline: "通うジムで、1週間のプラン。",
          subtitle: "登録した設備に合わせて、週間メニューを組み立てます。", accent: violet),
    Slide(source: "03-runner-active.png", output: "03-runner.png",
          headline: "セットに、集中できる。",
          subtitle: "回数・前回記録・休憩を、トレーニング中に確認。", accent: blue,
          fitsWholeScreen: true),
    Slide(source: "04-nutrition.png", output: "04-nutrition.png",
          headline: "食事も、同じアプリで。",
          subtitle: "カロリーとたんぱく質を記録して、今日の残りを確認。", accent: violet),
    Slide(source: "05-progress.png", output: "05-progress.png",
          headline: "続けた変化が、見える。",
          subtitle: "トレーニング回数や種目ごとの変化を振り返れます。", accent: blue),
    Slide(source: "06-my-gym.png", output: "06-my-gym.png",
          headline: "あなたのジムに、合わせる。",
          subtitle: "使えるマシンを登録して、プランに反映。", accent: violet),
]

let devices = [
    ("iphone-17-pro", 1206, 2622),
    ("iphone-17-pro-max", 1320, 2868),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fail("could not load screenshot at \(path)") }
    return image
}

func line(_ text: String, font: String, size: CGFloat, color: CGColor) -> CTLine {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: CTFontCreateWithName(font as CFString, size, nil),
        .foregroundColor: color,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
}

func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

/// Splits after the first "、" so each headline reads as two short beats.
func headlineLines(_ text: String) -> [String] {
    guard let i = text.firstIndex(of: "、") else { return [text] }
    let cut = text.index(after: i)
    return [String(text[..<cut]), String(text[cut...])]
}

func render(_ slide: Slide, device: (String, Int, Int), root: String, outRoot: String) {
    let (dir, W, H) = device
    let w = CGFloat(W), h = CGFloat(H), u = w / 1206
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("could not create \(W)x\(H) context") }

    // Background: near-white to faint lavender.
    let bg = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.973, green: 0.976, blue: 0.988, alpha: 1),
        CGColor(srgbRed: 0.925, green: 0.922, blue: 0.980, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    let (ar, ag, ab) = slide.accent
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: ar, green: ag, blue: ab, alpha: 0.20),
        CGColor(srgbRed: ar, green: ag, blue: ab, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let glowCenter = CGPoint(x: w / 2, y: h * 0.45)
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: w * 0.85, options: [])

    // Text block (CoreGraphics origin is bottom-left; y counts from the top here).
    let ink = CGColor(srgbRed: 0.078, green: 0.082, blue: 0.110, alpha: 1)
    let sub = CGColor(srgbRed: 0.357, green: 0.376, blue: 0.459, alpha: 1)
    let accentInk = CGColor(srgbRed: ar * 0.8, green: ag * 0.8, blue: ab * 0.85, alpha: 1)
    let maxText = w * 0.84

    func drawCentered(_ l: CTLine, baselineFromTop y: CGFloat) {
        ctx.textPosition = CGPoint(x: (w - width(l)) / 2, y: h - y)
        CTLineDraw(l, ctx)
    }

    var y = 190 * u
    drawCentered(line("Pulse Cue", font: "HiraginoSans-W6", size: 34 * u, color: accentInk), baselineFromTop: y)

    y += 60 * u
    let headSize = 98 * u
    for text in headlineLines(slide.headline) {
        let l = line(text, font: "HiraginoSans-W7", size: headSize, color: ink)
        if width(l) > maxText { fail("headline overflows: \(text) on \(dir)") }
        y += headSize * 1.22
        drawCentered(l, baselineFromTop: y)
    }

    var subSize = 40 * u
    var subLine = line(slide.subtitle, font: "HiraginoSans-W4", size: subSize, color: sub)
    while width(subLine) > maxText {
        subSize -= 1
        if subSize < 32 * u { fail("subtitle overflows: \(slide.subtitle) on \(dir)") }
        subLine = line(slide.subtitle, font: "HiraginoSans-W4", size: subSize, color: sub)
    }
    y += 116 * u
    drawCentered(subLine, baselineFromTop: y)

    // Screen: uniform scale, rounded, soft shadow, bleeding off the bottom edge.
    let shot = loadImage("\(root)/\(dir)/\(slide.source)")
    let aspect = CGFloat(shot.height) / CGFloat(shot.width)
    var top = max(y + 80 * u, h * 0.27)
    var sw = w * 0.80
    if slide.fitsWholeScreen {
        top = y + 70 * u
        sw = (h - top - 90 * u) / aspect
    }
    let sh = sw * aspect
    let rect = CGRect(x: (w - sw) / 2, y: h - top - sh, width: sw, height: sh)
    let path = CGPath(roundedRect: rect, cornerWidth: 64 * u, cornerHeight: 64 * u, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * u), blur: 70 * u,
                  color: CGColor(srgbRed: 0.10, green: 0.10, blue: 0.25, alpha: 0.28))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.06, blue: 0.07, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(shot, in: rect)
    ctx.restoreGState()

    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10))
    ctx.setLineWidth(2 * u)
    ctx.strokePath()

    let outDir = "\(outRoot)/\(dir)"
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let url = URL(fileURLWithPath: "\(outDir)/\(slide.output)")
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not prepare \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fail("could not write \(url.path)") }
    print("wrote \(url.path)")
}

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: swift compose.swift <screenshots-root> <output-root>") }
for device in devices {
    for slide in slides { render(slide, device: device, root: args[1], outRoot: args[2]) }
}

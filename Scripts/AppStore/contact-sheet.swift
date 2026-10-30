// Lays the six marketing images side by side for a series check.
//
//   swift Scripts/AppStore/contact-sheet.swift <device-dir> <output.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: swift contact-sheet.swift <device-dir> <output.png>"); exit(1) }
let names = ["01-home", "02-weekly-plan", "03-runner", "04-nutrition", "05-progress", "06-my-gym"]
let images: [CGImage] = names.map { name in
    let url = URL(fileURLWithPath: "\(args[1])/\(name).png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { print("could not load \(url.path)"); exit(1) }
    return image
}

let tileW = 440, tileH = tileW * images[0].height / images[0].width, gap = 40
let W = gap + names.count * (tileW + gap), H = tileH + 2 * gap
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.interpolationQuality = .high
for (i, image) in images.enumerated() {
    ctx.draw(image, in: CGRect(x: gap + i * (tileW + gap), y: gap, width: tileW, height: tileH))
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { print("could not write \(args[2])"); exit(1) }
print("wrote \(args[2])")

// The fixtures 0.2.0's golden check adds (AB-T-0377), made from fox-256.png so they can be rebuilt:
//   fox-grey-256.png       colorize's input (luma only)
//   fox-dark-256.png       relight's input (a quarter of the exposure, so CIDNet's luma gate lets it through)
//   fox-scratched-256.png  defect detection's input (grey, with thin white scratches)
//   sign-256.png           the fox with a line of large text, so the text guard protects words (Nacre)
//
//   swift scripts/make-fixtures.swift scripts/fixtures
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let src = CGImageSourceCreateWithURL(dir.appending(path: "fox-256.png") as CFURL, nil)!
let fox = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = fox.width, h = fox.height
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func context() -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}
func write(_ image: CGImage, _ name: String) {
    let dest = CGImageDestinationCreateWithURL(dir.appending(path: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
}
func pixels(_ transform: (inout UInt8, inout UInt8, inout UInt8) -> Void) -> CGContext {
    let ctx = context()
    ctx.draw(fox, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
        for x in 0..<w {
            let i = y * ctx.bytesPerRow + x * 4
            transform(&p[i], &p[i + 1], &p[i + 2])
        }
    }
    return ctx
}

let grey = pixels { r, g, b in
    let l = UInt8((0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)).rounded())
    r = l; g = l; b = l
}
write(grey.makeImage()!, "fox-grey-256.png")
write(pixels { r, g, b in r /= 4; g /= 4; b /= 4 }.makeImage()!, "fox-dark-256.png")

grey.setStrokeColor(CGColor(gray: 0.97, alpha: 1))
grey.setLineWidth(1.5)
for (a, b) in [((20.0, 230.0), (150.0, 40.0)), ((90.0, 250.0), (240.0, 150.0)), ((10.0, 60.0), (250.0, 90.0))] {
    grey.move(to: CGPoint(x: a.0, y: a.1)); grey.addLine(to: CGPoint(x: b.0, y: b.1))
}
grey.strokePath()
write(grey.makeImage()!, "fox-scratched-256.png")

let sign = context()
sign.draw(fox, in: CGRect(x: 0, y: 0, width: w, height: h))
sign.setFillColor(CGColor(gray: 1, alpha: 1))
sign.fill(CGRect(x: 8, y: 8, width: w - 16, height: 64))
NSGraphicsContext.current = NSGraphicsContext(cgContext: sign, flipped: false)
NSAttributedString(string: "OPEN DAILY 9 TO 5", attributes: [.font: NSFont.boldSystemFont(ofSize: 22),
                                                            .foregroundColor: NSColor.black])
    .draw(at: CGPoint(x: 18, y: 26))
write(sign.makeImage()!, "sign-256.png")

// Builds assets/demo/swipes.gif from SillyTavern screenshots (800x600 view):
// three swipes of one turn, then the same turn with its rulings unfolded
// (a file whose name contains "rulings").
//
// Usage: swift scripts/demo/swipes_gif.swift out.gif swipe1.jpg swipe2.jpg swipe3.jpg rulings.jpg

import Foundation
import ImageIO
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let inputs = Array(args[2...])
let title = "같은 공격 장면을 세 번 스와이프 (SillyTavern + Aethrion)"
let sub = "서술은 매번 새로 쓰이고, 숫자와 주사위 판정은 그대로"
let crop = CGRect(x: 236, y: 22, width: 372, height: 552)   // the chat column, in 800x600 points
let scale: CGFloat = 2
let header: CGFloat = 70

func text(_ ctx: CGContext, _ s: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ alpha: CGFloat) {
  let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, size, nil)
  let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: alpha)]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
  ctx.textPosition = CGPoint(x: x, y: y)
  CTLineDraw(line, ctx)
}

let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, inputs.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (i, path) in inputs.enumerated() {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let k = CGFloat(img.width) / 800
  let piece = img.cropping(to: CGRect(x: crop.minX * k, y: crop.minY * k, width: crop.width * k, height: crop.height * k))!
  let w = Int(crop.width * scale), h = Int((crop.height + header) * scale)
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.interpolationQuality = .high
  ctx.draw(piece, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: crop.height * scale))
  text(ctx, title, 13 * scale, 12 * scale, CGFloat(h) - 26 * scale, 1)
  text(ctx, sub, 11 * scale, 12 * scale, CGFloat(h) - 46 * scale, 0.75)
  let label = path.contains("rulings") ? "펼치면: 이번 턴 판정" : "스와이프 \(i + 1)/\(inputs.count - 1)"
  text(ctx, label, 11 * scale, CGFloat(w) - (path.contains("rulings") ? 122 : 86) * scale, CGFloat(h) - 64 * scale, 0.9)
  CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: path.contains("rulings") ? 4.0 : 2.6]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("wrote", out.path)

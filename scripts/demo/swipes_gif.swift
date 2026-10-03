// Builds the demo GIFs from window captures taken at the display's own
// pixel density: one turn rerolled three times, then the same turn with its
// rulings unfolded (a file whose name contains "rulings"). Frames are
// cropped, never resampled, so the text stays sharp. The captures come from
// the RisuAI desktop app (`screencapture -l <window id>`) or from
// SillyTavern (scripts/demo/st_capture.mjs).
//
// Usage: swift scripts/demo/swipes_gif.swift out.gif reroll1.png reroll2.png reroll3.png rulings.png
//
// The captions are Korean by default; TITLE, SUB, CREDIT (a third, smaller
// line, for a card's author and license), REROLL ("Reroll"), UNFOLDED, and
// KEEP (pixels kept from the bottom of each capture) change them.

import Foundation
import ImageIO
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let inputs = Array(args[2...])
let env = ProcessInfo.processInfo.environment
let title = env["TITLE"] ?? "같은 턴을 세 번 리롤 (RisuAI + Aethrion)"
let sub = env["SUB"] ?? "서술은 매번 새로 쓰이고, 숫자와 주사위 판정은 그대로"
let credit = env["CREDIT"] ?? ""
let rerollWord = env["REROLL"] ?? "리롤"
let unfolded = env["UNFOLDED"] ?? "펼치면: 이번 턴 판정"
let keep = Int(env["KEEP"] ?? "") ?? 1560   // pixels kept from the bottom of the window: the end of the reply and the status window
let header = credit == "" ? 150 : 196       // pixels for the caption above it
let fade = 120       // pixels over which the cut-off top of the reply fades in

func text(_ ctx: CGContext, _ s: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, _ alpha: CGFloat, right: Bool = false) {
  let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, size, nil)
  let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: alpha)]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
  let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  ctx.textPosition = CGPoint(x: right ? x - width : x, y: y)
  CTLineDraw(line, ctx)
}

let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, inputs.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for (i, path) in inputs.enumerated() {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let w = img.width, h = keep + header
  let piece = img.cropping(to: CGRect(x: 0, y: img.height - keep, width: w, height: keep))!
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  // The chat's background: the most common colour along the row where the
  // capture is cut.
  var row = [UInt8](repeating: 0, count: 4 * w)
  let strip = CGContext(data: &row, width: w, height: 1, bitsPerComponent: 8, bytesPerRow: 4 * w, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  strip.interpolationQuality = .none
  strip.draw(img.cropping(to: CGRect(x: 0, y: img.height - keep, width: w, height: 1))!, in: CGRect(x: 0, y: 0, width: w, height: 1))
  var seen: [UInt32: Int] = [:]
  for x in 0..<w { seen[UInt32(row[4 * x]) << 16 | UInt32(row[4 * x + 1]) << 8 | UInt32(row[4 * x + 2]), default: 0] += 1 }
  let common = seen.max { $0.value < $1.value }!.key
  let bg = CGColor(red: CGFloat((common >> 16) & 255) / 255, green: CGFloat((common >> 8) & 255) / 255, blue: CGFloat(common & 255) / 255, alpha: 1)
  ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.interpolationQuality = .none
  ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: keep))
  // The reply is cut mid-scroll: fade its top into the background, in bands
  // so the palette stays small.
  let bands = 9
  for b in 0..<bands {
    ctx.setFillColor(bg.copy(alpha: 1 - CGFloat(b) / CGFloat(bands))!)
    ctx.fill(CGRect(x: 0, y: keep - (b + 1) * fade / bands, width: w, height: fade / bands))
  }
  ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1))
  ctx.fill(CGRect(x: 0, y: keep, width: w, height: header))
  let rulings = path.contains("rulings")
  text(ctx, title, 40, 40, CGFloat(h) - 66, 1)
  text(ctx, sub, 30, 40, CGFloat(h) - 118, 0.72)
  if credit != "" { text(ctx, credit, 24, 40, CGFloat(h) - 164, 0.5) }
  text(ctx, rulings ? unfolded : "\(rerollWord) \(i + 1)/\(inputs.count - 1)", 30, CGFloat(w) - 40, CGFloat(h) - 66, 0.95, right: true)
  CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: rulings ? 5.0 : 3.0]] as CFDictionary)
}
CGImageDestinationFinalize(dest)
print("wrote", out.path)

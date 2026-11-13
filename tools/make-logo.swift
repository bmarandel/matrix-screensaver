// Rend le glyphe Apple (U+F8FF, police système macOS) en art ASCII « demi-blocs » ▀▄█.
// Usage : swift tools/make-logo.swift [colonnes] > Resources/logo.txt
import AppKit
let cols = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 44
let s = "\u{F8FF}" as NSString
let font = NSFont.systemFont(ofSize: 400)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: s as String, attributes: attrs))
let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let W = cols, H = Int((Double(cols) * b.height / b.width).rounded()) // pixels carrés = 1 col × ½ ligne
let rows = (H + 1) / 2
let ctx = CGContext(data: nil, width: W, height: rows * 2, bitsPerComponent: 8, bytesPerRow: W,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: rows * 2))
let k = CGFloat(W) / b.width
ctx.scaleBy(x: k, y: k)
ctx.translateBy(x: -b.minX, y: -b.minY + (CGFloat(rows * 2 - H) / 2) / k)
ctx.setFillColor(gray: 1, alpha: 1)
ctx.textPosition = .zero
CTLineDraw(line, ctx)
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
func on(_ x: Int, _ y: Int) -> Bool { px[y * W + x] > 110 } // y=0 en haut
var out = ""
for r in 0..<rows {
  var l = ""
  for x in 0..<W {
    switch (on(x, 2 * r), on(x, 2 * r + 1)) {
    case (true, true): l += "█"; case (true, false): l += "▀"
    case (false, true): l += "▄"; default: l += " " }
  }
  while l.hasSuffix(" ") { l.removeLast() }
  out += l + "\n"
}
print(out, terminator: "")

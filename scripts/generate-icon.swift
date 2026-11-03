#!/usr/bin/env swift
// Generates the AppIcon.appiconset PNGs.
//
// Same composition as macOS's iPhone Mirroring icon — a dark phone behind, a
// frosted light phone in front showing a home screen — recoloured for Android:
// an Android-green backdrop, round launcher icons, and a punch-hole camera.
//
// Run:  swift scripts/generate-icon.swift
// Out:  App/Resources/Assets.xcassets/AppIcon.appiconset/

import AppKit
import CoreGraphics
import Foundation

let outDir = URL(fileURLWithPath: "App/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let pngs: [Int] = [16, 32, 64, 128, 256, 512, 1024]

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
  CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// macOS icon squircle: a superellipse, which is what the continuous-corner
/// app icon shape approximates.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
  let path = CGMutablePath()
  let a = rect.width / 2, b = rect.height / 2
  let cx = rect.midX, cy = rect.midY
  let steps = 360
  for i in 0...steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let c = cos(t), s = sin(t)
    let x = cx + a * copysign(pow(abs(c), 2 / n), c)
    let y = cy + b * copysign(pow(abs(s), 2 / n), s)
    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
  }
  path.closeSubpath()
  return path
}

/// Rect in a 1024-pt design space with a top-left origin, flipped into CG.
func design(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
  CGRect(x: x, y: 1024 - y - h, width: w, height: h)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
  let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil)!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024 - top), end: CGPoint(x: 0, y: 1024 - bottom), options: [])
}

func drawIcon(_ pixels: Int) -> Data? {
  guard let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }
  ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
  ctx.setShouldAntialias(true)

  // macOS icon grid: the 824-pt squircle sits centred on the 1024 canvas with a
  // soft drop shadow; everything below is drawn in a 1024 space scaled into it.
  let tile = squircle(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
  ctx.saveGState()
  ctx.translateBy(x: 100, y: 100 + 8)
  ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0, 0, 0, 0.28))
  ctx.addPath(tile); ctx.setFillColor(rgb(40, 190, 120)); ctx.fillPath()
  ctx.restoreGState()

  // 1. Backdrop (tile space): light mint at the top to Android green below.
  ctx.saveGState()
  ctx.translateBy(x: 100, y: 100 + 8)
  ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
  ctx.saveGState()
  ctx.addPath(tile); ctx.clip()
  linear(ctx, [rgb(150, 238, 186), rgb(61, 220, 132), rgb(18, 160, 110)], from: 0, to: 1024)
  // Soft top glow, like the lit glass edge on the system icon.
  let glow = CGGradient(colorsSpace: nil, colors: [rgb(255, 255, 255, 0.35), rgb(255, 255, 255, 0)] as CFArray, locations: nil)!
  ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 1060), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 1060), endRadius: 620, options: [])
  ctx.restoreGState()

  // Glass rim.
  ctx.saveGState()
  ctx.addPath(squircle(in: CGRect(x: 6, y: 6, width: 1012, height: 1012)))
  ctx.setStrokeColor(rgb(255, 255, 255, 0.45)); ctx.setLineWidth(10); ctx.strokePath()
  ctx.restoreGState()
  ctx.restoreGState()

  // Phones are laid out on the full 1024 canvas, matching the system icon.

  // 2. Back phone: dark, slightly green-tinted, behind and to the left.
  let back = design(306, 200, 270, 514)
  let backPath = CGPath(roundedRect: back, cornerWidth: 50, cornerHeight: 50, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0, 40, 20, 0.35))
  ctx.addPath(backPath); ctx.setFillColor(rgb(24, 44, 40)); ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(backPath); ctx.clip()
  linear(ctx, [rgb(30, 52, 48), rgb(22, 40, 44)], from: 200, to: 714)
  ctx.restoreGState()
  ctx.addPath(CGPath(roundedRect: back.insetBy(dx: 3, dy: 3), cornerWidth: 47, cornerHeight: 47, transform: nil))
  ctx.setStrokeColor(rgb(255, 255, 255, 0.16)); ctx.setLineWidth(5); ctx.strokePath()

  // 3. Front phone: frosted white, overlapping to the right.
  let front = design(446, 306, 270, 512)
  let frontPath = CGPath(roundedRect: front, cornerWidth: 54, cornerHeight: 54, transform: nil)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0, 50, 25, 0.35))
  ctx.addPath(frontPath); ctx.setFillColor(rgb(244, 250, 247)); ctx.fillPath()
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(frontPath); ctx.clip()
  linear(ctx, [rgb(255, 255, 255), rgb(236, 247, 241), rgb(222, 240, 232)], from: 306, to: 818)
  ctx.restoreGState()
  ctx.addPath(CGPath(roundedRect: front.insetBy(dx: 3, dy: 3), cornerWidth: 51, cornerHeight: 51, transform: nil))
  ctx.setStrokeColor(rgb(255, 255, 255, 0.9)); ctx.setLineWidth(6); ctx.strokePath()
  ctx.addPath(frontPath)
  ctx.setStrokeColor(rgb(20, 90, 60, 0.18)); ctx.setLineWidth(2); ctx.strokePath()

  // Punch-hole camera — the Android tell.
  ctx.setFillColor(rgb(34, 46, 44))
  ctx.fillEllipse(in: design(446 + 135 - 9, 306 + 22, 18, 18))

  // Round launcher icons: three rows (3, 3, 2) and a dock of three.
  let icon: CGFloat = 52, pitch: CGFloat = 68
  let left: CGFloat = 446 + (270 - (2 * pitch + icon)) / 2
  ctx.setFillColor(rgb(196, 208, 204))
  for (row, count) in [3, 3, 2].enumerated() {
    for col in 0..<count {
      ctx.fillEllipse(in: design(left + CGFloat(col) * pitch, 370 + CGFloat(row) * pitch, icon, icon))
    }
  }
  ctx.setFillColor(rgb(178, 194, 189))
  for col in 0..<3 {
    ctx.fillEllipse(in: design(left + CGFloat(col) * pitch, 730, icon, icon))
  }

  guard let image = ctx.makeImage() else { return nil }
  return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for px in pngs {
  guard let data = drawIcon(px) else { fatalError("render \(px) failed") }
  let url = outDir.appendingPathComponent("icon_\(px).png")
  try data.write(to: url)
  print("wrote \(url.lastPathComponent)")
}

// Contents.json — point sizes × density to filenames.
let entries: [(String, String, Int)] = [
  ("16x16", "1x", 16), ("16x16", "2x", 32),
  ("32x32", "1x", 32), ("32x32", "2x", 64),
  ("128x128", "1x", 128), ("128x128", "2x", 256),
  ("256x256", "1x", 256), ("256x256", "2x", 512),
  ("512x512", "1x", 512), ("512x512", "2x", 1024),
]
let images = entries.map { size, scale, px in
  ["filename": "icon_\(px).png", "idiom": "mac", "scale": scale, "size": size]
}
let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")

// Measures WCAG contrast in a rendered screenshot, so "is that label readable" is answered
// with a number instead of an opinion.
//
//   swift Tools/measure_contrast.swift docs/ui-dark.png "section header" 780 74 60 10 ...
//
// Each region is given as a label and a rect in pixels. The lightest and darkest pixels found
// inside it are taken as the background and the text, which is the practical way to measure
// antialiased glyphs. Written for a UI/UX audit and kept because
// a contrast claim that cannot be re-measured is a claim with a shelf life.

import AppKit

// contrast <png> [label x y w h]...
// For each region: the extreme light and dark pixels are taken as background and text,
// and the WCAG 2.x contrast ratio between them is printed.
func luminance(_ c: NSColor) -> Double {
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
}

let a = CommandLine.arguments
guard let img = NSImage(contentsOfFile: a[1]),
      let rep = img.representations.first as? NSBitmapImageRep else { exit(1) }

var i = 2
while i + 4 < a.count {
    let label = a[i]
    let x0 = Int(a[i+1])!, y0 = Int(a[i+2])!, w = Int(a[i+3])!, h = Int(a[i+4])!
    i += 5
    var lo = 2.0, hi = -1.0
    var loC = NSColor.black, hiC = NSColor.white
    for x in x0..<min(x0+w, rep.pixelsWide) {
        for y in y0..<min(y0+h, rep.pixelsHigh) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let l = luminance(c)
            if l < lo { lo = l; loC = c }
            if l > hi { hi = l; hiC = c }
        }
    }
    let ratio = (hi + 0.05) / (lo + 0.05)
    func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255))
    }
    print(String(format: "%-26@  %@ on %@   ratio %.2f:1  %@",
                 label as NSString, hex(hiC) as NSString, hex(loC) as NSString, ratio,
                 (ratio >= 4.5 ? "pass" : ratio >= 3 ? "large/non-text only" : "FAIL") as NSString))
}

import Foundation
import AppKit
import CoreText

func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

// Outline a string to an SVG path `d` (baseline at y=0, x starts at 0, y-down),
// returning the path data and the true ink max-x (rightmost point actually drawn).
func outline(_ text: String, font: NSFont, kern: CGFloat) -> (String, CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: kern]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    var d = ""
    var maxX: CGFloat = 0
    func track(_ x: CGFloat) { if x > maxX { maxX = x } }
    for run in runs {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
        CTRunGetPositions(run, CFRangeMake(0, n), &pos)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
        for i in 0..<n {
            guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            let ox = pos[i].x, oy = pos[i].y
            gp.applyWithBlock { ep in
                let e = ep.pointee
                let p = e.points
                switch e.type {
                case .moveToPoint:
                    d += "M\(f(ox+p[0].x)) \(f(-(oy+p[0].y)))"; track(ox+p[0].x)
                case .addLineToPoint:
                    d += "L\(f(ox+p[0].x)) \(f(-(oy+p[0].y)))"; track(ox+p[0].x)
                case .addQuadCurveToPoint:
                    d += "Q\(f(ox+p[0].x)) \(f(-(oy+p[0].y))) \(f(ox+p[1].x)) \(f(-(oy+p[1].y)))"; track(ox+p[0].x); track(ox+p[1].x)
                case .addCurveToPoint:
                    d += "C\(f(ox+p[0].x)) \(f(-(oy+p[0].y))) \(f(ox+p[1].x)) \(f(-(oy+p[1].y))) \(f(ox+p[2].x)) \(f(-(oy+p[2].y)))"; track(ox+p[0].x); track(ox+p[1].x); track(ox+p[2].x)
                case .closeSubpath:
                    d += "Z"
                @unknown default: break
                }
            }
        }
    }
    return (d, maxX)
}

let titleFont = NSFont.systemFont(ofSize: 150, weight: .heavy)
let descFont  = NSFont(name: "Menlo-Bold", size: 30) ?? NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold)

let (titleD, titleMaxX) = outline("Trace", font: titleFont, kern: -3)
let (descD,  descMaxX)  = outline("XRK \u{2192} CSV \u{00B7} for RaceChrono", font: descFont, kern: 0.5)

let xTitle: CGFloat = 336, yTitle: CGFloat = 206
let xDesc: CGFloat  = 340, yDesc: CGFloat  = 256
// viewBox width from the true rightmost ink of either line, plus a right margin
// matching the ~41px tile→text gap so the lockup is visually balanced.
let vbW = Int(ceil(max(xTitle + titleMaxX, xDesc + descMaxX) + 41))

let tile = """
  <defs>
    <linearGradient id="wbg" x1="512" y1="100" x2="512" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#272C34"/><stop offset="0.55" stop-color="#14181D"/><stop offset="1" stop-color="#090B0E"/>
    </linearGradient>
    <linearGradient id="wtr" x1="175" y1="812" x2="858" y2="238" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFC24A"/><stop offset="0.5" stop-color="#FF7A1A"/><stop offset="1" stop-color="#FF3D2E"/>
    </linearGradient>
    <radialGradient id="wdot" cx="470" cy="812" r="60" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.55" stop-color="#FFE9C2"/><stop offset="1" stop-color="#FFB84D"/>
    </radialGradient>
    <clipPath id="wsq"><rect x="100" y="100" width="824" height="824" rx="190" ry="190"/></clipPath>
  </defs>
  <g transform="translate(3.45,18.45) scale(0.3155)">
    <rect x="100" y="100" width="824" height="824" rx="190" ry="190" fill="url(#wbg)"/>
    <g clip-path="url(#wsq)">
      <path d="M 157,554 C 232,699 337,766 452,766 C 587,766 682,499 840,192" fill="none" stroke="#8FA6C0" stroke-opacity="0.28" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M 175,600 C 250,745 355,812 470,812 C 605,812 700,545 858,238" fill="none" stroke="url(#wtr)" stroke-width="82" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="470" cy="812" r="36" fill="url(#wdot)"/>
      <circle cx="470" cy="812" r="36" fill="none" stroke="#FFFFFF" stroke-opacity="0.9" stroke-width="4"/>
    </g>
    <rect x="101.5" y="101.5" width="821" height="821" rx="188.5" ry="188.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.10" stroke-width="3"/>
  </g>
"""

func svg(titleFill: String, descFill: String, note: String) -> String {
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(vbW)" height="360" viewBox="0 0 \(vbW) 360" role="img" aria-label="Trace — XRK to CSV for RaceChrono">
      <!-- \(note) Text is outlined to vector paths (SF Pro Heavy + Menlo) — no font dependency. -->
    \(tile)
      <path transform="translate(\(f(xTitle)),\(f(yTitle)))" d="\(titleD)" fill="\(titleFill)"/>
      <path transform="translate(\(f(xDesc)),\(f(yDesc)))" d="\(descD)" fill="\(descFill)"/>
    </svg>

    """
}

// <repo>/branding, resolved from this script's own location (portable).
let base = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()          // scripts/
    .deletingLastPathComponent()          // repo root
    .appendingPathComponent("branding").path
try svg(titleFill: "#14181D", descFill: "#5A6470", note: "Light background (dark text).")
    .write(toFile: "\(base)/trace-wordmark.svg", atomically: true, encoding: .utf8)
try svg(titleFill: "#F2F4F7", descFill: "#9AA6B2", note: "Dark background (light text).")
    .write(toFile: "\(base)/trace-wordmark-dark.svg", atomically: true, encoding: .utf8)

FileHandle.standardError.write("title maxX=\(f(titleMaxX)) desc maxX=\(f(descMaxX)) descRight=\(f(xDesc+descMaxX)) viewBox=\(vbW)x360\n".data(using: .utf8)!)
print("wrote trace-wordmark.svg + trace-wordmark-dark.svg")

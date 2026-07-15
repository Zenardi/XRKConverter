import SwiftUI

// The "Trace" visual identity, in code. Carbon instrument-panel ground + a single
// amber→red heat accent, SF Pro for display and SF Mono for every telemetry-style
// readout. Deliberately a committed dark world (matches the app icon / brand board).
enum Trace {
    // Carbon neutrals
    static let carbon0     = Color(red: 0.039, green: 0.047, blue: 0.059) // #0A0C0F  window
    static let carbon1     = Color(red: 0.078, green: 0.094, blue: 0.114) // #14181D  panel
    static let carbon2     = Color(red: 0.110, green: 0.129, blue: 0.153) // #1C2127  raised
    static let carbon3     = Color(red: 0.153, green: 0.173, blue: 0.204) // #272C34  tile top
    static let carbonDeep  = Color(red: 0.035, green: 0.043, blue: 0.055) // #090B0E  tile bottom

    // Ink
    static let ink      = Color(red: 0.933, green: 0.945, blue: 0.957) // #EEF1F4
    static let inkDim   = Color(red: 0.604, green: 0.651, blue: 0.698) // #9AA6B2
    static let inkFaint = Color(red: 0.361, green: 0.404, blue: 0.451) // #5C6773

    // Hairlines
    static let line       = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.16)

    // Heat accent + semantics
    static let amber  = Color(red: 1.000, green: 0.761, blue: 0.290) // #FFC24A
    static let orange = Color(red: 1.000, green: 0.478, blue: 0.102) // #FF7A1A
    static let red    = Color(red: 1.000, green: 0.239, blue: 0.180) // #FF3D2E
    static let steel  = Color(red: 0.561, green: 0.651, blue: 0.753) // #8FA6C0 (the "ghost" trace)
    static let good   = Color(red: 0.204, green: 0.827, blue: 0.600) // #34D399

    static let heat = LinearGradient(colors: [amber, orange, red],
                                     startPoint: .leading, endPoint: .trailing)
    static let heatDiag = LinearGradient(colors: [amber, orange, red],
                                         startPoint: .bottomLeading, endPoint: .topTrailing)
    static let tileFill = LinearGradient(colors: [carbon3, carbon1, carbonDeep],
                                         startPoint: .top, endPoint: .bottom)

    // Type roles
    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

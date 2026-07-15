import SwiftUI

// MARK: - The mark, drawn live (same bezier as the app icon)

/// The racing line clipping the apex — mapped from the icon's 824-unit inner box.
struct TraceMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 824, sy = rect.height / 824
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 100) * sx, y: rect.minY + (y - 100) * sy)
        }
        var path = Path()
        path.move(to: p(175, 600))
        path.addCurve(to: p(470, 812), control1: p(250, 745), control2: p(355, 812))
        path.addCurve(to: p(858, 238), control1: p(605, 812), control2: p(700, 545))
        return path
    }
}

/// The faint "ghost" trace (raw XRK before conversion).
struct TraceGhost: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 824, sy = rect.height / 824
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 100) * sx, y: rect.minY + (y - 100) * sy)
        }
        var path = Path()
        path.move(to: p(157, 554))
        path.addCurve(to: p(452, 766), control1: p(232, 699), control2: p(337, 766))
        path.addCurve(to: p(840, 192), control1: p(587, 766), control2: p(682, 499))
        return path
    }
}

/// The app-icon tile, in-app. `trim` (0…1) draws the heat trace — pass a progress
/// value to make it a live telemetry plot; leave at 1 to show the finished logo.
struct TraceTile: View {
    var size: CGFloat = 52
    var trim: CGFloat = 1
    var body: some View {
        let corner = size * 0.2255
        let apexT = min(max((trim - 0.30) / 0.10, 0), 1) // dot arrives as the line clips the apex
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Trace.tileFill)
            TraceGhost().stroke(Trace.steel.opacity(0.28),
                                style: StrokeStyle(lineWidth: size * 0.036, lineCap: .round, lineJoin: .round))
            TraceMark().trim(from: 0, to: trim).stroke(Trace.heatDiag,
                                style: StrokeStyle(lineWidth: size * 0.100, lineCap: .round, lineJoin: .round))
            Circle().fill(.white)
                .frame(width: size * 0.088, height: size * 0.088)
                .overlay(Circle().stroke(Trace.amber.opacity(0.65), lineWidth: size * 0.014))
                .shadow(color: Trace.amber.opacity(0.6), radius: size * 0.05)
                .position(x: (470 - 100) * size / 824, y: (812 - 100) * size / 824)
                .opacity(apexT)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: max(1, size * 0.01))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Backgrounds

struct HUDBackground: View {
    var body: some View {
        ZStack {
            Trace.carbon0
            Canvas { ctx, size in
                let step: CGFloat = 32
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(path, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
            RadialGradient(colors: [Trace.orange.opacity(0.10), .clear],
                           center: .top, startRadius: 0, endRadius: 440)
        }
        .ignoresSafeArea()
    }
}

// MARK: - A branded determinate progress: heat bar with a glowing apex head

struct HeatProgress: View {
    var value: Double
    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, value)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Trace.carbon2)
                Capsule().fill(Trace.heat).frame(width: w)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .shadow(color: Trace.orange.opacity(0.85), radius: 6)
                    .offset(x: min(max(w - 6, -6), geo.size.width - 6))
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Chips + panels

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Trace.mono(10.5, .semibold)).tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

extension View {
    /// Standard carbon card: fill, hairline border, padding.
    func tracePanel(border: Color = Trace.line) -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Trace.carbon1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - Buttons (custom so the heat accent + focus/hover are on-brand)

struct PrimaryButton: View {
    var title: String
    var systemImage: String? = nil
    var disabled = false
    var action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let s = systemImage { Image(systemName: s) }
                Text(title).fontWeight(.semibold)
            }
            .font(.system(size: 15))
            .frame(maxWidth: .infinity).frame(height: 46)
            .foregroundStyle(disabled ? Trace.inkFaint : Trace.carbon0)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(disabled ? AnyShapeStyle(Trace.carbon2) : AnyShapeStyle(Trace.heat)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? Trace.amber : Color.white.opacity(disabled ? 0.04 : 0.16),
                              lineWidth: focused ? 2.5 : 1))
            .brightness(hover && !disabled ? 0.06 : 0)
            .shadow(color: disabled ? .clear : Trace.orange.opacity(hover ? 0.45 : 0.30),
                    radius: hover ? 16 : 9, y: 4)
        }
        .buttonStyle(.plain)
        .focusable(!disabled)
        .focused($focused)
        .disabled(disabled)
        .onHover { hover = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hover)
    }
}

struct GhostButton: View {
    var title: String
    var systemImage: String? = nil
    var action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s) }
                Text(title)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Trace.ink)
            .padding(.horizontal, 14).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Trace.carbon2.opacity(hover ? 1 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused ? Trace.amber : Trace.line, lineWidth: focused ? 2 : 1))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

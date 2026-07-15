import SwiftUI
import AppKit
import UniformTypeIdentifiers
import XRKConverterCore

@main
struct XRKConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, idealWidth: 560, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    @StateObject private var model = ConversionModel()
    @State private var isTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSuccess: Bool { if case .success = model.state { return true }; return false }

    // The header logo doubles as a live plot: its trace draws with conversion progress.
    private var headerTrim: CGFloat {
        if case let .running(p, _) = model.state { return max(0.02, CGFloat(p)) }
        return 1
    }

    var body: some View {
        ZStack {
            HUDBackground()
            VStack(spacing: 18) {
                header
                dropZone
                if model.inputURL != nil && !isSuccess { ratePicker }
                statusArea
                Spacer(minLength: 0)
                if !isSuccess { actionBar }
            }
            .padding(22)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            TraceTile(size: 52, trim: headerTrim)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: headerTrim)
            VStack(alignment: .leading, spacing: 3) {
                Text("Trace")
                    .font(Trace.display(30, .heavy)).tracking(-0.5)
                    .foregroundStyle(Trace.ink)
                Text("XRK → CSV · for RaceChrono")
                    .font(Trace.mono(11, .medium)).tracking(0.4)
                    .foregroundStyle(Trace.inkDim)
            }
            Spacer()
        }
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        let hasFile = model.inputURL != nil
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Trace.carbon2.opacity(isTargeted ? 0.95 : 0.55))
            .frame(height: 150)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: hasFile ? [] : [7, 6]))
                    .foregroundStyle(isTargeted ? Trace.orange : (hasFile ? Trace.lineStrong : Trace.line))
            )
            .overlay(dropContent)
            .shadow(color: isTargeted ? Trace.orange.opacity(0.35) : .clear, radius: 18, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { browse() }
            .dropDestination(for: URL.self) { urls, _ in
                if let u = urls.first { model.setInput(u); return true }
                return false
            } isTargeted: { isTargeted = $0 }
            .accessibilityLabel("Drop an .xrk or .xrz file here, or click to browse")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
    }

    @ViewBuilder private var dropContent: some View {
        if let url = model.inputURL {
            VStack(spacing: 9) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 27)).foregroundStyle(Trace.orange)
                Text(url.lastPathComponent)
                    .font(Trace.mono(13, .medium)).foregroundStyle(Trace.ink)
                    .lineLimit(1).truncationMode(.middle).padding(.horizontal, 24)
                HStack(spacing: 8) {
                    Chip(text: "READY", color: Trace.good)
                    Text("click to replace").font(Trace.mono(10.5)).foregroundStyle(Trace.inkFaint)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(isTargeted ? Trace.orange : Trace.inkDim)
                Text("Drop an .xrk or .xrz file")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Trace.ink)
                Text("or click to browse")
                    .font(Trace.mono(11)).foregroundStyle(Trace.inkFaint)
            }
        }
    }

    // MARK: - Rate picker

    private var ratePicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("SAMPLE RATE").font(Trace.mono(11, .medium)).tracking(1).foregroundStyle(Trace.inkFaint)
                Spacer()
                HStack(spacing: 6) {
                    ForEach([10.0, 20.0, 25.0, 50.0], id: \.self) { hz in
                        RatePill(hz: hz, selected: model.rateHz == hz, disabled: model.isRunning) {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { model.rateHz = hz }
                        }
                    }
                    Text("Hz").font(Trace.mono(11)).foregroundStyle(Trace.inkFaint)
                }
            }
            Text("20 Hz matches RaceStudio’s export · 25 Hz keeps full GPS resolution")
                .font(Trace.mono(10.5)).foregroundStyle(Trace.inkFaint)
        }
        .tracePanel()
    }

    // MARK: - Status

    @ViewBuilder private var statusArea: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case let .running(progress, message):
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(message.uppercased())
                        .font(Trace.mono(11, .medium)).tracking(0.8)
                        .foregroundStyle(Trace.inkDim).lineLimit(1)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(Trace.mono(13, .semibold)).foregroundStyle(Trace.orange).monospacedDigit()
                }
                HeatProgress(value: progress)
            }
            .tracePanel()
        case let .success(result):
            successCard(result)
        case let .failure(message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Trace.red)
                Text(message).font(.system(size: 13)).foregroundStyle(Trace.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tracePanel(border: Trace.red.opacity(0.4))
        }
    }

    private func successCard(_ r: ConversionResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Trace.good)
                Text("CONVERTED").font(Trace.mono(12, .semibold)).tracking(1.2).foregroundStyle(Trace.good)
                Spacer()
                Chip(text: r.has_gps ? "GPS LOCKED" : "NO GPS", color: r.has_gps ? Trace.good : Trace.amber)
            }
            Rectangle().fill(Trace.line).frame(height: 1)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                infoRow("VENUE", r.venue.isEmpty ? "—" : r.venue)
                infoRow("VEHICLE", r.vehicle.isEmpty ? "—" : r.vehicle)
                infoRow("LAPS", "\(r.laps)")
                infoRow("SAMPLES", "\(r.samples)  @ \(Int(r.rate_hz)) Hz")
                infoRow("DURATION", String(format: "%.0f s", r.duration_s))
                infoRow("CHANNELS", "\(r.channels)")
            }
            Text(URL(fileURLWithPath: r.output).lastPathComponent)
                .font(Trace.mono(11)).foregroundStyle(Trace.inkFaint)
                .lineLimit(1).truncationMode(.middle)
            if !r.has_gps {
                Text("RaceChrono needs GPS for a track map.")
                    .font(Trace.mono(10.5)).foregroundStyle(Trace.amber)
            }
            HStack(spacing: 10) {
                GhostButton(title: "Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.output)])
                }
                GhostButton(title: "Convert Another", systemImage: "arrow.clockwise") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.reset() }
                }
            }
            .padding(.top, 2)
        }
        .tracePanel(border: Trace.good.opacity(0.25))
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).font(Trace.mono(11)).foregroundStyle(Trace.inkFaint).gridColumnAlignment(.leading)
            Text(value).font(Trace.mono(12.5)).foregroundStyle(Trace.ink)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        PrimaryButton(
            title: model.isRunning ? "Converting…" : "Convert & Save…",
            systemImage: model.isRunning ? nil : "bolt.fill",
            disabled: model.inputURL == nil || model.isRunning
        ) { startConvert() }
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Actions

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["xrk", "xrz"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { model.setInput(url) }
    }

    private func startConvert() {
        guard let input = model.inputURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = model.defaultOutputURL(for: input).lastPathComponent
        panel.directoryURL = input.deletingLastPathComponent()
        if panel.runModal() == .OK, let out = panel.url {
            model.convert(to: out)
        }
    }
}

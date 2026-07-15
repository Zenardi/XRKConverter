import SwiftUI
import AppKit
import UniformTypeIdentifiers
import XRKConverterCore

@main
struct XRKConverterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 460, idealWidth: 520, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    @StateObject private var model = ConversionModel()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            header
            dropZone
            if model.inputURL != nil { ratePicker }
            statusArea
            Spacer(minLength: 0)
            actionBar
        }
        .padding(24)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("XRK → RaceChrono CSV")
                .font(.system(size: 22, weight: .semibold))
            Text("Convert AiM MyChron / RaceStudio .xrk files for RaceChrono")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var dropZone: some View {
        let accent = isTargeted ? Color.accentColor : Color.secondary.opacity(0.4)
        return RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .foregroundStyle(accent)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(isTargeted ? 0.12 : 0.05)))
            .frame(height: 150)
            .overlay(dropContent)
            .contentShape(Rectangle())
            .onTapGesture { browse() }
            .dropDestination(for: URL.self) { urls, _ in
                if let u = urls.first { model.setInput(u); return true }
                return false
            } isTargeted: { isTargeted = $0 }
    }

    private var dropContent: some View {
        VStack(spacing: 8) {
            Image(systemName: model.inputURL == nil ? "arrow.down.doc" : "doc.badge.gearshape")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            if let url = model.inputURL {
                Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("Click to choose a different file").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Drop an .xrk or .xrz file here").font(.headline)
                Text("or click to browse").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var ratePicker: some View {
        HStack {
            Text("Sample rate").foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $model.rateHz) {
                Text("10 Hz").tag(10.0)
                Text("20 Hz").tag(20.0)
                Text("25 Hz").tag(25.0)
                Text("50 Hz").tag(50.0)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(model.isRunning)
        }
    }

    @ViewBuilder private var statusArea: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case let .running(progress, message):
            ProgressView(value: progress) {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        case let .success(result):
            successCard(result)
        case let .failure(msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        }
    }

    private func successCard(_ r: ConversionResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Converted successfully", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                infoRow("Venue", r.venue.isEmpty ? "—" : r.venue)
                infoRow("Vehicle", r.vehicle.isEmpty ? "—" : r.vehicle)
                infoRow("Laps", "\(r.laps)")
                infoRow("Samples", "\(r.samples) @ \(Int(r.rate_hz)) Hz  (\(String(format: "%.0f", r.duration_s)) s)")
                infoRow("Channels", "\(r.channels)  ·  GPS: \(r.has_gps ? "yes" : "no")")
            }.font(.callout)
            if !r.has_gps {
                Text("No GPS data found — RaceChrono needs GPS for a track map.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.output)])
                }
                Button("Convert Another") { model.inputURL = nil; model.state = .idle }
            }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.07)))
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v)
        }
    }

    private var actionBar: some View {
        Button(action: startConvert) {
            Text(model.isRunning ? "Converting…" : "Convert & Save…")
                .frame(minWidth: 140)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .disabled(model.inputURL == nil || model.isRunning)
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

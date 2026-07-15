import Foundation
import Combine

/// Result payload mirrored from xrk2csv.py's JSON output.
///
/// Decoding is tolerant: any missing or `null` field falls back to a default,
/// so a `null` string (e.g. an unrecognized logger model) never breaks parsing.
public struct ConversionResult: Decodable, Equatable {
    public var output: String
    public var samples: Int
    public var rate_hz: Double
    public var duration_s: Double
    public var laps: Int
    public var channels: Int
    public var has_gps: Bool
    public var venue: String
    public var vehicle: String
    public var driver: String
    public var logger: String

    public init(output: String, samples: Int, rate_hz: Double, duration_s: Double,
                laps: Int, channels: Int, has_gps: Bool,
                venue: String, vehicle: String, driver: String, logger: String) {
        self.output = output; self.samples = samples; self.rate_hz = rate_hz
        self.duration_s = duration_s; self.laps = laps; self.channels = channels
        self.has_gps = has_gps; self.venue = venue; self.vehicle = vehicle
        self.driver = driver; self.logger = logger
    }

    private enum CodingKeys: String, CodingKey {
        case output, samples, rate_hz, duration_s, laps, channels, has_gps, venue, vehicle, driver, logger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 0
        rate_hz = try c.decodeIfPresent(Double.self, forKey: .rate_hz) ?? 0
        duration_s = try c.decodeIfPresent(Double.self, forKey: .duration_s) ?? 0
        laps = try c.decodeIfPresent(Int.self, forKey: .laps) ?? 0
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? 0
        has_gps = try c.decodeIfPresent(Bool.self, forKey: .has_gps) ?? false
        venue = try c.decodeIfPresent(String.self, forKey: .venue) ?? ""
        vehicle = try c.decodeIfPresent(String.self, forKey: .vehicle) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? ""
        logger = try c.decodeIfPresent(String.self, forKey: .logger) ?? ""
    }
}

public enum ConversionState: Equatable {
    case idle
    case running(progress: Double, message: String)
    case success(ConversionResult)
    case failure(String)

    public var isRunning: Bool { if case .running = self { return true }; return false }
    public var isTerminal: Bool {
        switch self { case .success, .failure: return true; default: return false }
    }
}

/// One parsed line of the converter's newline-delimited JSON protocol.
public enum ProgressEvent: Equatable {
    case progress(Double, String)
    case result(ConversionResult)
    case failure(String)
}

@MainActor
public final class ConversionModel: ObservableObject {
    @Published public var inputURL: URL?
    @Published public var state: ConversionState = .idle
    @Published public var rateHz: Double = 20

    public static let acceptedExtensions: Set<String> = ["xrk", "xrz"]

    public init() {}

    public var isRunning: Bool { state.isRunning }

    public func setInput(_ url: URL) {
        guard Self.acceptedExtensions.contains(url.pathExtension.lowercased()) else {
            state = .failure("Not an .xrk/.xrz file: \(url.lastPathComponent)")
            return
        }
        inputURL = url
        state = .idle
    }

    public func reset() {
        inputURL = nil
        state = .idle
    }

    public func defaultOutputURL(for input: URL) -> URL {
        input.deletingPathExtension().appendingPathExtension("csv")
    }

    // MARK: - Tool resolution

    /// Pure resolver for the embedded Python + converter script. Env overrides
    /// (XRK_PYTHON / XRK_SCRIPT) let us run against a dev venv without the
    /// bundle. Factored out (with an injectable existence check) so both
    /// branches are unit-testable.
    public nonisolated static func resolveTools(env: [String: String],
                                                bundleResource: URL?,
                                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (python: String, script: String)? {
        if let p = env["XRK_PYTHON"], let s = env["XRK_SCRIPT"] {
            return (p, s)
        }
        guard let res = bundleResource else { return nil }
        let python = res.appendingPathComponent("python/bin/python3").path
        let script = res.appendingPathComponent("xrk2csv.py").path
        return (fileExists(python) && fileExists(script)) ? (python, script) : nil
    }

    private func toolPaths() -> (python: String, script: String)? {
        Self.resolveTools(env: ProcessInfo.processInfo.environment,
                          bundleResource: Bundle.main.resourceURL)
    }

    // MARK: - JSON protocol parsing (pure)

    public nonisolated static func parseLine(_ data: Data) -> ProgressEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let resObj = obj["result"],
           let resData = try? JSONSerialization.data(withJSONObject: resObj),
           let result = try? JSONDecoder().decode(ConversionResult.self, from: resData) {
            return .result(result)
        }
        if let ok = obj["ok"] as? Bool, ok == false {
            return .failure((obj["error"] as? String) ?? "Unknown error")
        }
        if let progress = obj["progress"] as? Double {
            return .progress(progress, (obj["message"] as? String) ?? "")
        }
        return nil
    }

    // MARK: - Conversion

    public func convert(to output: URL) {
        _ = startConversion(to: output, tools: toolPaths())
    }

    /// Testable seam: `tools` is injected so the "no runtime" branch and the
    /// async happy path can be driven deterministically. Returns the running
    /// Task (nil if it couldn't start) so tests can await completion.
    @discardableResult
    func startConversion(to output: URL,
                         tools: (python: String, script: String)?) -> Task<Void, Never>? {
        guard let input = inputURL else { return nil }
        guard let tools else {
            state = .failure("Could not locate the embedded Python runtime.")
            return nil
        }
        state = .running(progress: 0, message: "Starting…")
        let rate = rateHz
        return Task {
            let final = await self.performConversion(
                python: tools.python, script: tools.script,
                input: input.path, output: output.path, rate: rate,
                onProgress: { [weak self] p, m in
                    Task { @MainActor in
                        guard let self, !self.state.isTerminal else { return }
                        self.state = .running(progress: p / 100.0, message: m)
                    }
                })
            self.state = final
        }
    }

    /// Runs the converter subprocess off the main actor and returns the terminal
    /// state. `onProgress` (percent 0-100, message) fires as progress arrives.
    /// Returning the terminal state lets tests assert without observing @Published.
    public nonisolated func performConversion(
        python: String, script: String,
        input: String, output: String, rate: Double,
        onProgress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async -> ConversionState {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, input, "-o", output,
                          "--rate", String(format: "%g", rate), "--json"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        // stderr -> temp file (avoids a pipe-buffer deadlock if the child prints
        // many warnings while we're not draining stderr).
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xrk-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errFH = try? FileHandle(forWritingTo: errURL)
        if let errFH { proc.standardError = errFH }

        let lines = LineBuffer()
        let sink = EventSink()
        // Single consumer for every stdout line, whether it arrives via the
        // streaming handler or the post-exit drain.
        let consume: @Sendable (Data) -> Void = { line in
            guard let event = ConversionModel.parseLine(line) else { return }
            sink.record(event)
            if case let .progress(p, m) = event { onProgress(p, m) }
        }
        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { h in lines.feed(h.availableData, onLine: consume) }

        do {
            try proc.run()
        } catch {
            try? errFH?.close()
            try? FileManager.default.removeItem(at: errURL)
            return .failure("Failed to launch converter: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        outHandle.readabilityHandler = nil

        lines.feed(outHandle.readDataToEndOfFile(), onLine: consume)
        lines.drain(onLine: consume)
        try? errFH?.close()
        let stderrText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: errURL)

        let (result, failure) = sink.snapshot()
        if let result { return .success(result) }
        if let failure { return .failure(failure) }
        let status = proc.terminationStatus
        if status != 0 {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail.isEmpty ? "Converter exited with code \(status)" : detail)
        }
        return .failure("Converter finished without a result.")
    }
}

/// Thread-safe accumulator that splits a byte stream into newline-delimited
/// lines. Serialized on a private queue, so it is safe to call from a
/// `FileHandle.readabilityHandler` (background queue).
public final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let queue = DispatchQueue(label: "com.xrkconverter.linebuffer")

    public init() {}

    public func feed(_ chunk: Data, onLine: (Data) -> Void) {
        guard !chunk.isEmpty else { return }
        queue.sync {
            data.append(chunk)
            while let nl = data.firstIndex(of: 0x0A) {
                let line = data.subdata(in: data.startIndex..<nl)
                data.removeSubrange(data.startIndex...nl)
                if !line.isEmpty { onLine(line) }
            }
        }
    }

    public func drain(onLine: (Data) -> Void) {
        queue.sync {
            if !data.isEmpty { onLine(data) }
            data.removeAll()
        }
    }
}

/// Thread-safe holder for the terminal event (result or failure) observed on
/// the converter's stdout stream.
final class EventSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.xrkconverter.eventsink")
    private var _result: ConversionResult?
    private var _failure: String?

    func record(_ event: ProgressEvent) {
        queue.sync {
            switch event {
            case .result(let r): _result = r
            case .failure(let m): _failure = m
            case .progress: break
            }
        }
    }

    func snapshot() -> (ConversionResult?, String?) {
        queue.sync { (_result, _failure) }
    }
}

import Testing
import Foundation
@testable import XRKConverterCore

/// Thread-safe counter for onProgress callbacks.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Resolve dev python + script + a real sample, or nil to skip real-conversion cases.
private func devTools() -> (python: String, script: String, sample: String)? {
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let python = env["XRK_TEST_PYTHON"] ?? root.appendingPathComponent(".venv/bin/python3").path
    let script = env["XRK_TEST_SCRIPT"] ?? root.appendingPathComponent("core/xrk2csv.py").path
    var candidates: [String] = []
    if let s = env["XRK_TEST_SAMPLE"] { candidates.append(s) }
    candidates.append(root.appendingPathComponent("samples/aim_official_test.xrk").path)
    candidates.append(root.appendingPathComponent("test-file/Smk-14-07-2026.xrk").path)
    let fm = FileManager.default
    guard fm.fileExists(atPath: python), fm.fileExists(atPath: script),
          let sample = candidates.first(where: { fm.fileExists(atPath: $0) }) else { return nil }
    return (python, script, sample)
}

@Suite struct PerformConversionTests {

    // MARK: deterministic process branches (no external deps)

    @Test func launchFailure() async {
        let m = await ConversionModel()
        let s = await m.performConversion(python: "/nonexistent/python", script: "s",
                                          input: "i", output: "o", rate: 20)
        guard case let .failure(msg) = s else { Issue.record("expected failure"); return }
        #expect(msg.contains("Failed to launch"))
    }

    @Test func noResultOnCleanExit() async {
        let m = await ConversionModel()
        let s = await m.performConversion(python: "/bin/echo", script: "s",
                                          input: "i", output: "o", rate: 20)
        #expect(s == .failure("Converter finished without a result."))
    }

    @Test func nonZeroExitEmptyStderr() async {
        let m = await ConversionModel()
        let s = await m.performConversion(python: "/usr/bin/false", script: "s",
                                          input: "i", output: "o", rate: 20)
        guard case let .failure(msg) = s else { Issue.record("expected failure"); return }
        #expect(msg.contains("exited with code"))
    }

    @Test func nonZeroExitWithStderr() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fail-\(UUID().uuidString).sh")
        try "echo boom 1>&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let m = await ConversionModel()
        let s = await m.performConversion(python: "/bin/sh", script: script.path,
                                          input: "i", output: "o", rate: 20)
        #expect(s == .failure("boom"))
    }

    @Test func progressThenResultViaScript() async throws {
        // Emits a progress line then a result line; uses the DEFAULT onProgress.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString).sh")
        let content = """
        printf '{"progress": 50, "message": "half"}\\n'
        printf '{"result": {"samples": 5, "laps": 1, "has_gps": true, "output": "/o.csv"}}\\n'
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let m = await ConversionModel()
        let s = await m.performConversion(python: "/bin/sh", script: script.path,
                                          input: "i", output: "o", rate: 20)
        guard case let .success(r) = s else { Issue.record("expected success, got \(s)"); return }
        #expect(r.samples == 5)
        #expect(r.laps == 1)
    }

    // MARK: real conversion (needs dev venv + sample)

    @Test func realConversionSuccess() async throws {
        guard let t = devTools() else { return }   // skipped if sample/venv absent
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: out) }
        let counter = Counter()
        let m = await ConversionModel()
        let s = await m.performConversion(python: t.python, script: t.script,
                                          input: t.sample, output: out.path, rate: 20,
                                          onProgress: { _, _ in counter.bump() })
        guard case let .success(r) = s else { Issue.record("expected success, got \(s)"); return }
        #expect(r.samples > 0)
        #expect(r.laps > 0)
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(counter.value > 0)
    }

    @Test func realConversionJSONFailure() async throws {
        guard let t = devTools() else { return }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: out) }
        let m = await ConversionModel()
        let s = await m.performConversion(python: t.python, script: t.script,
                                          input: t.sample, output: out.path, rate: 0)
        guard case let .failure(msg) = s else { Issue.record("expected failure"); return }
        #expect(msg.lowercased().contains("rate"))
    }

    @MainActor
    @Test func startConversionDrivesModelToSuccess() async throws {
        guard let t = devTools() else { return }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: out) }
        let m = ConversionModel()
        m.setInput(URL(fileURLWithPath: t.sample))
        let task = m.startConversion(to: out, tools: (t.python, t.script))
        await task?.value
        guard case let .success(r) = m.state else { Issue.record("expected success, got \(m.state)"); return }
        #expect(r.samples > 0)
    }
}

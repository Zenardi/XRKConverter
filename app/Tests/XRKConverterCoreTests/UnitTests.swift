import Testing
import Foundation
@testable import XRKConverterCore

private func d(_ s: String) -> Data { Data(s.utf8) }

private func sampleResult(output: String = "/o.csv") -> ConversionResult {
    ConversionResult(output: output, samples: 100, rate_hz: 20, duration_s: 5,
                     laps: 3, channels: 7, has_gps: true,
                     venue: "V", vehicle: "Ve", driver: "Dr", logger: "Lg")
}

@Suite struct ParseLineTests {
    @Test func progress() {
        #expect(ConversionModel.parseLine(d(#"{"progress": 42.5, "message": "hi"}"#)) == .progress(42.5, "hi"))
    }
    @Test func progressNoMessage() {
        #expect(ConversionModel.parseLine(d(#"{"progress": 10}"#)) == .progress(10, ""))
    }
    @Test func result() throws {
        let json = #"{"result": {"output":"/o.csv","samples":100,"rate_hz":20,"duration_s":5,"laps":3,"channels":7,"has_gps":true,"venue":"V","vehicle":"Ve","driver":"Dr","logger":"Lg"}}"#
        let event = ConversionModel.parseLine(d(json))
        guard case let .result(r)? = event else { Issue.record("expected .result"); return }
        #expect(r.samples == 100)
        #expect(r.venue == "V")
        #expect(r.has_gps)
    }
    @Test func malformedResultFallsThrough() {
        #expect(ConversionModel.parseLine(d(#"{"result": {"samples": "notanint"}}"#)) == nil)
    }
    @Test func resultWithNullLoggerDecodes() {
        // Regression: some files have Logger Model == null; must still parse.
        let json = #"{"result": {"output":"/o.csv","samples":10,"rate_hz":20,"duration_s":1,"laps":1,"channels":5,"has_gps":true,"venue":"V","vehicle":"","driver":"","logger":null}}"#
        guard case let .result(r)? = ConversionModel.parseLine(d(json)) else { Issue.record("expected .result"); return }
        #expect(r.logger == "")
        #expect(r.venue == "V")
    }
    @Test func error() {
        #expect(ConversionModel.parseLine(d(#"{"ok": false, "error": "boom"}"#)) == .failure("boom"))
    }
    @Test func errorNoMessage() {
        #expect(ConversionModel.parseLine(d(#"{"ok": false}"#)) == .failure("Unknown error"))
    }
    @Test func okTrueIsNil() {
        #expect(ConversionModel.parseLine(d(#"{"ok": true}"#)) == nil)
    }
    @Test func garbageIsNil() {
        #expect(ConversionModel.parseLine(d("not json at all")) == nil)
    }
    @Test func unrecognizedIsNil() {
        #expect(ConversionModel.parseLine(d(#"{"foo": 1}"#)) == nil)
    }
}

@Suite struct ResolveToolsTests {
    @Test func envOverride() {
        let t = ConversionModel.resolveTools(env: ["XRK_PYTHON": "/p", "XRK_SCRIPT": "/s"], bundleResource: nil)
        #expect(t?.python == "/p")
        #expect(t?.script == "/s")
    }
    @Test func envBeatsBundle() {
        let t = ConversionModel.resolveTools(env: ["XRK_PYTHON": "/p", "XRK_SCRIPT": "/s"],
                                             bundleResource: URL(fileURLWithPath: "/b"),
                                             fileExists: { _ in true })
        #expect(t?.python == "/p")
    }
    @Test func noEnvNoBundle() {
        #expect(ConversionModel.resolveTools(env: [:], bundleResource: nil) == nil)
    }
    @Test func bundleFilesPresent() {
        let t = ConversionModel.resolveTools(env: [:], bundleResource: URL(fileURLWithPath: "/bundle"),
                                             fileExists: { _ in true })
        #expect(t?.python == "/bundle/python/bin/python3")
        #expect(t?.script == "/bundle/xrk2csv.py")
    }
    @Test func bundleFilesMissing() {
        #expect(ConversionModel.resolveTools(env: [:], bundleResource: URL(fileURLWithPath: "/bundle"),
                                             fileExists: { _ in false }) == nil)
    }
    @Test func partialEnvFallsToBundle() {
        #expect(ConversionModel.resolveTools(env: ["XRK_PYTHON": "/p"], bundleResource: nil) == nil)
    }
}

@Suite struct ConversionStateTests {
    @Test func equality() {
        #expect(ConversionState.idle == .idle)
        #expect(ConversionState.running(progress: 0.5, message: "a") == .running(progress: 0.5, message: "a"))
        #expect(ConversionState.running(progress: 0.5, message: "a") != .running(progress: 0.6, message: "a"))
        #expect(ConversionState.success(sampleResult()) == .success(sampleResult()))
        #expect(ConversionState.success(sampleResult(output: "/a")) != .success(sampleResult(output: "/b")))
        #expect(ConversionState.failure("x") == .failure("x"))
        #expect(ConversionState.idle != .running(progress: 0, message: ""))
    }
    @Test func flags() {
        #expect(ConversionState.running(progress: 0, message: "").isRunning)
        #expect(!ConversionState.idle.isRunning)
        #expect(ConversionState.success(sampleResult()).isTerminal)
        #expect(ConversionState.failure("x").isTerminal)
        #expect(!ConversionState.running(progress: 0, message: "").isTerminal)
        #expect(!ConversionState.idle.isTerminal)
    }
}

@Suite struct LineBufferTests {
    private func collect(_ chunks: [String], drain: Bool = false) -> [String] {
        let lb = LineBuffer()
        var out: [String] = []
        for c in chunks { lb.feed(Data(c.utf8)) { out.append(String(decoding: $0, as: UTF8.self)) } }
        if drain { lb.drain { out.append(String(decoding: $0, as: UTF8.self)) } }
        return out
    }
    @Test func singleLine() { #expect(collect(["a\n"]) == ["a"]) }
    @Test func multipleInOneChunk() { #expect(collect(["a\nb\nc\n"]) == ["a", "b", "c"]) }
    @Test func partialThenComplete() { #expect(collect(["ab", "cd\n"]) == ["abcd"]) }
    @Test func emptyChunkNoop() { #expect(collect([""]) == []) }
    @Test func blankLinesSkipped() { #expect(collect(["a\n\nb\n"]) == ["a", "b"]) }
    @Test func drainRemainder() { #expect(collect(["tail"], drain: true) == ["tail"]) }
    @Test func drainEmptyNoop() { #expect(collect(["a\n"], drain: true) == ["a"]) }
}

@MainActor
@Suite struct ConversionModelStateTests {
    @Test func setInputValid() {
        let m = ConversionModel()
        m.setInput(URL(fileURLWithPath: "/a/b.xrk"))
        #expect(m.inputURL?.lastPathComponent == "b.xrk")
        #expect(m.state == .idle)
    }
    @Test func setInputXrzUppercase() {
        let m = ConversionModel()
        m.setInput(URL(fileURLWithPath: "/a/b.XRZ"))
        #expect(m.inputURL != nil)
    }
    @Test func setInputRejectsOther() {
        let m = ConversionModel()
        m.setInput(URL(fileURLWithPath: "/a/b.txt"))
        #expect(m.inputURL == nil)
        #expect(m.state.isTerminal)
        guard case .failure = m.state else { Issue.record("expected failure"); return }
    }
    @Test func defaultOutputURL() {
        let m = ConversionModel()
        #expect(m.defaultOutputURL(for: URL(fileURLWithPath: "/a/b.xrk")).lastPathComponent == "b.csv")
    }
    @Test func reset() {
        let m = ConversionModel()
        m.setInput(URL(fileURLWithPath: "/a/b.xrk"))
        m.reset()
        #expect(m.inputURL == nil)
        #expect(m.state == .idle)
    }
    @Test func startConversionNoInputReturnsNil() {
        let m = ConversionModel()
        #expect(m.startConversion(to: URL(fileURLWithPath: "/tmp/o.csv"), tools: nil) == nil)
        #expect(m.state == .idle)
    }
    @Test func startConversionNoToolsFails() {
        let m = ConversionModel()
        m.setInput(URL(fileURLWithPath: "/a/b.xrk"))
        #expect(m.startConversion(to: URL(fileURLWithPath: "/tmp/o.csv"), tools: nil) == nil)
        guard case let .failure(msg) = m.state else { Issue.record("expected failure"); return }
        #expect(msg.contains("Python"))
    }
    @Test func convertNoInputIsNoop() {
        let m = ConversionModel()
        m.convert(to: URL(fileURLWithPath: "/tmp/o.csv"))
        #expect(m.state == .idle)
    }
    @Test func isRunningReflectsState() {
        let m = ConversionModel()
        #expect(!m.isRunning)
        m.state = .running(progress: 0.1, message: "x")
        #expect(m.isRunning)
    }
}

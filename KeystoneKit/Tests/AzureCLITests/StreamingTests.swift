import Foundation
import Testing

@testable import AzureCLI

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

@Suite struct StreamingTests {
    @Test func parsesDeviceCodeLine() {
        let line =
            "To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code AB12CD34E to authenticate."
        let p = DeviceCodePrompt.parse(line)
        #expect(p?.code == "AB12CD34E")
        #expect(p?.url.absoluteString == "https://microsoft.com/devicelogin")
        #expect(DeviceCodePrompt.parse("Something else") == nil)
    }

    @Test func streamsStderrLinesLive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("az")
        try "#!/bin/sh\necho first >&2\necho out\nprintf 'partial' >&2\n".write(
            to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let lines = Lines()
        let runner = CLIRunner(executable: script)
        let r = try await runner.runStreaming(["login"], profileDir: nil, timeout: .seconds(10)) { lines.add($0) }
        #expect(r.exitCode == 0)
        #expect(Set(lines.all) == ["first", "out", "partial"])
    }
}

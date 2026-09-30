import Foundation
import Testing

@testable import AzureCLI

private func script(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fakeaz-\(UUID().uuidString).sh")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite struct ErrorParsingTests {
    @Test(arguments: ["AADSTS50076", "AADSTS50079", "AADSTS700082"])
    func interaction(code: String) {
        let e = AzureCLIErrorParser.parse(stderr: "ERROR: \(code): blah", exitCode: 1)
        guard case .interactionRequired(let c, _) = e else {
            Issue.record("got \(e)")
            return
        }
        #expect(c == code)
    }

    @Test func interactionRequiredText() {
        let e = AzureCLIErrorParser.parse(stderr: "AADSTS53000 interaction_required", exitCode: 1)
        #expect(e == .interactionRequired(code: "AADSTS53000", message: "AADSTS53000 interaction_required"))
    }

    @Test func loginRequired() {
        let e = AzureCLIErrorParser.parse(stderr: "ERROR: Please run 'az login' to setup account.", exitCode: 1)
        guard case .loginRequired = e else {
            Issue.record("got \(e)")
            return
        }
    }

    @Test func notFound() {
        #expect(AzureCLIErrorParser.parse(stderr: "zsh: command not found: az", exitCode: 127) == .notFound)
    }

    @Test func generic() {
        #expect(
            AzureCLIErrorParser.parse(stderr: " boom \n", exitCode: 3) == .commandFailed(exitCode: 3, stderr: "boom"))
    }
}

@Suite struct VersionTests {
    @Test func parse() {
        #expect(AzureVersion(parsing: "2.60.1") == AzureVersion(major: 2, minor: 60, patch: 1))
        #expect(AzureVersion(parsing: "azure-cli                         2.61.0 *\n\ncore 2.61.0")?.minor == 61)
        #expect(AzureVersion(parsing: #"{"azure-cli": "2.75.0", "extensions": {}}"#)?.minor == 75)
        #expect(AzureVersion(parsing: "garbage") == nil)
    }

    @Test func supported() {
        #expect(AzureVersion(major: 2, minor: 59, patch: 9).isSupported == false)
        #expect(AzureVersion(major: 2, minor: 60).isSupported)
        #expect(AzureVersion(major: 3, minor: 0).isSupported)
    }
}

@Suite struct LocatorTests {
    @Test func overrideWins() async throws {
        let l = AzureLocator(isExecutable: { _ in true }, shellWhich: { nil })
        #expect(try await l.locate(override: "/custom/az").path == "/custom/az")
    }

    @Test func badOverrideThrows() async {
        let l = AzureLocator(isExecutable: { $0 != "/custom/az" }, shellWhich: { nil })
        await #expect(throws: AzureCLIError.notFound) { try await l.locate(override: "/custom/az") }
    }

    @Test func order() async throws {
        let both = AzureLocator(isExecutable: { _ in true }, shellWhich: { "/x/az" })
        #expect(try await both.locate().path == "/opt/homebrew/bin/az")
        let intel = AzureLocator(isExecutable: { $0 == "/usr/local/bin/az" }, shellWhich: { "/x/az" })
        #expect(try await intel.locate().path == "/usr/local/bin/az")
        let shell = AzureLocator(isExecutable: { $0 == "/x/az" }, shellWhich: { "/x/az" })
        #expect(try await shell.locate().path == "/x/az")
    }

    @Test func missing() async {
        let l = AzureLocator(isExecutable: { _ in false }, shellWhich: { nil })
        await #expect(throws: AzureCLIError.notFound) { try await l.locate() }
    }
}

@Suite struct RunnerTests {
    @Test func environment() {
        let env = CLIRunner.environment(profileDir: URL(fileURLWithPath: "/p/1"), base: ["PATH": "/a"])
        #expect(env["AZURE_CONFIG_DIR"] == "/p/1")
        #expect(env["AZURE_CORE_ONLY_SHOW_ERRORS"] == "1")
        #expect(env["PATH"]?.hasPrefix("/a:") == true)
    }

    @Test func successAndEnv() async throws {
        let s = try script(#"echo "$AZURE_CONFIG_DIR|$AZURE_CORE_ONLY_SHOW_ERRORS|$1""#)
        defer { try? FileManager.default.removeItem(at: s) }
        let r = try await CLIRunner(executable: s).run(["hi"], profileDir: URL(fileURLWithPath: "/tmp/prof"))
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp/prof|1|hi")
    }

    @Test func stderrMapped() async throws {
        let s = try script(#"echo "ERROR: AADSTS50076 mfa" >&2; exit 1"#)
        defer { try? FileManager.default.removeItem(at: s) }
        await #expect(throws: AzureCLIError.self) { try await CLIRunner(executable: s).run(["x"]) }
        do { _ = try await CLIRunner(executable: s).run(["x"]) } catch let e as AzureCLIError {
            guard case .interactionRequired(let c, _) = e else {
                Issue.record("got \(e)")
                return
            }
            #expect(c == "AADSTS50076")
        }
    }

    @Test func timeout() async throws {
        let s = try script("sleep 10")
        defer { try? FileManager.default.removeItem(at: s) }
        let start = ContinuousClock.now
        await #expect(throws: AzureCLIError.timedOut(after: .milliseconds(300))) {
            try await CLIRunner(executable: s).run([], profileDir: nil, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellation() async throws {
        let s = try script("sleep 10")
        defer { try? FileManager.default.removeItem(at: s) }
        let task = Task { try await CLIRunner(executable: s).run([], profileDir: nil, timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: AzureCLIError.cancelled) { try await task.value }
    }

    @Test func missingExecutable() async {
        let r = CLIRunner(executable: URL(fileURLWithPath: "/nonexistent/az"))
        await #expect(throws: AzureCLIError.notFound) { try await r.run(["x"]) }
    }

    @Test func secretArgsRejected() async throws {
        let r = CLIRunner(executable: URL(fileURLWithPath: "/bin/echo"))
        await #expect(throws: AzureCLIError.forbiddenArgument("--value")) {
            try await r.run(["keyvault", "secret", "set", "--value=abc"])
        }
    }
}

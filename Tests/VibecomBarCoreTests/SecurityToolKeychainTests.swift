import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Claude keychain handoff")
struct SecurityToolKeychainTests {
    /// The shape of the real payload that stopped switching: Claude's OAuth
    /// login plus several MCP server logins, about 2.6 KB.
    static func claudePayload(bytes: Int) -> Data {
        let head = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-secret","refreshToken":"rt"},"mcpOAuth":{"linear|1":{"blob":""#
        let tail = #""}}}"#
        let filler = String(repeating: "a\\\"b c", count: bytes).prefix(bytes - head.utf8.count - tail.utf8.count)
        return Data((head + filler + tail).utf8)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test("sends a small credential to the helper over stdin, never in its arguments")
    func smallPayloadUsesInteractiveStdin() throws {
        let secret = Self.claudePayload(bytes: 600)
        let invocation = SecurityToolKeychain.updateInvocation(
            secret, service: ClaudeKeychain.service, account: "builder")

        #expect(invocation.arguments == ["/usr/bin/security", "-i"])
        let command = try #require(invocation.input.map { String(decoding: $0, as: UTF8.self) })
        #expect(command == #"add-generic-password -U -a "builder" -s "Claude Code-credentials" -X ""#
            + Self.hex(secret) + "\" \n")
        #expect(command.utf8.count - 1 <= SecurityToolKeychain.interactiveCommandLimit)
        #expect(!invocation.arguments.joined().contains(Self.hex(secret)))
    }

    @Test("falls back to arguments past the helper's 4 KB line, as Claude Code does")
    func largePayloadUsesArguments() {
        let secret = Self.claudePayload(bytes: 2_602)
        let invocation = SecurityToolKeychain.updateInvocation(
            secret, service: ClaudeKeychain.service, account: "builder")

        #expect(invocation.input == nil)
        #expect(invocation.arguments == [
            "/usr/bin/security", "add-generic-password", "-U", "-a", "builder",
            "-s", ClaudeKeychain.service, "-X", Self.hex(secret),
        ])
    }

    @Test("never routes a password-prompt write, which keeps only 128 bytes")
    func neverUsesPasswordPrompt() {
        for size in [64, 129, 1_024, 2_602, 40_000] {
            let invocation = SecurityToolKeychain.updateInvocation(
                Self.claudePayload(bytes: max(size, 120)), service: ClaudeKeychain.service,
                account: "builder")
            let everything = invocation.arguments.joined(separator: " ")
                + String(decoding: invocation.input ?? Data(), as: UTF8.self)
            #expect(everything.contains(" -X "))
            #expect(!invocation.arguments.contains("-w"))
        }
    }

    @Test("does not quote names that would break the helper's command line")
    func unquotableNamesUseArguments() {
        let invocation = SecurityToolKeychain.updateInvocation(
            Data("{}".utf8), service: ClaudeKeychain.service, account: #"odd"name"#)
        #expect(invocation.input == nil)
        #expect(invocation.arguments.contains(#"odd"name"#))
    }

    @Test("hex encodes every byte so quotes and backslashes survive")
    func hexEncodesBytes() {
        let secret = Data(#"{"a":""q" \ z"}"#.utf8)
        let invocation = SecurityToolKeychain.updateInvocation(
            secret, service: "s", account: "a")
        let command = String(decoding: invocation.input ?? Data(), as: UTF8.self)
        let hex = Self.hex(secret)
        #expect(command.contains("-X \"\(hex)\""))
        #expect(hex.count == secret.count * 2)
        #expect(hex.allSatisfy { $0.isHexDigit })
    }

    @Test("accepts the stored item only when it matches what was written")
    func verifiesReadback() {
        let secret = Data(#"{"k":"v"}"#.utf8)
        #expect(SecurityToolKeychain.holds(secret, secret))
        #expect(SecurityToolKeychain.holds(secret, secret + Data([10])))
        #expect(SecurityToolKeychain.holds(Data(Self.hex(secret).utf8), secret))
        #expect(!SecurityToolKeychain.holds(secret.prefix(4), secret))
        #expect(!SecurityToolKeychain.holds(Data(), secret))
    }

    @Test("feeds stdin to the helper and still drains its output")
    func passesInput() throws {
        let input = Data(String(repeating: "y", count: 4_000).utf8)
        let output = try SecurityToolKeychain.captureOutput(
            executable: "/bin/cat", arguments: [], input: input, timeout: 5)

        #expect(output.status == 0)
        #expect(output.data == input)
    }

    @Test("gives a helper without input an empty stdin instead of the app's")
    func closesStdinWithoutInput() throws {
        let output = try SecurityToolKeychain.captureOutput(
            executable: "/bin/cat", arguments: [], timeout: 5)
        #expect(output.status == 0)
        #expect(output.data.isEmpty)
    }

    @Test("drains a credential larger than the security helper's output pipe")
    func readsLargeOutputWithoutDeadlock() throws {
        let output = try SecurityToolKeychain.captureOutput(
            executable: "/usr/bin/awk",
            arguments: ["BEGIN { for (i = 0; i < 32768; i++) printf \"x\" }"],
            timeout: 5)

        #expect(output.exitedNormally)
        #expect(output.status == 0)
        #expect(output.data.count == 32_768)
    }

    @Test("stops a keychain helper that never exits")
    func timesOutBlockedHelper() {
        #expect(throws: StoreError.securityToolTimedOut) {
            _ = try SecurityToolKeychain.captureOutput(
                executable: "/bin/sleep", arguments: ["10"], timeout: 0.2)
        }
    }

    /// Writes real keychain items through Apple's helper, the way a Use click
    /// does. Off by default because it needs an unlocked login keychain; run
    /// with `VIBECOM_KEYCHAIN_ROUNDTRIP=1 swift test`. Each run uses a throwaway
    /// item and deletes it; Claude Code's own item is never touched.
    @Test(
        "round-trips Claude-sized credentials through the real keychain helper",
        .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_KEYCHAIN_ROUNDTRIP"] == "1"))
    func roundTripsThroughRealHelper() throws {
        let service = "build.vibecom.bar.test.roundtrip.\(UUID().uuidString)"
        let account = NSUserName()
        let seeded = try SecurityToolKeychain.captureOutput(
            executable: "/usr/bin/security",
            arguments: ["add-generic-password", "-a", account, "-s", service, "-w", "seed"],
            timeout: 10)
        #expect(seeded.status == 0)
        defer {
            _ = try? SecurityToolKeychain.captureOutput(
                executable: "/usr/bin/security",
                arguments: ["delete-generic-password", "-a", account, "-s", service],
                timeout: 10)
        }

        // 600 bytes goes over stdin; the others exceed both the old prompt's
        // 128-byte and 1,023-byte limits and the 4 KB interactive line.
        for size in [600, 1_100, 2_602, 16_500, 40_000] {
            let secret = Self.claudePayload(bytes: size)
            try SecurityToolKeychain.replaceExisting(secret, service: service, account: account)
            #expect(try SecurityToolKeychain.read(service: service, account: account) == secret)
        }
    }
}

import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Claude keychain handoff")
struct SecurityToolKeychainTests {
    @Test("delegates the live credential update to Apple's security helper")
    func usesSecurityToolWithoutPuttingSecretInArguments() {
        let arguments = SecurityToolKeychain.updateArguments(
            service: ClaudeKeychain.service, account: "builder")

        #expect(arguments.first == "/usr/bin/security")
        #expect(arguments.contains("-U"))
        #expect(arguments.contains(ClaudeKeychain.service))
        #expect(!arguments.contains("access-token-secret"))
        #expect(arguments.last == "-w")
    }

    @Test("answers both prompts when security creates rather than updates an item")
    func countsCreationPrompts() {
        let transcript = "password data for new item: retype password for new item:"
        #expect(SecurityToolKeychain.requiredResponses(in: transcript) == 2)
    }

    @Test("answers one prompt when security updates the existing item")
    func countsUpdatePrompt() {
        #expect(SecurityToolKeychain.requiredResponses(in: "password data for item:") == 1)
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
}

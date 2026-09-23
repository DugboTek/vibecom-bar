import AppKit
import Foundation
import VibecomBarCore

/// Runs a sign-in in Terminal by opening a `.command` script, which needs no
/// automation permission and gives the CLI a real login shell.
enum TerminalRunner {
    enum RunError: Error {
        case cliMissing(String)
        case cannotWriteScript
    }

    static func run(_ login: LoginCommand, title: String, in profile: URL) throws {
        guard let executable = which(login.executable) else { throw RunError.cliMissing(login.executable) }
        let command = login.shellLine(executablePath: executable.path)

        try FileManager.default.createDirectory(
            at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let script = """
            #!/bin/zsh
            clear
            echo "\(title)"
            echo "This sign-in runs on its own, so the account you are using now stays signed in."
            echo
            \(command)
            status=$?
            echo
            if [ $status -eq 0 ]; then
              echo "Signed in. vibecom bar is picking this account up — you can close this window."
            else
              echo "Sign-in did not complete (exit $status). You can close this window and try again."
            fi
            """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecom-bar-signin-\(UUID().uuidString).command")
        guard let data = script.data(using: .utf8) else { throw RunError.cannotWriteScript }
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)

        NSWorkspace.shared.open(url)
    }

    static func resume(
        provider: Provider, sessionID: String, relayEnabled: Bool
    ) throws {
        guard relayEnabled else { throw RunError.cliMissing("Vibecom Relay is not enabled") }
        guard let executable = which(provider == .claude ? "claude" : "codex") else {
            throw RunError.cliMissing(provider == .claude ? "claude" : "codex")
        }
        let arguments = RelayArguments.resume(provider: provider, sessionID: sessionID, original: [])
        let command = ([executable.path] + arguments).map(shellQuoted).joined(separator: " ")
        let script = """
            #!/bin/zsh
            clear
            echo "Resuming your \(provider.displayName) conversation through Vibecom Relay."
            echo "This opens a new terminal process and keeps the conversation history."
            echo
            \(command)
            status=$?
            echo
            if [ $status -eq 0 ]; then
              echo "Session ended (exit 0). You can close this window."
            else
              echo "Session ended with exit $status. You can close this window or try again."
            fi
            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecom-bar-adopt-\(UUID().uuidString).command")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Looks where a login shell would, since a menu bar app does not inherit
    /// the PATH from a shell profile.
    static func which(_ command: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates =
            [
                home.appendingPathComponent(".local/bin"),
                home.appendingPathComponent("bin"),
                URL(fileURLWithPath: "/opt/homebrew/bin"),
                URL(fileURLWithPath: "/usr/local/bin"),
                URL(fileURLWithPath: "/usr/bin"),
            ] + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map {
                URL(fileURLWithPath: String($0))
            } ?? [])

        for directory in candidates {
            let candidate = directory.appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

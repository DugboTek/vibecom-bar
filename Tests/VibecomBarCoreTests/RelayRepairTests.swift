import Darwin
import Foundation
import Testing

@testable import VibecomBarCore

/// Why running Claude sessions did not move when auto swap switched accounts.
@Suite("Relay repairs")
struct RelayRepairTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecom-relay-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(_ url: URL, _ contents: String = "#!/bin/sh\n") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: Session IDs

    @Test("knows the conversation Xirp names with --session-id before any hook fires")
    func sessionIDFromArguments() {
        let id = "3fe6975b-ebc8-4643-87f9-d85815259fe5"
        #expect(RelayArguments.sessionID(
            provider: .claude, arguments: ["--session-id", id, "--dangerously-skip-permissions"]) == id)
        #expect(RelayArguments.sessionID(
            provider: .claude, arguments: ["--resume", id, "--model", "opus"]) == id)
        #expect(RelayArguments.sessionID(provider: .claude, arguments: ["-r", id]) == id)
        #expect(RelayArguments.sessionID(provider: .claude, arguments: ["--session-id=\(id)"]) == id)
        #expect(RelayArguments.sessionID(provider: .claude, arguments: ["--resume", "--model", "x"]) == nil)
        #expect(RelayArguments.sessionID(provider: .claude, arguments: ["fix the bug"]) == nil)
        #expect(RelayArguments.sessionID(provider: .codex, arguments: ["resume", "01a1668a", "-c", "x"]) == "01a1668a")
    }

    // MARK: Claude version

    @Test("starts the newest installed Claude Code instead of the version current at install")
    func launchesNewestClaude() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let versions = root.appendingPathComponent("claude/versions", isDirectory: true)
        for version in ["2.1.280", "2.1.311", "2.1.99", "2.1.400.tmp"] {
            try executable(versions.appendingPathComponent(version))
        }
        try Data("partial".utf8).write(to: versions.appendingPathComponent("2.2.0"))
        let original = root.appendingPathComponent("claude.vibecom-original")
        try FileManager.default.createSymbolicLink(
            at: original, withDestinationURL: versions.appendingPathComponent("2.1.280"))

        // 2.2.0 is not executable yet (still downloading), so 2.1.311 wins.
        #expect(RelayPaths.launchTarget(for: original).lastPathComponent == "2.1.311")
    }

    @Test("leaves any other original command as it is")
    func keepsOtherOriginals() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex/bin/codex")
        try executable(codex)
        let original = root.appendingPathComponent("codex.vibecom-original")
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: codex)

        #expect(RelayPaths.launchTarget(for: original) == original)
    }

    @Test("finds its Claude plugin beside its own bundle, not the working directory")
    func pluginBesideHelper() {
        let helper = URL(fileURLWithPath: "/Applications/Vibecom Bar.app/Contents/MacOS/VibecomRelay")
        #expect(RelayPaths.claudePlugin(besides: helper).path
            == "/Applications/Vibecom Bar.app/Contents/Resources/VibecomRelayClaudePlugin")
    }

    // MARK: Installer

    @Test("puts the relay back after a CLI updater replaces its link, keeping the newer command")
    func repairsAfterUpdaterReplacesLink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let helper = root.appendingPathComponent("VibecomRelay")
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        try executable(helper)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["codex", "claude"] {
            let target = root.appendingPathComponent("old-\(name)")
            try executable(target)
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent(name), withDestinationURL: target)
        }
        let installer = RelayInstaller(
            relayExecutable: helper, claudePlugin: plugin,
            binDirectory: bin, codexHooksURL: root.appendingPathComponent("hooks.json"))
        try installer.install()

        // Codex's updater rewrites its link, as it did on Oct 19.
        let newCodex = root.appendingPathComponent("new-codex")
        try executable(newCodex)
        try FileManager.default.removeItem(at: bin.appendingPathComponent("codex"))
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("codex"), withDestinationURL: newCodex)

        #expect(installer.isInstalled(.claude))
        #expect(!installer.isInstalled(.codex))
        #expect(installer.providersNeedingRepair == [.codex])

        try installer.install()

        #expect(installer.isInstalled)
        #expect(installer.providersNeedingRepair.isEmpty)
        let original = try FileManager.default.destinationOfSymbolicLink(
            atPath: bin.appendingPathComponent("codex.vibecom-original").path)
        #expect(original == newCodex.path)
        #expect(FileManager.default.fileExists(
            atPath: bin.appendingPathComponent("codex.vibecom-original.previous").path))
    }

    // MARK: Handoff

    @Test("clears files left by relays that have exited")
    func prunesDeadSessions() throws {
        let runtime = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: runtime) }
        try RelayFiles.write(
            RelaySession(relayPID: 101, provider: .claude, accountKey: "old"),
            to: RelayPaths.session(101, in: runtime))
        try RelayFiles.write(
            RelaySession(relayPID: 999, provider: .claude, accountKey: "old"),
            to: RelayPaths.session(999, in: runtime))
        try RelayFiles.write(
            RelayEvent(lifecycle: .idle, sessionID: "s"), to: RelayPaths.event(999, in: runtime))

        let controller = RelayController(
            runtimeDirectory: runtime,
            signal: { pid, _ in pid == 101 ? 0 : -1 },
            isRelayProcess: { $0 == 101 })
        let target = StoredAccount(
            provider: .claude, label: "new", identity: AccountIdentity(accountUUID: "new"))
        let source = StoredAccount(
            provider: .claude, label: "old", identity: AccountIdentity(accountUUID: "old"))

        #expect(controller.queueHandoff(from: source, to: target) == 1)
        #expect(!FileManager.default.fileExists(atPath: RelayPaths.session(999, in: runtime).path))
        #expect(!FileManager.default.fileExists(atPath: RelayPaths.event(999, in: runtime).path))
        #expect(FileManager.default.fileExists(atPath: RelayPaths.session(101, in: runtime).path))
    }

    // MARK: Token override

    @Test("finds CLAUDE_CODE_OAUTH_TOKEN in the login session and shell profiles")
    func findsTokenOverride() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("export PATH=x\nexport CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-x\n".utf8)
            .write(to: home.appendingPathComponent(".zshrc"))
        try Data("# export CLAUDE_CODE_OAUTH_TOKEN=old\n".utf8)
            .write(to: home.appendingPathComponent(".zprofile"))

        let sources = ClaudeTokenOverride.sources(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-x"], home: home)
        #expect(sources.count == 2)
        #expect(sources.last == "~/.zshrc")
        #expect(ClaudeTokenOverride.sources(environment: [:], home: home) == ["~/.zshrc"])

        try Data("export PATH=x\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        #expect(ClaudeTokenOverride.sources(environment: [:], home: home).isEmpty)
    }
}

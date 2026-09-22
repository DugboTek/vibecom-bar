import Darwin
import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Vibecom Relay")
struct RelayTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibecom-relay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func account(_ provider: Provider, _ email: String, uuid: String? = nil) -> StoredAccount {
        StoredAccount(
            provider: provider, label: email,
            identity: AccountIdentity(email: email, accountUUID: uuid))
    }

    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw RelayTestError.timedOut
    }

    private enum RelayTestError: Error { case timedOut }

    @Test("Codex resume keeps launch flags and never replays the prompt")
    func codexResumeArguments() {
        let result = RelayArguments.resume(
            provider: .codex, sessionID: "new-thread",
            original: ["-C", "/tmp/project", "build the thing"])
        #expect(result == ["resume", "new-thread", "-C", "/tmp/project"])

        let existing = RelayArguments.resume(
            provider: .codex, sessionID: "replacement",
            original: ["resume", "old-thread", "--full-auto"])
        #expect(existing == ["resume", "replacement", "--full-auto"])
    }

    @Test("Claude resume keeps launch flags and never replays the prompt")
    func claudeResumeArguments() {
        let result = RelayArguments.resume(
            provider: .claude, sessionID: "new-session",
            original: ["--model", "opus", "finish this task"])
        #expect(result == ["--resume", "new-session", "--model", "opus"])

        let existing = RelayArguments.resume(
            provider: .claude, sessionID: "replacement",
            original: ["--resume", "old-session", "--permission-mode", "plan"])
        #expect(existing == ["--resume", "replacement", "--permission-mode", "plan"])
    }

    @Test("handoff finds only live matching sessions and writes a private command")
    func queuesMatchingHandoff() throws {
        let runtime = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: runtime) }
        let source = account(.codex, "old@example.com", uuid: "old-id")
        let target = account(.codex, "new@example.com", uuid: "new-id")
        try RelayFiles.write(
            RelaySession(relayPID: 101, provider: .codex, accountKey: "old-id"),
            to: RelayPaths.session(101, in: runtime))
        try RelayFiles.write(
            RelaySession(relayPID: 202, provider: .claude, accountKey: "old-id"),
            to: RelayPaths.session(202, in: runtime))
        try RelayFiles.write(
            RelayCommand(accountKey: nil, label: "not a session"),
            to: RelayPaths.command(303, in: runtime))

        let controller = RelayController(
            runtimeDirectory: runtime,
            signal: { pid, signal in
                (pid == 101 && (signal == 0 || signal == SIGUSR1)) ? 0 : -1
            },
            isRelayProcess: { $0 == 101 })
        #expect(controller.queueHandoff(from: source, to: target) == 1)

        let command = try RelayFiles.read(
            RelayCommand.self, from: RelayPaths.command(101, in: runtime))
        #expect(command == RelayCommand(accountKey: "new-id", label: "new@example.com"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: RelayPaths.command(101, in: runtime).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("installer is reversible and preserves existing Codex hooks")
    func installerRoundTrip() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let helper = root.appendingPathComponent("VibecomRelay")
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        let hooks = root.appendingPathComponent("codex/hooks.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        for name in ["codex", "claude"] {
            let target = root.appendingPathComponent("real-\(name)")
            try Data(name.utf8).write(to: target)
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent(name), withDestinationURL: target)
        }
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalHooks = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"keep-me"}]}]}}
        """
        try Data(originalHooks.utf8).write(to: hooks)

        let installer = RelayInstaller(
            relayExecutable: helper, claudePlugin: plugin,
            binDirectory: bin, codexHooksURL: hooks)
        try installer.install()
        #expect(installer.isInstalled)
        let installedHooks = try String(contentsOf: hooks, encoding: .utf8)
        #expect(installedHooks.contains("keep-me"))
        #expect(installedHooks.contains("boundary codex idle"))

        try installer.uninstall()
        #expect(!installer.isInstalled)
        #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("codex").path))
        let restoredHooks = try String(contentsOf: hooks, encoding: .utf8)
        #expect(restoredHooks.contains("keep-me"))
        #expect(!restoredHooks.contains("boundary codex"))
    }

    @Test("partial installation rolls back both commands")
    func installerRollback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let helper = root.appendingPathComponent("VibecomRelay")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try Data("codex".utf8).write(to: bin.appendingPathComponent("codex"))

        let installer = RelayInstaller(
            relayExecutable: helper, claudePlugin: root,
            binDirectory: bin, codexHooksURL: root.appendingPathComponent("hooks.json"))
        #expect(throws: RelayInstallError.self) { try installer.install() }
        #expect(FileManager.default.fileExists(atPath: bin.appendingPathComponent("codex").path))
        #expect(!FileManager.default.fileExists(
            atPath: bin.appendingPathComponent("codex.vibecom-original").path))
    }

    @Test("a turn boundary resumes the same fake Codex conversation")
    func endToEndHandoff() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let log = root.appendingPathComponent("launches.txt")
        let fake = root.appendingPathComponent("fake-codex")
        let relay = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/VibecomRelay")
        guard FileManager.default.isExecutableFile(atPath: relay.path) else { return }
        let shim = root.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: shim, withDestinationURL: relay)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$VIBECOM_TEST_LOG"
        trap 'exit 0' TERM
        while :; do sleep 0.05; done
        """
        try Data(script.utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let process = Process()
        process.executableURL = shim
        process.arguments = ["-C", "/tmp/project", "do not replay me"]
        var environment = ProcessInfo.processInfo.environment
        environment["VIBECOM_RELAY_RUNTIME_DIR"] = runtime.path
        environment["VIBECOM_RELAY_ORIGINAL"] = fake.path
        environment["VIBECOM_TEST_LOG"] = log.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let relayPID = process.processIdentifier

        do {
            try await waitUntil {
                FileManager.default.fileExists(atPath: RelayPaths.session(relayPID, in: runtime).path)
                    && ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count == 1
            }
            try RelayFiles.write(
                RelayCommand(accountKey: "next", label: "next@example.com"),
                to: RelayPaths.command(relayPID, in: runtime))
            #expect(kill(relayPID, SIGUSR1) == 0)

            let boundary = Process()
            boundary.executableURL = relay
            boundary.arguments = ["boundary", "codex", "idle"]
            var boundaryEnvironment = environment
            boundaryEnvironment["VIBECOM_RELAY_PID"] = String(relayPID)
            boundary.environment = boundaryEnvironment
            let input = Pipe()
            boundary.standardInput = input
            boundary.standardOutput = FileHandle.nullDevice
            boundary.standardError = FileHandle.nullDevice
            try boundary.run()
            input.fileHandleForWriting.write(Data("{\"session_id\":\"thread-42\"}".utf8))
            try input.fileHandleForWriting.close()
            boundary.waitUntilExit()

            try await waitUntil {
                ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                    .split(separator: "\n").count >= 2
            }
            let launches = try String(contentsOf: log, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            #expect(launches[0].contains("do not replay me"))
            #expect(launches[1] == "resume thread-42 -C /tmp/project")
            #expect(!launches[1].contains("do not replay me"))
        } catch {
            if let session = try? RelayFiles.read(
                RelaySession.self, from: RelayPaths.session(relayPID, in: runtime)),
                let child = session.childPID
            { _ = kill(child, SIGTERM) }
            _ = kill(relayPID, SIGTERM)
            throw error
        }

        if let session = try? RelayFiles.read(
            RelaySession.self, from: RelayPaths.session(relayPID, in: runtime)),
            let child = session.childPID
        { _ = kill(child, SIGTERM) }
        process.waitUntilExit()
    }
}

import Darwin
import Foundation
import VibecomBarCore

private final class RelayRuntime: @unchecked Sendable {
    let provider: Provider
    let originalArguments: [String]
    let executable: URL
    let relayPID = getpid()
    var child: Process?
    var session = RelaySession(relayPID: getpid(), provider: .codex)
    var pending: RelayCommand?
    var shouldResume = false
    let claudePlugin: URL?

    init(provider: Provider, arguments: [String], executable: URL, claudePlugin: URL?) {
        self.provider = provider
        self.originalArguments = arguments
        self.executable = executable
        self.claudePlugin = claudePlugin
        self.session = RelaySession(
            relayPID: relayPID, provider: provider,
            accountKey: Self.currentAccountKey(provider: provider))
    }

    func start() throws {
        try RelayFiles.write(session, to: RelayPaths.session(relayPID))
        try launch(arguments: originalArguments)
    }

    func launch(arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = injected(arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["VIBECOM_RELAY_PID"] = String(relayPID)
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.childFinished(status: process.terminationStatus) }
        }
        child = process
        try process.run()
        session.childPID = process.processIdentifier
        session.accountKey = pending?.accountKey ?? Self.currentAccountKey(provider: provider)
        session.updatedAt = Date()
        try RelayFiles.write(session, to: RelayPaths.session(relayPID))
    }

    private func injected(_ arguments: [String]) -> [String] {
        guard provider == .claude, let plugin = claudePlugin else { return arguments }
        return ["--plugin-dir", plugin.path] + arguments
    }

    func receivedSwapRequest() {
        guard let command = try? RelayFiles.read(
            RelayCommand.self, from: RelayPaths.command(relayPID))
        else { return }
        pending = command
        session.pendingAccountKey = command.accountKey
        session.pendingLabel = command.label
        session.updatedAt = Date()
        try? RelayFiles.write(session, to: RelayPaths.session(relayPID))
        FileHandle.standardError.write(
            Data("\r\n\u{001B}[36mVibecom Relay:\u{001B}[0m switch to \(command.label) queued.\r\n".utf8))
        if session.isIdle { beginHandoff() }
    }

    func receivedLifecycleEvent() {
        guard let event = try? RelayFiles.read(RelayEvent.self, from: RelayPaths.event(relayPID))
        else { return }
        if let id = event.sessionID { session.sessionID = id }
        session.isIdle = event.lifecycle != .active
        session.updatedAt = Date()
        try? RelayFiles.write(session, to: RelayPaths.session(relayPID))
        if pending != nil, session.isIdle { beginHandoff() }
    }

    private func beginHandoff() {
        guard let child, child.isRunning, session.sessionID != nil else { return }
        shouldResume = true
        session.isIdle = false
        try? RelayFiles.write(session, to: RelayPaths.session(relayPID))
        FileHandle.standardError.write(
            Data("\r\n\u{001B}[36mVibecom Relay:\u{001B}[0m moving this conversation…\r\n".utf8))
        child.terminate()
        let pid = child.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func childFinished(status: Int32) {
        guard shouldResume, let sessionID = session.sessionID else {
            cleanup()
            exit(status)
        }
        shouldResume = false
        let arguments = RelayArguments.resume(
            provider: provider, sessionID: sessionID, original: originalArguments)
        do {
            try launch(arguments: arguments)
            pending = nil
            session.pendingAccountKey = nil
            session.pendingLabel = nil
            session.updatedAt = Date()
            try? RelayFiles.write(session, to: RelayPaths.session(relayPID))
            FileHandle.standardError.write(
                Data("\r\n\u{001B}[32mVibecom Relay:\u{001B}[0m resumed on the new account.\r\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("\r\nVibecom Relay could not resume: \(error.localizedDescription)\r\n".utf8))
            cleanup()
            exit(1)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: RelayPaths.session(relayPID))
        try? FileManager.default.removeItem(at: RelayPaths.command(relayPID))
        try? FileManager.default.removeItem(at: RelayPaths.event(relayPID))
    }

    private static func currentAccountKey(provider: Provider) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = provider == .codex
            ? home.appendingPathComponent(".codex/auth.json")
            : home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if provider == .codex {
            return (root["tokens"] as? [String: Any])?["account_id"] as? String
        }
        let account = root["oauthAccount"] as? [String: Any]
        return account?["accountUuid"] as? String
            ?? (account?["emailAddress"] as? String)?.lowercased()
    }
}

private enum RelayMain {
    static func run() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "install" { installerCommand(uninstall: false) }
        if arguments.first == "uninstall" { installerCommand(uninstall: true) }
        if arguments.first == "boundary" { boundary(Array(arguments.dropFirst())) }

        let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.lowercased()
        let provider: Provider = name.contains("claude") ? .claude : .codex
        let original = ProcessInfo.processInfo.environment["VIBECOM_RELAY_ORIGINAL"]
            .map { URL(fileURLWithPath: $0) } ?? RelayPaths.originalExecutable(for: provider)
        guard FileManager.default.fileExists(atPath: original.path) else {
            fputs("Vibecom Relay: original \(provider.displayName) executable is missing.\n", stderr)
            exit(127)
        }

        let resolvedHelper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundledPlugin = resolvedHelper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/VibecomRelayClaudePlugin", isDirectory: true)
        let plugin = FileManager.default.fileExists(atPath: bundledPlugin.path) ? bundledPlugin : nil
        let runtime = RelayRuntime(
            provider: provider, arguments: arguments, executable: original, claudePlugin: plugin)
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        let swap = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        swap.setEventHandler { runtime.receivedSwapRequest() }
        swap.resume()
        let lifecycle = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        lifecycle.setEventHandler { runtime.receivedLifecycleEvent() }
        lifecycle.resume()

        do { try runtime.start() } catch {
            fputs("Vibecom Relay: \(error.localizedDescription)\n", stderr)
            runtime.cleanup()
            exit(1)
        }
        dispatchMain()
    }

    private static func installerCommand(uninstall: Bool) -> Never {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let resources = helper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let installer = RelayInstaller(
            relayExecutable: helper,
            claudePlugin: resources.appendingPathComponent(
                "VibecomRelayClaudePlugin", isDirectory: true))
        do {
            if uninstall {
                try installer.uninstall()
                print("Vibecom Relay: uninstalled")
            } else {
                try installer.install()
                print("Vibecom Relay: installed")
            }
            exit(0)
        } catch {
            fputs("Vibecom Relay: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func boundary(_ arguments: [String]) -> Never {
        guard let pidText = ProcessInfo.processInfo.environment["VIBECOM_RELAY_PID"],
            let pid = Int32(pidText), kill(pid, 0) == 0
        else { exit(0) }
        let lifecycle = RelayLifecycleEvent(rawValue: arguments.last ?? "idle") ?? .idle
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        let sessionID = json["session_id"] as? String ?? json["thread-id"] as? String
        try? RelayFiles.write(
            RelayEvent(lifecycle: lifecycle, sessionID: sessionID), to: RelayPaths.event(pid))
        _ = kill(pid, SIGUSR2)
        exit(0)
    }
}

RelayMain.run()

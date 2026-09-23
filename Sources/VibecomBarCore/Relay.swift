import Darwin
import Foundation

public struct RelaySession: Codable, Equatable, Sendable, Identifiable {
    public var id: Int32 { relayPID }
    public let relayPID: Int32
    public var childPID: Int32?
    public let provider: Provider
    public var accountKey: String?
    public var sessionID: String?
    public var isIdle: Bool
    public var pendingAccountKey: String?
    public var pendingLabel: String?
    public var updatedAt: Date

    public init(
        relayPID: Int32, childPID: Int32? = nil, provider: Provider,
        accountKey: String? = nil, sessionID: String? = nil, isIdle: Bool = false,
        pendingAccountKey: String? = nil, pendingLabel: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.relayPID = relayPID
        self.childPID = childPID
        self.provider = provider
        self.accountKey = accountKey
        self.sessionID = sessionID
        self.isIdle = isIdle
        self.pendingAccountKey = pendingAccountKey
        self.pendingLabel = pendingLabel
        self.updatedAt = updatedAt
    }
}

public struct RelayCommand: Codable, Equatable, Sendable {
    public let accountKey: String?
    public let label: String

    public init(accountKey: String?, label: String) {
        self.accountKey = accountKey
        self.label = label
    }
}

public enum RelayLifecycleEvent: String, Codable, Sendable {
    case started
    case active
    case idle
}

public struct RelayEvent: Codable, Equatable, Sendable {
    public let lifecycle: RelayLifecycleEvent
    public let sessionID: String?

    public init(lifecycle: RelayLifecycleEvent, sessionID: String?) {
        self.lifecycle = lifecycle
        self.sessionID = sessionID
    }
}

public enum RelayPaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibecomBar", isDirectory: true)
    }

    public static var runtimeDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["VIBECOM_RELAY_RUNTIME_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return supportDirectory.appendingPathComponent("relay", isDirectory: true)
    }

    public static func session(_ pid: Int32, in directory: URL = runtimeDirectory) -> URL {
        directory.appendingPathComponent("\(pid).json")
    }

    public static func command(_ pid: Int32, in directory: URL = runtimeDirectory) -> URL {
        directory.appendingPathComponent("\(pid).command.json")
    }

    public static func event(_ pid: Int32, in directory: URL = runtimeDirectory) -> URL {
        directory.appendingPathComponent("\(pid).event.json")
    }

    public static func executable(for provider: Provider) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/\(provider == .codex ? "codex" : "claude")")
    }

    public static func originalExecutable(for provider: Provider) -> URL {
        executable(for: provider).appendingPathExtension("vibecom-original")
    }
}

public enum RelayFiles {
    public static func prepareRuntimeDirectory(_ directory: URL = RelayPaths.runtimeDirectory) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepareRuntimeDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

public enum RelayArguments {
    public static func resume(
        provider: Provider, sessionID: String, original: [String]
    ) -> [String] {
        switch provider {
        case .codex:
            return codexResume(sessionID: sessionID, original: original)
        case .claude:
            return claudeResume(sessionID: sessionID, original: original)
        }
    }

    private static func codexResume(sessionID: String, original: [String]) -> [String] {
        if let index = original.firstIndex(of: "resume") {
            let before = optionsOnly(Array(original[..<index]), provider: .codex)
            let resumeArguments = Array(original[(index + 1)...])
            let after = resumeArguments.first?.hasPrefix("-") == false
                ? Array(resumeArguments.dropFirst()) : resumeArguments
            return before + ["resume", sessionID] + optionsOnly(after, provider: .codex)
        }
        return ["resume", sessionID] + optionsOnly(original, provider: .codex)
    }

    private static func claudeResume(sessionID: String, original: [String]) -> [String] {
        if let index = original.firstIndex(where: { $0 == "--resume" || $0 == "-r" }) {
            let before = optionsOnly(Array(original[..<index]), provider: .claude)
            let resumeArguments = Array(original[(index + 1)...])
            let after = resumeArguments.first?.hasPrefix("-") == false
                ? Array(resumeArguments.dropFirst()) : resumeArguments
            return before + ["--resume", sessionID] + optionsOnly(after, provider: .claude)
        }
        return ["--resume", sessionID] + optionsOnly(original, provider: .claude)
    }

    /// A first-launch prompt must not be replayed when the same conversation is resumed.
    /// Preserve flags and their values, while dropping positional prompt text.
    private static func optionsOnly(_ arguments: [String], provider: Provider) -> [String] {
        let valued: Set<String> = provider == .codex
            ? ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
               "-C", "--cd", "--add-dir", "-a", "--ask-for-approval", "-i", "--image"]
            : ["--add-dir", "--agent", "--agents", "--allowedTools", "--allowed-tools",
               "--append-system-prompt", "--autocompact", "--betas", "--debug", "--debug-file",
               "--disallowedTools", "--disallowed-tools", "--effort", "--fallback-model", "--file",
               "--mcp-config", "--model", "--name", "--permission-mode", "--plugin-dir",
               "--setting-sources", "--settings", "--system-prompt"]
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-") else {
                index += 1
                continue
            }
            result.append(argument)
            if valued.contains(argument), index + 1 < arguments.count {
                result.append(arguments[index + 1])
                index += 1
            }
            index += 1
        }
        return result
    }
}

public struct RelayController: @unchecked Sendable {
    private let runtimeDirectory: URL
    private let signal: @Sendable (Int32, Int32) -> Int32
    private let isRelayProcess: @Sendable (Int32) -> Bool

    public init(
        runtimeDirectory: URL = RelayPaths.runtimeDirectory,
        signal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) },
        isRelayProcess: @escaping @Sendable (Int32) -> Bool = Self.processIsRelay
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.signal = signal
        self.isRelayProcess = isRelayProcess
    }

    @discardableResult
    public func queueHandoff(from: StoredAccount?, to: StoredAccount) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimeDirectory, includingPropertiesForKeys: nil)
        else { return 0 }

        let sourceKey = Self.accountKey(for: from)
        let targetKey = Self.accountKey(for: to)
        var count = 0
        for url in entries where Self.sessionPID(from: url) != nil {
            guard var session = try? RelayFiles.read(RelaySession.self, from: url),
                session.provider == to.provider,
                sourceKey == nil || session.accountKey == sourceKey,
                signal(session.relayPID, 0) == 0,
                isRelayProcess(session.relayPID)
            else { continue }
            let command = RelayCommand(accountKey: targetKey, label: to.label)
            guard (try? RelayFiles.write(
                command, to: RelayPaths.command(session.relayPID, in: runtimeDirectory))) != nil else {
                continue
            }
            session.pendingAccountKey = targetKey
            session.pendingLabel = to.label
            session.updatedAt = Date()
            try? RelayFiles.write(session, to: url)
            guard signal(session.relayPID, SIGUSR1) == 0 else { continue }
            count += 1
        }
        return count
    }

    private static func sessionPID(from url: URL) -> Int32? {
        guard url.pathExtension == "json" else { return nil }
        return Int32(url.deletingPathExtension().lastPathComponent)
    }

    public static func processIsRelay(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
            .lastPathComponent == "VibecomRelay"
    }

    public static func accountKey(for account: StoredAccount?) -> String? {
        guard let account else { return nil }
        return account.identity.accountUUID ?? account.identity.email?.lowercased()
    }
}

public enum RelayInstallError: LocalizedError {
    case relayMissing
    case pluginMissing
    case cliMissing(String)
    case unexpectedExistingBackup(String)
    case originalMissing(String)
    case invalidHooks

    public var errorDescription: String? {
        switch self {
        case .relayMissing: "The Vibecom Relay helper is missing from this app."
        case .pluginMissing: "The Claude lifecycle plugin is missing from this app."
        case .cliMissing(let name): "The \(name) CLI was not found in ~/.local/bin."
        case .unexpectedExistingBackup(let name):
            "A \(name).vibecom-original backup already exists and was left untouched."
        case .originalMissing(let name):
            "The original \(name) command is missing, so the relay was left in place."
        case .invalidHooks: "The existing Codex hooks file isn't valid JSON, so it was left untouched."
        }
    }
}

public struct RelayInstaller: Sendable {
    private enum PreviousInstall {
        case originalCommand
        case relayLink(URL)
    }

    public let relayExecutable: URL
    public let claudePlugin: URL
    public let binDirectory: URL
    public let codexHooksURL: URL

    public init(
        relayExecutable: URL,
        claudePlugin: URL,
        binDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true),
        codexHooksURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    ) {
        self.relayExecutable = relayExecutable
        self.claudePlugin = claudePlugin
        self.binDirectory = binDirectory
        self.codexHooksURL = codexHooksURL
    }

    public var isInstalled: Bool {
        Provider.allCases.allSatisfy { provider in
            let path = executable(for: provider)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)
            else { return false }
            return resolvedLink(destination, relativeTo: path) == relayExecutable.standardizedFileURL
        }
    }

    public func install() throws {
        guard FileManager.default.isExecutableFile(atPath: relayExecutable.path) else {
            throw RelayInstallError.relayMissing
        }
        guard FileManager.default.fileExists(atPath: claudePlugin.path) else {
            throw RelayInstallError.pluginMissing
        }
        let hooksExisted = FileManager.default.fileExists(atPath: codexHooksURL.path)
        let previousHooks = hooksExisted ? try Data(contentsOf: codexHooksURL) : nil
        var installed: [(Provider, PreviousInstall)] = []
        do {
            for provider in Provider.allCases {
                if let previous = try install(provider) { installed.append((provider, previous)) }
            }
            try installCodexHooks()
        } catch {
            for (provider, previous) in installed.reversed() {
                switch previous {
                case .originalCommand: try? restore(provider)
                case .relayLink(let destination): try? link(provider, to: destination)
                }
            }
            if let previousHooks {
                try? previousHooks.write(to: codexHooksURL, options: [.atomic])
            } else if !hooksExisted {
                try? FileManager.default.removeItem(at: codexHooksURL)
            }
            throw error
        }
    }

    public func uninstall() throws {
        for provider in Provider.allCases {
            let live = executable(for: provider)
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: live.path)
            let isCurrent = destination.map {
                resolvedLink($0, relativeTo: live) == relayExecutable.standardizedFileURL
            } ?? false
            guard isCurrent || previousRelay(for: provider) != nil else { continue }
            try restore(provider)
        }
        try uninstallCodexHooks()
    }

    @discardableResult
    private func install(_ provider: Provider) throws -> PreviousInstall? {
        let live = executable(for: provider)
        let backup = originalExecutable(for: provider)
        let manager = FileManager.default
        try manager.createDirectory(
            at: live.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let destination = try? manager.destinationOfSymbolicLink(atPath: live.path),
            resolvedLink(destination, relativeTo: live) == relayExecutable.standardizedFileURL
        { return nil }
        if let previous = previousRelay(for: provider) {
            try link(provider, to: relayExecutable)
            return .relayLink(previous)
        }
        guard manager.fileExists(atPath: live.path) else {
            throw RelayInstallError.cliMissing(provider == .codex ? "Codex" : "Claude")
        }
        guard !manager.fileExists(atPath: backup.path) else {
            throw RelayInstallError.unexpectedExistingBackup(provider == .codex ? "codex" : "claude")
        }
        try manager.moveItem(at: live, to: backup)
        do {
            try manager.createSymbolicLink(at: live, withDestinationURL: relayExecutable)
        } catch {
            try? manager.moveItem(at: backup, to: live)
            throw error
        }
        return .originalCommand
    }

    private func previousRelay(for provider: Provider) -> URL? {
        let live = executable(for: provider)
        guard FileManager.default.fileExists(atPath: originalExecutable(for: provider).path),
            let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: live.path)
        else { return nil }
        let target = resolvedLink(destination, relativeTo: live)
        let contents = target.deletingLastPathComponent().deletingLastPathComponent()
        guard target.lastPathComponent == "VibecomRelay",
            target.deletingLastPathComponent().lastPathComponent == "MacOS",
            contents.lastPathComponent == "Contents",
            contents.deletingLastPathComponent().lastPathComponent == "Vibecom Bar.app"
        else { return nil }
        return target
    }

    private func link(_ provider: Provider, to target: URL) throws {
        let live = executable(for: provider)
        let replacement = live.deletingLastPathComponent()
            .appendingPathComponent(".\(live.lastPathComponent).vibecom-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: replacement) }
        guard rename(replacement.path, live.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func restore(_ provider: Provider) throws {
        let manager = FileManager.default
        let live = executable(for: provider)
        let backup = originalExecutable(for: provider)
        guard manager.fileExists(atPath: backup.path) else {
            throw RelayInstallError.originalMissing(provider == .codex ? "Codex" : "Claude")
        }
        if manager.fileExists(atPath: live.path) { try manager.removeItem(at: live) }
        try manager.moveItem(at: backup, to: live)
    }

    private func executable(for provider: Provider) -> URL {
        binDirectory.appendingPathComponent(provider == .codex ? "codex" : "claude")
    }

    private func originalExecutable(for provider: Provider) -> URL {
        executable(for: provider).appendingPathExtension("vibecom-original")
    }

    private func resolvedLink(_ destination: String, relativeTo link: URL) -> URL {
        let url = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
        return url.standardizedFileURL
    }

    private var hookMarker: String { " boundary codex " }

    private func hook(_ lifecycle: String) -> [String: Any] {
        let command = "\"\(relayExecutable.path.replacingOccurrences(of: "\"", with: "\\\""))\" boundary codex \(lifecycle)"
        return ["hooks": [["type": "command", "command": command, "timeout": 5]]]
    }

    private func installCodexHooks() throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: codexHooksURL.path) {
            let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: codexHooksURL))
            guard let existing = object as? [String: Any] else { throw RelayInstallError.invalidHooks }
            root = existing
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, lifecycle) in [
            ("SessionStart", "started"), ("UserPromptSubmit", "active"),
            ("Stop", "idle"), ("Interrupt", "idle"), ("SessionEnd", "idle"),
        ] {
            var handlers = removingOurHooks(from: hooks[event] as? [[String: Any]] ?? [])
            handlers.append(hook(lifecycle))
            hooks[event] = handlers
        }
        root["hooks"] = hooks
        try writeJSON(root, to: codexHooksURL)
    }

    private func uninstallCodexHooks() throws {
        guard FileManager.default.fileExists(atPath: codexHooksURL.path),
            let rootObject = try? JSONSerialization.jsonObject(with: Data(contentsOf: codexHooksURL)),
            var root = rootObject as? [String: Any], var hooks = root["hooks"] as? [String: Any]
        else { return }
        for (event, value) in hooks {
            guard let handlers = value as? [[String: Any]] else { continue }
            let filtered = removingOurHooks(from: handlers)
            if filtered.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = filtered }
        }
        root["hooks"] = hooks
        try writeJSON(root, to: codexHooksURL)
    }

    private func removingOurHooks(from handlers: [[String: Any]]) -> [[String: Any]] {
        handlers.compactMap { handler in
            guard let commands = handler["hooks"] as? [[String: Any]] else { return handler }
            let remaining = commands.filter {
                ($0["command"] as? String)?.contains(hookMarker) != true
            }
            guard !remaining.isEmpty else { return nil }
            var updated = handler
            updated["hooks"] = remaining
            return updated
        }
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

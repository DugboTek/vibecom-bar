import Foundation

public struct Preferences: Codable, Equatable, Sendable {
    public static let minimumRefreshInterval: TimeInterval = 60
    public static let maximumRefreshInterval: TimeInterval = 3600

    private var storedRefreshInterval: TimeInterval = 300
    public var menuBarStyle: MenuBarStyle = .activeAccounts
    public var alertThresholds: [Double] = [0.8, 0.95]
    public var notifyOnReset: Bool = true
    public var showInactiveAccounts: Bool = true
    public var launchAtLogin: Bool = false
    public var blurAccountNames: Bool = false
    public var autoSwapEnabled: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        storedRefreshInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .storedRefreshInterval) ?? 300
        menuBarStyle = try values.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle) ?? .activeAccounts
        alertThresholds = try values.decodeIfPresent([Double].self, forKey: .alertThresholds) ?? [0.8, 0.95]
        notifyOnReset = try values.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? true
        showInactiveAccounts = try values.decodeIfPresent(Bool.self, forKey: .showInactiveAccounts) ?? true
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        blurAccountNames = try values.decodeIfPresent(Bool.self, forKey: .blurAccountNames) ?? false
        autoSwapEnabled = try values.decodeIfPresent(Bool.self, forKey: .autoSwapEnabled) ?? false
        refreshInterval = storedRefreshInterval
    }

    /// Clamped on the way in: polling faster than a minute buys nothing and
    /// risks the rate limiting this app exists to avoid.
    public var refreshInterval: TimeInterval {
        get { storedRefreshInterval }
        set {
            storedRefreshInterval = min(
                max(newValue, Self.minimumRefreshInterval), Self.maximumRefreshInterval)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case storedRefreshInterval = "refreshInterval"
        case menuBarStyle, alertThresholds, notifyOnReset, showInactiveAccounts, launchAtLogin,
            blurAccountNames, autoSwapEnabled
    }
}

public struct PreferencesStore: Sendable {
    private let files: FileStore
    private let url: URL

    public init(files: FileStore, url: URL) {
        self.files = files
        self.url = url
    }

    public func load() -> Preferences {
        guard let data = (try? files.read(url)) ?? nil,
            let preferences = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return preferences
    }

    public func save(_ preferences: Preferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(try encoder.encode(preferences), to: url)
    }
}

// MARK: - Alerts

public struct UsageNotification: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case thresholdCrossed(Double)
        case windowReset
        case needsLogin
    }

    public let id: String
    public let accountID: UUID
    public let kind: Kind
    public let title: String
    public let body: String
}

/// Decides what is worth interrupting for by comparing the previous reading
/// with the current one, so an alert fires on a change rather than on a state.
public struct NotificationPlanner: Sendable {
    /// A window this far down from a near-spent reading has clearly rolled over.
    static let resetCeiling = 0.25

    private let thresholds: [Double]
    private let notifyOnReset: Bool

    public init(thresholds: [Double], notifyOnReset: Bool) {
        self.thresholds = thresholds.sorted()
        self.notifyOnReset = notifyOnReset
    }

    public init(preferences: Preferences) {
        self.init(thresholds: preferences.alertThresholds, notifyOnReset: preferences.notifyOnReset)
    }

    public func notifications(previous: [AccountStatus], current: [AccountStatus], now: Date)
        -> [UsageNotification]
    {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.account.id, $0) })
        var alerts: [UsageNotification] = []

        for status in current {
            guard let old = before[status.account.id] else { continue }

            if status.error == .needsLogin, old.error != .needsLogin {
                alerts.append(
                    UsageNotification(
                        id: "\(status.account.id)-login-\(Int(now.timeIntervalSince1970))",
                        accountID: status.account.id,
                        kind: .needsLogin,
                        title: "\(status.account.label) needs signing in again",
                        body: "Its saved login expired, so vibecom bar can't read its usage."))
            }

            for window in status.snapshot?.windows ?? [] {
                guard let previousWindow = old.snapshot?.windows.first(where: { $0.id == window.id })
                else { continue }

                if let crossed = crossedThreshold(from: previousWindow.usedFraction, to: window.usedFraction) {
                    alerts.append(
                        UsageNotification(
                            id: "\(status.account.id)-\(window.id)-\(crossed)",
                            accountID: status.account.id,
                            kind: .thresholdCrossed(crossed),
                            title: "\(status.account.label) is at \(UsageFormatter.percent(window.usedFraction))",
                            body: resetLine(for: window, now: now)))
                }

                if notifyOnReset, previousWindow.usedFraction >= thresholds.last ?? 0.9,
                    window.usedFraction <= Self.resetCeiling
                {
                    alerts.append(
                        UsageNotification(
                            id: "\(status.account.id)-\(window.id)-reset",
                            accountID: status.account.id,
                            kind: .windowReset,
                            title: "\(status.account.label) is back",
                            body:
                                "\(window.label) reset — \(UsageFormatter.percent(window.usedFraction)) used."
                        ))
                }
            }
        }

        return alerts
    }

    private func crossedThreshold(from old: Double, to new: Double) -> Double? {
        thresholds.last { threshold in old < threshold && new >= threshold }
    }

    private func resetLine(for window: UsageWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else { return "\(window.label) limit." }
        return "\(window.label) · resets in \(UsageFormatter.countdown(to: resetsAt, from: now))"
    }
}

// MARK: - Guided sign-in

/// A sign-in to run in Terminal. The executable is named rather than parsed
/// back out of the command text, since profile paths contain spaces.
public struct LoginCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [(String, String)]

    public static func == (lhs: LoginCommand, rhs: LoginCommand) -> Bool {
        lhs.executable == rhs.executable && lhs.arguments == rhs.arguments
            && lhs.environment.map(\.0) == rhs.environment.map(\.0)
            && lhs.environment.map(\.1) == rhs.environment.map(\.1)
    }

    /// The line to run, with the CLI given by its full path so the sign-in
    /// does not depend on what PATH the Terminal shell ends up with.
    public func shellLine(executablePath: String) -> String {
        let assignments = environment.map { "\($0.0)=\(GuidedLogin.shellQuoted($0.1))" }
        return (assignments + [GuidedLogin.shellQuoted(executablePath)] + arguments)
            .joined(separator: " ")
    }
}

/// Builds the sign-ins a guided add runs, so a new account can be added
/// without signing the current one out.
public enum GuidedLogin {
    public static func codex(codexHome: URL) -> LoginCommand {
        LoginCommand(executable: "codex", arguments: ["login"], environment: [("CODEX_HOME", codexHome.path)])
    }

    public static func claude(configDir: URL) -> LoginCommand {
        LoginCommand(
            executable: "claude", arguments: ["/login"],
            environment: [("CLAUDE_CONFIG_DIR", configDir.path)])
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

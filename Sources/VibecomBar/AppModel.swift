import AppKit
import Foundation
import Observation
import UserNotifications
import VibecomBarCore

@MainActor
@Observable
final class AppModel {
    enum Page: Equatable {
        case accounts
        case addAccount
        case settings
    }

    enum SignInState: Equatable {
        case idle
        case waiting(Provider)
        case failed(String)
    }

    private(set) var statuses: [AccountStatus] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    private(set) var signInState: SignInState = .idle
    /// Tokens spent on this Mac, read live from the CLIs' own transcripts.
    private(set) var tokens: TokenSummary?
    private(set) var isCountingTokens = false
    var page: Page = .accounts

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            try? preferencesStore.save(preferences)
            restartTimer()
        }
    }

    private let vault: AccountVault
    private let activator: AccountActivator
    private let monitor: AccountMonitor
    private let importer: AccountImporter
    private let preferencesStore: PreferencesStore
    private let environment: CLIEnvironment
    private let support: URL

    private var timerTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private let ledger = TokenLedger()
    /// Transcripts are re-checked this often; an update costs a few milliseconds.
    static let tokenInterval: Duration = .seconds(5)
    private var signInTask: Task<Void, Never>?
    private var notificationsAuthorized = false

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibecomBar", isDirectory: true)
        self.support = support

        let files = DiskFileStore()
        let environment = CLIEnvironment.live(files: files)
        self.environment = environment
        vault = AccountVault(secrets: KeychainSecretStore(), files: files, directory: support)
        activator = AccountActivator(vault: vault, environment: environment)
        monitor = AccountMonitor(vault: vault, activator: activator, environment: environment)
        importer = AccountImporter(environment: environment)
        preferencesStore = PreferencesStore(
            files: files, url: support.appendingPathComponent("preferences.json"))
        preferences = preferencesStore.load()
    }

    // MARK: - Lifecycle

    private var started = false

    /// Safe to call more than once; the menu bar label can appear repeatedly.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await requestNotificationPermission()
            await refresh()
            restartTimer()
        }
        startTokenFeed()
    }

    func startTokenFeed() {
        tokenTask?.cancel()
        isCountingTokens = tokens == nil
        tokenTask = Task { [weak self, ledger] in
            while !Task.isCancelled {
                let summary = await ledger.update(now: Date())
                await MainActor.run {
                    self?.tokens = summary
                    self?.isCountingTokens = false
                }
                try? await Task.sleep(for: Self.tokenInterval)
            }
        }
    }

    private func restartTimer() {
        timerTask?.cancel()
        let interval = preferences.refreshInterval
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    /// Sample accounts for layout snapshots, so rendering the UI never touches
    /// the keychain (and never puts a password prompt on screen).
    func loadPreviewAccounts() {
        let now = Date()
        func window(_ id: String, _ label: String, _ kind: UsageWindow.Kind, _ used: Double, _ hours: Double) -> UsageWindow {
            UsageWindow(id: id, label: label, kind: kind, usedFraction: used, resetsAt: now.addingTimeInterval(hours * 3600))
        }
        func status(_ provider: Provider, _ label: String, _ plan: String, active: Bool, _ windows: [UsageWindow], resets: ResetCredits? = nil) -> AccountStatus {
            AccountStatus(
                account: StoredAccount(provider: provider, label: label, identity: AccountIdentity(email: label, plan: plan)),
                snapshot: UsageSnapshot(provider: provider, windows: windows, plan: plan, email: label, accountID: nil, fetchedAt: now, resetCredits: resets),
                isActive: active)
        }
        statuses = [
            status(.claude, "work@example.com", "claude_max", active: true, [
                window("s", "5-hour session", .session, 0.03, 1.2),
                window("w", "Weekly (all models)", .weekly, 0.01, 152),
                window("f", "Weekly (Fable)", .weeklyModel, 0, 152),
            ]),
            status(.claude, "personal@example.com", "claude_max", active: false, [
                window("s", "5-hour session", .session, 0.86, 0.7),
                window("w", "Weekly (all models)", .weekly, 0.41, 60),
            ]),
            status(.codex, "main@example.com", "pro", active: true, [window("p", "Weekly", .weekly, 0.22, 164)], resets: ResetCredits(available: 1, usableNow: 0)),
            status(.codex, "side@example.com", "pro", active: false, [window("p", "Weekly", .weekly, 1, 26)], resets: ResetCredits(available: 2, usableNow: 1)),
        ]
        lastUpdated = now
    }

    // MARK: - Reading usage

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let previous = statuses
        let current = await monitor.refreshAll()
        statuses = current
        lastUpdated = Date()

        let alerts = NotificationPlanner(preferences: preferences)
            .notifications(previous: previous, current: current, now: Date())
        for alert in alerts { post(alert) }
    }

    var menuBarText: String {
        MenuBarTitle.text(for: statuses, style: preferences.menuBarStyle, tokens: tokens)
    }

    func statuses(for provider: Provider) -> [AccountStatus] {
        statuses
            .filter { $0.account.provider == provider }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive }
                return lhs.account.sortIndex < rhs.account.sortIndex
            }
    }

    var hasAccounts: Bool { !statuses.isEmpty }

    // MARK: - Switching

    func activate(_ status: AccountStatus) async {
        do {
            try await activator.activate(status.account)
            await refresh()
        } catch {
            signInState = .failed("Couldn't switch: \(error.localizedDescription)")
        }
    }

    func remove(_ status: AccountStatus) async {
        try? await vault.remove(status.account.id)
        await refresh()
    }

    func rename(_ status: AccountStatus, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await vault.rename(status.account.id, to: trimmed)
        await refresh()
    }

    // MARK: - Adding accounts

    /// Captures whoever is signed in to the CLI right now.
    func captureActiveLogin(for provider: Provider) async {
        do {
            let captured =
                provider == .claude
                ? try importer.captureActiveClaudeLogin()
                : try importer.captureActiveCodexLogin()
            try await vault.add(
                provider: provider, identity: captured.identity, secret: captured.secret)
            signInState = .idle
            page = .accounts
            await refresh()
        } catch ImportError.noActiveLogin(let provider) {
            signInState = .failed(
                "No \(provider.displayName) login found. Sign in with the CLI first, or use guided sign-in.")
        } catch ImportError.cannotReadUsage {
            signInState = .failed(
                "That login came from `claude setup-token`, which can't read usage. Use /login instead.")
        } catch {
            signInState = .failed(error.localizedDescription)
        }
    }

    /// Opens Terminal on a sign-in that runs in its own config directory, so
    /// the account currently signed in stays signed in, then captures it.
    func startGuidedSignIn(for provider: Provider) {
        signInTask?.cancel()
        signInState = .waiting(provider)

        let profile = support
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let before = try KeychainSecretStore().services(withPrefix: "Claude Code-credentials")
                try TerminalRunner.run(
                    provider == .claude
                        ? GuidedLogin.claude(configDir: profile)
                        : GuidedLogin.codex(codexHome: profile),
                    title: "Sign in to \(provider.displayName) for vibecom bar",
                    in: profile)

                let captured = try await self.waitForLogin(
                    provider: provider, profile: profile, keychainBefore: before)
                try await self.vault.add(
                    provider: provider, identity: captured.identity, secret: captured.secret)
                self.signInState = .idle
                self.page = .accounts
                await self.refresh()
            } catch is CancellationError {
                self.signInState = .idle
            } catch {
                self.signInState = .failed(Self.describe(error))
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signInState = .idle
    }

    /// Polls for the credentials the sign-in writes. A Claude sign-in under its
    /// own config directory lands in a keychain item named after a hash of that
    /// directory, so the new item is found by comparing the list before and after.
    private func waitForLogin(provider: Provider, profile: URL, keychainBefore: [String]) async throws
        -> CapturedLogin
    {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            switch provider {
            case .claude:
                let after = try KeychainSecretStore().services(withPrefix: "Claude Code-credentials")
                if let service = ClaudeKeychain.newService(before: keychainBefore, after: after),
                    let captured = try? importer.captureClaudeLogin(
                        keychainService: service, configDir: profile)
                {
                    return captured
                }
            case .codex:
                if let captured = try? importer.captureCodexLogin(fromCodexHome: profile) {
                    return captured
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw SignInError.timedOut
    }

    enum SignInError: Error { case timedOut }

    private static func describe(_ error: Error) -> String {
        switch error {
        case SignInError.timedOut:
            return "Timed out waiting for the sign-in to finish."
        case ImportError.cannotReadUsage:
            return "That login can't read usage. Sign in with /login rather than setup-token."
        case TerminalRunner.RunError.cliMissing(let name):
            return "Couldn't find the `\(name)` command. Open it once in Terminal, then try again."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Alerts

    private func requestNotificationPermission() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        // An unsigned build has no notification entitlement; the app still works.
        notificationsAuthorized =
            (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private func post(_ alert: UsageNotification) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }
}

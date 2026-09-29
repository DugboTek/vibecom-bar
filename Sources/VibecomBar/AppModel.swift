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
    /// Glides today's count between readings so it reads like a live ticker.
    private(set) var ticker = TokenTicker(duration: 5)
    /// Public leaderboard standing for the user signed in through the Vibecom CLI.
    private(set) var vibecomStanding: VibecomStanding?
    /// Human-readable result of the most recent automatic account decision.
    private(set) var autoSwapActivity: String?
    private(set) var autoSwapActivityIsFailure = false
    /// Why auto swap is or is not switching each provider right now.
    private(set) var autoSwapExplanations: [String] = []
    /// Everything auto swap saw and did, for explaining a switch that did not happen.
    let activityLog = ActivityLog()
    /// Why the last switch, manual or automatic, did not happen. Shown on the
    /// accounts page, where the Use button lives.
    private(set) var switchFailure: String?
    /// The account a Use click is currently switching to.
    private(set) var switchingAccountID: UUID?
    /// Whether the popover is on screen. Token counting slows down and the
    /// ticker stops animating while it is not.
    private(set) var isPopoverShown = false
    private(set) var relayIsInstalled = false
    private(set) var relayStatusMessage: String?
    var page: Page = .accounts

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            try? preferencesStore.save(preferences)
            updateAppNapExemption()
            if !preferences.autoSwapEnabled {
                autoSwapAttempts.removeAll()
                autoSwapActivity = nil
                autoSwapActivityIsFailure = false
            }
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
    private let vibecomProfile: VibecomProfile?
    private let vibecomStandingService: VibecomStandingService
    private let relayController = RelayController()
    private let relayInstaller: RelayInstaller

    private var timerTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private let ledger = TokenLedger()
    /// Transcripts are re-checked this often while the count is on screen.
    static let tokenInterval: TimeInterval = 5
    /// And this often while nothing shows it, which is most of the time.
    static let backgroundTokenInterval: TimeInterval = 60
    private var signInTask: Task<Void, Never>?
    private var notificationsAuthorized = false
    /// Retries a failed automatic switch on a cooldown, not every refresh.
    private var autoSwapAttempts = AutoSwapAttempts()
    /// Keeps App Nap from stretching the refresh timer while auto swap is on;
    /// a napping menu bar app can otherwise go many minutes between checks.
    private var autoSwapActivityToken: NSObjectProtocol?

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibecomBar", isDirectory: true)
        self.support = support

        let files = DiskFileStore()
        let environment = CLIEnvironment.live(files: files)
        self.environment = environment
        let configRoot = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        let vibecomData =
            (try? files.read(
                configRoot
                    .appendingPathComponent("vibecom", isDirectory: true)
                    .appendingPathComponent("credentials.json"))) ?? nil
        vibecomProfile = vibecomData.flatMap(VibecomProfile.parse)
        vibecomStandingService = VibecomStandingService()
        vault = AccountVault(secrets: KeychainSecretStore(), files: files, directory: support)
        activator = AccountActivator(vault: vault, environment: environment)
        monitor = AccountMonitor(vault: vault, activator: activator, environment: environment)
        importer = AccountImporter(environment: environment)
        preferencesStore = PreferencesStore(
            files: files, url: support.appendingPathComponent("preferences.json"))
        preferences = preferencesStore.load()
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let resources = Bundle.main.resourceURL ?? executableDirectory
        relayInstaller = RelayInstaller(
            relayExecutable: executableDirectory.appendingPathComponent("VibecomRelay"),
            claudePlugin: resources.appendingPathComponent(
                "VibecomRelayClaudePlugin", isDirectory: true))
        relayIsInstalled = relayInstaller.isInstalled
        if preferences.liveRelayEnabled && !relayIsInstalled {
            // Never mutate command resolution merely because the app launched.
            // A missing relay stays visibly off until the user enables it again.
            preferences.liveRelayEnabled = false
        }
    }

    // MARK: - Lifecycle

    private var started = false

    /// Safe to call more than once; the menu bar label can appear repeatedly.
    func start() {
        guard !started else { return }
        started = true
        updateAppNapExemption()
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
                    self?.ticker.receive(summary.today.tokens, at: Date())
                    self?.tokens = summary
                    self?.isCountingTokens = false
                }
                let interval = await MainActor.run { self?.tokenFeedInterval } ?? Self.backgroundTokenInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// While an active account is close to a limit, usage is read this often,
    /// so auto swap acts within a minute rather than a full refresh interval.
    static let nearLimitInterval: TimeInterval = 60

    private var tokenFeedInterval: TimeInterval {
        isPopoverShown || preferences.menuBarStyle == .tokensToday
            ? Self.tokenInterval : Self.backgroundTokenInterval
    }

    private func updateAppNapExemption() {
        if preferences.autoSwapEnabled, autoSwapActivityToken == nil {
            autoSwapActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Auto swap watches account limits")
        } else if !preferences.autoSwapEnabled, let token = autoSwapActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            autoSwapActivityToken = nil
        }
    }

    func setPopoverShown(_ shown: Bool) {
        guard shown != isPopoverShown else { return }
        isPopoverShown = shown
        // Opening shows a fresh count at once instead of up to a minute old.
        if shown { startTokenFeed() }
    }

    private func restartTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.nextRefreshDelay() ?? 300
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func nextRefreshDelay() -> TimeInterval {
        let interval = TimeInterval(preferences.refreshInterval)
        let nearLimit = statuses.contains { status in
            status.isActive && (status.snapshot?.windows.contains { $0.usedFraction >= 0.9 } ?? false)
        }
        return preferences.autoSwapEnabled && nearLimit
            ? min(interval, Self.nearLimitInterval) : interval
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

        var claude = TokenTotals()
        claude.tokens = 84_902_117
        claude.cost = 76.42
        var codex = TokenTotals()
        codex.tokens = 37_541_804
        codex.cost = 31.18
        var preview = TokenSummary()
        preview.today.tokens = claude.tokens + codex.tokens
        preview.today.cost = claude.cost + codex.cost
        preview.week.tokens = 611_804_291
        preview.week.cost = 528.37
        preview.byTool = [.claudeCode: claude, .codex: codex]
        preview.hourly = [0, 0, 0, 0, 0, 0, 400_000, 1_300_000, 3_100_000, 7_800_000,
                          11_200_000, 16_400_000, 22_100_000, 18_700_000, 14_200_000, 9_500_000,
                          8_100_000, 4_900_000, 2_700_000, 1_100_000, 0, 0, 0, 0]
        preview.tokensPerMinute = 18_420
        preview.lastActivity = now
        tokens = preview
        ticker.receive(preview.today.tokens, at: now)
        vibecomStanding = VibecomStanding(
            username: "sola",
            displayName: "Sola",
            rank: VibecomStanding.Rank(
                level: 8, name: "Staff Vibe Engineer", label: "Staff Engineer",
                progress: 0.42, nextName: "Context Maxxer I", tokensToNext: 12_900_000),
            weekly: VibecomStanding.Period(position: 12, tokens: 42_800_000),
            allTime: VibecomStanding.Period(position: 4, tokens: 611_800_000),
            streakDays: 9)
        lastUpdated = now
    }

    // MARK: - Reading usage

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let refreshedStanding = fetchVibecomStanding()
        let previous = statuses
        let current = await monitor.refreshAll()
        let final = await autoSwapIfNeeded(current)
        statuses = final
        if let refreshedStanding = await refreshedStanding {
            vibecomStanding = refreshedStanding
        }
        lastUpdated = Date()

        let alerts = NotificationPlanner(preferences: preferences)
            .notifications(previous: previous, current: final, now: Date())
        for alert in alerts { post(alert) }
    }

    private func autoSwapIfNeeded(_ current: [AccountStatus]) async -> [AccountStatus] {
        let owners = await monitor.lastLiveOwners
        for status in current { activityLog.record(AutoSwapPlanner.logLine(for: status)) }
        for (provider, owner) in owners.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            activityLog.record("\(provider.displayName) live login: \(describe(owner, in: current))")
        }
        autoSwapExplanations = Provider.allCases.compactMap {
            AutoSwapPlanner.explanation(for: $0, in: current)
        }
        guard preferences.autoSwapEnabled else {
            activityLog.record("Auto swap is off.")
            return current
        }
        for explanation in autoSwapExplanations { activityLog.record(explanation) }

        autoSwapAttempts.reconcile(with: current)

        var switched = false
        for decision in AutoSwapPlanner.decisions(in: current) {
            guard autoSwapAttempts.shouldAttempt(decision, now: Date()) else {
                activityLog.record(
                    "\(decision.provider.displayName): waiting to retry the failed switch to \(decision.to.label).")
                continue
            }
            autoSwapAttempts.record(decision, at: Date())
            activityLog.record(
                "Auto swap: \(decision.provider.displayName) \(decision.from.label) → \(decision.to.label)")
            do {
                try await monitor.activate(decision.to)
                switched = true
                switchFailure = nil
                autoSwapActivityIsFailure = false
                activityLog.record("Auto swap succeeded.")
                let relays = preferences.liveRelayEnabled && relayIsInstalled
                    ? relayController.queueHandoff(from: decision.from, to: decision.to) : 0
                if relays > 0 {
                    autoSwapActivity = "Moving \(relays) live \(decision.provider.displayName) session\(relays == 1 ? "" : "s") after the current turn."
                } else {
                    autoSwapActivity = decision.successMessage
                }
                if decision.requiresProcessRestart && relays == 0 {
                    post(
                        id: "auto-swap-codex-\(decision.to.id.uuidString)",
                        title: "Codex account changed",
                        body: "Quit the limited Codex session, then run codex resume to continue on the new account.")
                }
            } catch {
                let reason = Self.describeSwitchFailure(error)
                activityLog.record("Auto swap failed: \(reason) [\(error)]")
                autoSwapActivity = "Couldn't switch \(decision.provider.displayName): \(reason)"
                autoSwapActivityIsFailure = true
                switchFailure =
                    "Auto swap couldn't move \(decision.provider.displayName) to \(decision.to.label): \(reason)"
                post(
                    id: "auto-swap-failed-\(decision.from.id.uuidString)",
                    title: "\(decision.provider.displayName) account not switched",
                    body: "\(decision.from.label) is nearly spent, but switching to \(decision.to.label) failed: \(reason)")
            }
        }

        // Re-read once so the Active badge and menu-bar title immediately
        // reflect successful switches without recursively applying the policy.
        return switched ? await monitor.refreshAll() : current
    }

    private func fetchVibecomStanding() async -> VibecomStanding? {
        guard let vibecomProfile else { return nil }
        return try? await vibecomStandingService.fetch(vibecomProfile)
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
        guard switchingAccountID == nil else { return }
        switchingAccountID = status.id
        switchFailure = nil
        defer { switchingAccountID = nil }
        do {
            let source = statuses.first {
                $0.account.provider == status.account.provider && $0.isActive
            }?.account
            activityLog.record(
                "Use: \(status.account.provider.displayName) → \(status.account.label)")
            try await monitor.activate(status.account)
            let relays = preferences.liveRelayEnabled && relayIsInstalled
                ? relayController.queueHandoff(from: source, to: status.account) : 0
            if relays > 0 {
                autoSwapActivity = "Moving \(relays) live \(status.account.provider.displayName) session\(relays == 1 ? "" : "s") after the current turn."
            } else if status.account.provider == .codex {
                autoSwapActivity =
                    "Codex account changed. Restart Codex and resume this session to use it."
                post(
                    id: "manual-swap-codex-\(status.id.uuidString)",
                    title: "Codex account changed",
                    body: "Quit the current Codex session, then run codex resume to continue on this account.")
            }
            await refresh()
        } catch {
            activityLog.record("Use failed: \(error)")
            switchFailure =
                "Couldn't switch to \(status.account.label): \(Self.describeSwitchFailure(error))"
        }
    }

    func dismissSwitchFailure() { switchFailure = nil }

    func revealActivityLog() {
        NSWorkspace.shared.activateFileViewerSelecting([activityLog.url])
    }

    private func describe(_ owner: LiveLoginOwner, in statuses: [AccountStatus]) -> String {
        switch owner {
        case .account(let id):
            return statuses.first { $0.id == id }?.account.label ?? "a saved account"
        case .someoneElse: return "an account that isn't saved in vibecom bar"
        case .signedOut: return "signed out"
        case .unknown: return "couldn't be read or identified"
        }
    }

    static func describeSwitchFailure(_ error: Error) -> String {
        switch error {
        case SwitchError.savedLoginExpired:
            return "Its saved login has expired. Sign in to it again from Add Account; the account in use was left alone."
        case is UsageError, is URLError:
            return "Couldn't reach the provider to check the saved login. Try again when you're online."
        case VaultError.missingExternalSecret:
            return "Claude Code isn't signed in on this Mac. Run `claude` and sign in once, then try again."
        case VaultError.missingSecret:
            return "This account's saved login is missing. Remove it and add it again."
        case StoreError.securityToolTimedOut:
            return "macOS Keychain didn't respond in time. Unlock Keychain Access and try again."
        case StoreError.writeNotVerified:
            return "Keychain didn't confirm the new login. Run `claude auth status` to check Claude Code is still signed in."
        case StoreError.securityTool(let status):
            return "macOS Keychain refused the change (security exited \(status))."
        default:
            return error.localizedDescription
        }
    }

    func setLiveRelayEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try relayInstaller.install()
                relayIsInstalled = true
                preferences.liveRelayEnabled = true
                relayStatusMessage = "Ready. New Claude and Codex sessions can move accounts between turns."
            } else {
                try relayInstaller.uninstall()
                relayIsInstalled = false
                preferences.liveRelayEnabled = false
                relayStatusMessage = "Off. Your original Claude and Codex commands were restored."
            }
        } catch {
            relayIsInstalled = relayInstaller.isInstalled
            preferences.liveRelayEnabled = relayIsInstalled
            relayStatusMessage = error.localizedDescription
        }
    }

    func adoptExistingSession(provider: Provider, sessionID: String) {
        let identifier = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            relayStatusMessage = "Enter the session ID you want to resume."
            return
        }
        do {
            try TerminalRunner.resume(
                provider: provider, sessionID: identifier,
                relayEnabled: preferences.liveRelayEnabled && relayIsInstalled)
            relayStatusMessage = "Opened the session in a new relay-managed terminal."
        } catch {
            relayStatusMessage = error.localizedDescription
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
                if let service = ClaudeKeychain.newService(before: keychainBefore, after: after) {
                    do {
                        return try importer.captureClaudeLogin(
                            keychainService: service, configDir: profile)
                    } catch ImportError.noActiveLogin {
                        // Claude can create the item just before its contents
                        // are complete. Retry only that transient condition.
                    } catch {
                        // A denied keychain read must stop. Swallowing it here
                        // used to ask again every two seconds for ten minutes.
                        throw error
                    }
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
        post(id: alert.id, title: alert.title, body: alert.body)
    }

    private func post(id: String, title: String, body: String) {
        guard notificationsAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

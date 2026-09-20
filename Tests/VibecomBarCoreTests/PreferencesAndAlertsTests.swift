import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Preferences")
struct PreferencesTests {
    @Test("starts with settings that are useful before anything is configured")
    func defaults() {
        let preferences = Preferences()

        #expect(preferences.refreshInterval == 300)
        #expect(preferences.menuBarStyle == .activeAccounts)
        #expect(preferences.alertThresholds == [0.8, 0.95])
        #expect(preferences.notifyOnReset)
        #expect(!preferences.blurAccountNames)
        #expect(!preferences.autoSwapEnabled)
    }

    @Test("remembers settings across launches")
    func roundTrip() throws {
        let files = MemoryFileStore()
        let url = URL(fileURLWithPath: "/vault/preferences.json")
        var preferences = Preferences()
        preferences.refreshInterval = 60
        preferences.menuBarStyle = .highestUsage
        preferences.blurAccountNames = true
        preferences.autoSwapEnabled = true

        try PreferencesStore(files: files, url: url).save(preferences)

        let loaded = PreferencesStore(files: files, url: url).load()
        #expect(loaded.refreshInterval == 60)
        #expect(loaded.menuBarStyle == .highestUsage)
        #expect(loaded.blurAccountNames)
        #expect(loaded.autoSwapEnabled)
    }

    @Test("keeps existing preferences when privacy setting is introduced")
    func decodesLegacyPreferences() throws {
        let data = Data(
            """
            {
              "refreshInterval": 120,
              "menuBarStyle": "iconOnly",
              "alertThresholds": [0.95],
              "notifyOnReset": false,
              "showInactiveAccounts": false,
              "launchAtLogin": true
            }
            """.utf8)

        let preferences = try JSONDecoder().decode(Preferences.self, from: data)

        #expect(preferences.refreshInterval == 120)
        #expect(preferences.menuBarStyle == .iconOnly)
        #expect(preferences.launchAtLogin)
        #expect(!preferences.blurAccountNames)
        #expect(!preferences.autoSwapEnabled)
    }

    @Test("falls back to defaults when the settings file is damaged")
    func toleratesCorruptFile() {
        let files = MemoryFileStore(["/vault/preferences.json": Data("not json".utf8)])

        let loaded = PreferencesStore(files: files, url: URL(fileURLWithPath: "/vault/preferences.json")).load()

        #expect(loaded.refreshInterval == 300)
    }

    @Test("keeps polling sane no matter what is asked for")
    func clampsRefreshInterval() {
        var preferences = Preferences()

        preferences.refreshInterval = 5
        #expect(preferences.refreshInterval == 60)

        preferences.refreshInterval = 99_999
        #expect(preferences.refreshInterval == 3600)
    }
}

@Suite("Alerts")
struct NotificationPlannerTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)

    private func status(
        label: String, id: UUID, used: Double, error: AccountError? = nil, windowLabel: String = "Weekly"
    ) -> AccountStatus {
        let account = StoredAccount(
            id: id, provider: .claude, label: label, identity: AccountIdentity(email: label))
        return AccountStatus(
            account: account,
            snapshot: UsageSnapshot(
                provider: .claude,
                windows: [
                    UsageWindow(
                        id: "seven_day", label: windowLabel, kind: .weekly, usedFraction: used,
                        resetsAt: nil)
                ],
                plan: nil, email: nil, accountID: nil, fetchedAt: Self.now),
            error: error)
    }

    @Test("warns the first time a window crosses a threshold")
    func warnsOnCrossing() {
        let id = UUID()
        let planner = NotificationPlanner(thresholds: [0.8, 0.95], notifyOnReset: true)

        let alerts = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.7)],
            current: [status(label: "work", id: id, used: 0.82)], now: Self.now)

        #expect(alerts.count == 1)
        #expect(alerts[0].title == "work is at 82%")
        #expect(alerts[0].body.contains("Weekly"))
    }

    @Test("does not warn again while usage sits above the same threshold")
    func doesNotRepeatWarning() {
        let id = UUID()
        let planner = NotificationPlanner(thresholds: [0.8, 0.95], notifyOnReset: true)

        let alerts = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.82)],
            current: [status(label: "work", id: id, used: 0.9)], now: Self.now)

        #expect(alerts.isEmpty)
    }

    @Test("warns again at the higher threshold")
    func warnsAtEachThreshold() {
        let id = UUID()
        let planner = NotificationPlanner(thresholds: [0.8, 0.95], notifyOnReset: true)

        let alerts = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.9)],
            current: [status(label: "work", id: id, used: 0.96)], now: Self.now)

        #expect(alerts.count == 1)
        #expect(alerts[0].title == "work is at 96%")
    }

    @Test("says when a spent limit comes back")
    func announcesReset() {
        let id = UUID()
        let planner = NotificationPlanner(thresholds: [0.8], notifyOnReset: true)

        let alerts = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.97)],
            current: [status(label: "work", id: id, used: 0.02)], now: Self.now)

        #expect(alerts.count == 1)
        #expect(alerts[0].title == "work is back")
        #expect(alerts[0].kind == .windowReset)
    }

    @Test("stays quiet about resets when that has been turned off")
    func respectsResetPreference() {
        let id = UUID()
        let planner = NotificationPlanner(thresholds: [0.8], notifyOnReset: false)

        let alerts = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.97)],
            current: [status(label: "work", id: id, used: 0.02)], now: Self.now)

        #expect(alerts.isEmpty)
    }

    @Test("says once when an account needs signing in again")
    func announcesSignInNeeded() {
        let id = UUID()
        let planner = NotificationPlanner(thresholds: [0.8], notifyOnReset: true)

        let first = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.1)],
            current: [status(label: "work", id: id, used: 0.1, error: .needsLogin)], now: Self.now)
        let second = planner.notifications(
            previous: [status(label: "work", id: id, used: 0.1, error: .needsLogin)],
            current: [status(label: "work", id: id, used: 0.1, error: .needsLogin)], now: Self.now)

        #expect(first.count == 1)
        #expect(first[0].kind == .needsLogin)
        #expect(second.isEmpty)
    }

    @Test("says nothing about an account it is seeing for the first time")
    func ignoresNewAccounts() {
        let planner = NotificationPlanner(thresholds: [0.8], notifyOnReset: true)

        let alerts = planner.notifications(
            previous: [], current: [status(label: "work", id: UUID(), used: 0.99)], now: Self.now)

        #expect(alerts.isEmpty)
    }
}

@Suite("Guided sign-in")
struct GuidedLoginTests {
    static let profile = URL(fileURLWithPath: "/Users/me/Library/Application Support/VibecomBar/profiles/ABC")

    @Test("names the CLI it runs, whatever spaces the profile path contains")
    func namesExecutable() {
        #expect(GuidedLogin.codex(codexHome: Self.profile).executable == "codex")
        #expect(GuidedLogin.claude(configDir: Self.profile).executable == "claude")
    }

    @Test("signs a new Codex account in without disturbing the current one")
    func codexCommand() {
        let line = GuidedLogin.codex(codexHome: URL(fileURLWithPath: "/tmp/profile one"))
            .shellLine(executablePath: "/Users/me/.local/bin/codex")

        #expect(line == "CODEX_HOME='/tmp/profile one' '/Users/me/.local/bin/codex' login")
    }

    @Test("signs a new Claude account in under its own config directory")
    func claudeCommand() {
        let line = GuidedLogin.claude(configDir: URL(fileURLWithPath: "/tmp/profile one"))
            .shellLine(executablePath: "/Users/me/.local/bin/claude")

        #expect(line == "CLAUDE_CONFIG_DIR='/tmp/profile one' '/Users/me/.local/bin/claude' /login")
    }

    @Test("escapes a path that could otherwise break out of the quoting")
    func escapesQuotes() {
        let line = GuidedLogin.codex(codexHome: URL(fileURLWithPath: "/tmp/it's here"))
            .shellLine(executablePath: "codex")

        #expect(line == "CODEX_HOME='/tmp/it'\\''s here' 'codex' login")
    }
}

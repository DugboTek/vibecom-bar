import AppKit
import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Formatting")
struct FormattingTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)

    @Test("rounds usage to whole percents")
    func percent() {
        #expect(UsageFormatter.percent(0.426) == "43%")
        #expect(UsageFormatter.percent(0) == "0%")
        #expect(UsageFormatter.percent(1) == "100%")
    }

    @Test("the longest percentage fits its compact column on one line")
    func percentColumnFits() {
        let text = UsageFormatter.percent(1) as NSString
        let width = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]).width

        #expect(width <= UsageFormatter.percentColumnWidth)
    }

    @Test("never rounds a nearly spent window down to a comfortable number")
    func percentNearLimit() {
        #expect(UsageFormatter.percent(0.999) == "99%")
        #expect(UsageFormatter.percent(0.001) == "1%")
    }

    @Test("counts down to a reset in the units that matter at that distance")
    func countdown() {
        #expect(UsageFormatter.countdown(to: Self.now.addingTimeInterval(535_260), from: Self.now) == "6d 4h")
        #expect(UsageFormatter.countdown(to: Self.now.addingTimeInterval(5400), from: Self.now) == "1h 30m")
        #expect(UsageFormatter.countdown(to: Self.now.addingTimeInterval(600), from: Self.now) == "10m")
        #expect(UsageFormatter.countdown(to: Self.now.addingTimeInterval(30), from: Self.now) == "<1m")
    }

    @Test("says a window is back rather than showing a negative countdown")
    func countdownInThePast() {
        #expect(UsageFormatter.countdown(to: Self.now.addingTimeInterval(-10), from: Self.now) == "ready")
    }

    @Test("spells out the reset time so a weekly limit can be planned around")
    func resetDescription() {
        let text = UsageFormatter.resetDescription(
            at: Self.now.addingTimeInterval(535_260), from: Self.now,
            timeZone: TimeZone(identifier: "America/Chicago")!)

        #expect(text.contains("6d 4h"))
        #expect(text.contains("Sep 25"))
    }
}

@Suite("Menu bar title")
struct MenuBarTitleTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)

    private func status(
        _ provider: Provider, label: String, used: Double, active: Bool, error: AccountError? = nil
    ) -> AccountStatus {
        let account = StoredAccount(
            provider: provider, label: label, identity: AccountIdentity(email: label))
        let snapshot = UsageSnapshot(
            provider: provider,
            windows: [
                UsageWindow(id: "w", label: "Weekly", kind: .weekly, usedFraction: used, resetsAt: nil)
            ],
            plan: nil, email: nil, accountID: nil, fetchedAt: Self.now)
        return AccountStatus(account: account, snapshot: snapshot, error: error, isActive: active)
    }

    @Test("shows the signed-in account for each CLI, most pressing first")
    func showsActiveAccounts() {
        let title = MenuBarTitle.text(
            for: [
                status(.claude, label: "work", used: 0.2, active: true),
                status(.claude, label: "personal", used: 0.9, active: false),
                status(.codex, label: "main", used: 0.99, active: true),
            ], style: .activeAccounts)

        #expect(title == "CX 99% · CC 20%")
    }

    @Test("can show the account closest to running out across every account")
    func showsWorstAccount() {
        let title = MenuBarTitle.text(
            for: [
                status(.claude, label: "work", used: 0.2, active: true),
                status(.codex, label: "main", used: 0.91, active: false),
            ], style: .highestUsage)

        #expect(title == "CX 91%")
    }

    @Test("can show today's token count instead of limits")
    func showsTokensToday() {
        var summary = TokenSummary()
        summary.today.tokens = 1_284_000_000

        let title = MenuBarTitle.text(
            for: [status(.claude, label: "work", used: 0.2, active: true)], style: .tokensToday,
            tokens: summary)

        #expect(title == "1.3B")
    }

    @Test("falls back to the brand mark before any account is added")
    func emptyState() {
        #expect(MenuBarTitle.text(for: [], style: .activeAccounts) == "")
    }

    @Test("flags an account that needs signing in again instead of showing a stale number")
    func needsLogin() {
        let title = MenuBarTitle.text(
            for: [status(.claude, label: "work", used: 0.2, active: true, error: .needsLogin)],
            style: .activeAccounts)

        #expect(title == "CC sign in")
    }
}

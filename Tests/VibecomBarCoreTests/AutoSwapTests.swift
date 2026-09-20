import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Auto swap")
struct AutoSwapTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)

    private func status(
        _ label: String, provider: Provider = .claude, active: Bool = false,
        used: Double, resetIn: TimeInterval?, error: AccountError? = nil, sortIndex: Int = 0
    ) -> AccountStatus {
        let account = StoredAccount(
            provider: provider, label: label, identity: AccountIdentity(email: label),
            sortIndex: sortIndex)
        return AccountStatus(
            account: account,
            snapshot: UsageSnapshot(
                provider: provider,
                windows: [
                    UsageWindow(
                        id: "weekly", label: "Weekly", kind: .weekly,
                        usedFraction: used,
                        resetsAt: resetIn.map { Self.now.addingTimeInterval($0) })
                ],
                plan: nil, email: label, accountID: nil, fetchedAt: Self.now),
            error: error, isActive: active)
    }

    @Test("chooses the available account whose reset is soonest")
    func nearestResetWins() throws {
        let statuses = [
            status("spent", active: true, used: 1, resetIn: 3600),
            status("later", used: 0.1, resetIn: 86_400),
            status("sooner", used: 0.7, resetIn: 7200),
        ]

        let decision = try #require(
            AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now))

        #expect(decision.from.label == "spent")
        #expect(decision.to.label == "sooner")
    }

    @Test("uses remaining capacity to break equal reset times")
    func capacityBreaksTie() throws {
        let statuses = [
            status("spent", active: true, used: 1, resetIn: 3600),
            status("busier", used: 0.8, resetIn: 7200),
            status("freer", used: 0.2, resetIn: 7200),
        ]

        let decision = try #require(
            AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now))
        #expect(decision.to.label == "freer")
    }

    @Test("switches when the active account reaches 99 percent")
    func switchesAtNinetyNinePercent() throws {
        let statuses = [
            status("active", active: true, used: 0.99, resetIn: 3600),
            status("free", used: 0, resetIn: 7200),
        ]

        let decision = try #require(
            AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now))
        #expect(decision.to.label == "free")
    }

    @Test("does nothing before the active account reaches 99 percent")
    func waitsForExhaustion() {
        let statuses = [
            status("active", active: true, used: 0.98, resetIn: 3600),
            status("free", used: 0, resetIn: 7200),
        ]

        #expect(AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now) == nil)
    }

    @Test("never switches to another spent or unhealthy account")
    func requiresHealthyCapacity() {
        let statuses = [
            status("active", active: true, used: 1, resetIn: 3600),
            status("spent", used: 1, resetIn: 1800),
            status("offline", used: 0, resetIn: 900, error: .unreachable),
        ]

        #expect(AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now) == nil)
    }

    @Test("plans Claude and Codex independently")
    func separatesProviders() {
        let statuses = [
            status("claude spent", active: true, used: 1, resetIn: 3600),
            status("claude free", used: 0, resetIn: 7200),
            status("codex spent", provider: .codex, active: true, used: 1, resetIn: 3600),
            status("codex free", provider: .codex, used: 0, resetIn: 7200),
        ]

        let decisions = AutoSwapPlanner.decisions(in: statuses, now: Self.now)
        #expect(decisions.map(\.provider) == [.claude, .codex])
    }
}

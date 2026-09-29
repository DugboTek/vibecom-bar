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

    @Test("never switches to another spent account or one that needs signing in")
    func requiresHealthyCapacity() {
        let statuses = [
            status("active", active: true, used: 1, resetIn: 3600),
            status("spent", used: 1, resetIn: 1800),
            status("signed out", used: 0, resetIn: 900, error: .needsLogin),
            status("no scope", used: 0, resetIn: 900, error: .cannotReadUsage),
        ]

        #expect(AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now) == nil)
    }

    @Test("still switches to an account whose last reading was rate limited")
    func toleratesTransientErrors() throws {
        for error in [AccountError.rateLimited, .unreachable] {
            let statuses = [
                status("active", active: true, used: 1, resetIn: 3600),
                status("throttled", used: 0.1, resetIn: 900, error: error),
            ]
            let decision = try #require(
                AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now))
            #expect(decision.to.label == "throttled")
        }
    }

    @Test("explains why it is not switching")
    func explainsDecisions() {
        let waiting = [status("main", active: true, used: 0.63, resetIn: 3600)]
        #expect(AutoSwapPlanner.explanation(for: .claude, in: waiting, now: Self.now)
            == "Claude Code: main is at 63%; switches at 99%.")

        let stuck = [
            status("main", active: true, used: 1, resetIn: 3600),
            status("other", used: 1, resetIn: 900),
            status("old", used: 0, resetIn: 900, error: .needsLogin),
        ]
        #expect(AutoSwapPlanner.explanation(for: .claude, in: stuck, now: Self.now)
            == "Claude Code: main is spent, but no other account is ready (other — also spent; old — sign in again).")

        let going = [
            status("main", active: true, used: 1, resetIn: 3600),
            status("fresh", used: 0, resetIn: 900),
        ]
        #expect(AutoSwapPlanner.explanation(for: .claude, in: going, now: Self.now)
            == "Claude Code: main is spent; switching to fresh.")

        let nobody = [status("main", used: 0.2, resetIn: 900)]
        #expect(AutoSwapPlanner.explanation(for: .claude, in: nobody, now: Self.now)?
            .contains("none of your saved accounts is the one signed in") == true)
        #expect(AutoSwapPlanner.explanation(for: .codex, in: nobody, now: Self.now) == nil)
    }

    @Test("describes each account for the activity log without any token")
    func logLines() {
        let line = AutoSwapPlanner.logLine(
            for: status("main", active: true, used: 0.5, resetIn: 60, error: .rateLimited))
        #expect(line == "Claude Code main | ACTIVE | Weekly 50% | error: Rate limited — retrying")
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

    @Test("tells Codex users that a running session must be resumed")
    func explainsCodexProcessRestart() throws {
        let statuses = [
            status("spent", provider: .codex, active: true, used: 1, resetIn: 3600),
            status("free", provider: .codex, used: 0, resetIn: 7200),
        ]
        let decision = try #require(
            AutoSwapPlanner.decision(for: .codex, in: statuses, now: Self.now))

        #expect(decision.requiresProcessRestart)
        #expect(decision.successMessage.contains("Restart Codex"))
        #expect(decision.successMessage.contains("resume this session"))
    }

    @Test("does not ask Claude users to restart")
    func claudeSwitchesLive() throws {
        let statuses = [
            status("spent", active: true, used: 1, resetIn: 3600),
            status("free", used: 0, resetIn: 7200),
        ]
        let decision = try #require(
            AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now))

        #expect(!decision.requiresProcessRestart)
        #expect(!decision.successMessage.contains("Restart"))
    }

    @Test("retries a failed switch after the cooldown instead of never")
    func retriesFailedSwitchAfterCooldown() throws {
        let statuses = [
            status("spent", active: true, used: 1, resetIn: 3600),
            status("fresh", used: 0.1, resetIn: 7200),
        ]
        let decision = try #require(
            AutoSwapPlanner.decision(for: .claude, in: statuses, now: Self.now))
        var attempts = AutoSwapAttempts()

        #expect(attempts.shouldAttempt(decision, now: Self.now))
        attempts.record(decision, at: Self.now)
        attempts.reconcile(with: statuses)

        #expect(!attempts.shouldAttempt(decision, now: Self.now.addingTimeInterval(300)))
        #expect(attempts.shouldAttempt(
            decision, now: Self.now.addingTimeInterval(AutoSwapAttempts.retryInterval)))
    }

    @Test("forgets an attempt once the active account changes or recovers")
    func reconcileClearsAttempts() throws {
        let spent = status("spent", active: true, used: 1, resetIn: 3600)
        let fresh = status("fresh", used: 0.1, resetIn: 7200)
        let decision = try #require(
            AutoSwapPlanner.decision(for: .claude, in: [spent, fresh], now: Self.now))
        let soon = Self.now.addingTimeInterval(60)

        var switched = AutoSwapAttempts()
        switched.record(decision, at: Self.now)
        var nowActive = fresh
        nowActive.isActive = true
        var nowInactive = spent
        nowInactive.isActive = false
        switched.reconcile(with: [nowInactive, nowActive])
        #expect(switched.shouldAttempt(decision, now: soon))

        var recovered = AutoSwapAttempts()
        recovered.record(decision, at: Self.now)
        let reset = AccountStatus(
            account: spent.account, snapshot: fresh.snapshot, error: nil, isActive: true)
        recovered.reconcile(with: [reset, fresh])
        #expect(recovered.shouldAttempt(decision, now: soon))
    }

    @Test("keeps the cooldown per provider")
    func attemptsArePerProvider() throws {
        let claude = try #require(AutoSwapPlanner.decision(
            for: .claude,
            in: [status("c-spent", active: true, used: 1, resetIn: 3600),
                 status("c-fresh", used: 0.1, resetIn: 7200)],
            now: Self.now))
        let codex = try #require(AutoSwapPlanner.decision(
            for: .codex,
            in: [status("x-spent", provider: .codex, active: true, used: 1, resetIn: 3600),
                 status("x-fresh", provider: .codex, used: 0.1, resetIn: 7200)],
            now: Self.now))
        var attempts = AutoSwapAttempts()
        attempts.record(claude, at: Self.now)

        #expect(!attempts.shouldAttempt(claude, now: Self.now))
        #expect(attempts.shouldAttempt(codex, now: Self.now))
    }
}

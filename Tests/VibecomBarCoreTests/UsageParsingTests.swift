import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Claude usage parsing")
struct ClaudeUsageParsingTests {
    @Test("shows the same limits, in the same order, as Claude Code's /usage")
    func readsLimitsList() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows.map(\.label) == ["5-hour session", "Weekly (all models)", "Weekly (Fable)"])
        #expect(snapshot.windows.map(\.kind) == [.session, .weekly, .weeklyModel])
    }

    @Test("reads 1 as one percent, not as a spent limit")
    func onePercentIsOnePercent() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows[0].usedFraction == 0.03)
        #expect(snapshot.windows[1].usedFraction == 0.01)
        #expect(snapshot.windows[2].usedFraction == 0)
        #expect(!snapshot.windows[1].isExhausted)
    }

    @Test("parses the reset timestamp including fractional seconds")
    func parsesResetDate() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try #require(formatter.date(from: "2026-09-19T19:20:00.468931Z"))
        let parsed = try #require(snapshot.windows[0].resetsAt)
        #expect(abs(parsed.timeIntervalSince(expected)) < 0.001)
    }

    @Test("falls back to the per-window fields, which are also percentages")
    func legacyFieldsArePercentages() throws {
        let snapshot = try ClaudeUsageParser.snapshot(
            from: Fixture.data("claude_usage_legacy"), fetchedAt: .distantPast)

        #expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(snapshot.windows[0].usedFraction == 0.42)
        #expect(snapshot.windows[1].usedFraction == 0.01)
        #expect(snapshot.windows[2].usedFraction == 1)
    }

    @Test("ignores internal limits that are not part of the coding plan")
    func ignoresUnknownWindows() throws {
        let snapshot = try ClaudeUsageParser.snapshot(
            from: Fixture.data("claude_usage_legacy"), fetchedAt: .distantPast)

        #expect(!snapshot.windows.contains { $0.id == "nimbus_quill" })
    }

    @Test("marks a window the provider reports as locked")
    func readsLockedReason() throws {
        let snapshot = try ClaudeUsageParser.snapshot(
            from: Fixture.data("claude_usage_legacy"), fetchedAt: .distantPast)

        #expect(snapshot.windows[2].isExhausted)
        #expect(!snapshot.windows[0].isExhausted)
    }
}

@Suite("Codex usage parsing")
struct CodexUsageParsingTests {
    @Test("names each window after the length of the limit window")
    func namesWindowsByDuration() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows.map(\.label) == ["Weekly", "5-hour session"])
        #expect(snapshot.windows[0].kind == .weekly)
        #expect(snapshot.windows[1].kind == .session)
    }

    @Test("converts a whole-number percent into a fraction")
    func convertsPercent() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows[0].usedFraction == 0.99)
        #expect(snapshot.windows[1].usedFraction == 0.125)
    }

    @Test("reads the reset time from the epoch timestamp")
    func readsResetEpoch() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_790_362_999))
    }

    @Test("carries the plan and the account the token belongs to")
    func readsIdentity() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.plan == "pro")
        #expect(snapshot.email == "builder@example.com")
        #expect(snapshot.accountID == "3e2d996c-de48-4a66-957b-ed8f1293c63d")
    }

    @Test("leaves out secondary limits that are not the plan's own quota")
    func skipsAdditionalLimits() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows.count == 2)
    }
}

@Suite("Snapshot headline")
struct SnapshotHeadlineTests {
    @Test("headlines the window closest to running out")
    func picksMostUsedWindow() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.headline?.label == "Weekly")
    }

    @Test("has no headline when the provider reports no windows")
    func emptySnapshot() {
        let snapshot = UsageSnapshot(
            provider: .claude, windows: [], plan: nil, email: nil, accountID: nil, fetchedAt: .distantPast)

        #expect(snapshot.headline == nil)
    }
}

@Suite("Codex limit resets")
struct CodexResetCreditTests {
    @Test("reads how many limit resets the account can spend")
    func readsResetCredits() throws {
        let snapshot = try CodexUsageParser.snapshot(from: Fixture.data("codex_usage"), fetchedAt: .distantPast)

        #expect(snapshot.resetCredits == ResetCredits(available: 2, usableNow: 0))
    }

    @Test("reports no reset information when the plan does not have any")
    func absentResetCredits() throws {
        let snapshot = try CodexUsageParser.snapshot(
            from: Data(#"{"plan_type":"plus","rate_limit":{}}"#.utf8), fetchedAt: .distantPast)

        #expect(snapshot.resetCredits == nil)
    }

    @Test("counts resets in words")
    func describesResets() {
        #expect(ResetCredits(available: 1, usableNow: 0).summary == "1 reset")
        #expect(ResetCredits(available: 3, usableNow: 1).summary == "3 resets")
        #expect(ResetCredits(available: 0, usableNow: 0).summary == "No resets")
    }
}

@Suite("Account reset line")
struct AccountResetLineTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)

    private func status(_ windows: [UsageWindow]) -> AccountStatus {
        AccountStatus(
            account: StoredAccount(provider: .codex, label: "a", identity: AccountIdentity()),
            snapshot: UsageSnapshot(
                provider: .codex, windows: windows, plan: nil, email: nil, accountID: nil, fetchedAt: Self.now))
    }

    @Test("counts down to when the most pressing limit resets")
    func countsDownToHeadlineReset() {
        let line = UsageFormatter.resetLine(
            for: status([
                UsageWindow(
                    id: "a", label: "5-hour session", kind: .session, usedFraction: 0.1,
                    resetsAt: Self.now.addingTimeInterval(3600)),
                UsageWindow(
                    id: "b", label: "Weekly", kind: .weekly, usedFraction: 0.6,
                    resetsAt: Self.now.addingTimeInterval(200_000)),
            ]), now: Self.now)

        #expect(line == "Weekly resets in 2d 7h")
    }

    @Test("says when a spent account is usable again")
    func spentAccountSaysWhenItIsBack() {
        let line = UsageFormatter.resetLine(
            for: status([
                UsageWindow(
                    id: "a", label: "5-hour session", kind: .session, usedFraction: 1,
                    resetsAt: Self.now.addingTimeInterval(4000)),
                UsageWindow(
                    id: "b", label: "Weekly", kind: .weekly, usedFraction: 1,
                    resetsAt: Self.now.addingTimeInterval(90_000)),
            ]), now: Self.now)

        #expect(line == "Out of usage · back in 1d 1h")
    }

    @Test("has nothing to say without a reset time")
    func noResetTime() {
        let line = UsageFormatter.resetLine(
            for: status([
                UsageWindow(id: "a", label: "Weekly", kind: .weekly, usedFraction: 0.2, resetsAt: nil)
            ]), now: Self.now)

        #expect(line == nil)
    }
}

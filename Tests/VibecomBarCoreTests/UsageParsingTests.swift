import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Claude usage parsing")
struct ClaudeUsageParsingTests {
    @Test("reads each non-null limit window as a fraction of its limit")
    func readsWindows() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        #expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(snapshot.windows[0].label == "5-hour session")
        #expect(snapshot.windows[0].usedFraction == 0.42)
        #expect(snapshot.windows[1].label == "Weekly (all models)")
        #expect(snapshot.windows[1].usedFraction == 0.7)
        #expect(snapshot.windows[2].label == "Weekly (Opus)")
    }

    @Test("skips limits the account does not have")
    func skipsNullWindows() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        #expect(!snapshot.windows.contains { $0.id == "seven_day_sonnet" })
    }

    @Test("ignores internal limits that are not part of the coding plan")
    func ignoresUnknownWindows() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        #expect(!snapshot.windows.contains { $0.id == "nimbus_quill" })
    }

    @Test("parses the reset timestamp including fractional seconds")
    func parsesResetDate() throws {
        let snapshot = try ClaudeUsageParser.snapshot(from: Fixture.data("claude_usage"), fetchedAt: .distantPast)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2026-09-19T19:20:00.689272Z")
        #expect(snapshot.windows[0].resetsAt == expected)
    }

    @Test("treats a utilization above 1 as a percentage, not a fraction")
    func toleratesPercentScale() throws {
        let snapshot = try ClaudeUsageParser.snapshot(
            from: Fixture.data("claude_usage_percent_scale"), fetchedAt: .distantPast)

        #expect(snapshot.windows[0].usedFraction == 0.42)
        #expect(snapshot.windows[1].usedFraction == 1.0)
    }

    @Test("marks a window the provider reports as locked")
    func readsLockedReason() throws {
        let snapshot = try ClaudeUsageParser.snapshot(
            from: Fixture.data("claude_usage_percent_scale"), fetchedAt: .distantPast)

        #expect(snapshot.windows[1].isExhausted)
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

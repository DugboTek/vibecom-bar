import Foundation
import Testing

@testable import VibecomBarCore

private func claudeLine(
    id: String, model: String = "claude-opus-5", input: Int = 0, output: Int = 0, cacheRead: Int = 0,
    cacheCreation: Int = 0, oneHour: Int = 0, at timestamp: String
) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"req_\(id)","uuid":"u_\(id)","message":{"id":"\(id)","model":"\(model)","content":[{"type":"text","text":"never read"}],"usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheCreation),"cache_creation":{"ephemeral_1h_input_tokens":\(oneHour),"ephemeral_5m_input_tokens":\(cacheCreation - oneHour)}}}}
    """
}

private func codexTokenLine(input: Int, cached: Int, output: Int, totalInput: Int, at timestamp: String) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(totalInput),"cached_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,"cache_write_input_tokens":0},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"cache_write_input_tokens":0}}}}
    """
}

private func codexModelLine(_ model: String, at timestamp: String) -> String {
    #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"\#(model)","cwd":"/x"}}"#
}

@Suite("Transcript lines")
struct TranscriptLineTests {
    @Test("splits a Claude message's usage into the classes pricing needs")
    func claudeUsage() throws {
        let line = claudeLine(
            id: "m1", input: 2, output: 364, cacheRead: 23_766, cacheCreation: 26_745, oneHour: 26_000,
            at: "2026-09-19T14:21:49.595Z")

        let parsed = try #require(ClaudeTranscript.parse(Data(line.utf8)))

        #expect(parsed.key == "m1")
        #expect(parsed.event.model == "claude-opus-5")
        #expect(
            parsed.event.usage
                == TokenUsage(
                    inputTokens: 2, outputTokens: 364, cacheReadTokens: 23_766, cacheWrite5mTokens: 745,
                    cacheWrite1hTokens: 26_000))
        #expect(parsed.event.tool == .claudeCode)
    }

    @Test("ignores Claude records that carry no usage")
    func claudeNonUsage() {
        #expect(ClaudeTranscript.parse(Data(#"{"type":"user","message":{"content":"hi"}}"#.utf8)) == nil)
        #expect(ClaudeTranscript.parse(Data("not json".utf8)) == nil)
    }

    @Test("counts a Codex request once even when its running total repeats")
    func codexDedupes() {
        var reader = CodexTranscript()
        let first = codexTokenLine(input: 100, cached: 40, output: 10, totalInput: 100, at: "2026-09-19T17:00:00Z")

        let a = reader.consume(Data(codexModelLine("gpt-5.6-sol", at: "2026-09-19T17:00:00Z").utf8))
        let b = reader.consume(Data(first.utf8))
        let c = reader.consume(Data(first.utf8))

        #expect(a == nil)
        #expect(c == nil)
        let event = b
        #expect(event?.model == "gpt-5.6-sol")
        #expect(event?.tool == .codex)
        #expect(event?.usage == TokenUsage(inputTokens: 60, outputTokens: 10, cacheReadTokens: 40))
    }
}

@Suite("Token ledger", .serialized)
struct TokenLedgerTests {
    static let now = ISO8601.date(from: "2026-09-19T18:00:00Z")!
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func sandbox() throws -> (URL, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-ledger-\(UUID().uuidString)")
        let claude = root.appendingPathComponent("claude/projects/-Users-me-app")
        let codex = root.appendingPathComponent("codex/sessions/2026/09/19")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return (root, claude, codex)
    }

    private func ledger(_ root: URL) -> TokenLedger {
        TokenLedger(
            claudeRoot: root.appendingPathComponent("claude/projects"),
            codexRoot: root.appendingPathComponent("codex/sessions"),
            calendar: Self.utc)
    }

    private func write(_ lines: [String], to url: URL, append: Bool = false) throws {
        let text = lines.map { $0 + "\n" }.joined()
        if append, let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    @Test("adds up today's tokens and cost across both CLIs")
    func totalsToday() async throws {
        let (root, claude, codex) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [claudeLine(id: "a", input: 1_000_000, output: 1_000_000, at: "2026-09-19T10:00:00Z")],
            to: claude.appendingPathComponent("s1.jsonl"))
        try write(
            [
                codexModelLine("gpt-5.6-terra", at: "2026-09-19T11:00:00Z"),
                codexTokenLine(input: 100_000, cached: 0, output: 0, totalInput: 100_000, at: "2026-09-19T11:00:00Z"),
            ], to: codex.appendingPathComponent("rollout-1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.today.tokens == 2_100_000)
        #expect(abs(summary.today.cost - 30.2) < 1e-9)
        #expect(summary.byTool[.claudeCode]?.tokens == 2_000_000)
        #expect(summary.byTool[.codex]?.tokens == 100_000)
    }

    @Test("keeps yesterday out of today but inside the last seven days")
    func separatesDays() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [
                claudeLine(id: "old", output: 500, at: "2026-09-18T23:00:00Z"),
                claudeLine(id: "new", output: 200, at: "2026-09-19T01:00:00Z"),
            ], to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.today.tokens == 200)
        #expect(summary.week.tokens == 700)
    }

    @Test("counts a streamed Claude message once, at its final size")
    func streamedMessageCountsOnce() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [
                claudeLine(id: "m", input: 10, output: 5, at: "2026-09-19T10:00:00Z"),
                claudeLine(id: "m", input: 10, output: 50, at: "2026-09-19T10:00:01Z"),
            ], to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.today.tokens == 60)
    }

    @Test("counts a message copied into a resumed session once")
    func resumedSessionCountsOnce() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let line = claudeLine(id: "shared", output: 100, at: "2026-09-19T10:00:00Z")
        try write([line], to: claude.appendingPathComponent("s1.jsonl"))
        try write([line], to: claude.appendingPathComponent("s2.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.today.tokens == 100)
    }

    @Test("picks up new lines as a live session writes them, without recounting old ones")
    func readsIncrementally() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = claude.appendingPathComponent("s1.jsonl")
        try write([claudeLine(id: "a", output: 100, at: "2026-09-19T10:00:00Z")], to: file)
        let ledger = ledger(root)
        _ = await ledger.update(now: Self.now)

        try write([claudeLine(id: "b", output: 40, at: "2026-09-19T17:59:00Z")], to: file, append: true)
        let summary = await ledger.update(now: Self.now)

        #expect(summary.today.tokens == 140)
    }

    @Test("re-checks known sessions every tick and walks for new ones once a minute")
    func discoversNewSessions() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([claudeLine(id: "a", output: 100, at: "2026-09-19T10:00:00Z")], to: claude.appendingPathComponent("s1.jsonl"))
        let ledger = ledger(root)
        _ = await ledger.update(now: Self.now)

        try write([claudeLine(id: "b", output: 5, at: "2026-09-19T17:59:00Z")], to: claude.appendingPathComponent("s2.jsonl"))
        let soon = await ledger.update(now: Self.now.addingTimeInterval(5))
        let later = await ledger.update(now: Self.now.addingTimeInterval(61))

        #expect(soon.today.tokens == 100)
        #expect(later.today.tokens == 105)
    }

    @Test("waits for a line that is still being written")
    func skipsPartialLine() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = claude.appendingPathComponent("s1.jsonl")
        let full = claudeLine(id: "a", output: 100, at: "2026-09-19T10:00:00Z")
        try Data((full + "\n" + String(full.prefix(40))).utf8).write(to: file)
        let ledger = ledger(root)

        let first = await ledger.update(now: Self.now)
        try Data((full + "\n" + claudeLine(id: "b", output: 7, at: "2026-09-19T10:00:00Z") + "\n").utf8)
            .write(to: file)
        let second = await ledger.update(now: Self.now)

        #expect(first.today.tokens == 100)
        #expect(second.today.tokens == 107)
    }

    @Test("reports the live rate over the last five minutes")
    func liveRate() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [
                claudeLine(id: "a", output: 1_000, at: "2026-09-19T17:58:00Z"),
                claudeLine(id: "b", output: 4_000, at: "2026-09-19T17:59:30Z"),
                claudeLine(id: "c", output: 9_999, at: "2026-09-19T12:00:00Z"),
            ], to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.tokensPerMinute == 1_000)
        #expect(summary.lastActivity == ISO8601.date(from: "2026-09-19T17:59:30Z"))
        #expect(summary.isLive(at: Self.now))
    }

    @Test("puts each hour's tokens in its own bucket")
    func hourlyBuckets() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [
                claudeLine(id: "a", output: 10, at: "2026-09-19T09:10:00Z"),
                claudeLine(id: "b", output: 20, at: "2026-09-19T09:50:00Z"),
                claudeLine(id: "c", output: 5, at: "2026-09-19T17:00:00Z"),
            ], to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.hourly.count == 24)
        #expect(summary.hourly[9] == 30)
        #expect(summary.hourly[17] == 5)
    }

    @Test("ranks today's models by volume")
    func topModels() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [
                claudeLine(id: "a", model: "claude-opus-5", output: 10, at: "2026-09-19T09:00:00Z"),
                claudeLine(id: "b", model: "claude-sonnet-5", output: 90, at: "2026-09-19T09:00:00Z"),
            ], to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.topModels.map(\.model) == ["claude-sonnet-5", "claude-opus-5"])
    }

    @Test("leaves models that used no tokens out of the ranking")
    func skipsEmptyModels() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [
                claudeLine(id: "a", model: "claude-opus-5", output: 10, at: "2026-09-19T09:00:00Z"),
                claudeLine(id: "b", model: "claude-sonnet-4-6[1m]", at: "2026-09-19T09:00:00Z"),
            ], to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.topModels.map(\.model) == ["claude-opus-5"])
    }

    @Test("keeps tokens from a model without a published rate visible")
    func unpricedTokens() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(
            [claudeLine(id: "a", model: "mystery-model", output: 500, at: "2026-09-19T09:00:00Z")],
            to: claude.appendingPathComponent("s1.jsonl"))

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.today.tokens == 500)
        #expect(summary.today.unpricedTokens == 500)
        #expect(summary.today.cost == 0)
    }

    @Test("does not open transcripts untouched for longer than the lookback")
    func skipsOldFiles() async throws {
        let (root, claude, _) = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = claude.appendingPathComponent("old.jsonl")
        try write([claudeLine(id: "a", output: 100, at: "2026-09-19T10:00:00Z")], to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.now.addingTimeInterval(-30 * 86_400)], ofItemAtPath: file.path)

        let summary = await ledger(root).update(now: Self.now)

        #expect(summary.today.tokens == 0)
    }
}

@Suite("Token formatting")
struct TokenFormattingTests {
    @Test("shortens large counts the way the menu bar has room for")
    func compact() {
        #expect(UsageFormatter.tokens(512) == "512")
        #expect(UsageFormatter.tokens(940_000) == "940K")
        #expect(UsageFormatter.tokens(18_234_000) == "18.2M")
        #expect(UsageFormatter.tokens(1_200_000_000) == "1.2B")
        #expect(UsageFormatter.tokens(3_000_000) == "3M")
    }

    @Test("shows cost in dollars with cents")
    func dollars() {
        #expect(UsageFormatter.dollars(41.3) == "$41.30")
        #expect(UsageFormatter.dollars(1234.5) == "$1,234.50")
    }
}

import Foundation

/// Which coding tool a token event came from.
public enum CodingTool: String, Sendable, CaseIterable, Identifiable {
    case claudeCode
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One billable request, derived from a transcript line. Only these counters
/// ever leave this file — prompts and responses are never kept.
public struct TokenEvent: Equatable, Sendable {
    public let tool: CodingTool
    public let model: String?
    public let usage: TokenUsage
    public let timestamp: Date
    /// List-price cost, or nil when the model has no published rate.
    public let cost: Double?

    public init(tool: CodingTool, model: String?, usage: TokenUsage, timestamp: Date) {
        self.tool = tool
        self.model = model
        self.usage = usage
        self.timestamp = timestamp
        cost = Pricing.price(model: model, usage: usage)
    }
}

// MARK: - Parsing, ported from vibecom's cli/src/transcripts.ts

public enum ClaudeTranscript {
    static let usageMarker = Data(#""usage""#.utf8)

    /// A Claude Code transcript line with usage, keyed by the message it
    /// belongs to: a streamed reply repeats one message as it grows.
    public static func parse(_ line: Data) -> (key: String, event: TokenEvent)? {
        // Most lines are prompts, tool output and file contents; skip them unparsed.
        guard line.contains(marker: usageMarker),
            let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let message = record["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let timestamp = (record["timestamp"] as? String).flatMap(ISO8601.date(from:))
        else { return nil }

        let key =
            message["id"] as? String ?? record["requestId"] as? String ?? record["uuid"] as? String
        guard let key else { return nil }

        let creation = int(usage["cache_creation_input_tokens"])
        let oneHour = int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let tokens = TokenUsage(
            inputTokens: int(usage["input_tokens"]),
            outputTokens: int(usage["output_tokens"]),
            cacheReadTokens: int(usage["cache_read_input_tokens"]),
            cacheWrite5mTokens: max(0, creation - oneHour),
            cacheWrite1hTokens: oneHour)

        return (
            key,
            TokenEvent(
                tool: .claudeCode, model: message["model"] as? String, usage: tokens, timestamp: timestamp)
        )
    }
}

/// Codex writes a running total after every event, so a request is a change
/// in that total; `last_token_usage` is the request itself.
public struct CodexTranscript: Sendable {
    private var previousTotal: [Int]?
    private var model: String?

    static let markers = [
        Data(#""token_count""#.utf8), Data(#""turn_context""#.utf8), Data(#""session_meta""#.utf8),
    ]

    public init() {}

    public mutating func consume(_ line: Data) -> TokenEvent? {
        guard Self.markers.contains(where: { line.contains(marker: $0) }),
            let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        let payload = record["payload"] as? [String: Any] ?? [:]
        let type = record["type"] as? String

        if type == "session_meta" || type == "turn_context", let model = payload["model"] as? String {
            self.model = model
            return nil
        }
        guard payload["type"] as? String == "token_count",
            let info = payload["info"] as? [String: Any],
            let total = info["total_token_usage"] as? [String: Any]
        else { return nil }

        let tuple = [
            "input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens",
            "cache_write_input_tokens",
        ].map { int(total[$0]) }
        guard tuple != previousTotal else { return nil }
        previousTotal = tuple

        guard let last = info["last_token_usage"] as? [String: Any],
            let timestamp = (record["timestamp"] as? String).flatMap(ISO8601.date(from:))
        else { return nil }

        // Cached input is a subset of input, not a sibling of it.
        let wholeInput = int(last["input_tokens"])
        let cached = min(int(last["cached_input_tokens"]), wholeInput)
        return TokenEvent(
            tool: .codex,
            model: model,
            usage: TokenUsage(
                inputTokens: wholeInput - cached,
                outputTokens: int(last["output_tokens"]),
                cacheReadTokens: cached,
                cacheWrite5mTokens: int(last["cache_write_input_tokens"])),
            timestamp: timestamp)
    }
}

extension Data {
    /// memmem, which is far faster than `range(of:)` on multi-megabyte lines.
    func contains(marker: Data) -> Bool {
        withUnsafeBytes { haystack in
            marker.withUnsafeBytes { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
    }
}

private func int(_ value: Any?) -> Int {
    (value as? Int) ?? (value as? Double).map { Int($0) } ?? 0
}

// MARK: - Totals

public struct TokenTotals: Equatable, Sendable {
    public var tokens = 0
    public var cost = 0.0
    public var unpricedTokens = 0

    public init() {}

    mutating func add(_ event: TokenEvent) {
        tokens += event.usage.total
        if let price = event.cost {
            cost += price
        } else {
            unpricedTokens += event.usage.total
        }
    }
}

public struct ModelTotals: Equatable, Sendable, Identifiable {
    public let model: String
    public let totals: TokenTotals
    public var id: String { model }
}

public struct TokenSummary: Equatable, Sendable {
    public var today = TokenTotals()
    public var week = TokenTotals()
    public var byTool: [CodingTool: TokenTotals] = [:]
    public var topModels: [ModelTotals] = []
    /// Today's tokens per local clock hour, 0...23.
    public var hourly: [Int] = Array(repeating: 0, count: 24)
    public var tokensPerMinute = 0
    public var lastActivity: Date?

    public init() {}

    public static let liveWindow: TimeInterval = 300

    /// Tokens are flowing right now.
    public func isLive(at now: Date) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) < 120
    }
}

// MARK: - Ledger

/// Keeps a running count of the tokens Claude Code and Codex spend on this Mac,
/// read straight from the transcripts they write. Each update reads only what
/// was appended since the last one, so it can run every few seconds.
public actor TokenLedger {
    private struct FileState: Sendable {
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var modified: Date = .distantPast
        var codex = CodexTranscript()
    }

    private let claudeRoot: URL
    private let codexRoot: URL
    private let calendar: Calendar
    private let lookback: TimeInterval

    private var files: [String: FileState] = [:]
    /// Claude repeats a message while it streams and copies history into
    /// resumed sessions; keyed by message, the largest output wins.
    private var claudeMessages: [String: TokenEvent] = [:]
    private var codexEvents: [TokenEvent] = []

    public init(
        claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects"),
        codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"),
        calendar: Calendar = .current,
        lookback: TimeInterval = 8 * 86_400
    ) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.calendar = calendar
        self.lookback = lookback
    }

    public func update(now: Date = Date()) async -> TokenSummary {
        let cutoff = now.addingTimeInterval(-lookback)
        let pending = changedFiles(root: claudeRoot, tool: .claudeCode, cutoff: cutoff)
            + changedFiles(root: codexRoot, tool: .codex, cutoff: cutoff)

        // Files are independent, so they are read on every core at once.
        let results = await withTaskGroup(of: FileRead.self) { group in
            for job in pending {
                group.addTask { Self.read(job) }
            }
            var collected: [FileRead] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for result in results {
            for (key, event) in result.claude {
                if let existing = claudeMessages[key],
                    existing.usage.outputTokens > event.usage.outputTokens
                {
                    continue
                }
                claudeMessages[key] = event
            }
            codexEvents.append(contentsOf: result.codex)
            files[result.job.path] = result.state
        }

        prune(before: cutoff)
        return summarize(now: now)
    }

    private struct ReadJob: Sendable {
        let path: String
        let tool: CodingTool
        let state: FileState
        let size: UInt64
        let modified: Date
    }

    private struct FileRead: Sendable {
        let job: ReadJob
        let state: FileState
        let claude: [(String, TokenEvent)]
        let codex: [TokenEvent]
    }

    private func changedFiles(root: URL, tool: CodingTool, cutoff: Date) -> [ReadJob] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }

        var jobs: [ReadJob] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            let size = UInt64(values.fileSize ?? 0)

            var state = files[url.path] ?? FileState()
            guard size != state.size || modified != state.modified else { continue }
            // Rewritten from scratch: start over rather than read garbage.
            if size < state.offset { state = FileState() }
            jobs.append(ReadJob(path: url.path, tool: tool, state: state, size: size, modified: modified))
        }
        return jobs
    }

    private static func read(_ job: ReadJob) -> FileRead {
        var state = job.state
        var claude: [(String, TokenEvent)] = []
        var codex: [TokenEvent] = []
        defer {
            state.size = job.size
            state.modified = job.modified
        }

        guard
            let mapped = try? Data(
                contentsOf: URL(fileURLWithPath: job.path), options: [.alwaysMapped]),
            mapped.count > Int(state.offset)
        else {
            return FileRead(job: job, state: stamped(state, job), claude: [], codex: [])
        }

        let consumed: Int = mapped.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var cursor = Int(state.offset)
            let end = raw.count
            while cursor < end {
                // Only whole lines: the last one may still be mid-write.
                guard let newline = memchr(base + cursor, 0x0A, end - cursor) else { break }
                let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                let length = lineEnd - cursor
                if length > 0 {
                    let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + cursor),
                                    count: length, deallocator: .none)
                    switch job.tool {
                    case .claudeCode:
                        if let parsed = ClaudeTranscript.parse(line) { claude.append(parsed) }
                    case .codex:
                        if let event = state.codex.consume(line) { codex.append(event) }
                    }
                }
                cursor = lineEnd + 1
            }
            return cursor
        }
        state.offset = UInt64(consumed)
        return FileRead(job: job, state: stamped(state, job), claude: claude, codex: codex)
    }

    private static func stamped(_ state: FileState, _ job: ReadJob) -> FileState {
        var state = state
        state.size = job.size
        state.modified = job.modified
        return state
    }

    private func prune(before cutoff: Date) {
        claudeMessages = claudeMessages.filter { $0.value.timestamp >= cutoff }
        codexEvents.removeAll { $0.timestamp < cutoff }
    }

    private func summarize(now: Date) -> TokenSummary {
        var summary = TokenSummary()
        let startOfDay = calendar.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-7 * 86_400)
        let liveStart = now.addingTimeInterval(-TokenSummary.liveWindow)
        var models: [String: TokenTotals] = [:]
        var liveTokens = 0

        for event in Array(claudeMessages.values) + codexEvents {
            guard event.timestamp <= now else { continue }
            if event.timestamp >= weekStart { summary.week.add(event) }
            if event.timestamp >= liveStart { liveTokens += event.usage.total }
            if summary.lastActivity.map({ event.timestamp > $0 }) ?? true {
                summary.lastActivity = event.timestamp
            }
            guard event.timestamp >= startOfDay else { continue }

            summary.today.add(event)
            summary.byTool[event.tool, default: TokenTotals()].add(event)
            models[event.model ?? "unknown", default: TokenTotals()].add(event)
            let hour = calendar.component(.hour, from: event.timestamp)
            summary.hourly[hour] += event.usage.total
        }

        summary.tokensPerMinute = liveTokens / Int(TokenSummary.liveWindow / 60)
        summary.topModels = models
            .filter { $0.value.tokens > 0 }
            .map { ModelTotals(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.tokens > $1.totals.tokens }
        return summary
    }
}

import Foundation

/// Which CLI a stored account signs in to.
public enum Provider: String, Codable, Sendable, CaseIterable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One rate-limit window as the provider reports it.
public struct UsageWindow: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case session
        case weekly
        case weeklyModel
    }

    public let id: String
    public let label: String
    public let kind: Kind
    /// 0...1, where 1 means the window is spent.
    public let usedFraction: Double
    public let resetsAt: Date?
    public let lockedReason: String?

    public init(
        id: String, label: String, kind: Kind, usedFraction: Double, resetsAt: Date?,
        lockedReason: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.lockedReason = lockedReason
    }

    public var isExhausted: Bool { lockedReason != nil || usedFraction >= 1 }
}

/// Codex lets an account spend a credit to reset a spent limit early.
public struct ResetCredits: Equatable, Sendable {
    public let available: Int
    /// How many can be spent right now; a reset only applies once a limit is hit.
    public let usableNow: Int

    public init(available: Int, usableNow: Int) {
        self.available = available
        self.usableNow = usableNow
    }

    public var summary: String {
        switch available {
        case 0: "No resets"
        case 1: "1 reset"
        default: "\(available) resets"
        }
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let provider: Provider
    public let windows: [UsageWindow]
    public let plan: String?
    public let email: String?
    public let accountID: String?
    public let fetchedAt: Date
    public let resetCredits: ResetCredits?

    public init(
        provider: Provider, windows: [UsageWindow], plan: String?, email: String?,
        accountID: String?, fetchedAt: Date, resetCredits: ResetCredits? = nil
    ) {
        self.resetCredits = resetCredits
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.email = email
        self.accountID = accountID
        self.fetchedAt = fetchedAt
    }

    /// The window closest to running out — what the menu bar shows.
    public var headline: UsageWindow? {
        windows.max { $0.usedFraction < $1.usedFraction }
    }
}

public enum UsageParseError: Error, Equatable {
    case malformed(String)
}

enum ISO8601 {
    static func date(from string: String) -> Date? {
        if let date = fastDate(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`, parsed by hand. Foundation's
    /// formatter clones an ICU formatter behind a global lock on every call,
    /// which serialised the transcript scan across every core.
    static func fastDate(from string: String) -> Date? {
        var utf8 = string.utf8[...]
        func digits(_ count: Int) -> Int? {
            guard utf8.count >= count else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = utf8.removeFirst()
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        func expect(_ character: UInt8) -> Bool {
            guard utf8.first == character else { return false }
            utf8.removeFirst()
            return true
        }

        guard let year = digits(4), expect(45), let month = digits(2), expect(45), let day = digits(2),
            expect(84), let hour = digits(2), expect(58), let minute = digits(2), expect(58),
            let second = digits(2),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var fraction = 0.0
        if expect(46) {
            var scale = 0.1
            var sawDigit = false
            while let byte = utf8.first, byte >= 48, byte <= 57 {
                fraction += Double(byte - 48) * scale
                scale /= 10
                sawDigit = true
                utf8.removeFirst()
            }
            guard sawDigit else { return nil }
        }

        var offset = 0
        if expect(90) {
            offset = 0
        } else if let sign = utf8.first, sign == 43 || sign == 45 {
            utf8.removeFirst()
            guard let hours = digits(2), expect(58), let minutes = digits(2) else { return nil }
            offset = (hours * 3600 + minutes * 60) * (sign == 45 ? -1 : 1)
        } else {
            return nil
        }
        guard utf8.isEmpty else { return nil }

        // Days since 1970-01-01 in the proleptic Gregorian calendar (Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468

        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}

/// Both providers report usage as a percentage, 0...100.
func fraction(fromPercent percent: Double) -> Double {
    min(max(percent / 100, 0), 1)
}

public enum ClaudeUsageParser {
    /// Only the windows that belong to a coding plan; anything else the API
    /// reports is an unrelated product limit and stays out of the UI.
    private static let known: [(id: String, label: String, kind: UsageWindow.Kind)] = [
        ("five_hour", "5-hour session", .session),
        ("seven_day", "Weekly (all models)", .weekly),
        ("seven_day_opus", "Weekly (Opus)", .weeklyModel),
        ("seven_day_sonnet", "Weekly (Sonnet)", .weeklyModel),
        ("seven_day_cowork", "Weekly (Cowork)", .weeklyModel),
    ]

    public static func snapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.malformed("response was not a JSON object")
        }
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            throw UsageParseError.malformed(message)
        }

        let fromList = (root["limits"] as? [[String: Any]])?.compactMap(window(fromLimit:)) ?? []
        let windows = fromList.isEmpty ? legacyWindows(root) : fromList

        return UsageSnapshot(
            provider: .claude, windows: windows, plan: nil, email: nil, accountID: nil, fetchedAt: fetchedAt)
    }

    /// The `limits` list is what Claude Code's own /usage screen renders, and it
    /// names model-scoped weekly limits (such as Fable) that have no fixed key.
    private static func window(fromLimit limit: [String: Any]) -> UsageWindow? {
        guard let kind = limit["kind"] as? String, let percent = limit["percent"] as? Double else {
            return nil
        }
        let scope = limit["scope"] as? [String: Any]
        let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
        let resetsAt = (limit["resets_at"] as? String).flatMap(ISO8601.date(from:))
        let locked = (limit["severity"] as? String).flatMap { $0 == "exceeded" || $0 == "blocked" ? $0 : nil }

        let label: String
        let windowKind: UsageWindow.Kind
        switch kind {
        case "session":
            (label, windowKind) = ("5-hour session", .session)
        case "weekly_all":
            (label, windowKind) = ("Weekly (all models)", .weekly)
        case "weekly_scoped":
            (label, windowKind) = ("Weekly (\(model ?? "model"))", .weeklyModel)
        default:
            return nil
        }

        return UsageWindow(
            id: model.map { "\(kind):\($0)" } ?? kind, label: label, kind: windowKind,
            usedFraction: fraction(fromPercent: percent), resetsAt: resetsAt, lockedReason: locked)
    }

    private static func legacyWindows(_ root: [String: Any]) -> [UsageWindow] {
        known.compactMap { entry in
            guard let raw = root[entry.id] as? [String: Any],
                let utilization = raw["utilization"] as? Double
            else { return nil }
            return UsageWindow(
                id: entry.id,
                label: entry.label,
                kind: entry.kind,
                usedFraction: fraction(fromPercent: utilization),
                resetsAt: (raw["resets_at"] as? String).flatMap(ISO8601.date(from:)),
                lockedReason: raw["locked_reason"] as? String
            )
        }
    }
}

public enum CodexUsageParser {
    public static func snapshot(from data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.malformed("response was not a JSON object")
        }
        if let detail = root["detail"] as? String {
            throw UsageParseError.malformed(detail)
        }

        let limit = root["rate_limit"] as? [String: Any]
        let windows = [
            window(from: limit?["primary_window"], id: "primary"),
            window(from: limit?["secondary_window"], id: "secondary"),
        ].compactMap { $0 }

        return UsageSnapshot(
            provider: .codex,
            windows: windows,
            plan: root["plan_type"] as? String,
            email: root["email"] as? String,
            accountID: root["account_id"] as? String,
            fetchedAt: fetchedAt,
            resetCredits: resetCredits(from: root["rate_limit_reset_credits"])
        )
    }

    private static func resetCredits(from raw: Any?) -> ResetCredits? {
        guard let raw = raw as? [String: Any], let available = raw["available_count"] as? Int else {
            return nil
        }
        return ResetCredits(
            available: available, usableNow: raw["applicable_available_count"] as? Int ?? 0)
    }

    private static func window(from raw: Any?, id: String) -> UsageWindow? {
        guard let raw = raw as? [String: Any],
            let percent = raw["used_percent"] as? Double
        else { return nil }
        let seconds = raw["limit_window_seconds"] as? Double ?? 0
        let resetsAt = (raw["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }

        return UsageWindow(
            id: id,
            label: Self.label(forWindowOf: seconds),
            kind: seconds >= 86_400 ? .weekly : .session,
            usedFraction: fraction(fromPercent: percent),
            resetsAt: resetsAt,
            lockedReason: (raw["limit_reached"] as? Bool == true) ? "limit_reached" : nil
        )
    }

    static func label(forWindowOf seconds: Double) -> String {
        switch seconds {
        case 0: "Usage"
        case ..<86_400: "\(Int((seconds / 3600).rounded()))-hour session"
        case 604_800: "Weekly"
        default: "\(Int((seconds / 86_400).rounded()))-day"
        }
    }
}

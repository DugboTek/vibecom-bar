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

public struct UsageSnapshot: Equatable, Sendable {
    public let provider: Provider
    public let windows: [UsageWindow]
    public let plan: String?
    public let email: String?
    public let accountID: String?
    public let fetchedAt: Date

    public init(
        provider: Provider, windows: [UsageWindow], plan: String?, email: String?,
        accountID: String?, fetchedAt: Date
    ) {
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
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

/// A utilization number is a fraction on some plans and a percentage on others,
/// so anything above 1 is read as a percentage. Both scales agree below 1%.
func normalizedFraction(_ raw: Double) -> Double {
    let value = raw > 1 ? raw / 100 : raw
    return min(max(value, 0), 1)
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

        let windows: [UsageWindow] = known.compactMap { entry in
            guard let raw = root[entry.id] as? [String: Any],
                let utilization = raw["utilization"] as? Double
            else { return nil }
            return UsageWindow(
                id: entry.id,
                label: entry.label,
                kind: entry.kind,
                usedFraction: normalizedFraction(utilization),
                resetsAt: (raw["resets_at"] as? String).flatMap(ISO8601.date(from:)),
                lockedReason: raw["locked_reason"] as? String
            )
        }

        return UsageSnapshot(
            provider: .claude,
            windows: windows,
            plan: nil,
            email: nil,
            accountID: nil,
            fetchedAt: fetchedAt
        )
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
            fetchedAt: fetchedAt
        )
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
            usedFraction: normalizedFraction(percent / 100),
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

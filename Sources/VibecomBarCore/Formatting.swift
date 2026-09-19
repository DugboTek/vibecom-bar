import Foundation

public enum UsageFormatter {
    /// Rounds toward the honest side: a window that has any usage never shows
    /// 0%, and one with anything left never shows 100%.
    public static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        let scaled = clamped * 100
        let rounded: Int
        switch scaled {
        case 0: rounded = 0
        case ..<1: rounded = 1
        case 100: rounded = 100
        case 99...: rounded = 99
        default: rounded = Int(scaled.rounded())
        }
        return "\(rounded)%"
    }

    public static func countdown(to date: Date, from now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "ready" }

        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24

        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    public static func resetDescription(at date: Date, from now: Date, timeZone: TimeZone = .current)
        -> String
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"

        return "\(countdown(to: date, from: now)) · \(formatter.string(from: date))"
    }

    /// One line per account: when it is usable again if it is spent,
    /// otherwise when its most pressing limit resets.
    public static func resetLine(for status: AccountStatus, now: Date) -> String? {
        let windows = status.snapshot?.windows ?? []

        let spent = windows.filter(\.isExhausted).compactMap(\.resetsAt)
        if let back = spent.max() {
            return "Out of usage · back in \(countdown(to: back, from: now))"
        }

        guard let headline = status.headline, let resetsAt = headline.resetsAt else { return nil }
        return "\(headline.label) resets in \(countdown(to: resetsAt, from: now))"
    }

    /// 512, 940K, 18.2M, 1.2B — short enough for the menu bar.
    public static func tokens(_ count: Int) -> String {
        func oneDecimal(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded))\(suffix)" : String(format: "%.1f%@", rounded, suffix)
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return "\(Int((Double(count) / 1_000).rounded()))K"
        case ..<1_000_000_000: return oneDecimal(Double(count) / 1_000_000, "M")
        default: return oneDecimal(Double(count) / 1_000_000_000, "B")
        }
    }

    /// Every digit, grouped: 1,634,221,907.
    public static func fullTokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    public static func dollars(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: amount)) ?? "$0.00"
    }

    public static func relative(_ date: Date, from now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        default: return "\(seconds / 3600)h ago"
        }
    }
}

public enum MenuBarStyle: String, Codable, Sendable, CaseIterable {
    /// One reading per CLI, for whichever account that CLI would use now.
    case activeAccounts
    /// The single account closest to running out, whichever it is.
    case highestUsage
    /// Today's tokens across every CLI on this Mac.
    case tokensToday
    case iconOnly

    public var displayName: String {
        switch self {
        case .activeAccounts: "Signed-in accounts"
        case .highestUsage: "Closest to its limit"
        case .tokensToday: "Tokens today"
        case .iconOnly: "Icon only"
        }
    }
}

public enum MenuBarTitle {
    static func abbreviation(for provider: Provider) -> String {
        switch provider {
        case .claude: "CC"
        case .codex: "CX"
        }
    }

    public static func text(
        for statuses: [AccountStatus], style: MenuBarStyle, tokens: TokenSummary? = nil
    ) -> String {
        guard style != .iconOnly else { return "" }
        if style == .tokensToday {
            return tokens.map { UsageFormatter.tokens($0.today.tokens) } ?? ""
        }

        let candidates: [AccountStatus]
        switch style {
        case .activeAccounts:
            candidates = Provider.allCases.compactMap { provider in
                statuses.first { $0.isActive && $0.account.provider == provider }
            }
        case .highestUsage:
            candidates = [statuses.max { lhs, rhs in
                (lhs.headline?.usedFraction ?? -1) < (rhs.headline?.usedFraction ?? -1)
            }].compactMap { $0 }
        case .iconOnly, .tokensToday:
            candidates = []
        }

        let segments =
            candidates
            .sorted { ($0.headline?.usedFraction ?? -1) > ($1.headline?.usedFraction ?? -1) }
            .map { segment(for: $0) }

        return segments.joined(separator: " · ")
    }

    private static func segment(for status: AccountStatus) -> String {
        let mark = abbreviation(for: status.account.provider)
        if let error = status.error {
            switch error {
            case .needsLogin, .cannotReadUsage: return "\(mark) sign in"
            case .rateLimited, .unreachable:
                guard let headline = status.headline else { return "\(mark) —" }
                return "\(mark) \(UsageFormatter.percent(headline.usedFraction))"
            }
        }
        guard let headline = status.headline else { return "\(mark) —" }
        return "\(mark) \(UsageFormatter.percent(headline.usedFraction))"
    }
}

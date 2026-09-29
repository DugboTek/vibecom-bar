import Foundation

public struct AutoSwapDecision: Equatable, Sendable {
    public let provider: Provider
    public let from: StoredAccount
    public let to: StoredAccount

    public init(provider: Provider, from: StoredAccount, to: StoredAccount) {
        self.provider = provider
        self.from = from
        self.to = to
    }

    /// Codex deliberately keeps the account a process started with. Updating
    /// auth.json prepares the next process, but cannot retarget a live one.
    public var successMessage: String {
        switch provider {
        case .claude:
            "Switched Claude Code to the account resetting soonest."
        case .codex:
            "Codex account changed. Restart Codex and resume this session to use it."
        }
    }

    public var requiresProcessRestart: Bool { provider == .codex }
}

/// Chooses a replacement once the active account reaches 99%. The account
/// with the nearest upcoming reset goes first,
/// so capacity that is about to refill is used before longer-lived capacity.
public enum AutoSwapPlanner {
    public static func decisions(in statuses: [AccountStatus], now: Date = Date())
        -> [AutoSwapDecision]
    {
        Provider.allCases.compactMap { decision(for: $0, in: statuses, now: now) }
    }

    public static func decision(
        for provider: Provider, in statuses: [AccountStatus], now: Date = Date()
    ) -> AutoSwapDecision? {
        let providerStatuses = statuses.filter { $0.account.provider == provider }
        guard let active = providerStatuses.first(where: \.isActive), isNearLimit(active) else {
            return nil
        }

        let available = providerStatuses.filter { status in
            !status.isActive && isUsableDestination(status) && !isNearLimit(status)
        }
        guard let destination = available.min(by: { preferred($0, over: $1, now: now) }) else {
            return nil
        }

        return AutoSwapDecision(provider: provider, from: active.account, to: destination.account)
    }

    /// Why auto swap is or is not switching this provider right now, in words
    /// the settings page and the activity log can show. Nil when the provider
    /// has no saved accounts.
    public static func explanation(
        for provider: Provider, in statuses: [AccountStatus], now: Date = Date()
    ) -> String? {
        let providerStatuses = statuses.filter { $0.account.provider == provider }
        guard !providerStatuses.isEmpty else { return nil }
        let name = provider.displayName
        guard let active = providerStatuses.first(where: \.isActive) else {
            return "\(name): none of your saved accounts is the one signed in, so there is nothing to switch from."
        }
        guard isNearLimit(active) else {
            let used = active.snapshot.map { snapshot in
                UsageFormatter.percent(snapshot.windows.map(\.usedFraction).max() ?? 0)
            }
            if let used {
                return "\(name): \(active.account.label) is at \(used); switches at 99%."
            }
            let reason = active.error?.message.lowercased() ?? "reading usage"
            return "\(name): \(active.account.label) usage unknown (\(reason))."
        }
        if let decision = decision(for: provider, in: statuses, now: now) {
            return "\(name): \(active.account.label) is spent; switching to \(decision.to.label)."
        }
        let others = providerStatuses.filter { !$0.isActive }.map { status -> String in
            if status.snapshot == nil { return "\(status.account.label) — usage unknown" }
            if !isUsableDestination(status), let error = status.error {
                return "\(status.account.label) — \(error.message.lowercased())"
            }
            return "\(status.account.label) — also spent"
        }
        let detail = others.isEmpty ? "no other account is saved" : others.joined(separator: "; ")
        return "\(name): \(active.account.label) is spent, but no other account is ready (\(detail))."
    }

    /// One account's state for the activity log.
    public static func logLine(for status: AccountStatus) -> String {
        var parts = ["\(status.account.provider.displayName) \(status.account.label)"]
        if status.isActive { parts.append("ACTIVE") }
        if let windows = status.snapshot?.windows, !windows.isEmpty {
            parts.append(windows.map { "\($0.label) \(UsageFormatter.percent($0.usedFraction))" }
                .joined(separator: ", "))
        } else {
            parts.append("no usage")
        }
        if let error = status.error { parts.append("error: \(error.message)") }
        return parts.joined(separator: " | ")
    }

    /// A reading that could not be refreshed this time still counts: the
    /// usage endpoint rate-limits, and treating a 429 as "not ready" left auto
    /// swap with nowhere to go at the moment it was needed. Only a login that
    /// needs signing in again rules an account out; the switch itself renews
    /// and checks the login before using it.
    static func isUsableDestination(_ status: AccountStatus) -> Bool {
        guard status.snapshot != nil else { return false }
        switch status.error {
        case nil, .rateLimited, .unreachable, .awaitingCLIRenewal: return true
        case .needsLogin, .cannotReadUsage: return false
        }
    }

    static func isNearLimit(_ status: AccountStatus) -> Bool {
        status.snapshot?.windows.contains {
            $0.isExhausted || $0.usedFraction >= 0.99
        } ?? false
    }

    private static func preferred(_ lhs: AccountStatus, over rhs: AccountStatus, now: Date) -> Bool {
        let lhsReset = nextReset(for: lhs, after: now)
        let rhsReset = nextReset(for: rhs, after: now)
        switch (lhsReset, rhsReset) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let lhsUsage = lhs.snapshot?.headline?.usedFraction ?? 1
            let rhsUsage = rhs.snapshot?.headline?.usedFraction ?? 1
            if lhsUsage != rhsUsage { return lhsUsage < rhsUsage }
            return lhs.account.sortIndex < rhs.account.sortIndex
        }
    }

    private static func nextReset(for status: AccountStatus, after now: Date) -> Date? {
        status.snapshot?.windows.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}

/// Remembers which spent account auto swap last tried to leave. A failed
/// switch is retried after a cooldown: never retrying stranded the user on a
/// spent account for the rest of its window, and retrying every refresh would
/// repeat a failing keychain write.
public struct AutoSwapAttempts: Sendable {
    public static let retryInterval: TimeInterval = 10 * 60

    private struct Attempt: Sendable {
        let accountID: UUID
        let at: Date
    }

    private var attempts: [Provider: Attempt] = [:]

    public init() {}

    /// A changed or recovered active account opens a fresh decision cycle.
    public mutating func reconcile(with statuses: [AccountStatus]) {
        for provider in Provider.allCases {
            guard let attempt = attempts[provider] else { continue }
            let active = statuses.first { $0.account.provider == provider && $0.isActive }
            if active?.id != attempt.accountID || !(active.map(AutoSwapPlanner.isNearLimit) ?? false) {
                attempts[provider] = nil
            }
        }
    }

    public func shouldAttempt(_ decision: AutoSwapDecision, now: Date) -> Bool {
        guard let attempt = attempts[decision.provider], attempt.accountID == decision.from.id else {
            return true
        }
        return now.timeIntervalSince(attempt.at) >= Self.retryInterval
    }

    public mutating func record(_ decision: AutoSwapDecision, at now: Date) {
        attempts[decision.provider] = Attempt(accountID: decision.from.id, at: now)
    }

    public mutating func removeAll() { attempts.removeAll() }
}

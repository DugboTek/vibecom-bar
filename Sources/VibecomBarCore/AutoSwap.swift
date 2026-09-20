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
        guard let active = providerStatuses.first(where: \.isActive), shouldSwap(active) else {
            return nil
        }

        let available = providerStatuses.filter { status in
            !status.isActive && status.error == nil && status.snapshot != nil && !shouldSwap(status)
        }
        guard let destination = available.min(by: { preferred($0, over: $1, now: now) }) else {
            return nil
        }

        return AutoSwapDecision(provider: provider, from: active.account, to: destination.account)
    }

    private static func shouldSwap(_ status: AccountStatus) -> Bool {
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

import Foundation

public enum AccountError: Error, Equatable, Sendable {
    /// The refresh token is dead — only signing in again fixes this.
    case needsLogin
    /// The token cannot read usage, which is what `claude setup-token` produces.
    case cannotReadUsage
    case rateLimited
    case unreachable

    public var message: String {
        switch self {
        case .needsLogin: "Sign in again"
        case .cannotReadUsage: "This login can't read usage"
        case .rateLimited: "Rate limited — retrying"
        case .unreachable: "Couldn't reach the provider"
        }
    }
}

public struct AccountStatus: Equatable, Sendable, Identifiable {
    public let account: StoredAccount
    public var snapshot: UsageSnapshot?
    public var error: AccountError?
    public var isActive: Bool

    public var id: UUID { account.id }

    public init(
        account: StoredAccount, snapshot: UsageSnapshot? = nil, error: AccountError? = nil,
        isActive: Bool = false
    ) {
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.isActive = isActive
    }

    public var headline: UsageWindow? { snapshot?.headline }
}

/// Keeps every stored account's usage current: renews tokens as they age,
/// hands a renewed token to the CLI when it belongs to the signed-in account,
/// and holds on to the last good reading when a provider is unreachable.
public actor AccountMonitor {
    private let vault: AccountVault
    private let activator: AccountActivator
    private let environment: CLIEnvironment
    private let http: HTTPClient
    private let usage: UsageService
    private let now: @Sendable () -> Date

    private var lastGood: [UUID: UsageSnapshot] = [:]

    public init(
        vault: AccountVault,
        activator: AccountActivator,
        environment: CLIEnvironment,
        http: HTTPClient = LiveHTTPClient(),
        usage: UsageService = UsageService(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.vault = vault
        self.activator = activator
        self.environment = environment
        self.http = http
        self.usage = usage
        self.now = now
    }

    public func refreshAll() async -> [AccountStatus] {
        let accounts = (try? await vault.accounts()) ?? []
        var statuses: [AccountStatus] = []
        for account in accounts {
            statuses.append(await refresh(account))
        }
        return statuses
    }

    public func refresh(_ account: StoredAccount) async -> AccountStatus {
        let isActive = ((try? await activator.activeAccountID(for: account.provider)) ?? nil) == account.id

        do {
            let secret = try await vault.secret(for: account.id)
            let usable = try await renewIfNeeded(secret, for: account, force: false)
            do {
                let snapshot = try await fetch(usable, provider: account.provider)
                lastGood[account.id] = snapshot
                return AccountStatus(
                    account: account, snapshot: snapshot, error: nil, isActive: isActive)
            } catch UsageError.unauthorized {
                // The provider disagreed about the token's life; renew once and retry.
                let renewed = try await renewIfNeeded(usable, for: account, force: true)
                let snapshot = try await fetch(renewed, provider: account.provider)
                lastGood[account.id] = snapshot
                return AccountStatus(
                    account: account, snapshot: snapshot, error: nil, isActive: isActive)
            }
        } catch {
            return AccountStatus(
                account: account, snapshot: lastGood[account.id], error: Self.classify(error),
                isActive: isActive)
        }
    }

    /// Renews an account's token even though it has not expired, for the
    /// "renew now" action and for proving the renewal path works.
    public func renewCredentials(for account: StoredAccount) async throws {
        let secret = try await vault.secret(for: account.id)
        _ = try await renewIfNeeded(secret, for: account, force: true)
    }

    private func fetch(_ secret: AccountSecret, provider: Provider) async throws -> UsageSnapshot {
        switch secret {
        case .claude(let credentials): try await usage.fetchUsage(claude: credentials, now: now())
        case .codex(let credentials): try await usage.fetchUsage(codex: credentials, now: now())
        }
    }

    private func renewIfNeeded(_ secret: AccountSecret, for account: StoredAccount, force: Bool) async throws
        -> AccountSecret
    {
        switch secret {
        case .claude(let credentials):
            guard force || credentials.isExpired(at: now()) else { return secret }
            guard let refreshToken = credentials.refreshToken else { throw AccountError.needsLogin }
            let (data, response) = try await http.send(
                OAuthRefresher.claudeRequest(refreshToken: refreshToken))
            try Self.checkRefreshResponse(response)
            let renewed = try OAuthRefresher.apply(claudeResponse: data, to: credentials, now: now())
            try await store(.claude(renewed), for: account)
            return .claude(renewed)

        case .codex(let credentials):
            guard force || Self.isCodexTokenExpired(credentials, now: now()) else { return secret }
            let (data, response) = try await http.send(
                OAuthRefresher.codexRequest(refreshToken: credentials.refreshToken))
            try Self.checkRefreshResponse(response)
            let renewed = try OAuthRefresher.apply(codexResponse: data, to: credentials, now: now())
            try await store(.codex(renewed), for: account)
            return .codex(renewed)
        }
    }

    /// Saves renewed credentials, and keeps the CLI in step when this account is
    /// the signed-in one — otherwise the CLI would hold a rotated-away token.
    private func store(_ secret: AccountSecret, for account: StoredAccount) async throws {
        let wasActive = ((try? await activator.activeAccountID(for: account.provider)) ?? nil) == account.id
        try await vault.update(secret: secret, for: account.id)
        guard wasActive else { return }
        try? await activator.activate(account)
    }

    private static func checkRefreshResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300: return
        case 400, 401, 403: throw OAuthError.needsReauthentication
        case 429: throw UsageError.rateLimited
        default: throw UsageError.server(response.statusCode)
        }
    }

    /// Codex access tokens are JWTs, so their own `exp` claim is the truth.
    static func isCodexTokenExpired(_ credentials: CodexCredentials, now: Date) -> Bool {
        guard let claims = JWT.claims(of: credentials.accessToken),
            let exp = claims["exp"] as? Double
        else { return true }
        return now.timeIntervalSince1970 >= exp - ClaudeCredentials.expiryGrace
    }

    private static func classify(_ error: Error) -> AccountError {
        switch error {
        case let accountError as AccountError: return accountError
        case OAuthError.needsReauthentication: return .needsLogin
        case UsageError.needsProfileScope: return .cannotReadUsage
        case UsageError.rateLimited: return .rateLimited
        case UsageError.unauthorized: return .needsLogin
        case VaultError.missingSecret: return .needsLogin
        default: return .unreachable
        }
    }
}

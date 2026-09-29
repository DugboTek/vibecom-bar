import Foundation

public enum AccountError: Error, Equatable, Sendable {
    /// The refresh token is dead — only signing in again fixes this.
    case needsLogin
    /// The token cannot read usage, which is what `claude setup-token` produces.
    case cannotReadUsage
    case rateLimited
    case unreachable
    /// The CLI's own token has lapsed while it sat unused. The CLI renews it on
    /// its next request; renewing it here would sign the CLI out.
    case awaitingCLIRenewal

    public var message: String {
        switch self {
        case .needsLogin: "Sign in again"
        case .cannotReadUsage: "This login can't read usage"
        case .rateLimited: "Rate limited — retrying"
        case .unreachable: "Couldn't reach the provider"
        case .awaitingCLIRenewal: "Updates when the CLI is next used"
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

/// Whose login a CLI is using right now.
public enum LiveLoginOwner: Equatable, Sendable {
    case account(UUID)
    /// Signed in as an account that is not saved in vibecom bar.
    case someoneElse
    case signedOut
    /// The live login could not be read or identified this time.
    case unknown
}

public enum SwitchError: Error, Equatable {
    /// The saved login was revoked or rotated away; only a new sign-in fixes it.
    case savedLoginExpired
}

/// Keeps every stored account's usage current and holds on to the last good
/// reading when a provider is unreachable. An active Claude login is never
/// renewed here: Claude refresh tokens rotate, and rotating one before a
/// keychain write succeeds would sign Claude Code out.
public actor AccountMonitor {
    private let vault: AccountVault
    private let activator: AccountActivator
    private let environment: CLIEnvironment
    private let http: HTTPClient
    private let usage: UsageService
    private let now: @Sendable () -> Date

    private var lastGood: [UUID: UsageSnapshot] = [:]
    /// When each account's usage was last read without error. Accounts not in
    /// use are read at most this often, so the fast polling near a limit does
    /// not trip the usage endpoint's rate limit for every saved account.
    private var lastClean: [UUID: Date] = [:]
    public static let inactiveRefreshInterval: TimeInterval = 270
    /// Whose login each CLI held at the last refresh, for the activity log.
    public private(set) var lastLiveOwners: [Provider: LiveLoginOwner] = [:]
    /// Who owns the last live Claude access token seen, so the profile lookup
    /// runs once per token rather than once per refresh.
    private var claudeProfileCache: (accessToken: String, identity: AccountIdentity)?

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
        // Which login each CLI holds is checked once per provider, not once per account.
        var active: [Provider: UUID] = [:]
        for provider in Set(accounts.map(\.provider)) {
            let owner = await syncLiveLogin(for: provider)
            lastLiveOwners[provider] = owner
            switch owner {
            case .account(let id):
                active[provider] = id
            case .someoneElse, .signedOut:
                active[provider] = nil
            case .unknown:
                active[provider] = (try? await activator.activeAccountID(for: provider)) ?? nil
            }
        }

        var statuses: [AccountStatus] = []
        for account in accounts {
            statuses.append(await refresh(account, isActive: active[account.provider] == account.id))
        }
        return statuses
    }

    public func refresh(_ account: StoredAccount) async -> AccountStatus {
        let isActive = ((try? await activator.activeAccountID(for: account.provider)) ?? nil) == account.id
        return await refresh(account, isActive: isActive)
    }

    private func refresh(_ account: StoredAccount, isActive: Bool) async -> AccountStatus {
        if !isActive, let snapshot = lastGood[account.id], let clean = lastClean[account.id],
            now().timeIntervalSince(clean) < Self.inactiveRefreshInterval
        {
            return AccountStatus(account: account, snapshot: snapshot, error: nil, isActive: false)
        }
        let status = await read(account, isActive: isActive)
        if status.error == nil { lastClean[account.id] = now() } else { lastClean[account.id] = nil }
        return status
    }

    private func read(_ account: StoredAccount, isActive: Bool) async -> AccountStatus {
        do {
            let secret = try await vault.secret(for: account.id)
            let usable = try await renewIfNeeded(
                secret, for: account, force: false, isActive: isActive)
            do {
                let snapshot = try await fetch(usable, provider: account.provider)
                lastGood[account.id] = snapshot
                let named = await named(account, using: usable)
                return AccountStatus(
                    account: named, snapshot: snapshot, error: nil, isActive: isActive)
            } catch UsageError.unauthorized {
                // The provider disagreed about the token's life; renew once and retry.
                let renewed = try await renewIfNeeded(
                    usable, for: account, force: true, isActive: isActive)
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

    // MARK: - Live logins

    /// Reads the login a CLI is using right now, works out which saved account
    /// it belongs to, and saves any tokens the CLI has rotated since into that
    /// account. Claude Code and Codex rotate refresh tokens whenever they renew,
    /// so without this a saved copy goes stale as soon as its account is used,
    /// and switching back to it hands the CLI a dead login.
    ///
    /// Ownership comes from the tokens themselves, never from `~/.claude.json`,
    /// which a running Claude process can rewrite with the account it started on.
    @discardableResult
    public func syncLiveLogin(for provider: Provider) async -> LiveLoginOwner {
        guard let accounts = try? await vault.accounts(for: provider), !accounts.isEmpty else {
            return .unknown
        }
        switch provider {
        case .claude: return await syncLiveClaude(accounts)
        case .codex: return await syncLiveCodex(accounts)
        }
    }

    private func syncLiveClaude(_ accounts: [StoredAccount]) async -> LiveLoginOwner {
        // Through Apple's security helper, which Claude's item already trusts,
        // so this cannot put a password prompt on screen.
        let data: Data
        do {
            guard let found = try environment.secrets.readExternal(service: ClaudeKeychain.service) else {
                return .signedOut
            }
            data = found
        } catch {
            return .unknown
        }
        guard let live = try? ClaudeCredentials(keychainJSON: data) else { return .unknown }

        var saved: [UUID: ClaudeCredentials] = [:]
        for account in accounts {
            if case .claude(let credentials) = try? await vault.secret(for: account.id) {
                saved[account.id] = credentials
            }
        }

        var owner = accounts.first { account in
            guard let credentials = saved[account.id] else { return false }
            return credentials.accessToken == live.accessToken
                || (credentials.refreshToken != nil && credentials.refreshToken == live.refreshToken)
        }
        if owner == nil {
            guard let identity = await claudeIdentity(of: live) else { return .unknown }
            owner = accounts.first { Self.isSameAccount($0.identity, identity) }
        }
        guard let owner else { return .someoneElse }

        if saved[owner.id] != live {
            try? await vault.update(secret: .claude(live), for: owner.id)
        }
        return .account(owner.id)
    }

    private func claudeIdentity(of live: ClaudeCredentials) async -> AccountIdentity? {
        if let cached = claudeProfileCache, cached.accessToken == live.accessToken {
            return cached.identity
        }
        guard let identity = try? await usage.fetchProfile(claude: live) else { return nil }
        claudeProfileCache = (live.accessToken, identity)
        return identity
    }

    private func syncLiveCodex(_ accounts: [StoredAccount]) async -> LiveLoginOwner {
        let data: Data
        do {
            guard let found = try environment.files.read(environment.codexAuthFile) else {
                return .signedOut
            }
            data = found
        } catch {
            return .unknown
        }
        guard let live = try? CodexCredentials(authFileJSON: data) else { return .unknown }

        var saved: [UUID: CodexCredentials] = [:]
        for account in accounts {
            if case .codex(let credentials) = try? await vault.secret(for: account.id) {
                saved[account.id] = credentials
            }
        }

        var owner = accounts.first { account in
            guard let credentials = saved[account.id] else { return false }
            return credentials.accessToken == live.accessToken
                || credentials.refreshToken == live.refreshToken
        }
        if owner == nil {
            // Codex's ID token names its account, so no network call is needed.
            guard let identity = live.identity else { return .unknown }
            owner = accounts.first { Self.isSameAccount($0.identity, identity) }
        }
        guard let owner else { return .someoneElse }

        if saved[owner.id] != live {
            try? await vault.update(secret: .codex(live), for: owner.id)
        }
        return .account(owner.id)
    }

    /// Account IDs can be shared by everyone in a workspace, so when both sides
    /// name a person the emails must agree too.
    static func isSameAccount(_ saved: AccountIdentity, _ live: AccountIdentity) -> Bool {
        let savedEmail = saved.email?.lowercased()
        let liveEmail = live.email?.lowercased()
        if let savedEmail, let liveEmail, savedEmail != liveEmail { return false }
        if let savedID = saved.accountUUID, let liveID = live.accountUUID {
            return savedID.lowercased() == liveID.lowercased()
        }
        return savedEmail != nil && savedEmail == liveEmail
    }

    // MARK: - Switching

    /// Switches a CLI to a saved account without ever handing it a dead login.
    ///
    /// First the outgoing account's rotated tokens are saved, so switching back
    /// later works. Then the incoming login is renewed: that proves its refresh
    /// token is still alive before anything the CLI uses is touched.
    public func activate(_ account: StoredAccount) async throws {
        let owner = await syncLiveLogin(for: account.provider)
        if owner != .account(account.id) {
            try await prepareForHandoff(account)
        }
        try await activator.activate(account)
        if account.provider == .claude { claudeProfileCache = nil }
    }

    private func prepareForHandoff(_ account: StoredAccount) async throws {
        let secret = try await vault.secret(for: account.id)
        do {
            // Only vibecom bar holds an inactive account's tokens, so rotating
            // them here cannot sign anything else out.
            _ = try await renewIfNeeded(secret, for: account, force: true, isActive: false)
        } catch OAuthError.needsReauthentication {
            throw SwitchError.savedLoginExpired
        } catch {
            // Offline or rate limited: a token that is still valid can go ahead,
            // and the CLI renews it itself later. An expired one cannot.
            if Self.isExpired(secret, now: now()) { throw error }
        }
    }

    private static func isExpired(_ secret: AccountSecret, now: Date) -> Bool {
        switch secret {
        case .claude(let credentials): credentials.isExpired(at: now)
        case .codex(let credentials): isCodexTokenExpired(credentials, now: now)
        }
    }

    /// Fills in who a Claude account belongs to when it was saved without an
    /// email. Best effort: a failure leaves the account as it was.
    private func named(_ account: StoredAccount, using secret: AccountSecret) async -> StoredAccount {
        guard account.identity.email == nil, case .claude(let credentials) = secret,
            let identity = try? await usage.fetchProfile(claude: credentials),
            identity.email != nil,
            let updated = try? await vault.fillIdentity(account.id, with: identity)
        else { return account }
        return updated
    }

    /// Renews an account's token even though it has not expired, for the
    /// "renew now" action and for proving the renewal path works.
    public func renewCredentials(for account: StoredAccount) async throws {
        let isActive =
            ((try? await activator.activeAccountID(for: account.provider)) ?? nil) == account.id
        let secret = try await vault.secret(for: account.id)
        _ = try await renewIfNeeded(secret, for: account, force: true, isActive: isActive)
    }

    private func fetch(_ secret: AccountSecret, provider: Provider) async throws -> UsageSnapshot {
        switch secret {
        case .claude(let credentials): try await usage.fetchUsage(claude: credentials, now: now())
        case .codex(let credentials): try await usage.fetchUsage(codex: credentials, now: now())
        }
    }

    private func renewIfNeeded(
        _ secret: AccountSecret, for account: StoredAccount, force: Bool, isActive: Bool
    ) async throws -> AccountSecret
    {
        switch secret {
        case .claude(let credentials):
            guard force || credentials.isExpired(at: now()) else { return secret }
            // Never touch the live Claude keychain item from a periodic
            // refresh. Even a read can display a password dialog, and retrying
            // it on a timer creates a prompt storm.
            guard !isActive else { throw AccountError.awaitingCLIRenewal }
            guard let refreshToken = credentials.refreshToken else { throw AccountError.needsLogin }
            let (data, response) = try await http.send(
                OAuthRefresher.claudeRequest(refreshToken: refreshToken))
            try Self.checkRefreshResponse(response)
            let renewed = try OAuthRefresher.apply(claudeResponse: data, to: credentials, now: now())
            try await vault.update(secret: .claude(renewed), for: account.id)
            return .claude(renewed)

        case .codex(let credentials):
            guard force || Self.isCodexTokenExpired(credentials, now: now()) else { return secret }
            let (data, response) = try await http.send(
                OAuthRefresher.codexRequest(refreshToken: credentials.refreshToken))
            try Self.checkRefreshResponse(response)
            let renewed = try OAuthRefresher.apply(codexResponse: data, to: credentials, now: now())
            try await vault.update(secret: .codex(renewed), for: account.id)
            if isActive {
                // Codex stores credentials in a normal file, so this cannot
                // produce a keychain prompt.
                try await activator.activate(account)
            }
            return .codex(renewed)
        }
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

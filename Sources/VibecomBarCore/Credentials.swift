import Foundation

public enum CredentialError: Error, Equatable {
    case malformed(String)
    case missingRefreshToken
}

/// Who an account belongs to, shown in the menu so accounts are told apart by
/// person rather than by which one happens to be signed in.
public struct AccountIdentity: Codable, Equatable, Sendable {
    public var email: String?
    public var accountUUID: String?
    public var organizationUUID: String?
    public var organizationName: String?
    public var plan: String?

    public init(
        email: String? = nil, accountUUID: String? = nil, organizationUUID: String? = nil,
        organizationName: String? = nil, plan: String? = nil
    ) {
        self.email = email
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.plan = plan
    }
}

// MARK: - Claude

public struct ClaudeCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var refreshTokenExpiresAt: Date?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    /// The tolerance that keeps a call from going out with a token that expires
    /// while it is in flight.
    static let expiryGrace: TimeInterval = 300

    public init(
        accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil, scopes: [String] = [],
        subscriptionType: String? = nil, rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public init(keychainJSON: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: keychainJSON) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty
        else {
            throw CredentialError.malformed("no claudeAiOauth block in the keychain item")
        }

        self.init(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: Self.date(fromMilliseconds: oauth["expiresAt"]),
            refreshTokenExpiresAt: Self.date(fromMilliseconds: oauth["refreshTokenExpiresAt"]),
            scopes: oauth["scopes"] as? [String] ?? [],
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    /// `claude setup-token` mints tokens without this scope, and the usage
    /// endpoint turns them away.
    public var canReadUsage: Bool { scopes.contains("user:profile") }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt.addingTimeInterval(-Self.expiryGrace)
    }

    public var oauthBlock: [String: Any] {
        var block: [String: Any] = ["accessToken": accessToken, "scopes": scopes]
        block["refreshToken"] = refreshToken
        block["expiresAt"] = expiresAt.map { ($0.timeIntervalSince1970 * 1000).rounded() }
        block["refreshTokenExpiresAt"] = refreshTokenExpiresAt.map {
            ($0.timeIntervalSince1970 * 1000).rounded()
        }
        block["subscriptionType"] = subscriptionType
        block["rateLimitTier"] = rateLimitTier
        return block
    }

    /// Replaces the signed-in account while leaving every other key — above all
    /// the MCP server logins that live in the same item — untouched.
    public static func merge(_ credentials: ClaudeCredentials, intoKeychainJSON existing: Data?) throws
        -> Data
    {
        var root: [String: Any] = [:]
        if let existing, let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = decoded
        }
        root["claudeAiOauth"] = credentials.oauthBlock
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let milliseconds = value as? Double, milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// The `~/.claude.json` file, which records which account the CLI shows as
/// signed in. Switching without updating it leaves the CLI naming the account
/// it used to hold.
public enum ClaudeProfileFile {
    public static func identity(fromJSON data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["oauthAccount"] as? [String: Any]
        else { return nil }

        return AccountIdentity(
            email: account["emailAddress"] as? String,
            accountUUID: account["accountUuid"] as? String,
            organizationUUID: account["organizationUuid"] as? String,
            organizationName: account["organizationName"] as? String,
            plan: account["organizationType"] as? String
        )
    }

    public static func apply(_ identity: AccountIdentity, toJSON data: Data?) throws -> Data {
        var root: [String: Any] = [:]
        if let data, let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = decoded
        }
        var account = root["oauthAccount"] as? [String: Any] ?? [:]
        account["emailAddress"] = identity.email
        account["accountUuid"] = identity.accountUUID
        account["organizationUuid"] = identity.organizationUUID
        account["organizationName"] = identity.organizationName
        account["organizationType"] = identity.plan
        // The CLI refetches the profile when this is stale, which is what we want.
        account["profileFetchedAt"] = 0
        root["oauthAccount"] = account

        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

// MARK: - Codex

public struct CodexCredentials: Codable, Equatable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    public var accountID: String?
    public var apiKey: String?
    public var lastRefresh: String?

    public init(
        idToken: String, accessToken: String, refreshToken: String, accountID: String? = nil,
        apiKey: String? = nil, lastRefresh: String? = nil
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.apiKey = apiKey
        self.lastRefresh = lastRefresh
    }

    public init(authFileJSON: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: authFileJSON) as? [String: Any],
            let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else {
            throw CredentialError.malformed("no tokens block in auth.json")
        }
        guard let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CredentialError.missingRefreshToken
        }

        self.init(
            idToken: tokens["id_token"] as? String ?? "",
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: tokens["account_id"] as? String,
            apiKey: root["OPENAI_API_KEY"] as? String,
            lastRefresh: root["last_refresh"] as? String
        )
    }

    public var identity: AccountIdentity? {
        guard let claims = JWT.claims(of: idToken) else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        return AccountIdentity(
            email: claims["email"] as? String,
            accountUUID: auth?["chatgpt_account_id"] as? String ?? accountID,
            organizationName: claims["name"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String
        )
    }

    public func authFileJSON() throws -> Data {
        var tokens: [String: Any] = [
            "id_token": idToken,
            "access_token": accessToken,
            "refresh_token": refreshToken,
        ]
        tokens["account_id"] = accountID

        var root: [String: Any] = ["auth_mode": "chatgpt", "tokens": tokens]
        root["OPENAI_API_KEY"] = apiKey
        root["last_refresh"] = lastRefresh

        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

enum JWT {
    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

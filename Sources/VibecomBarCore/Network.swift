import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct LiveHTTPClient: HTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": UsageService.userAgent]
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("response was not HTTP")
        }
        return (data, http)
    }
}

public enum UsageError: Error, Equatable {
    case unauthorized
    case rateLimited
    case needsProfileScope
    case server(Int)
    case transport(String)
    case parse(String)
}

public enum OAuthError: Error, Equatable {
    /// The refresh token is gone or revoked; only a fresh login fixes it.
    case needsReauthentication
    case malformed(String)
}

// MARK: - Refreshing

public enum OAuthRefresher {
    /// The public client id Claude Code itself uses for its OAuth flow.
    public static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public static func claudeRequest(refreshToken: String) -> URLRequest {
        jsonRequest(
            url: URL(string: "https://console.anthropic.com/v1/oauth/token")!,
            body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": claudeClientID,
            ])
    }

    public static func codexRequest(refreshToken: String) -> URLRequest {
        jsonRequest(
            url: URL(string: "https://auth.openai.com/oauth/token")!,
            body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": codexClientID,
                "scope": "openid profile email",
            ])
    }

    public static func apply(claudeResponse data: Data, to credentials: ClaudeCredentials, now: Date)
        throws -> ClaudeCredentials
    {
        let body = try payload(data)
        var updated = credentials
        updated.accessToken = try requireToken(body["access_token"])
        updated.refreshToken = body["refresh_token"] as? String ?? credentials.refreshToken
        if let expiresIn = body["expires_in"] as? Double {
            updated.expiresAt = now.addingTimeInterval(expiresIn)
        }
        if let scope = body["scope"] as? String {
            updated.scopes = scope.split(separator: " ").map(String.init)
        }
        return updated
    }

    public static func apply(codexResponse data: Data, to credentials: CodexCredentials, now: Date)
        throws -> CodexCredentials
    {
        let body = try payload(data)
        var updated = credentials
        updated.accessToken = try requireToken(body["access_token"])
        updated.idToken = body["id_token"] as? String ?? credentials.idToken
        updated.refreshToken = body["refresh_token"] as? String ?? credentials.refreshToken
        updated.lastRefresh = codexTimestamp.string(from: now)
        return updated
    }

    private static let codexTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func payload(_ data: Data) throws -> [String: Any] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.malformed("refresh response was not a JSON object")
        }
        if let error = body["error"] {
            let code = (error as? String) ?? (error as? [String: Any])?["type"] as? String ?? ""
            if code.contains("invalid_grant") || code.contains("invalid_request")
                || code.contains("token_expired")
            {
                throw OAuthError.needsReauthentication
            }
            let description = body["error_description"] as? String ?? code
            throw OAuthError.malformed(description)
        }
        return body
    }

    private static func requireToken(_ value: Any?) throws -> String {
        guard let token = value as? String, !token.isEmpty else {
            throw OAuthError.malformed("refresh response carried no access token")
        }
        return token
    }

    private static func jsonRequest(url: URL, body: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UsageService.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

// MARK: - Reading usage

public struct UsageService: Sendable {
    public static let userAgent = "vibecom-bar/1.0 (+https://vibecom.build)"

    private let http: HTTPClient

    public init(http: HTTPClient = LiveHTTPClient()) {
        self.http = http
    }

    public func fetchUsage(claude credentials: ClaudeCredentials, now: Date) async throws -> UsageSnapshot {
        guard credentials.canReadUsage else { throw UsageError.needsProfileScope }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(UsageService.userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await perform(request)
        do {
            var snapshot = try ClaudeUsageParser.snapshot(from: data, fetchedAt: now)
            snapshot = UsageSnapshot(
                provider: .claude, windows: snapshot.windows,
                plan: credentials.subscriptionType, email: nil, accountID: nil, fetchedAt: now)
            return snapshot
        } catch let error as UsageParseError {
            throw UsageError.parse(String(describing: error))
        }
    }

    public func fetchUsage(codex credentials: CodexCredentials, now: Date) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID ?? "", forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue(UsageService.userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await perform(request)
        do {
            return try CodexUsageParser.snapshot(from: data, fetchedAt: now)
        } catch let error as UsageParseError {
            throw UsageError.parse(String(describing: error))
        }
    }

    /// Who a Claude login belongs to, for logins captured without a name.
    public func fetchProfile(claude credentials: ClaudeCredentials) async throws -> AccountIdentity {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(UsageService.userAgent, forHTTPHeaderField: "User-Agent")
        return try ClaudeProfileParser.identity(from: try await perform(request))
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.server(response.statusCode)
        }
    }
}

public enum ClaudeProfileParser {
    public static func identity(from data: Data) throws -> AccountIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["account"] as? [String: Any]
        else { throw UsageError.parse("profile response had no account") }
        let organization = root["organization"] as? [String: Any]
        return AccountIdentity(
            email: account["email"] as? String,
            accountUUID: account["uuid"] as? String,
            organizationUUID: organization?["uuid"] as? String,
            organizationName: organization?["name"] as? String,
            plan: organization?["organization_type"] as? String)
    }
}

// MARK: - Vibecom standing

/// The non-secret portion of the Vibecom CLI login file.
public struct VibecomProfile: Decodable, Equatable, Sendable {
    public let username: String
    public let origin: String

    public init(username: String, origin: String) {
        self.username = username
        self.origin = origin
    }

    public static func parse(_ data: Data) -> VibecomProfile? {
        try? JSONDecoder().decode(VibecomProfile.self, from: data)
    }
}

public struct VibecomStanding: Decodable, Equatable, Sendable {
    public struct Rank: Decodable, Equatable, Sendable {
        public let level: Int
        public let name: String
        public let label: String
        public let progress: Double
        public let nextName: String?
        public let tokensToNext: Int

        public init(
            level: Int, name: String, label: String, progress: Double, nextName: String?,
            tokensToNext: Int
        ) {
            self.level = level
            self.name = name
            self.label = label
            self.progress = progress
            self.nextName = nextName
            self.tokensToNext = tokensToNext
        }
    }

    public struct Period: Decodable, Equatable, Sendable {
        public let position: Int?
        public let tokens: Int

        public init(position: Int?, tokens: Int) {
            self.position = position
            self.tokens = tokens
        }
    }

    public let username: String
    public let displayName: String?
    public let rank: Rank
    public let weekly: Period
    public let allTime: Period
    public let streakDays: Int

    public init(
        username: String, displayName: String?, rank: Rank, weekly: Period, allTime: Period,
        streakDays: Int
    ) {
        self.username = username
        self.displayName = displayName
        self.rank = rank
        self.weekly = weekly
        self.allTime = allTime
        self.streakDays = streakDays
    }
}

public enum VibecomStandingError: Error, Equatable {
    case unsafeOrigin
    case unavailable(Int)
    case malformed
}

public struct VibecomStandingService: Sendable {
    private struct Response: Decodable { let builder: VibecomStanding }
    private let http: HTTPClient

    public init(http: HTTPClient = LiveHTTPClient()) {
        self.http = http
    }

    public func fetch(_ profile: VibecomProfile) async throws -> VibecomStanding {
        guard let url = summaryURL(for: profile) else { throw VibecomStandingError.unsafeOrigin }
        var request = URLRequest(url: url)
        request.setValue(UsageService.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            throw VibecomStandingError.unavailable(response.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(Response.self, from: data) else {
            throw VibecomStandingError.malformed
        }
        return payload.builder
    }

    private func summaryURL(for profile: VibecomProfile) -> URL? {
        guard var components = URLComponents(string: profile.origin),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1"))
        else { return nil }

        components.path = "/api/app/summary"
        components.queryItems = [URLQueryItem(name: "username", value: profile.username)]
        return components.url
    }
}

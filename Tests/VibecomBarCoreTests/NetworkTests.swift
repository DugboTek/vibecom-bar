import Foundation
import Testing

@testable import VibecomBarCore

/// Records what the core would put on the wire, so every request shape is
/// checked without touching a provider.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [URLRequest] = []
    private var responses: [(Data, Int)]

    init(responses: [(Data, Int)]) { self.responses = responses }

    init(json: String, status: Int = 200) { responses = [(Data(json.utf8), status)] }

    var sent: [URLRequest] { lock.withLock { _sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: (Data, Int)? = lock.withLock {
            _sent.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let (data, status) = next else { throw UsageError.transport("stub ran out of responses") }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Suite("Token refresh")
struct TokenRefreshTests {
    @Test("asks Anthropic for a new token with the Claude Code client id")
    func buildsClaudeRequest() throws {
        let request = OAuthRefresher.claudeRequest(refreshToken: "rt-1")

        #expect(request.url?.absoluteString == "https://console.anthropic.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: String])
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "rt-1")
        #expect(body["client_id"] == OAuthRefresher.claudeClientID)
    }

    @Test("keeps the plan details the refresh response does not return")
    func appliesClaudeResponse() throws {
        let existing = ClaudeCredentials(
            accessToken: "old", refreshToken: "rt-1", expiresAt: .distantPast,
            scopes: ["user:profile"], subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        let response = Data(
            """
            {"access_token":"new-at","refresh_token":"new-rt","expires_in":28800,
             "scope":"user:inference user:profile"}
            """.utf8)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let updated = try OAuthRefresher.apply(claudeResponse: response, to: existing, now: now)

        #expect(updated.accessToken == "new-at")
        #expect(updated.refreshToken == "new-rt")
        #expect(updated.expiresAt == now.addingTimeInterval(28800))
        #expect(updated.subscriptionType == "max")
        #expect(updated.scopes == ["user:inference", "user:profile"])
    }

    @Test("keeps using the old refresh token when the response omits a new one")
    func keepsRefreshTokenWhenRotationIsAbsent() throws {
        let existing = ClaudeCredentials(accessToken: "old", refreshToken: "rt-keep")
        let response = Data(#"{"access_token":"new-at","expires_in":60}"#.utf8)

        let updated = try OAuthRefresher.apply(
            claudeResponse: response, to: existing, now: Date(timeIntervalSince1970: 0))

        #expect(updated.refreshToken == "rt-keep")
    }

    @Test("reports a refresh token the provider has revoked")
    func detectsRevokedRefreshToken() {
        let existing = ClaudeCredentials(accessToken: "old", refreshToken: "rt-dead")
        let response = Data(#"{"error":"invalid_grant","error_description":"refresh token revoked"}"#.utf8)

        #expect(throws: OAuthError.needsReauthentication) {
            try OAuthRefresher.apply(claudeResponse: response, to: existing, now: Date())
        }
    }

    @Test("asks OpenAI for a new token with the Codex client id")
    func buildsCodexRequest() throws {
        let request = OAuthRefresher.codexRequest(refreshToken: "rt-2")

        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: String])
        #expect(body["client_id"] == OAuthRefresher.codexClientID)
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["scope"] == "openid profile email")
    }

    @Test("records when Codex credentials were last refreshed, as the CLI does")
    func appliesCodexResponse() throws {
        let existing = CodexCredentials(
            idToken: "old-id", accessToken: "old-at", refreshToken: "rt-2", accountID: "acct-1")
        let response = Data(
            #"{"id_token":"new-id","access_token":"new-at","refresh_token":"new-rt"}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_789_828_386)

        let updated = try OAuthRefresher.apply(codexResponse: response, to: existing, now: now)

        #expect(updated.accessToken == "new-at")
        #expect(updated.idToken == "new-id")
        #expect(updated.refreshToken == "new-rt")
        #expect(updated.accountID == "acct-1")
        #expect(updated.lastRefresh == "2026-09-19T14:33:06.000Z")
    }
}

@Suite("Usage requests")
struct UsageRequestTests {
    @Test("sends the OAuth beta header Anthropic's usage endpoint requires")
    func claudeRequestHeaders() async throws {
        let http = StubHTTPClient(json: #"{"five_hour":{"utilization":0.1,"resets_at":null}}"#)
        let service = UsageService(http: http)

        _ = try await service.fetchUsage(
            claude: ClaudeCredentials(accessToken: "at-1", scopes: ["user:profile"]), now: .distantPast)

        let request = try #require(http.sent.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-1")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test("names the ChatGPT account so the right subscription is reported")
    func codexRequestHeaders() async throws {
        let http = StubHTTPClient(json: #"{"plan_type":"pro","rate_limit":{}}"#)
        let service = UsageService(http: http)

        _ = try await service.fetchUsage(
            codex: CodexCredentials(
                idToken: "", accessToken: "at-2", refreshToken: "rt", accountID: "acct-9"),
            now: .distantPast)

        let request = try #require(http.sent.first)
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-9")
    }

    @Test("turns an expired token into a signal to refresh rather than a crash")
    func unauthorizedBecomesTypedError() async {
        let http = StubHTTPClient(json: #"{"error":"unauthorized"}"#, status: 401)
        let service = UsageService(http: http)

        await #expect(throws: UsageError.unauthorized) {
            try await service.fetchUsage(
                claude: ClaudeCredentials(accessToken: "at", scopes: ["user:profile"]), now: .distantPast)
        }
    }

    @Test("reports rate limiting separately so a stale reading is kept on screen")
    func rateLimitBecomesTypedError() async {
        let http = StubHTTPClient(json: #"{"error":{"type":"rate_limit_error"}}"#, status: 429)
        let service = UsageService(http: http)

        await #expect(throws: UsageError.rateLimited) {
            try await service.fetchUsage(
                claude: ClaudeCredentials(accessToken: "at", scopes: ["user:profile"]), now: .distantPast)
        }
    }

    @Test("refuses to spend a call on a token that cannot read usage")
    func refusesTokenWithoutProfileScope() async {
        let http = StubHTTPClient(json: "{}")
        let service = UsageService(http: http)

        await #expect(throws: UsageError.needsProfileScope) {
            try await service.fetchUsage(
                claude: ClaudeCredentials(accessToken: "at", scopes: ["user:inference"]), now: .distantPast)
        }
        #expect(await http.sent.isEmpty)
    }
}

@Suite("Vibecom standing")
struct VibecomStandingTests {
    @Test("reads only the public identity from the CLI credential file")
    func parsesProfileWithoutKeepingToken() throws {
        let profile = VibecomProfile.parse(
            Data(#"{"username":"sola","origin":"https://www.vibecom.build","token":"secret"}"#.utf8))

        #expect(profile == VibecomProfile(username: "sola", origin: "https://www.vibecom.build"))
    }

    @Test("fetches the signed-in builder's public standing without authorization")
    func fetchesStanding() async throws {
        let http = StubHTTPClient(json: Self.response)
        let standing = try await VibecomStandingService(http: http).fetch(
            VibecomProfile(username: "sola+work", origin: "https://www.vibecom.build"))

        #expect(standing.rank.label == "Staff Engineer")
        #expect(standing.weekly.position == 12)
        #expect(standing.allTime.position == 4)
        let request = try #require(http.sent.first)
        #expect(
            request.url?.absoluteString
                == "https://www.vibecom.build/api/app/summary?username=sola+work")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("refuses to send a username to an unsafe origin")
    func rejectsUnsafeOrigin() async {
        let http = StubHTTPClient(json: Self.response)

        await #expect(throws: VibecomStandingError.unsafeOrigin) {
            try await VibecomStandingService(http: http).fetch(
                VibecomProfile(username: "sola", origin: "http://example.com"))
        }
        #expect(http.sent.isEmpty)
    }

    private static let response = #"""
        {"builder":{"username":"sola","displayName":"Sola","rank":{"level":8,"name":"Staff Vibe Engineer","label":"Staff Engineer","progress":0.42,"nextName":"Context Maxxer I","tokensToNext":1234},"weekly":{"position":12,"tokens":4500000},"allTime":{"position":4,"tokens":21000000},"streakDays":9}}
        """#
}

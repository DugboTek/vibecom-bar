import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Claude credential payloads")
struct ClaudeCredentialTests {
    /// Shaped like the real "Claude Code-credentials" keychain item.
    static func keychainJSON(accessToken: String = "at-live", expiresAt: Int = 1_789_859_829_024) -> Data {
        let json = """
            {"mcpOAuth":{"linear|638130d5":{"serverName":"linear","accessToken":"mcp-token"}},
             "claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"rt-live",
              "expiresAt":\(expiresAt),"refreshTokenExpiresAt":1792376253024,
              "scopes":["user:inference","user:profile"],
              "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
            """
        return Data(json.utf8)
    }

    @Test("reads the Claude Code OAuth block out of the keychain item")
    func readsCredentials() throws {
        let credentials = try ClaudeCredentials(keychainJSON: Self.keychainJSON())

        #expect(credentials.accessToken == "at-live")
        #expect(credentials.refreshToken == "rt-live")
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.rateLimitTier == "default_claude_max_20x")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_789_859_829.024))
    }

    @Test("rejects a token that cannot read usage because it lacks the profile scope")
    func rejectsSetupToken() throws {
        let json = Data(
            """
            {"claudeAiOauth":{"accessToken":"at","refreshToken":null,"expiresAt":1,"scopes":["user:inference"]}}
            """.utf8)

        let credentials = try ClaudeCredentials(keychainJSON: json)

        #expect(!credentials.canReadUsage)
    }

    @Test("installing an account keeps the MCP server logins in the same keychain item")
    func preservesMCPLogins() throws {
        let incoming = try ClaudeCredentials(keychainJSON: Self.keychainJSON(accessToken: "at-other"))

        let merged = try ClaudeCredentials.merge(incoming, intoKeychainJSON: Self.keychainJSON())

        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let mcp = try #require(root["mcpOAuth"] as? [String: Any])
        #expect(mcp["linear|638130d5"] != nil)
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "at-other")
    }

    @Test("installing an account works when no keychain item exists yet")
    func createsItemWhenAbsent() throws {
        let incoming = try ClaudeCredentials(keychainJSON: Self.keychainJSON())

        let merged = try ClaudeCredentials.merge(incoming, intoKeychainJSON: nil)

        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect((root["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String == "at-live")
    }

    @Test("writes the expiry back in the milliseconds the CLI expects")
    func writesMillisecondExpiry() throws {
        let incoming = try ClaudeCredentials(keychainJSON: Self.keychainJSON())

        let merged = try ClaudeCredentials.merge(incoming, intoKeychainJSON: nil)

        let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        let oauth = try #require(root?["claudeAiOauth"] as? [String: Any])
        #expect(oauth["expiresAt"] as? Double == 1_789_859_829_024)
    }

    @Test("counts a token as expired a few minutes early to avoid a failed call")
    func expiresEarly() throws {
        let credentials = try ClaudeCredentials(keychainJSON: Self.keychainJSON())
        let expiry = Date(timeIntervalSince1970: 1_789_859_829.024)

        #expect(!credentials.isExpired(at: expiry.addingTimeInterval(-600)))
        #expect(credentials.isExpired(at: expiry.addingTimeInterval(-60)))
        #expect(credentials.isExpired(at: expiry.addingTimeInterval(60)))
    }
}

@Suite("Claude profile file")
struct ClaudeProfileTests {
    @Test("switching accounts rewrites only the signed-in account in .claude.json")
    func preservesUnrelatedSettings() throws {
        let existing = Data(
            """
            {"numStartups":42,"oauthAccount":{"emailAddress":"old@example.com","accountUuid":"old-uuid"},
             "projects":{"/tmp/x":{"allowedTools":[]}}}
            """.utf8)
        let identity = AccountIdentity(
            email: "new@example.com", accountUUID: "new-uuid", organizationUUID: "org-uuid",
            organizationName: "New Org", plan: "max")

        let updated = try ClaudeProfileFile.apply(identity, toJSON: existing)

        let root = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        #expect(root["numStartups"] as? Int == 42)
        #expect(root["projects"] != nil)
        let account = try #require(root["oauthAccount"] as? [String: Any])
        #expect(account["emailAddress"] as? String == "new@example.com")
        #expect(account["accountUuid"] as? String == "new-uuid")
        #expect(account["organizationName"] as? String == "New Org")
    }

    @Test("reads the signed-in identity so a captured account has a name")
    func readsIdentity() throws {
        let existing = Data(
            """
            {"oauthAccount":{"emailAddress":"builder@example.com","accountUuid":"uuid-1",
             "organizationUuid":"org-1","organizationName":"Builder's Org","organizationType":"claude_max"}}
            """.utf8)

        let identity = try #require(ClaudeProfileFile.identity(fromJSON: existing))

        #expect(identity.email == "builder@example.com")
        #expect(identity.accountUUID == "uuid-1")
        #expect(identity.plan == "claude_max")
    }
}

@Suite("Codex credential file")
struct CodexCredentialTests {
    static func authJSON(refreshToken: String = "rt-codex") -> Data {
        Data(
            """
            {"auth_mode":"chatgpt","OPENAI_API_KEY":null,
             "tokens":{"id_token":"\(CodexCredentialTests.idToken)","access_token":"at-codex",
              "refresh_token":"\(refreshToken)","account_id":"09a98933-21df-4f88-bafd-319729cd80c0"},
             "last_refresh":"2026-09-19T14:33:06.200861Z"}
            """.utf8)
    }

    /// An unsigned JWT carrying the claims Codex puts in a real id_token.
    static let idToken: String = {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let claims: [String: Any] = [
            "email": "builder@example.com",
            "name": "A Builder",
            "exp": 1_789_831_985,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "09a98933-21df-4f88-bafd-319729cd80c0",
                "chatgpt_plan_type": "pro",
            ],
        ]
        return "\(segment(["alg": "none"])).\(segment(claims)).sig"
    }()

    @Test("reads the tokens Codex stores in auth.json")
    func readsTokens() throws {
        let credentials = try CodexCredentials(authFileJSON: Self.authJSON())

        #expect(credentials.accessToken == "at-codex")
        #expect(credentials.refreshToken == "rt-codex")
        #expect(credentials.accountID == "09a98933-21df-4f88-bafd-319729cd80c0")
    }

    @Test("takes the account identity from the claims inside the id token")
    func readsIdentityFromIDToken() throws {
        let credentials = try CodexCredentials(authFileJSON: Self.authJSON())

        let identity = try #require(credentials.identity)
        #expect(identity.email == "builder@example.com")
        #expect(identity.plan == "pro")
        #expect(identity.accountUUID == "09a98933-21df-4f88-bafd-319729cd80c0")
    }

    @Test("writes an auth.json the Codex CLI can read back")
    func roundTrips() throws {
        let credentials = try CodexCredentials(authFileJSON: Self.authJSON())

        let written = try credentials.authFileJSON()
        let reread = try CodexCredentials(authFileJSON: written)

        #expect(reread == credentials)
        let root = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(root["auth_mode"] as? String == "chatgpt")
        #expect(root["last_refresh"] as? String == "2026-09-19T14:33:06.200861Z")
    }

    @Test("refuses a file that carries no refresh token to switch back to")
    func requiresRefreshToken() {
        let json = Data("""
            {"auth_mode":"chatgpt","tokens":{"access_token":"at"}}
            """.utf8)

        #expect(throws: CredentialError.self) { try CodexCredentials(authFileJSON: json) }
    }
}

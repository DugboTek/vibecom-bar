import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Monitoring accounts")
struct AccountMonitorTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)
    static let usageJSON = #"{"five_hour":{"utilization":0.25,"resets_at":null},"seven_day":{"utilization":0.8,"resets_at":null}}"#
    static let refreshJSON = #"{"access_token":"at-fresh","refresh_token":"rt-fresh","expires_in":28800}"#

    private func fixture(
        responses: [(Data, Int)], liveKeychain: Data? = nil
    ) -> (AccountMonitor, AccountVault, MemorySecretStore, MemoryFileStore, StubHTTPClient) {
        let secrets = MemorySecretStore(liveKeychain.map { [ClaudeKeychain.service: $0] } ?? [:])
        let files = MemoryFileStore()
        let vault = AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
        let environment = CLIEnvironment(
            secrets: secrets, files: files,
            claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
            codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json"))
        let http = StubHTTPClient(responses: responses)
        let monitor = AccountMonitor(
            vault: vault,
            activator: AccountActivator(vault: vault, environment: environment),
            environment: environment,
            http: http,
            usage: UsageService(http: http),
            now: { Self.now })
        return (monitor, vault, secrets, files, http)
    }

    private func expiredClaude() -> ClaudeCredentials {
        ClaudeCredentials(
            accessToken: "at-stale", refreshToken: "rt-stale",
            expiresAt: Self.now.addingTimeInterval(-60), scopes: ["user:profile"],
            subscriptionType: "max")
    }

    @Test("reads usage for an account whose token is still good")
    func readsUsage() async throws {
        let (monitor, vault, _, _, http) = fixture(responses: [(Data(Self.usageJSON.utf8), 200)])
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at-good", refreshToken: "rt",
                    expiresAt: Self.now.addingTimeInterval(3600), scopes: ["user:profile"])))

        let status = await monitor.refresh(account)

        #expect(status.snapshot?.headline?.usedFraction == 0.8)
        #expect(status.error == nil)
        #expect(http.sent.count == 1)
    }

    @Test("renews an expired token before spending a call on it")
    func refreshesBeforeFetching() async throws {
        let (monitor, vault, _, _, http) = fixture(responses: [
            (Data(Self.refreshJSON.utf8), 200), (Data(Self.usageJSON.utf8), 200),
        ])
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(expiredClaude()))

        let status = await monitor.refresh(account)

        #expect(status.error == nil)
        #expect(http.sent.count == 2)
        #expect(http.sent[0].url?.host == "console.anthropic.com")
        #expect(http.sent[1].value(forHTTPHeaderField: "Authorization") == "Bearer at-fresh")
    }

    @Test("keeps the renewed token so the next launch does not renew again")
    func persistsRotatedCredentials() async throws {
        let (monitor, vault, _, _, _) = fixture(responses: [
            (Data(Self.refreshJSON.utf8), 200), (Data(Self.usageJSON.utf8), 200),
        ])
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(expiredClaude()))

        _ = await monitor.refresh(account)

        guard case .claude(let stored) = try await vault.secret(for: account.id) else {
            Issue.record("expected Claude credentials")
            return
        }
        #expect(stored.accessToken == "at-fresh")
        #expect(stored.refreshToken == "rt-fresh")
    }

    @Test("hands the renewed token to the CLI when that account is the signed-in one")
    func writesRotatedCredentialsToLiveLogin() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-stale")
        let (monitor, vault, secrets, _, _) = fixture(
            responses: [(Data(Self.refreshJSON.utf8), 200), (Data(Self.usageJSON.utf8), 200)],
            liveKeychain: live)
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(expiredClaude()))

        _ = await monitor.refresh(account)

        let written = try #require(secrets.contents(of: ClaudeKeychain.service))
        #expect(try ClaudeCredentials(keychainJSON: written).accessToken == "at-fresh")
    }

    @Test("leaves another account's login alone when renewing a background account")
    func doesNotTouchLiveLoginOfOtherAccount() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-someone-else")
        let (monitor, vault, secrets, _, _) = fixture(
            responses: [(Data(Self.refreshJSON.utf8), 200), (Data(Self.usageJSON.utf8), 200)],
            liveKeychain: live)
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(expiredClaude()))

        _ = await monitor.refresh(account)

        let written = try #require(secrets.contents(of: ClaudeKeychain.service))
        #expect(try ClaudeCredentials(keychainJSON: written).accessToken == "at-someone-else")
    }

    @Test("renews once and retries when the provider rejects a token it thought was valid")
    func retriesAfterUnauthorized() async throws {
        let (monitor, vault, _, _, http) = fixture(responses: [
            (Data(#"{"error":"unauthorized"}"#.utf8), 401),
            (Data(Self.refreshJSON.utf8), 200),
            (Data(Self.usageJSON.utf8), 200),
        ])
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at-good", refreshToken: "rt",
                    expiresAt: Self.now.addingTimeInterval(3600), scopes: ["user:profile"])))

        let status = await monitor.refresh(account)

        #expect(status.error == nil)
        #expect(status.snapshot != nil)
        #expect(http.sent.count == 3)
    }

    @Test("asks for a fresh sign-in when the refresh token itself is dead")
    func reportsNeedsLogin() async throws {
        let (monitor, vault, _, _, _) = fixture(responses: [
            (Data(#"{"error":"invalid_grant"}"#.utf8), 400)
        ])
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(expiredClaude()))

        let status = await monitor.refresh(account)

        #expect(status.error == .needsLogin)
    }

    @Test("keeps the last good reading on screen when a refresh fails")
    func keepsLastGoodSnapshot() async throws {
        let (monitor, vault, _, _, _) = fixture(responses: [
            (Data(Self.usageJSON.utf8), 200),
            (Data("nope".utf8), 500),
        ])
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at-good", refreshToken: "rt",
                    expiresAt: Self.now.addingTimeInterval(3600), scopes: ["user:profile"])))
        _ = await monitor.refresh(account)

        let status = await monitor.refresh(account)

        #expect(status.snapshot?.headline?.usedFraction == 0.8)
        #expect(status.error == .unreachable)
    }

    @Test("marks which account each CLI would use right now")
    func marksActiveAccount() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-good")
        let (monitor, vault, _, _, _) = fixture(
            responses: [(Data(Self.usageJSON.utf8), 200), (Data(Self.usageJSON.utf8), 200)],
            liveKeychain: live)
        let active = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at-good", refreshToken: "rt",
                    expiresAt: Self.now.addingTimeInterval(3600), scopes: ["user:profile"])))
        _ = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "two@example.com"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at-other", refreshToken: "rt",
                    expiresAt: Self.now.addingTimeInterval(3600), scopes: ["user:profile"])))

        let statuses = await monitor.refreshAll()

        #expect(statuses.count == 2)
        #expect(statuses.first { $0.isActive }?.account.id == active.id)
    }
}

@Suite("Renewing on demand")
struct RenewOnDemandTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)

    @Test("renews a token that has not expired yet when asked to")
    func renewsValidToken() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore()
        let vault = AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
        let environment = CLIEnvironment(
            secrets: secrets, files: files,
            claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
            codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json"))
        let http = StubHTTPClient(json: #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":28800}"#)
        let monitor = AccountMonitor(
            vault: vault, activator: AccountActivator(vault: vault, environment: environment),
            environment: environment, http: http, usage: UsageService(http: http), now: { Self.now })
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at-old", refreshToken: "rt-old",
                    expiresAt: Self.now.addingTimeInterval(9999), scopes: ["user:profile"])))

        try await monitor.renewCredentials(for: account)

        guard case .claude(let stored) = try await vault.secret(for: account.id) else {
            Issue.record("expected Claude credentials")
            return
        }
        #expect(stored.accessToken == "at-new")
        #expect(http.sent.count == 1)
    }

    @Test("reports a dead refresh token instead of silently leaving the old one")
    func surfacesDeadRefreshToken() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore()
        let vault = AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
        let environment = CLIEnvironment(
            secrets: secrets, files: files,
            claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
            codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json"))
        let http = StubHTTPClient(json: #"{"error":"invalid_grant"}"#, status: 400)
        let monitor = AccountMonitor(
            vault: vault, activator: AccountActivator(vault: vault, environment: environment),
            environment: environment, http: http, usage: UsageService(http: http), now: { Self.now })
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at", refreshToken: "rt", scopes: ["user:profile"])))

        await #expect(throws: OAuthError.needsReauthentication) {
            try await monitor.renewCredentials(for: account)
        }
    }
}

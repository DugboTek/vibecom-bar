import Foundation
import Testing

@testable import VibecomBarCore

/// Claude Code and Codex rotate their refresh tokens as they renew. These
/// cover the bugs that caused: switching back to a used account signed Claude
/// Code out ("Login expired"), and auto swap never saw the active account fill.
@Suite("Live login sync")
struct LiveLoginSyncTests {
    static let now = Date(timeIntervalSince1970: 1_789_830_000)
    static let usageJSON = #"{"five_hour":{"utilization":99,"resets_at":null},"seven_day":{"utilization":40,"resets_at":null}}"#
    static let refreshJSON = #"{"access_token":"at-fresh","refresh_token":"rt-fresh","expires_in":28800}"#

    static func profileJSON(email: String, uuid: String) -> Data {
        Data(#"{"account":{"email":"\#(email)","uuid":"\#(uuid)"},"organization":{"uuid":"org"}}"#.utf8)
    }

    struct Fixture {
        let monitor: AccountMonitor
        let vault: AccountVault
        let secrets: MemorySecretStore
        let files: MemoryFileStore
        let http: StubHTTPClient
    }

    private func fixture(
        responses: [(Data, Int)] = [], liveClaude: Data? = nil, signedIn: String? = nil,
        codexAuth: Data? = nil
    ) -> Fixture {
        let secrets = MemorySecretStore(liveClaude.map { [ClaudeKeychain.service: $0] } ?? [:])
        var seed: [String: Data] = [:]
        if let signedIn {
            seed["/home/.claude.json"] = Data(#"{"oauthAccount":{"emailAddress":"\#(signedIn)"}}"#.utf8)
        }
        if let codexAuth { seed["/home/.codex/auth.json"] = codexAuth }
        let files = MemoryFileStore(seed)
        let vault = AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
        let environment = CLIEnvironment(
            secrets: secrets, files: files,
            claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
            codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json"))
        let http = StubHTTPClient(responses: responses)
        let monitor = AccountMonitor(
            vault: vault, activator: AccountActivator(vault: vault, environment: environment),
            environment: environment, http: http, usage: UsageService(http: http), now: { Self.now })
        return Fixture(monitor: monitor, vault: vault, secrets: secrets, files: files, http: http)
    }

    private func claude(_ access: String, _ refresh: String, expiresIn: TimeInterval = 3600)
        -> ClaudeCredentials
    {
        ClaudeCredentials(
            accessToken: access, refreshToken: refresh,
            expiresAt: Self.now.addingTimeInterval(expiresIn), scopes: ["user:inference", "user:profile"],
            subscriptionType: "max")
    }

    private func claudeSecret(_ vault: AccountVault, _ id: UUID) async throws -> ClaudeCredentials {
        guard case .claude(let credentials) = try await vault.secret(for: id) else {
            throw VaultError.missingSecret(id)
        }
        return credentials
    }

    // MARK: Claude

    @Test("saves the tokens Claude Code rotated into the account it is using")
    func savesRotatedClaudeTokens() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-rotated")
        let f = fixture(
            responses: [(Self.profileJSON(email: "one@example.com", uuid: "uuid-one"), 200)],
            liveClaude: live)
        let one = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com", accountUUID: "uuid-one"),
            secret: .claude(claude("at-captured", "rt-captured")))

        let owner = await f.monitor.syncLiveLogin(for: .claude)

        #expect(owner == .account(one.id))
        let saved = try await claudeSecret(f.vault, one.id)
        #expect(saved.accessToken == "at-rotated")
        #expect(saved.refreshToken == "rt-live")
        #expect(f.secrets.reads(of: ClaudeKeychain.service) == 0)
        #expect(f.secrets.externalReads(of: ClaudeKeychain.service) == 1)
    }

    @Test("recognises a login it already saved without asking the network")
    func matchesByTokenOffline() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-live")
        let f = fixture(liveClaude: live)
        let one = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(claude("at-older", "rt-live")))

        #expect(await f.monitor.syncLiveLogin(for: .claude) == .account(one.id))
        #expect(f.http.sent.isEmpty)
    }

    @Test("asks the provider who owns a new token only once")
    func cachesProfileLookup() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-stranger")
        let f = fixture(
            responses: [(Self.profileJSON(email: "stranger@example.com", uuid: "uuid-x"), 200)],
            liveClaude: live)
        _ = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com", accountUUID: "uuid-one"),
            secret: .claude(claude("at-1", "rt-1")))

        #expect(await f.monitor.syncLiveLogin(for: .claude) == .someoneElse)
        #expect(await f.monitor.syncLiveLogin(for: .claude) == .someoneElse)
        #expect(f.http.sent.count == 1)
    }

    @Test("trusts the live tokens over a stale ~/.claude.json")
    func tokensOverrideProfileFile() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-one")
        let usage = (Data(Self.usageJSON.utf8), 200)
        let f = fixture(responses: [usage, usage], liveClaude: live, signedIn: "two@example.com")
        let one = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(claude("at-one", "rt-live")))
        _ = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "two@example.com"),
            secret: .claude(claude("at-two", "rt-two")))

        let statuses = await f.monitor.refreshAll()

        #expect(statuses.first { $0.isActive }?.id == one.id)
    }

    @Test("never files a login it cannot identify under any account")
    func leavesUnidentifiedLoginAlone() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-mystery")
        let f = fixture(responses: [(Data("down".utf8), 503)], liveClaude: live)
        let one = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(claude("at-1", "rt-1")))

        #expect(await f.monitor.syncLiveLogin(for: .claude) == .unknown)
        #expect(try await claudeSecret(f.vault, one.id).accessToken == "at-1")
    }

    @Test("reads the active account's usage with Claude Code's current token, so auto swap sees 99%")
    func activeUsageUsesLiveToken() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-rotated")
        let f = fixture(
            responses: [
                (Self.profileJSON(email: "one@example.com", uuid: "uuid-one"), 200),
                (Data(Self.usageJSON.utf8), 200),
            ],
            liveClaude: live)
        // The saved copy expired hours ago; before the fix this read failed.
        _ = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com", accountUUID: "uuid-one"),
            secret: .claude(claude("at-captured", "rt-captured", expiresIn: -7200)))

        let statuses = await f.monitor.refreshAll()

        let active = try #require(statuses.first { $0.isActive })
        #expect(active.error == nil)
        #expect(active.snapshot?.windows.contains { $0.usedFraction >= 0.99 } == true)
        #expect(f.http.sent.last?.value(forHTTPHeaderField: "Authorization") == "Bearer at-rotated")
        #expect(f.http.sent.allSatisfy { $0.url?.host != "console.anthropic.com" })
    }

    // MARK: Codex

    @Test("saves the tokens Codex rotated and still knows which account is active")
    func savesRotatedCodexTokens() async throws {
        let f = fixture(codexAuth: CodexCredentialTests.authJSON(refreshToken: "rt-rotated"))
        let account = try await f.vault.add(
            provider: .codex,
            identity: AccountIdentity(
                email: "builder@example.com", accountUUID: "09a98933-21df-4f88-bafd-319729cd80c0"),
            secret: .codex(CodexCredentials(
                idToken: CodexCredentialTests.idToken, accessToken: "at-captured",
                refreshToken: "rt-captured", accountID: "09a98933-21df-4f88-bafd-319729cd80c0")))

        #expect(await f.monitor.syncLiveLogin(for: .codex) == .account(account.id))
        guard case .codex(let saved) = try await f.vault.secret(for: account.id) else {
            Issue.record("expected Codex credentials")
            return
        }
        #expect(saved.refreshToken == "rt-rotated")
        #expect(saved.accessToken == "at-codex")
    }

    @Test("does not confuse two people who share a Codex workspace")
    func workspaceMatesAreDifferentAccounts() async throws {
        let f = fixture(codexAuth: CodexCredentialTests.authJSON(refreshToken: "rt-rotated"))
        let teammate = try await f.vault.add(
            provider: .codex,
            identity: AccountIdentity(
                email: "teammate@example.com", accountUUID: "09a98933-21df-4f88-bafd-319729cd80c0"),
            secret: .codex(CodexCredentials(
                idToken: "", accessToken: "at-mate", refreshToken: "rt-mate",
                accountID: "09a98933-21df-4f88-bafd-319729cd80c0")))

        #expect(await f.monitor.syncLiveLogin(for: .codex) == .someoneElse)
        guard case .codex(let saved) = try await f.vault.secret(for: teammate.id) else { return }
        #expect(saved.refreshToken == "rt-mate")
    }

    // MARK: Switching

    @Test("keeps the outgoing account's rotated login and renews the incoming one before switching")
    func switchSavesOutgoingAndRenewsIncoming() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-one-rotated")
        let f = fixture(
            responses: [
                (Self.profileJSON(email: "one@example.com", uuid: "uuid-one"), 200),
                (Data(Self.refreshJSON.utf8), 200),
            ],
            liveClaude: live, signedIn: "one@example.com")
        let one = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com", accountUUID: "uuid-one"),
            secret: .claude(claude("at-one-captured", "rt-one-captured")))
        let two = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "two@example.com", accountUUID: "uuid-two"),
            secret: .claude(claude("at-two", "rt-two")))

        try await f.monitor.activate(two)

        let item = try #require(f.secrets.contents(of: ClaudeKeychain.service))
        let written = try ClaudeCredentials(keychainJSON: item)
        #expect(written.accessToken == "at-fresh")
        #expect(written.refreshToken == "rt-fresh")
        #expect(try await claudeSecret(f.vault, one.id).accessToken == "at-one-rotated")
        #expect(try await claudeSecret(f.vault, two.id).refreshToken == "rt-fresh")
        let root = try #require(try JSONSerialization.jsonObject(with: item) as? [String: Any])
        #expect(root["mcpOAuth"] != nil)
    }

    @Test("refuses to hand Claude Code a login whose refresh token is dead")
    func refusesDeadLogin() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-one")
        let f = fixture(
            responses: [(Data(#"{"error":"invalid_grant"}"#.utf8), 400)],
            liveClaude: live, signedIn: "one@example.com")
        _ = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(claude("at-one", "rt-live")))
        let two = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "two@example.com"),
            secret: .claude(claude("at-two", "rt-two-rotated-away")))

        await #expect(throws: SwitchError.savedLoginExpired) {
            try await f.monitor.activate(two)
        }
        #expect(f.secrets.contents(of: ClaudeKeychain.service) == live)
        let profile = try #require(f.files.contents(at: "/home/.claude.json"))
        #expect(String(decoding: profile, as: UTF8.self).contains("one@example.com"))
    }

    @Test("switches offline when the saved token is still valid")
    func switchesOfflineWithValidToken() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-one")
        let f = fixture(responses: [], liveClaude: live, signedIn: "one@example.com")
        _ = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(claude("at-one", "rt-live")))
        let two = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "two@example.com"),
            secret: .claude(claude("at-two", "rt-two")))

        try await f.monitor.activate(two)

        let written = try ClaudeCredentials(
            keychainJSON: try #require(f.secrets.contents(of: ClaudeKeychain.service)))
        #expect(written.accessToken == "at-two")
    }

    @Test("does not switch offline to a login that has already expired")
    func refusesExpiredTokenOffline() async throws {
        let live = ClaudeCredentialTests.keychainJSON(accessToken: "at-one")
        let f = fixture(responses: [], liveClaude: live, signedIn: "one@example.com")
        _ = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(claude("at-one", "rt-live")))
        let two = try await f.vault.add(
            provider: .claude, identity: AccountIdentity(email: "two@example.com"),
            secret: .claude(claude("at-two", "rt-two", expiresIn: -60)))

        await #expect(throws: (any Error).self) { try await f.monitor.activate(two) }
        #expect(f.secrets.contents(of: ClaudeKeychain.service) == live)
    }

    @Test("identifies saved and live identities strictly")
    func identityMatching() {
        let saved = AccountIdentity(email: "One@Example.com", accountUUID: "uuid-1")
        #expect(AccountMonitor.isSameAccount(saved, AccountIdentity(email: "one@example.com", accountUUID: "UUID-1")))
        #expect(AccountMonitor.isSameAccount(saved, AccountIdentity(accountUUID: "uuid-1")))
        #expect(!AccountMonitor.isSameAccount(saved, AccountIdentity(email: "two@example.com", accountUUID: "uuid-1")))
        #expect(!AccountMonitor.isSameAccount(saved, AccountIdentity(email: "one@example.com", accountUUID: "uuid-2")))
        #expect(AccountMonitor.isSameAccount(AccountIdentity(email: "a@x.com"), AccountIdentity(email: "A@x.com")))
        #expect(!AccountMonitor.isSameAccount(AccountIdentity(), AccountIdentity()))
    }
}

import Foundation
import Testing

@testable import VibecomBarCore

@Suite("Account identity")
struct IdentityTests {
    @Test("reads who a Claude login belongs to from Anthropic's profile response")
    func parsesProfile() throws {
        let identity = try ClaudeProfileParser.identity(from: Fixture.data("claude_profile"))

        #expect(identity.email == "builder@example.com")
        #expect(identity.accountUUID == "acct-uuid-1")
        #expect(identity.organizationUUID == "org-uuid-1")
        #expect(identity.plan == "claude_max")
    }

    @Test("asks the profile endpoint with the same OAuth header as usage")
    func profileRequest() async throws {
        let http = StubHTTPClient(json: String(decoding: try Fixture.data("claude_profile"), as: UTF8.self))

        let identity = try await UsageService(http: http).fetchProfile(
            claude: ClaudeCredentials(accessToken: "at-1", scopes: ["user:profile"]))

        let request = try #require(http.sent.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(identity.email == "builder@example.com")
    }

    @Test("names a guided Claude sign-in after the account in its own config folder")
    func guidedCaptureReadsProfileFolder() throws {
        let service = "Claude Code-credentials-abcd1234"
        let secrets = MemorySecretStore([service: ClaudeCredentialTests.keychainJSON(accessToken: "at-new")])
        let files = MemoryFileStore([
            "/profiles/new/.claude.json": Data(
                #"{"oauthAccount":{"emailAddress":"second@example.com","accountUuid":"uuid-2","organizationType":"claude_max"}}"#.utf8)
        ])
        let importer = AccountImporter(
            environment: CLIEnvironment(
                secrets: secrets, files: files,
                claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
                codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json")))

        let captured = try importer.captureClaudeLogin(
            keychainService: service, configDir: URL(fileURLWithPath: "/profiles/new"))

        #expect(captured.identity.email == "second@example.com")
        #expect(captured.identity.accountUUID == "uuid-2")
    }

    @Test("names an account saved without an email once the provider says whose it is")
    func repairsUnnamedAccount() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore()
        let vault = AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
        let environment = CLIEnvironment(
            secrets: secrets, files: files,
            claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
            codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json"))
        let http = StubHTTPClient(responses: [
            (Data(#"{"five_hour":{"utilization":5,"resets_at":null}}"#.utf8), 200),
            (try Fixture.data("claude_profile"), 200),
        ])
        let monitor = AccountMonitor(
            vault: vault, activator: AccountActivator(vault: vault, environment: environment),
            environment: environment, http: http, usage: UsageService(http: http))
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(plan: "max"),
            secret: .claude(
                ClaudeCredentials(
                    accessToken: "at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
                    scopes: ["user:profile"])))
        #expect(account.label == "Claude Code account")

        let status = await monitor.refresh(account)

        #expect(status.account.label == "builder@example.com")
        #expect(try await vault.accounts().first?.identity.email == "builder@example.com")
    }

    @Test("keeps a name the user chose when filling in the email")
    func keepsCustomLabel() async throws {
        let vault = AccountVault(
            secrets: MemorySecretStore(), files: MemoryFileStore(), directory: URL(fileURLWithPath: "/vault"))
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(), secret: .claude(ClaudeCredentials(accessToken: "at")))
        _ = try await vault.rename(account.id, to: "Work")

        let updated = try await vault.fillIdentity(account.id, with: AccountIdentity(email: "w@example.com"))

        #expect(updated.label == "Work")
        #expect(updated.identity.email == "w@example.com")
    }
}

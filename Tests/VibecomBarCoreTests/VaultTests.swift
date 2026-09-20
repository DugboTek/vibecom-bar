import Foundation
import Testing

@testable import VibecomBarCore

/// Stand-ins for the keychain and the file system, so the tests that cover
/// overwriting real credentials never touch the real ones.
final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    private var readLog: [String] = []
    private var writeLog: [String] = []

    init(_ seed: [String: Data] = [:]) { items = seed }

    /// Every keychain read can cost the user a password prompt, so tests count them.
    func reads(of service: String) -> Int { lock.withLock { readLog.filter { $0 == service }.count } }
    func writes(of service: String) -> Int { lock.withLock { writeLog.filter { $0 == service }.count } }
    func reads(withPrefix prefix: String) -> Int { lock.withLock { readLog.filter { $0.hasPrefix(prefix) }.count } }

    func read(service: String) throws -> Data? {
        lock.withLock {
            readLog.append(service)
            return items[service]
        }
    }
    func write(_ data: Data, service: String) throws {
        lock.withLock {
            writeLog.append(service)
            items[service] = data
        }
    }
    func replaceExisting(_ data: Data, service: String) throws {
        try lock.withLock {
            guard items[service] != nil else { throw VaultError.missingExternalSecret }
            items[service] = data
        }
    }
    func delete(service: String) throws { lock.withLock { items[service] = nil } }
    func services(withPrefix prefix: String) throws -> [String] {
        lock.withLock { items.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    func contents(of service: String) -> Data? { lock.withLock { items[service] } }
}

final class MemoryFileStore: FileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]

    init(_ seed: [String: Data] = [:]) { files = seed }

    func read(_ url: URL) throws -> Data? { lock.withLock { files[url.path] } }
    func write(_ data: Data, to url: URL) throws { lock.withLock { files[url.path] = data } }
    func exists(_ url: URL) -> Bool { lock.withLock { files[url.path] != nil } }
    func remove(_ url: URL) throws { lock.withLock { files[url.path] = nil } }

    func contents(at path: String) -> Data? { lock.withLock { files[path] } }
}

private func makeVault(
    secrets: MemorySecretStore = MemorySecretStore(), files: MemoryFileStore = MemoryFileStore()
) -> AccountVault {
    AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
}

@Suite("Account vault")
struct AccountVaultTests {
    @Test("keeps an added account and its secret apart: metadata on disk, tokens in the keychain")
    func storesSecretInKeychainOnly() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore()
        let vault = makeVault(secrets: secrets, files: files)

        let account = try await vault.add(
            provider: .claude,
            identity: AccountIdentity(email: "one@example.com", plan: "max"),
            secret: .claude(ClaudeCredentials(accessToken: "at-secret", refreshToken: "rt")))

        let metadata = try #require(files.contents(at: "/vault/accounts.json"))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("at-secret"))
        #expect(String(decoding: metadata, as: UTF8.self).contains("one@example.com"))
        let stored = try await vault.secret(for: account.id)
        #expect(stored == .claude(ClaudeCredentials(accessToken: "at-secret", refreshToken: "rt")))
    }

    @Test("names an account after its email until it is renamed")
    func defaultsLabelToEmail() async throws {
        let vault = makeVault()

        let account = try await vault.add(
            provider: .codex, identity: AccountIdentity(email: "two@example.com", plan: "pro"),
            secret: .codex(CodexCredentials(idToken: "", accessToken: "a", refreshToken: "r")))

        #expect(account.label == "two@example.com")
        let renamed = try await vault.rename(account.id, to: "Side project")
        #expect(renamed.label == "Side project")
    }

    @Test("reloads accounts written by an earlier run")
    func reloadsFromDisk() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore()
        let first = makeVault(secrets: secrets, files: files)
        let account = try await first.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at")))

        let second = makeVault(secrets: secrets, files: files)

        #expect(try await second.accounts().map(\.id) == [account.id])
        #expect(try await second.secret(for: account.id) == .claude(ClaudeCredentials(accessToken: "at")))
    }

    @Test("adding the same provider account twice updates it instead of duplicating it")
    func replacesMatchingAccount() async throws {
        let vault = makeVault()
        let identity = AccountIdentity(email: "one@example.com", accountUUID: "uuid-1")
        _ = try await vault.add(
            provider: .claude, identity: identity,
            secret: .claude(ClaudeCredentials(accessToken: "old")))

        _ = try await vault.add(
            provider: .claude, identity: identity,
            secret: .claude(ClaudeCredentials(accessToken: "new")))

        let accounts = try await vault.accounts()
        #expect(accounts.count == 1)
        #expect(try await vault.secret(for: accounts[0].id) == .claude(ClaudeCredentials(accessToken: "new")))
    }

    @Test("reads each saved login from the keychain once, not on every refresh")
    func cachesSecrets() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore()
        let first = makeVault(secrets: secrets, files: files)
        let account = try await first.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at")))
        let vault = makeVault(secrets: secrets, files: files)

        for _ in 0..<5 { _ = try await vault.secret(for: account.id) }

        #expect(secrets.reads(withPrefix: AccountVault.secretServicePrefix) == 1)
    }

    @Test("moves a login saved by an older build into an item this build owns, once")
    func migratesLegacyItem() async throws {
        let id = UUID()
        let legacy = "build.vibecom.bar.account.\(id.uuidString)"
        let secret = AccountSecret.claude(ClaudeCredentials(accessToken: "at-old-build"))
        let secrets = MemorySecretStore([legacy: try JSONEncoder().encode(secret)])
        let files = MemoryFileStore()
        let account = StoredAccount(id: id, provider: .claude, label: "old", identity: AccountIdentity(email: "o@example.com"))
        try files.write(
            {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return try encoder.encode([account])
            }(), to: URL(fileURLWithPath: "/vault/accounts.json"))

        #expect(try await makeVault(secrets: secrets, files: files).secret(for: id) == secret)
        #expect(try await makeVault(secrets: secrets, files: files).secret(for: id) == secret)

        #expect(secrets.reads(of: legacy) == 1)
        #expect(secrets.contents(of: legacy) == nil)
        #expect(secrets.contents(of: AccountVault.secretServicePrefix + id.uuidString) != nil)
    }

    @Test("removing an account takes its tokens out of the keychain too")
    func removeClearsSecret() async throws {
        let secrets = MemorySecretStore()
        let vault = makeVault(secrets: secrets)
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "one@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at")))

        try await vault.remove(account.id)

        #expect(try await vault.accounts().isEmpty)
        #expect(secrets.contents(of: AccountVault.secretServicePrefix + account.id.uuidString) == nil)
    }
}

@Suite("Switching accounts")
struct ActivationTests {
    static let liveKeychain = ClaudeCredentialTests.keychainJSON(accessToken: "at-live")
    static let liveProfile = Data(
        """
        {"numStartups":42,"oauthAccount":{"emailAddress":"live@example.com","accountUuid":"uuid-live"}}
        """.utf8)

    private func environment(secrets: MemorySecretStore, files: MemoryFileStore) -> CLIEnvironment {
        CLIEnvironment(
            secrets: secrets, files: files,
            claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
            codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json"))
    }

    @Test("makes the chosen Claude account the one the CLI will use next")
    func activatesClaude() async throws {
        let secrets = MemorySecretStore([ClaudeKeychain.service: Self.liveKeychain])
        let files = MemoryFileStore(["/home/.claude.json": Self.liveProfile])
        let vault = makeVault(secrets: secrets, files: files)
        let account = try await vault.add(
            provider: .claude,
            identity: AccountIdentity(email: "other@example.com", accountUUID: "uuid-other", plan: "max"),
            secret: .claude(ClaudeCredentials(accessToken: "at-other", refreshToken: "rt-other")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        try await activator.activate(account)

        let written = try #require(secrets.contents(of: ClaudeKeychain.service))
        #expect(try ClaudeCredentials(keychainJSON: written).accessToken == "at-other")
    }

    @Test("never creates Claude Code's live keychain item")
    func doesNotCreateClaudeKeychainItem() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore(["/home/.claude.json": Self.liveProfile])
        let vault = makeVault(secrets: secrets, files: files)
        let account = try await vault.add(
            provider: .claude,
            identity: AccountIdentity(email: "other@example.com", accountUUID: "uuid-other"),
            secret: .claude(ClaudeCredentials(accessToken: "at-other", refreshToken: "rt-other")))
        let activator = AccountActivator(
            vault: vault, environment: environment(secrets: secrets, files: files))

        await #expect(throws: VaultError.missingExternalSecret) {
            try await activator.activate(account)
        }
        #expect(secrets.contents(of: ClaudeKeychain.service) == nil)
    }

    @Test("leaves the MCP server logins in place when switching")
    func keepsMCPLogins() async throws {
        let secrets = MemorySecretStore([ClaudeKeychain.service: Self.liveKeychain])
        let files = MemoryFileStore(["/home/.claude.json": Self.liveProfile])
        let vault = makeVault(secrets: secrets, files: files)
        let account = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "other@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at-other")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        try await activator.activate(account)

        let written = try #require(secrets.contents(of: ClaudeKeychain.service))
        let root = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect((root["mcpOAuth"] as? [String: Any])?["linear|638130d5"] != nil)
    }

    @Test("tells the CLI which account is signed in, without disturbing other settings")
    func rewritesProfileIdentity() async throws {
        let secrets = MemorySecretStore([ClaudeKeychain.service: Self.liveKeychain])
        let files = MemoryFileStore(["/home/.claude.json": Self.liveProfile])
        let vault = makeVault(secrets: secrets, files: files)
        let account = try await vault.add(
            provider: .claude,
            identity: AccountIdentity(email: "other@example.com", accountUUID: "uuid-other"),
            secret: .claude(ClaudeCredentials(accessToken: "at-other")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        try await activator.activate(account)

        let profile = try #require(files.contents(at: "/home/.claude.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: profile) as? [String: Any])
        #expect(root["numStartups"] as? Int == 42)
        #expect((root["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "other@example.com")
    }

    @Test("writes a Codex auth.json the CLI can read back")
    func activatesCodex() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore(["/home/.codex/auth.json": CodexCredentialTests.authJSON()])
        let vault = makeVault(secrets: secrets, files: files)
        let credentials = CodexCredentials(
            idToken: "id-2", accessToken: "at-2", refreshToken: "rt-2", accountID: "acct-2")
        let account = try await vault.add(
            provider: .codex, identity: AccountIdentity(email: "codex@example.com"),
            secret: .codex(credentials))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        try await activator.activate(account)

        let written = try #require(files.contents(at: "/home/.codex/auth.json"))
        #expect(try CodexCredentials(authFileJSON: written) == credentials)
    }

    @Test("keeps a copy of whatever it replaced the first time it overwrites")
    func backsUpPreviousCredentials() async throws {
        let secrets = MemorySecretStore()
        let files = MemoryFileStore(["/home/.codex/auth.json": CodexCredentialTests.authJSON()])
        let vault = makeVault(secrets: secrets, files: files)
        let account = try await vault.add(
            provider: .codex, identity: AccountIdentity(email: "codex@example.com"),
            secret: .codex(CodexCredentials(idToken: "i", accessToken: "a", refreshToken: "r")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        try await activator.activate(account)

        let backup = try #require(files.contents(at: "/home/.codex/auth.json.vibecom-backup"))
        #expect(try CodexCredentials(authFileJSON: backup).accessToken == "at-codex")
    }

    @Test("recognises which stored account is the one currently signed in")
    func identifiesActiveAccount() async throws {
        let secrets = MemorySecretStore([ClaudeKeychain.service: Self.liveKeychain])
        let files = MemoryFileStore(["/home/.claude.json": Self.liveProfile])
        let vault = makeVault(secrets: secrets, files: files)
        let live = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "live@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at-live")))
        _ = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "other@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at-other")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        #expect(try await activator.activeAccountID(for: .claude) == live.id)
    }

    @Test("tells which Claude account is signed in without reading the keychain")
    func detectsActiveClaudeFromProfileFile() async throws {
        let secrets = MemorySecretStore([ClaudeKeychain.service: Self.liveKeychain])
        let files = MemoryFileStore(["/home/.claude.json": Self.liveProfile])
        let vault = makeVault(secrets: secrets, files: files)
        let live = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "live@example.com", accountUUID: "uuid-live"),
            secret: .claude(ClaudeCredentials(accessToken: "at-anything")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        let active = try await activator.activeAccountID(for: .claude)

        #expect(active == live.id)
        #expect(secrets.reads(of: ClaudeKeychain.service) == 0)
    }

    @Test("reports no active account when the signed-in login was never captured")
    func reportsUnknownActiveAccount() async throws {
        let secrets = MemorySecretStore([ClaudeKeychain.service: Self.liveKeychain])
        let files = MemoryFileStore()
        let vault = makeVault(secrets: secrets, files: files)
        _ = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "other@example.com"),
            secret: .claude(ClaudeCredentials(accessToken: "at-other")))
        let activator = AccountActivator(vault: vault, environment: environment(secrets: secrets, files: files))

        #expect(try await activator.activeAccountID(for: .claude) == nil)
    }
}

@Suite("Capturing a login")
struct AccountImportTests {
    @Test("captures the Claude account that is signed in right now")
    func capturesActiveClaudeLogin() async throws {
        let secrets = MemorySecretStore([
            ClaudeKeychain.service: ClaudeCredentialTests.keychainJSON(accessToken: "at-live")
        ])
        let files = MemoryFileStore([
            "/home/.claude.json": Data(
                """
                {"oauthAccount":{"emailAddress":"live@example.com","accountUuid":"uuid-live",
                 "organizationType":"claude_max"}}
                """.utf8)
        ])
        let importer = AccountImporter(
            environment: CLIEnvironment(
                secrets: secrets, files: files,
                claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
                codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json")))

        let captured = try importer.captureActiveClaudeLogin()

        #expect(captured.identity.email == "live@example.com")
        #expect(captured.identity.plan == "claude_max")
        #expect(captured.secret == .claude(try ClaudeCredentials(keychainJSON: ClaudeCredentialTests.keychainJSON(accessToken: "at-live"))))
    }

    @Test("reads a Codex login out of the profile directory a guided sign-in used")
    func capturesCodexLoginFromProfile() async throws {
        let files = MemoryFileStore(["/profiles/new/auth.json": CodexCredentialTests.authJSON()])
        let importer = AccountImporter(
            environment: CLIEnvironment(
                secrets: MemorySecretStore(), files: files,
                claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
                codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json")))

        let captured = try importer.captureCodexLogin(
            fromCodexHome: URL(fileURLWithPath: "/profiles/new"))

        #expect(captured.identity.email == "builder@example.com")
        #expect(captured.identity.plan == "pro")
    }

    @Test("explains itself when nobody is signed in to capture")
    func failsWhenNoLoginPresent() {
        let importer = AccountImporter(
            environment: CLIEnvironment(
                secrets: MemorySecretStore(), files: MemoryFileStore(),
                claudeConfigFile: URL(fileURLWithPath: "/home/.claude.json"),
                codexAuthFile: URL(fileURLWithPath: "/home/.codex/auth.json")))

        #expect(throws: ImportError.noActiveLogin(.claude)) {
            try importer.captureActiveClaudeLogin()
        }
    }

    @Test("spots the keychain item a guided Claude sign-in just created")
    func findsNewKeychainService() {
        let before = ["Claude Code-credentials", "Claude Code-credentials-71d93ce9"]
        let after = ["Claude Code-credentials", "Claude Code-credentials-71d93ce9", "Claude Code-credentials-abcd1234"]

        #expect(ClaudeKeychain.newService(before: before, after: after) == "Claude Code-credentials-abcd1234")
        #expect(ClaudeKeychain.newService(before: before, after: before) == nil)
    }
}

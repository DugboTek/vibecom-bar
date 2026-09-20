import Foundation

// MARK: - Storage seams

public protocol SecretStore: Sendable {
    func read(service: String) throws -> Data?
    func write(_ data: Data, service: String) throws
    /// Replaces an existing item without creating it or changing its ownership
    /// metadata. Used for credential stores owned by another application.
    func replaceExisting(_ data: Data, service: String) throws
    func delete(service: String) throws
    func services(withPrefix prefix: String) throws -> [String]
    /// Deletes only if it can be done without asking the user; otherwise leaves
    /// the item alone. For tidying up, never for anything that must happen.
    func deleteIfSilent(service: String)
}

extension SecretStore {
    public func replaceExisting(_ data: Data, service: String) throws {
        guard try read(service: service) != nil else { throw VaultError.missingExternalSecret }
        try write(data, service: service)
    }
    public func deleteIfSilent(service: String) { try? delete(service: service) }
}

public protocol FileStore: Sendable {
    func read(_ url: URL) throws -> Data?
    func write(_ data: Data, to url: URL) throws
    func exists(_ url: URL) -> Bool
    func remove(_ url: URL) throws
}

// MARK: - Model

public enum AccountSecret: Codable, Equatable, Sendable {
    case claude(ClaudeCredentials)
    case codex(CodexCredentials)

    public var provider: Provider {
        switch self {
        case .claude: .claude
        case .codex: .codex
        }
    }
}

public struct StoredAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var identity: AccountIdentity
    public var addedAt: Date
    public var sortIndex: Int

    public init(
        id: UUID = UUID(), provider: Provider, label: String, identity: AccountIdentity,
        addedAt: Date = Date(), sortIndex: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.identity = identity
        self.addedAt = addedAt
        self.sortIndex = sortIndex
    }

    /// Two captures are the same account when the provider says they are the
    /// same person, so re-capturing refreshes rather than duplicates.
    func isSameAccount(as other: AccountIdentity) -> Bool {
        if let mine = identity.accountUUID, let theirs = other.accountUUID { return mine == theirs }
        if let mine = identity.email, let theirs = other.email { return mine == theirs }
        return false
    }
}

public enum VaultError: Error, Equatable {
    case unknownAccount(UUID)
    case missingSecret(UUID)
    case missingExternalSecret
}

/// Account metadata lives in a plain file; tokens only ever live in the keychain.
public actor AccountVault {
    /// Items under this name are created by the signed app, so the keychain
    /// already trusts it and never asks.
    public static let secretServicePrefix = "build.vibecom.bar.v2.account."
    /// Saved by builds signed differently; each is read once and moved.
    static let legacyServicePrefixes = ["build.vibecom.bar.account."]

    private let secrets: SecretStore
    private let servicePrefix: String
    private let files: FileStore
    private let directory: URL
    private var cache: [StoredAccount]?
    /// Every keychain read can put a password prompt in front of the user, so
    /// each saved login is read once per launch and kept in memory after that.
    private var secretCache: [UUID: AccountSecret] = [:]

    public init(
        secrets: SecretStore, files: FileStore, directory: URL,
        servicePrefix: String = AccountVault.secretServicePrefix
    ) {
        self.secrets = secrets
        self.files = files
        self.directory = directory
        self.servicePrefix = servicePrefix
    }

    private var metadataURL: URL { directory.appendingPathComponent("accounts.json") }

    public func accounts() throws -> [StoredAccount] {
        if let cache { return cache }
        guard let data = try files.read(metadataURL) else {
            cache = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? decoder.decode([StoredAccount].self, from: data)) ?? []
        cache = loaded.sorted { $0.sortIndex < $1.sortIndex }
        return cache ?? []
    }

    public func accounts(for provider: Provider) throws -> [StoredAccount] {
        try accounts().filter { $0.provider == provider }
    }

    @discardableResult
    public func add(
        provider: Provider, identity: AccountIdentity, secret: AccountSecret, label: String? = nil
    ) throws -> StoredAccount {
        var all = try accounts()
        let existing = all.first { $0.provider == provider && $0.isSameAccount(as: identity) }

        let account = StoredAccount(
            id: existing?.id ?? UUID(),
            provider: provider,
            label: label ?? existing?.label ?? Self.defaultLabel(for: identity, provider: provider),
            identity: identity,
            addedAt: existing?.addedAt ?? Date(),
            sortIndex: existing?.sortIndex ?? all.count
        )

        try writeSecret(secret, for: account.id)
        if let index = all.firstIndex(where: { $0.id == account.id }) {
            all[index] = account
        } else {
            all.append(account)
        }
        try persist(all)
        return account
    }

    public func secret(for id: UUID) throws -> AccountSecret {
        if let cached = secretCache[id] { return cached }
        if let data = try secrets.read(service: servicePrefix + id.uuidString) {
            let secret = try JSONDecoder().decode(AccountSecret.self, from: data)
            secretCache[id] = secret
            return secret
        }

        // An item from a differently signed build asks for permission on every
        // read. Read it this one time, re-save it as this build's own item, and
        // remove the old one.
        for legacy in Self.legacyServicePrefixes {
            guard let data = try? secrets.read(service: legacy + id.uuidString),
                let secret = try? JSONDecoder().decode(AccountSecret.self, from: data)
            else { continue }
            try writeSecret(secret, for: id)
            secrets.deleteIfSilent(service: legacy + id.uuidString)
            return secret
        }
        throw VaultError.missingSecret(id)
    }

    public func update(secret: AccountSecret, for id: UUID) throws {
        try writeSecret(secret, for: id)
    }

    @discardableResult
    public func rename(_ id: UUID, to label: String) throws -> StoredAccount {
        var all = try accounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw VaultError.unknownAccount(id)
        }
        all[index].label = label
        try persist(all)
        return all[index]
    }

    /// Records who an account belongs to. A name the user chose is kept; the
    /// placeholder name an unnamed login got is replaced by the email.
    @discardableResult
    public func fillIdentity(_ id: UUID, with identity: AccountIdentity) throws -> StoredAccount {
        var all = try accounts()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw VaultError.unknownAccount(id)
        }
        let placeholder = Self.defaultLabel(for: all[index].identity, provider: all[index].provider)
        let hadPlaceholderName = all[index].label == placeholder
        all[index].identity = identity
        if hadPlaceholderName {
            all[index].label = Self.defaultLabel(for: identity, provider: all[index].provider)
        }
        try persist(all)
        return all[index]
    }

    public func reorder(_ ids: [UUID]) throws {
        var all = try accounts()
        for (index, id) in ids.enumerated() {
            if let position = all.firstIndex(where: { $0.id == id }) {
                all[position].sortIndex = index
            }
        }
        try persist(all.sorted { $0.sortIndex < $1.sortIndex })
    }

    public func remove(_ id: UUID) throws {
        let all = try accounts().filter { $0.id != id }
        try secrets.delete(service: servicePrefix + id.uuidString)
        for legacy in Self.legacyServicePrefixes {
            try? secrets.delete(service: legacy + id.uuidString)
        }
        secretCache[id] = nil
        try persist(all)
    }

    private func writeSecret(_ secret: AccountSecret, for id: UUID) throws {
        let data = try JSONEncoder().encode(secret)
        try secrets.write(data, service: servicePrefix + id.uuidString)
        secretCache[id] = secret
    }

    private func persist(_ all: [StoredAccount]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(try encoder.encode(all), to: metadataURL)
        cache = all
    }

    private static func defaultLabel(for identity: AccountIdentity, provider: Provider) -> String {
        identity.email ?? identity.organizationName ?? "\(provider.displayName) account"
    }
}

// MARK: - Where the CLIs keep their credentials

public enum ClaudeKeychain {
    public static let service = "Claude Code-credentials"

    /// A guided sign-in under its own CLAUDE_CONFIG_DIR lands in a keychain
    /// item whose name ends in a hash of that directory. Rather than guess the
    /// hash, the app compares the item list before and after.
    public static func newService(before: [String], after: [String]) -> String? {
        Set(after).subtracting(before).sorted().first
    }
}

public struct CLIEnvironment: Sendable {
    public let secrets: SecretStore
    public let files: FileStore
    public let claudeConfigFile: URL
    public let codexAuthFile: URL

    public init(secrets: SecretStore, files: FileStore, claudeConfigFile: URL, codexAuthFile: URL) {
        self.secrets = secrets
        self.files = files
        self.claudeConfigFile = claudeConfigFile
        self.codexAuthFile = codexAuthFile
    }

    public static func live(
        secrets: SecretStore = KeychainSecretStore(), files: FileStore = DiskFileStore()
    ) -> CLIEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CLIEnvironment(
            secrets: secrets,
            files: files,
            claudeConfigFile: home.appendingPathComponent(".claude.json"),
            codexAuthFile: home.appendingPathComponent(".codex/auth.json")
        )
    }
}

// MARK: - Switching

public struct AccountActivator: Sendable {
    private let vault: AccountVault
    private let environment: CLIEnvironment

    public init(vault: AccountVault, environment: CLIEnvironment) {
        self.vault = vault
        self.environment = environment
    }

    public func activate(_ account: StoredAccount) async throws {
        switch try await vault.secret(for: account.id) {
        case .claude(let credentials):
            try backUpClaudeKeychainOnce()
            guard let existing = try environment.secrets.read(service: ClaudeKeychain.service) else {
                // Claude must create its own live item. If Vibecom creates it,
                // macOS trusts only Vibecom and Claude Code prompts forever.
                throw VaultError.missingExternalSecret
            }
            let merged = try ClaudeCredentials.merge(credentials, intoKeychainJSON: existing)
            try environment.secrets.replaceExisting(merged, service: ClaudeKeychain.service)

            let profile = try environment.files.read(environment.claudeConfigFile)
            let updated = try ClaudeProfileFile.apply(account.identity, toJSON: profile)
            try environment.files.write(updated, to: environment.claudeConfigFile)

        case .codex(let credentials):
            try backUpOnce(environment.codexAuthFile)
            try environment.files.write(try credentials.authFileJSON(), to: environment.codexAuthFile)
        }
    }

    /// Which stored account the CLI would use right now. Claude is read from
    /// `~/.claude.json`, a plain file, because reading Claude Code's keychain
    /// item on every refresh is what put password prompts in front of the user.
    /// Codex keeps its login in a file, so its token is compared directly.
    public func activeAccountID(for provider: Provider) async throws -> UUID? {
        let accounts = try await vault.accounts(for: provider)

        switch provider {
        case .claude:
            guard let data = try environment.files.read(environment.claudeConfigFile),
                let live = ClaudeProfileFile.identity(fromJSON: data)
            else { return nil }
            if let uuid = live.accountUUID,
                let match = accounts.first(where: { $0.identity.accountUUID == uuid })
            {
                return match.id
            }
            guard let email = live.email else { return nil }
            return accounts.first { $0.identity.email?.lowercased() == email.lowercased() }?.id

        case .codex:
            guard let liveToken = try liveAccessToken(for: .codex) else { return nil }
            for account in accounts {
                if case .codex(let credentials) = try? await vault.secret(for: account.id),
                    credentials.accessToken == liveToken
                {
                    return account.id
                }
            }
            return nil
        }
    }

    private func liveAccessToken(for provider: Provider) throws -> String? {
        switch provider {
        case .claude:
            guard let data = try environment.secrets.read(service: ClaudeKeychain.service) else { return nil }
            return try? ClaudeCredentials(keychainJSON: data).accessToken
        case .codex:
            guard let data = try environment.files.read(environment.codexAuthFile) else { return nil }
            return try? CodexCredentials(authFileJSON: data).accessToken
        }
    }

    private func backUpOnce(_ url: URL) throws {
        let backup = url.appendingPathExtension("vibecom-backup")
        guard !environment.files.exists(backup), let current = try environment.files.read(url) else { return }
        try environment.files.write(current, to: backup)
    }

    private func backUpClaudeKeychainOnce() throws {
        let backupService = ClaudeKeychain.service + " (vibecom backup)"
        guard try environment.secrets.read(service: backupService) == nil,
            let current = try environment.secrets.read(service: ClaudeKeychain.service)
        else { return }
        try environment.secrets.write(current, service: backupService)
    }
}

// MARK: - Capturing logins

public struct CapturedLogin: Equatable, Sendable {
    public let provider: Provider
    public let identity: AccountIdentity
    public let secret: AccountSecret
}

public enum ImportError: Error, Equatable {
    case noActiveLogin(Provider)
    case cannotReadUsage
}

public struct AccountImporter: Sendable {
    private let environment: CLIEnvironment

    public init(environment: CLIEnvironment) {
        self.environment = environment
    }

    /// Captures whoever is signed in to Claude Code right now.
    public func captureActiveClaudeLogin() throws -> CapturedLogin {
        guard let data = try environment.secrets.read(service: ClaudeKeychain.service) else {
            throw ImportError.noActiveLogin(.claude)
        }
        return try captureClaudeLogin(keychainService: ClaudeKeychain.service, payload: data)
    }

    /// Captures a sign-in that ran under its own CLAUDE_CONFIG_DIR, named after
    /// the account recorded in that directory's own `.claude.json`.
    public func captureClaudeLogin(keychainService: String, configDir: URL) throws -> CapturedLogin {
        guard let data = try environment.secrets.read(service: keychainService) else {
            throw ImportError.noActiveLogin(.claude)
        }
        return try captureClaudeLogin(
            payload: data, profileFile: configDir.appendingPathComponent(".claude.json"))
    }

    private func captureClaudeLogin(keychainService: String, payload: Data) throws -> CapturedLogin {
        try captureClaudeLogin(payload: payload, profileFile: environment.claudeConfigFile)
    }

    private func captureClaudeLogin(payload: Data, profileFile: URL) throws -> CapturedLogin {
        let credentials: ClaudeCredentials
        do {
            credentials = try ClaudeCredentials(keychainJSON: payload)
        } catch {
            throw ImportError.noActiveLogin(.claude)
        }
        guard credentials.canReadUsage else { throw ImportError.cannotReadUsage }

        var identity = AccountIdentity(plan: credentials.subscriptionType)
        if let profile = try environment.files.read(profileFile),
            let fromProfile = ClaudeProfileFile.identity(fromJSON: profile)
        {
            identity = fromProfile
        }

        return CapturedLogin(provider: .claude, identity: identity, secret: .claude(credentials))
    }

    public func captureActiveCodexLogin() throws -> CapturedLogin {
        try captureCodexLogin(fromCodexHome: environment.codexAuthFile.deletingLastPathComponent())
    }

    public func captureCodexLogin(fromCodexHome home: URL) throws -> CapturedLogin {
        guard let data = try environment.files.read(home.appendingPathComponent("auth.json")) else {
            throw ImportError.noActiveLogin(.codex)
        }
        let credentials: CodexCredentials
        do {
            credentials = try CodexCredentials(authFileJSON: data)
        } catch {
            throw ImportError.noActiveLogin(.codex)
        }

        return CapturedLogin(
            provider: .codex,
            identity: credentials.identity ?? AccountIdentity(accountUUID: credentials.accountID),
            secret: .codex(credentials))
    }
}

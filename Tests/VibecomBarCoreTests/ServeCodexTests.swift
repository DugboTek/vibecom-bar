import Foundation
import Testing

@testable import VibecomBarCore

private let refreshSecret = "rt_real-rotating-refresh-token-never-served-0123456789"
private let apiKeySecret = "sk-proj-never-served-api-key"

/// An unsigned JWT with the given `exp`; vibecom bar only reads claims.
private func jwt(exp: Date, extra: [String: Any] = [:]) -> String {
    func part(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    var claims = extra
    claims["exp"] = exp.timeIntervalSince1970
    return part(["alg": "none"]) + "." + part(claims) + ".sig"
}

private func codexLogin(expiresIn seconds: TimeInterval, now: Date, account: String = "acct-1") -> CodexCredentials {
    CodexCredentials(
        idToken: jwt(exp: now.addingTimeInterval(seconds), extra: ["email": "\(account)@example.com"]),
        accessToken: jwt(exp: now.addingTimeInterval(seconds), extra: ["sub": account]),
        refreshToken: refreshSecret + account, accountID: account, apiKey: apiKeySecret,
        lastRefresh: "2026-11-01T00:00:00.000Z")
}

private func codexAccount(_ label: String) -> StoredAccount {
    StoredAccount(provider: .codex, label: label, identity: AccountIdentity(email: label))
}

private final class MemoryRecord: ServeOwnershipStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServedFileRecord?
    func load() -> ServedFileRecord? { lock.withLock { stored } }
    func save(_ record: ServedFileRecord?) throws { lock.withLock { stored = record } }
}

/// A private 750 folder owned by this user, as the setup notes describe.
private struct CodexSandbox {
    let folder: URL
    var target: URL { folder.appendingPathComponent("codex-auth.json") }

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    func settings(enabled: Bool = true) -> ServeSettings {
        ServeSettings(isEnabled: enabled, path: target.path, fileExtension: ServeSettings.codexExtension)
    }
    var data: Data? { try? Data(contentsOf: target) }
    var exists: Bool { FileManager.default.fileExists(atPath: target.path) }
    var mode: Int? { (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int }
    var json: [String: Any]? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}

@Suite("Serve Codex to another local user")
struct ServeCodexTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the served bytes never contain the refresh token or the API key")
    func payloadHasNoRefreshTokenOrAPIKey() throws {
        let login = codexLogin(expiresIn: 9 * 24 * 3600, now: now)
        let data = try CodexServe.payload(for: login, now: now).get()
        #expect(data.range(of: Data(refreshSecret.utf8)) == nil)
        #expect(data.range(of: Data(apiKeySecret.utf8)) == nil)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tokens = try #require(root["tokens"] as? [String: Any])
        #expect(tokens["refresh_token"] as? String == CodexServe.placeholderRefreshToken)
        #expect(tokens["access_token"] as? String == login.accessToken)
        #expect(tokens["id_token"] as? String == login.idToken)
        #expect(tokens["account_id"] as? String == "acct-1")
        #expect(root["auth_mode"] as? String == "chatgpt")
        // Codex must still read it as a ChatGPT login.
        let parsed = try CodexCredentials(authFileJSON: data)
        #expect(parsed.accessToken == login.accessToken)
    }

    @Test("under a day left, or no readable expiry, is never served")
    func expiringIsRefused() {
        #expect(CodexServe.payload(for: codexLogin(expiresIn: 23 * 3600, now: now), now: now) == .failure(.expiring))
        var noExpiry = codexLogin(expiresIn: 9 * 24 * 3600, now: now)
        noExpiry.accessToken = "not-a-jwt"
        #expect(CodexServe.payload(for: noExpiry, now: now) == .failure(.unknownExpiry))
        #expect((try? CodexServe.payload(for: codexLogin(expiresIn: 25 * 3600, now: now), now: now).get()) != nil)
    }

    @Test("renewal starts under three days left, and the thresholds keep their order")
    func renewalThreshold() {
        #expect(CodexServe.needsRenewal(codexLogin(expiresIn: 71 * 3600, now: now), now: now))
        #expect(!CodexServe.needsRenewal(codexLogin(expiresIn: 73 * 3600, now: now), now: now))
        #expect(CodexServe.consumerRefuseBelow < CodexServe.withdrawBelow)
        #expect(CodexServe.withdrawBelow < CodexServe.renewBelow)
    }

    @Test("the active Codex login is written at 640 and a swap rewrites it")
    func servesAndFollowsSwap() throws {
        let box = try CodexSandbox()
        defer { box.cleanUp() }
        let server = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let alpha = codexAccount("alpha@example.com")
        let bravo = codexAccount("bravo@example.com")
        let alphaLogin = codexLogin(expiresIn: 9 * 24 * 3600, now: now, account: "alpha")
        let bravoLogin = codexLogin(expiresIn: 9 * 24 * 3600, now: now, account: "bravo")

        let first = server.sync(codex: box.settings(), active: alpha, credentials: alphaLogin, now: now)
        #expect(first == .serving(account: alpha.label, path: box.target.path, group: first.groupForTest))
        #expect(box.mode == 0o640)
        #expect(((box.json?["tokens"] as? [String: Any])?["access_token"] as? String) == alphaLogin.accessToken)

        _ = server.sync(codex: box.settings(), active: bravo, credentials: bravoLogin, now: now)
        let tokens = box.json?["tokens"] as? [String: Any]
        #expect(tokens?["access_token"] as? String == bravoLogin.accessToken)
        #expect(box.data?.range(of: Data(bravoLogin.refreshToken.utf8)) == nil)
    }

    @Test("a login with under a day left removes the file, so the other user pauses")
    func expiringRemovesFile() throws {
        let box = try CodexSandbox()
        defer { box.cleanUp() }
        let server = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let alpha = codexAccount("alpha@example.com")
        _ = server.sync(codex: box.settings(), active: alpha, credentials: codexLogin(expiresIn: 5 * 24 * 3600, now: now), now: now)
        #expect(box.exists)

        let status = server.sync(
            codex: box.settings(), active: alpha, credentials: codexLogin(expiresIn: 20 * 3600, now: now), now: now)
        #expect(status == .pausedCodexExpiring(account: alpha.label))
        #expect(!box.exists)
    }

    @Test("a Claude account active never writes the Codex file, and Codex never feeds the Claude file")
    func providersStayApart() async throws {
        let box = try CodexSandbox()
        defer { box.cleanUp() }
        let server = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let claude = StoredAccount(provider: .claude, label: "claude@example.com", identity: AccountIdentity())
        let status = server.sync(codex: box.settings(), active: claude, credentials: codexLogin(expiresIn: 9 * 24 * 3600, now: now), now: now)
        #expect(status == .pausedNoActiveCodexAccount)
        #expect(!box.exists)

        let claudeFile = box.folder.appendingPathComponent("claude.token")
        let claudeServer = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let store = ServeTokenStore(secrets: MemorySecretStore())
        let codex = codexAccount("codex@example.com")
        let claudeStatus = await claudeServer.sync(
            settings: ServeSettings(isEnabled: true, path: claudeFile.path), active: codex, tokens: store)
        #expect(claudeStatus == .pausedNoActiveAccount)
        #expect(!FileManager.default.fileExists(atPath: claudeFile.path))
    }

    @Test("the setting off removes the file it wrote, and the .json ending is required")
    func offAndPathRules() throws {
        let box = try CodexSandbox()
        defer { box.cleanUp() }
        let server = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let alpha = codexAccount("alpha@example.com")
        _ = server.sync(codex: box.settings(), active: alpha, credentials: codexLogin(expiresIn: 9 * 24 * 3600, now: now), now: now)
        #expect(box.exists)
        #expect(server.sync(codex: box.settings(enabled: false), active: alpha, credentials: nil, now: now) == .off)
        #expect(!box.exists)

        #expect(ServeSettings.problem(with: ServeSettings.codexDefaultPath, fileExtension: "json") == nil)
        #expect(ServeSettings.problem(with: "/Users/Shared/compass-auth/codex.token", fileExtension: "json") != nil)
        #expect(ServeSettings.problem(with: "/Users/someone/.codex/auth.json", fileExtension: "json") == nil)
        #expect(ServeSettings.problem(with: ServeSettings.codexDefaultPath) != nil)
    }

    @Test("the Codex file follows the same folder rules: a 770 folder is refused")
    func folderRulesApply() throws {
        let box = try CodexSandbox()
        defer { box.cleanUp() }
        chmod(box.folder.path, 0o770)
        let server = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let status = server.sync(
            codex: box.settings(), active: codexAccount("alpha@example.com"),
            credentials: codexLogin(expiresIn: 9 * 24 * 3600, now: now), now: now)
        #expect(status == .failed(ServeFileError.folderGroupWritable(box.folder.path).message))
        #expect(!box.exists)
    }

    @Test("a file vibecom bar didn't write at the Codex path is left alone")
    func foreignFileUntouched() throws {
        let box = try CodexSandbox()
        defer { box.cleanUp() }
        try Data("someone else's".utf8).write(to: box.target)
        let server = LocalUserServer(ownership: MemoryRecord(), log: { _ in })
        let status = server.sync(
            codex: box.settings(), active: codexAccount("alpha@example.com"),
            credentials: codexLogin(expiresIn: 9 * 24 * 3600, now: now), now: now)
        #expect(status == .foreignFile(path: box.target.path))
        #expect(box.data == Data("someone else's".utf8))
    }

    @Test("Codex settings default off and old preference files still load")
    func preferencesDefault() throws {
        let defaults = Preferences()
        #expect(defaults.serveCodexEnabled == false)
        #expect(defaults.serveCodexPath == "/Users/Shared/compass-auth/codex-auth.json")
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(old.serveCodexEnabled == false)
        var changed = defaults
        changed.serveCodexEnabled = true
        let round = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        #expect(round.serveCodexEnabled)
        #expect(ServeSettings(codexPreferences: round).fileExtension == "json")
    }
}

private extension ServeStatus {
    /// The group the sandbox file landed in, which depends on the test host.
    var groupForTest: String? {
        if case .serving(_, _, let group) = self { return group }
        return nil
    }
}

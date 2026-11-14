import Darwin
import Foundation
import Testing

@testable import VibecomBarCore

/// Collects what the server logs, standing in for the activity log.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func record(_ line: String) { lock.withLock { stored.append(line) } }
}

/// Counts writes and removals on top of the real disk implementation.
private final class CountingFileSystem: ServeFileSystem, @unchecked Sendable {
    private let base: DiskServeFileSystem
    private let lock = NSLock()
    private var writeCount = 0
    var writes: Int { lock.withLock { writeCount } }

    init(base: DiskServeFileSystem = DiskServeFileSystem()) { self.base = base }

    func checkFolder(_ folder: URL) throws { try base.checkFolder(folder) }
    func current(_ url: URL) -> (data: Data, mode: mode_t)? { base.current(url) }
    func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        lock.withLock { writeCount += 1 }
        try base.writeAtomically(data, to: url, mode: mode)
    }
    func entry(at url: URL) -> ServeFileEntry { base.entry(at: url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func groupName(of url: URL) -> String? { base.groupName(of: url) }
}

private struct InjectedFailure: Error {}

/// Which file the server wrote, kept in memory and shared by every server a
/// test creates, the way the real record survives a relaunch.
private final class MemoryOwnershipStore: ServeOwnershipStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServedFileRecord?
    var record: ServedFileRecord? { lock.withLock { stored } }
    func load() -> ServedFileRecord? { lock.withLock { stored } }
    func save(_ record: ServedFileRecord?) throws { lock.withLock { stored = record } }
}

private let tokenA = "sk-ant-oat01-AAAA_served_token_for_alpha_0123456789"
private let tokenB = "sk-ant-oat01-BBBB_served_token_for_bravo_9876543210"
private let accessToken = "sk-ant-oat01-short-lived-access-from-the-refresh-pair"
private let refreshToken = "sk-ant-ort01-rotating-refresh-token-never-served"

/// A private folder laid out the way the setup notes describe: owned by this
/// user, mode 750.
private struct Sandbox {
    let folder: URL
    let ownership = MemoryOwnershipStore()
    var target: URL { folder.appendingPathComponent("claude.token") }

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-serve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    var contents: String? {
        (try? Data(contentsOf: target)).map { String(decoding: $0, as: UTF8.self) }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: target.path) }

    var mode: Int? {
        (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int
    }

    /// Anything left in the folder other than the token file itself.
    var strayFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0 != "claude.token" }
    }

    func settings(enabled: Bool = true) -> ServeSettings {
        ServeSettings(isEnabled: enabled, path: target.path)
    }
}

private func account(_ label: String) -> StoredAccount {
    StoredAccount(provider: .claude, label: label, identity: AccountIdentity(email: label))
}

private func tokens(_ seed: [UUID: String] = [:], secrets: MemorySecretStore = MemorySecretStore())
    async throws -> ServeTokenStore
{
    let store = ServeTokenStore(secrets: secrets)
    for (id, token) in seed { try await store.set(token, for: id) }
    return store
}

@Suite("Serve another local user")
struct ServeLocalUserTests {
    // MARK: (a) following swaps

    @Test("a swap writes the new account's token, replacing the old one")
    func swapWritesNewToken() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let bravo = account("bravo@example.com")
        let store = try await tokens([alpha.id: tokenA, bravo.id: tokenB])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        let first = await server.sync(settings: box.settings(), active: alpha, tokens: store)
        #expect(first == .serving(account: alpha.label, path: box.target.path, group: first.group))
        #expect(box.contents == tokenA)
        #expect(box.mode == 0o640)

        let second = await server.sync(settings: box.settings(), active: bravo, tokens: store)
        #expect(second == .serving(account: bravo.label, path: box.target.path, group: second.group))
        #expect(box.contents == tokenB)
        #expect(box.mode == 0o640)
        #expect(box.strayFiles.isEmpty)
    }

    @Test("an unchanged token is not rewritten on every refresh")
    func unchangedTokenIsNotRewritten() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let files = CountingFileSystem()
        let server = LocalUserServer(files: files, ownership: box.ownership, log: { _ in })

        for _ in 0..<5 { await server.sync(settings: box.settings(), active: alpha, tokens: store) }

        #expect(files.writes == 1)
        #expect(box.contents == tokenA)
    }

    @Test("a file whose permissions drifted is rewritten as 640")
    func repairsMode() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)
        chmod(box.target.path, 0o644)

        await server.sync(settings: box.settings(), active: alpha, tokens: store)

        #expect(box.mode == 0o640)
    }

    @Test("a slower sync for the previous account can't overwrite a newer one")
    func newestSyncWins() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let bravo = account("bravo@example.com")
        let store = try await tokens([alpha.id: tokenA, bravo.id: tokenB])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        async let older = server.sync(settings: box.settings(), active: alpha, tokens: store)
        async let newer = server.sync(settings: box.settings(), active: bravo, tokens: store)
        _ = await (older, newer)
        // Whichever ran last, the file and the status agree with each other.
        let final = await server.sync(settings: box.settings(), active: bravo, tokens: store)

        #expect(box.contents == tokenB)
        #expect(final.message.contains(bravo.label))
    }

    // MARK: (b) an account without a token

    @Test("an active account without a token removes the file, pausing the other user")
    func accountWithoutTokenRemovesFile() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let bare = account("bare@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)
        #expect(box.exists)

        let status = await server.sync(settings: box.settings(), active: bare, tokens: store)

        #expect(status == .pausedNoToken(account: bare.label))
        #expect(!box.exists)
    }

    @Test("no active account removes the file")
    func noActiveAccountRemovesFile() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)

        let status = await server.sync(settings: box.settings(), active: nil, tokens: store)

        #expect(status == .pausedNoActiveAccount)
        #expect(!box.exists)
    }

    @Test("a Codex account is never served, even with a token stored under its id")
    func codexIsNeverServed() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let codex = StoredAccount(provider: .codex, label: "codex@example.com", identity: AccountIdentity())
        let store = try await tokens([codex.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        let status = await server.sync(settings: box.settings(), active: codex, tokens: store)

        #expect(status == .pausedNoActiveAccount)
        #expect(!box.exists)
    }

    @Test("removing an account's token stops serving it on the next sync")
    func removingTokenStopsServing() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let secrets = MemorySecretStore()
        let store = try await tokens([alpha.id: tokenA], secrets: secrets)
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)

        try await store.remove(for: alpha.id)
        let status = await server.sync(settings: box.settings(), active: alpha, tokens: store)

        #expect(status == .pausedNoToken(account: alpha.label))
        #expect(!box.exists)
        #expect(secrets.contents(of: AccountVault.serveTokenServicePrefix + alpha.id.uuidString) == nil)
    }

    // MARK: (c) the setting

    @Test("turning the setting off removes the file")
    func settingOffRemovesFile() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)
        #expect(box.exists)

        let status = await server.sync(settings: box.settings(enabled: false), active: alpha, tokens: store)

        #expect(status == .off)
        #expect(!box.exists)
    }

    @Test("with the setting off, a file vibecom bar didn't write is left alone and nothing is written")
    func settingOffNeverWrites() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try Data("left over".utf8).write(to: box.target)
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let files = CountingFileSystem()
        let server = LocalUserServer(files: files, ownership: box.ownership, log: { _ in })

        let status = await server.sync(settings: box.settings(enabled: false), active: alpha, tokens: store)

        #expect(status == .off)
        #expect(box.contents == "left over")
        #expect(files.writes == 0)
    }

    @Test("the setting is off by default and keeps its path across launches")
    func preferenceDefaults() throws {
        let defaults = Preferences()
        #expect(defaults.serveLocalUserEnabled == false)
        #expect(defaults.serveLocalUserPath == "/Users/Shared/compass-auth/claude.token")

        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"autoSwapEnabled":true}"#.utf8))
        #expect(old.serveLocalUserEnabled == false)
        #expect(old.serveLocalUserPath == ServeSettings.defaultPath)

        var changed = Preferences()
        changed.serveLocalUserEnabled = true
        changed.serveLocalUserPath = "/Users/Shared/other/claude.token"
        let decoded = try JSONDecoder().decode(Preferences.self, from: try JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }

    @Test("moving the file elsewhere removes the copy at the old path")
    func pathChangeRemovesOldFile() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)

        let moved = box.folder.appendingPathComponent("moved.token")
        await server.sync(
            settings: ServeSettings(isEnabled: true, path: moved.path), active: alpha, tokens: store)

        #expect(!box.exists)
        #expect(String(decoding: try Data(contentsOf: moved), as: UTF8.self) == tokenA)
    }

    // MARK: Failing visibly

    @Test("a missing folder fails visibly and creates nothing")
    func missingFolderFailsVisibly() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let missing = box.folder.appendingPathComponent("absent", isDirectory: true)
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        let status = await server.sync(
            settings: ServeSettings(isEnabled: true, path: missing.appendingPathComponent("claude.token").path),
            active: alpha, tokens: store)

        #expect(status.isFailure)
        #expect(status.message.contains("doesn't exist"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("a folder vibecom bar can't write to fails visibly")
    func unwritableFolderFailsVisibly() async throws {
        let box = try Sandbox()
        defer {
            chmod(box.folder.path, 0o750)
            box.cleanUp()
        }
        chmod(box.folder.path, 0o550)
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        let status = await server.sync(settings: box.settings(), active: alpha, tokens: store)

        #expect(status.isFailure)
        #expect(!box.exists)
    }

    @Test("a world-writable folder is refused, since anyone could swap the file")
    func worldWritableFolderIsRefused() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        chmod(box.folder.path, 0o777)
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        let status = await server.sync(settings: box.settings(), active: alpha, tokens: store)

        #expect(status == .failed(ServeFileError.folderWorldWritable(box.folder.path).message))
        #expect(!box.exists)
    }

    @Test("a relative or folder path is refused before anything is touched")
    func badPathsAreRefused() {
        #expect(ServeSettings.problem(with: "") != nil)
        #expect(ServeSettings.problem(with: "claude.token") != nil)
        #expect(ServeSettings.problem(with: "/Users/Shared/compass-auth/") != nil)
        #expect(ServeSettings.problem(with: "/Users/Shared/../etc/claude.token") != nil)
        #expect(ServeSettings.problem(with: "/Users/someone/.zshrc") != nil)
        #expect(ServeSettings.problem(with: "/Users/someone/Documents/notes.txt") != nil)
        #expect(ServeSettings.problem(with: "/Users/Shared/compass-auth/.token") != nil)
        #expect(ServeSettings.problem(with: ServeSettings.defaultPath) == nil)
    }

    // MARK: (d) atomic writes

    @Test(
        "a write that fails partway leaves the previous file whole and no temp file behind",
        arguments: [AtomicFileWriter.Stage.opened, .wrote, .synced])
    func atomicWriteLeavesNoPartialFile(stage: AtomicFileWriter.Stage) throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let writer = AtomicFileWriter()
        try writer.write(Data(tokenA.utf8), to: box.target, mode: 0o640)

        let failing = AtomicFileWriter(fault: { if $0 == stage { throw InjectedFailure() } })
        #expect(throws: InjectedFailure.self) {
            try failing.write(Data(tokenB.utf8), to: box.target, mode: 0o640)
        }

        #expect(box.contents == tokenA)
        #expect(box.mode == 0o640)
        #expect(box.strayFiles.isEmpty)
    }

    @Test("a write that fails before any file existed leaves no file at all")
    func atomicWriteFromNothing() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let failing = AtomicFileWriter(fault: { if $0 == .wrote { throw InjectedFailure() } })

        #expect(throws: InjectedFailure.self) {
            try failing.write(Data(tokenA.utf8), to: box.target, mode: 0o640)
        }

        #expect(!box.exists)
        #expect(box.strayFiles.isEmpty)
    }

    @Test("the mode is exactly 640 whatever the umask")
    func modeIgnoresUmask() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let previous = umask(0o077)
        defer { umask(previous) }

        try AtomicFileWriter().write(Data(tokenA.utf8), to: box.target, mode: 0o640)

        #expect(box.mode == 0o640)
    }

    @Test("a failed write stops serving: the old account's token is removed, never left half-written")
    func failedWriteRemovesStaleToken() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let bravo = account("bravo@example.com")
        let store = try await tokens([alpha.id: tokenA, bravo.id: tokenB])
        let failOnBravo = AtomicFileWriter(fault: { stage in
            if stage == .wrote { throw ServeFileError.io(step: "write", path: "test", code: EIO) }
        })
        let healthy = LocalUserServer(ownership: box.ownership, log: { _ in })
        await healthy.sync(settings: box.settings(), active: alpha, tokens: store)
        let server = LocalUserServer(files: DiskServeFileSystem(writer: failOnBravo), ownership: box.ownership, log: { _ in })

        let status = await server.sync(settings: box.settings(), active: bravo, tokens: store)

        #expect(status.isFailure)
        #expect(!box.exists)
        #expect(box.strayFiles.isEmpty)
    }

    // MARK: (e) the token never reaches a log

    @Test("no log line or on-screen status ever contains a token")
    func tokenNeverLogged() async throws {
        let box = try Sandbox()
        defer {
            chmod(box.folder.path, 0o750)
            box.cleanUp()
        }
        let logURL = box.folder.appendingPathComponent("logs/activity.log")
        let activityLog = ActivityLog(url: logURL)
        let sink = LogSink()
        let alpha = account("alpha@example.com")
        let bravo = account("bravo@example.com")
        let bare = account("bare@example.com")
        let store = try await tokens([alpha.id: tokenA, bravo.id: tokenB])
        let server = LocalUserServer(ownership: box.ownership, log: {
            sink.record($0)
            activityLog.record($0)
        })
        var statuses: [ServeStatus] = []

        // Every state the server can report, including failures.
        statuses.append(await server.sync(settings: box.settings(), active: alpha, tokens: store))
        statuses.append(await server.sync(settings: box.settings(), active: bravo, tokens: store))
        statuses.append(await server.sync(settings: box.settings(), active: bare, tokens: store))
        statuses.append(await server.sync(settings: box.settings(), active: nil, tokens: store))
        statuses.append(await server.sync(settings: box.settings(), active: alpha, tokens: store))
        chmod(box.folder.path, 0o777)
        statuses.append(await server.sync(settings: box.settings(), active: bravo, tokens: store))
        chmod(box.folder.path, 0o750)
        let failing = LocalUserServer(
            files: DiskServeFileSystem(writer: AtomicFileWriter(fault: { _ in throw InjectedFailure() })),
            ownership: box.ownership,
            log: {
                sink.record($0)
                activityLog.record($0)
            })
        statuses.append(await failing.sync(settings: box.settings(), active: alpha, tokens: store))
        statuses.append(await server.sync(settings: box.settings(enabled: false), active: alpha, tokens: store))

        let fileLog = try String(contentsOf: logURL, encoding: .utf8)
        let everything = sink.lines + [fileLog] + statuses.map(\.message)
        #expect(sink.lines.count >= 6)
        for text in everything {
            #expect(!text.contains(tokenA))
            #expect(!text.contains(tokenB))
            #expect(!text.contains("sk-ant-"))
        }
        // The account is named instead.
        #expect(sink.lines.contains { $0.contains(alpha.label) })
        #expect(sink.lines.contains { $0.contains(bravo.label) })
    }

    @Test("hiding account names leaves the label out of the status line")
    func statusHidesAccount() {
        let serving = ServeStatus.serving(account: "alpha@example.com", path: "/p", group: "g")
        let paused = ServeStatus.pausedNoToken(account: "alpha@example.com")
        #expect(serving.message.contains("alpha@example.com"))
        #expect(!serving.message(showingAccount: false).contains("alpha@example.com"))
        #expect(!paused.message(showingAccount: false).contains("alpha@example.com"))
    }

    @Test("a refused paste never echoes the token back")
    func validationMessagesNeverEchoToken() {
        let saved = ClaudeCredentials(accessToken: accessToken, refreshToken: refreshToken, scopes: ["user:profile"])
        let pastes = [refreshToken, accessToken, "sk-ant-api03-secretapikey", "\(tokenA) \(tokenB)", "{\"t\":\"\(tokenA)\"}"]
        for paste in pastes {
            do {
                _ = try ServeToken.validate(paste, savedLogin: saved)
                Issue.record("accepted a paste it should refuse")
            } catch let error as ServeTokenError {
                #expect(!error.message.contains(paste))
                #expect(!error.message.contains("sk-ant-oat01-"))
                #expect(!error.message.contains("sk-ant-ort01-"))
            } catch {
                Issue.record("unexpected error \(type(of: error))")
            }
        }
    }

    // MARK: (f) refresh pairs never reach the other user

    @Test("only the setup-token is written: never the access token, refresh token or Claude's live item")
    func refreshPairNeverWritten() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let secrets = MemorySecretStore([ClaudeKeychain.service: Data(#"{"claudeAiOauth":{}}"#.utf8)])
        let files = MemoryFileStore()
        let vault = AccountVault(secrets: secrets, files: files, directory: URL(fileURLWithPath: "/vault"))
        let pair = ClaudeCredentials(
            accessToken: accessToken, refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(3600),
            scopes: ["user:inference", "user:profile"])
        let alpha = try await vault.add(
            provider: .claude, identity: AccountIdentity(email: "alpha@example.com"), secret: .claude(pair))
        let store = ServeTokenStore(secrets: secrets)
        try await store.set(try ServeToken.validate(tokenA, savedLogin: pair), for: alpha.id)
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })

        let status = await server.sync(settings: box.settings(), active: alpha, tokens: store)

        guard case .serving = status else {
            Issue.record("expected serving, got \(status)")
            return
        }
        let served = try Data(contentsOf: box.target)
        #expect(served == Data(tokenA.utf8))
        let text = String(decoding: served, as: UTF8.self)
        #expect(!text.contains(refreshToken))
        #expect(!text.contains(accessToken))
        #expect(!text.contains("claudeAiOauth"))
        #expect(!text.contains("\n"))
        // Claude Code's live item and the saved OAuth pair are untouched.
        #expect(secrets.writes(of: ClaudeKeychain.service) == 0)
        #expect(try await vault.secret(for: alpha.id) == .claude(pair))
    }

    @Test("a refresh token or the saved login's own tokens can't be stored as a Compass token")
    func refreshTokensAreRefused() throws {
        let saved = ClaudeCredentials(accessToken: accessToken, refreshToken: refreshToken, scopes: ["user:profile"])

        #expect(throws: ServeTokenError.refreshToken) { try ServeToken.validate(refreshToken) }
        #expect(throws: ServeTokenError.sameAsSavedLogin) { try ServeToken.validate(accessToken, savedLogin: saved) }
        #expect(throws: ServeTokenError.notSetupToken) { try ServeToken.validate("sk-ant-api03-key") }
        #expect(throws: ServeTokenError.notSetupToken) { try ServeToken.validate(#"{"claudeAiOauth":{}}"#) }
        #expect(throws: ServeTokenError.containsWhitespace) { try ServeToken.validate("\(tokenA)\n\(refreshToken)") }
        #expect(throws: ServeTokenError.empty) { try ServeToken.validate("  \n") }
        #expect(throws: ServeTokenError.tooLong) {
            try ServeToken.validate(ServeToken.requiredPrefix + String(repeating: "x", count: 2000))
        }
        #expect(try ServeToken.validate("  \(tokenA)\n", savedLogin: saved) == tokenA)
    }

    // MARK: Storage

    @Test("tokens live in their own keychain items, listed without reading any secret")
    func storageIsSeparate() async throws {
        let secrets = MemorySecretStore()
        let alpha = UUID()
        let bravo = UUID()
        let store = ServeTokenStore(secrets: secrets)
        try await store.set(tokenA, for: alpha)
        try await store.set(tokenB, for: bravo)

        #expect(try await store.accountIDs() == [alpha, bravo])
        #expect(secrets.reads(withPrefix: AccountVault.serveTokenServicePrefix) == 0)
        #expect(
            secrets.contents(of: "build.vibecom.bar.v2.servetoken.\(alpha.uuidString)") == Data(tokenA.utf8))
        #expect(secrets.reads(withPrefix: AccountVault.secretServicePrefix) == 0)

        let fresh = ServeTokenStore(secrets: secrets)
        #expect(try await fresh.token(for: alpha) == tokenA)
        #expect(try await fresh.token(for: alpha) == tokenA)
        #expect(secrets.reads(of: AccountVault.serveTokenServicePrefix + alpha.uuidString) == 1)
    }
}

extension ServeStatus {
    fileprivate var group: String? {
        if case .serving(_, _, let group) = self { return group }
        return nil
    }
}

/// Only a file vibecom bar itself wrote, and that is still exactly that file,
/// may ever be replaced or removed. A mistyped path must never cost the user a
/// file, and a symlink must never be followed.
@Suite("Serve another local user: never touches files it didn't write")
struct ServeOwnershipTests {
    enum Scenario: String, CaseIterable, Sendable {
        case settingOff, settingOnWithToken, noToken, noActiveAccount, pathChange, writeFailure
    }

    private static let foreignText = "export SECRET_SETTINGS=keep-me\n"

    /// Runs one scenario against whatever is at the box's target path.
    private func run(
        _ scenario: Scenario, box: Sandbox, server: LocalUserServer, alpha: StoredAccount,
        bare: StoredAccount, store: ServeTokenStore
    ) async -> ServeStatus {
        switch scenario {
        case .settingOff:
            return await server.sync(settings: box.settings(enabled: false), active: alpha, tokens: store)
        case .settingOnWithToken, .writeFailure:
            return await server.sync(settings: box.settings(), active: alpha, tokens: store)
        case .noToken:
            return await server.sync(settings: box.settings(), active: bare, tokens: store)
        case .noActiveAccount:
            return await server.sync(settings: box.settings(), active: nil, tokens: store)
        case .pathChange:
            let elsewhere = box.folder.appendingPathComponent("elsewhere.token")
            return await server.sync(
                settings: ServeSettings(isEnabled: true, path: elsewhere.path), active: alpha, tokens: store)
        }
    }

    private func server(for scenario: Scenario, box: Sandbox) -> LocalUserServer {
        let files =
            scenario == .writeFailure
            ? DiskServeFileSystem(writer: AtomicFileWriter(fault: { _ in throw InjectedFailure() }))
            : DiskServeFileSystem()
        return LocalUserServer(files: files, ownership: box.ownership, log: { _ in })
    }

    @Test("a file someone else put at the path survives every situation", arguments: Scenario.allCases)
    func foreignFileSurvives(_ scenario: Scenario) async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let bare = account("bare@example.com")
        let store = try await tokens([alpha.id: tokenA])
        try Data(Self.foreignText.utf8).write(to: box.target)
        // For a path change, the foreign file is at the old path, which the
        // server has never written: it must not be cleaned up as "ours".
        let server = server(for: scenario, box: box)

        let status = await run(scenario, box: box, server: server, alpha: alpha, bare: bare, store: store)

        #expect(box.contents == Self.foreignText, "\(scenario)")
        if scenario != .settingOff && scenario != .pathChange {
            #expect(status == .foreignFile(path: box.target.path), "\(scenario)")
            #expect(status.isFailure)
        }
        #expect(box.ownership.record?.path != box.target.path)
    }

    @Test("a file swapped in after vibecom bar wrote is no longer treated as its own")
    func replacedFileIsForeign() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: box.ownership, log: { _ in })
        await server.sync(settings: box.settings(), active: alpha, tokens: store)
        #expect(box.contents == tokenA)

        // Someone replaces the file with their own (a new inode at the same path).
        try FileManager.default.removeItem(at: box.target)
        try Data(Self.foreignText.utf8).write(to: box.target)

        let off = await server.sync(settings: box.settings(enabled: false), active: alpha, tokens: store)
        #expect(off == .off)
        #expect(box.contents == Self.foreignText)
        let on = await server.sync(settings: box.settings(), active: alpha, tokens: store)
        #expect(on == .foreignFile(path: box.target.path))
        #expect(box.contents == Self.foreignText)
    }

    @Test("a symlink at the path is never followed, replaced or removed", arguments: Scenario.allCases)
    func symlinkIsNeverTouched(_ scenario: Scenario) async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let victim = box.folder.appendingPathComponent("victim.txt")
        try Data(Self.foreignText.utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: box.target, withDestinationURL: victim)
        let alpha = account("alpha@example.com")
        let bare = account("bare@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = server(for: scenario, box: box)

        let status = await run(scenario, box: box, server: server, alpha: alpha, bare: bare, store: store)

        let link = try FileManager.default.destinationOfSymbolicLink(atPath: box.target.path)
        #expect(link == victim.path, "\(scenario)")
        #expect(String(decoding: try Data(contentsOf: victim), as: UTF8.self) == Self.foreignText, "\(scenario)")
        if scenario != .settingOff && scenario != .pathChange {
            #expect(status == .foreignFile(path: box.target.path), "\(scenario)")
        }
    }

    @Test(
        "vibecom bar's own file is still removed when it must stop serving",
        arguments: [Scenario.settingOff, .noToken, .noActiveAccount, .pathChange, .writeFailure])
    func ownFileIsRemoved(_ scenario: Scenario) async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let bravo = account("bravo@example.com")
        let bare = account("bare@example.com")
        let store = try await tokens([alpha.id: tokenA, bravo.id: tokenB])
        let writer = LocalUserServer(ownership: box.ownership, log: { _ in })
        // Bravo first, so the write-failure case is a switch to alpha that fails.
        await writer.sync(settings: box.settings(), active: bravo, tokens: store)
        #expect(box.contents == tokenB)
        #expect(box.ownership.record?.path == box.target.path)
        // A fresh server, as after a relaunch, relying on the saved record.
        let server = server(for: scenario, box: box)

        _ = await run(scenario, box: box, server: server, alpha: alpha, bare: bare, store: store)

        #expect(!box.exists, "\(scenario)")
        #expect(box.strayFiles.filter { $0 != "elsewhere.token" }.isEmpty, "\(scenario)")
        if scenario == .pathChange {
            let elsewhere = box.folder.appendingPathComponent("elsewhere.token")
            #expect(String(decoding: try Data(contentsOf: elsewhere), as: UTF8.self) == tokenA)
            #expect(box.ownership.record?.path == elsewhere.path)
        } else {
            #expect(box.ownership.record == nil, "\(scenario)")
        }
    }

    @Test("with no record of writing it, nothing at the path is removed, even a token file")
    func noRecordMeansHandsOff() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let writer = LocalUserServer(ownership: box.ownership, log: { _ in })
        await writer.sync(settings: box.settings(), active: alpha, tokens: store)
        // A server that lost its record (or never had one) must not assume.
        let amnesiac = LocalUserServer(ownership: MemoryOwnershipStore(), log: { _ in })

        let status = await amnesiac.sync(settings: box.settings(enabled: false), active: alpha, tokens: store)

        #expect(status == .off)
        #expect(box.contents == tokenA)
    }

    @Test("the saved record holds the path and file metadata, nothing derived from the token")
    func recordHasNoToken() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let files = MemoryFileStore()
        let url = URL(fileURLWithPath: "/support/served-file.json")
        let ownership = FileServeOwnershipStore(files: files, url: url)
        let alpha = account("alpha@example.com")
        let store = try await tokens([alpha.id: tokenA])
        let server = LocalUserServer(ownership: ownership, log: { _ in })

        await server.sync(settings: box.settings(), active: alpha, tokens: store)

        let saved = try #require(files.contents(at: url.path))
        let text = String(decoding: saved, as: UTF8.self)
        #expect(!text.contains("sk-ant-"))
        #expect(ownership.load()?.path == box.target.path)
        // A relaunched server reads it back and can clean up its own file.
        let relaunched = LocalUserServer(ownership: ownership, log: { _ in })
        await relaunched.sync(settings: box.settings(enabled: false), active: alpha, tokens: store)
        #expect(!box.exists)
        #expect(files.contents(at: url.path) == nil)
    }
}

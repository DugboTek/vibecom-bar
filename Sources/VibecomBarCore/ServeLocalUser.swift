import Darwin
import Foundation

// Serving another local macOS user (for example a never-GUI-logged-in `compass`
// account) the Claude login of whichever saved account is active here.
//
// The other user only ever receives a long-lived token minted by
// `claude setup-token`, which it uses through CLAUDE_CODE_OAUTH_TOKEN. It never
// receives a refresh pair or Claude Code's live keychain item: Claude refresh
// tokens rotate, so a renewal on one side would sign the other side out.

// MARK: - The pasted token

public enum ServeTokenError: Error, Equatable, Sendable {
    case empty
    case containsWhitespace
    case tooLong
    /// A refresh token (`sk-ant-ort…`). Handing one over would let the other
    /// user rotate it and sign this Mac out.
    case refreshToken
    /// Not the `sk-ant-oat…` token `claude setup-token` prints.
    case notSetupToken
    /// The saved login's own access or refresh token rather than a separate
    /// setup-token. It expires in hours and belongs to the refresh pair.
    case sameAsSavedLogin

    public var message: String {
        switch self {
        case .empty: "Paste the token `claude setup-token` printed."
        case .containsWhitespace: "That isn't a single token. Paste only the line that starts with sk-ant-oat."
        case .tooLong: "That is far longer than a setup-token. Paste only the token itself."
        case .refreshToken: "That is a refresh token. Run `claude setup-token` and paste the token it prints instead."
        case .notSetupToken: "That doesn't look like a `claude setup-token` token (they start with sk-ant-oat)."
        case .sameAsSavedLogin:
            "That is this account's own short-lived login, not a setup-token. Run `claude setup-token` and paste its token."
        }
    }
}

public enum ServeToken {
    public static let requiredPrefix = "sk-ant-oat"
    static let refreshPrefix = "sk-ant-ort"
    static let maximumLength = 1024

    /// Returns the token to store, or throws why it can't be served. The
    /// account's saved login, when known, is checked so its own access or
    /// refresh token can never end up in the served file.
    public static func validate(_ raw: String, savedLogin: ClaudeCredentials? = nil) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServeTokenError.empty }
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F })
        else { throw ServeTokenError.containsWhitespace }
        guard token.utf8.count <= maximumLength else { throw ServeTokenError.tooLong }
        guard !token.hasPrefix(refreshPrefix) else { throw ServeTokenError.refreshToken }
        guard token.hasPrefix(requiredPrefix) else { throw ServeTokenError.notSetupToken }
        if let savedLogin, token == savedLogin.accessToken || token == savedLogin.refreshToken {
            throw ServeTokenError.sameAsSavedLogin
        }
        return token
    }
}

// MARK: - Storage

extension AccountVault {
    /// One optional setup-token per saved account, kept apart from the OAuth
    /// pair so it is never sent to the usage endpoint (setup-tokens lack the
    /// `user:profile` scope it needs) and never merged into Claude Code's item.
    public static let serveTokenServicePrefix = "build.vibecom.bar.v2.servetoken."
}

/// The setup-tokens saved for serving another local user. They live in the
/// login keychain next to the saved accounts, under their own service name.
public actor ServeTokenStore {
    private let secrets: SecretStore
    private let prefix: String
    private var cache: [UUID: String] = [:]

    public init(secrets: SecretStore, prefix: String = AccountVault.serveTokenServicePrefix) {
        self.secrets = secrets
        self.prefix = prefix
    }

    /// Which accounts have a token, read from the item names alone so no
    /// secret is loaded to draw the account list.
    public func accountIDs() throws -> Set<UUID> {
        Set(try secrets.services(withPrefix: prefix).compactMap { UUID(uuidString: String($0.dropFirst(prefix.count))) })
    }

    public func token(for id: UUID) throws -> String? {
        if let cached = cache[id] { return cached }
        guard let data = try secrets.read(service: prefix + id.uuidString),
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        cache[id] = token
        return token
    }

    /// Stores an already validated token. Call `ServeToken.validate` first.
    public func set(_ token: String, for id: UUID) throws {
        try secrets.write(Data(token.utf8), service: prefix + id.uuidString)
        cache[id] = token
    }

    public func remove(for id: UUID) throws {
        try secrets.delete(service: prefix + id.uuidString)
        cache[id] = nil
    }
}

// MARK: - Settings

public struct ServeSettings: Equatable, Sendable {
    public static let defaultPath = "/Users/Shared/compass-auth/claude.token"

    public var isEnabled: Bool
    public var path: String

    public init(isEnabled: Bool, path: String = ServeSettings.defaultPath) {
        self.isEnabled = isEnabled
        self.path = path
    }

    public init(preferences: Preferences) {
        self.init(isEnabled: preferences.serveLocalUserEnabled, path: preferences.serveLocalUserPath)
    }

    public static let requiredExtension = "token"

    /// Why a path can't be used, or nil when it can. The `.token` ending keeps
    /// a mistyped path from naming a file someone cares about.
    public static func problem(with path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter the full path of the token file." }
        guard trimmed.hasPrefix("/") else { return "Use a full path that starts with /." }
        guard !trimmed.hasSuffix("/") else { return "The path must name a file, not a folder." }
        let name = (trimmed as NSString).lastPathComponent
        guard name != ".", name != ".." else { return "The path must name a file, not a folder." }
        guard !trimmed.split(separator: "/").contains("..") else { return "The path can't contain “..”." }
        guard (name as NSString).pathExtension == requiredExtension, name.count > requiredExtension.count + 1
        else { return "The file name must end in .\(requiredExtension), for example claude.token." }
        return nil
    }
}

// MARK: - The file on disk

public enum ServeFileError: Error, Equatable, Sendable {
    case folderMissing(String)
    case notAFolder(String)
    /// The folder belongs to another user, so who can swap the file is out of our hands.
    case folderNotOwned(String)
    /// Anyone can create files in the folder, so the file could be replaced.
    case folderWorldWritable(String)
    case folderNotWritable(String)
    case invalidPath(String)
    /// errno from the failed step. The path is included; the contents never are.
    case io(step: String, path: String, code: Int32)

    public var message: String {
        switch self {
        case .folderMissing(let path):
            "The folder \(path) doesn't exist. Create it (see Setup) and vibecom bar will write the token there."
        case .notAFolder(let path): "\(path) isn't a folder."
        case .folderNotOwned(let path):
            "\(path) belongs to another user. It must be owned by \(NSUserName()) so only vibecom bar can change the token."
        case .folderWorldWritable(let path):
            "Anyone can write to \(path). Set it to 750 so the token file can't be swapped out."
        case .folderNotWritable(let path): "vibecom bar can't write to \(path). Check its owner and permissions."
        case .invalidPath(let problem): problem
        case .io(let step, let path, let code):
            "Couldn't \(step) \(path): \(String(cString: strerror(code)))."
        }
    }
}

/// The few file operations serving needs, behind a seam so tests can check
/// the policy without touching a real shared folder.
/// Identifies one particular file, so the app can tell the file it wrote from
/// anything else later found at the same path. Derived from metadata only,
/// never from the token.
public struct FileStamp: Codable, Equatable, Sendable {
    public var device: Int64
    public var inode: UInt64
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64

    public init(device: Int64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// What is at a path, without following a symlink there.
public enum ServeFileEntry: Equatable, Sendable {
    case absent
    case regular(FileStamp)
    case symlink
    /// A folder, socket or anything else that isn't a plain file.
    case other
    case unreadable(Int32)
}

public protocol ServeFileSystem: Sendable {
    /// Throws when the folder can't hold the token safely.
    func checkFolder(_ folder: URL) throws
    /// What is at `url`, by lstat: a symlink is reported, never followed.
    func entry(at url: URL) -> ServeFileEntry
    /// The current contents and mode, or nil when there is no regular file.
    func current(_ url: URL) -> (data: Data, mode: mode_t)?
    func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws
    /// Removing a file that is already gone succeeds. Callers only remove a
    /// file they have just confirmed is the one they wrote.
    func remove(_ url: URL) throws
    /// The group the file or folder belongs to, for the status line.
    func groupName(of url: URL) -> String?
}

/// Writes by temp file, fsync, rename: a reader sees the old token or the new
/// one, never part of either, and a failure leaves nothing behind.
public struct AtomicFileWriter: Sendable {
    public enum Stage: Sendable { case opened, wrote, synced }

    /// Lets tests fail the write at a chosen point.
    let fault: (@Sendable (Stage) throws -> Void)?

    public init() { fault = nil }
    init(fault: (@Sendable (Stage) throws -> Void)?) { self.fault = fault }

    public func write(_ data: Data, to url: URL, mode: mode_t) throws {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).vibecom-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw ServeFileError.io(step: "create a file in", path: folder.path, code: errno) }

        var renamed = false
        var closed = false
        defer {
            if !closed { close(fd) }
            if !renamed { unlink(temp.path) }
        }

        // The umask may have taken bits away; set exactly what was asked for.
        guard fchmod(fd, mode) == 0 else { throw ServeFileError.io(step: "set permissions on", path: temp.path, code: errno) }
        try fault?(.opened)

        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ServeFileError.io(step: "write", path: temp.path, code: errno)
                }
                offset += written
            }
        }
        try fault?(.wrote)

        guard fsync(fd) == 0 else { throw ServeFileError.io(step: "flush", path: temp.path, code: errno) }
        try fault?(.synced)

        closed = true
        guard close(fd) == 0 else { throw ServeFileError.io(step: "close", path: temp.path, code: errno) }
        guard rename(temp.path, url.path) == 0 else {
            throw ServeFileError.io(step: "replace", path: url.path, code: errno)
        }
        renamed = true

        // Make the rename itself durable.
        let dirfd = open(folder.path, O_RDONLY | O_CLOEXEC)
        if dirfd >= 0 {
            fsync(dirfd)
            close(dirfd)
        }
    }
}

public struct DiskServeFileSystem: ServeFileSystem {
    let writer: AtomicFileWriter

    public init() { writer = AtomicFileWriter() }
    init(writer: AtomicFileWriter) { self.writer = writer }

    public func checkFolder(_ folder: URL) throws {
        var info = stat()
        guard stat(folder.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw ServeFileError.folderMissing(folder.path) }
            throw ServeFileError.io(step: "check", path: folder.path, code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ServeFileError.notAFolder(folder.path) }
        guard info.st_uid == getuid() else { throw ServeFileError.folderNotOwned(folder.path) }
        guard info.st_mode & S_IWOTH == 0 else { throw ServeFileError.folderWorldWritable(folder.path) }
        guard access(folder.path, W_OK | X_OK) == 0 else { throw ServeFileError.folderNotWritable(folder.path) }
    }

    public func entry(at url: URL) -> ServeFileEntry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .absent : .unreadable(errno)
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFREG:
            return .regular(
                FileStamp(
                    device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                    modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)))
        default: return .other
        }
    }

    public func current(_ url: URL) -> (data: Data, mode: mode_t)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= ServeToken.maximumLength * 4
        else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return (Data(), info.st_mode & 0o7777) }
        return (data, info.st_mode & 0o7777)
    }

    public func writeAtomically(_ data: Data, to url: URL, mode: mode_t) throws {
        try writer.write(data, to: url, mode: mode)
    }

    public func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT || errno == ENOTDIR else {
            throw ServeFileError.io(step: "remove", path: url.path, code: errno)
        }
    }

    public func groupName(of url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, let group = getgrgid(info.st_gid) else { return nil }
        return String(cString: group.pointee.gr_name)
    }
}

// MARK: - Remembering which file is ours

/// The one file this app wrote and may therefore replace or remove.
public struct ServedFileRecord: Codable, Equatable, Sendable {
    public var path: String
    public var stamp: FileStamp

    public init(path: String, stamp: FileStamp) {
        self.path = path
        self.stamp = stamp
    }
}

/// Keeps the record across launches, so a file written before a restart can
/// still be cleaned up, and nothing else ever is.
public protocol ServeOwnershipStore: Sendable {
    func load() -> ServedFileRecord?
    func save(_ record: ServedFileRecord?) throws
}

/// A small JSON file in the app's support folder. It holds the path and file
/// metadata only, nothing derived from the token.
public struct FileServeOwnershipStore: ServeOwnershipStore {
    private let files: FileStore
    private let url: URL

    public init(files: FileStore, url: URL) {
        self.files = files
        self.url = url
    }

    public func load() -> ServedFileRecord? {
        guard let data = (try? files.read(url)) ?? nil else { return nil }
        return try? JSONDecoder().decode(ServedFileRecord.self, from: data)
    }

    public func save(_ record: ServedFileRecord?) throws {
        guard let record else {
            try files.remove(url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try files.write(try encoder.encode(record), to: url)
    }
}

// MARK: - Keeping the file in step with the active account

public enum ServeStatus: Equatable, Sendable {
    /// The setting is off and no file is being served.
    case off
    case serving(account: String, path: String, group: String?)
    /// The file was removed, so the other user pauses until this changes.
    case pausedNoActiveAccount
    case pausedNoToken(account: String)
    /// Something vibecom bar didn't write is at the path. It is left alone.
    case foreignFile(path: String)
    case failed(String)

    public var message: String { message(showingAccount: true) }

    /// With `showingAccount` false the account's name is left out, for when
    /// the user has asked for account names to be hidden on screen.
    public func message(showingAccount: Bool) -> String {
        func name(_ account: String) -> String { showingAccount ? account : "the active account" }
        switch self {
        case .off: return "Off."
        case .serving(let account, let path, let group):
            return "Serving \(name(account)) at \(path)" + (group.map { " to group \($0)" } ?? "") + "."
        case .pausedNoActiveAccount: return "Paused: no saved Claude account is active."
        case .pausedNoToken(let account):
            let subject = showingAccount ? account : "The active account"
            return "Paused: \(subject) has no Compass token. Add one from its menu."
        case .foreignFile(let path):
            return "A file vibecom bar did not write is at \(path); not touching it. Move it away or choose another path."
        case .failed(let message): return message
        }
    }

    public var isFailure: Bool {
        switch self {
        case .failed, .foreignFile: true
        default: false
        }
    }
}

/// Writes the active account's setup-token to the shared file, or removes it.
/// It only ever replaces or removes a file it can prove it wrote itself (same
/// path, same device, inode, size and modification time, and a plain file,
/// not a symlink). Anything else found at the path is left exactly as it is.
/// Nothing but the token is ever written, and the token never reaches the log
/// or the status shown on screen: both name the account only.
public final class LocalUserServer: @unchecked Sendable {
    public static let fileMode: mode_t = 0o640

    private let files: ServeFileSystem
    private let ownership: ServeOwnershipStore
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    /// The file this app last wrote, if it still stands.
    private var record: ServedFileRecord?
    private var lastStatus: ServeStatus?
    /// Syncs can overlap while one waits on the keychain. Only the newest one
    /// may touch the file, so an older active account can't win the race.
    private var issuedTickets = 0
    private var appliedTicket = 0

    public init(
        files: ServeFileSystem = DiskServeFileSystem(), ownership: ServeOwnershipStore,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.files = files
        self.ownership = ownership
        self.log = log
        record = ownership.load()
    }

    /// Brings the file in line with the setting and the active account. Safe to
    /// call on every refresh: an unchanged token is not rewritten, and the log
    /// records changes only.
    @discardableResult
    public func sync(settings: ServeSettings, active: StoredAccount?, tokens: ServeTokenStore) async -> ServeStatus {
        let ticket = lock.withLock {
            issuedTickets += 1
            return issuedTickets
        }
        var token: String?
        var tokenReadFailed = false
        if settings.isEnabled, let active, active.provider == .claude {
            do {
                token = try await tokens.token(for: active.id)
            } catch {
                tokenReadFailed = true
            }
        }
        return lock.withLock {
            if ticket < appliedTicket, let lastStatus { return lastStatus }
            appliedTicket = ticket
            let status: ServeStatus
            if tokenReadFailed, let active {
                // Not knowing the token is not the same as having none, but the
                // safe side is still to stop serving the previous account's.
                status = withdraw(
                    settings.path,
                    otherwise: .failed("Couldn't read \(active.label)'s Compass token from the keychain."))
            } else {
                status = apply(settings: settings, active: active, token: token)
            }
            if status != lastStatus {
                log("Serve another user: \(status.message)")
                lastStatus = status
            }
            return status
        }
    }

    private enum Ownership {
        case nothing
        case ours(FileStamp)
        case foreign
    }

    /// Whether what is at `path` is the file this app wrote.
    private func ownership(of path: String) -> Ownership {
        switch files.entry(at: URL(fileURLWithPath: path)) {
        case .absent: return .nothing
        case .regular(let stamp):
            if let record, record.path == path, record.stamp == stamp { return .ours(stamp) }
            return .foreign
        case .symlink, .other, .unreadable: return .foreign
        }
    }

    private func remember(_ newRecord: ServedFileRecord?) {
        guard newRecord != record else { return }
        record = newRecord
        do {
            try ownership.save(newRecord)
        } catch {
            log("Serve another user: couldn't save which file it wrote (\(type(of: error))).")
        }
    }

    private enum Removal {
        case removed
        case leftForeign
        case failed(String)
    }

    /// Removes the file at `path` only if this app wrote it.
    private func removeIfOurs(_ path: String) -> Removal {
        switch ownership(of: path) {
        case .nothing:
            if record?.path == path { remember(nil) }
            return .removed
        case .foreign:
            // Whatever was ours there is gone; never claim the new file.
            if record?.path == path { remember(nil) }
            return .leftForeign
        case .ours:
            do {
                try files.remove(URL(fileURLWithPath: path))
                remember(nil)
                return .removed
            } catch {
                return .failed(Self.describe(error))
            }
        }
    }

    private func apply(settings: ServeSettings, active: StoredAccount?, token: String?) -> ServeStatus {
        // A file of ours left at a previous path would keep serving a stale
        // account. A file someone else put there is theirs and stays.
        if let previous = record?.path, previous != settings.path {
            if case .failed(let reason) = removeIfOurs(previous) {
                return .failed("Couldn't remove the old token file at \(previous): \(reason)")
            }
        }

        guard settings.isEnabled else {
            // Off: clean up only a file this app wrote; otherwise do nothing.
            if record?.path == settings.path, case .failed(let reason) = removeIfOurs(settings.path) {
                return .failed("Couldn't remove the token file, so the other user may still be served: \(reason)")
            }
            return .off
        }
        if let problem = ServeSettings.problem(with: settings.path) { return .failed(problem) }
        guard let active, active.provider == .claude else {
            return withdraw(settings.path, otherwise: .pausedNoActiveAccount)
        }
        guard let token else {
            return withdraw(settings.path, otherwise: .pausedNoToken(account: active.label))
        }

        let url = URL(fileURLWithPath: settings.path)
        let data = Data(token.utf8)
        do {
            try files.checkFolder(url.deletingLastPathComponent())
            switch ownership(of: settings.path) {
            case .foreign:
                return .foreignFile(path: settings.path)
            case .ours(let stamp):
                if let existing = files.current(url), existing.data == data, existing.mode == Self.fileMode {
                    remember(ServedFileRecord(path: settings.path, stamp: stamp))
                } else {
                    try write(data, to: url)
                }
            case .nothing:
                try write(data, to: url)
            }
            return .serving(account: active.label, path: settings.path, group: files.groupName(of: url))
        } catch {
            // A write that failed must not leave the previous account's token
            // being served as if it were current, but only our own file goes.
            _ = removeIfOurs(settings.path)
            return .failed(Self.describe(error))
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try files.writeAtomically(data, to: url, mode: Self.fileMode)
        guard case .regular(let stamp) = files.entry(at: url) else {
            throw ServeFileError.io(step: "confirm", path: url.path, code: ENOENT)
        }
        remember(ServedFileRecord(path: url.path, stamp: stamp))
    }

    /// Stops serving at `path`: removes our file, or reports a foreign one.
    private func withdraw(_ path: String, otherwise status: ServeStatus) -> ServeStatus {
        guard ServeSettings.problem(with: path) == nil else { return status }
        switch removeIfOurs(path) {
        case .removed: return status
        case .leftForeign: return .foreignFile(path: path)
        case .failed(let reason):
            return .failed("Couldn't remove the token file, so the other user may still be served: \(reason)")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? ServeFileError)?.message ?? "Couldn't update the token file."
    }
}

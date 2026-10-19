import Darwin
import Foundation

/// Every installed copy uses the same file. The kernel releases the lock on
/// exit, including a crash; the file must stay in place so all launches keep
/// locking the same inode.
public final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Returns nil when another process already owns the lock.
    public static func acquire(at url: URL) throws -> SingleInstanceLock? {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return SingleInstanceLock(descriptor: descriptor)
    }

    deinit {
        close(descriptor)
    }
}

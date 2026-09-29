import Foundation

/// A small plain-text record of what auto swap saw and did, so a switch that
/// did not happen can be explained afterwards. It holds account labels,
/// percentages and outcomes only, never tokens.
public final class ActivityLog: @unchecked Sendable {
    public static let maxBytes = 512 * 1024

    public static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VibecomBar", isDirectory: true)
            .appendingPathComponent("activity.log")
    }

    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL = ActivityLog.standardURL, maxBytes: Int = ActivityLog.maxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func record(_ message: String, at date: Date = Date()) {
        let line = "\(Self.timestamp.string(from: date)) \(message)\n"
        lock.withLock {
            let manager = FileManager.default
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // One previous file is kept, so the log never grows without bound.
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int,
                size + line.utf8.count > maxBytes
            {
                let previous = url.appendingPathExtension("1")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                manager.createFile(
                    atPath: url.path, contents: Data(line.utf8),
                    attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

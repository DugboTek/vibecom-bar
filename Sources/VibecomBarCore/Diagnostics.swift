import Foundation

/// Opt-in tracing for the operations that can put a password prompt in front of
/// the user. Set VIBECOM_KEYCHAIN_TRACE to a file path to record them.
public enum Diagnostics {
    public static var tracePath: String? {
        ProcessInfo.processInfo.environment["VIBECOM_KEYCHAIN_TRACE"]
    }

    public static func trace(_ message: String) {
        guard let path = tracePath else { return }
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}

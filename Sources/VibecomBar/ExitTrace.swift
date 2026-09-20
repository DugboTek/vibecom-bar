import Darwin
import Foundation
import VibecomBarCore

/// Diagnostic only: with VIBECOM_KEYCHAIN_TRACE set, records who ended the
/// process, so an unexplained quit can be traced to its caller.
enum ExitTrace {
    static func install() {
        guard Diagnostics.tracePath != nil else { return }
        atexit {
            guard let path = ProcessInfo.processInfo.environment["VIBECOM_KEYCHAIN_TRACE"] else { return }
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
            let count = backtrace(&frames, Int32(frames.count))
            var text = "\n=== process exiting ===\n"
            if let symbols = backtrace_symbols(&frames, count) {
                for index in 0..<Int(count) {
                    if let symbol = symbols[index] { text += String(cString: symbol) + "\n" }
                }
            }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            }
        }
    }
}

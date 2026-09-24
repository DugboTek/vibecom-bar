import Darwin
import Foundation

/// Claude Code uses Apple's `/usr/bin/security` helper for its legacy
/// keychain item. Reads and writes must go through the same helper. A direct
/// SecItem update makes macOS replace Claude's `apple-tool:` partition with
/// Vibecom's team ID, causing every running Claude process to prompt forever.
enum SecurityToolKeychain {
    static let timeout: TimeInterval = 10

    static func read(service: String, account: String) throws -> Data? {
        let result = try captureOutput(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-a", account, "-w", "-s", service])
        if result.status == 44 { return nil }
        guard result.exitedNormally, result.status == 0 else {
            throw StoreError.securityTool(result.status)
        }
        return trimmingLineEndings(result.data)
    }

    struct CommandOutput {
        let data: Data
        let status: Int32
        let exitedNormally: Bool
    }

    /// Drain stdout while the child runs. Waiting for exit first deadlocks once
    /// Claude's credential JSON fills the pipe (16 KB on this macOS version).
    static func captureOutput(
        executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval = 60
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let commands = input.map { _ in Pipe() }
        process.standardInput = commands ?? FileHandle.nullDevice
        try process.run()
        if let commands, let input {
            // Input is capped at one 4 KB command, well inside the pipe buffer,
            // so this write cannot block on a helper that has not read yet.
            try commands.fileHandleForWriting.write(contentsOf: input)
            try commands.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        let descriptor = output.fileHandleForReading.fileDescriptor
        var data = Data()
        var reachedEOF = false

        while !reachedEOF || process.isRunning {
            if Date() >= deadline {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw StoreError.securityToolTimedOut
            }
            if reachedEOF {
                usleep(50_000)
                continue
            }
            var pending = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&pending, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                let code = errno
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw StoreError.securityTool(code)
            }
            guard ready > 0 else { continue }
            if pending.revents & Int16(POLLIN | POLLHUP) != 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    reachedEOF = true
                } else if errno != EINTR {
                    let code = errno
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    throw StoreError.securityTool(code)
                }
            }
        }
        process.waitUntilExit()
        return CommandOutput(
            data: data, status: process.terminationStatus,
            exitedNormally: process.terminationReason == .exit)
    }

    /// Claude Code's own ceiling for one `security -i` command line. The
    /// helper reads commands through a 4 KB buffer and splits anything longer
    /// into separate, broken commands.
    static let interactiveCommandLimit = 4032

    /// Writes exactly the way Claude Code writes its own item, so the item's
    /// `apple-tool:` partition and Claude's ownership never change.
    ///
    /// The secret travels as hex through `-X`. It never goes through the
    /// helper's password prompt, which keeps only the first 128 bytes and, on a
    /// terminal line, cannot accept more than 1,023 bytes at all.
    static func replaceExisting(_ data: Data, service: String, account: String) throws {
        guard !data.isEmpty else { throw StoreError.invalidExternalSecret }

        let invocation = updateInvocation(data, service: service, account: account)
        let result = try captureOutput(
            executable: invocation.arguments[0],
            arguments: Array(invocation.arguments.dropFirst()),
            input: invocation.input,
            timeout: timeout)
        guard result.exitedNormally, result.status == 0 else {
            throw StoreError.securityTool(result.status)
        }

        // A write that reports success but stores different bytes would sign
        // Claude Code out. Confirm the item now holds exactly what was sent.
        guard let stored = try read(service: service, account: account),
            holds(stored, data)
        else {
            throw StoreError.writeNotVerified
        }
    }

    /// `find-generic-password -w` prints a secret it cannot show as text in hex.
    static func holds(_ printed: Data, _ secret: Data) -> Bool {
        printed == trimmingLineEndings(secret) || printed == Data(hex(secret).utf8)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    struct UpdateInvocation: Equatable {
        let arguments: [String]
        /// Commands for `security -i`; nil when everything is in `arguments`.
        let input: Data?
    }

    /// Mirrors Claude Code: the command goes over stdin when it fits, keeping
    /// the secret out of the process list. Larger payloads fall back to
    /// arguments, as Claude Code itself does for the same item.
    static func updateInvocation(_ data: Data, service: String, account: String)
        -> UpdateInvocation
    {
        let hex = hex(data)
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\" "
        if command.utf8.count <= interactiveCommandLimit,
            isSafelyQuotable(account), isSafelyQuotable(service)
        {
            return UpdateInvocation(
                arguments: ["/usr/bin/security", "-i"], input: Data((command + "\n").utf8))
        }
        return UpdateInvocation(
            arguments: [
                "/usr/bin/security", "add-generic-password", "-U", "-a", account,
                "-s", service, "-X", hex,
            ],
            input: nil)
    }

    private static func isSafelyQuotable(_ value: String) -> Bool {
        !value.contains { $0 == "\"" || $0 == "\\" || $0.isNewline }
    }

    private static func trimmingLineEndings(_ data: Data) -> Data {
        var data = data
        while data.last == 10 || data.last == 13 { data.removeLast() }
        return data
    }
}

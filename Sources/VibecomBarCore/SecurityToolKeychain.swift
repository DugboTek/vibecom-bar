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
        var data = result.data
        while data.last == 10 || data.last == 13 { data.removeLast() }
        return data
    }

    struct CommandOutput {
        let data: Data
        let status: Int32
        let exitedNormally: Bool
    }

    /// Drain stdout while the child runs. Waiting for exit first deadlocks once
    /// Claude's credential JSON fills the pipe (16 KB on this macOS version).
    static func captureOutput(
        executable: String, arguments: [String], timeout: TimeInterval = 60
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
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

    static func replaceExisting(_ data: Data, service: String, account: String) throws {
        guard !data.isEmpty else { throw StoreError.invalidExternalSecret }

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw StoreError.securityTool(errno)
        }
        defer { close(master) }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, master)

        let arguments = updateArguments(service: service, account: account)
        let storage = arguments.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var argv = storage + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, nil, &argv, environ)
        close(slave)
        guard spawned == 0 else { throw StoreError.securityTool(spawned) }

        let deadline = Date().addingTimeInterval(timeout)
        var transcript = ""
        var responseCount = 0
        while Date() < deadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0, descriptor.revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 512)
                let count = Darwin.read(master, &buffer, buffer.count)
                if count > 0 {
                    transcript += String(decoding: buffer.prefix(count), as: UTF8.self)
                    let needed = requiredResponses(in: transcript)
                    while responseCount < needed {
                        try write(data + Data([13]), to: master)
                        responseCount += 1
                    }
                }
            }

            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                let exitedNormally = (status & 0x7f) == 0
                let exitCode = (status >> 8) & 0xff
                guard exitedNormally, exitCode == 0 else {
                    throw StoreError.securityTool(exitCode)
                }
                return
            }
        }

        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        throw StoreError.securityToolTimedOut
    }

    static func updateArguments(service: String, account: String) -> [String] {
        [
            "/usr/bin/security", "add-generic-password", "-U", "-a", account,
            "-s", service, "-w",
        ]
    }

    static func requiredResponses(in transcript: String) -> Int {
        let prompts = [
            "password data for new item:",
            "retype password for new item:",
            "password data for item:",
        ]
        return prompts.reduce(0) { count, prompt in
            count + transcript.components(separatedBy: prompt).count - 1
        }
    }

    private static func write(_ data: Data, to file: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.write(file, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { throw StoreError.securityTool(errno) }
            offset += written
        }
    }
}

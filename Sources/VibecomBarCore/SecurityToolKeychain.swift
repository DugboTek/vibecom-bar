import Darwin
import Foundation

/// Claude Code uses Apple's `/usr/bin/security` helper for its legacy
/// keychain item. Reads and writes must go through the same helper. A direct
/// SecItem update makes macOS replace Claude's `apple-tool:` partition with
/// Vibecom's team ID, causing every running Claude process to prompt forever.
enum SecurityToolKeychain {
    static let timeout: TimeInterval = 10

    static func read(service: String, account: String) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-a", account, "-w", "-s", service,
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 44 { return nil }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw StoreError.securityTool(process.terminationStatus)
        }
        var data = output.fileHandleForReading.readDataToEndOfFile()
        while data.last == 10 || data.last == 13 { data.removeLast() }
        return data
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

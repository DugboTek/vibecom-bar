import Foundation
import Testing

@testable import VibecomBarCore

/// Exercises the whole path against the real CLIs and the real providers:
/// capture the signed-in login, renew its token, read usage back.
///
/// Off by default — run with `VIBECOM_LIVE=1 swift test`. Renewed credentials
/// are written straight back to the CLI's own store, so the CLI keeps working.
@Suite(
    "Live providers",
    .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_LIVE"] == "1"),
    .serialized)
struct LiveIntegrationTests {
    /// Credentials can be handed in through the environment, which lets the
    /// live run happen without a keychain prompt aimed at the test binary.
    static func claudeCapture(_ importer: AccountImporter) throws -> CapturedLogin {
        guard let json = ProcessInfo.processInfo.environment["VIBECOM_LIVE_CLAUDE_JSON"] else {
            return try importer.captureActiveClaudeLogin()
        }
        let credentials = try ClaudeCredentials(keychainJSON: Data(json.utf8))
        return CapturedLogin(
            provider: .claude,
            identity: AccountIdentity(
                email: ProcessInfo.processInfo.environment["VIBECOM_LIVE_CLAUDE_EMAIL"],
                plan: credentials.subscriptionType),
            secret: .claude(credentials))
    }

    private func liveSetup() -> (AccountVault, AccountActivator, AccountMonitor, AccountImporter) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibecom-bar-live-\(UUID().uuidString)")
        let environment = CLIEnvironment.live()
        let vault = AccountVault(
            secrets: KeychainSecretStore(), files: DiskFileStore(), directory: directory)
        let activator = AccountActivator(vault: vault, environment: environment)
        let monitor = AccountMonitor(vault: vault, activator: activator, environment: environment)
        return (vault, activator, monitor, AccountImporter(environment: environment))
    }

    @Test(
        "captures the signed-in Claude account and reads its real limits",
        .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_LIVE_CLAUDE_JSON"] == nil))
    func claudeEndToEnd() async throws {
        let (vault, _, monitor, importer) = liveSetup()
        let captured = try Self.claudeCapture(importer)
        let account = try await vault.add(
            provider: .claude, identity: captured.identity, secret: captured.secret)

        let status = await monitor.refresh(account)

        print("claude: \(captured.identity.email ?? "?") plan=\(captured.identity.plan ?? "?")")
        for window in status.snapshot?.windows ?? [] {
            print("  \(window.label): \(UsageFormatter.percent(window.usedFraction)) resets \(window.resetsAt.map { UsageFormatter.countdown(to: $0, from: Date()) } ?? "—")")
        }
        #expect(status.error == nil)
        #expect(status.snapshot?.windows.isEmpty == false)
        #expect(status.isActive)
    }

    @Test(
        "renews the Claude token against Anthropic and reads usage with the new one",
        .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_LIVE_CLAUDE_JSON"] == nil))
    func claudeRefresh() async throws {
        let (vault, _, monitor, importer) = liveSetup()
        let captured = try Self.claudeCapture(importer)
        guard case .claude(let before) = captured.secret else { return }
        let account = try await vault.add(
            provider: .claude, identity: captured.identity, secret: captured.secret)

        // Renews because the stored expiry is forced into the past.
        var stale = before
        stale.expiresAt = Date(timeIntervalSince1970: 1)
        try await vault.update(secret: .claude(stale), for: account.id)
        let status = await monitor.refresh(account)

        guard case .claude(let after) = try await vault.secret(for: account.id) else {
            Issue.record("expected Claude credentials")
            return
        }
        print("claude refresh: token changed=\(after.accessToken != before.accessToken)")
        #expect(status.error == nil)
        #expect(after.accessToken != before.accessToken)
        #expect(after.expiresAt ?? .distantPast > Date())

        // The CLI must end up holding the renewed token, not the rotated-away one.
        if status.isActive {
            let live = try #require(try KeychainSecretStore().read(service: ClaudeKeychain.service))
            #expect(try ClaudeCredentials(keychainJSON: live).accessToken == after.accessToken)
        }
    }

    @Test("captures the signed-in Codex account and reads its real limits")
    func codexEndToEnd() async throws {
        let (vault, _, monitor, importer) = liveSetup()
        let captured = try importer.captureActiveCodexLogin()
        let account = try await vault.add(
            provider: .codex, identity: captured.identity, secret: captured.secret)

        let status = await monitor.refresh(account)

        print("codex: \(captured.identity.email ?? "?") plan=\(captured.identity.plan ?? "?")")
        for window in status.snapshot?.windows ?? [] {
            print("  \(window.label): \(UsageFormatter.percent(window.usedFraction)) resets \(window.resetsAt.map { UsageFormatter.countdown(to: $0, from: Date()) } ?? "—")")
        }
        #expect(status.error == nil)
        #expect(status.snapshot?.windows.isEmpty == false)
    }

    @Test("leaves the Codex CLI able to read its own auth file after a renewal")
    func codexAuthFileStaysValid() async throws {
        let (vault, _, monitor, importer) = liveSetup()
        let captured = try importer.captureActiveCodexLogin()
        let account = try await vault.add(
            provider: .codex, identity: captured.identity, secret: captured.secret)

        _ = await monitor.refresh(account)

        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        let onDisk = try #require(try DiskFileStore().read(path))
        let credentials = try CodexCredentials(authFileJSON: onDisk)
        #expect(!credentials.accessToken.isEmpty)
        #expect(!credentials.refreshToken.isEmpty)
    }

    /// Read-only: no token is rotated, so nothing here can cost a sign-in.
    @Test(
        "reads real Claude limits with credentials supplied directly",
        .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_LIVE_CLAUDE_JSON"] != nil))
    func claudeReadOnly() async throws {
        let json = try #require(ProcessInfo.processInfo.environment["VIBECOM_LIVE_CLAUDE_JSON"])
        let credentials = try ClaudeCredentials(keychainJSON: Data(json.utf8))

        let snapshot = try await UsageService().fetchUsage(claude: credentials, now: Date())

        print("claude plan=\(credentials.subscriptionType ?? "?") tier=\(credentials.rateLimitTier ?? "?")")
        for window in snapshot.windows {
            let resets = window.resetsAt.map { UsageFormatter.resetDescription(at: $0, from: Date()) } ?? "—"
            print("  \(window.label): \(UsageFormatter.percent(window.usedFraction)) · resets \(resets)")
        }
        #expect(!snapshot.windows.isEmpty)
        #expect(snapshot.windows.contains { $0.kind == .session })
    }
}

/// Rotates a real Codex token against OpenAI and checks the CLI is left with
/// working credentials. Opt in separately: it consumes the refresh token.
@Suite(
    "Live token renewal",
    .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_LIVE_RENEW"] == "1"),
    .serialized)
struct LiveRenewalTests {
    @Test("renews the Codex token and leaves the CLI able to use it")
    func renewsCodex() async throws {
        let environment = CLIEnvironment.live()
        let vault = AccountVault(
            secrets: KeychainSecretStore(), files: DiskFileStore(),
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vibecom-bar-renew-\(UUID().uuidString)"))
        let activator = AccountActivator(vault: vault, environment: environment)
        let monitor = AccountMonitor(vault: vault, activator: activator, environment: environment)
        let importer = AccountImporter(environment: environment)

        let captured = try importer.captureActiveCodexLogin()
        guard case .codex(let before) = captured.secret else { return }
        let account = try await vault.add(
            provider: .codex, identity: captured.identity, secret: captured.secret)

        try await monitor.renewCredentials(for: account)

        guard case .codex(let after) = try await vault.secret(for: account.id) else {
            Issue.record("expected Codex credentials")
            return
        }
        #expect(after.accessToken != before.accessToken)
        print("codex renewal: access rotated=\(after.accessToken != before.accessToken) refresh rotated=\(after.refreshToken != before.refreshToken)")

        // What the CLI will read next must be the renewed credentials.
        let onDisk = try #require(try DiskFileStore().read(environment.codexAuthFile))
        let live = try CodexCredentials(authFileJSON: onDisk)
        #expect(live.accessToken == after.accessToken)
        #expect(live.refreshToken == after.refreshToken)

        // And they must actually work.
        let snapshot = try await UsageService().fetchUsage(codex: live, now: Date())
        #expect(!snapshot.windows.isEmpty)
        print("codex after renewal: \(snapshot.email ?? "?") \(snapshot.windows.map { "\($0.label) \(UsageFormatter.percent($0.usedFraction))" }.joined(separator: ", "))")
    }
}

@Suite("Live token ledger", .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_LIVE"] == "1"))
struct LiveTokenLedgerTests {
    @Test("reads this Mac's real transcripts quickly enough to run on a timer")
    func readsRealTranscripts() async {
        let ledger = TokenLedger()
        let clock = ContinuousClock()

        var summary = TokenSummary()
        let first = await clock.measure { summary = await ledger.update() }
        let second = await clock.measure { summary = await ledger.update() }

        print("ledger first scan \(first), incremental \(second)")
        print("today \(UsageFormatter.tokens(summary.today.tokens)) \(UsageFormatter.dollars(summary.today.cost)) · week \(UsageFormatter.tokens(summary.week.tokens)) \(UsageFormatter.dollars(summary.week.cost)) · \(summary.tokensPerMinute)/min")
        for model in summary.topModels.prefix(4) {
            print("  \(model.model): \(UsageFormatter.tokens(model.totals.tokens))")
        }
        #expect(second < .seconds(2))
    }
}

/// Sums the same transcript files vibecom's CLI sums, file by file, so the two
/// implementations can be compared on real data.
@Suite("Live parity with vibecom", .enabled(if: ProcessInfo.processInfo.environment["VIBECOM_PARITY_CLAUDE"] != nil))
struct LiveParityTests {
    @Test("counts the same tokens as vibecom's CLI for the same files")
    func matchesVibecom() throws {
        let environment = ProcessInfo.processInfo.environment
        for (tool, variable) in [(CodingTool.claudeCode, "VIBECOM_PARITY_CLAUDE"), (.codex, "VIBECOM_PARITY_CODEX")] {
            guard let list = environment[variable] else { continue }
            var total = 0
            for path in try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n") {
                let data = try Data(contentsOf: URL(fileURLWithPath: String(path)), options: .alwaysMapped)
                var messages: [String: TokenEvent] = [:]
                var codex = CodexTranscript()
                for line in data.split(separator: 0x0A) {
                    switch tool {
                    case .claudeCode:
                        guard let (key, event) = ClaudeTranscript.parse(Data(line)) else { continue }
                        if let existing = messages[key], existing.usage.outputTokens > event.usage.outputTokens { continue }
                        messages[key] = event
                    case .codex:
                        if let event = codex.consume(Data(line)) { total += event.usage.total }
                    }
                }
                total += messages.values.reduce(0) { $0 + $1.usage.total }
            }
            print("swift \(tool.rawValue): \(total)")
        }
    }
}

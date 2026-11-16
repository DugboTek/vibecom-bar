import SwiftUI
import VibecomBarCore

struct AccountsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TokensCard(
                summary: model.tokens, ticker: model.ticker, isCounting: model.isCountingTokens,
                standing: model.vibecomStanding)

            if let failure = model.switchFailure {
                SwitchFailureBanner(message: failure) { model.dismissSwitchFailure() }
            }

            if model.hasAccounts {
                ForEach(Provider.allCases) { provider in
                    let statuses = model.statuses(for: provider)
                    if !statuses.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                ProviderMark(provider: provider, size: 17)
                                Text(provider.displayName)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(statuses.count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 3)
                            Card {
                                ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                                    if index > 0 { Divider().padding(.leading, 40) }
                                    AccountRow(status: status, model: model)
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyState(model: model)
            }
        }
    }
}

private struct AccountRow: View {
    @Environment(\.brand) private var brand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: AccountStatus
    let model: AppModel

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isEditingServeToken = false
    @State private var draftServeToken = ""
    @State private var serveTokenError: String?
    @State private var isSavingServeToken = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            UsageRing(fraction: status.headline?.usedFraction, isActive: status.isActive)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                titleRow
                subtitle
                if let error = status.error, error == .needsLogin || error == .cannotReadUsage {
                    signInPrompt(error)
                }
                if isEditingServeToken {
                    serveTokenEditor
                }
                VStack(spacing: 2) {
                    ForEach(status.snapshot?.windows ?? []) { window in
                        WindowRow(window: window)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovering ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { hovering in
            if reduceMotion {
                isHovering = hovering
            } else {
                withAnimation(Motion.feedback) { isHovering = hovering }
            }
        }
        .contextMenu { menu }
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit {
                        isRenaming = false
                        Task { await model.rename(status, to: draftName) }
                    }
                    .onExitCommand { isRenaming = false }
            } else {
                AccountIdentityText(
                    value: status.account.label,
                    isBlurred: model.preferences.blurAccountNames)
                    .font(.system(size: 12, weight: .semibold))
            }

            Spacer(minLength: 4)

            if model.hasServeToken(status) {
                Pill(
                    text: "Compass", systemImage: isServed ? "person.2.fill" : "person.2",
                    tint: isServed ? Color(brand.accent) : .secondary
                )
                .help(
                    isServed
                        ? "Another user on this Mac is signed in with this account's Compass token."
                        : "Has a Compass token. Another user on this Mac gets it while this account is active and Serve Another User is on.")
            }

            if let resets = status.snapshot?.resetCredits, resets.available > 0 {
                Pill(text: resets.summary, systemImage: "arrow.counterclockwise", tint: Color(brand.accent))
                    .help(
                        resets.usableNow > 0
                            ? "\(resets.summary) available — you can reset a spent limit now."
                            : "\(resets.summary) available — usable once this account hits a limit.")
            }

            if status.isActive {
                HStack(spacing: 4) {
                    Circle().fill(Color(brand.signal)).frame(width: 5, height: 5)
                    Text("Active")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            } else if model.switchingAccountID == status.id {
                ProgressView()
                    .controlSize(.mini)
                    .help("Switching \(status.account.provider.displayName) to this account…")
            } else {
                Button("Use") { Task { await model.activate(status) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(model.switchingAccountID != nil)
                    .help("Make this the account \(status.account.provider.displayName) uses next")
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        let parts = [planName, UsageFormatter.resetLine(for: status, now: Date()), staleNote].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(isSpent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        } else if status.snapshot == nil, status.error == nil {
            Text("Reading usage…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var isServed: Bool {
        if case .serving = model.serveStatus { return status.isActive }
        return false
    }

    /// Pasting a `claude setup-token` token, inline like renaming. A secure
    /// field, so the token is never shown on screen.
    private var serveTokenEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Compass token")
                .font(.system(size: 11, weight: .medium))
            Text("Run `claude setup-token` signed in as this account and paste the token it prints. Only this token is ever given to the other user.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("sk-ant-oat…", text: $draftServeToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(saveServeToken)
                    .onExitCommand(perform: closeServeTokenEditor)
                Button("Save", action: saveServeToken)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(draftServeToken.isEmpty || isSavingServeToken)
                Button("Cancel", action: closeServeTokenEditor)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            if let serveTokenError {
                Label(serveTokenError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    private func saveServeToken() {
        guard !isSavingServeToken else { return }
        isSavingServeToken = true
        let pasted = draftServeToken
        Task {
            let problem = await model.setServeToken(pasted, for: status)
            isSavingServeToken = false
            if let problem {
                serveTokenError = problem
            } else {
                closeServeTokenEditor()
            }
        }
    }

    private func closeServeTokenEditor() {
        isEditingServeToken = false
        draftServeToken = ""
        serveTokenError = nil
    }

    private var isSpent: Bool { status.snapshot?.windows.contains(where: \.isExhausted) ?? false }

    private var staleNote: String? {
        guard let error = status.error,
            error == .rateLimited || error == .unreachable || error == .awaitingCLIRenewal
        else { return nil }
        return error.message
    }

    private var planName: String? {
        guard let plan = status.account.identity.plan ?? status.snapshot?.plan else { return nil }
        let cleaned =
            plan
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
    }

    private func signInPrompt(_ error: AccountError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(error.message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Sign in…") {
                model.startGuidedSignIn(for: status.account.provider)
                model.page = .addAccount
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !status.isActive {
            Button("Use This Account") { Task { await model.activate(status) } }
                .disabled(model.switchingAccountID != nil)
        }
        Button("Rename…") {
            draftName = status.account.label
            isRenaming = true
        }
        if status.account.provider == .claude {
            Divider()
            Button(model.hasServeToken(status) ? "Replace Compass Token…" : "Set Compass Token…") {
                draftServeToken = ""
                serveTokenError = nil
                isEditingServeToken = true
            }
            if model.hasServeToken(status) {
                Button("Remove Compass Token") { Task { await model.removeServeToken(for: status) } }
            }
        }
        Divider()
        Button("Remove", role: .destructive) { Task { await model.remove(status) } }
    }
}

/// Why the last switch did not happen, kept on screen until dismissed.
private struct SwitchFailureBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One limit: its name, how much is spent, and when it comes back.
private struct WindowRow: View {
    @Environment(\.brand) private var brand
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)

            UsageBar(fraction: window.usedFraction)

            Text(UsageFormatter.percent(window.usedFraction))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(
                    window.usedFraction >= 0.8
                        ? Style.usageColor(window.usedFraction, accent: Color(brand.accent))
                        : .primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: UsageFormatter.percentColumnWidth, alignment: .trailing)

            Group {
                if let resetsAt = window.resetsAt {
                    Text(UsageFormatter.countdown(to: resetsAt, from: Date()))
                        .help("Resets \(UsageFormatter.resetDescription(at: resetsAt, from: Date()))")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(window.label), \(UsageFormatter.percent(window.usedFraction)) used"
                + (window.resetsAt.map { ", resets in \(UsageFormatter.countdown(to: $0, from: Date()))" } ?? "")
        )
    }
}

private struct EmptyState: View {
    let model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Add your accounts")
                    .font(.system(size: 13, weight: .semibold))
                Text(
                    "Add each Claude and Codex account once. vibecom keeps their logins in your keychain and shows every limit here."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("Add Account…") { model.page = .addAccount }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

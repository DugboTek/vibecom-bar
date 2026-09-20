import SwiftUI
import VibecomBarCore

struct AccountsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TokensCard(summary: model.tokens, ticker: model.ticker, isCounting: model.isCountingTokens)

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

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            UsageRing(fraction: status.headline?.usedFraction, isActive: status.isActive)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                titleRow
                subtitle
                if let error = status.error, error == .needsLogin || error == .cannotReadUsage {
                    signInPrompt(error)
                }
                VStack(spacing: 4) {
                    ForEach(status.snapshot?.windows ?? []) { window in
                        WindowRow(window: window)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
                    .font(.system(size: 13, weight: .semibold))
            }

            Spacer(minLength: 4)

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
            } else {
                Button("Use") { Task { await model.activate(status) } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
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

    private var isSpent: Bool { status.snapshot?.windows.contains(where: \.isExhausted) ?? false }

    private var staleNote: String? {
        guard let error = status.error, error == .rateLimited || error == .unreachable else { return nil }
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
        }
        Button("Rename…") {
            draftName = status.account.label
            isRenaming = true
        }
        Divider()
        Button("Remove", role: .destructive) { Task { await model.remove(status) } }
    }
}

/// One limit: its name, how much is spent, and when it comes back.
private struct WindowRow: View {
    @Environment(\.brand) private var brand
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 7) {
            Text(window.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 105, alignment: .leading)
                .lineLimit(1)

            UsageBar(fraction: window.usedFraction)

            Text(UsageFormatter.percent(window.usedFraction))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(
                    window.usedFraction >= 0.8
                        ? Style.usageColor(window.usedFraction, accent: Color(brand.accent))
                        : .primary
                )
                .frame(width: 32, alignment: .trailing)

            Group {
                if let resetsAt = window.resetsAt {
                    Text(UsageFormatter.countdown(to: resetsAt, from: Date()))
                        .help("Resets \(UsageFormatter.resetDescription(at: resetsAt, from: Date()))")
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 42, alignment: .trailing)
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

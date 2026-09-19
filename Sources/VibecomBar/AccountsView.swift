import SwiftUI
import VibecomBarCore

struct AccountsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TokensCard(summary: model.tokens, ticker: model.ticker, isCounting: model.isCountingTokens)

            if model.hasAccounts {
                ForEach(Provider.allCases) { provider in
                    let statuses = model.statuses(for: provider)
                    if !statuses.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(
                                text: provider.displayName,
                                trailing: statuses.count == 1 ? "1 account" : "\(statuses.count) accounts")
                            Card {
                                ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                                    if index > 0 { Divider().padding(.leading, 44) }
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
    let status: AccountStatus
    let model: AppModel

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UsageRing(fraction: status.headline?.usedFraction, isActive: status.isActive)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 7) {
                titleRow
                subtitle
                if let error = status.error, error == .needsLogin || error == .cannotReadUsage {
                    signInPrompt(error)
                }
                VStack(spacing: 5) {
                    ForEach(status.snapshot?.windows ?? []) { window in
                        WindowRow(window: window)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isHovering ? 0.03 : 0))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
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
                Text(status.account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                Text("In use")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") { Task { await model.activate(status) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
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
                .frame(width: 34, alignment: .trailing)

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
            .frame(width: 44, alignment: .trailing)
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

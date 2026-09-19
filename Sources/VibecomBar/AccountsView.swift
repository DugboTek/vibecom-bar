import SwiftUI
import VibecomBarCore

struct AccountsView: View {
    @Environment(\.brand) private var brand
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.hasAccounts {
                ForEach(Provider.allCases) { provider in
                    let statuses = model.statuses(for: provider)
                    if !statuses.isEmpty {
                        ProviderSection(provider: provider, statuses: statuses, model: model)
                    }
                }
            } else {
                EmptyState(model: model)
            }
        }
    }
}

private struct ProviderSection: View {
    @Environment(\.brand) private var brand
    let provider: Provider
    let statuses: [AccountStatus]
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(brand.muted))
                Rectangle()
                    .fill(Color(brand.line))
                    .frame(height: 1)
            }

            ForEach(statuses) { status in
                AccountRow(status: status, model: model)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(status.isActive ? Color(brand.signal) : Color(brand.foreground).opacity(0.18))
                    .frame(width: 7, height: 7)

                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            isRenaming = false
                            Task { await model.rename(status, to: draftName) }
                        }
                } else {
                    Text(status.account.label)
                        .font(.system(size: 12, weight: status.isActive ? .semibold : .regular))
                        .foregroundStyle(Color(brand.foreground))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let plan = status.account.identity.plan ?? status.snapshot?.plan {
                    Chip(text: Self.planName(plan), tint: status.isActive ? brand.accent : nil)
                }

                Spacer(minLength: 4)

                if status.isActive {
                    Text("in use")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(brand.signal))
                } else if isHovering {
                    BarButton(title: "Switch", systemImage: "arrow.left.arrow.right", prominent: true) {
                        Task { await model.activate(status) }
                    }
                }
            }

            if let error = status.error, error == .needsLogin || error == .cannotReadUsage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(brand.negative))
                    Text(error.message)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(brand.muted))
                    BarButton(title: "Sign in") {
                        model.startGuidedSignIn(for: status.account.provider)
                        model.page = .addAccount
                    }
                }
            }

            ForEach(status.snapshot?.windows ?? []) { window in
                WindowRow(window: window)
            }

            if status.snapshot == nil, status.error == nil {
                Text("Reading usage…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(brand.muted))
            } else if let error = status.error, error == .rateLimited || error == .unreachable {
                Text(error.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(brand.muted))
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(brand.foreground).opacity(isHovering ? 0.055 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            status.isActive ? Color(brand.accent).opacity(0.4) : Color(brand.line),
                            lineWidth: 1))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…") {
                draftName = status.account.label
                isRenaming = true
            }
            Button("Switch to this account") { Task { await model.activate(status) } }
            Divider()
            Button("Remove", role: .destructive) { Task { await model.remove(status) } }
        }
    }

    private static func planName(_ plan: String) -> String {
        plan
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }
}

private struct WindowRow: View {
    @Environment(\.brand) private var brand
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(brand.muted))
                Spacer(minLength: 4)
                if let resetsAt = window.resetsAt {
                    Text(UsageFormatter.countdown(to: resetsAt, from: Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(Color(brand.muted))
                        .help("Resets \(UsageFormatter.resetDescription(at: resetsAt, from: Date()))")
                }
                Text(UsageFormatter.percent(window.usedFraction))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(brand.color(forUsage: window.usedFraction)))
            }
            UsageBar(fraction: window.usedFraction)
        }
    }
}

private struct EmptyState: View {
    @Environment(\.brand) private var brand
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No accounts yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(brand.foreground))
            Text(
                "Add each Claude and Codex account once. vibecom bar keeps their logins and shows every limit here."
            )
            .font(.system(size: 11))
            .foregroundStyle(Color(brand.muted))
            .fixedSize(horizontal: false, vertical: true)

            BarButton(title: "Add an account", systemImage: "plus", prominent: true) {
                model.page = .addAccount
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(brand.foreground).opacity(0.04))
        )
    }
}

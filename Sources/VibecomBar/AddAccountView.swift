import SwiftUI
import VibecomBarCore

struct AddAccountView: View {
    @Environment(\.brand) private var brand
    let model: AppModel

    @State private var provider: Provider = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $provider) {
                ForEach(Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.signInState {
            case .waiting(let waitingFor):
                waitingCard(for: waitingFor)
            default:
                optionsCard
            }

            if case .failed(let message) = model.signInState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(brand.negative))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            option(
                title: "Sign in to another account",
                detail:
                    "Opens Terminal and signs in under its own config folder, so the account you are using now stays signed in.",
                action: "Start sign-in",
                prominent: true
            ) {
                model.startGuidedSignIn(for: provider)
            }

            Divider().overlay(Color(brand.line))

            option(
                title: "Capture the account already signed in",
                detail: "Saves whoever \(provider.displayName) is signed in as right now.",
                action: "Capture",
                prominent: false
            ) {
                Task { await model.captureActiveLogin(for: provider) }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(brand.foreground).opacity(0.04))
        )
    }

    private func option(
        title: String, detail: String, action: String, prominent: Bool, run: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(brand.foreground))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color(brand.muted))
                .fixedSize(horizontal: false, vertical: true)
            BarButton(title: action, prominent: prominent, action: run)
                .padding(.top, 1)
        }
    }

    private func waitingCard(for provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Waiting for the \(provider.displayName) sign-in to finish…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(brand.foreground))
            }
            Text(
                provider == .claude
                    ? "Terminal is open. Finish the login there — vibecom bar saves the account as soon as it appears."
                    : "Terminal is open. Approve the login in your browser — vibecom bar saves the account as soon as it appears."
            )
            .font(.system(size: 11))
            .foregroundStyle(Color(brand.muted))
            .fixedSize(horizontal: false, vertical: true)

            BarButton(title: "Cancel") { model.cancelSignIn() }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(brand.accent).opacity(0.1))
        )
    }
}

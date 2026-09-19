import SwiftUI
import VibecomBarCore

struct AddAccountView: View {
    let model: AppModel

    @State private var provider: Provider = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if case .waiting(let waitingFor) = model.signInState {
                waiting(for: waitingFor)
            } else {
                options
            }

            if case .failed(let message) = model.signInState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var options: some View {
        Card {
            option(
                symbol: "person.badge.plus",
                title: "Sign in to another account",
                detail: "Opens Terminal and signs in separately, so the account you're using now stays signed in."
            ) {
                Button("Sign In…") { model.startGuidedSignIn(for: provider) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Divider().padding(.leading, 40)
            option(
                symbol: "square.and.arrow.down",
                title: "Add the signed-in account",
                detail: "Saves whoever \(provider.displayName) is signed in as right now."
            ) {
                Button("Add") { Task { await model.captureActiveLogin(for: provider) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func option<Action: View>(
        symbol: String, title: String, detail: String, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func waiting(for provider: Provider) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(provider.displayName) sign-in…")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(
                    provider == .claude
                        ? "Finish the login in Terminal and your browser. The account appears here as soon as it's done."
                        : "Approve the login in your browser. The account appears here as soon as it's done."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("Cancel") { model.cancelSignIn() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

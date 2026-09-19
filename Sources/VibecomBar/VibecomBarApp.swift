import SwiftUI
import VibecomBarCore

@main
struct VibecomBarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cloud.fill")
                let text = model.menuBarText
                if !text.isEmpty {
                    Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel

    private var brand: BrandPalette { colorScheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ScrollView {
                Group {
                    switch model.page {
                    case .accounts: AccountsView(model: model)
                    case .addAccount: AddAccountView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(maxHeight: 460)
            .scrollBounceBehavior(.basedOnSize)

            footer
        }
        .padding(13)
        .frame(width: 352)
        .background(Color(brand.canvas))
        .environment(\.brand, brand)
    }

    private var header: some View {
        HStack {
            if model.page == .accounts {
                Wordmark()
            } else {
                BarButton(title: "Back", systemImage: "chevron.left") {
                    model.cancelSignIn()
                    model.page = .accounts
                }
                Text(model.page == .addAccount ? "Add account" : "Settings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(brand.foreground))
            }

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(brand.muted))
                }
                .buttonStyle(.plain)
                .help("Check usage now")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let lastUpdated = model.lastUpdated, model.page == .accounts {
                Text("Updated \(UsageFormatter.relative(lastUpdated, from: Date()))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(brand.muted))
            }

            Spacer()

            if model.page == .accounts {
                BarButton(title: "Add", systemImage: "plus") { model.page = .addAccount }
                BarButton(title: "Settings", systemImage: "gearshape") { model.page = .settings }
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(brand.muted))
            }
            .buttonStyle(.plain)
            .help("Quit vibecom bar")
        }
        .environment(\.brand, brand)
    }
}

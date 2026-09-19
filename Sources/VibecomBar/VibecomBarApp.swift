import SwiftUI
import VibecomBarCore

@main
struct VibecomBarApp: App {
    @State private var model = AppModel()

    init() {
        Snapshot.runIfRequested()
    }

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
            .onAppear {
                // A snapshot run renders sample accounts and must never read the keychain.
                if !Snapshot.isRequested { model.start() }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppModel

    /// A scroll view has no height of its own, and a menu bar window sizes to
    /// its content, so the page is measured and the scroll view given that height.
    @State private var contentHeight: CGFloat = 120
    static let maxContentHeight: CGFloat = 560

    private var brand: BrandPalette { colorScheme == .dark ? .dark : .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            ScrollView {
                Group {
                    switch model.page {
                    case .accounts: AccountsView(model: model)
                    case .addAccount: AddAccountView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(contentHeight, Self.maxContentHeight))
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(ContentHeightKey.self) { height in
                if height > 0 { contentHeight = height }
            }

            Divider().padding(.top, 8)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 372)
        .tint(Color(brand.accent))
        .environment(\.brand, brand)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.page == .accounts {
                Wordmark()
            } else {
                Button {
                    model.cancelSignIn()
                    model.page = .accounts
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(model.page == .addAccount ? "Add Account" : "Settings")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("Back to accounts")
            }

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
            } else {
                IconButton(systemImage: "arrow.clockwise", help: "Check limits now") {
                    Task { await model.refresh() }
                }
            }
            if model.page == .accounts {
                IconButton(systemImage: "gearshape", help: "Settings") { model.page = .settings }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let lastUpdated = model.lastUpdated {
                Text("Limits updated \(UsageFormatter.relative(lastUpdated, from: Date()))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.page == .accounts {
                Button("Add Account…") { model.page = .addAccount }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            IconButton(systemImage: "power", help: "Quit vibecom") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

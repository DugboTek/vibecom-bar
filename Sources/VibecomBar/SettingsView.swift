import ServiceManagement
import SwiftUI
import VibecomBarCore

struct SettingsView: View {
    @Environment(\.brand) private var brand
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            section("Menu bar") {
                Picker("Show", selection: $model.preferences.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))
            }

            section("Check usage every") {
                HStack(spacing: 8) {
                    Slider(
                        value: $model.preferences.refreshInterval,
                        in: Preferences.minimumRefreshInterval...Preferences.maximumRefreshInterval,
                        step: 60)
                    Text(intervalLabel)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color(brand.muted))
                        .frame(width: 58, alignment: .trailing)
                }
            }

            section("Alerts") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Warn at 80% and 95%",
                        isOn: Binding(
                            get: { !model.preferences.alertThresholds.isEmpty },
                            set: { model.preferences.alertThresholds = $0 ? [0.8, 0.95] : [] })
                    )
                    Toggle("Say when a limit resets", isOn: $model.preferences.notifyOnReset)
                    Toggle("Start at login", isOn: launchAtLogin)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }

            HStack {
                BarButton(title: "Add account", systemImage: "plus") { model.page = .addAccount }
                Spacer()
                Text("Right-click an account to rename or remove it.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(brand.muted))
            }
        }
    }

    private var intervalLabel: String {
        let minutes = Int(model.preferences.refreshInterval / 60)
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { model.preferences.launchAtLogin },
            set: { enabled in
                model.preferences.launchAtLogin = enabled
                // Only a bundled app can register; a `swift run` build cannot.
                guard Bundle.main.bundleIdentifier != nil else { return }
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    model.preferences.launchAtLogin = !enabled
                }
            })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(brand.muted))
            content()
        }
    }
}

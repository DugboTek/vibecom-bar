import ServiceManagement
import SwiftUI
import VibecomBarCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Menu Bar") {
                row("Show") {
                    Picker("Show", selection: $model.preferences.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider().padding(.leading, 12)
                row("Check limits every") {
                    Picker("Check limits every", selection: $model.preferences.refreshInterval) {
                        ForEach([60.0, 120, 300, 600, 900, 1800], id: \.self) { seconds in
                            Text(seconds < 3600 ? "\(Int(seconds / 60)) min" : "1 hour").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            group("Privacy") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blur account names")
                            .font(.system(size: 12))
                        Text("Keeps emails private in the popover and screenshots.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Toggle("Blur account names", isOn: $model.preferences.blurAccountNames)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            group("Notifications") {
                toggle(
                    "Warn at 80% and 95%",
                    isOn: Binding(
                        get: { !model.preferences.alertThresholds.isEmpty },
                        set: { model.preferences.alertThresholds = $0 ? [0.8, 0.95] : [] }))
                Divider().padding(.leading, 12)
                toggle("Tell me when a limit resets", isOn: $model.preferences.notifyOnReset)
            }

            group("General") {
                toggle("Open at login", isOn: launchAtLogin)
            }

            Text("Right-click an account to rename or remove it.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: title)
            Card { content() }
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
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
}

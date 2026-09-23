import ServiceManagement
import SwiftUI
import VibecomBarCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var adoptionProvider: Provider = .codex
    @State private var adoptionSessionID = ""
    @State private var showingAdoptionConfirmation = false

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

            group("Auto Swap") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switch accounts at 99%")
                            .font(.system(size: 12))
                        Text("Uses the available account whose usage resets soonest.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Switch accounts at 99%", isOn: $model.preferences.autoSwapEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if model.preferences.autoSwapEnabled {
                    Divider().padding(.leading, 12)
                    HStack(spacing: 5) {
                        Image(systemName: model.autoSwapActivity == nil ? "eye" : "checkmark.circle.fill")
                        Text(model.autoSwapActivity ?? "Watching Claude Code and Codex.")
                            .lineLimit(2)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
            }

            group("Live Sessions") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live account handoff")
                            .font(.system(size: 12))
                        Text("Moves newly launched sessions between turns. Anything already open stays untouched.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle(
                        "Live account handoff",
                        isOn: Binding(
                            get: { model.preferences.liveRelayEnabled && model.relayIsInstalled },
                            set: { model.setLiveRelayEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if let message = model.relayStatusMessage {
                    Divider().padding(.leading, 12)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }

                Divider().padding(.leading, 12)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Adopt an existing session")
                        .font(.system(size: 12, weight: .medium))
                    Text("Resume a conversation opened before Live Handoff was enabled.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Picker("Provider", selection: $adoptionProvider) {
                            ForEach(Provider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()

                        TextField("Session ID", text: $adoptionSessionID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))

                        Button("Adopt…") { showingAdoptionConfirmation = true }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(adoptionSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || !model.preferences.liveRelayEnabled || !model.relayIsInstalled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .alert("Resume this session through Vibecom?", isPresented: $showingAdoptionConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Resume Session") {
                        model.adoptExistingSession(
                            provider: adoptionProvider, sessionID: adoptionSessionID)
                        adoptionSessionID = ""
                    }
                } message: {
                    Text("First exit the original \(adoptionProvider.displayName) session after it reaches a safe stopping point. Vibecom will open the same conversation in a new relay-managed Terminal window. The old process is not closed for you.")
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

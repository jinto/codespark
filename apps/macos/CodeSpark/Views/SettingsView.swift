import SwiftUI

struct SettingsView: View {
    @AppStorage(StorageKeys.terminalFontFamily) private var fontFamily = ""
    @AppStorage(StorageKeys.terminalFontSize) private var fontSize: Double = 0
    @State private var saved = false
    @State private var hooksStatus: ClaudeHooksStatus = .installed
    @State private var symlinkFailed = false
    @State private var showUninstallConfirm = false

    private var displayFamily: String {
        fontFamily.isEmpty ? "Auto (\(TerminalFontSettings.resolvedFontFamily()))" : fontFamily
    }
    private var displaySize: Double {
        fontSize > 0 ? fontSize : TerminalFontSettings.resolvedFontSize()
    }

    var body: some View {
        Form {
            Section("Terminal Font") {
                TextField("Font Family", text: $fontFamily, prompt: Text("Auto-detect by language"))
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Font Size")
                    Stepper(value: Binding(
                        get: { displaySize },
                        set: { fontSize = $0 }
                    ), in: 8...36, step: 1) {
                        Text("\(Int(displaySize)) pt")
                            .monospacedDigit()
                    }
                    if fontSize > 0 {
                        Button("Reset") { fontSize = 0 }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Text("Current: \(TerminalFontSettings.resolvedFontFamily()), \(Int(TerminalFontSettings.resolvedFontSize()))pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Save") {
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                if saved {
                    Text("Saved. New sessions will use this font.")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("New sessions will use the updated font.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Claude Code Integration") {
                HStack {
                    if hooksStatus == .installed {
                        Label("Hooks installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(hooksStatusLabel, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }

                if hooksStatus != .installed {
                    Button("Install Hooks") {
                        ClaudeHooksManager.install()
                        refreshStatus()
                        symlinkFailed = hooksStatus != .installed && hooksStatus != .missingHooks
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    if symlinkFailed {
                        Text("Could not create /usr/local/bin/codespark-hook symlink. CLI is still available inside CodeSpark terminals.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Button("Uninstall Hooks") {
                        ClaudeHooksManager.uninstall()
                        refreshStatus()
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.secondary)
                }

                Text("Hooks let CodeSpark detect when Claude Code is waiting for input.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Uninstall") {
                Button("Uninstall CodeSpark...") {
                    showUninstallConfirm = true
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)

                Text("Removes hooks from Claude settings, CLI binary, and all app data.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
        .onAppear { refreshStatus() }
        .alert("Uninstall CodeSpark?", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                ClaudeHooksManager.fullUninstall()
                NSApp.terminate(nil)
            }
        } message: {
            Text("This will remove Claude hooks, the CLI tool, and all app data. The app itself will remain but can be moved to Trash.")
        }
    }

    private var hooksStatusLabel: String {
        switch hooksStatus {
        case .installed: "Installed"
        case .missingHooks: "Hooks not registered in Claude settings"
        case .missingCLI: "CLI tool not in PATH"
        case .missingBoth: "Hooks and CLI not configured"
        }
    }

    private func refreshStatus() {
        hooksStatus = ClaudeHooksManager.checkStatus()
    }
}

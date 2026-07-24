import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(StorageKeys.terminalFontFamily) private var fontFamily = ""
    @AppStorage(StorageKeys.terminalFontSize) private var fontSize: Double = 0
    @AppStorage(StorageKeys.worktreeRoot) private var worktreeRoot = GitWorktreeService.defaultWorktreeRoot
    @State private var saved = false

    private var displayFamily: String {
        fontFamily.isEmpty ? "Auto (\(TerminalFontSettings.resolvedFontFamily()))" : fontFamily
    }
    private var displaySize: Double {
        fontSize > 0 ? fontSize : TerminalFontSettings.resolvedFontSize()
    }

    var body: some View {
        Form {
            Section("Worktrees") {
                HStack {
                    TextField("~/worktrees", text: $worktreeRoot)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        chooseWorktreeRoot()
                    }
                }

                Text("New worktrees are created as <repo>-<branch>-<id> in this folder. Existing worktrees are not moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }

    private func chooseWorktreeRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for new worktrees"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        worktreeRoot = url.path
    }
}

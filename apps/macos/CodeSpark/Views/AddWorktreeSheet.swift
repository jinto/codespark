import SwiftUI

struct AddWorktreeSheet: View {
    @Binding var branchName: String
    let projectPath: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    private var sanitized: String {
        branchName.replacingOccurrences(of: "/", with: "-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Worktree")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Branch name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("feature/my-agent", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { if !branchName.isEmpty { onCreate() } }
            }

            if !branchName.isEmpty {
                Text(".worktrees/\(sanitized)/")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(branchName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { isFocused = true }
    }
}

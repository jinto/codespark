import SwiftUI

/// Issue in, worktree out.
///
/// The user writes what the work *is*; headless claude names the branch and
/// follows the repo's own worktree conventions (`ClaudeWorktreeCreator`), and
/// a claude tab opens in the result, told where its mission is. The sheet only
/// carries the issue text and the wait — which is long enough (tens of
/// seconds) that it has to be shown, not implied.
struct AddWorktreeSheet: View {
    /// Runs the whole creation. Returns the error to show here, nil when done.
    let onCreate: (String) async -> String?
    let onDismiss: () -> Void
    @State private var issue = ""
    @State private var errorMessage: String?
    @State private var creating: Task<Void, Never>?
    @State private var startedAt: Date?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Worktree")
                .font(.headline)

            Text("무슨 작업을 할지 적으면 Claude가 브랜치를 지어 워크트리를 만듭니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $issue)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 110)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06))
                )
                .focused($isFocused)
                .disabled(creating != nil)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let startedAt {
                // Indeterminate on purpose: claude's progress has no fraction
                // to report, and a bar that pretends otherwise stalls at a
                // made-up number. The clock is the honest part — it says the
                // wait is normal (tens of seconds; a remote one, more).
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.linear)
                    HStack {
                        Text("Claude가 워크트리를 만드는 중…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text("\(Int(context.date.timeIntervalSince(startedAt)))s")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    creating?.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if creating == nil {
                    Button("Create", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(issue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFocused = true }
        // Mid-creation the sheet is the only place the wait is visible.
        .interactiveDismissDisabled(creating != nil)
    }

    private func start() {
        errorMessage = nil
        startedAt = Date()
        creating = Task {
            let error = await onCreate(issue)
            creating = nil
            startedAt = nil
            if let error {
                errorMessage = error
            } else {
                onDismiss()
            }
        }
    }
}

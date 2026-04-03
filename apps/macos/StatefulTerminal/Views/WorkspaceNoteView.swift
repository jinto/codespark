import SwiftUI

struct WorkspaceNoteView: View {
    @Binding var noteBody: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace Note")
                .font(.headline)
            TextEditor(text: $noteBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
            Button("Save", action: onSave)
                .buttonStyle(.borderedProminent)
        }
    }
}

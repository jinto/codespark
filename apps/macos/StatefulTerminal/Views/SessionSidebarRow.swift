import SwiftUI

struct SessionSidebarRow: View {
    let session: SessionSummary
    let isActive: Bool
    let isIdle: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isIdle ? Color.gray.opacity(0.4) : Color.green)
                .frame(width: 6, height: 6)

            if isEditing {
                TextField("", text: $editTitle, onCommit: {
                    if !editTitle.isEmpty { onRename(editTitle) }
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(.caption, weight: .medium))
                .onExitCommand { isEditing = false }
            } else {
                Text(session.title)
                    .font(.system(.caption, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .white : .primary)
                    .lineLimit(1)
            }

            Spacer()

            if isIdle {
                Text("idle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            }

            if let cwd = session.lastCwd {
                Text((cwd as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? AppTheme.accent.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editTitle = session.title
            isEditing = true
        }
        .onTapGesture(perform: onSelect)
    }
}

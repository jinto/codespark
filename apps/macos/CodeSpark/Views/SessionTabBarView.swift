import SwiftUI

struct SessionTabBarView: View {
    let sessions: [SessionViewData]
    let activeSessionID: String?
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onNew: () -> Void
    let onNewWorktree: () -> Void
    let canCreateWorktree: Bool
    /// Branch a tab is working in when that is not the worktree it belongs to.
    var visitingBranch: (SessionViewData) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(sessions) { session in
                        SessionTab(
                            title: session.title,
                            visitingBranch: visitingBranch(session),
                            isActive: session.id == activeSessionID,
                            onSelect: { onSelect(session.id) },
                            onClose: { onClose(session.id) }
                        )
                    }
                }
            }

            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New session (\u{2318}T)")

            Button(action: onNewWorktree) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New worktree")
            .disabled(!canCreateWorktree)

            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

private struct SessionTab: View {
    let title: String
    var visitingBranch: String? = nil
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.caption, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

            if let visitingBranch {
                Text(visitingBranch)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 110)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .help("Working in \(visitingBranch)")
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AppTheme.accent.opacity(0.25) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}

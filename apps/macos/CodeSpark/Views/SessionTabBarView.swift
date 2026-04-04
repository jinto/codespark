import SwiftUI

struct SessionTabBarView: View {
    let sessions: [SessionViewData]
    let activeSessionID: String?
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(sessions) { session in
                SessionTab(
                    title: session.title,
                    isActive: session.id == activeSessionID,
                    onSelect: { onSelect(session.id) },
                    onClose: { onClose(session.id) }
                )
            }

            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New session (\u{2318}T)")

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(AppTheme.toolbarBackground)
    }
}

private struct SessionTab: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.caption, weight: isActive ? .semibold : .regular))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? AppTheme.accent.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

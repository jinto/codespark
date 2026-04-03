import SwiftUI

struct RecentlyClosedSessionCardView: View {
    let session: ClosedSessionViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.gray.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(session.title)
                    .font(.system(.caption, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }

            Text(session.snapshotPreview.lines.suffix(3).joined(separator: "\n"))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let cwd = session.lastCwd {
                Text(cwd)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(10)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.divider, lineWidth: 1))
    }
}

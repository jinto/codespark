import SwiftUI

struct RecentlyClosedSessionCardView: View {
    let session: ClosedSessionViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title).font(.headline)
            Text("\(session.targetLabel) \u{00B7} \(session.lastCwd ?? "unknown cwd")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.snapshotPreview.lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .lineLimit(4)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

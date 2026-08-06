import SwiftUI

/// What a restored tab was showing before the app went away, drawn over the fresh
/// terminal so the thread of work is still visible. Deliberately not real
/// scrollback: it sits above the surface and disappears on the first keystroke.
///
/// It paints its own background — the live shell has already printed a prompt
/// underneath, and two layers of text at the same coordinates read as neither.
struct RestoredScreenGhost: View {
    let snapshot: TerminalSnapshotViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                Text("Before restart · press any key to continue")
            }
            .font(.caption)
            .foregroundStyle(AppTheme.infoText)
            .padding(.bottom, 6)

            ForEach(Array(trimmedLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.custom(
                        TerminalFontSettings.resolvedFontFamily(),
                        size: TerminalFontSettings.resolvedFontSize()
                    ))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.surfaceBackground)
        .allowsHitTesting(false)
        .accessibilityIdentifier("restored-screen-ghost")
    }

    /// Trailing blank lines just push the ghost's footprint down the screen.
    private var trimmedLines: [String] {
        var lines = snapshot.lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }
}

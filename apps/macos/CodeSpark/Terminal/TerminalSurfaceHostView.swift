import SwiftUI

#if GHOSTTY_FIRST
import GhosttyKit

struct TerminalSurfaceHostView: NSViewRepresentable {
    let surfaceView: GhosttyTerminalSurfaceView
    var isActive: Bool = false

    func makeNSView(context: Context) -> GhosttyTerminalSurfaceView {
        surfaceView
    }

    func updateNSView(_ nsView: GhosttyTerminalSurfaceView, context: Context) {
        let wasHidden = nsView.isHidden
        nsView.isHidden = !isActive
        if isActive {
            // Force full re-render after unhide — prevents CJK glyph loss
            if wasHidden, let surface = nsView.surface {
                let scaled = nsView.convertToBacking(nsView.frame.size)
                ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
            }
            if nsView.window?.firstResponder !== nsView {
                DispatchQueue.main.async {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }
}
#else
struct TerminalSurfaceHostView: View {
    let session: SessionViewData
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(session.title).font(.headline)
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.9))
                .overlay(alignment: .topLeading) {
                    Text(session.lastCwd ?? session.targetLabel)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(12)
                }
        }
    }
}
#endif

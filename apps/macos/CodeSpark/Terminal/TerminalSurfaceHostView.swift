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
        nsView.isHidden = !isActive
        if isActive, nsView.window?.firstResponder !== nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
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

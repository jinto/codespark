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
            // A surface coming back into view has to be told to paint. Nothing
            // else will: a render is scheduled by output arriving from the shell
            // or by a size change, and a tab that was left at an idle prompt has
            // neither — it reappears still wearing the frame it was hidden with,
            // until something prints or the user hits Ctrl-L.
            //
            // This used to ask for a resize instead, to the size the surface
            // already had. `updateSize` in Ghostty's `apprt/embedded.zig` returns
            // at its first line when the size is unchanged — it says so, and says
            // SwiftUI is why — so the call was a no-op that only ever worked when
            // the size happened to differ. `refresh` schedules the render with no
            // size delta, which is what was wanted all along.
            if wasHidden, let surface = nsView.surface {
                ghostty_surface_refresh(surface)
            }
        }
        // The tab's own idea of whether it is on screen. The claim below is the
        // first of several chances — the view re-claims when it gets a window and
        // when it is unhidden, because at this moment it usually has neither.
        // This used to be a single `DispatchQueue.main.async` that called
        // `makeFirstResponder` and never checked whether it worked; when the
        // window had not arrived by the next runloop turn, the tab opened with no
        // keyboard and stayed that way until it was clicked.
        nsView.isActiveTab = isActive
        nsView.claimFocus()
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

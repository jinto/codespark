import SwiftUI

struct ClosedSessionInspectorView: View {
    let session: ClosedSessionViewData
    let actions: [RecoveryActionViewData]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.title2)
            Text(session.snapshotPreview.lines.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].title, action: actions[index].perform)
            }
        }
        .padding(16)
    }
}

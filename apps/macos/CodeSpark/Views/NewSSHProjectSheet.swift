import SwiftUI

struct NewSSHProjectSheet: View {
    @Binding var host: String
    @Binding var user: String
    @Binding var port: String
    @Binding var remotePath: String
    let onCreate: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?

    private enum Field { case host, user, port, path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New SSH Project")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("example.com or ssh-config alias", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .host)
                    .onSubmit { focusedField = .user }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("User (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("username", text: $user)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .user)
                        .onSubmit { focusedField = .port }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("22", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .path }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Path (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/home/user/project", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .path)
                    .onSubmit { if !host.isEmpty { onCreate() } }
            }

            if !host.isEmpty {
                let info = buildConnectionInfo()
                Text(info.sshCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focusedField = .host }
    }

    private func buildConnectionInfo() -> SSHConnectionInfo {
        SSHConnectionInfo(
            host: host,
            user: user.isEmpty ? nil : user,
            port: Int(port),
            remotePath: remotePath.isEmpty ? nil : remotePath
        )
    }
}

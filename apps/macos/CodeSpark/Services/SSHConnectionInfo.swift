import Foundation

struct SSHConnectionInfo: Equatable {
    let host: String
    var user: String?
    var port: Int?
    var remotePath: String?

    /// Parse from URI like `ssh://[user@]host[:port][/remote/path]`
    init?(uri: String) {
        guard uri.hasPrefix("ssh://") else { return nil }
        let stripped = String(uri.dropFirst("ssh://".count))
        guard !stripped.isEmpty else { return nil }

        // Split authority from path: user@host:port/path
        let authorityAndPath: (String, String?)
        if let slashIndex = stripped.firstIndex(of: "/") {
            authorityAndPath = (String(stripped[..<slashIndex]), String(stripped[slashIndex...]))
        } else {
            authorityAndPath = (stripped, nil)
        }

        let authority = authorityAndPath.0
        let pathPart = authorityAndPath.1

        // Parse user@host:port
        let userHost: (String?, String)
        if let atIndex = authority.firstIndex(of: "@") {
            let u = String(authority[..<atIndex])
            userHost = (u.isEmpty ? nil : u, String(authority[authority.index(after: atIndex)...]))
        } else {
            userHost = (nil, authority)
        }

        let hostPort = userHost.1
        if let colonIndex = hostPort.lastIndex(of: ":") {
            let h = String(hostPort[..<colonIndex])
            let p = String(hostPort[hostPort.index(after: colonIndex)...])
            guard !h.isEmpty else { return nil }
            self.host = h
            self.port = Int(p)
        } else {
            guard !hostPort.isEmpty else { return nil }
            self.host = hostPort
            self.port = nil
        }

        self.user = userHost.0

        if let p = pathPart, p != "/" {
            self.remotePath = p
        } else {
            self.remotePath = nil
        }
    }

    init(host: String, user: String? = nil, port: Int? = nil, remotePath: String? = nil) {
        self.host = host
        self.user = user
        self.port = port
        self.remotePath = remotePath
    }

    var uri: String {
        var s = "ssh://"
        if let user { s += "\(user)@" }
        s += host
        if let port { s += ":\(port)" }
        if let remotePath { s += remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)" }
        return s
    }

    var sshCommand: String {
        var parts = ["ssh"]
        if let port { parts.append(contentsOf: ["-p", "\(port)"]) }
        if let user {
            parts.append("\(user)@\(host)")
        } else {
            parts.append(host)
        }
        if let remotePath {
            let quoted = remotePath.replacingOccurrences(of: "'", with: "'\\''")
            parts.append(contentsOf: ["-t", "cd '\(quoted)' && exec $SHELL"])
        }
        return parts.joined(separator: " ")
    }

    var displayLabel: String {
        if let user { return "\(user)@\(host)" }
        return host
    }
}

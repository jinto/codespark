import AppKit

/// Handles clipboard image paste — saves image to temp file and returns the path.
enum ClipboardImageHandler {

    /// Check if the pasteboard has an image (PNG or TIFF).
    static func hasImage(pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }

    /// Save clipboard image to a temp file and return the path.
    /// Returns nil if no image is found or save fails.
    static func saveImageToTempFile(pasteboard: NSPasteboard = .general) -> String? {
        guard let imageData = pasteboard.data(forType: .png) ?? tiffToPNG(pasteboard.data(forType: .tiff)) else {
            return nil
        }
        let uuid = UUID().uuidString.prefix(8).uppercased()
        let timestamp = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmmss"
            return f.string(from: Date())
        }()
        let path = NSTemporaryDirectory() + "clipboard-\(timestamp)-\(uuid).png"
        guard FileManager.default.createFile(atPath: path, contents: imageData) else {
            return nil
        }
        return path
    }

    // MARK: - SSH remote transfer

    /// Build scp arguments for transferring a file to a remote host.
    static func scpArguments(localPath: String, sshInfo: SSHConnectionInfo) -> (args: [String], remotePath: String) {
        let filename = (localPath as NSString).lastPathComponent
        let remotePath = "/tmp/\(filename)"
        // The only ssh/scp call in the app that used to prompt: without
        // BatchMode a password-authenticating host leaves scp waiting on stdin
        // the app never gives it, so the paste silently never happened.
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if let port = sshInfo.port { args.append(contentsOf: ["-P", "\(port)"]) }
        let target = sshInfo.user.map { "\($0)@\(sshInfo.host)" } ?? sshInfo.host
        // Guards both positionals: the destination, and a local path that could
        // itself begin with a dash.
        args.append("--")
        args.append(contentsOf: [localPath, "\(target):\(remotePath)"])
        return (args, remotePath)
    }

    /// Transfer a local file to a remote host via scp.
    /// Calls completion on main thread with the remote path on success, nil on failure.
    static func scpToRemote(localPath: String, sshInfo: SSHConnectionInfo, completion: @escaping (String?) -> Void) {
        let (args, remotePath) = scpArguments(localPath: localPath, sshInfo: sshInfo)
        Task {
            let status = try? await Subprocess.run("/usr/bin/scp", args, timeout: 60).status
            let result = status == 0 ? remotePath : nil
            await MainActor.run { completion(result) }
        }
    }

    private static func tiffToPNG(_ tiffData: Data?) -> Data? {
        guard let tiffData,
              let image = NSImage(data: tiffData),
              let tiffRep = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffRep) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

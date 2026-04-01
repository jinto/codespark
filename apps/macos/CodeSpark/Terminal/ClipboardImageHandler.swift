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
        var args: [String] = []
        if let port = sshInfo.port { args.append(contentsOf: ["-P", "\(port)"]) }
        let target = sshInfo.user.map { "\($0)@\(sshInfo.host)" } ?? sshInfo.host
        args.append(contentsOf: [localPath, "\(target):\(remotePath)"])
        return (args, remotePath)
    }

    /// Transfer a local file to a remote host via scp.
    /// Calls completion on main thread with the remote path on success, nil on failure.
    static func scpToRemote(localPath: String, sshInfo: SSHConnectionInfo, completion: @escaping (String?) -> Void) {
        let (args, remotePath) = scpArguments(localPath: localPath, sshInfo: sshInfo)
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
            do {
                try process.run()
                process.waitUntilExit()
                let result = process.terminationStatus == 0 ? remotePath : nil
                DispatchQueue.main.async { completion(result) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
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

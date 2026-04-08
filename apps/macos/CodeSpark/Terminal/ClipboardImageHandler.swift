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

    private static func tiffToPNG(_ tiffData: Data?) -> Data? {
        guard let tiffData,
              let image = NSImage(data: tiffData),
              let tiffRep = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffRep) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }
}

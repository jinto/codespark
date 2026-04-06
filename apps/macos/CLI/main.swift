// codespark-hook — CLI bridge for Claude Code hooks → CodeSpark Unix socket
//
// Usage: codespark-hook <stop|session-start|prompt-submit|session-end>
// Reads JSON from stdin, adds hook_event_name, sends to Unix domain socket.
// Socket path from $CODESPARK_SOCK env var (set by CodeSpark app).

import Foundation

let socketPath = ProcessInfo.processInfo.environment["CODESPARK_SOCK"]
    ?? "/tmp/codespark.sock"

guard CommandLine.arguments.count >= 2 else { exit(1) }

let eventName: String
switch CommandLine.arguments[1] {
case "stop":           eventName = "Stop"
case "session-start":  eventName = "SessionStart"
case "prompt-submit":  eventName = "UserPromptSubmit"
case "session-end":    eventName = "SessionEnd"
case "notification":   eventName = "Notification"
default:               exit(1)
}

// Read JSON from stdin (Claude Code pipes hook payload here)
let inputData = FileHandle.standardInput.readDataToEndOfFile()
var json = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] ?? [:]
json["hook_event_name"] = eventName

guard let payload = try? JSONSerialization.data(withJSONObject: json) else { exit(1) }

// Connect to Unix domain socket
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(1) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = socketPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); exit(1) }
_ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
    pathBytes.withUnsafeBufferPointer { buf in
        memcpy(sunPath, buf.baseAddress!, buf.count)
    }
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, addrLen)
    }
}
guard connected == 0 else { close(fd); exit(1) }

// Send JSON + newline delimiter
payload.withUnsafeBytes { _ = write(fd, $0.baseAddress!, payload.count) }
let newline: [UInt8] = [0x0A]
_ = write(fd, newline, 1)
close(fd)

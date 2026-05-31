import Foundation
import os

/// Simple logging wrapper that writes to os_log and a file.
enum Logger {
    private static let osLog = OSLog(subsystem: "com.ainstype.app", category: "general")
    private static let logFile: URL? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ainstype")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    static func log(_ message: String) {
        os_log("%{public}@", log: osLog, type: .info, message)
        appendToFile("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: osLog, type: .error, message)
        appendToFile("[\(ISO8601DateFormatter().string(from: Date()))] ERROR: \(message)")
    }

    private static func appendToFile(_ line: String) {
        guard let url = logFile else { return }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }
}

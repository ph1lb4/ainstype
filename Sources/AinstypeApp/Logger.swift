import Foundation
import os

/// Simple logging wrapper that writes to os_log and a file.
///
/// Privacy: transcribed speech must never be logged (see Pipeline). Messages are
/// emitted to os_log with the `%{private}@` specifier so they are redacted in the
/// unified log / Console / sysdiagnose, and the on-disk file is size-capped so logs
/// can't grow without bound.
enum Logger {
    private static let osLog = OSLog(subsystem: "com.ainstype.app", category: "general")

    /// Rotate the log file once it exceeds this size, keeping a single `.1` backup.
    private static let maxLogBytes: UInt64 = 5 * 1024 * 1024

    /// Verbose lines are dropped unless this is enabled (wired from Config at launch).
    static var verboseEnabled = false

    private static let logFile: URL? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ainstype")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()

    static func log(_ message: String) {
        os_log("%{private}@", log: osLog, type: .info, message)
        appendToFile("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
    }

    static func error(_ message: String) {
        os_log("%{private}@", log: osLog, type: .error, message)
        appendToFile("[\(ISO8601DateFormatter().string(from: Date()))] ERROR: \(message)")
    }

    /// Verbose-only line; emitted only when `verboseEnabled` is true.
    static func verbose(_ message: String) {
        guard verboseEnabled else { return }
        log(message)
    }

    private static func appendToFile(_ line: String) {
        guard let url = logFile else { return }
        let data = (line + "\n").data(using: .utf8) ?? Data()

        rotateIfNeeded(url)

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

    /// Move `app.log` to `app.log.1` (overwriting any previous backup) once it
    /// exceeds the size cap, so the active log starts fresh.
    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxLogBytes
        else { return }

        let backup = url.appendingPathExtension("1")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }
}

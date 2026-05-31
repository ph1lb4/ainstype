import Foundation

/// Manages the LaunchAgent plist for auto-start at login.
enum LaunchAgent {
    static let label = "com.ainstype.menubar"
    static let plistDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    static let plistPath = plistDir.appendingPathComponent("\(label).plist")
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ainstype")

    /// Install the LaunchAgent plist pointing to the current app bundle.
    static func install() throws {
        guard let execPath = Bundle.main.executableURL?.path else {
            throw LaunchAgentError.noExecutable
        }

        try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistPath)

        // Load the agent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath.path]
        try process.run()
        process.waitUntilExit()

        Logger.log("LaunchAgent installed at \(plistPath.path)")
    }

    /// Uninstall the LaunchAgent.
    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistPath.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistPath.path]
            try process.run()
            process.waitUntilExit()

            try FileManager.default.removeItem(at: plistPath)
            Logger.log("LaunchAgent uninstalled")
        }
    }

    /// Check if the LaunchAgent is installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    enum LaunchAgentError: Error {
        case noExecutable
    }
}

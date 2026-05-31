import AppKit

@main
struct AinstypeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController!
    private var pipeline: Pipeline!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.load()

        pipeline = Pipeline(config: config)
        statusMenu = StatusMenuController(config: config, pipeline: pipeline)
        statusMenu.setup()

        // Sleep/wake notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        Logger.log("ainstype started, hotkey=\(config.recording.hotkey)")
    }

    @objc private func systemDidWake(_ notification: Notification) {
        Logger.log("System woke from sleep, resetting state")
        statusMenu.handleWake()
    }
}

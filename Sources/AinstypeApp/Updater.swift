import AppKit
import Sparkle

/// Sparkle auto-update. Reads `appcast.xml` from the latest GitHub release
/// (`SUFeedURL`) and only installs updates signed with the key matching `SUPublicEDKey`.
///
/// A dictation app must never pop a window while the user is typing elsewhere, so
/// scheduled updates found in the background are not shown right away. The menu item
/// turns into "Install Update…" instead, and the update shows when the user clicks it.
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    /// True during recording/processing. Set by the status menu.
    var isBusy: () -> Bool = { false }
    /// Called with the version of a found update that waits for the user, or nil once handled.
    var onWaitingUpdateChange: (String?) -> Void = { _ in }

    /// False in `swift run` builds (no bundle Info.plist), so the updater stays off.
    let isEnabled: Bool

    override init() {
        let info = Bundle.main.infoDictionary
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        isEnabled = !key.isEmpty && !feed.isEmpty
        super.init()
    }

    func start() {
        guard isEnabled, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && !isBusy()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            onWaitingUpdateChange(update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onWaitingUpdateChange(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onWaitingUpdateChange(nil)
    }
}

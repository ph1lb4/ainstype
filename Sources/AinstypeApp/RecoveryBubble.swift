import AppKit

/// An on-screen bubble that surfaces a failure the user may need to act on —
/// above all "your words couldn't be inserted into the app, here they are, copy
/// them". Shown bottom-center on the active screen and dismissed automatically.
///
/// Three requirements shape the implementation:
///   * It must never take keyboard focus. The whole point is that the user can
///     click Copy and then press ⌘V in whatever app is still frontmost, so this
///     is a non-activating borderless panel rather than a window or an NSAlert.
///   * It must be visible over full-screen apps and on every Space, so a
///     dictation into a full-screen editor is still recoverable.
///   * It goes away on its own, but not while the pointer is over it — a long
///     transcription takes longer to read than the timeout.
final class RecoveryBubble {
    static let shared = RecoveryBubble()

    /// What the bubble is reporting — only affects the leading icon.
    enum Style {
        /// Something went wrong and the user probably has to act.
        case failure
        /// A confirmation, e.g. "the latest transcription is on your clipboard".
        case info

        var symbolName: String {
            switch self {
            case .failure: "exclamationmark.triangle.fill"
            case .info: "doc.on.clipboard.fill"
            }
        }

        var tint: NSColor {
            switch self {
            case .failure: .systemOrange
            case .info: .secondaryLabelColor
            }
        }
    }

    /// How long the bubble stays up when the pointer is elsewhere. Long enough
    /// to notice it and reach for the mouse; hovering suspends the countdown.
    static let visibleDuration: TimeInterval = 6

    /// Absolute ceiling on how long a bubble can stay up, hover or no hover.
    /// Without it, a pointer that merely happens to rest over the bubble's
    /// corner of the screen (or one that entered without a matching exit event)
    /// would pin it there indefinitely.
    static let maximumLifetime: TimeInterval = 20

    /// Bubble width; the height follows the content.
    private static let width: CGFloat = 420

    /// Gap between the bubble and the bottom of the screen's visible area
    /// (above the Dock).
    private static let bottomMargin: CGFloat = 24

    /// Long transcriptions are elided in the bubble — the full text is what gets
    /// copied. Keeps the bubble from growing into a wall of text.
    private static let previewLimit = 280

    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var noteLabel: NSTextField!
    private var copyButton: NSButton!
    private var iconView: NSImageView!
    private var dismissTimer: Timer?
    /// Backstop timer for `maximumLifetime`; never suspended by hovering.
    private var lifetimeTimer: Timer?
    /// Full text (not the elided preview) that the Copy button puts on the
    /// clipboard; nil for failures with nothing to recover.
    private var copyText: String?

    private init() {}

    /// Show the bubble from any thread.
    ///
    /// - Parameters:
    ///   - title: one-line summary of what went wrong.
    ///   - message: the transcription to recover, or a longer explanation.
    ///   - copyText: text for the Copy button; nil hides the button.
    ///   - note: optional hint line under the message.
    ///   - style: icon to lead with. Defaults to `.failure`.
    static func present(
        title: String,
        message: String,
        copyText: String? = nil,
        note: String? = nil,
        style: Style = .failure
    ) {
        DispatchQueue.main.async {
            shared.show(title: title, message: message, copyText: copyText, note: note, style: style)
        }
    }

    /// Hide the bubble if it's up (no-op otherwise). Safe from any thread.
    static func dismiss() {
        DispatchQueue.main.async { shared.hide() }
    }

    // MARK: - Presentation

    private func show(title: String, message: String, copyText: String?, note: String?, style: Style) {
        let panel = ensurePanel()
        self.copyText = copyText

        iconView.image = NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = style.tint

        titleLabel.stringValue = title
        bodyLabel.stringValue = Self.preview(of: message)
        bodyLabel.isHidden = message.isEmpty

        noteLabel.stringValue = note ?? ""
        noteLabel.isHidden = note == nil

        copyButton.isHidden = copyText == nil
        copyButton.isEnabled = true
        copyButton.title = "Copy"

        // Resize to the new content before positioning, so the bubble sits the
        // same distance above the Dock whatever its height.
        panel.layoutIfNeeded()
        let height = panel.contentView?.fittingSize.height ?? 0
        panel.setContentSize(NSSize(width: Self.width, height: height))
        position(panel)

        panel.orderFrontRegardless()
        startDismissTimer()
        lifetimeTimer?.invalidate()
        lifetimeTimer = schedule(after: Self.maximumLifetime)
    }

    private func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        lifetimeTimer?.invalidate()
        lifetimeTimer = nil
        panel?.orderOut(nil)
    }

    /// Bottom-center of the screen the pointer is on, falling back to the main
    /// screen — the bubble should appear where the user is working.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomMargin
        ))
    }

    private func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = schedule(after: Self.visibleDuration)
    }

    /// Timer that hides the bubble, registered in `.common` run loop modes.
    /// A plain `Timer.scheduledTimer` only fires in the default mode, so a bubble
    /// shown while a menu is open or a scroll/drag is tracking would sit there
    /// until the user happened to interact with something else.
    private func schedule(after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Elide a long message for display; `copyText` keeps the full version.
    private static func preview(of text: String) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > previewLimit else { return collapsed }
        return collapsed.prefix(previewLimit) + "\u{2026}"
    }

    // MARK: - Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        // .nonactivatingPanel keeps the focused app focused (so ⌘V still goes
        // where the user was typing); .borderless drops the title bar for a
        // notification-like look.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above ordinary floating windows, and present on every Space and over
        // full-screen apps — a failed dictation is usually into a full-screen app.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = makeContentView()

        self.panel = panel
        return panel
    }

    private func makeContentView() -> NSView {
        let background = BubbleBackgroundView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        // Hovering suspends the countdown so a long transcription can be read,
        // and restarts it once the pointer leaves.
        background.onMouseEntered = { [weak self] in
            self?.dismissTimer?.invalidate()
            self?.dismissTimer = nil
        }
        background.onMouseExited = { [weak self] in
            self?.startDismissTimer()
        }

        // Image and tint are set per presentation from the Style.
        let icon = NSImageView()
        icon.setContentHuggingPriority(.required, for: .horizontal)
        iconView = icon

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let closeButton = NSButton()
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let header = NSStackView(views: [icon, titleLabel, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6

        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .labelColor
        bodyLabel.preferredMaxLayoutWidth = Self.width - 32
        bodyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        noteLabel = NSTextField(wrappingLabelWithString: "")
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.preferredMaxLayoutWidth = Self.width - 32

        copyButton = NSButton(title: "Copy", target: self, action: #selector(copyClicked))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small

        let footer = NSStackView(views: [NSView(), copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let stack = NSStackView(views: [header, bodyLabel, noteLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        return background
    }

    // MARK: - Actions

    @objc private func copyClicked() {
        guard let text = copyText else { return }
        // Pinned: a pending clipboard restore from the paste that just failed
        // must not overwrite what the user explicitly asked for.
        Clipboard.copyPinned(text)
        copyButton.title = "Copied"
        copyButton.isEnabled = false
        Logger.log("Recovery bubble: copied \(text.count) characters to clipboard")
        // Leave it up briefly so the "Copied" state is seen, then get out of
        // the way — the user's next move is ⌘V in their own app.
        dismissTimer?.invalidate()
        dismissTimer = schedule(after: 1.2)
    }

    @objc private func dismissClicked() {
        hide()
    }
}

/// Visual-effect background that reports pointer enter/exit, so the bubble can
/// suspend its auto-dismiss countdown while the user is reading it.
private final class BubbleBackgroundView: NSVisualEffectView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            // .activeAlways: the app is an accessory (LSUIElement) and never
            // becomes active, so activeInActiveApp would never fire.
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

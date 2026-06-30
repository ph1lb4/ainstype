import AppKit

/// First-time setup window showing download and optimization progress.
/// User can dismiss it and track progress in the menu bar instead.
class SetupWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var stepLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var privacyLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var spinner: NSProgressIndicator!
    private var dismissButton: NSButton!

    var onDismiss: (() -> Void)?

    func show() {
        if window == nil { buildWindow() }
        updateForWelcome()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    // MARK: - State Updates

    func updateForWelcome() {
        stepLabel.stringValue = "Welcome to ainstype"
        detailLabel.stringValue = "First-time setup requires downloading and optimizing a speech recognition model. This is a one-time process."
        privacyLabel.stringValue = "All transcription happens on your Mac. Your voice never leaves this device."
        privacyLabel.isHidden = false
        progressBar.isHidden = true
        spinner.isHidden = true
        dismissButton.title = "Continue in Background"
    }

    func updateForDownload(progress: Double) {
        stepLabel.stringValue = "Downloading speech model…"
        let pct = Int(progress * 100)
        detailLabel.stringValue = "Downloading: \(pct)% complete. This only happens once."
        privacyLabel.isHidden = true
        progressBar.isHidden = false
        progressBar.isIndeterminate = false
        progressBar.doubleValue = progress * 100
        spinner.isHidden = true
    }

    func updateForReady() {
        stepLabel.stringValue = "Ready!"
        detailLabel.stringValue = "Hold the Right Command key, speak, then release.\nYour words will be typed into the focused app."
        privacyLabel.isHidden = true
        progressBar.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        dismissButton.title = "Get Started"

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.close()
        }
    }

    // MARK: - Build Window

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "ainstype Setup"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let contentView = w.contentView!

        // App icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        // Step label (bold title)
        stepLabel = NSTextField(labelWithString: "")
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        stepLabel.alignment = .center
        contentView.addSubview(stepLabel)

        // Detail label (description)
        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        contentView.addSubview(detailLabel)

        // Progress bar (for download)
        progressBar = NSProgressIndicator()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isHidden = true
        contentView.addSubview(progressBar)

        // Spinner (for optimization)
        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isHidden = true
        contentView.addSubview(spinner)

        // Privacy note
        privacyLabel = NSTextField(wrappingLabelWithString: "")
        privacyLabel.translatesAutoresizingMaskIntoConstraints = false
        privacyLabel.font = .systemFont(ofSize: 11)
        privacyLabel.textColor = .tertiaryLabelColor
        privacyLabel.alignment = .center
        contentView.addSubview(privacyLabel)

        // Dismiss button
        dismissButton = NSButton(title: "Continue in Background", target: self, action: #selector(dismissWindow))
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .large
        dismissButton.keyEquivalent = "\r"
        contentView.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 32),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            stepLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            stepLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            stepLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),

            detailLabel.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),

            progressBar.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 20),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),

            spinner.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 20),
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            privacyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 40),
            privacyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -40),
            privacyLabel.bottomAnchor.constraint(equalTo: dismissButton.topAnchor, constant: -16),

            dismissButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            dismissButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])

        window = w
    }

    @objc private func dismissWindow() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }
}

import AppKit

/// Reads and applies the app settings surfaced in the Settings tab. Implemented
/// by `StatusMenuController`, which owns the live `Config` and the components
/// (hotkey monitor, pipeline) that changes must be applied to.
protocol SettingsDelegate: AnyObject {
    func settingsCurrentConfig() -> Config
    func settingsDidChangeHotkey(_ key: String)
    func settingsDidChangeLanguage(_ language: String?)
    func settingsDidToggleLiveTranscription(_ enabled: Bool)
    func settingsDidChangeLiveMode(_ mode: LiveMode)
    func settingsDidChangeInputDevice(_ value: String)
    func settingsDidChangeClipboardHold(_ seconds: Int)
}

/// Manages the app window: a Settings tab, the dictionary replacements, and the
/// transcription history. (The former Words/Names tabs were removed together
/// with Whisper prompt biasing — see DictionaryManager.)
class DictionaryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private let dictionary: DictionaryManager
    private let history: TranscriptionHistory
    weak var settingsDelegate: SettingsDelegate?

    private var replacementKeys: [String] = []
    private var replacementValues: [String] = []

    private var replacementsTable: NSTableView!
    private var tabView: NSTabView!
    private var historyTextView: NSTextView!

    // Settings-tab controls.
    private var hotkeyPopup: NSPopUpButton!
    private var languageField: NSTextField!
    private var liveCheckbox: NSButton!
    private var liveModePopup: NSPopUpButton!
    private var inputDevicePopup: NSPopUpButton!
    private var clipboardHoldPopup: NSPopUpButton!
    /// Hold duration in seconds for each `clipboardHoldPopup` item, by index.
    /// 0 = off. A value from config.toml outside this list is appended as an
    /// extra item so opening Settings doesn't silently overwrite it.
    private var clipboardHoldValues: [Int] = []
    /// Config value for each `inputDevicePopup` item, by index (kept in sync
    /// when the popup is rebuilt in `populateSettings`).
    private var inputDeviceValues: [String] = []

    /// Hotkey config value ↔ human label, in display order.
    private let hotkeyOptions: [(key: String, label: String)] = [
        ("cmd_r", "Right Command (⌘)"),
        ("cmd", "Left Command (⌘)"),
        ("alt_r", "Right Option (⌥)"),
        ("alt", "Left Option (⌥)"),
        ("ctrl_r", "Right Control (⌃)"),
        ("ctrl", "Left Control (⌃)"),
    ]

    /// Tab indices, for `showWindow(selectTab:)`. Order: Settings,
    /// Replacements, History.
    static let settingsTabIndex = 0
    static let replacementsTabIndex = 1
    static let historyTabIndex = 2

    init(dictionary: DictionaryManager, history: TranscriptionHistory) {
        self.dictionary = dictionary
        self.history = history
        super.init()
    }

    func showWindow(selectTab: Int? = nil) {
        if window == nil {
            buildWindow()
        }
        loadData()
        replacementsTable.reloadData()
        loadHistory()
        populateSettings()
        if let selectTab {
            tabView.selectTabViewItem(at: selectTab)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadHistory() {
        let entries = history.recent()
        guard !entries.isEmpty else {
            historyTextView.string = "No transcriptions yet."
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        historyTextView.string = entries
            .map { "[\(formatter.string(from: $0.date))]\n\($0.text)" }
            .joined(separator: "\n\n\u{2014}\u{2014}\u{2014}\n\n")
    }

    private func loadData() {
        let reps = dictionary.allReplacements
        replacementKeys = reps.keys.sorted()
        replacementValues = replacementKeys.map { reps[$0]! }
    }

    private func persist() {
        var reps: [String: String] = [:]
        for i in 0..<replacementKeys.count {
            let key = replacementKeys[i]
            guard !key.isEmpty else { continue }
            reps[key] = replacementValues[i]
        }
        dictionary.setReplacements(reps)
        dictionary.save()
    }

    // MARK: - Build Window

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "ainstype"
        w.center()
        w.delegate = self
        w.minSize = NSSize(width: 360, height: 300)
        w.isReleasedWhenClosed = false

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(makeSettingsTab())
        tabView.addTabViewItem(makeReplacementsTab())
        tabView.addTabViewItem(makeHistoryTab())
        self.tabView = tabView

        w.contentView!.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: w.contentView!.topAnchor, constant: 8),
            tabView.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor, constant: -8),
            tabView.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor, constant: -8),
        ])

        window = w
    }

    // MARK: - Settings Tab

    private func makeSettingsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Settings"

        hotkeyPopup = NSPopUpButton()
        hotkeyPopup.addItems(withTitles: hotkeyOptions.map { $0.label })
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)

        languageField = NSTextField()
        languageField.placeholderString = "auto-detect (e.g. en, de)"
        languageField.delegate = self
        languageField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        liveCheckbox = NSButton(checkboxWithTitle: "Insert text live while recording", target: self, action: #selector(liveToggled))

        liveModePopup = NSPopUpButton()
        liveModePopup.addItems(withTitles: ["Sentence", "Word"])
        liveModePopup.target = self
        liveModePopup.action = #selector(liveModeChanged)

        inputDevicePopup = NSPopUpButton()
        inputDevicePopup.target = self
        inputDevicePopup.action = #selector(inputDeviceChanged)

        clipboardHoldPopup = NSPopUpButton()
        clipboardHoldPopup.target = self
        clipboardHoldPopup.action = #selector(clipboardHoldChanged)

        let hint = NSTextField(wrappingLabelWithString: "Sentence commits a whole phrase at a time; Word commits each word as it's confirmed (snappier, but types in bursts). The built-in mic keeps Bluetooth headphones in full-quality music playback; picking the headset's own mic drops it into call-quality audio. Keeping the latest transcription on the clipboard lets you paste it yourself with ⌘V for that long; afterwards your previous clipboard content comes back (this does not apply while live insertion is on — live mode never touches the clipboard; use Copy Latest instead). Other options (model, sample rate) live in ~/.config/ainstype/config.toml.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 360

        let stack = NSStackView(views: [
            settingsRow("Hotkey:", hotkeyPopup),
            settingsRow("Microphone:", inputDevicePopup),
            settingsRow("Language:", languageField),
            settingsRow("", liveCheckbox),
            settingsRow("Live mode:", liveModePopup),
            settingsRow("Keep on clipboard:", clipboardHoldPopup),
            hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])

        item.view = container
        return item
    }

    /// A labeled form row: a fixed-width right-aligned label next to a control.
    private func settingsRow(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        // Wide enough for the longest label ("Keep on clipboard:", ~118pt) with
        // room to spare, so nothing truncates.
        l.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// Load current config values into the settings controls.
    private func populateSettings() {
        guard let config = settingsDelegate?.settingsCurrentConfig() else { return }
        if let idx = hotkeyOptions.firstIndex(where: { $0.key == config.recording.hotkey }) {
            hotkeyPopup.selectItem(at: idx)
        }
        languageField.stringValue = config.language ?? ""
        liveCheckbox.state = config.liveTranscription ? .on : .off
        liveModePopup.selectItem(at: config.liveMode == .word ? 1 : 0)
        liveModePopup.isEnabled = config.liveTranscription
        populateInputDevices(selected: config.recording.inputDevice)
        populateClipboardHold(selected: config.clipboardHoldSeconds)
    }

    /// Fill the clipboard-hold popup. Off plus the two presets; a custom value
    /// from config.toml is kept as its own entry.
    private func populateClipboardHold(selected: Int) {
        clipboardHoldPopup.removeAllItems()
        clipboardHoldValues = [0, 5, 10]
        clipboardHoldPopup.addItems(withTitles: ["Off", "5 seconds", "10 seconds"])

        if let idx = clipboardHoldValues.firstIndex(of: selected) {
            clipboardHoldPopup.selectItem(at: idx)
        } else {
            clipboardHoldPopup.addItem(withTitle: "\(selected) seconds")
            clipboardHoldValues.append(selected)
            clipboardHoldPopup.selectItem(at: clipboardHoldValues.count - 1)
        }
    }

    /// Rebuild the microphone popup from the currently connected devices. The
    /// built-in mic is offered as a stable "Built-in Microphone" entry (rather
    /// than by name) so the choice survives renames; other inputs are listed by
    /// name. A saved-but-disconnected device is kept as a disabled entry so the
    /// selection isn't silently lost.
    private func populateInputDevices(selected: String) {
        inputDevicePopup.removeAllItems()
        inputDeviceValues = []

        func add(_ title: String, _ value: String) {
            inputDevicePopup.addItem(withTitle: title)
            inputDeviceValues.append(value)
        }

        add("System Default", "default")
        add("Built-in Microphone", "builtin")
        for device in AudioDevices.inputDevices() where !device.isBuiltIn {
            add(device.name, device.uid)
        }

        if let idx = inputDeviceValues.firstIndex(of: selected) {
            inputDevicePopup.selectItem(at: idx)
        } else {
            // Saved device isn't connected right now — surface it so it's clear
            // what's selected and it isn't overwritten by merely opening Settings.
            add("\(selected) (disconnected)", selected)
            inputDevicePopup.selectItem(at: inputDeviceValues.count - 1)
        }
    }

    @objc private func hotkeyChanged() {
        let idx = hotkeyPopup.indexOfSelectedItem
        guard idx >= 0, idx < hotkeyOptions.count else { return }
        settingsDelegate?.settingsDidChangeHotkey(hotkeyOptions[idx].key)
    }

    @objc private func liveToggled() {
        let on = liveCheckbox.state == .on
        liveModePopup.isEnabled = on
        settingsDelegate?.settingsDidToggleLiveTranscription(on)
    }

    @objc private func liveModeChanged() {
        let mode: LiveMode = liveModePopup.indexOfSelectedItem == 1 ? .word : .sentence
        settingsDelegate?.settingsDidChangeLiveMode(mode)
    }

    @objc private func clipboardHoldChanged() {
        let idx = clipboardHoldPopup.indexOfSelectedItem
        guard idx >= 0, idx < clipboardHoldValues.count else { return }
        settingsDelegate?.settingsDidChangeClipboardHold(clipboardHoldValues[idx])
    }

    @objc private func inputDeviceChanged() {
        let idx = inputDevicePopup.indexOfSelectedItem
        guard idx >= 0, idx < inputDeviceValues.count else { return }
        settingsDelegate?.settingsDidChangeInputDevice(inputDeviceValues[idx])
    }

    // MARK: - Replacements Tab

    private func makeReplacementsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Replacements"

        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        let spokenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("spoken"))
        spokenCol.title = "Spoken Phrase"
        spokenCol.minWidth = 120
        table.addTableColumn(spokenCol)

        let writtenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("written"))
        writtenCol.title = "Written Text"
        writtenCol.minWidth = 120
        table.addTableColumn(writtenCol)

        table.headerView = NSTableHeaderView()
        replacementsTable = table

        scrollView.documentView = table

        let addButton = NSButton(title: "+", target: self, action: #selector(addRow))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .smallSquare
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        let removeButton = NSButton(title: "\u{2212}", target: self, action: #selector(removeRow))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .smallSquare
        removeButton.setContentHuggingPriority(.required, for: .horizontal)

        container.addSubview(scrollView)
        container.addSubview(addButton)
        container.addSubview(removeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            addButton.widthAnchor.constraint(equalToConstant: 28),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            removeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
        ])

        item.view = container
        return item
    }

    private func makeHistoryTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "History"

        let container = NSView()

        let scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        historyTextView = textView

        let copyButton = NSButton(title: "Copy Latest", target: self, action: #selector(copyLatestHistory))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .rounded

        let hint = NSTextField(labelWithString: "Last 5 transcriptions. Select text to copy a portion.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(copyButton)
        container.addSubview(hint)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),

            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            hint.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        item.view = container
        return item
    }

    @objc private func copyLatestHistory() {
        guard let latest = history.recent().first else { return }
        // Pinned so a clipboard hold still in flight can't restore over it.
        Clipboard.copyPinned(latest.text)
    }

    // MARK: - Actions

    @objc private func addRow() {
        replacementKeys.append("")
        replacementValues.append("")
        replacementsTable.reloadData()
        let row = replacementKeys.count - 1
        replacementsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        editCell(table: replacementsTable, row: row, column: 0)
    }

    @objc private func removeRow() {
        let row = replacementsTable.selectedRow
        guard row >= 0 else { return }
        replacementKeys.remove(at: row)
        replacementValues.remove(at: row)
        replacementsTable.reloadData()
        persist()
    }

    private func editCell(table: NSTableView, row: Int, column: Int) {
        DispatchQueue.main.async {
            guard let cellView = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let textField = cellView.textField
            else { return }
            textField.becomeFirstResponder()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        replacementKeys.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("spoken")
        let cellView: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cellView = reused
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let textField = NSTextField()
            textField.isBordered = false
            textField.drawsBackground = false
            textField.isEditable = true
            textField.delegate = self
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let text = identifier.rawValue == "spoken" ? replacementKeys[row] : replacementValues[row]
        cellView.textField?.stringValue = text
        cellView.textField?.tag = row
        return cellView
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }

        // The Settings language field is not a table cell — handle it separately.
        if textField === languageField {
            let text = textField.stringValue.trimmingCharacters(in: .whitespaces)
            settingsDelegate?.settingsDidChangeLanguage(text.isEmpty ? nil : text)
            return
        }

        guard let cellView = textField.superview as? NSTableCellView else { return }

        let row = replacementsTable.row(for: cellView)
        guard row >= 0, row < replacementKeys.count else { return }
        let col = replacementsTable.column(for: cellView)
        let identifier = replacementsTable.tableColumns[col].identifier.rawValue
        if identifier == "spoken" {
            replacementKeys[row] = textField.stringValue
        } else {
            replacementValues[row] = textField.stringValue
        }

        persist()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Clean up empty entries on close
        for i in stride(from: replacementKeys.count - 1, through: 0, by: -1) {
            if replacementKeys[i].isEmpty && replacementValues[i].isEmpty {
                replacementKeys.remove(at: i)
                replacementValues.remove(at: i)
            }
        }
        persist()
    }
}

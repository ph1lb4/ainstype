import AppKit

/// Manages a window for editing the dictionary (terms and replacements).
class DictionaryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var window: NSWindow?
    private let dictionary: DictionaryManager
    private let history: TranscriptionHistory

    private var words: [String] = []
    private var names: [String] = []
    private var replacementKeys: [String] = []
    private var replacementValues: [String] = []

    private var wordsTable: NSTableView!
    private var namesTable: NSTableView!
    private var replacementsTable: NSTableView!
    private var tabView: NSTabView!
    private var historyTextView: NSTextView!

    /// Index of the History tab, for `showWindow(selectTab:)`.
    static let historyTabIndex = 3

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
        wordsTable.reloadData()
        namesTable.reloadData()
        replacementsTable.reloadData()
        loadHistory()
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
        words = dictionary.words
        names = dictionary.names
        let reps = dictionary.allReplacements
        replacementKeys = reps.keys.sorted()
        replacementValues = replacementKeys.map { reps[$0]! }
    }

    private func persist() {
        dictionary.setWords(words)
        dictionary.setNames(names)
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
        w.title = "Dictionary"
        w.center()
        w.delegate = self
        w.minSize = NSSize(width: 360, height: 300)
        w.isReleasedWhenClosed = false

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        tabView.addTabViewItem(makeTab(title: "Words", tag: 0))
        tabView.addTabViewItem(makeTab(title: "Names", tag: 1))
        tabView.addTabViewItem(makeTab(title: "Replacements", tag: 2))
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

    private func makeTab(title: String, tag: Int) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title

        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let table = NSTableView()
        table.tag = tag
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.headerView = nil

        if tag == 2 {
            // Replacements: two columns
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
        } else {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
            col.title = title
            table.addTableColumn(col)

            if tag == 0 { wordsTable = table }
            else { namesTable = table }
        }

        scrollView.documentView = table

        let addButton = NSButton(title: "+", target: self, action: #selector(addRow(_:)))
        addButton.tag = tag
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .smallSquare
        addButton.setContentHuggingPriority(.required, for: .horizontal)

        let removeButton = NSButton(title: "\u{2212}", target: self, action: #selector(removeRow(_:)))
        removeButton.tag = tag
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
        Clipboard.copy(latest.text)
    }

    // MARK: - Actions

    @objc private func addRow(_ sender: NSButton) {
        let tag = sender.tag
        switch tag {
        case 0:
            words.append("")
            wordsTable.reloadData()
            let row = words.count - 1
            wordsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            editCell(table: wordsTable, row: row, column: 0)
        case 1:
            names.append("")
            namesTable.reloadData()
            let row = names.count - 1
            namesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            editCell(table: namesTable, row: row, column: 0)
        case 2:
            replacementKeys.append("")
            replacementValues.append("")
            replacementsTable.reloadData()
            let row = replacementKeys.count - 1
            replacementsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            editCell(table: replacementsTable, row: row, column: 0)
        default:
            break
        }
    }

    @objc private func removeRow(_ sender: NSButton) {
        let tag = sender.tag
        switch tag {
        case 0:
            let row = wordsTable.selectedRow
            guard row >= 0 else { return }
            words.remove(at: row)
            wordsTable.reloadData()
            persist()
        case 1:
            let row = namesTable.selectedRow
            guard row >= 0 else { return }
            names.remove(at: row)
            namesTable.reloadData()
            persist()
        case 2:
            let row = replacementsTable.selectedRow
            guard row >= 0 else { return }
            replacementKeys.remove(at: row)
            replacementValues.remove(at: row)
            replacementsTable.reloadData()
            persist()
        default:
            break
        }
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
        switch tableView.tag {
        case 0: return words.count
        case 1: return names.count
        case 2: return replacementKeys.count
        default: return 0
        }
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("value")
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

        let text: String
        switch tableView.tag {
        case 0:
            text = words[row]
        case 1:
            text = names[row]
        case 2:
            if identifier.rawValue == "spoken" {
                text = replacementKeys[row]
            } else {
                text = replacementValues[row]
            }
        default:
            text = ""
        }

        cellView.textField?.stringValue = text
        cellView.textField?.tag = row
        return cellView
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        guard let cellView = textField.superview as? NSTableCellView else { return }

        // Find which table this belongs to
        var view: NSView? = cellView
        while view != nil && !(view is NSTableView) {
            view = view?.superview
        }
        guard let tableView = view as? NSTableView else { return }

        let row = tableView.row(for: cellView)
        guard row >= 0 else { return }
        let col = tableView.column(for: cellView)
        let value = textField.stringValue

        switch tableView.tag {
        case 0:
            guard row < words.count else { return }
            words[row] = value
        case 1:
            guard row < names.count else { return }
            names[row] = value
        case 2:
            guard row < replacementKeys.count else { return }
            let identifier = tableView.tableColumns[col].identifier.rawValue
            if identifier == "spoken" {
                replacementKeys[row] = value
            } else {
                replacementValues[row] = value
            }
        default:
            break
        }

        persist()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Clean up empty entries on close
        words.removeAll { $0.isEmpty }
        names.removeAll { $0.isEmpty }
        for i in stride(from: replacementKeys.count - 1, through: 0, by: -1) {
            if replacementKeys[i].isEmpty && replacementValues[i].isEmpty {
                replacementKeys.remove(at: i)
                replacementValues.remove(at: i)
            }
        }
        persist()
    }
}

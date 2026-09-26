import AppKit
import UniformTypeIdentifiers
import HPLink

/// The Monitor window: one thumbnail per attached calculator, refreshed on a
/// timer or on demand.
///
/// Thumbnails are produced by asking each calculator for a downscaled screenshot,
/// which is far cheaper than scaling a full-resolution capture on the computer and
/// keeps the classroom network quiet.
@MainActor
final class MonitorViewController: NSViewController {
    enum ImageSize: Int, CaseIterable {
        case small, medium, large

        var pixelWidth: CGFloat {
            switch self {
            case .small: 80
            case .medium: 160
            case .large: 240
            }
        }

        var title: String {
            switch self {
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
    }

    /// Exposed to the file so per-row menu actions can reach it.
    fileprivate unowned let model: WorkspaceModel
    private let collectionView = NSCollectionView()
    private let scrollView = NSScrollView()
    private let statusLabel = secondaryLabel("")
    private var refreshTimer: Timer?
    private var isRefreshing = false
    /// Live projection windows, kept alive while open.
    private var projectors: [ScreenProjector] = []

    /// Calculators selected for targeted sending and messaging.
    private(set) var selectedCalculators: [CalculatorEntry] = []
    var onSelectionChange: (() -> Void)?

    var imageSize: ImageSize = .medium {
        didSet { collectionView.collectionViewLayout?.invalidateLayout(); collectionView.reloadData() }
    }

    var automaticRefresh = false {
        didSet { automaticRefresh ? startTimer() : stopTimer() }
    }

    init(model: WorkspaceModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = NSView()

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: imageSize.pixelWidth + 24, height: imageSize.pixelWidth * 0.75 + 44)
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        collectionView.collectionViewLayout = layout

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        container.embed(scrollView, insets: NSEdgeInsets(top: 0, left: 0, bottom: 24, right: 0))
        container.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        view = container
        updateStatus()
    }

    /// Re-reads the calculator list and refreshes every thumbnail.
    func reload() {
        collectionView.reloadData()
        updateStatus()
        Task { await refreshAll() }
    }

    /// Captures a fresh thumbnail from every attached calculator.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for entry in model.calculators where entry.isAttached {
            if let image = await model.captureScreen(from: entry) {
                entry.lastScreen = image
            }
            collectionView.reloadData()
        }
        updateStatus()
    }

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateStatus() {
        let attached = model.calculators.filter(\.isAttached).count
        let selected = selectedCalculators.count
        var text = attached == 1 ? "1 calculator connected" : "\(attached) calculators connected"
        if selected > 0 { text += " — \(selected) selected" }
        statusLabel.stringValue = text
    }

    /// The calculators a send should target: the selection, or all when empty.
    var recipients: [CalculatorEntry] {
        selectedCalculators.isEmpty ? model.calculators.filter(\.isAttached) : selectedCalculators
    }

    deinit { refreshTimer?.invalidate() }
}

extension MonitorViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.calculators.filter(\.isAttached).count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath)
        guard let thumbnail = item as? ThumbnailItem else { return item }
        let entry = model.calculators.filter(\.isAttached)[indexPath.item]
        thumbnail.configure(entry: entry, size: imageSize)
        return thumbnail
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectedCalculators = indexPaths.compactMap { path in
            let attached = model.calculators.filter(\.isAttached)
            return path.item < attached.count ? attached[path.item] : nil
        }
        updateStatus()
        onSelectionChange?()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectedCalculators = collectionView.selectionIndexPaths.compactMap { path in
            let attached = model.calculators.filter(\.isAttached)
            return path.item < attached.count ? attached[path.item] : nil
        }
        updateStatus()
        onSelectionChange?()
    }

    /// Right-click commands, matching the Connectivity Kit's Monitor menu.
    override func rightMouseDown(with event: NSEvent) {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        let entry = model.calculators.filter(\.isAttached)[indexPath.item]

        let actions = MonitorRowActions(controller: self, entry: entry)
        let menu = NSMenu()
        menu.addItem(withTitle: "Project", action: #selector(MonitorRowActions.project), keyEquivalent: "")
            .target = actions
        menu.addItem(withTitle: "Save As…", action: #selector(MonitorRowActions.saveScreen), keyEquivalent: "")
            .target = actions
        menu.addItem(withTitle: "Copy to Clipboard", action: #selector(MonitorRowActions.copyScreen), keyEquivalent: "")
            .target = actions
        menu.addItem(.separator())
        menu.addItem(withTitle: "Send Message…", action: #selector(MonitorRowActions.sendMessage), keyEquivalent: "")
            .target = actions
        menu.addItem(withTitle: entry.needsHelp ? "Reset Help" : "No Help Flag", action: #selector(MonitorRowActions.resetHelp), keyEquivalent: "")
            .target = actions
        menu.items.last?.isEnabled = entry.needsHelp

        // The target must outlive the menu's tracking loop.
        objc_setAssociatedObject(menu, &MonitorRowActions.key, actions, .OBJC_ASSOCIATION_RETAIN)
        NSMenu.popUpContextMenu(menu, with: event, for: collectionView)
    }

    /// Opens a live window showing one calculator's display.
    func project(_ entry: CalculatorEntry) {
        let projector = ScreenProjector(model: model, entry: entry)
        projectors.append(projector)
        projector.showWindow(nil)
        projector.start()
    }

    /// Refreshes a single thumbnail.
    func refresh(_ entry: CalculatorEntry) async {
        if let image = await model.captureScreen(from: entry) {
            entry.lastScreen = image
        }
        collectionView.reloadData()
    }
}

/// Per-row menu actions for the Monitor window.
///
/// A separate object holds the calculator the menu was opened on, because a menu
/// item's target is a single object and the row is only known at click time.
@MainActor
final class MonitorRowActions: NSObject {
    static var key: UInt8 = 0

    private unowned let controller: MonitorViewController
    private let entry: CalculatorEntry

    init(controller: MonitorViewController, entry: CalculatorEntry) {
        self.controller = controller
        self.entry = entry
    }

    @objc func project() {
        controller.project(entry)
    }

    @objc func saveScreen() {
        Task { @MainActor in
            var bytes = entry.lastScreen
            if bytes == nil {
                bytes = await controller.model.captureScreen(from: entry)
            }
            guard let bytes else { return }
            ScreenshotExport.show(bytes: bytes, suggestedName: entry.name, in: nil)
        }
    }

    @objc func copyScreen() {
        guard let bytes = entry.lastScreen, let image = NSImage(data: Data(bytes)) else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    @objc func sendMessage() {
        guard let text = promptForText(
            title: "Send Message to \(entry.name)",
            message: "The message appears in the calculator's Message Center.",
            in: nil
        ) else { return }
        Task { @MainActor in await controller.model.sendMessage(text, to: [entry]) }
    }

    @objc func resetHelp() {
        entry.needsHelp = false
        controller.reload()
    }
}

/// A window that follows one calculator's display.
///
/// The Connectivity Kit freezes the other thumbnails while a display is
/// projected, because the calculator's link is busy; this window does the same by
/// taking over the refresh loop for its calculator.
@MainActor
final class ScreenProjector: NSWindowController {
    private unowned let model: WorkspaceModel
    private let entry: CalculatorEntry
    private let imageView = NSImageView()
    private let statusLabel = secondaryLabel("")
    private var timer: Timer?

    init(model: WorkspaceModel, entry: CalculatorEntry) {
        self.model = model
        self.entry = entry

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Projecting \(entry.name)"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor

        let container = NSView()
        container.embed(imageView, insets: NSEdgeInsets(top: 8, left: 8, bottom: 28, right: 8))
        container.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        window.contentView = container
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Begins refreshing the projected display.
    ///
    /// The calculator is polled faster than the thumbnail grid so a student's
    /// work is followed closely.
    func start() {
        guard entry.isAttached else {
            statusLabel.stringValue = "This calculator is no longer connected."
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard entry.isAttached else {
            statusLabel.stringValue = "Disconnected."
            timer?.invalidate()
            timer = nil
            return
        }
        Task { @MainActor in
            if let bytes = await model.captureScreen(from: entry), let image = NSImage(data: Data(bytes)) {
                imageView.image = image
                statusLabel.stringValue = "Live — updating every 1.5 seconds"
            } else {
                statusLabel.stringValue = "Waiting for the calculator…"
            }
        }
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}

/// One calculator thumbnail.
final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("Thumbnail")

    private let screenView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let helpBadge = NSImageView()

    override func loadView() {
        let container = NSView()

        screenView.imageScaling = .scaleProportionallyUpOrDown
        screenView.wantsLayer = true
        screenView.layer?.borderWidth = 1
        screenView.layer?.borderColor = NSColor.separatorColor.cgColor
        screenView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail

        helpBadge.image = NSImage(systemSymbolName: "questionmark.circle.fill", accessibilityDescription: "Needs help")
        helpBadge.contentTintColor = Theme.helpFlagColor
        helpBadge.isHidden = true

        for subview in [screenView, nameLabel, helpBadge] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            screenView.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            screenView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            screenView.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -16),
            screenView.heightAnchor.constraint(equalTo: screenView.widthAnchor, multiplier: 0.75),

            helpBadge.leadingAnchor.constraint(equalTo: screenView.leadingAnchor, constant: -2),
            helpBadge.topAnchor.constraint(equalTo: screenView.topAnchor, constant: -2),

            nameLabel.topAnchor.constraint(equalTo: screenView.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
        ])
        view = container
    }

    func configure(entry: CalculatorEntry, size: MonitorViewController.ImageSize) {
        nameLabel.stringValue = entry.name
        helpBadge.isHidden = !entry.needsHelp

        if let bytes = entry.lastScreen, let image = NSImage(data: Data(bytes)) {
            screenView.image = image
        } else {
            screenView.image = nil
            screenView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

/// The Messages window: sends text to selected calculators and shows replies.
@MainActor
final class MessagesViewController: NSViewController {
    private unowned let model: WorkspaceModel
    private let transcript = NSTextView()
    private let entryField = NSTextField()
    private let recipientLabel = secondaryLabel("")

    /// Supplies the calculators a message should go to.
    var recipientsProvider: () -> [CalculatorEntry] = { [] }

    init(model: WorkspaceModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = NSView()

        transcript.isEditable = false
        transcript.font = Theme.labelFont
        let transcriptScroll = textScrollView(transcript)

        entryField.placeholderString = "Message"
        entryField.target = self
        entryField.action = #selector(send)
        entryField.delegate = self

        let sendButton = NSButton(title: "Send to class", target: self, action: #selector(send))
        sendButton.bezelStyle = .rounded

        let entryRow = NSStackView(views: [entryField, sendButton])
        entryRow.orientation = .horizontal
        entryRow.spacing = 8
        entryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        container.embed(transcriptScroll, insets: NSEdgeInsets(top: 8, left: 8, bottom: 40, right: 8))
        container.addSubview(entryRow)
        container.addSubview(recipientLabel)
        for subview in [entryRow, recipientLabel] as [NSView] { subview.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            recipientLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            recipientLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            recipientLabel.bottomAnchor.constraint(equalTo: entryRow.topAnchor, constant: -4),

            entryRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            entryRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            entryRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        view = container
        updateRecipients()
    }

    /// Updates the recipient line from the Monitor window's selection.
    func updateRecipients() {
        let targets = recipientsProvider()
        let attached = model.calculators.filter(\.isAttached).count
        recipientLabel.stringValue = targets.isEmpty
            ? "No calculators are connected."
            : "To \(targets.count) of \(attached) connected calculator(s): "
                + targets.map(\.name).joined(separator: ", ")
    }

    @objc private func send() {
        let text = entryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let targets = recipientsProvider()
        guard !targets.isEmpty else {
            append("No calculators are connected.")
            return
        }

        entryField.stringValue = ""
        append("You → \(targets.map(\.name).joined(separator: ", ")): \(text)")
        Task { @MainActor in
            await model.sendMessage(text, to: targets)
            append(model.statusMessage)
        }
    }

    /// Adds a line to the transcript.
    func append(_ line: String) {
        transcript.string += (transcript.string.isEmpty ? "" : "\n") + line
        transcript.scrollToEndOfDocument(nil)
    }
}

extension MessagesViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) { }
}

/// The Proctor Mode pane: applies an exam configuration to every calculator as it
/// connects.
@MainActor
final class ProctorViewController: NSViewController {
    private unowned let model: WorkspaceModel
    private let statusLabel = NSTextField(labelWithString: "")
    private let configurationLabel = secondaryLabel("")
    private let startButton = NSButton()
    private let logView = NSTextView()
    private var applied: Set<String> = []

    /// The configuration to apply, if one has been chosen.
    var configuration: PrimeObject? {
        didSet { updateState() }
    }

    init(model: WorkspaceModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = NSView()

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.alignment = .center

        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(toggleProctorMode)

        let openButton = NSButton(title: "Open…", target: self, action: #selector(chooseConfiguration))
        openButton.bezelStyle = .rounded

        logView.isEditable = false
        logView.font = Theme.bodyFont
        let logScroll = textScrollView(logView)

        let buttonRow = NSStackView(views: [openButton, startButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [statusLabel, configurationLabel, buttonRow, logScroll])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        container.embed(stack, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        view = container
        updateState()
    }

    private(set) var isActive = false

    @objc private func toggleProctorMode() {
        isActive.toggle()
        updateState()
        if isActive {
            log("Proctor mode started. Every calculator that connects will receive the selected configuration.")
            Task { @MainActor in await applyToConnected() }
        } else {
            log("Proctor mode stopped.")
        }
    }

    @objc private func chooseConfiguration() {
        let panel = NSOpenPanel()
        // The extension is declared by the bundle's own document types, so the
        // content type is resolved from it rather than hardcoded here.
        panel.allowedContentTypes = [.primeContentType(forExtension: "hpexammode")].compactMap { $0 }
        panel.directoryURL = model.workingFolder.contentURL
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }

        let name = PrimeObjectName.parse(diskName: url.lastPathComponent).name
        configuration = PrimeObject(name: name, type: .examConfiguration, content: Array(data))
        log("Selected configuration “\(name)”.")
        if isActive { Task { @MainActor in await applyToConnected() } }
    }

    /// Applies the configuration to every attached calculator that has not had it.
    func applyToConnected() async {
        guard isActive, let configuration else { return }
        for entry in model.calculators where entry.isAttached && !applied.contains(entry.name) {
            do {
                try entry.session?.sendObject(configuration)
                applied.insert(entry.name)
                log("Applied to \(entry.name).")
            } catch {
                log("Could not apply to \(entry.name): \(WorkspaceModel.describe(error))")
            }
        }
    }

    private func updateState() {
        if isActive {
            statusLabel.stringValue = "Proctor mode is active"
            statusLabel.textColor = .systemGreen
            startButton.title = "Stop"
        } else {
            statusLabel.stringValue = "Proctor mode is not active"
            statusLabel.textColor = .secondaryLabelColor
            startButton.title = "Start"
        }
        startButton.isEnabled = configuration != nil
        configurationLabel.stringValue = configuration.map {
            "Configuration: \($0.name)"
        } ?? "No configuration selected. Any calculator that connects will be placed into exam mode immediately once one is chosen."
    }

    private func log(_ line: String) {
        logView.string += (logView.string.isEmpty ? "" : "\n") + line
        logView.scrollToEndOfDocument(nil)
    }
}

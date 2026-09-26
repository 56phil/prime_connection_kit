import AppKit
import UniformTypeIdentifiers
import HPLink

/// The application's main window: calculator pane, content pane, and a tabbed
/// work area.
///
/// The layout follows the Connectivity Kit: a toolbar of the most-used commands,
/// two source-list panes on the left and right, and editors filling the middle.
@MainActor
final class MainWindowController: NSWindowController {
    let model: WorkspaceModel

    private let splitView = NSSplitView()
    private let calculatorPane = CalculatorPaneController()
    private let contentPane = ContentPaneController()
    private let tabView = NSTabView()
    /// Where an open editor's object lives, which decides where Save writes.
    ///
    /// The Connectivity Kit's rule is that Save targets the pane the object was
    /// opened from: an object taken from a calculator is written back to that
    /// calculator, and one from the content pane is written to this computer.
    /// Without this the editor would have to guess, and a program opened from a
    /// calculator would be saved only to disk.
    enum EditorOrigin: Equatable {
        /// The object came from a connected calculator, by name.
        case calculator(String)
        /// The object came from the content pane.
        case content
    }

    /// Open editors, keyed by the object identity shown in the tab identifier.
    private var editors: [String: PrimeEditor] = [:]
    /// Where each open object came from.
    private var editorOrigins: [String: EditorOrigin] = [:]

    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let busyIndicator = NSProgressIndicator()

    private var monitorController: MonitorViewController?
    private var messagesController: MessagesViewController?
    private var proctorController: ProctorViewController?
    private var monitorWindow: NSWindow?
    private var messagesWindow: NSWindow?
    private var proctorWindow: NSWindow?

    /// Which calculators the classroom commands target.
    private var classroomSelection: [CalculatorEntry] = []
    /// Registry IDs of devices with a connection attempt in flight, so the poll
    /// does not start a second attempt before the first finishes.
    private var connecting: Set<UInt64> = []

    init(model: WorkspaceModel) {
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prime Connection Kit"
        window.setFrameAutosaveName("MainWindow")
        // Wide enough for both side panes at their minimum widths plus a work area
        // that can still show a line of code.
        window.minSize = NSSize(width: 900, height: 500)
        super.init(window: window)

        buildContentView()
        buildToolbar()
        observeModel()
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Layout

    private func buildContentView() {
        guard let window else { return }

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let calculatorSide = sidePanel(title: "Calculators", content: calculatorPane.scrollView)
        let contentSide = sidePanel(title: "Content", content: contentPane.scrollView)
        let workSide = sidePanel(title: "Work area", content: tabView)

        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self

        splitView.addArrangedSubview(calculatorSide)
        splitView.addArrangedSubview(workSide)
        splitView.addArrangedSubview(contentSide)

        // The work area takes the remaining width, so it must be the pane with no
        // width of its own. The side panes are given fixed preferred widths and
        // minimums instead of calling `setPosition`, which was the earlier
        // approach: `setPosition` measures against `splitView.bounds`, and the
        // split view has no size until it is laid out, so the second divider was
        // placed at `0 - 250` and the work area — the editor — collapsed to a
        // sliver while the space went to the Content pane.
        calculatorSide.translatesAutoresizingMaskIntoConstraints = false
        contentSide.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            calculatorSide.widthAnchor.constraint(equalToConstant: 230).withPriority(.defaultHigh),
            calculatorSide.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            contentSide.widthAnchor.constraint(equalToConstant: 260).withPriority(.defaultHigh),
            contentSide.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            // The work area may shrink, but not below the width at which a line of
            // code stops being readable.
            workSide.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        calculatorPane.onSelectionChange = { [weak self] in self?.updateMenus() }
        contentPane.onSelectionChange = { [weak self] in self?.updateMenus() }
        calculatorPane.outlineView.doubleAction = #selector(openSelected)
        calculatorPane.outlineView.target = self
        contentPane.outlineView.doubleAction = #selector(openSelected)
        contentPane.outlineView.target = self

        // Dropping onto the calculator pane sends objects to the calculator the
        // drop landed on, and imports files dragged in from Finder.
        calculatorPane.onDrop = { [weak self] payloads, urls, node in
            self?.handleDrop(payloads: payloads, fileURLs: urls, onto: node, destination: .calculator) ?? false
        }
        contentPane.onDrop = { [weak self] payloads, urls, node in
            self?.handleDrop(payloads: payloads, fileURLs: urls, onto: node, destination: .content) ?? false
        }

        calculatorPane.outlineView.menuProvider = { [weak self] row, _ in
            self?.calculatorMenu(forRow: row)
        }
        contentPane.outlineView.menuProvider = { [weak self] row, _ in
            self?.contentMenu(forRow: row)
        }

        let statusBar = NSView()
        statusBar.wantsLayer = true
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        busyIndicator.style = .spinning
        busyIndicator.controlSize = .small
        busyIndicator.isDisplayedWhenStopped = false

        statusBar.addSubview(statusLabel)
        statusBar.addSubview(busyIndicator)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: busyIndicator.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            busyIndicator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            busyIndicator.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        let root = NSView()
        root.addSubview(splitView)
        root.addSubview(statusBar)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        window.contentView = root
    }

    private func sidePanel(title: String, content: NSView) -> NSView {
        let container = NSView()
        let header = NSTextField(labelWithString: title)
        header.font = Theme.headerFont
        header.textColor = .secondaryLabelColor

        container.addSubview(header)
        container.addSubview(content)
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),

            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.paneMinimumWidth).isActive = true
        return container
    }

    private func buildToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
    }

    // MARK: - Model observation

    private func observeModel() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(modelChanged), name: WorkspaceModel.didChange, object: model
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(busyChanged), name: WorkspaceModel.didChangeBusyState, object: model
        )
    }

    @objc private func modelChanged() {
        refreshAll()
    }

    @objc private func busyChanged() {
        statusLabel.stringValue = model.statusMessage
        model.isBusy ? busyIndicator.startAnimation(nil) : busyIndicator.stopAnimation(nil)
    }

    /// Rebuilds both panes and reconnects any newly attached calculator.
    func refreshAll() {
        model.refreshKnownCalculators()
        calculatorPane.update(with: model)
        contentPane.update(with: model)
        statusLabel.stringValue = model.statusMessage
        updateMenus()
    }

    /// Called on a timer to notice devices being plugged in and unplugged.
    ///
    /// Connecting is driven by what is *unconnected*, not by whether the device
    /// list changed: a calculator attached before the app launched is already in
    /// the list on the first poll, so a change test would never connect it.
    func pollForDevices() {
        let before = model.calculators.map { "\($0.name):\($0.isAttached)" }
        model.refreshKnownCalculators()
        let after = model.calculators.map { "\($0.name):\($0.isAttached)" }
        if before != after {
            calculatorPane.update(with: model)
            updateMenus()
        }

        // Connect to anything that is attached but has no session yet.
        for entry in model.calculators where entry.descriptor != nil && !entry.isAttached && !connecting.contains(entry.descriptor!.id) {
            let id = entry.descriptor!.id
            connecting.insert(id)
            Task { @MainActor in
                await model.connect(entry)
                connecting.remove(id)
                await proctorController?.applyToConnected()
            }
        }
    }

    private func updateMenus() {
        messagesController?.updateRecipients()
    }

    // MARK: - Opening editors

    /// Opens the selected object in the work area.
    @objc func openSelected() {
        // The pane an object is opened from decides where Save will write, so the
        // origin is recorded with it.
        let owner = calculatorPane.selectionOwner?.name
        for object in calculatorPane.selectedObjects {
            open(object, origin: .calculator(owner ?? ""))
        }
        for object in contentPane.selectedObjects {
            open(object, origin: .content)
        }
    }

    /// Opens one object, reusing its existing tab.
    func open(_ object: PrimeObject, origin: EditorOrigin = .content) {
        // Editors are keyed by the object's identity, so opening the same object
        // twice focuses the tab that is already showing it.
        if editors[object.id] != nil,
           let tab = tabView.tabViewItems.first(where: { ($0.identifier as? String) == object.id }) {
            tabView.selectTabViewItem(tab)
            return
        }

        let editor = makeEditor(for: object)
        editors[object.id] = editor
        editorOrigins[object.id] = origin
        editor.onDirtyChange = { [weak self] in self?.updateTabTitles() }
        updateTabTitles()

        let viewController = NSViewController()
        viewController.view = editor.editorView
        let tab = NSTabViewItem(viewController: viewController)
        tab.identifier = object.id
        tab.label = editor.title
        tabView.addTabViewItem(tab)
        tabView.selectTabViewItem(tab)
    }

    private func makeEditor(for object: PrimeObject) -> PrimeEditor {
        switch object.type {
        case .real, .complex:
            return VariableSetEditor(object: object)
        case .list:
            return ListEditor(object: object)
        case .matrix:
            return MatrixEditor(object: object)
        case .program, .appProgram:
            return ProgramEditor(object: object)
        case .note, .appNote:
            return NoteEditor(object: object)
        case .examConfiguration:
            return ExamModeEditor(object: object)
        case .application, .settings:
            // An application's program and note are separate objects. They are
            // looked up from the calculator's own listing rather than from the
            // selection, so opening the application alone still shows what it
            // contains.
            return ApplicationEditor(object: object, sidecars: sidecars(of: object))
        }
    }

    /// The companion objects stored alongside an application.
    private func sidecars(of application: PrimeObject) -> [PrimeObject] {
        let pool = calculatorPane.selectedObjects
            + model.contentObjects
            + model.calculators.flatMap { entry in
                entry.isAttached ? entry.deviceObjects : model.mirroredObjects(for: entry.name)
            }
        return pool.filter { $0.name == application.name && $0.type != application.type }
    }

    private func updateTabTitles() {
        for tab in tabView.tabViewItems {
            guard let identifier = tab.identifier as? String else { continue }
            let dirty = editors[identifier]?.isDirty ?? false
            let name = tab.label.replacingOccurrences(of: " *", with: "")
            tab.label = dirty ? "\(name) *" : name
        }
        window?.isDocumentEdited = editors.values.contains(where: \.isDirty)
    }

    /// The editor in the active tab, if any.
    private var activeEditor: PrimeEditor? {
        guard let identifier = tabView.selectedTabViewItem?.identifier as? String else { return nil }
        return editors[identifier]
    }

    // MARK: - Commands

    /// Saves the active editor's object where it came from.
    ///
    /// An object opened from a calculator is written back to that calculator and
    /// mirrored here; one opened from the content pane is written to this
    /// computer. Objects that belong to a calculator are also mirrored locally, so
    /// the pane and the working folder stay consistent with the device.
    @objc func saveActive() {
        guard let identifier = tabView.selectedTabViewItem?.identifier as? String,
              let editor = editors[identifier],
              let object = editor.produceObject()
        else {
            NSSound.beep()
            return
        }

        Task { @MainActor in
            await save(object, origin: editorOrigins[identifier] ?? .content)
            editor.markSaved()
            updateTabTitles()
        }
    }

    /// Saves one object at its origin.
    private func save(_ object: PrimeObject, origin: EditorOrigin) async {
        switch origin {
        case .calculator(let name):
            if let entry = model.calculators.first(where: { $0.name == name && $0.isAttached }) {
                await model.save(object, to: entry)
                // An application's sidecars travel with it, so the whole set is
                // pushed rather than just the edited file.
                await model.saveCompanions(of: object, to: entry)
            } else {
                model.status("“\(name)” is no longer connected; saved to the content folder instead.")
                model.saveToContent(object)
            }
        case .content:
            model.saveToContent(object)
        }
    }

    @objc func saveAll() {
        Task { @MainActor in
            for (identifier, editor) in editors where editor.isDirty {
                guard let object = editor.produceObject() else { continue }
                await save(object, origin: editorOrigins[identifier] ?? .content)
                editor.markSaved()
            }
            updateTabTitles()
        }
    }

    @objc func closeActiveTab() {
        guard let tab = tabView.selectedTabViewItem else { return }
        close(tab: tab)
    }

    @objc func closeAllTabs() {
        for tab in tabView.tabViewItems { close(tab: tab) }
    }

    private func close(tab: NSTabViewItem) {
        guard let identifier = tab.identifier as? String,
              let editor = editors[identifier]
        else {
            tabView.removeTabViewItem(tab)
            return
        }

        if editor.isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(editor.object.name)”?"
            alert.informativeText = "Your changes will be lost if you do not save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn: saveActive()
            case .alertThirdButtonReturn: return
            default: break
            }
        }
        editors = editors.filter { $0.value !== editor }
        tabView.removeTabViewItem(tab)
        updateTabTitles()
    }

    @objc func newContent(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        let objects: [PrimeObject]
        switch menuItem.tag {
        case 0:
            let name = promptForText(title: "New Folder", message: "Name for the folder.", in: window) ?? "New Folder"
            try? FileManager.default.createDirectory(
                at: model.workingFolder.contentURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
            model.reloadContent()
            modelChanged()
            return
        case 1:
            let name = promptForText(title: "New Program", message: "The calculator shows this name in the Program Catalog.", in: window) ?? "NewProgram"
            let program = PrimeProgramTemplate.sources.first!
            let content = (try? PrimeProgramFile.encode(source: program.body, name: name))
                ?? PrimeTextContent.encode(program.body)
            objects = [PrimeObject(name: name, type: .program, content: content)]
        case 2:
            let name = promptForText(title: "New Note", message: "Name for the note.", in: window) ?? "NewNote"
            objects = [PrimeObject(name: name, type: .note, content: PrimeNoteFile.encode(text: "", reusing: nil, isAppNote: false))]
        case 3:
            let name = promptForText(title: "New Exam Mode", message: "Name for the configuration.", in: window) ?? "New Exam Mode"
            // A configuration needs a trailer this app cannot mint, so it is
            // created from the one the calculator ships with when it is available.
            let template = (try? model.workingFolder.contentObjects())?
                .first { $0.type == .examConfiguration }
            if let template, let decoded = try? PrimeExamModeFile.decode(template.content) {
                let encoded = PrimeExamModeFile.encode(name: name, reusing: decoded)
                objects = [PrimeObject(name: name, type: .examConfiguration, content: encoded.bytes)]
            } else {
                let encoded = PrimeExamModeFile.encode(name: name, reusing: nil)
                objects = [PrimeObject(name: name, type: .examConfiguration, content: encoded.bytes)]
            }
        default:
            return
        }

        for object in objects {
            model.saveToContent(object)
            open(object)
        }
    }

    @objc func showPreferences() {
        PreferencesWindowController.present(model: model, parent: window)
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Prime Connection Kit"
        alert.informativeText = """
        A native macOS replacement for HP Connectivity Kit.

        Manages HP Prime calculators over USB: reads and edits their content, \
        captures their screens, backs them up, restores and clones them, and \
        sends messages to a class.

        Working folder: \(model.workingFolder.root.path)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Classroom windows

    @objc func toggleMonitor() {
        if let monitorWindow, monitorWindow.isVisible {
            monitorWindow.orderOut(nil)
            return
        }
        let controller = monitorController ?? MonitorViewController(model: model)
        monitorController = controller
        controller.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.classroomSelection = controller.selectedCalculators
            self.updateMenus()
        }
        let window = makeUtilityWindow(title: "Monitor", content: controller.view, size: NSSize(width: 720, height: 500))
        monitorWindow = window
        controller.reload()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func toggleMessages() {
        if let messagesWindow, messagesWindow.isVisible {
            messagesWindow.orderOut(nil)
            return
        }
        let controller = messagesController ?? MessagesViewController(model: model)
        messagesController = controller
        controller.recipientsProvider = { [weak self] in self?.monitorController?.recipients ?? [] }
        let window = makeUtilityWindow(title: "Messages", content: controller.view, size: NSSize(width: 560, height: 380))
        messagesWindow = window
        controller.updateRecipients()
        window.makeKeyAndOrderFront(nil)
    }

    @objc func toggleProctor() {
        if let proctorWindow, proctorWindow.isVisible {
            proctorWindow.orderOut(nil)
            return
        }
        let controller = proctorController ?? ProctorViewController(model: model)
        proctorController = controller
        let window = makeUtilityWindow(title: "Proctor Mode", content: controller.view, size: NSSize(width: 520, height: 420))
        proctorWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func makeUtilityWindow(title: String, content: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    // MARK: - Drag and drop

    /// Where a drop landed.
    enum DropDestination {
        case calculator
        case content
    }

    /// Handles content dropped onto a pane.
    ///
    /// Two things can arrive: an object dragged from the other pane, which is
    /// resolved through the model and then copied, and a file dragged in from
    /// Finder, which is imported by its extension. Importing is the only way to
    /// bring in content produced elsewhere, so an unrecognised file is reported
    /// rather than ignored.
    private func handleDrop(
        payloads: [PrimeDragPayload],
        fileURLs: [URL],
        onto node: PaneNode?,
        destination: DropDestination
    ) -> Bool {
        var handled = false

        // Objects dragged from the other pane.
        for payload in payloads {
            guard let type = payload.fileType else { continue }
            guard let object = resolve(payload: payload, type: type) else {
                model.status("“\(payload.name)” could not be found.")
                continue
            }

            switch destination {
            case .calculator:
                // Send to the calculator the drop landed on, falling back to the
                // selection.
                guard let entry = node?.calculator ?? calculatorPane.selectedCalculators.first else {
                    model.status("Drop onto a calculator to send content to it.")
                    continue
                }
                Task { @MainActor in await model.save(object, to: entry) }
            case .content:
                model.saveToContent(object)
            }
            handled = true
        }

        // Files dragged in from Finder.
        let imported = importFiles(fileURLs, destination: destination, node: node)
        return handled || imported
    }

    /// Finds the object a drag payload refers to.
    private func resolve(payload: PrimeDragPayload, type: PrimeFileType) -> PrimeObject? {
        let pool = model.contentObjects
            + model.calculators.flatMap { entry in
                entry.isAttached ? entry.deviceObjects : model.mirroredObjects(for: entry.name)
            }
        return pool.first { $0.name == payload.name && $0.type == type }
    }

    /// Imports files from Finder.
    ///
    /// The extension decides the content type, which is the same rule the
    /// Connectivity Kit applies when content is dragged into it.
    private func importFiles(_ urls: [URL], destination: DropDestination, node: PaneNode?) -> Bool {
        guard !urls.isEmpty else { return false }

        var imported: [PrimeObject] = []
        var rejected: [String] = []

        for url in urls {
            do {
                imported.append(contentsOf: try readContent(at: url))
            } catch {
                rejected.append("\(url.lastPathComponent): \(WorkspaceModel.describe(error))")
            }
        }

        guard !rejected.isEmpty == false else {
            model.status("Nothing could be imported — " + rejected.joined(separator: "; "))
            return false
        }

        switch destination {
        case .content:
            for object in imported { model.saveToContent(object) }
        case .calculator:
            guard let entry = node?.calculator ?? calculatorPane.selectedCalculators.first else {
                // Without a target calculator the files are still worth keeping.
                for object in imported { model.saveToContent(object) }
                model.status("Imported \(imported.count) item(s) into the content folder; drop onto a calculator to send them.")
                return true
            }
            for object in imported {
                Task { @MainActor in await model.save(object, to: entry) }
            }
        }

        model.status("Imported \(imported.count) item(s)"
            + (rejected.isEmpty ? "" : "; skipped — " + rejected.joined(separator: "; ")))
        return true
    }

    /// Reads a dropped file, or a directory of content, into objects.
    private func readContent(at url: URL) throws -> [PrimeObject] {
        let manager = FileManager.default

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HPLinkError.malformedContent("the file no longer exists")
        }

        // An `.hpappdir` is a whole application package.
        if isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "hpappdir" else {
                // A plain folder is scanned for content, which is how a folder
                // exported from another computer is brought in.
                return try PrimeWorkingFolder(root: url).contentObjects()
            }
            var objects: [PrimeObject] = []
            for entry in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                if let object = try? readSingleFile(at: entry) { objects.append(object) }
            }
            guard !objects.isEmpty else {
                throw HPLinkError.malformedContent("the application package is empty")
            }
            return objects
        }

        return [try readSingleFile(at: url)]
    }

    /// Reads one content file, deriving its type from its name.
    private func readSingleFile(at url: URL) throws -> PrimeObject {
        guard let type = PrimeWorkingFolder.contentType(for: url) else {
            throw HPLinkError.malformedContent("“\(url.lastPathComponent)” is not a calculator content type")
        }
        let parsed = PrimeObjectName.parse(diskName: url.lastPathComponent, type: type)
        return PrimeObject(
            name: parsed.name,
            type: type,
            isBuiltIn: parsed.isBuiltIn
                || (type == .application && PrimeWorkingFolder.builtInAppNames().contains(parsed.name))
                || (type == .examConfiguration && parsed.name == PrimeWorkingFolder.builtInExamConfigurationName),
            content: Array(try Data(contentsOf: url))
        )
    }

    /// The menu for a row in the calculator pane.
    func calculatorMenu(forRow row: Int) -> NSMenu? {
        guard let node = calculatorPane.node(at: row) else { return nil }

        let menu = NSMenu()

        if let entry = node.calculator {
            if entry.isAttached {
                menu.addItem(withTitle: "Refresh", action: #selector(refreshCalculator), keyEquivalent: "")
                    .target = self
                menu.addItem(withTitle: "Get Screen Capture", action: #selector(captureScreen), keyEquivalent: "")
                    .target = self
                menu.addItem(.separator())
                menu.addItem(withTitle: "Backup…", action: #selector(backUpCalculator), keyEquivalent: "")
                    .target = self
                menu.addItem(withTitle: "Restore…", action: #selector(restoreCalculator), keyEquivalent: "")
                    .target = self
                menu.addItem(withTitle: "Clone From Here", action: #selector(cloneFrom), keyEquivalent: "")
                    .target = self
                menu.addItem(.separator())
                menu.addItem(withTitle: "Properties", action: #selector(showProperties), keyEquivalent: "")
                    .target = self
                menu.addItem(withTitle: "Rename…", action: #selector(renameCalculator), keyEquivalent: "")
                    .target = self
                menu.addItem(.separator())
                menu.addItem(withTitle: "Disconnect", action: #selector(disconnectCalculator), keyEquivalent: "")
                    .target = self
                menu.addItem(withTitle: "Set Clock from Computer", action: #selector(syncClock), keyEquivalent: "")
                    .target = self
            } else {
                menu.addItem(withTitle: "Connect", action: #selector(connectCalculator), keyEquivalent: "")
                    .target = self
                menu.addItem(withTitle: "Clone To Here", action: #selector(cloneTo), keyEquivalent: "")
                    .target = self
            }
            return menu
        }

        if let object = node.objectValue {
            menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Send to Class", action: #selector(sendToClass), keyEquivalent: "")
                .target = self
            if object.isDeletable {
                menu.addItem(withTitle: "Delete", action: #selector(deleteObject), keyEquivalent: "")
                    .target = self
            }
            if object.isClearable {
                menu.addItem(withTitle: "Clear", action: #selector(clearObject), keyEquivalent: "")
                    .target = self
            }
            return menu
        }

        return nil
    }

    /// The menu for a row in the content pane.
    func contentMenu(forRow row: Int) -> NSMenu? {
        guard let node = contentPane.node(at: row) else { return nil }
        let menu = NSMenu()

        if let object = node.objectValue {
            menu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Send to Class", action: #selector(sendToClass), keyEquivalent: "")
                .target = self
            if object.type == .examConfiguration {
                menu.addItem(withTitle: "Proctor Mode", action: #selector(useProctorMode), keyEquivalent: "")
                    .target = self
            }
            if object.isDeletable {
                menu.addItem(withTitle: "Delete", action: #selector(deleteObject), keyEquivalent: "")
                    .target = self
            }
            return menu
        }

        menu.addItem(withTitle: "New Folder…", action: #selector(newContent(_:)), keyEquivalent: "").tag = 0
        menu.items.last?.target = self
        return menu
    }

    // MARK: - Command implementations

    /// The calculator a command applies to: the selected calculator row, or the
    /// owner of the selected object row.
    private var targetCalculator: CalculatorEntry? {
        calculatorPane.selectedCalculators.first ?? calculatorPane.selectionOwner
    }

    @objc private func connectCalculator() {
        guard let entry = targetCalculator else { return }
        Task { @MainActor in await model.connect(entry) }
    }

    @objc private func disconnectCalculator() {
        guard let entry = targetCalculator else { return }
        model.disconnect(entry)
    }

    @objc private func refreshCalculator() {
        guard let entry = targetCalculator else { return }
        Task { @MainActor in await model.refresh(entry) }
    }

    @objc private func captureScreen() {
        guard let entry = targetCalculator else { return }
        Task { @MainActor in
            guard let bytes = await model.captureScreen(from: entry) else { return }
            ScreenshotExport.show(bytes: bytes, suggestedName: entry.name, in: window)
        }
    }

    @objc private func backUpCalculator() {
        guard let entry = targetCalculator else { return }
        Task { @MainActor in
            guard let url = await model.backUp(entry) else { return }
            let alert = NSAlert()
            alert.messageText = "Backup complete"
            alert.informativeText = "Saved to \(url.path)"
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    @objc private func restoreCalculator() {
        guard let entry = targetCalculator else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = model.workingFolder.backupsURL
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in await model.restore(entry, from: url) }
    }

    private var cloneSource: CalculatorEntry?

    @objc private func cloneFrom() {
        cloneSource = targetCalculator
        model.status("Cloning will apply to the next calculator you choose “Clone To Here” on.")
        modelChanged()
    }

    @objc private func cloneTo() {
        guard let destination = targetCalculator else { return }
        guard let source = cloneSource else {
            let alert = NSAlert()
            alert.messageText = "Choose a source first"
            alert.informativeText = "Use “Clone From Here” on the calculator whose contents you want to copy."
            alert.runModal()
            return
        }
        Task { @MainActor in
            await model.clone(from: source, to: destination)
            cloneSource = nil
        }
    }

    @objc private func showProperties() {
        guard let entry = targetCalculator else { return }
        let alert = NSAlert()
        alert.messageText = entry.name
        if let information = entry.information {
            alert.informativeText = information.summaryLines
                .map { "\($0.0): \($0.1)" }
                .joined(separator: "\n")
        } else {
            alert.informativeText = entry.lastError ?? "No information has been read from this calculator yet."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func renameCalculator() {
        guard let entry = targetCalculator else { return }
        guard let name = promptForText(
            title: "Rename Calculator",
            message: "This renames the local folder. The name shown on the calculator is set in Home Settings page 2.",
            defaultValue: entry.name,
            in: window
        ) else { return }
        Task { @MainActor in await model.rename(entry, to: name) }
    }

    @objc private func syncClock() {
        guard let entry = targetCalculator else { return }
        Task { @MainActor in
            try? entry.session?.setDateTime(Date())
            model.status("Clock sent to \(entry.name)")
            modelChanged()
        }
    }

    @objc private func sendToClass() {
        let objects = contentPane.selectedObjects + calculatorPane.selectedObjects
        guard let object = objects.first else { return }
        Task { @MainActor in await model.sendToClass(object) }
    }

    @objc private func deleteObject() {
        if let entry = targetCalculator, let object = calculatorPane.selectedObjects.first {
            Task { @MainActor in await model.delete(object, from: entry) }
        } else if let object = contentPane.selectedObjects.first {
            try? model.workingFolder.deleteFromContent(object)
            model.reloadContent()
            modelChanged()
        }
    }

    @objc private func clearObject() {
        guard let entry = targetCalculator, let object = calculatorPane.selectedObjects.first else { return }
        var cleared = object
        cleared.content = []
        Task { @MainActor in await model.save(cleared, to: entry) }
    }

    @objc private func useProctorMode() {
        guard let configuration = contentPane.selectedObjects.first(where: { $0.type == .examConfiguration }) else { return }
        toggleProctor()
        proctorController?.configuration = configuration
        Task { @MainActor in await proctorController?.applyToConnected() }
    }

    // MARK: - Menu building

    /// Builds the standard menu bar, mirroring the Connectivity Kit's four menus.
    static func makeMenuBar(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        // Application menu.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Prime Connection Kit", action: #selector(showAbout), keyEquivalent: "")
            .target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
            .target = target
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Prime Connection Kit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu: New, Save, Save All, Close, Close All.
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let newMenu = NSMenu()
        for (index, title) in ["Folder…", "Program…", "Note…", "Exam Mode…"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(newContent(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            newMenu.addItem(item)
        }
        newItem.submenu = newMenu
        fileMenu.addItem(newItem)
        fileMenu.addItem(withTitle: "Open", action: #selector(openSelected), keyEquivalent: "o").target = target
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(saveActive), keyEquivalent: "s").target = target
        fileMenu.addItem(withTitle: "Save All", action: #selector(saveAll), keyEquivalent: "S").target = target
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Backup Calculator…", action: #selector(backUpCalculator), keyEquivalent: "").target = target
        fileMenu.addItem(withTitle: "Restore Calculator…", action: #selector(restoreCalculator), keyEquivalent: "").target = target
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(closeActiveTab), keyEquivalent: "w").target = target
        fileMenu.addItem(withTitle: "Close All", action: #selector(closeAllTabs), keyEquivalent: "W").target = target
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu: the standard responder-chain editing commands.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu: panes and classroom windows.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Monitor", action: #selector(toggleMonitor), keyEquivalent: "m").target = target
        windowMenu.addItem(withTitle: "Messages", action: #selector(toggleMessages), keyEquivalent: "M").target = target
        windowMenu.addItem(withTitle: "Proctor Mode", action: #selector(toggleProctor), keyEquivalent: "").target = target
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu

        // Help menu.
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Prime Connection Kit Help", action: #selector(showAbout), keyEquivalent: "?").target = target
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        return mainMenu
    }

    // MARK: - Unsaved work

    /// Whether any editor holds unsaved changes.
    var hasUnsavedWork: Bool { editors.values.contains(where: \.isDirty) }

    /// Asks to save before the app closes.
    func reviewUnsavedWork() -> Bool {
        guard hasUnsavedWork else { return true }

        let alert = NSAlert()
        alert.messageText = "Save your work before closing?"
        alert.informativeText = "Some editors have unsaved changes."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveAll()
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

extension MainWindowController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateTabTitles()
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .init("connect"), .init("save"), .init("saveAll"), .flexibleSpace,
            .init("screen"), .init("monitor"), .init("messages"), .init("proctor"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let specs: [String: (label: String, symbol: String, action: Selector)] = [
            "connect": ("Connect", "cable.connector", #selector(connectCalculator)),
            "save": ("Save", "square.and.arrow.down", #selector(saveActive)),
            "saveAll": ("Save All", "square.and.arrow.down.on.square", #selector(saveAll)),
            "screen": ("Screen Capture", "camera", #selector(captureScreen)),
            "monitor": ("Monitor", "rectangle.grid.2x2", #selector(toggleMonitor)),
            "messages": ("Messages", "bubble.left.and.bubble.right", #selector(toggleMessages)),
            "proctor": ("Proctor Mode", "lock.shield", #selector(toggleProctor)),
        ]
        guard let spec = specs[identifier.rawValue] else { return nil }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = self
        item.action = spec.action
        return item
    }
}

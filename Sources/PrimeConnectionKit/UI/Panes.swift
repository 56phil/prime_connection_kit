import AppKit
import HPLink

/// A row in either pane's outline.
@MainActor
final class PaneNode {
    enum Kind {
        /// A calculator, with the device it came from when attached.
        case calculator(CalculatorEntry)
        /// A content category such as Real or Programs.
        case category(PrimeFileType)
        /// A named folder in the content pane.
        case folder(String)
        /// A content object.
        case object(PrimeObject)
    }

    let kind: Kind
    var children: [PaneNode]
    /// Whether the row shows an expansion arrow.
    var isExpandable: Bool { !children.isEmpty }

    init(kind: Kind, children: [PaneNode] = []) {
        self.kind = kind
        self.children = children
    }

    var title: String {
        switch kind {
        case .calculator(let entry): entry.name
        case .category(let type): Self.categoryTitle(type)
        case .folder(let name): name
        case .object(let object): object.name
        }
    }

    var icon: NSImage? {
        switch kind {
        case .calculator: ContentIcons.calculator
        case .category(let type): ContentIcons.image(for: type)
        case .folder(let name):
            NSImage(systemSymbolName: name == "Results" ? "chart.bar" : "folder", accessibilityDescription: name)
        case .object(let object): ContentIcons.image(for: object.type)
        }
    }

    var objectValue: PrimeObject? {
        if case .object(let object) = kind { return object }
        return nil
    }

    var calculator: CalculatorEntry? {
        if case .calculator(let entry) = kind { return entry }
        return nil
    }

    /// A category's display name. These follow the Connectivity Kit's own list of
    /// content types.
    static func categoryTitle(_ type: PrimeFileType) -> String {
        switch type {
        case .application: "Application Library"
        case .real: "Real (vars)"
        case .complex: "Complex (vars)"
        case .list: "List"
        case .matrix: "Matrices"
        case .note: "Notes"
        case .program: "Programs"
        case .examConfiguration: "Exam Configurations"
        default: type.displayName
        }
    }
}

/// An outline view that reports context-menu targets to its owner.
@MainActor
final class PaneOutlineView: NSOutlineView {
    /// Called with the row under the pointer and the event, so the owner can
    /// build a menu for whatever was clicked.
    var menuProvider: ((Int, NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        return menuProvider?(row, event)
    }
}

/// The pasteboard type used for calculator content dragged within the app.
///
/// A custom type keeps the drag payload explicit, so an unrelated text drag is
/// not mistaken for content.
extension NSPasteboard.PasteboardType {
    static let primeObject = NSPasteboard.PasteboardType("com.primeconnectionkit.object")
}

/// The content a drag carries, encoded into the pasteboard.
///
/// Only identifying information travels — the object's name and type, plus the
/// calculator folder it came from. The receiving pane resolves that back through
/// the app's model, so a drag can never smuggle a stale copy of the bytes.
struct PrimeDragPayload: Codable, Sendable {
    var name: String
    var type: UInt8
    /// The calculator the object came from, when it was dragged from one.
    var calculatorName: String?

    init(object: PrimeObject, calculatorName: String?) {
        name = object.name
        type = object.type.rawValue
        self.calculatorName = calculatorName
    }

    var fileType: PrimeFileType? { PrimeFileType(rawValue: type) }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> PrimeDragPayload? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Shared behaviour for the calculator and content panes.
@MainActor
class PaneController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outlineView = PaneOutlineView()
    let scrollView = NSScrollView()
    var rootNodes: [PaneNode] = []
    /// Called when the selection changes, so the window can update its menus.
    var onSelectionChange: (() -> Void)?
    /// Called when something is dropped onto the pane.
    ///
    /// The pane knows *what* was dropped but not what to do with it, so the
    /// window supplies the behaviour. Returning `false` rejects the drop.
    var onDrop: ((_ payloads: [PrimeDragPayload], _ fileURLs: [URL], _ node: PaneNode?) -> Bool)?

    /// Objects currently selected.
    var selectedObjects: [PrimeObject] {
        outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? PaneNode)?.objectValue
        }
    }

    /// The calculators currently selected.
    var selectedCalculators: [CalculatorEntry] {
        outlineView.selectedRowIndexes.compactMap { row in
            (outlineView.item(atRow: row) as? PaneNode)?.calculator
        }
    }

    /// The calculator a row belongs to, found by walking the tree.
    ///
    /// Selecting an object row does not select the calculator row above it, so the
    /// owner cannot be read from the selection. It has to be found by locating the
    /// row's root, which is what decides where an object is saved.
    func owningCalculator(ofRow row: Int) -> CalculatorEntry? {
        guard let node = self.node(at: row) else { return nil }
        if let entry = node.calculator { return entry }
        for root in rootNodes {
            guard let entry = root.calculator else { continue }
            if contains(root, node) { return entry }
        }
        return nil
    }

    /// The calculator owning the current selection, if any.
    var selectionOwner: CalculatorEntry? {
        for row in outlineView.selectedRowIndexes {
            if let entry = owningCalculator(ofRow: row) { return entry }
        }
        return nil
    }

    /// Whether `root` contains `target` anywhere in its subtree.
    private func contains(_ root: PaneNode, _ target: PaneNode) -> Bool {
        if root === target { return true }
        return root.children.contains { contains($0, target) }
    }

    /// The node at a row, if any.
    func node(at row: Int) -> PaneNode? {
        row >= 0 ? outlineView.item(atRow: row) as? PaneNode : nil
    }

    override init() {
        super.init()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.rowHeight = Theme.rowHeight
        outlineView.style = .sourceList
        outlineView.allowsMultipleSelection = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        // The panes act as a drag source: an object row is dragged to the other
        // pane, or to the Monitor window, to copy it. Calculator rows are not
        // draggable, because there is nowhere meaningful to drop one.
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outlineView.setDraggingSourceOperationMask([.copy], forLocal: false)

        // And as a drop target: a file dragged in from Finder, or an object
        // dragged from the other pane, is imported here.
        outlineView.registerForDraggedTypes([
            .primeObject,
            .fileURL,
        ])
    }

    // MARK: - Dragging out

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? PaneNode, let object = node.objectValue else { return nil }

        let payload = PrimeDragPayload(object: object, calculatorName: calculatorName(for: node))
        guard let data = payload.encoded() else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .primeObject)
        return pasteboardItem
    }

    /// The calculator a node belongs to, found by walking up to the root.
    private func calculatorName(for node: PaneNode) -> String? {
        if let entry = node.calculator { return entry.name }
        for root in rootNodes {
            guard let entry = root.calculator else { continue }
            if contains(root, node) { return entry.name }
        }
        return nil
    }

    // MARK: - Dropping in

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        // Anywhere in the pane is a valid target; the destination is chosen from
        // what was dropped, not from the row it landed on.
        guard onDrop != nil else { return [] }
        guard info.draggingPasteboard.availableType(from: [.primeObject, .fileURL]) != nil else { return [] }
        return .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let onDrop else { return false }

        let pasteboard = info.draggingPasteboard

        // Objects dragged from the other pane.
        var payloads: [PrimeDragPayload] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let data = item.data(forType: .primeObject),
                   let payload = PrimeDragPayload.decode(data) {
                    payloads.append(payload)
                }
            }
        }

        // Files dragged in from Finder.
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []

        guard !payloads.isEmpty || !urls.isEmpty else { return false }
        return onDrop(payloads, urls, node(at: outlineView.selectedRow))
    }

    /// Replaces the tree, preserving which rows were expanded.
    ///
    /// Folders and content categories start expanded, so content is visible
    /// without hunting for disclosure triangles, while calculator rows start
    /// collapsed because their subtrees are large.
    func setRootNodes(_ nodes: [PaneNode]) {
        let expanded = Set((0..<outlineView.numberOfRows).filter { outlineView.isItemExpanded(outlineView.item(atRow: $0)) }
            .compactMap { outlineView.item(atRow: $0) as? PaneNode }
            .map(\.title))
        let selected = outlineView.selectedRowIndexes.compactMap { (outlineView.item(atRow: $0) as? PaneNode)?.title }

        rootNodes = nodes
        outlineView.reloadData()

        func expand(_ node: PaneNode, isRoot: Bool) {
            switch node.kind {
            case .folder, .category:
                outlineView.expandItem(node)
            case .calculator:
                // A calculator row is only re-expanded if it was before.
                if expanded.contains(node.title) { outlineView.expandItem(node) }
            case .object:
                break
            }
            for child in node.children { expand(child, isRoot: false) }
        }
        for node in nodes { expand(node, isRoot: true) }

        // Restore selection by title, which is enough because titles are unique
        // within a pane.
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? PaneNode else { continue }
            if selected.contains(node.title) { outlineView.selectRowIndexes([row], byExtendingSelection: true) }
        }
    }

    // MARK: - Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? PaneNode else { return rootNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? PaneNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? PaneNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PaneNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)

        cell.textField?.stringValue = node.title
        cell.imageView?.image = node.icon
        cell.imageView?.contentTintColor = .secondaryLabelColor

        // A calculator shows a badge when it needs help, matching the
        // Connectivity Kit's blue question mark.
        if let entry = node.calculator {
            cell.toolTip = entry.lastError
                ?? (entry.isAttached ? "Connected" : "Not connected")
            cell.textField?.textColor = entry.isAttached ? .labelColor : .secondaryLabelColor
        } else {
            cell.toolTip = nil
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = Theme.labelFont
        textField.lineBreakMode = .byTruncatingTail
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: Theme.iconSize.width),
            imageView.heightAnchor.constraint(equalToConstant: Theme.iconSize.height),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?()
    }
}

/// The calculator pane: attached devices and their contents.
///
/// Categories whose contents are known to the calculator's fixed naming scheme
/// (Real, Complex, List, Matrices) are always shown, because their names are part
/// of the platform. Categories whose contents are discovered from the device
/// (Applications, Notes, Programs, Exam Configurations) appear only when
/// something is present, matching the Connectivity Kit's behaviour of hiding an
/// expansion arrow when there is nothing inside.
@MainActor
final class CalculatorPaneController: PaneController {
    /// Builds the tree from the model.
    func update(with model: WorkspaceModel) {
        let nodes = model.calculators.map { entry -> PaneNode in
            PaneNode(kind: .calculator(entry), children: categories(for: entry, model: model))
        }
        setRootNodes(nodes)
    }

    private func categories(for entry: CalculatorEntry, model: WorkspaceModel) -> [PaneNode] {
        // Prefer what the device reported; fall back to the mirror on disk, which
        // is what the Connectivity Kit shows for a calculator that is offline.
        let objects = entry.isAttached ? entry.deviceObjects : model.mirroredObjects(for: entry.name)

        let order: [PrimeFileType] = [
            .application, .real, .complex, .list, .matrix, .note, .program, .examConfiguration,
        ]

        var result: [PaneNode] = []
        for type in order {
            let matching = objects.filter { $0.type == type }
            if matching.isEmpty, !Self.alwaysShown.contains(type) { continue }
            let children = matching
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { PaneNode(kind: .object($0)) }
            result.append(PaneNode(kind: .category(type), children: children))
        }
        return result
    }

    /// Categories the calculator always provides, even when empty.
    private static let alwaysShown: Set<PrimeFileType> = [
        .application, .real, .complex, .list, .matrix, .examConfiguration,
    ]
}

/// The content pane: the working folder's authored content.
@MainActor
final class ContentPaneController: PaneController {
    func update(with model: WorkspaceModel) {
        // Group by the on-disk folder the object came from, so the pane mirrors
        // the folder the user sees in Finder.
        var folders: [String: [PrimeObject]] = [:]
        for object in model.contentObjects {
            folders[Self.folderName(for: object), default: []].append(object)
        }

        let order = ["Exam Modes", "Results", "Notes", "Programs"]
        var nodes: [PaneNode] = []
        for name in order where folders[name] != nil {
            nodes.append(folder(name, objects: folders.removeValue(forKey: name)!))
        }
        for (name, objects) in folders.sorted(by: { $0.key < $1.key }) {
            nodes.append(folder(name, objects: objects))
        }

        // Loose files at the root of the content folder get their own section.
        setRootNodes(nodes)
    }

    private func folder(_ name: String, objects: [PrimeObject]) -> PaneNode {
        PaneNode(
            kind: .folder(name),
            children: objects
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { PaneNode(kind: .object($0)) }
        )
    }

    /// The section an object belongs to in the content pane.
    private static func folderName(for object: PrimeObject) -> String {
        switch object.type {
        case .examConfiguration: "Exam Modes"
        case .note, .appNote: "Notes"
        case .program, .appProgram: "Programs"
        default: object.type.displayName
        }
    }
}

import AppKit
import HPLink

/// A spreadsheet-like grid for numeric content: real and complex variables,
/// lists, and matrices.
///
/// ``NSTableView`` is used rather than ``NSCollectionView`` because these editors
/// are two-dimensional arrays with keyboard traversal, which a table with a
/// column per value handles directly. Two shapes are supported:
///
/// * **key–value** — one column of names and one of values, for Home variables;
/// * **matrix** — a grid whose dimensions follow the data.
///
/// Committed edits are reported through ``onChange``, so the owning editor can
/// mark itself dirty rather than saving on every keystroke.
@MainActor
final class VariableGridView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// One row: a label and a list of cell values rendered as text.
    struct Row {
        var label: String
        var cells: [String]
    }

    enum Shape {
        /// Two columns: names and values.
        case keyValue
        /// `columnCount` value columns, with no name column.
        case grid(columnCount: Int)
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let shape: Shape
    private var rows: [Row] = []
    /// The cell being edited, so it can be read back when editing ends.
    private weak var activeField: NSTextField?

    /// Called with the row index and cell index when a value is committed.
    var onChange: ((Int, Int) -> Void)?
    /// Supplies the value shown in a cell, used to re-read after an edit.
    var valueProvider: ((Int, Int) -> String)?

    init(shape: Shape) {
        self.shape = shape
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = Theme.rowHeight
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        switch shape {
        case .keyValue:
            addColumn(identifier: "name", title: "Variable", width: 110)
            addColumn(identifier: "value", title: "Value", width: 200)
        case .grid(let columnCount):
            for index in 0..<max(columnCount, 1) {
                addColumn(identifier: "c\(index)", title: "\(index + 1)", width: 84)
            }
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        embed(scrollView)
    }

    private func addColumn(identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 48
        tableView.addTableColumn(column)
    }

    /// Replaces the displayed rows.
    func setRows(_ newRows: [Row]) {
        rows = newRows
        tableView.reloadData()
    }

    /// The current rows, including any edits.
    var currentRows: [Row] { rows }

    /// Rebuilds the columns for a new grid width, used when a matrix resizes.
    func setColumnCount(_ count: Int) {
        guard case .grid = shape else { return }
        while tableView.tableColumns.count > count {
            tableView.removeTableColumn(tableView.tableColumns.last!)
        }
        while tableView.tableColumns.count < count {
            let index = tableView.tableColumns.count
            addColumn(identifier: "c\(index)", title: "\(index + 1)", width: 84)
        }
        tableView.reloadData()
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }

        let identifier = tableColumn.identifier
        let cell = CellView()
        cell.field.delegate = self
        cell.field.font = Theme.bodyFont

        switch shape {
        case .keyValue:
            if identifier.rawValue == "name" {
                cell.field.isEditable = false
                cell.field.stringValue = rows[row].label
                cell.field.textColor = .labelColor
            } else {
                cell.field.isEditable = true
                cell.field.stringValue = rows[row].cells.first ?? ""
            }
        case .grid:
            let index = tableView.tableColumns.firstIndex(of: tableColumn) ?? 0
            cell.field.isEditable = true
            cell.field.stringValue = index < rows[row].cells.count ? rows[row].cells[index] : ""
        }

        cell.field.identifier = NSUserInterfaceItemIdentifier("\(row):\(columnIndex(of: tableColumn))")
        return cell
    }

    private func columnIndex(of tableColumn: NSTableColumn) -> Int {
        switch shape {
        case .keyValue:
            return tableColumn.identifier.rawValue == "value" ? 0 : -1
        case .grid:
            return tableView.tableColumns.firstIndex(of: tableColumn) ?? 0
        }
    }

    /// Parses the "row:column" identifier a cell carries.
    private func coordinates(of field: NSTextField) -> (row: Int, column: Int)? {
        guard let raw = field.identifier?.rawValue else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let row = Int(parts[0]), let column = Int(parts[1]) else { return nil }
        return (row, column)
    }

    // MARK: - Editing

    func controlTextDidBeginEditing(_ notification: Notification) {
        activeField = notification.object as? NSTextField
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let position = coordinates(of: field)
        else { return }

        // Reject input that is not a number, keeping the previous value, so the
        // model never has to cope with a half-typed entry.
        guard field.stringValue.isEmpty || HPNumberText.value(from: field.stringValue) != nil else {
            NSSound.beep()
            field.stringValue = valueProvider?(position.row, position.column)
                ?? (position.row < rows.count ? rows[position.row].cells[safe: position.column] ?? "" : "")
            return
        }

        if position.row < rows.count {
            if position.column < rows[position.row].cells.count {
                rows[position.row].cells[position.column] = field.stringValue
            } else if position.column >= 0 {
                while rows[position.row].cells.count <= position.column {
                    rows[position.row].cells.append("")
                }
                rows[position.row].cells[position.column] = field.stringValue
            }
        }
        onChange?(position.row, position.column)
    }

    // MARK: - Commands

    /// Handles the matrix editor's row and column commands.
    @objc func insertRow(_ sender: Any?) {
        rows.append(Row(label: "\(rows.count + 1)", cells: [String](repeating: "0", count: columnCount)))
        tableView.reloadData()
        onChange?(-1, -1)
    }

    @objc func deleteRow(_ sender: Any?) {
        guard tableView.selectedRow >= 0, rows.count > 1 else { return }
        rows.remove(at: tableView.selectedRow)
        tableView.reloadData()
        onChange?(-1, -1)
    }

    @objc func insertColumn(_ sender: Any?) {
        for index in rows.indices { rows[index].cells.append("0") }
        setColumnCount(columnCount + 1)
        onChange?(-1, -1)
    }

    @objc func deleteColumn(_ sender: Any?) {
        guard columnCount > 1 else { return }
        for index in rows.indices where !rows[index].cells.isEmpty {
            rows[index].cells.removeLast()
        }
        setColumnCount(columnCount - 1)
        onChange?(-1, -1)
    }

    private var columnCount: Int {
        switch shape {
        case .keyValue: 1
        case .grid: max(tableView.tableColumns.count, 1)
        }
    }
}

/// A table cell holding one editable text field.
private final class CellView: NSTableCellView {
    let field = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        textField = field
        embed(field, insets: NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

extension Array {
    /// Bounds-checked access, used where a row is shorter than its neighbour.
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}

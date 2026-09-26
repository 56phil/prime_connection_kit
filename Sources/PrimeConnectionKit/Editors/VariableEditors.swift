import AppKit
import HPLink

/// Editor for the Home real and complex variables.
///
/// The values live in one payload per type, so this editor presents every slot
/// the calculator holds rather than one object per variable, matching the
/// Connectivity Kit's Real and Complex editors.
@MainActor
final class VariableSetEditor: BaseEditor {
    private let grid: VariableGridView
    private let names: [String]
    private let isComplex: Bool
    private var values: [Double]
    private var layout: PrimeScalarSetCodec.Layout

    override init(object: PrimeObject) {
        self.isComplex = object.type == .complex
        // The calculator's variable slots: A–Z plus theta for reals, Z0–Z9 for
        // complex values, in the order the Home screen shows them.
        if isComplex {
            names = (0...9).map { "Z\($0)" }
        } else {
            names = (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }
                + ["\u{03B8}"]
        }

        let decoded = PrimeScalarSetCodec.decode(object.content, isComplex: isComplex)
        self.layout = decoded.layout
        // Pad or trim so the editor always shows exactly one row per slot.
        var values = decoded.values
        if values.count < names.count {
            values.append(contentsOf: [Double](repeating: 0, count: names.count - values.count))
        } else if values.count > names.count {
            values = Array(values.prefix(names.count))
        }
        self.values = values

        grid = VariableGridView(shape: .keyValue)
        super.init(object: object)

        grid.setRows(names.enumerated().map { index, name in
            VariableGridView.Row(label: name, cells: [HPNumberText.string(from: values[index])])
        })
        grid.onChange = { [weak self] row, _ in
            guard let self, row >= 0, row < self.values.count else { return }
            let text = self.grid.currentRows[row].cells.first ?? ""
            self.values[row] = HPNumberText.value(from: text) ?? 0
            self.setDirty()
        }
        grid.valueProvider = { [weak self] row, _ in
            guard let self, row < self.values.count else { return "" }
            return HPNumberText.string(from: self.values[row])
        }

        installContent(grid)
        if decoded.layout.valueRanges.isEmpty, !object.content.isEmpty {
            showNotice("This variable set could not be read in the calculator's format, so its values are shown as zero. Editing will replace the payload.")
        }
    }

    override func produceObject() -> PrimeObject? {
        var updated = object
        updated.content = PrimeScalarSetCodec.write(values, into: object.content, layout: layout)
        if layout.valueRanges.isEmpty {
            // No slots were found, so build the container from scratch.
            updated.content = Self.synthesisePayload(values: values, isComplex: isComplex)
        }
        return updated
    }

    /// Builds a payload for a variable set that was not present on the device.
    ///
    /// The container's shape follows the public implementation of the format: a
    /// length word, the type marker, then 16-byte values.
    static func synthesisePayload(values: [Double], isComplex: Bool) -> [UInt8] {
        let marker = isComplex
            ? PrimeScalarSetCodec.complexMarker
            : PrimeScalarSetCodec.realMarker
        let payloadLength = 4 + values.count * HPNumber.wideSize

        var out: [UInt8] = [
            UInt8(payloadLength & 0xFF),
            UInt8((payloadLength >> 8) & 0x0F),
            0x00, 0x00,
        ]
        out.append(contentsOf: marker)
        for value in values {
            out.append(contentsOf: HPNumber.encodeWide(value))
        }
        return out
    }
}

/// Editor for a list variable.
@MainActor
final class ListEditor: BaseEditor {
    private let grid = VariableGridView(shape: .grid(columnCount: 1))
    private var elements: [PrimeListCodec.Element]
    private let isDevicePayload: Bool

    override init(object: PrimeObject) {
        // Content read from the device carries a preamble before the header
        // marker; content read from disk starts at the marker.
        let fromDevice = PrimeListCodec.markerOffset(in: object.content).map { $0 > 0 } ?? false
        self.isDevicePayload = fromDevice

        let decoded = (try? PrimeListCodec.decode(object.content))
            ?? (try? PrimeListCodec.decodeDevicePayload(object.content))
            ?? []
        elements = decoded

        super.init(object: object)
        rebuild()

        grid.onChange = { [weak self] row, _ in
            guard let self, row >= 0, row < self.elements.count else { return }
            let text = self.grid.currentRows[row].cells.first ?? ""
            self.elements[row].real = HPNumberText.value(from: text) ?? 0
            self.setDirty()
        }
        grid.valueProvider = { [weak self] row, _ in
            guard let self, row < self.elements.count else { return "" }
            let element = self.elements[row]
            if let imaginary = element.imaginary {
                return "\(HPNumberText.string(from: element.real))+\(HPNumberText.string(from: imaginary))i"
            }
            return HPNumberText.string(from: element.real)
        }
        installContent(grid)
        if decoded.isEmpty, !object.content.isEmpty {
            showNotice("This list's contents could not be decoded. Saving will replace them.")
        }
    }

    private func rebuild() {
        grid.setRows(elements.enumerated().map { index, element in
            let text: String
            if let imaginary = element.imaginary {
                text = "\(HPNumberText.string(from: element.real))+\(HPNumberText.string(from: imaginary))i"
            } else {
                text = HPNumberText.string(from: element.real)
            }
            return VariableGridView.Row(label: "\(index + 1)", cells: [text])
        })
    }

    override func produceObject() -> PrimeObject? {
        var updated = object
        updated.content = (try? PrimeListCodec.encode(elements)) ?? object.content
        return updated
    }

    /// Appends an element, as pressing Enter past the last cell does.
    func appendElement() {
        elements.append(PrimeListCodec.Element(real: 0))
        rebuild()
        setDirty()
    }
}

/// Editor for a matrix variable.
@MainActor
final class MatrixEditor: BaseEditor {
    private let grid: VariableGridView
    private var matrix: PrimeMatrixCodec.Matrix

    override init(object: PrimeObject) {
        let decoded = (try? PrimeMatrixCodec.decode(object.content))
            ?? (try? PrimeMatrixCodec.decodeDevicePayload(object.content))
            ?? .zeros(rows: 2, columns: 2)
        matrix = decoded
        grid = VariableGridView(shape: .grid(columnCount: max(decoded.columns, 1)))

        super.init(object: object)
        rebuild()

        grid.onChange = { [weak self] _, _ in
            guard let self else { return }
            self.readGrid()
            self.setDirty()
        }
        grid.valueProvider = { [weak self] row, column in
            guard let self else { return "0" }
            return HPNumberText.string(from: self.matrix.cell(row: row, column: column).real)
        }
        installContent(grid)

        if decoded.rows == 2, decoded.columns == 2, object.content.isEmpty {
            showNotice("This matrix has no stored values yet; it starts as a 2×2 grid of zeros.")
        }
    }

    private func rebuild() {
        grid.setColumnCount(max(matrix.columns, 1))
        grid.setRows((0..<matrix.rows).map { row in
            VariableGridView.Row(
                label: "\(row + 1)",
                cells: (0..<matrix.columns).map { column in
                    HPNumberText.string(from: matrix.cell(row: row, column: column).real)
                }
            )
        })
    }

    /// Copies the grid back into the matrix, resizing it to match.
    private func readGrid() {
        let rows = grid.currentRows
        let columns = max(rows.map(\.cells.count).max() ?? 1, 1)
        var cells: [PrimeMatrixCodec.HPNumberPair] = []
        for row in rows {
            for column in 0..<columns {
                let text = row.cells[safe: column] ?? "0"
                cells.append(PrimeMatrixCodec.HPNumberPair(real: HPNumberText.value(from: text) ?? 0))
            }
        }
        matrix = PrimeMatrixCodec.Matrix(
            rows: rows.count,
            columns: columns,
            cells: cells,
            leadingWord: matrix.leadingWord
        )
    }

    override func produceObject() -> PrimeObject? {
        readGrid()
        var updated = object
        updated.content = (try? PrimeMatrixCodec.encode(matrix)) ?? object.content
        return updated
    }
}

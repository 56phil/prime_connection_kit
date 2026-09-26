import Foundation

/// Reader and writer for `.hplist` list variables.
///
/// ## Layout
///
/// | offset | meaning |
/// |--------|---------|
/// | 0      | `0xFE`, `0xFF` |
/// | 2      | `0x16`, `0x00` |
/// | 4      | element count, little-endian `UInt16` |
/// | 6      | `0x00`, `0x00` |
/// | 8      | elements, 16 bytes each |
///
/// Each element is a ``HPNumber`` wide value. A *complex* element occupies two
/// consecutive slots, distinguished by `0x13` in the third byte of the first,
/// which holds the real part; the second holds the imaginary part.
///
/// The header is reproduced from the only public writer of this format. The
/// third element byte is treated as a tag: it is preserved from the file being
/// edited, and only freshly created elements get zero, so a round trip through
/// the editor cannot drop information the format is carrying.
public enum PrimeListCodec {
    /// Fixed header length before the first element.
    static let headerLength = 8

    /// One list element.
    public struct Element: Equatable, Sendable {
        public var real: Double
        public var imaginary: Double?
        /// Tag bytes preserved from the source file; empty for new elements.
        public var tagBytes: [UInt8]

        public init(real: Double, imaginary: Double? = nil, tagBytes: [UInt8] = []) {
            self.real = real
            self.imaginary = imaginary
            self.tagBytes = tagBytes
        }

        public var isComplex: Bool { imaginary != nil }
    }

    /// Decodes list bytes into elements.
    ///
    /// - Throws: ``HPLinkError/malformedContent(_:)`` when the header marker is
    ///   absent, rather than returning a plausible-looking empty list.
    public static func decode(_ bytes: [UInt8]) throws -> [Element] {
        guard bytes.count >= headerLength else {
            throw HPLinkError.malformedContent("the list is shorter than its header")
        }
        guard bytes[0] == 0xFE, bytes[1] == 0xFF, bytes[2] == 0x16, bytes[3] == 0x00 else {
            throw HPLinkError.malformedContent("the list header marker is missing")
        }

        let declaredCount = Int(UInt16(bytes[4]) | (UInt16(bytes[5]) << 8))
        var elements: [Element] = []
        var offset = headerLength

        // Trust the buffer over the declared count: a truncated transfer must not
        // read past the end.
        while elements.count < declaredCount, offset + HPNumber.wideSize <= bytes.count {
            let slice = bytes[offset..<(offset + HPNumber.wideSize)]
            let isComplex = bytes[offset + 2] == 0x13
            let tag = Array(bytes[offset..<(offset + 3)])

            if isComplex, offset + HPNumber.wideSize * 2 <= bytes.count {
                let real = try HPNumber.decodeWide(slice)
                let imaginary = try HPNumber.decodeWide(
                    bytes[(offset + HPNumber.wideSize)..<(offset + HPNumber.wideSize * 2)]
                )
                elements.append(Element(real: real, imaginary: imaginary, tagBytes: tag))
                offset += HPNumber.wideSize * 2
            } else {
                elements.append(Element(real: try HPNumber.decodeWide(slice), tagBytes: tag))
                offset += HPNumber.wideSize
            }
        }
        return elements
    }

    /// Encodes elements into list bytes.
    public static func encode(_ elements: [Element]) throws -> [UInt8] {
        var out: [UInt8] = [0xFE, 0xFF, 0x16, 0x00]
        let count = UInt16(clamping: elements.count)
        out.append(UInt8(count & 0xFF))
        out.append(UInt8(count >> 8))
        out.append(contentsOf: [0x00, 0x00])

        for element in elements {
            var wide = HPNumber.encodeWide(element.real)
            // Restore the source tag bytes so complex markers and any other
            // meaning they carry survive editing.
            for (index, byte) in element.tagBytes.prefix(3).enumerated() {
                wide[index] = byte
            }
            if element.imaginary != nil, wide.count > 2 {
                wide[2] = 0x13
            }
            out.append(contentsOf: wide)

            if let imaginary = element.imaginary {
                out.append(contentsOf: HPNumber.encodeWide(imaginary))
            }
        }
        return out
    }

    /// Decodes bytes returned by the calculator, which may carry a leading tag.
    ///
    /// The device wraps a list in a short preamble before the header marker, so
    /// the marker is located rather than assumed to be at offset zero.
    public static func decodeDevicePayload(_ bytes: [UInt8]) throws -> [Element] {
        if let start = markerOffset(in: bytes) {
            return try decode(Array(bytes[start...]))
        }
        throw HPLinkError.malformedContent("no list header marker was found in the payload")
    }

    /// Index of the `FE FF 16 00` header marker, if present.
    public static func markerOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for start in 0...(bytes.count - 4) {
            if bytes[start] == 0xFE, bytes[start + 1] == 0xFF,
               bytes[start + 2] == 0x16, bytes[start + 3] == 0x00 {
                return start
            }
        }
        return nil
    }
}

/// Reader and writer for `.hpmat` matrix variables.
///
/// ## Layout
///
/// | offset | meaning |
/// |--------|---------|
/// | 0      | `0x01 0x00`, or `0x02 0x00` in some files |
/// | 2      | `0x14` for a real matrix, `0x94` for a complex one |
/// | 3      | `0x80` |
/// | 4      | `0x02 0x00` |
/// | 6      | `0x00 0x00` |
/// | 8      | row count, little-endian `UInt32` |
/// | 12     | column count, little-endian `UInt32` |
/// | 16     | elements, 8 bytes each, row-major |
///
/// Elements are ``HPNumber`` compact values. A complex matrix stores two elements
/// per cell, real part first.
public enum PrimeMatrixCodec {
    /// Fixed header length before the first element.
    static let headerLength = 16

    /// A matrix of values.
    public struct Matrix: Equatable, Sendable {
        public var rows: Int
        public var columns: Int
        /// Row-major cells.
        public var cells: [HPNumberPair]
        /// The first header word, preserved because real files vary between
        /// `0x0001` and `0x0002`.
        public var leadingWord: UInt16

        public init(
            rows: Int,
            columns: Int,
            cells: [HPNumberPair],
            leadingWord: UInt16 = 0x0001
        ) {
            self.rows = rows
            self.columns = columns
            self.cells = cells
            self.leadingWord = leadingWord
        }

        /// Whether any cell carries an imaginary part.
        public var isComplex: Bool { cells.contains(where: \.isComplex) }

        /// The value at a cell, or zero when out of range.
        public func cell(row: Int, column: Int) -> HPNumberPair {
            let index = row * columns + column
            guard index >= 0, index < cells.count else { return HPNumberPair(real: 0) }
            return cells[index]
        }

        /// A matrix of zeros.
        public static func zeros(rows: Int, columns: Int) -> Matrix {
            Matrix(
                rows: rows,
                columns: columns,
                cells: Array(repeating: HPNumberPair(real: 0), count: max(rows * columns, 0))
            )
        }
    }

    /// A numeric cell, optionally complex.
    public struct HPNumberPair: Equatable, Sendable {
        public var real: Double
        public var imaginary: Double?

        public init(real: Double, imaginary: Double? = nil) {
            self.real = real
            self.imaginary = imaginary
        }

        public var isComplex: Bool { imaginary != nil }
    }

    /// Decodes matrix bytes.
    public static func decode(_ bytes: [UInt8]) throws -> Matrix {
        guard bytes.count >= headerLength else {
            throw HPLinkError.malformedContent("the matrix is shorter than its header")
        }

        let typeByte = bytes[2]
        let isComplex = typeByte == 0x94 || (typeByte & 0x80) == 0x80
        let rows = Int(PrimeProgramFile.readUInt32(bytes, at: 8) ?? 0)
        let columns = Int(PrimeProgramFile.readUInt32(bytes, at: 12) ?? 0)
        let leadingWord = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        // Reject an implausible shape rather than allocating from a corrupt file.
        guard rows >= 0, columns >= 0, rows <= 4096, columns <= 4096 else {
            throw HPLinkError.malformedContent("the matrix declares \(rows)×\(columns) cells")
        }

        let elementSize = isComplex ? HPNumber.compactSize * 2 : HPNumber.compactSize
        let available = (bytes.count - headerLength) / elementSize
        let expected = rows * columns
        let count = min(expected, available)

        var cells: [HPNumberPair] = []
        cells.reserveCapacity(expected)
        var offset = headerLength

        for _ in 0..<count {
            let real = try HPNumber.decodeCompact(bytes[offset..<(offset + HPNumber.compactSize)])
            offset += HPNumber.compactSize
            var imaginary: Double?
            if isComplex, offset + HPNumber.compactSize <= bytes.count {
                let value = try HPNumber.decodeCompact(bytes[offset..<(offset + HPNumber.compactSize)])
                offset += HPNumber.compactSize
                // A zero imaginary part is how a real cell is stored in a
                // complex matrix, so it collapses back to a real value.
                if value != 0 { imaginary = value }
            }
            cells.append(HPNumberPair(real: real, imaginary: imaginary))
        }

        // Pad short files so the declared shape is always honoured.
        while cells.count < expected {
            cells.append(HPNumberPair(real: 0))
        }

        return Matrix(rows: rows, columns: columns, cells: cells, leadingWord: leadingWord)
    }

    /// Encodes a matrix.
    public static func encode(_ matrix: Matrix) throws -> [UInt8] {
        // A matrix that holds even one complex value must be stored in the
        // complex form, because a cell only has room for an imaginary part there.
        let complex = matrix.isComplex

        var out: [UInt8] = []
        out.append(UInt8(matrix.leadingWord & 0xFF))
        out.append(UInt8(matrix.leadingWord >> 8))
        out.append(complex ? 0x94 : 0x14)
        out.append(0x80)
        out.append(contentsOf: [0x02, 0x00])
        out.append(contentsOf: [0x00, 0x00])
        PrimeProgramFile.appendUInt32(&out, UInt32(matrix.rows))
        PrimeProgramFile.appendUInt32(&out, UInt32(matrix.columns))

        for row in 0..<matrix.rows {
            for column in 0..<matrix.columns {
                let cell = matrix.cell(row: row, column: column)
                out.append(contentsOf: HPNumber.encodeCompact(cell.real))
                if complex {
                    out.append(contentsOf: HPNumber.encodeCompact(cell.imaginary ?? 0))
                }
            }
        }
        return out
    }

    /// Decodes device payload bytes, locating the header when it is offset.
    public static func decodeDevicePayload(_ bytes: [UInt8]) throws -> Matrix {
        guard bytes.count >= headerLength else { throw HPLinkError.malformedContent("the payload is too short") }
        // A matrix header is recognisable by its type byte; scan for it when the
        // payload carries a preamble.
        for start in 0...(bytes.count - headerLength) {
            let typeByte = bytes[start + 2]
            if (typeByte == 0x14 || typeByte == 0x94 || (typeByte & 0x7F) == 0x14), bytes[start + 3] == 0x80 {
                return try decode(Array(bytes[start...]))
            }
        }
        throw HPLinkError.malformedContent("no matrix header was found in the payload")
    }
}

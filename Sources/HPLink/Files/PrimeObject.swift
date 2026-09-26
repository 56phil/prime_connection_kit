import Foundation

/// One object stored on a calculator or in the working folder.
///
/// Content is kept as raw bytes. The Connectivity Kit stores most object types
/// in formats that are not publicly documented, so round-tripping bytes
/// unchanged is the only way to guarantee that editing one object cannot corrupt
/// it. Types whose formats *are* understood are exposed through dedicated
/// accessors (``PrimeTextContent``, ``PrimeListContent`` and friends).
public struct PrimeObject: Hashable, Sendable, Identifiable {
    /// The object's name on the calculator, without any on-disk decoration.
    public var name: String
    public var type: PrimeFileType
    /// Whether this is a factory object, which can be reset but not deleted.
    public var isBuiltIn: Bool
    /// The object's payload, exactly as stored.
    public var content: [UInt8]

    public var id: String { "\(type.rawValue):\(name)" }

    public init(name: String, type: PrimeFileType, isBuiltIn: Bool = false, content: [UInt8] = []) {
        self.name = name
        self.type = type
        self.isBuiltIn = isBuiltIn
        self.content = content
    }

    /// Whether the object may be deleted. Built-in applications can only be
    /// reset, per the Connectivity Kit user guide.
    public var isDeletable: Bool {
        if type == .application { return !isBuiltIn }
        // At least one exam-mode configuration must always exist; the built-in
        // "Custom Mode" is resettable but not deletable.
        if type == .examConfiguration { return !isBuiltIn }
        return true
    }

    /// Whether the object's contents can be cleared while the object remains.
    public var isClearable: Bool {
        switch type {
        case .list, .matrix, .real, .complex, .note, .program: true
        case .application, .examConfiguration, .appNote, .appProgram, .settings: false
        }
    }
}

/// Text-bearing object content: programs and notes.
///
/// Programs and notes are UTF-16 little-endian, usually with a byte order mark.
/// The calculator rejects a BOM on the wire, so it is stripped when sending and
/// restored when writing to disk, matching the Connectivity Kit's files.
public enum PrimeTextContent {
    /// Decodes a program or note body.
    public static func decode(_ bytes: [UInt8]) -> String {
        var body = bytes
        if body.count >= 2, body[0] == 0xFF, body[1] == 0xFE { body.removeFirst(2) }
        else if body.count >= 2, body[0] == 0xFE, body[1] == 0xFF {
            // Big-endian BOM: swap each pair, then decode.
            body.removeFirst(2)
            var swapped: [UInt8] = []
            swapped.reserveCapacity(body.count)
            var index = 0
            while index + 1 < body.count {
                swapped.append(body[index + 1])
                swapped.append(body[index])
                index += 2
            }
            body = swapped
        }
        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var index = 0
        while index + 1 < body.count {
            units.append(UInt16(body[index]) | (UInt16(body[index + 1]) << 8))
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Encodes a program or note body, with a UTF-16LE byte order mark.
    ///
    /// The Connectivity Kit writes the BOM on disk, and the two-byte size of an
    /// empty app note on disk is exactly that BOM.
    public static func encode(_ text: String) -> [UInt8] {
        [0xFF, 0xFE] + PrimeObjectName.utf16LittleEndian(text)
    }
}

import Foundation

/// Reader and writer for `.hpprgm` program files.
///
/// Two layouts exist in the wild, and this type handles both.
///
/// ## Plain (named) layout
///
/// Verified byte-for-byte against a real `Graphics.hpprgm`:
///
/// | offset | meaning |
/// |--------|---------|
/// | 0      | header size, little-endian `UInt32` |
/// | 4      | reserved, zero |
/// | 8      | name flag, `1` when a name is embedded |
/// | 12     | reserved, zero |
/// | 16     | name marker, `0x0031` |
/// | 18…   | name, UTF-16LE, terminated by `00 00` |
/// | 18+nameBytes | program size, little-endian `UInt32` |
/// | …      | program text, UTF-16LE |
///
/// The real file `Graphics.hpprgm` is 790 bytes: an 8-character name occupies
/// offsets 18–33, the terminator sits at 34–35, the size field at 36 reads 750,
/// and 40 + 750 is exactly 790. That arithmetic is what the parser relies on
/// rather than the header-size field, which real files set inconsistently.
///
/// An *unnamed* program — the other documented shape — has a zero name flag and
/// places the size at offset 16 with the text at 20.
///
/// ## Container layout
///
/// Files beginning `7C 61 8A B2` are a richer container that carries application
/// variables alongside the program. Its record framing is not publicly
/// documented field by field. Such files are read for display — the program text
/// is the last UTF-16LE run — but writing always produces the plain layout, which
/// every firmware accepts. See ``ContentEditingSupport`` for how the UI surfaces
/// this limitation instead of silently discarding variables.
public enum PrimeProgramFile {
    /// Magic that introduces a variable container rather than a plain program.
    public static let containerMagic: [UInt8] = [0x7C, 0x61, 0x8A, 0xB2]
    /// Name-start marker in the plain layout.
    static let nameMarker: UInt16 = 0x0031
    /// Bytes preceding the name in the plain layout.
    static let nameOffset = 18

    /// How a program file is stored.
    public enum Layout: Sendable {
        /// The plain layout, fully editable.
        case plain(named: Bool)
        /// A variable container; only the trailing program text is understood.
        case container
    }

    /// A decoded program file.
    public struct Decoded: Sendable {
        public let layout: Layout
        /// Embedded name, when the plain layout carries one.
        public let embeddedName: String?
        /// The program source text.
        public let source: String
        /// Whether the container's variables are preserved on save.
        public let preservesVariables: Bool
    }

    // MARK: - Reading

    /// Decodes a program file.
    public static func decode(_ bytes: [UInt8]) throws -> Decoded {
        guard bytes.count >= 4 else {
            throw HPLinkError.malformedContent("the program file is shorter than its header")
        }

        if Array(bytes.prefix(4)) == containerMagic {
            return Decoded(
                layout: .container,
                embeddedName: nil,
                source: trailingText(in: bytes),
                preservesVariables: false
            )
        }

        let nameFlag = readUInt32(bytes, at: 8) ?? 0
        if nameFlag == 1, bytes.count >= nameOffset {
            return try decodeNamed(bytes)
        }
        return try decodeUnnamed(bytes)
    }

    private static func decodeNamed(_ bytes: [UInt8]) throws -> Decoded {
        let marker = readUInt16(bytes, at: 16)
        guard marker == nameMarker else {
            throw HPLinkError.malformedContent(
                String(format: "expected the program name marker 0031 but found %04X", marker ?? 0)
            )
        }

        // The name runs until a doubled NUL terminator.
        var index = nameOffset
        var nameBytes: [UInt8] = []
        while index + 1 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 { break }
            nameBytes.append(bytes[index])
            nameBytes.append(bytes[index + 1])
            index += 2
        }
        guard index + 1 < bytes.count else {
            throw HPLinkError.malformedContent("the program name is not terminated")
        }
        index += 2  // step over the terminator

        guard let size = readUInt32(bytes, at: index) else {
            throw HPLinkError.truncatedReply(expectedBytes: index + 4, actualBytes: bytes.count)
        }
        let textStart = index + 4
        guard textStart + Int(size) <= bytes.count else {
            throw HPLinkError.truncatedReply(
                expectedBytes: textStart + Int(size),
                actualBytes: bytes.count
            )
        }

        return Decoded(
            layout: .plain(named: true),
            embeddedName: PrimeObjectName.decode(nameBytes),
            source: decodeText(Array(bytes[textStart..<(textStart + Int(size))])),
            preservesVariables: true
        )
    }

    private static func decodeUnnamed(_ bytes: [UInt8]) throws -> Decoded {
        guard let size = readUInt32(bytes, at: 16) else {
            throw HPLinkError.truncatedReply(expectedBytes: 20, actualBytes: bytes.count)
        }
        let textStart = 20
        guard textStart + Int(size) <= bytes.count else {
            throw HPLinkError.truncatedReply(
                expectedBytes: textStart + Int(size),
                actualBytes: bytes.count
            )
        }
        return Decoded(
            layout: .plain(named: false),
            embeddedName: nil,
            source: decodeText(Array(bytes[textStart..<(textStart + Int(size))])),
            preservesVariables: true
        )
    }

    // MARK: - Writing

    /// Encodes a program in the plain named layout.
    ///
    /// - Parameters:
    ///   - source: the program text.
    ///   - name: the object name embedded in the file. The calculator shows this
    ///     name in the Program Catalog, so it must match the file name.
    public static func encode(source: String, name: String) throws -> [UInt8] {
        try PrimeObjectName.validate(name)

        var nameBytes = PrimeObjectName.utf16LittleEndian(name)
        // The name is terminated by a doubled NUL, which the length arithmetic
        // below accounts for.
        nameBytes.append(contentsOf: [0x00, 0x00])

        var text = PrimeObjectName.utf16LittleEndian(source)
        // Programs are NUL terminated in every observed sample.
        text.append(contentsOf: [0x00, 0x00])

        // `Graphics.hpprgm` sets this field to the offset of the size field minus
        // four, so it is reproduced the same way rather than guessed.
        let headerSize = UInt32(nameOffset + nameBytes.count - 4)

        var out: [UInt8] = []
        out.reserveCapacity(nameOffset + nameBytes.count + 4 + text.count)
        appendUInt32(&out, headerSize)
        appendUInt32(&out, 0)          // reserved
        appendUInt32(&out, 1)          // named
        appendUInt32(&out, 0)          // reserved
        appendUInt16(&out, nameMarker)
        out.append(contentsOf: nameBytes)
        appendUInt32(&out, UInt32(text.count))
        out.append(contentsOf: text)
        return out
    }

    // MARK: - Text helpers

    /// Decodes UTF-16LE text, tolerating a byte order mark and a trailing NUL.
    static func decodeText(_ bytes: [UInt8]) -> String {
        var body = bytes
        if body.count >= 2, body[0] == 0xFF, body[1] == 0xFE { body.removeFirst(2) }

        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var index = 0
        while index + 1 < body.count {
            units.append(UInt16(body[index]) | (UInt16(body[index + 1]) << 8))
            index += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        // Strip a single trailing NUL, which terminates the stored text.
        if text.hasSuffix("\0") { text.removeLast() }
        return text
    }

    /// Finds the longest UTF-16LE text run in a container, which is where the
    /// program source lives.
    static func trailingText(in bytes: [UInt8]) -> String {
        var best = ""
        var current: [UInt16] = []

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= 8 else { return }
            let candidate = String(decoding: current, as: UTF16.self)
            if candidate.count > best.count { best = candidate }
        }

        var index = 0
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            // Printable Latin text, or a newline, which programs are full of.
            if bytes[index + 1] == 0, unit == 0x0A || unit == 0x0D || (unit >= 0x20 && unit < 0x7F) {
                current.append(unit)
            } else {
                flush()
            }
            index += 2
        }
        flush()
        return best.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Byte helpers

    /// Reads a little-endian 32-bit field, for callers inspecting a header.
    public static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Reads a little-endian 16-bit field.
    public static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func appendUInt32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    static func appendUInt16(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    }
}

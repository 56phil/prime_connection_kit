import Foundation

/// Reader and writer for `.hpnote` / `.hpappnote` note files.
///
/// ## Layout
///
/// A note is a UTF-16LE document whose plain-text content comes first, followed
/// by a formatted section. Verified against a real `Fonts.hpappnote` (296 bytes):
///
/// | region | content |
/// |--------|---------|
/// | 0      | plain-text fallback, terminated by `00 00` |
/// | …      | magic `CSWD110` for notes, `CSWT110` for an app's Info note |
/// | …      | `FF FF FF FF` |
/// | …      | formatting: `\`-escaped control words |
/// | end    | footer: `\0 \3 \0`, the line count as a base-32 value, then `\0`×7 |
///
/// The magic's fourth character distinguishes the two kinds: `D` for a standalone
/// note, `T` for the Info tab of an application.
///
/// ## Why this preserves rather than rewrites
///
/// The formatting language inside the second half is a rich, partially documented
/// control-word stream. ``decode(_:)`` extracts the plain text an editor can
/// display and show, but the *original bytes are kept and written back unchanged*
/// so that bolding, colours, bullets, subscripts and embedded pictures cannot be
/// damaged by a round trip. Only a note whose plain text has changed is rebuilt,
/// and even then the formatting tail is carried over verbatim.
public enum PrimeNoteFile {
    /// Magic introducing the formatted section, shared by notes and app notes.
    static let magicPrefix = "CSW"
    /// Fourth character for a standalone note.
    static let noteKind: Character = "D"
    /// Fourth character for an application's Info note.
    static let appNoteKind: Character = "T"

    /// A decoded note.
    public struct Decoded: Sendable {
        /// The editable plain text.
        public let text: String
        /// Whether the file carries a formatted section.
        public let hasFormatting: Bool
        /// Whether the formatted section is an app's Info note rather than a note.
        public let isAppNote: Bool
        /// Byte offset where the formatted section begins, if present.
        public let formatSectionOffset: Int?
    }

    // MARK: - Reading

    /// Decodes a note file.
    ///
    /// A file too short to hold a note body is an empty note. The minimum
    /// meaningful body is one character plus its terminator — four bytes — so a
    /// two-byte file cannot be text, whatever it contains. The Connectivity Kit
    /// writes such files for applications whose Info note has never been set, and
    /// their two bytes are not reliably zero: real files on this machine hold
    /// values such as `01 80`, `0A 00` and `C4 3A`. Decoding those as a single
    /// UTF-16 unit would invent a character that is not there.
    public static func decode(_ bytes: [UInt8]) throws -> Decoded {
        let units = codeUnits(bytes)

        // Locate the magic, which begins the formatted section.
        let magicUnits: [UInt16] = Array("CSW".utf16)
        guard let magicIndex = find(magicUnits, in: units) else {
            // No formatting. A body still needs a terminator, so anything shorter
            // than four bytes carries nothing.
            let text = bytes.count < 4 ? "" : trimTerminators(plainText(units))
            return Decoded(
                text: text,
                hasFormatting: false,
                isAppNote: false,
                formatSectionOffset: nil
            )
        }

        let kindUnit = magicIndex + 3 < units.count ? units[magicIndex + 3] : 0
        let kind = Character(UnicodeScalar(kindUnit) ?? "D")

        let textUnits = Array(units[0..<magicIndex])
        return Decoded(
            text: trimTerminators(plainText(textUnits)),
            hasFormatting: true,
            isAppNote: kind == appNoteKind,
            formatSectionOffset: magicIndex * 2
        )
    }

    // MARK: - Writing

    /// Encodes a note, reusing an existing file's structure when possible.
    ///
    /// - Parameters:
    ///   - text: the new plain text.
    ///   - existingContent: the note's current bytes. Its formatted tail is
    ///     preserved, and its overall shape is respected. Pass `nil` for a new
    ///     note.
    ///   - isAppNote: whether the note is an application's Info note. Only used
    ///     when a new file has to be built from nothing.
    public static func encode(
        text: String,
        reusing existingContent: [UInt8]?,
        isAppNote: Bool
    ) -> [UInt8] {
        if let existing = existingContent, let decoded = try? decode(existing) {
            if decoded.hasFormatting, let offset = decoded.formatSectionOffset {
                // Retain the formatted tail exactly and rebuild only the
                // plain-text prefix, so formatting survives editing.
                var out = PrimeObjectName.utf16LittleEndian(text)
                out.append(contentsOf: [0x00, 0x00])
                out.append(contentsOf: existing[offset...])
                return out
            }

            // The file carries no formatted section. The Connectivity Kit writes
            // an empty app note as a bare terminator, so that shape is preserved
            // rather than replaced by a longer formatted skeleton — rewriting it
            // would change a file the calculator already accepts.
            var out = PrimeObjectName.utf16LittleEndian(text)
            out.append(contentsOf: [0x00, 0x00])
            return out
        }

        return encodeMinimal(text: text, isAppNote: isAppNote)
    }

    /// Builds a note from scratch: plain text plus the fixed formatted-section
    /// skeleton the calculator expects.
    static func encodeMinimal(text: String, isAppNote: Bool) -> [UInt8] {
        var out = PrimeObjectName.utf16LittleEndian(text)
        out.append(contentsOf: [0x00, 0x00])  // plain-text terminator

        // `CSWD110` or `CSWT110`.
        let magic = magicPrefix + String(isAppNote ? appNoteKind : noteKind) + "110"
        out.append(contentsOf: PrimeObjectName.utf16LittleEndian(magic))
        out.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        // `\l` with a default line height, one empty paragraph, then the footer.
        out.append(contentsOf: PrimeObjectName.utf16LittleEndian("\\l"))
        out.append(contentsOf: [0x3E, 0x01])
        out.append(contentsOf: PrimeObjectName.utf16LittleEndian("\\0\\3\\0\\0\\0\\0\\0\\0\\0\\0"))
        return out
    }

    // MARK: - Helpers

    /// The file as UTF-16 code units, honouring a byte order mark.
    private static func codeUnits(_ bytes: [UInt8]) -> [UInt16] {
        var body = bytes
        var swap = false
        if body.count >= 2, body[0] == 0xFF, body[1] == 0xFE {
            body.removeFirst(2)
        } else if body.count >= 2, body[0] == 0xFE, body[1] == 0xFF {
            body.removeFirst(2)
            swap = true
        }

        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var index = 0
        while index + 1 < body.count {
            let unit = UInt16(body[index]) | (UInt16(body[index + 1]) << 8)
            units.append(swap ? (unit >> 8) | ((unit & 0xFF) << 8) : unit)
            index += 2
        }
        return units
    }

    /// Converts code units up to the first NUL into text, dropping control words.
    private static func plainText(_ units: [UInt16]) -> String {
        var body = units
        if let terminator = body.firstIndex(of: 0) { body = Array(body[0..<terminator]) }
        return String(decoding: body, as: UTF16.self)
    }

    private static func trimTerminators(_ text: String) -> String {
        var result = text
        while result.hasSuffix("\0") { result.removeLast() }
        return result
    }

    private static func find(_ needle: [UInt16], in haystack: [UInt16]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }
}

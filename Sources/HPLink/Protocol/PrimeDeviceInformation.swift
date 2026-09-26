import Foundation

/// What the calculator reports about itself.
///
/// The layout of the `getInfos` reply is not publicly documented. Rather than
/// invent field offsets, the raw payload is retained and printable strings are
/// extracted with a heuristic that matches the shape of the observed replies
/// (version text, an identifier, and the calculator's name are all present as
/// text). Callers should treat the parsed fields as best-effort and fall back to
/// ``raw``.
public struct PrimeDeviceInformation: Sendable {
    /// The reply body exactly as received.
    public let raw: [UInt8]
    /// Every printable string found in the reply, in order of appearance.
    public let strings: [String]

    public init(raw: [UInt8]) {
        self.raw = raw
        self.strings = Self.extractStrings(from: raw)
    }

    /// Firmware version text, if one was recognised.
    ///
    /// Matches the first token that looks like a version: a run containing a digit
    /// and a dot, for example `V2.060.650`.
    public var firmwareVersion: String? {
        strings.first { token in
            token.contains(".") && token.contains(where: \.isNumber) && token.count >= 3
        }
    }

    /// The calculator's name as set on Home Settings page 2, if recognised.
    ///
    /// The reply's fields appear in the order **name, version, serial**, which was
    /// established by reading a real calculator: it reports `Sample Calculator`,
    /// `V2.060.650`, `SN00000001` in that order.
    ///
    /// Taking the last text token — an obvious first guess — picks the *serial*,
    /// which makes the application label each calculator with a number and rename
    /// its folder to match. The name is therefore identified by exclusion: the
    /// first token that is neither the version nor the serial.
    public var calculatorName: String? {
        let version = firmwareVersion
        let serial = serialNumber
        return strings.first { token in
            token != version
                && token != serial
                && !token.isEmpty
                && token.contains(where: { $0.isLetter || $0 == " " })
        }
    }

    /// A serial-number-like token, if one was recognised.
    ///
    /// The serial is the last token that is entirely alphanumeric and long enough
    /// to be an identifier rather than a name.
    public var serialNumber: String? {
        strings.last { token in
            token.count >= 8
                && token.contains(where: \.isNumber)
                && token.allSatisfy { $0.isLetter || $0.isNumber }
        }
    }

    /// Builds the display strings for the Properties dialog.
    public var summaryLines: [(String, String)] {
        var lines: [(String, String)] = []
        if let version = firmwareVersion { lines.append(("Software version", version)) }
        if let name = calculatorName { lines.append(("Calculator name", name)) }
        if let serial = serialNumber { lines.append(("Identifier", serial)) }
        lines.append(("Reported strings", strings.isEmpty ? "none" : strings.joined(separator: ", ")))
        lines.append(("Reply size", "\(raw.count) bytes"))
        return lines
    }

    /// Extracts printable strings, trying UTF-16LE first because the protocol
    /// carries text that way, then ASCII.
    static func extractStrings(from bytes: [UInt8]) -> [String] {
        var results: [String] = UTF16StringScanner.strings(in: bytes)
        let ascii = ASCIIStringScanner.strings(in: bytes)
        // Prefer UTF-16 strings; add ASCII runs only when they are not fragments
        // of the text already found.
        for candidate in ascii where !results.contains(where: { $0.contains(candidate) || candidate.contains($0) }) {
            results.append(candidate)
        }
        return results
    }
}

/// Finds UTF-16 little-endian text runs in a byte buffer.
enum UTF16StringScanner {
    static func strings(in bytes: [UInt8], minimumLength: Int = 3) -> [String] {
        var results: [String] = []
        var units: [UInt16] = []
        var index = 0

        func flush() {
            defer { units.removeAll(keepingCapacity: true) }
            guard units.count >= minimumLength else { return }
            let text = String(decoding: units, as: UTF16.self)
                .trimmingCharacters(in: .controlCharacters)
            if !text.isEmpty { results.append(text) }
        }

        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            // The zero high byte is the signature of Latin text in UTF-16LE.
            if bytes[index + 1] == 0, unit >= 0x20, unit < 0x7F {
                units.append(unit)
            } else {
                flush()
            }
            index += 2
        }
        flush()
        return results
    }
}

/// Finds ASCII text runs in a byte buffer.
enum ASCIIStringScanner {
    static func strings(in bytes: [UInt8], minimumLength: Int = 4) -> [String] {
        var results: [String] = []
        var current: [UInt8] = []

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= minimumLength else { return }
            if let text = String(bytes: current, encoding: .ascii) { results.append(text) }
        }

        for byte in bytes {
            if byte >= 0x20, byte < 0x7F {
                current.append(byte)
            } else {
                flush()
            }
        }
        flush()
        return results
    }
}

/// Raised when a reply is not the command we were waiting for.
struct UnexpectedReplyError: Error, CustomStringConvertible {
    let expected: PrimeCommand
    let found: UInt8

    var description: String {
        String(format: "expected a %02X reply but received %02X", expected.rawValue, found)
    }
}

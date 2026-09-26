import Foundation

/// Reader and writer for `.hpexammode` exam-mode configurations.
///
/// ## Layout
///
/// Verified against the two configurations in this machine's working folder,
/// which are byte-identical:
///
/// | offset | size | meaning |
/// |--------|------|---------|
/// | 0      | 32   | configuration name, UTF-16LE, NUL padded |
/// | 32     | 1024 | configuration flags, all zero in every observed file |
/// | 1056   | 12   | zero |
/// | 1068   | 88   | integrity trailer: a checksum region, padding, then a MAC |
///
/// ## The integrity trailer
///
/// The trailer is not a checksum over the file in any scheme the public
/// implementations use; it behaves like an encrypted or keyed digest, and no
/// public source documents it. The Connectivity Kit also holds no such file
/// under `Content/Exam Modes`, so no second independent sample exists here to
/// compare against.
///
/// Rather than invent an algorithm and emit files the calculator would reject,
/// this type:
///
/// * parses the name and the flag region, which is what the editor displays;
/// * keeps the trailer bytes verbatim;
/// * writes the trailer back unchanged when the name or flags are edited.
///
/// The practical consequence is that a configuration derived from one already
/// produced by the Connectivity Kit round-trips correctly, while a brand-new
/// configuration cannot be minted from nothing. ``isDerived`` reports which case
/// a value is, so the UI can say so instead of producing a broken file.
public enum PrimeExamModeFile {
    /// Bytes of the name field.
    static let nameFieldLength = 32
    /// Bytes of the flag region.
    static let flagRegionLength = 1024
    /// Bytes between the flag region and the trailer.
    static let gapLength = 12
    /// Offset at which the integrity trailer begins.
    public static var trailerOffset: Int { nameFieldLength + flagRegionLength + gapLength }
    /// Bytes of integrity trailer observed in real files.
    static let trailerLength = 88

    /// A decoded exam-mode configuration.
    public struct Decoded: Sendable {
        /// The configuration's name.
        public var name: String
        /// The flag region, preserved verbatim. No public source assigns meaning
        /// to individual bits, so it is kept as an opaque blob rather than
        /// guessed at.
        public var flags: [UInt8]
        /// The integrity trailer, preserved verbatim.
        public var trailer: [UInt8]
        /// Whether the file carried a trailer to preserve.
        public var isDerived: Bool
    }

    // MARK: - Reading

    /// Decodes a configuration file.
    public static func decode(_ bytes: [UInt8]) throws -> Decoded {
        guard bytes.count >= nameFieldLength + 4 else {
            throw HPLinkError.malformedContent("the exam-mode file is shorter than its name field")
        }

        let name = decodeName(Array(bytes[0..<nameFieldLength]))

        let flagStart = nameFieldLength
        let flagEnd = min(flagStart + flagRegionLength, bytes.count)
        let flags = Array(bytes[flagStart..<flagEnd])

        let trailer = bytes.count > trailerOffset ? Array(bytes[trailerOffset...]) : []

        return Decoded(
            name: name,
            flags: flags,
            trailer: trailer,
            isDerived: !trailer.isEmpty
        )
    }

    // MARK: - Writing

    /// Encodes a configuration, reusing the trailer from `template`.
    ///
    /// - Parameters:
    ///   - name: the configuration's name.
    ///   - flags: the flag region; defaults to the template's.
    ///   - template: an existing configuration whose trailer is preserved. Pass
    ///     the file being edited. `nil` produces a file without a valid trailer,
    ///     which the calculator will reject.
    public static func encode(
        name: String,
        flags: [UInt8]? = nil,
        reusing template: Decoded?
    ) -> (bytes: [UInt8], isComplete: Bool) {
        var out = encodeName(name)
        out.append(contentsOf: [UInt8](repeating: 0, count: nameFieldLength - out.count))

        if let flags {
            out.append(contentsOf: flags.prefix(flagRegionLength))
            out.append(contentsOf: [UInt8](repeating: 0, count: max(0, flagRegionLength - flags.count)))
        } else if let template {
            out.append(contentsOf: template.flags.prefix(flagRegionLength))
            out.append(contentsOf: [UInt8](repeating: 0, count: max(0, flagRegionLength - template.flags.count)))
        } else {
            out.append(contentsOf: [UInt8](repeating: 0, count: flagRegionLength))
        }

        out.append(contentsOf: [UInt8](repeating: 0, count: gapLength))

        if let template, !template.trailer.isEmpty {
            out.append(contentsOf: template.trailer)
            return (out, true)
        }
        return (out, false)
    }

    // MARK: - Names

    private static func decodeName(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            let unit = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func encodeName(_ name: String) -> [UInt8] {
        // Cap the name so it cannot overrun the field.
        var bytes = PrimeObjectName.utf16LittleEndian(name)
        let limit = nameFieldLength - 2
        if bytes.count > limit { bytes = Array(bytes.prefix(limit)) }
        return bytes
    }
}

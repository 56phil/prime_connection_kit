import Foundation

/// A calculator-side object name and its conversion to and from the on-disk
/// file name.
///
/// Two conversions happen in opposite directions:
///
/// * **On-disk names** — the Connectivity Kit prefixes built-in application
///   directories with `&`. The prefix is not part of the object's name; it marks
///   an app that shipped with the calculator and therefore cannot be deleted,
///   only reset.
/// * **Wire names** — object names travel as UTF-16 little-endian. They are
///   capped at ``maximumLength`` code units.
public enum PrimeObjectName {
    /// Maximum code units in an object name.
    ///
    /// The wire protocol carries the name length in a single byte counting
    /// *bytes*, so a UTF-16 name can be at most 127 code units. The
    /// Connectivity Kit uses 32, which we follow to match its behaviour.
    public static let maximumLength = 32

    /// Marks a built-in application directory in the working folder.
    public static let builtInPrefix: Character = "&"

    /// Splits an on-disk file or directory name into the object name and whether
    /// it is built in.
    ///
    /// - Parameters:
    ///   - fileName: a file name, optionally with an extension, such as
    ///     `&Function.hpappdir` or `MyProgram.hpprgm`.
    ///   - type: the object's content type, when it is already known. Settings
    ///     files need it, because their names include their own extension.
    public static func parse(
        diskName fileName: String,
        type: PrimeFileType? = nil
    ) -> (name: String, isBuiltIn: Bool) {
        let isBuiltIn = fileName.hasPrefix(String(builtInPrefix))
        let body = isBuiltIn ? String(fileName.dropFirst()) : fileName

        // A settings file is named exactly what the calculator calls the object:
        // `calc.hpsettings`, `calc.hpvars` and `settings` are all complete names,
        // not a stem plus an extension. Splitting one at its last dot would
        // shorten `calc.hpsettings` to `calc` and lose the distinction from
        // `calc.hpvars`.
        if type == .settings { return (body, isBuiltIn) }

        let withoutExtension = (body as NSString).deletingPathExtension
        return (withoutExtension, isBuiltIn)
    }

    /// The on-disk file name for an object of the given type.
    ///
    /// Applications are stored as a directory suffixed `.hpappdir`, matching the
    /// Connectivity Kit. Settings are stored under the name the calculator gives
    /// them, which already carries its own extension. Every other type is a single
    /// file named for the object plus its type's extension.
    public static func diskName(
        for name: String,
        type: PrimeFileType,
        isBuiltIn: Bool = false
    ) -> String {
        let prefix = isBuiltIn ? String(builtInPrefix) : ""
        switch type {
        case .application:
            return "\(prefix)\(name).hpappdir"
        case .settings:
            // Appending an extension here produces `calc.hpsettings.hpsettings` —
            // a second file beside the one the Connectivity Kit writes, which the
            // calculator then reports as a separate object.
            return "\(prefix)\(name)"
        default:
            return "\(prefix)\(name).\(PrimeFileExtension.default(for: type))"
        }
    }

    /// Validates a name for use on the calculator.
    ///
    /// The Connectivity Kit accepts letters, digits, and a few punctuation
    /// marks, and rejects anything that would confuse the protocol's
    /// length-prefixed encoding.
    public static func validate(_ name: String) throws {
        guard !name.isEmpty else {
            throw HPLinkError.invalidObjectName(name)
        }
        guard name.count <= maximumLength else {
            throw HPLinkError.invalidObjectName(
                "“\(name)” is \(name.count) characters; the limit is \(maximumLength)."
            )
        }
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|\u{0}")
        guard name.rangeOfCharacter(from: forbidden) == nil else {
            throw HPLinkError.invalidObjectName(
                "“\(name)” contains a character the calculator cannot store."
            )
        }
        // Leading or trailing whitespace survives the round trip inconsistently.
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw HPLinkError.invalidObjectName("“\(name)” has leading or trailing spaces.")
        }
    }

    /// The UTF-16 little-endian byte sequence for a name, as sent on the wire.
    static func wireBytes(for name: String) throws -> [UInt8] {
        try validate(name)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.utf16.count * 2)
        for unit in name.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }

    /// Decodes a wire name back to a ``String``.
    static func decode(_ bytes: some Collection<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var iterator = bytes.makeIterator()
        while let low = iterator.next() {
            guard let high = iterator.next() else { break }
            units.append(UInt16(low) | (UInt16(high) << 8))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Encodes a name to UTF-16LE, used when the length limit is not the
    /// protocol's (for example when reading on-disk content).
    public static func utf16LittleEndian(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf16.count * 2)
        for unit in string.utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }
}

/// Convenience alias so call sites read naturally.
public typealias PrimeObjectNameWire = PrimeObjectName

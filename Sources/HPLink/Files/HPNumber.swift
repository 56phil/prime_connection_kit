import Foundation

/// Encoding of HP Prime numeric values.
///
/// The Prime stores numbers in a packed binary-coded-decimal form rather than
/// IEEE 754, so that decimal results are exact. Two widths appear in the
/// documented layouts: a 16-byte form used by the Home variables and a compact
/// 8-byte form used inside lists and matrices.
///
/// ## 16-byte form
///
/// | bytes | meaning |
/// |-------|---------|
/// | 0…2   | tag bytes; not interpreted here |
/// | 3     | sign, as a signed byte: negative when non-zero-and-negative |
/// | 4…7   | exponent, little-endian `Int32` |
/// | 8…15  | eight base-100 digit pairs, most significant first |
///
/// The mantissa is therefore `pair₁ + pair₂/100 + pair₃/100² + …` and the value is
/// `sign × mantissa × 10^exponent`. This is self-consistent: 500 encodes as
/// mantissa 5 with exponent 2, and 0.5 as mantissa 50 with exponent −2.
///
/// ## 8-byte form
///
/// | bytes | meaning |
/// |-------|---------|
/// | 0…1   | exponent, little-endian `Int16` |
/// | 2…6  | five base-100 digit pairs |
/// | 7     | low nibble: leading digit; high nibble: `9` when negative, else `0` |
///
/// The mantissa is `d₁.d₂d₃…` and the value is `sign × mantissa × 10^exponent`.
///
/// ## Provenance
///
/// Both layouts are derived from the only public implementations of the format
/// (`QtHPConnect`'s `extract16`, `extract8` and `BCD`). The 16-byte form is
/// internally consistent there. The 8-byte *decoder* in that project disagrees
/// with its own *encoder* about where the leading digit sits; this type follows
/// the encoder, which is the direction that has to satisfy the calculator, and
/// ``HPNumberTests`` pins both directions together.
public enum HPNumber {
    // MARK: - 16-byte form

    /// Number of bytes in the wide form.
    public static let wideSize = 16
    /// Number of bytes in the compact form.
    public static let compactSize = 8

    /// Decodes a 16-byte value.
    ///
    /// - Throws: ``HPLinkError/malformedContent(_:)`` if `bytes` is too short.
    public static func decodeWide(_ bytes: ArraySlice<UInt8>) throws -> Double {
        guard bytes.count >= wideSize else {
            throw HPLinkError.malformedContent("a wide number needs \(wideSize) bytes but got \(bytes.count)")
        }
        let base = bytes.startIndex

        let signByte = Int8(bitPattern: bytes[base + 3])
        let sign: Double = signByte < 0 ? -1 : 1

        let exponent = Int32(bytes[base + 4])
            | (Int32(bytes[base + 5]) << 8)
            | (Int32(bytes[base + 6]) << 16)
            | (Int32(bytes[base + 7]) << 24)

        // The pairs are the digits of an integer part followed by a base-100
        // fraction: `d₀ + d₁/100 + d₂/100² + …`, most significant pair first.
        var mantissa = 0.0
        for offset in stride(from: wideSize - 1, through: 8, by: -1) {
            mantissa = mantissa / 100 + Double(base100(bytes[base + offset]))
        }

        return sign * mantissa * pow(10, Double(exponent))
    }

    /// Encodes a value in the 16-byte form.
    ///
    /// The first three bytes are zero, matching the layout's unused tag region.
    public static func encodeWide(_ value: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: wideSize)

        // Zero is the natural encoding of itself and needs no digit work.
        guard value != 0, value.isFinite else { return bytes }

        let sign: Double = value < 0 ? -1 : 1
        bytes[3] = value < 0 ? 0xFF : 0x00

        // Normalise into [0, 100) so the leading pair is a full base-100 digit.
        var exponent = Int32(floor(log10(abs(value)) / 2) * 2)
        var mantissa = abs(value) / pow(10, Double(exponent))
        while mantissa >= 100 { mantissa /= 100; exponent += 2 }
        while mantissa < 1 { mantissa *= 100; exponent -= 2 }

        bytes[4] = UInt8(truncatingIfNeeded: exponent)
        bytes[5] = UInt8(truncatingIfNeeded: exponent >> 8)
        bytes[6] = UInt8(truncatingIfNeeded: exponent >> 16)
        bytes[7] = UInt8(truncatingIfNeeded: exponent >> 24)

        for offset in 8..<wideSize {
            let pair = Int(mantissa.rounded(.down))
            bytes[offset] = encodeBase100(pair)
            mantissa = (mantissa - Double(pair)) * 100
        }

        _ = sign
        return bytes
    }

    // MARK: - 8-byte form

    /// Decodes a compact value.
    ///
    /// - Throws: ``HPLinkError/malformedContent(_:)`` if `bytes` is too short.
    public static func decodeCompact(_ bytes: ArraySlice<UInt8>) throws -> Double {
        guard bytes.count >= compactSize else {
            throw HPLinkError.malformedContent("a compact number needs \(compactSize) bytes but got \(bytes.count)")
        }
        let base = bytes.startIndex

        let exponent = Int16(bytes[base]) | (Int16(bytes[base + 1]) << 8)
        // The high nibble of the last byte carries the sign — `9` when negative —
        // and its low nibble is the mantissa's leading digit.
        let sign: Double = (bytes[base + 7] & 0xF0) == 0x90 ? -1 : 1

        var mantissa = Double(bytes[base + 7] & 0x0F)
        for index in 0..<5 {
            let slot = base + 6 - index
            mantissa = mantissa + Double(base100(bytes[slot])) / pow(100, Double(index + 1))
        }

        return sign * mantissa * pow(10, Double(exponent))
    }

    /// Encodes a value in the compact form.
    ///
    /// The mantissa keeps at most eleven significant digits, which is the width
    /// the layout provides: one leading digit plus five base-100 pairs.
    public static func encodeCompact(_ value: Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: compactSize)

        guard value != 0, value.isFinite else { return bytes }

        // The exponent is a decimal power of ten, so the mantissa lands in [1, 10).
        var exponent = Int(floor(log10(abs(value))))
        var mantissa = abs(value) / pow(10, Double(exponent))
        if mantissa >= 10 { mantissa /= 10; exponent += 1 }
        while mantissa < 1 { mantissa *= 10; exponent -= 1 }

        // Clamp to the exponent range the layout can express.
        exponent = min(max(exponent, Int(Int16.min)), Int(Int16.max))
        let exponentBits = UInt16(bitPattern: Int16(exponent))
        bytes[0] = UInt8(truncatingIfNeeded: exponentBits)
        bytes[1] = UInt8(truncatingIfNeeded: exponentBits >> 8)

        // Emit eleven significant digits: one leading digit plus five pairs.
        var digits: [Int] = []
        var remainder = mantissa
        for _ in 0..<11 {
            // Round the last digit rather than truncating, so a value that
            // decimal expansion cannot hit exactly still encodes correctly.
            let digit = Int(floor(remainder))
            digits.append(min(max(digit, 0), 9))
            remainder = (remainder - Double(digit)) * 10
            if remainder < 0 { remainder = 0 }
        }

        // The leading digit is the high nibble of the final byte, which also
        // carries the sign. Each pair then fills one byte, least significant pair
        // first, working backwards from offset 6.
        bytes[7] = (value < 0 ? 0x90 : 0x00) | UInt8(digits[0] & 0x0F)
        for index in 0..<5 {
            // digits[1], digits[2] is the first pair; it belongs at offset 6.
            let high = digits[1 + index * 2]
            let low = digits[2 + index * 2]
            bytes[6 - index] = UInt8(((high & 0x0F) << 4) | (low & 0x0F))
        }
        return bytes
    }

    // MARK: - Base-100 helpers

    /// Decodes one packed base-100 byte into 0…99.
    static func base100(_ byte: UInt8) -> Int {
        Int(byte >> 4) * 10 + Int(byte & 0x0F)
    }

    /// Encodes 0…99 into one packed base-100 byte.
    static func encodeBase100(_ value: Int) -> UInt8 {
        let clamped = min(max(value, 0), 99)
        return UInt8(((clamped / 10) << 4) | (clamped % 10))
    }
}

/// Formats and parses numbers the way the calculator's editors present them.
public enum HPNumberText {
    /// Renders a value the way the calculator displays it: plain decimal where
    /// practical, scientific notation outside that range.
    public static func string(from value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let magnitude = abs(value)
        if magnitude != 0, magnitude < 1e-4 || magnitude >= 1e12 {
            return String(format: "%.10E", value)
        }
        // Trim trailing zeros that would otherwise clutter edited lists.
        var text = String(format: "%.12g", value)
        if text.contains("e") || text.contains("E") {
            text = String(format: "%.10E", value)
        }
        return text
    }

    /// Parses a value typed by the user.
    ///
    /// Accepts plain decimals, scientific notation, and the calculator's `E`
    /// exponent form. Returns `nil` rather than guessing at unparseable input.
    public static func value(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed) { return value }
        return nil
    }
}

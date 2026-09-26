import Foundation
import Testing
@testable import HPLink

/// Pins the packed decimal number formats in both directions.
///
/// These encodings are the least-documented part of the format family, so the
/// tests assert the property that actually matters to the calculator: a value
/// written and read back must be the same value, and the byte layout must be the
/// one the format describes.
@Suite("Number encoding")
struct HPNumberTests {
    /// Values that exercise the exponent range and the mantissa's digit slots.
    static let samples: [Double] = [
        0, 1, -1, 2, 10, 100, 500, -500, 0.5, -0.5, 0.01, 1234, -1234,
        12345, 99999999, 1e10, 1e-10, 3.14159265358979, -2.718281828459045,
    ]

    @Test("wide values survive a round trip", arguments: samples)
    func wideRoundTrip(value: Double) throws {
        let bytes = HPNumber.encodeWide(value)
        #expect(bytes.count == HPNumber.wideSize)
        let decoded = try HPNumber.decodeWide(bytes[...])

        // Zero is exact; everything else is within the format's precision.
        if value == 0 {
            #expect(decoded == 0)
        } else {
            let relativeError = abs(decoded - value) / abs(value)
            #expect(relativeError < 1e-10, "\(value) decoded as \(decoded)")
        }
    }

    @Test("compact values survive a round trip", arguments: samples)
    func compactRoundTrip(value: Double) throws {
        let bytes = HPNumber.encodeCompact(value)
        #expect(bytes.count == HPNumber.compactSize)
        let decoded = try HPNumber.decodeCompact(bytes[...])

        if value == 0 {
            #expect(decoded == 0)
        } else {
            // The compact form carries eleven significant digits.
            let relativeError = abs(decoded - value) / abs(value)
            #expect(relativeError < 1e-9, "\(value) decoded as \(decoded)")
        }
    }

    @Test("the sign is recoverable in both formats")
    func signPreserved() throws {
        for magnitude in [1.0, 42.0, 0.25, 1e6] {
            #expect(try HPNumber.decodeWide(HPNumber.encodeWide(magnitude)[...]) > 0)
            #expect(try HPNumber.decodeWide(HPNumber.encodeWide(-magnitude)[...]) < 0)
            #expect(try HPNumber.decodeCompact(HPNumber.encodeCompact(magnitude)[...]) > 0)
            #expect(try HPNumber.decodeCompact(HPNumber.encodeCompact(-magnitude)[...]) < 0)
        }
    }

    @Test("zero encodes as all zeros in both formats")
    func zeroEncoding() throws {
        #expect(HPNumber.encodeWide(0).allSatisfy { $0 == 0 })
        #expect(HPNumber.encodeCompact(0).allSatisfy { $0 == 0 })
        #expect(try HPNumber.decodeWide([UInt8](repeating: 0, count: 16)[...]) == 0)
        #expect(try HPNumber.decodeCompact([UInt8](repeating: 0, count: 8)[...]) == 0)
    }

    @Test("the wide layout places digits in base-100 pairs")
    func wideByteLayout() throws {
        // 500 = mantissa 5, exponent 2. The mantissa digits are 05 then zeros,
        // packed as base-100 bytes: 0x05, then 0x00.
        let bytes = HPNumber.encodeWide(500)
        #expect(bytes[4] == 2)   // exponent, little-endian
        #expect(bytes[5] == 0)
        #expect(bytes[8] == 0x05)
        #expect(bytes[9] == 0x00)

        // Independent reconstruction of the value from the format description.
        let reconstructed = 5.0 * pow(10.0, 2.0)
        #expect(try abs(HPNumber.decodeWide(bytes[...]) - reconstructed) < 1e-12)
    }

    @Test("a short buffer is rejected rather than misread")
    func shortBufferRejected() {
        #expect(throws: HPLinkError.self) { try HPNumber.decodeWide([0x01, 0x02][...]) }
        #expect(throws: HPLinkError.self) { try HPNumber.decodeCompact([0x01][...]) }
    }

    @Test("base-100 packing round-trips every representable pair")
    func base100Packing() {
        for value in 0...99 {
            #expect(HPNumber.base100(HPNumber.encodeBase100(value)) == value)
        }
        // Out-of-range input is clamped instead of producing a malformed byte.
        #expect(HPNumber.base100(HPNumber.encodeBase100(150)) == 99)
    }

    @Test("number text formatting is parseable by the app's own parser")
    func textRoundTrip() {
        for value in Self.samples where value.isFinite {
            let text = HPNumberText.string(from: value)
            let parsed = HPNumberText.value(from: text)
            #expect(parsed != nil, "“\(text)” did not parse back")
            if let parsed, value != 0 {
                #expect(abs(parsed - value) / abs(value) < 1e-9, "\(value) → “\(text)” → \(parsed)")
            }
        }
    }

    @Test("unparseable input is rejected")
    func textParsingRejectsGarbage() {
        #expect(HPNumberText.value(from: "abc") == nil)
        #expect(HPNumberText.value(from: "") == nil)
        #expect(HPNumberText.value(from: "1.5") == 1.5)
        #expect(HPNumberText.value(from: "-2.5E3") == -2500)
    }
}

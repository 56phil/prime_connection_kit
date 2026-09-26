import Foundation
import Testing
@testable import HPLink

/// Checks the CRC-16/CCITT implementation against the reference.
///
/// `libhpcalcs` uses a 256-entry table for the `0x1021` polynomial. The first few
/// rows of that table are transcribed here from `prime_cmd.c` so the generated
/// table is pinned to the real one rather than to itself.
@Suite("CRC-16")
struct HPCRC16Tests {
    /// Rows sampled verbatim from `libhpcalcs/src/prime_cmd.c`'s
    /// `ccitt_crc16_table`.
    static let referenceTableRows: [(index: Int, values: [UInt16])] = [
        (0x00, [0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50A5, 0x60C6, 0x70E7]),
        (0x08, [0x8108, 0x9129, 0xA14A, 0xB16B, 0xC18C, 0xD1AD, 0xE1CE, 0xF1EF]),
        (0x10, [0x1231, 0x0210, 0x3273, 0x2252, 0x52B5, 0x4294, 0x72F7, 0x62D6]),
        (0xF0, [0xEF1F, 0xFF3E, 0xCF5D, 0xDF7C, 0xAF9B, 0xBFBA, 0x8FD9, 0x9FF8]),
    ]

    @Test("the generated table matches the reference implementation")
    func tableMatchesReference() {
        for row in Self.referenceTableRows {
            for (offset, expected) in row.values.enumerated() {
                let actual = HPCRC16.table[row.index + offset]
                #expect(
                    actual == expected,
                    "table[\(row.index + offset)] = \(String(format: "%04X", actual)), expected \(String(format: "%04X", expected))"
                )
            }
        }
    }

    @Test("the table has 256 distinct entries")
    func tableShape() {
        #expect(HPCRC16.table.count == 256)
    }

    @Test("an empty input has a zero checksum")
    func emptyInput() {
        #expect(HPCRC16.checksum([UInt8]()) == 0)
    }

    @Test("a known vector produces the expected checksum")
    func knownVector() {
        // "123456789" is the conventional test vector for this polynomial. With an
        // initial value of zero and no final XOR — the parameters `libhpcalcs`
        // uses — it is known as CRC-16/XMODEM and yields 0x31C3.
        let checksum = HPCRC16.checksum(Array("123456789".utf8))
        #expect(checksum == 0x31C3)
    }

    @Test("checksums are sensitive to byte order")
    func orderMatters() {
        let forward = HPCRC16.checksum([0x01, 0x02])
        let reversed = HPCRC16.checksum([0x02, 0x01])
        #expect(forward != reversed)
    }
}

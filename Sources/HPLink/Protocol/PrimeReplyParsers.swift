import Foundation

/// Parses a `recvScreen` reply.
///
/// Layout, from `libhpcalcs/src/prime_cmd.c` (`calc_prime_r_recv_screen`):
///
/// | offset | meaning |
/// |--------|---------|
/// | 0      | command, `0xFC` |
/// | 1      | `0x01` |
/// | 2…5   | declared length, big-endian |
/// | 6…7   | checksum, big-endian (note: the file layout uses little-endian) |
/// | 8      | screenshot format selector, echoing the request |
/// | 9…12  | `0xFF 0xFF 0xFF 0xFF` marker |
/// | 13…   | image bytes |
public enum PrimeScreenReply {
    /// The smallest reply that can carry an image.
    static let headerLength = 13

    /// Extracts the image from a reply.
    ///
    /// - Throws: ``HPLinkError/truncatedReply(expectedBytes:actualBytes:)``,
    ///   ``HPLinkError/checksumMismatch(expected:actual:)`` or
    ///   ``HPLinkError/malformedContent(_:)``.
    public static func parse(_ reply: [UInt8], format: PrimeScreenshotFormat) throws -> [UInt8] {
        guard reply.count > headerLength else {
            throw HPLinkError.truncatedReply(expectedBytes: headerLength + 1, actualBytes: reply.count)
        }
        guard reply.first == PrimeCommand.recvScreen.rawValue else {
            throw UnexpectedReplyError(expected: .recvScreen, found: reply.first ?? 0)
        }

        // The checksum covers everything from itself to the end, with its own
        // two bytes read as zero.
        let embedded = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        var covered = Array(reply[6...])
        HPCRC16.clearChecksumField(&covered, at: [0, 1])
        let computed = HPCRC16.checksum(covered)
        guard computed == embedded else {
            throw HPLinkError.checksumMismatch(expected: embedded, actual: computed)
        }

        guard reply[8] == format.rawValue,
              reply[9] == 0xFF, reply[10] == 0xFF, reply[11] == 0xFF, reply[12] == 0xFF
        else {
            throw HPLinkError.malformedContent("the screenshot reply has an unrecognised header marker")
        }

        return Array(reply[headerLength...])
    }

    /// Whether `bytes` begin with a PNG signature.
    public static func isPNG(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 8 && Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }
}

/// Parses a `recvFile` reply into an object.
///
/// Layout, from `libhpcalcs/src/prime_cmd.c` (`calc_prime_r_recv_file`):
///
/// | offset | meaning |
/// |--------|---------|
/// | 0      | command, `0xF7` |
/// | 1      | `0x01` |
/// | 2…5   | declared length, big-endian |
/// | 6      | object type |
/// | 7      | name length in bytes |
/// | 8…9   | checksum, little-endian |
/// | 10…   | name, UTF-16LE, then the object's content |
public enum PrimeFileReply {
    /// Bytes of header preceding the name.
    static let headerLength = 10
    /// Bytes at the end of the message excluded from the checksum.
    static let checksumExclusionLength = 6

    /// Parses a reply.
    ///
    /// - Returns: the object, or `nil` for a frame that carries no object, which
    ///   is how the calculator terminates a backup stream.
    public static func parse(_ reply: [UInt8]) throws -> PrimeObject? {
        guard !reply.isEmpty else { return nil }

        // An F9 frame is the terminator of a backup stream and carries no object.
        if reply[0] == PrimeCommand.recvBackup.rawValue { return nil }

        guard reply[0] == PrimeCommand.recvFile.rawValue else {
            throw UnexpectedReplyError(expected: .recvFile, found: reply[0])
        }
        guard reply.count >= headerLength else {
            throw HPLinkError.truncatedReply(expectedBytes: headerLength, actualBytes: reply.count)
        }

        let typeCode = reply[6]
        let nameLength = Int(reply[7])
        guard reply.count >= headerLength + nameLength else {
            throw HPLinkError.truncatedReply(expectedBytes: headerLength + nameLength, actualBytes: reply.count)
        }

        // The checksum covers the message except its final six bytes, with the
        // checksum field itself read as zero. For a very short object the field
        // falls outside that region entirely; the reference implementation simply
        // computes over a shorter span, so the zeroing is conditional rather than
        // an error.
        let coveredLength = reply.count - checksumExclusionLength
        let embedded = UInt16(reply[8]) | (UInt16(reply[9]) << 8)
        var covered = coveredLength > 0 ? Array(reply[0..<coveredLength]) : []
        HPCRC16.clearChecksumField(&covered, at: [8, 9])
        let computed = HPCRC16.checksum(covered)
        guard computed == embedded else {
            throw HPLinkError.checksumMismatch(expected: embedded, actual: computed)
        }

        let nameBytes = reply[headerLength..<(headerLength + nameLength)]
        let content = reply[(headerLength + nameLength)...]

        // An unknown type code is preserved as-is so nothing is lost, but it is
        // surfaced to the caller rather than invented.
        guard let type = PrimeFileType(rawValue: typeCode) else {
            throw HPLinkError.malformedContent(
                String(format: "the calculator returned an unknown object type %02X", typeCode)
            )
        }

        let name = PrimeObjectName.decode(nameBytes)
        return PrimeObject(
            name: name,
            type: type,
            isBuiltIn: type == .application && PrimeWorkingFolder.builtInAppNames().contains(name),
            content: Self.normaliseContent(Array(content), type: type)
        )
    }

    /// Removes the framing prefix some objects carry.
    ///
    /// An application read from current firmware arrives with a short prefix
    /// before its container magic — observed as four bytes, for example
    /// `00 00 05 A5` ahead of `7C 61 8A B2`. The Connectivity Kit strips this
    /// when it mirrors an application to disk: the files it writes begin with the
    /// magic itself.
    ///
    /// The prefix is removed here rather than when writing, so an object is the
    /// same in memory as it is on disk, and re-sending it produces the bytes the
    /// calculator expects.
    ///
    /// Only applied when the magic is actually found a little way in, so a blob
    /// that legitimately starts with something else is left alone.
    static func normaliseContent(_ content: [UInt8], type: PrimeFileType) -> [UInt8] {
        guard type == .application else { return content }
        guard Array(content.prefix(4)) != PrimeProgramFile.containerMagic else { return content }

        // Look for the magic within the first few bytes; anything further would
        // not be framing.
        let maximumPrefix = 8
        guard content.count > maximumPrefix else { return content }
        for offset in 1...maximumPrefix {
            if Array(content[offset..<(offset + 4)]) == PrimeProgramFile.containerMagic {
                return Array(content[offset...])
            }
        }
        return content
    }
}

import Foundation

/// Errors raised by the link layer and the content codecs.
public enum HPLinkError: Error, Equatable, Sendable {
    /// No calculator with a known vendor/product id is attached.
    case deviceNotFound
    /// The USB device could not be opened, usually an entitlement or permission problem.
    case deviceOpenFailed(String)
    /// A HID write or read failed.
    case transportFailure(String)
    /// The device stopped responding within the allotted time.
    case timeout
    /// A received chunk carried an unexpected sequence number.
    case packetOutOfSequence(expected: UInt8, actual: UInt8)
    /// The reply was too short to contain its declared header.
    case truncatedReply(expectedBytes: Int, actualBytes: Int)
    /// The reply's declared length exceeded the protocol's sanity bound.
    case implausibleLength(UInt32)
    /// A payload failed its CRC-16 check.
    case checksumMismatch(expected: UInt16, actual: UInt16)
    /// An object name is empty, too long, or contains characters the calculator rejects.
    case invalidObjectName(String)
    /// A content file could not be parsed.
    case malformedContent(String)
    /// The request is not meaningful for the object or device given.
    case unsupportedOperation(String)
    /// The session was used after being closed.
    case sessionClosed
}

extension HPLinkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "No HP Prime calculator is connected. Connect one by USB and turn it on."
        case .deviceOpenFailed(let reason):
            "Could not open the calculator: \(reason)"
        case .transportFailure(let reason):
            "Lost communication with the calculator: \(reason)"
        case .timeout:
            "The calculator did not respond in time."
        case .packetOutOfSequence(let expected, let actual):
            String(format: "Malformed reply: expected chunk %02X but received %02X.", expected, actual)
        case .truncatedReply(let expectedBytes, let actualBytes):
            "Truncated reply: expected \(expectedBytes) bytes but received \(actualBytes)."
        case .implausibleLength(let length):
            String(format: "Reply declared an implausible length of %u bytes.", length)
        case .checksumMismatch(let expected, let actual):
            String(format: "Checksum mismatch: expected %04X but computed %04X.", expected, actual)
        case .invalidObjectName(let name):
            "“\(name)” is not a valid calculator object name."
        case .malformedContent(let detail):
            "The content file is damaged or in an unrecognised format: \(detail)"
        case .unsupportedOperation(let detail):
            detail
        case .sessionClosed:
            "The calculator connection has been closed."
        }
    }
}

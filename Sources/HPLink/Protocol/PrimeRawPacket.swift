import Foundation

/// A raw HID report, the lowest layer of the Prime link protocol.
///
/// ## Two framings
///
/// The protocol has been shipped with two report sizes, and they are not
/// interchangeable — a message framed for one arrives as unintelligible bytes on
/// the other:
///
/// | generation | report | payload | layout |
/// |---|---|---|---|
/// | early firmware | 64 bytes | 63 bytes | `sequence, payload…` |
/// | current hardware | 1024 bytes | 1023 bytes | `sequence, payload…` |
///
/// The layout is the same; only the capacity differs. Which one applies is read
/// from the device's own HID descriptor (``PrimeDeviceDescriptor/maximumInputReportSize``)
/// rather than guessed, because guessing wrong is silent: the calculator simply
/// never answers.
///
/// A report whose payload is shorter than the capacity terminates a message,
/// which is how a sender signals the end of a partial final chunk.
///
/// ## macOS asymmetry
///
/// IOKit hands us reports *after* the report ID, because the Prime uses
/// unnumbered reports (`report_id == 0`). Writes are the mirror image: the buffer
/// handed to `IOHIDDeviceSetReport` must still carry a leading report ID byte,
/// which the stack strips before the bytes go on the wire. Concretely, `hidapi`
/// writes `data[1…]` when `data[0] == 0`.
public struct PrimeRawPacket: Sendable {
    /// Size of a report on the older generation.
    public static let smallReportSize = 64
    /// Size of a report on current hardware.
    public static let largeReportSize = 1024

    /// Payload capacity of an older-generation report.
    public static let smallPayloadCapacity = smallReportSize - 1
    /// Payload capacity of a current report.
    public static let largePayloadCapacity = largeReportSize - 1

    /// Sequence number the protocol skips when wrapping.
    static let reservedSequence: UInt8 = 0xFF

    /// Chunk sequence number, carried in the report's first byte.
    public var sequence: UInt8
    /// Payload bytes.
    public var payload: [UInt8]
    /// Payload capacity this packet was framed for.
    public var capacity: Int

    public init(sequence: UInt8, payload: [UInt8], capacity: Int = smallPayloadCapacity) {
        precondition(payload.count <= capacity, "payload exceeds one report")
        self.sequence = sequence
        self.payload = payload
        self.capacity = capacity
    }

    /// True when this report terminates a message.
    public var isTerminal: Bool { payload.count < capacity }

    // MARK: - Device-bound serialisation

    /// Bytes to hand to the HID write call: `reportID, sequence, payload`.
    ///
    /// Not padded. A full report is one byte longer than the capacity here
    /// because of the report ID; a partial report stays short so the device sees
    /// the message end.
    public func serializedForDevice(reportID: UInt8 = 0) -> [UInt8] {
        [reportID, sequence] + payload
    }

    // MARK: - Host-bound parsing

    /// Parses a report received from the device, which carries no report ID.
    public init(parsing bytes: [UInt8], capacity: Int) {
        sequence = bytes.first ?? 0
        payload = bytes.count > 1 ? Array(bytes[1...]) : []
        self.capacity = capacity
        if payload.count > capacity { payload = Array(payload.prefix(capacity)) }
    }

    /// Advances a sequence number, skipping the reserved value.
    public static func nextSequence(after sequence: UInt8) -> UInt8 {
        let next = sequence &+ 1
        return next == reservedSequence ? 0 : next
    }

    /// The sequence number expected at a given chunk index.
    ///
    /// Mirrors the sender's wrap rule: increment and skip `0xFF`.
    public static func sequence(forChunkIndex index: Int) -> UInt8 {
        // The cycle is 255 long: 0x00…0xFE.
        UInt8(index % 255)
    }
}

import Foundation

/// The report-level interface the session layer needs from a transport.
///
/// Abstracting this keeps the protocol logic testable without hardware: the
/// session can be driven against an in-memory fake that replays recorded
/// traffic.
public protocol PrimeTransport: AnyObject, Sendable {
    /// Payload bytes per HID report for this connection.
    ///
    /// Depends on the device: 63 on early firmware, 1023 on current hardware.
    /// The session uses it to frame messages correctly, so this must reflect
    /// what the device actually declared.
    var payloadCapacity: Int { get }

    /// Sends one HID report.
    ///
    /// The buffer includes the leading report ID byte that the platform HID
    /// stack expects for unnumbered reports; its length is deliberately not
    /// padded so a short report also signals the end of a message.
    func write(report bytes: [UInt8]) throws

    /// Waits for the next HID report from the calculator.
    func readReport(timeout: TimeInterval) throws -> [UInt8]

    /// Whether a report is already buffered and can be read without blocking.
    var hasPendingReport: Bool { get }

    /// Discards buffered reports so a stale reply cannot be mistaken for the
    /// answer to the next request.
    func flushPendingReports()
}

public extension PrimeTransport {
    /// Writes a raw packet to the device.
    func send(_ packet: PrimeRawPacket) throws {
        try write(report: packet.serializedForDevice())
    }
}

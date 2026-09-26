import Foundation

/// A transport that replays a scripted conversation.
///
/// Used by the tests to exercise the whole protocol stack without a calculator.
///
/// ## Why the queue survives a flush
///
/// A real device's replies sit in the host's buffers until read, so a transport
/// that discarded them on flush would model a device that answers a request and
/// then forgets the answer. ``PrimeSession`` flushes before every request to
/// discard *stale* traffic, which is exactly what a real connection needs and
/// exactly what a pre-scripted queue cannot survive.
///
/// To keep both behaviours honest, queued reports are treated as pending device
/// output that a flush has nothing to do with, and replies are queued per
/// request instead. Callers use ``enqueue(_:)`` for replies to a specific write.
public final class MockTransport: PrimeTransport, @unchecked Sendable {
    /// Reports the session has written, in order.
    public private(set) var writtenReports: [[UInt8]] = []

    /// Replies waiting for the session to read.
    private var inbound: [[UInt8]] = []
    /// Replies per written report index, applied when a write happens.
    private var repliesByWriteIndex: [Int: [[UInt8]]] = [:]
    private let lock = NSLock()

    /// Payload bytes per report, matching the framing under test.
    public let payloadCapacity: Int

    public init(payloadCapacity: Int = PrimePacketCodec.defaultPayloadCapacity) {
        self.payloadCapacity = payloadCapacity
    }

    /// Queues reports for the session to read immediately.
    public func enqueue(_ reports: [[UInt8]]) {
        lock.lock()
        inbound.append(contentsOf: reports)
        lock.unlock()
    }

    /// Queues a reply to be released once `count` reports have been written.
    ///
    /// This models a device that answers when it is spoken to, so the answer
    /// cannot be discarded by the session's pre-request flush.
    public func reply(afterWrites count: Int, reports: [[UInt8]]) {
        lock.lock()
        repliesByWriteIndex[count, default: []].append(contentsOf: reports)
        lock.unlock()
    }

    public func write(report bytes: [UInt8]) throws {
        lock.lock()
        writtenReports.append(bytes)
        let count = writtenReports.count
        // Release any replies scheduled for this point in the conversation.
        if let pending = repliesByWriteIndex.removeValue(forKey: count) {
            inbound.append(contentsOf: pending)
        }
        lock.unlock()
    }

    public func readReport(timeout: TimeInterval) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        guard !inbound.isEmpty else { throw HPLinkError.timeout }
        return inbound.removeFirst()
    }

    public var hasPendingReport: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !inbound.isEmpty
    }

    /// Discards reports already queued for reading, which is what a real device's
    /// outstanding-but-unread output would be.
    public func flushPendingReports() {
        lock.lock()
        inbound.removeAll()
        lock.unlock()
    }
}

/// Builds scripted device replies for tests and diagnostics.
public enum MockReplyBuilder {
    /// Wraps `message` in HID reports exactly as the calculator would send it.
    ///
    /// The device-side report is `sequence, payload…` with the payload *not*
    /// padded, which is what terminates a message. The fragmentation and the
    /// sequence numbering are therefore taken from ``PrimePacketCodec``, so a
    /// scripted reply cannot drift from the framing the session expects.
    public static func reports(for message: [UInt8]) -> [[UInt8]] {
        PrimePacketCodec.fragment(message).map { packet in
            [packet.sequence] + packet.payload
        }
    }

    /// A `getInfos` reply carrying the given version text.
    ///
    /// The reply body is not documented beyond its length prefix; the app treats
    /// it as opaque and stores it verbatim, so the tests only need a
    /// well-formed frame.
    public static func getInfosReply(body: [UInt8]) -> [[UInt8]] {
        reports(for: PrimeMessage.withLengthHeader(command: .getInfos, body: body).bytes)
    }

    /// A `checkReady` reply: the command byte echoed back.
    public static func checkReadyReply() -> [[UInt8]] {
        reports(for: [PrimeCommand.checkReady.rawValue])
    }

    /// A `recvScreen` reply carrying a screenshot in the given format.
    ///
    /// Layout, matching `libhpcalcs`: `0xFC, 0x01, length(4), checksum(2),
    /// format, 0xFF×4, image`. The checksum is stored **big-endian** and covers
    /// the message from the checksum field onward — notably *not* the four header
    /// bytes before it — with its own two bytes read as zero.
    public static func screenReply(format: PrimeScreenshotFormat, image: [UInt8]) -> [[UInt8]] {
        let payload: [UInt8] = [format.rawValue, 0xFF, 0xFF, 0xFF, 0xFF] + image

        // The declared length is everything after the six-byte header.
        let declaredLength = payload.count + 2
        var message: [UInt8] = [PrimeCommand.recvScreen.rawValue, 0x01]
        message.append(UInt8((declaredLength >> 24) & 0xFF))
        message.append(UInt8((declaredLength >> 16) & 0xFF))
        message.append(UInt8((declaredLength >> 8) & 0xFF))
        message.append(UInt8(declaredLength & 0xFF))
        message.append(contentsOf: [0x00, 0x00])  // checksum placeholder
        message.append(contentsOf: payload)

        // Covered region starts at the checksum field.
        var covered = Array(message[6...])
        HPCRC16.clearChecksumField(&covered, at: [0, 1])
        let checksum = HPCRC16.checksum(covered)
        message[6] = UInt8(checksum >> 8)
        message[7] = UInt8(checksum & 0xFF)

        return reports(for: message)
    }

    /// A `recvFile` reply carrying one object.
    ///
    /// Layout: `0xF7, 0x01, length(4), type, nameLength, checksum(2), name,
    /// content`. The declared length counts everything after the six-byte header,
    /// and the checksum covers the whole message except its final six bytes, with
    /// the checksum field read as zero. It is stored **little-endian**.
    public static func fileMessage(name: String, type: PrimeFileType, content: [UInt8]) -> [UInt8] {
        let nameBytes = PrimeObjectName.utf16LittleEndian(name)
        let declaredLength = 4 + nameBytes.count + content.count

        var message: [UInt8] = [PrimeCommand.recvFile.rawValue, 0x01]
        message.append(UInt8((declaredLength >> 24) & 0xFF))
        message.append(UInt8((declaredLength >> 16) & 0xFF))
        message.append(UInt8((declaredLength >> 8) & 0xFF))
        message.append(UInt8(declaredLength & 0xFF))
        message.append(type.rawValue)
        message.append(UInt8(nameBytes.count))
        message.append(contentsOf: [0x00, 0x00])  // checksum placeholder
        message.append(contentsOf: nameBytes)
        message.append(contentsOf: content)

        // The checksum sits at offsets 8 and 9, after the type and name length.
        // For an empty object those offsets fall outside the region the checksum
        // covers, which is what the calculator does too, so the zeroing is
        // conditional.
        var covered = Array(message[0..<(message.count - 6)])
        HPCRC16.clearChecksumField(&covered, at: [8, 9])
        let checksum = HPCRC16.checksum(covered)
        message[8] = UInt8(checksum & 0xFF)
        message[9] = UInt8(checksum >> 8)

        return message
    }

    /// A `recvFile` reply carrying one object, already fragmented into reports.
    public static func fileReply(name: String, type: PrimeFileType, content: [UInt8]) -> [[UInt8]] {
        reports(for: fileMessage(name: name, type: type, content: content))
    }
}

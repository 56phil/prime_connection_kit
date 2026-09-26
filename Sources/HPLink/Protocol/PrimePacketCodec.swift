import Foundation

/// Fragments logical messages into HID reports and reassembles replies.
///
/// The Prime link protocol has two layers. The upper layer is a byte stream made
/// of messages that always begin with a command byte; replies that carry a
/// payload declare it with `cmd, 0x01, length(4, big-endian)`. The lower layer
/// chops that stream into payload-sized chunks, each prefixed by a sequence
/// number that wraps from `0xFE` to `0x00`.
///
/// The chunk capacity depends on the report size the device declares — 63 bytes
/// on early firmware, 1023 on current hardware — so every entry point takes it as
/// a parameter. See ``PrimeRawPacket`` for why the distinction matters.
///
/// Both directions are implemented from `libhpcalcs/src/prime_vpkt.c`
/// (`prime_send_data` / `prime_recv_data` / `prime_data_size`) and the
/// 1024-byte variant in QtHPConnect's `submit_sync_s_transfer`.
public enum PrimePacketCodec {
    /// Largest payload we will believe from a length-prefixed reply.
    ///
    /// The Prime has 32 MB of flash and 256 KB of RAM on the G2; a backup is at
    /// most a few megabytes. This bound exists to reject garbage length fields
    /// without imposing a real limit on legitimate transfers.
    public static let maximumDeclaredPayload = 128 * 1024 * 1024

    /// The default framing, used where a device's own descriptor is unavailable.
    public static let defaultPayloadCapacity = PrimeRawPacket.smallPayloadCapacity

    // MARK: - Outbound

    /// Fragments `message` into HID reports.
    ///
    /// The message is split into payload-sized chunks; the final report is short
    /// when the message length is an exact multiple of the capacity, or when the
    /// message is empty, so the device always sees a terminating report.
    public static func fragment(
        _ message: [UInt8],
        payloadCapacity: Int = defaultPayloadCapacity
    ) -> [PrimeRawPacket] {
        var packets: [PrimeRawPacket] = []
        var offset = 0
        var sequence: UInt8 = 0

        while message.count - offset >= payloadCapacity {
            let end = offset + payloadCapacity
            packets.append(PrimeRawPacket(
                sequence: sequence,
                payload: Array(message[offset..<end]),
                capacity: payloadCapacity
            ))
            sequence = PrimeRawPacket.nextSequence(after: sequence)
            offset = end
        }

        // Trailing (possibly empty) report terminates the message.
        packets.append(PrimeRawPacket(
            sequence: sequence,
            payload: Array(message[offset...]),
            capacity: payloadCapacity
        ))
        return packets
    }

    // MARK: - Inbound

    /// The declared total length of a length-prefixed reply, or `nil` when the
    /// command does not use a length prefix.
    ///
    /// - Parameter command: the command the reply is expected to answer.
    /// - Parameter bytes: the first reassembled bytes of the reply. At least six
    ///   bytes are required for commands that declare a length.
    public static func declaredReplyLength(
        for command: PrimeCommand,
        firstBytes bytes: [UInt8]
    ) throws -> Int? {
        switch command {
        case .checkReady:
            // Single, self-describing packet.
            return 1
        case .getInfos, .recvScreen, .recvBackup, .recvFile, .chat:
            guard bytes.count >= 6 else {
                throw HPLinkError.truncatedReply(expectedBytes: 6, actualBytes: bytes.count)
            }
            // The first byte may be a leading zero, which is part of the framing
            // rather than the command: the calculator's packets begin with a
            // zero byte on the wire.
            let second = bytes[1]
            guard second == 0x01 else {
                throw HPLinkError.malformedContent(
                    String(format: "expected 0x01 as the second byte of a %02X reply, got %02X", command.rawValue, second)
                )
            }
            let payload = UInt32(bytes[2]) << 24
                | UInt32(bytes[3]) << 16
                | UInt32(bytes[4]) << 8
                | UInt32(bytes[5])
            guard Int(payload) <= maximumDeclaredPayload else {
                throw HPLinkError.implausibleLength(payload)
            }
            // The four length bytes describe everything after the header.
            return Int(payload) + 6
        case .requestFile, .sendKey, .setDateTime:
            // The calculator never sends these; nothing to wait for.
            return nil
        }
    }

    /// Accumulates HID reports into a message and validates chunk sequencing.
    ///
    /// Reports whose sequence number is `0xFF` are skipped: the protocol never
    /// uses that value for message chunks, and `libhpcalcs` treats such reports
    /// as out-of-band traffic that must not be reassembled.
    public struct Reassembler: Sendable {
        private var accumulated: [UInt8] = []
        private var chunkIndex = 0
        private let capacity: Int

        public init(payloadCapacity: Int = PrimePacketCodec.defaultPayloadCapacity) {
            self.capacity = payloadCapacity
        }

        /// How many chunks have been accepted for the current message.
        public var chunkCount: Int { chunkIndex }

        /// Appends a report.
        ///
        /// - Returns: `true` when the report terminated the message, meaning the
        ///   accumulator now holds a complete message.
        /// - Throws: ``HPLinkError/packetOutOfSequence(expected:actual:)`` when
        ///   the sequence number is not the one expected next.
        @discardableResult
        public mutating func append(_ packet: PrimeRawPacket) throws -> Bool {
            // Out-of-band report: not part of any message.
            if packet.sequence == PrimeRawPacket.reservedSequence {
                return false
            }

            let expected = PrimeRawPacket.sequence(forChunkIndex: chunkIndex)
            guard packet.sequence == expected else {
                reset()
                throw HPLinkError.packetOutOfSequence(expected: expected, actual: packet.sequence)
            }

            chunkIndex += 1
            accumulated.append(contentsOf: packet.payload)
            return packet.isTerminal
        }

        /// The bytes assembled so far.
        public var message: [UInt8] { accumulated }

        /// Clears the accumulator for the next message.
        public mutating func reset() {
            accumulated.removeAll(keepingCapacity: true)
            chunkIndex = 0
        }
    }
}

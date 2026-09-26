import Foundation
import Testing
@testable import HPLink

/// Checks the report-level framing against the rules in
/// `libhpcalcs/src/prime_vpkt.c`.
@Suite("Packet framing")
struct PrimePacketCodecTests {
    @Test("a report carries a sequence number and up to 63 payload bytes")
    func reportShape() {
        #expect(PrimeRawPacket.smallReportSize == 64)
        #expect(PrimeRawPacket.smallPayloadCapacity == 63)
        #expect(PrimeRawPacket.largeReportSize == 1024)
        #expect(PrimeRawPacket.largePayloadCapacity == 1023)

        let packet = PrimeRawPacket(sequence: 5, payload: [1, 2, 3])
        let device = packet.serializedForDevice()
        // The device buffer is the report ID plus the wire report.
        #expect(device[0] == 0x00)
        #expect(device[1] == 5)
        #expect(Array(device[2...]) == [1, 2, 3])
    }

    @Test("a full-length message ends with a short terminating report")
    func exactMultipleGetsTerminator() {
        // 63 bytes exactly: one full report, then an empty terminator.
        let packets = PrimePacketCodec.fragment([UInt8](repeating: 0xAA, count: 63), payloadCapacity: 63)
        #expect(packets.count == 2)
        #expect(packets[0].payload.count == 63)
        #expect(packets[0].isTerminal == false)
        #expect(packets[1].payload.isEmpty)
        #expect(packets[1].isTerminal)
    }

    @Test("a multi-report message splits at 63 bytes")
    func splitting() {
        let message = [UInt8](repeating: 0x5A, count: 200)
        let packets = PrimePacketCodec.fragment(message, payloadCapacity: 63)

        // 200 = 63 + 63 + 63 + 11, so three full reports and one short one.
        #expect(packets.count == 4)
        #expect(packets[0].payload.count == 63)
        #expect(packets[1].payload.count == 63)
        #expect(packets[2].payload.count == 63)
        #expect(packets[3].payload.count == 11)
        #expect(packets[3].isTerminal)

        // Reassembling recovers the original bytes exactly.
        let recovered = packets.flatMap(\.payload)
        #expect(recovered == message)
    }

    @Test("sequence numbers advance and skip 0xFF")
    func sequenceWrapping() {
        #expect(PrimeRawPacket.sequence(forChunkIndex: 0) == 0x00)
        #expect(PrimeRawPacket.sequence(forChunkIndex: 1) == 0x01)
        #expect(PrimeRawPacket.sequence(forChunkIndex: 254) == 0xFE)
        // 0xFF is skipped, so index 255 wraps to 0x00.
        #expect(PrimeRawPacket.sequence(forChunkIndex: 255) == 0x00)
        #expect(PrimeRawPacket.sequence(forChunkIndex: 256) == 0x01)
    }

    @Test("the reassembler recovers a fragmented message")
    func reassembly() throws {
        let message = [UInt8](repeating: 0x11, count: 150)
        var reassembler = PrimePacketCodec.Reassembler(payloadCapacity: 63)

        var completed = false
        for packet in PrimePacketCodec.fragment(message) {
            completed = try reassembler.append(packet)
        }
        #expect(completed)
        #expect(reassembler.message == message)
    }

    @Test("out-of-band reports starting with the reserved sequence are skipped")
    func skipsReservedSequence() throws {
        var reassembler = PrimePacketCodec.Reassembler(payloadCapacity: 63)
        let skipped = try reassembler.append(PrimeRawPacket(sequence: 0xFF, payload: [0x99]))
        #expect(skipped == false)
        #expect(reassembler.chunkCount == 0)
        #expect(reassembler.message.isEmpty)
    }

    @Test("a sequence gap is reported rather than silently accepted")
    func detectsSequenceGap() {
        var reassembler = PrimePacketCodec.Reassembler(payloadCapacity: 63)
        #expect(throws: HPLinkError.self) {
            // The first chunk must carry sequence 0.
            try reassembler.append(PrimeRawPacket(sequence: 3, payload: [0x01]))
        }
    }

    @Test("check-ready replies are one byte long")
    func checkReadyLength() throws {
        let length = try PrimePacketCodec.declaredReplyLength(for: .checkReady, firstBytes: [0xFF])
        #expect(length == 1)
    }

    @Test("a length-prefixed reply reports its total size")
    func lengthPrefixedReply() throws {
        // cmd, 0x01, then a big-endian payload length of 10.
        let header: [UInt8] = [0xFA, 0x01, 0x00, 0x00, 0x00, 0x0A]
        let length = try PrimePacketCodec.declaredReplyLength(for: .getInfos, firstBytes: header)
        // The total is the payload plus the six header bytes.
        #expect(length == 16)
    }

    @Test("an implausible declared length is rejected")
    func rejectsImplausibleLength() {
        // 0xFFFFFFFF bytes is not a real transfer.
        let header: [UInt8] = [0xFA, 0x01, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: HPLinkError.self) {
            try PrimePacketCodec.declaredReplyLength(for: .getInfos, firstBytes: header)
        }
    }

    @Test("a missing length marker is reported")
    func rejectsMissingMarker() {
        let header: [UInt8] = [0xFA, 0x00, 0x00, 0x00, 0x00, 0x0A]
        #expect(throws: HPLinkError.self) {
            try PrimePacketCodec.declaredReplyLength(for: .getInfos, firstBytes: header)
        }
    }

    @Test("a message larger than one report splits correctly in the large framing")
    func largeFramingSplitting() {
        // 1023 payload bytes per report on current hardware.
        let message = [UInt8](repeating: 0x7E, count: 2500)
        let packets = PrimePacketCodec.fragment(message, payloadCapacity: 1023)

        // 2500 = 1023 + 1023 + 454, so two full reports and one short one.
        #expect(packets.count == 3)
        #expect(packets[0].payload.count == 1023)
        #expect(packets[1].payload.count == 1023)
        #expect(packets[2].payload.count == 454)
        #expect(packets[2].isTerminal)
        #expect(packets.flatMap(\.payload) == message)

        var reassembler = PrimePacketCodec.Reassembler(payloadCapacity: 1023)
        var completed = false
        for packet in packets { completed = (try? reassembler.append(packet)) ?? false }
        #expect(completed)
        #expect(reassembler.message == message)
    }

    @Test("the two framings produce different wire bytes for the same message")
    func framingsDiffer() {
        let message = [UInt8](repeating: 0x11, count: 500)
        let small = PrimePacketCodec.fragment(message, payloadCapacity: 63)
        let large = PrimePacketCodec.fragment(message, payloadCapacity: 1023)

        // A message framed for one generation is unintelligible to the other,
        // which is why the report size is read from the device rather than assumed.
        #expect(small.count != large.count)
        #expect(small[0].payload.count != large[0].payload.count)
    }

    @Test("a report shorter than the capacity terminates the message")
    func terminalDetectionIsCapacityRelative() {
        let payload = [UInt8](repeating: 0, count: 63)
        // Full for the small framing, short for the large one.
        #expect(PrimeRawPacket(sequence: 0, payload: payload, capacity: 63).isTerminal == false)
        #expect(PrimeRawPacket(sequence: 0, payload: payload, capacity: 1023).isTerminal)
    }
}

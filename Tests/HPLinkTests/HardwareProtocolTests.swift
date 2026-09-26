import Foundation
import Testing
@testable import HPLink

/// Pins the protocol details that were established by talking to real hardware.
///
/// These are the facts that no published source records, and getting any of them
/// wrong makes a reachable calculator look broken. They were measured on a Prime
/// reporting itself as `V2.060.650`, with a serial number and a 1024-byte HID
/// report descriptor.
@Suite("Hardware-verified protocol details")
struct HardwareProtocolTests {
    /// The product ID the attached calculator reports.
    ///
    /// Neither `libhpcalcs` (0x0441, 0x1541) nor QtHPConnect (0x0441, 0x1541,
    /// 0x2441) — actually QtHPConnect does list this one, but only hplp's list is
    /// otherwise complete. It is recorded here because a calculator not matched
    /// during discovery is invisible to the whole application.
    static let observedProductID = 0x2441

    @Test("the 1024-byte generation is recognised")
    func currentGenerationIsKnown() {
        #expect(PrimeUSB.knownProductIDs.contains(Self.observedProductID))
        #expect(PrimeUSB.knownProductIDs.contains(0x0441))
        #expect(PrimeUSB.knownProductIDs.contains(0x1541))
        #expect(PrimeUSB.vendorID == 0x03F0)
    }

    @Test("report size decides the framing, not the product ID")
    func framingFollowsReportSize() {
        // A device declaring 1024-byte reports is driven with 1023-byte payloads.
        let large = PrimeDeviceDescriptor(
            id: 1, vendorID: PrimeUSB.vendorID, productID: Self.observedProductID,
            productName: "HP Prime", serialNumber: nil, locationID: 0,
            maximumInputReportSize: 1024, maximumOutputReportSize: 1024
        )
        #expect(large.usesLargeReports)
        #expect(PrimeHIDConnection.maximumReportSize(for: large) == 1024)

        // One declaring 64-byte reports is driven with 63-byte payloads, even at
        // the same product ID: the descriptor is authoritative.
        let small = PrimeDeviceDescriptor(
            id: 2, vendorID: PrimeUSB.vendorID, productID: Self.observedProductID,
            productName: "HP Prime", serialNumber: nil, locationID: 0,
            maximumInputReportSize: 64, maximumOutputReportSize: 64
        )
        #expect(small.usesLargeReports == false)
        #expect(PrimeHIDConnection.maximumReportSize(for: small) == 64)
    }

    @Test("current firmware answers a readiness probe with 'Y'")
    func affirmativeReadinessReply() throws {
        // Measured on the attached calculator: the reply is a single 0x59 byte,
        // not the echoed command byte that the reference implementation expects.
        #expect(PrimeSession.affirmativeReply == 0x59)
        #expect(PrimeSession.affirmativeReply == UInt8(ascii: "Y"))

        // Both answers must count as ready, or a reachable calculator reports as
        // unreachable on the very first exchange of a session.
        let transport = MockTransport(payloadCapacity: 1023)
        transport.reply(afterWrites: 1, reports: [[0x00, 0x59]])
        let session = PrimeSession(transport: transport)
        #expect(try session.checkReady(timeout: 1))

        let echoTransport = MockTransport()
        echoTransport.reply(afterWrites: 1, reports: [[0x00, 0xFF]])
        let echoSession = PrimeSession(transport: echoTransport)
        #expect(try echoSession.checkReady(timeout: 1))
    }

    @Test("a device information reply parses into its fields")
    func deviceInformationLayout() throws {
        // The reply measured from the calculator, rebuilt: a name field, the
        // version, and the serial number, each as NUL-terminated UTF-16LE.
        var body: [UInt8] = []
        for field in ["Sample Calculator", "V2.060.650", "SN00000001"] {
            body.append(contentsOf: PrimeObjectName.utf16LittleEndian(field))
            body.append(contentsOf: [0x00, 0x00])
        }

        let information = PrimeDeviceInformation(raw: body)
        #expect(information.firmwareVersion == "V2.060.650")
        #expect(information.serialNumber == "SN00000001")
        #expect(information.strings.contains("Sample Calculator"))

        // The fields arrive as name, version, serial. Choosing the last text token
        // would pick the serial, which labels the calculator with a number and
        // renames its folder to match — so the name is pinned here.
        #expect(information.calculatorName == "Sample Calculator")
    }

    @Test("a large-framed message is a single report")
    func largeFramingSingleReport() {
        // A small program fits in one 1023-byte payload, which is what the
        // calculator received when the write was confirmed to land.
        let message = [UInt8](repeating: 0x41, count: 154)
        let packets = PrimePacketCodec.fragment(message, payloadCapacity: 1023)
        #expect(packets.count == 1)
        #expect(packets[0].isTerminal)
        #expect(packets[0].payload.count == 154)
    }

    @Test("a backup stream reassembles objects larger than one report")
    func largeObjectReassembly() throws {
        // A real 160 KB list on the attached calculator spans many 1023-byte
        // reports, so reassembly must not be report-size dependent.
        let content = [UInt8](repeating: 0x5A, count: 160_008)
        var reports: [[UInt8]] = []
        for packet in PrimePacketCodec.fragment(
            MockReplyBuilder.fileMessage(name: "L1", type: .list, content: content),
            payloadCapacity: 1023
        ) {
            reports.append([packet.sequence] + packet.payload)
        }
        // The content alone needs more than 150 reports, so the framing is
        // genuinely being exercised across many chunks.
        #expect(reports.count > 150)

        let transport = MockTransport(payloadCapacity: 1023)
        transport.reply(afterWrites: 1, reports: reports)
        let session = PrimeSession(transport: transport)

        let message = try PrimeCommandBuilder.sendFile(
            PrimeObject(name: "L1", type: .list, content: content)
        )
        let reply = try session.rawExchange(message)
        let object = try #require(try PrimeFileReply.parse(reply))
        #expect(object.name == "L1")
        #expect(object.content == content)
    }

    @Test("a write is not treated as failed when the firmware stays silent")
    func silentWriteIsNotFailure() throws {
        // Current firmware sends nothing for a file write. The session must treat
        // that as success rather than reporting a failure for a write that landed.
        let transport = MockTransport(payloadCapacity: 1023)
        // No reply is queued at all.
        let session = PrimeSession(transport: transport)

        let object = PrimeObject(name: "Quiet", type: .program, content: [0x41, 0x42])
        #expect(throws: Never.self) {
            try session.sendObject(object, timeout: 0.2)
        }
        // The write itself must still have gone out.
        #expect(!transport.writtenReports.isEmpty)
    }

    @Test("an application's framing prefix is stripped on receipt")
    func applicationPrefixStripped() throws {
        // Observed from current firmware: four bytes ahead of the container magic,
        // for example `00 00 05 A5`. The Connectivity Kit strips this when it
        // mirrors an application, and its files begin with the magic itself.
        let container = PrimeProgramFile.containerMagic + [0xAA, 0xBB, 0xCC]
        let prefixed: [UInt8] = [0x00, 0x00, 0x05, 0xA5] + container

        let reply = MockReplyBuilder.fileMessage(
            name: "Function", type: .application, content: prefixed
        )
        let object = try #require(try PrimeFileReply.parse(reply))
        #expect(object.content == container)
        #expect(Array(object.content.prefix(4)) == PrimeProgramFile.containerMagic)
    }

    @Test("a clean application container is left alone")
    func cleanApplicationUnchanged() throws {
        let container = PrimeProgramFile.containerMagic + [0x11, 0x22]
        let reply = MockReplyBuilder.fileMessage(
            name: "Solve", type: .application, content: container
        )
        let object = try #require(try PrimeFileReply.parse(reply))
        #expect(object.content == container)
    }

    @Test("only applications are normalised")
    func normalisationIsTypeSpecific() throws {
        // A program that happens to contain the magic mid-blob must not have its
        // start trimmed.
        let content: [UInt8] = [0x01, 0x02] + PrimeProgramFile.containerMagic + [0x03]
        let reply = MockReplyBuilder.fileMessage(
            name: "Odd", type: .program, content: content
        )
        let object = try #require(try PrimeFileReply.parse(reply))
        #expect(object.content == content)
    }

    @Test("a program transfers its raw text, not its container")
    func programTransferCarriesRawText() throws {
        // Measured on real hardware: the calculator stores a program transfer as
        // *text* and terminates on a NUL, so sending the `.hpprgm` container makes
        // it keep only the leading UTF-16 units. A container starting `14 00 00 00`
        // arrived as four bytes; HP's own file starting `7C 61 8A B2 FE FF FF FF 00 00`
        // arrived as ten. Both match that rule exactly.
        let source = "EXPORT Demo()\nBEGIN\n  RETURN 42;\nEND;"
        let container = try PrimeProgramFile.encode(source: source, name: "Demo")

        // The container itself is not valid text: it begins with a length word
        // whose second unit is zero.
        #expect(container[2] == 0x00 && container[3] == 0x00)

        let message = try PrimeCommandBuilder.sendFile(
            PrimeObject(name: "Demo", type: .program, content: container)
        )
        let payload = try PrimeCommandBuilder.transferPayload(
            for: PrimeObject(name: "Demo", type: .program, content: container)
        )

        // The payload must be the source text, and must carry no NUL before its end.
        #expect(payload == PrimeObjectName.utf16LittleEndian(source))
        let body = Array(message.bytes[(10 + PrimeObjectName.utf16LittleEndian("Demo").count)...])
        #expect(body == payload)

        // A text payload has no zero high byte except for genuine NUL terminators,
        // which is exactly what the calculator's truncation rule requires.
        #expect(body.count == source.utf16.count * 2)
    }

    @Test("a program payload round-trips through the transfer form")
    func programPayloadRoundTrip() throws {
        // Whatever the transfer carries must decode back to the same source, so
        // saving a program does not silently alter it.
        let source = "EXPORT Round(N)\nBEGIN\n  RETURN N*2;\nEND;"
        let container = try PrimeProgramFile.encode(source: source, name: "Round")
        let payload = try PrimeCommandBuilder.transferPayload(
            for: PrimeObject(name: "Round", type: .program, content: container)
        )

        // Rebuilding a container from the payload must give the source back.
        let rebuilt = try PrimeProgramFile.encode(
            source: PrimeTextContent.decode(payload),
            name: "Round"
        )
        #expect(try PrimeProgramFile.decode(rebuilt).source == source)
    }

    @Test("a non-program payload is sent unchanged")
    func otherTypesAreNotRewritten() throws {
        // A list or matrix is binary, and must travel exactly as stored.
        let list = try PrimeListCodec.encode([
            PrimeListCodec.Element(real: 1), PrimeListCodec.Element(real: 2),
        ])
        let payload = try PrimeCommandBuilder.transferPayload(
            for: PrimeObject(name: "L1", type: .list, content: list)
        )
        #expect(payload == list)
    }

    @Test("an application container is sent unchanged")
    func applicationPayloadUnchanged() throws {
        // Only programs and notes are text; an application's container is not, so
        // unwrapping it would corrupt the transfer.
        let container = PrimeProgramFile.containerMagic + [0x01, 0x02, 0x03]
        let payload = try PrimeCommandBuilder.transferPayload(
            for: PrimeObject(name: "Function", type: .application, content: container)
        )
        #expect(payload == container)
    }

    @Test("a refusal is still reported")
    func refusalIsReported() throws {
        // An F9 frame means the calculator rejected the transfer, which happens on
        // firmware too old to accept content. That must not be swallowed along
        // with the silent-success case.
        let transport = MockTransport(payloadCapacity: 1023)
        transport.reply(afterWrites: 1, reports: [[0x00, 0xF9]])
        let session = PrimeSession(transport: transport)

        let object = PrimeObject(name: "Old", type: .program, content: [0x41])
        #expect(throws: HPLinkError.self) {
            try session.sendObject(object, timeout: 1)
        }
    }
}

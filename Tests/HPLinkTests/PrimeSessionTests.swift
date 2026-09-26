import Foundation
import Testing
@testable import HPLink

/// Drives the whole protocol stack against a scripted calculator.
///
/// These tests exercise the real ``PrimeSession`` through ``MockTransport``, so
/// the framing, the checksums and the reply parsing are all covered together
/// without hardware.
@Suite("Session protocol")
struct PrimeSessionTests {
    /// Builds a session whose transport answers the scripted exchange.
    ///
    /// Each entry is released after the corresponding number of written reports,
    /// so a reply cannot be discarded by the session's pre-request flush.
    static func makeSession(
        exchanges: [(afterWrites: Int, reports: [[UInt8]])]
    ) -> (PrimeSession, MockTransport) {
        let transport = MockTransport()
        for exchange in exchanges {
            transport.reply(afterWrites: exchange.afterWrites, reports: exchange.reports)
        }
        return (PrimeSession(transport: transport), transport)
    }

    @Test("a readiness probe sends 0xFF and accepts the echo")
    func checkReady() throws {
        let (session, transport) = Self.makeSession(
            exchanges: [(1, MockReplyBuilder.checkReadyReply())]
        )
        #expect(try session.checkReady())
        // The outbound message is the single command byte, in one report.
        #expect(transport.writtenReports.count == 1)
        #expect(transport.writtenReports[0] == [0x00, 0x00, 0xFF])
    }

    @Test("device information is parsed into printable strings")
    func deviceInformation() throws {
        // A reply whose body reads "SDKV0.30" then "MyCalc" in UTF-16LE, which is
        // the shape the calculator's answer takes.
        var body: [UInt8] = []
        for text in ["SDKV0.30", "", "MyCalc"] {
            body.append(contentsOf: PrimeObjectName.utf16LittleEndian(text))
            body.append(contentsOf: [0x00, 0x00])
        }

        let (session, _) = Self.makeSession(
            exchanges: [(1, MockReplyBuilder.getInfosReply(body: body))]
        )
        let information = try session.deviceInformation()

        #expect(information.firmwareVersion == "SDKV0.30")
        #expect(information.calculatorName == "MyCalc")
        #expect(information.raw.count == body.count + 6)
    }

    @Test("a screenshot reply is checksum-verified and unwrapped")
    func screenshot() throws {
        // A tiny but valid PNG signature plus payload.
        let image: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x11, 0x22]
        let (session, _) = Self.makeSession(
            exchanges: [(1, MockReplyBuilder.screenReply(format: .png320x240x16, image: image))]
        )

        let captured = try session.captureScreen()
        #expect(captured == image)
        #expect(PrimeScreenReply.isPNG(captured))
    }

    @Test("a corrupted screenshot checksum is detected")
    func screenshotChecksumFailure() throws {
        let image: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var reports = MockReplyBuilder.screenReply(format: .png320x240x16, image: image)
        // Flip a byte in the checksum field of the first report.
        reports[0][7] ^= 0xFF

        let (session, _) = Self.makeSession(exchanges: [(1, reports)])
        #expect(throws: HPLinkError.self) { try session.captureScreen() }
    }

    @Test("a file reply becomes an object")
    func fileReply() throws {
        let content: [UInt8] = Array("EXPORT F() BEGIN END;".utf8)
        let (session, _) = Self.makeSession(
            exchanges: [(1, MockReplyBuilder.fileReply(name: "Demo", type: .program, content: content))]
        )

        let request = try PrimeCommandBuilder.requestFile(name: "Demo", type: .program)
        let reply = try session.rawExchange(request)
        let object = try #require(try PrimeFileReply.parse(reply))

        #expect(object.name == "Demo")
        #expect(object.type == .program)
        #expect(object.content == content)
    }

    @Test("a terminator frame yields no object")
    func backupTerminator() throws {
        // An F9 frame ends a backup stream.
        let terminator: [UInt8] = [PrimeCommand.recvBackup.rawValue]
        #expect(try PrimeFileReply.parse(terminator) == nil)
    }

    @Test("a backup stream is read until its terminator")
    func backupStream() throws {
        var reports: [[UInt8]] = []
        reports.append(contentsOf: MockReplyBuilder.fileReply(
            name: "P1", type: .program, content: Array("A".utf8)
        ))
        reports.append(contentsOf: MockReplyBuilder.fileReply(
            name: "N1", type: .note, content: []
        ))
        // The dummy request reply, then the terminator.
        reports.append(contentsOf: MockReplyBuilder.reports(for: [PrimeCommand.recvBackup.rawValue]))

        // The backup command is one report, then each object arrives in reply to
        // the session's own reads, which do not write. All the scripted traffic
        // is therefore released after the initial request.
        let (session, _) = Self.makeSession(exchanges: [(1, reports)])
        let result = try session.receiveBackup()

        #expect(result.objects.count == 2)
        #expect(result.objects.map(\.name) == ["P1", "N1"])
        #expect(result.damagedCount == 0)
    }

    @Test("an unrecognised object type is reported, not invented")
    func unknownTypeRejected() {
        // Type code 0x7E is not in the registry.
        let nameBytes = PrimeObjectName.utf16LittleEndian("X")
        // Body: type, name length, checksum, name, one byte of content.
        let bodyLength = 4 + nameBytes.count + 1
        var message: [UInt8] = [
            PrimeCommand.recvFile.rawValue, 0x01,
            UInt8((bodyLength >> 24) & 0xFF),
            UInt8((bodyLength >> 16) & 0xFF),
            UInt8((bodyLength >> 8) & 0xFF),
            UInt8(bodyLength & 0xFF),
            0x7E,
            UInt8(nameBytes.count),
            0x00, 0x00,
        ]
        message.append(contentsOf: nameBytes)
        message.append(0x41)
        message.append(0x42)

        var covered = Array(message[0..<(message.count - 6)])
        covered[6] = 0
        covered[7] = 0
        let checksum = HPCRC16.checksum(covered)
        message[6] = UInt8(checksum & 0xFF)
        message[7] = UInt8(checksum >> 8)

        #expect(throws: HPLinkError.self) { try PrimeFileReply.parse(message) }
    }

    // MARK: - Command building

    @Test("the readiness probe is one byte")
    func checkReadyBytes() {
        #expect(PrimeCommandBuilder.checkReady().bytes == [0xFF])
    }

    @Test("a screenshot request carries the format selector")
    func screenshotRequest() {
        #expect(PrimeCommandBuilder.recvScreen(format: .png320x240x16).bytes == [0xFC, 0x08])
        #expect(PrimeCommandBuilder.recvScreen(format: .png160x120x4).bytes == [0xFC, 0x0B])
    }

    @Test("the clock command has the layout the calculator expects")
    func dateTimeCommand() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 14, minute: 30, second: 5))!

        let message = PrimeCommandBuilder.setDateTime(date, calendar: calendar)
        #expect(message.command == .setDateTime)
        // Header: 0x01 then a big-endian length of 10.
        #expect(Array(message.payload.prefix(5)) == [0x01, 0x00, 0x00, 0x00, 0x0A])
        let body = Array(message.payload.dropFirst(5))
        #expect(body == [0x00, 0x00, 0x54, 0x1E, 26, 9, 26, 14, 30, 5])
    }

    @Test("a chat message is UTF-16 little-endian")
    func chatCommand() {
        let message = PrimeCommandBuilder.sendChat("Hi")
        #expect(message.command == .chat)
        // Length is 4 bytes for two code units.
        #expect(Array(message.payload.prefix(5)) == [0x01, 0x00, 0x00, 0x00, 0x04])
        #expect(Array(message.payload.suffix(4)) == [0x48, 0x00, 0x69, 0x00])
    }

    @Test("a file command's checksum covers the message except its last six bytes")
    func fileChecksumFraming() throws {
        let object = PrimeObject(
            name: "Demo",
            type: .program,
            content: Array("EXPORT F() BEGIN END;".utf8)
        )
        let message = try PrimeCommandBuilder.sendFile(object)
        let bytes = message.bytes

        // The declared length must describe everything after the six-byte header.
        let declared = Int(UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5]))
        #expect(declared == bytes.count - 6)

        // Recompute the checksum the way the calculator will, from the message
        // minus its final six bytes with the checksum field zeroed.
        var covered = Array(bytes[0..<(bytes.count - 6)])
        covered[8] = 0
        covered[9] = 0
        let computed = HPCRC16.checksum(covered)
        let embedded = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)
        #expect(embedded == computed)
    }

    @Test("a program's byte order mark is stripped before sending")
    func bomStrippedOnSend() throws {
        // The firmware rejects a BOM, so it must not reach the wire.
        let withBOM = PrimeTextContent.encode("EXPORT F() BEGIN END;")
        #expect(Array(withBOM.prefix(2)) == [0xFF, 0xFE])

        let message = try PrimeCommandBuilder.sendFile(
            PrimeObject(name: "Demo", type: .program, content: withBOM)
        )
        // Locate the name and confirm the content that follows has no BOM.
        let nameLength = Int(message.bytes[7])
        let contentStart = 10 + nameLength
        let content = Array(message.bytes[contentStart...])
        #expect(!(content.count >= 2 && content[0] == 0xFF && content[1] == 0xFE))
        #expect(content == Array(withBOM.dropFirst(2)))
    }

    @Test("a request-file command declares the name length in bytes")
    func requestFileHeader() throws {
        let message = try PrimeCommandBuilder.requestFile(name: "Demo", type: .program)
        let bytes = message.bytes
        #expect(bytes[0] == PrimeCommand.requestFile.rawValue)
        #expect(bytes[6] == PrimeFileType.program.rawValue)
        // Four characters, two bytes each.
        #expect(bytes[7] == 8)
        // The declared length counts the type, name length, checksum and name.
        let declared = Int(UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5]))
        #expect(declared == 4 + 8)
    }

    @Test("a closed session refuses further work")
    func closedSessionRejects() {
        let (session, _) = Self.makeSession(exchanges: [])
        session.close()
        #expect(throws: HPLinkError.self) { try session.checkReady() }
    }

    @Test("a missing reply times out rather than hanging")
    func timeout() {
        let transport = MockTransport()
        let session = PrimeSession(transport: transport)
        #expect(throws: HPLinkError.self) { try session.checkReady(timeout: 0.05) }
    }
}


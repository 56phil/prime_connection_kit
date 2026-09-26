import Foundation

/// A logical message exchanged with the calculator: a command byte followed by
/// its argument bytes.
public struct PrimeMessage: Equatable, Sendable {
    public var command: PrimeCommand
    public var payload: [UInt8]

    public init(command: PrimeCommand, payload: [UInt8] = []) {
        self.command = command
        self.payload = payload
    }

    /// The wire representation: command byte, then payload.
    public var bytes: [UInt8] { [command.rawValue] + payload }

    /// Encodes a length-prefixed body, the shape used by every command that
    /// carries bulk data: `cmd, 0x01, length(4, big-endian), body`.
    ///
    /// The declared length is the count of bytes following the six-byte header.
    public static func withLengthHeader(
        command: PrimeCommand,
        body: [UInt8]
    ) -> PrimeMessage {
        let length = UInt32(body.count)
        let header: [UInt8] = [
            0x01,
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
        return PrimeMessage(command: command, payload: header + body)
    }
}

/// Builds outbound commands.
///
/// Each builder reproduces the byte layout of the corresponding
/// `calc_prime_s_*` function in `libhpcalcs/src/prime_cmd.c`.
public enum PrimeCommandBuilder {
    /// `0xFF` — liveness probe with no arguments.
    public static func checkReady() -> PrimeMessage {
        PrimeMessage(command: .checkReady)
    }

    /// `0xFA` — request device information.
    public static func getInfos() -> PrimeMessage {
        PrimeMessage(command: .getInfos)
    }

    /// `0xFC` — request a screen capture in the given format.
    public static func recvScreen(format: PrimeScreenshotFormat) -> PrimeMessage {
        PrimeMessage(command: .recvScreen, payload: [format.rawValue])
    }

    /// `0xF9` — request a full memory dump.
    public static func recvBackup() -> PrimeMessage {
        PrimeMessage(command: .recvBackup)
    }

    /// `0xE7` — set the real-time clock.
    ///
    /// The body is ten bytes: two unknown zero bytes, a fixed `0x54 0x1E` pair,
    /// then year-of-century, month, day, hour, minute, second.
    public static func setDateTime(_ date: Date, calendar: Calendar = .current) -> PrimeMessage {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let body: [UInt8] = [
            0x00, 0x00, 0x54, 0x1E,
            UInt8(truncatingIfNeeded: (parts.year ?? 2000) % 100),
            UInt8(truncatingIfNeeded: parts.month ?? 1),
            UInt8(truncatingIfNeeded: parts.day ?? 1),
            UInt8(truncatingIfNeeded: parts.hour ?? 0),
            UInt8(truncatingIfNeeded: parts.minute ?? 0),
            UInt8(truncatingIfNeeded: parts.second ?? 0),
        ]
        return .withLengthHeader(command: .setDateTime, body: body)
    }

    /// `0xEC` — inject a single key press.
    public static func sendKey(_ code: UInt8) -> PrimeMessage {
        PrimeMessage(command: .sendKey, payload: [0x01, 0x00, 0x00, 0x00, 0x01, code])
    }

    /// `0xEC` — inject a sequence of key presses.
    public static func sendKeys(_ codes: [UInt8]) -> PrimeMessage {
        .withLengthHeader(command: .sendKey, body: codes)
    }

    /// `0xF2` — send a chat message.
    ///
    /// The payload is UTF-16 little-endian. `String.utf16` yields host-endian
    /// code units, so each unit is written little-endian explicitly.
    public static func sendChat(_ text: String) -> PrimeMessage {
        var body: [UInt8] = []
        for unit in text.utf16 {
            body.append(UInt8(unit & 0xFF))
            body.append(UInt8(unit >> 8))
        }
        return .withLengthHeader(command: .chat, body: body)
    }

    /// `0xF8` — ask the calculator for one named object.
    public static func requestFile(name: String, type: PrimeFileType) throws -> PrimeMessage {
        try fileTransfer(command: .requestFile, name: name, type: type, content: nil)
    }

    /// `0xF7` — sends one object to the calculator.
    ///
    /// ## What a program transfer carries
    ///
    /// The payload for a program or a note is the **raw UTF-16 source text**, not
    /// the `.hpprgm` container that sits on disk. The calculator stores what it
    /// receives as text and terminates on a NUL, so sending a container makes it
    /// keep only the leading units before the first zero byte — which is why a
    /// program sent as a container arrives as a couple of stray characters.
    ///
    /// This was established by measuring both forms against a real calculator: the
    /// raw text round-trips exactly, while the container is truncated to its
    /// leading UTF-16 units. `libhpcalcs` records the same thing from the other
    /// direction, noting that "the leading metadata of `*.hpprgm`, if any, needs to
    /// be stripped manually" when sending.
    ///
    /// The container is therefore unwrapped here rather than at every call site, so
    /// an editor can hold whichever form it read and still save correctly.
    public static func sendFile(_ object: PrimeObject) throws -> PrimeMessage {
        let content = try transferPayload(for: object)
        return try fileTransfer(command: .recvFile, name: object.name, type: object.type, content: content)
    }

    /// The payload a transfer should carry for an object.
    ///
    /// Program and note objects are reduced to their text; everything else travels
    /// as stored.
    public static func transferPayload(for object: PrimeObject) throws -> [UInt8] {
        var content = object.content

        switch object.type {
        case .program, .appProgram:
            // Unwrap the container, keeping only the source text.
            if let decoded = try? PrimeProgramFile.decode(content) {
                content = PrimeObjectName.utf16LittleEndian(decoded.source)
            }
        default:
            break
        }

        // The firmware rejects a byte order mark on a program or note.
        if (object.type == .program || object.type == .note
            || object.type == .appProgram || object.type == .appNote),
           content.count >= 2, content[0] == 0xFF, content[1] == 0xFE {
            content.removeFirst(2)
        }

        return content
    }

    /// Builds the shared body of `0xF7`/`0xF8` messages.
    ///
    /// Layout: `cmd, 0x01, length(4, big-endian), type, nameLength, crc(2),
    /// name(UTF-16LE), [content]`. The declared length counts every byte after
    /// the six-byte header. The checksum covers the whole message except its
    /// final six bytes, with the checksum field read as zero — the rule the
    /// calculator applies when it validates incoming files and the one
    /// `libhpcalcs` applies when it validates replies.
    private static func fileTransfer(
        command: PrimeCommand,
        name: String,
        type: PrimeFileType,
        content: [UInt8]?
    ) throws -> PrimeMessage {
        let nameBytes = try PrimeObjectName.wireBytes(for: name)
        var body: [UInt8] = [
            type.rawValue,
            UInt8(nameBytes.count),
            0x00, 0x00,  // checksum placeholder
        ]
        body.append(contentsOf: nameBytes)
        if let content { body.append(contentsOf: content) }

        var message = PrimeMessage.withLengthHeader(command: command, body: body)

        // Checksum covers `message` minus its final six bytes, with the checksum
        // field zeroed. A request carries no content, so for a short name the
        // checksum field falls outside the covered region entirely; the reference
        // implementation then hashes the shorter span, which is why the zeroing is
        // conditional rather than unconditional.
        let coveredLength = message.bytes.count - 6
        var covered = Array(message.bytes[0..<coveredLength])
        HPCRC16.clearChecksumField(&covered, at: [8, 9])
        let checksum = HPCRC16.checksum(covered)

        // `message.bytes` is the command byte followed by `payload`, so the
        // checksum at message offsets 8 and 9 is at payload offsets 7 and 8.
        message.payload[7] = UInt8(checksum & 0xFF)
        message.payload[8] = UInt8(checksum >> 8)
        return message
    }
}

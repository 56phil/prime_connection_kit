import Foundation
import HPLink

/// Determines how this calculator generation expects a file write to be framed.
///
/// Motivated by a real incident: a program sent to a calculator was stored as its
/// first four bytes. Reading those stored bytes as UTF-16 little-endian explains
/// it — the calculator treats the payload as *text* and stops at the first NUL:
///
/// | sent | stored | as UTF-16 |
/// |---|---|---|
/// | `14 00 00 00 …` (this project's program) | 4 bytes | one control character, then a terminator |
/// | `7C 61 8A B2 FE FF FF FF 00 00 …` (HP's own `.hpprgm`) | 10 bytes | four units, then a terminator |
///
/// Both match exactly, which means the payload a program transfer carries is the
/// raw UTF-16 source text rather than the `.hpprgm` container that sits on disk.
/// `libhpcalcs`' README says as much — "the leading metadata of `*.hpprgm`, if
/// any, needs to be stripped manually" — and the container turns out to be the
/// *disk* form, which the calculator builds itself.
///
/// This sends the container and the raw text and reports which the calculator
/// keeps intact.
enum WriteExperiment {
    /// Payload forms to try.
    enum PayloadForm: String {
        case container = "the .hpprgm container as stored on disk"
        case rawText = "the raw UTF-16 program text"
    }

    static func run(descriptor: PrimeDeviceDescriptor) async throws {
        print("\n=== write framing experiment ===")

        // A payload long enough to need more than one report at 1023 bytes, so
        // the framing of *subsequent* reports is exercised too.
        var source = "EXPORT XE()\nBEGIN\n"
        for index in 0..<60 { source += "  // filler line \(index) to pad the program out\n" }
        source += "  RETURN 0;\nEND;"
        let payload = (try? PrimeProgramFile.encode(source: source, name: "XE"))
            ?? PrimeTextContent.encode(source)
        print("payload: \(payload.count) bytes")
        print("  head: \(hex(payload, limit: 16))")

        // A real program of moderate length, used as the text to transfer. It is
        // found by searching the working folder rather than by naming a calculator,
        // since the folder is named after whichever calculator was last connected
        // and its name is not this diagnostic's business.
        let text = Self.referenceProgram() ?? "EXPORT XE()\nBEGIN\n  RETURN 0;\nEND;"
        var rawText = PrimeObjectName.utf16LittleEndian(text)
        rawText.append(contentsOf: [0x00, 0x00])
        print("raw text payload: \(rawText.count) bytes for \(text.count) characters")

        // Compare the two forms: the container as stored on disk, and the raw
        // UTF-16 text. Only the second survives the calculator's text handling.
        // A single object name is used for both attempts, so repeated runs do not
        // accumulate objects. The link protocol has no delete command, so anything
        // this creates stays on the calculator until it is removed by hand.
        try await attempt(form: .container, payload: payload, label: "PCKExp", descriptor: descriptor)
        try await attempt(form: .rawText, payload: rawText, label: "PCKExp", descriptor: descriptor)
    }

    /// Finds a program in the working folder to use as transfer text.
    ///
    /// The longest program available is chosen, because the point of the experiment
    /// is to show how a *multi-report* transfer survives — a short program would not
    /// exercise the framing at all. Returns `nil` when the folder holds no programs,
    /// in which case the caller falls back to a built-in stub.
    ///
    /// The calculator is not named here: its folder is called whatever the
    /// calculator is called, which is the user's business and not this
    /// diagnostic's.
    static func referenceProgram() -> String? {
        let folder = PrimeWorkingFolder(root: PrimeWorkingFolder.defaultURL)
        guard let calculators = try? folder.calculatorNames() else { return nil }

        var best: String?
        for calculator in calculators {
            guard let objects = try? folder.objects(inCalculatorFolder: calculator) else { continue }
            for object in objects where object.type == .program {
                guard let decoded = try? PrimeProgramFile.decode(object.content) else { continue }
                if best == nil || decoded.source.count > best!.count { best = decoded.source }
            }
        }
        return best
    }

    static func attempt(
        form: PayloadForm,
        payload: [UInt8],
        label: String,
        descriptor: PrimeDeviceDescriptor
    ) async throws {
        print("\n--- \(form.rawValue) ---")

        let name = label
        let object = PrimeObject(name: name, type: .program, content: payload)
        let message = try PrimeCommandBuilder.sendFile(object)

        // The standard framing, which is already known to reach the calculator:
        // the stored bytes it produced are exactly the payload's leading UTF-16
        // units, so the transport carries the payload correctly.
        let reports = PrimePacketCodec.fragment(message.bytes, payloadCapacity: 1023)
            .map { [$0.sequence] + $0.payload }
        print("  message \(message.bytes.count) bytes → \(reports.count) report(s)")
        for (index, report) in reports.enumerated() {
            print("    [\(index)] \(report.count) bytes: \(hex(report, limit: 12))")
        }

        let connection = try PrimeHIDConnection(descriptor: descriptor)
        let session = PrimeSession(transport: connection)
        defer { connection.close() }

        guard try session.checkReady(timeout: 5) else {
            print("  the calculator is not answering")
            return
        }

        connection.flushPendingReports()
        // Reports are written through the transport's own report layer, bypassing
        // the session's framing so this controls it explicitly.
        for report in reports {
            try connection.write(report: [0x00] + report)
        }
        print("  written; reading back…")

        try await Task.sleep(nanoseconds: 3_000_000_000)
        connection.flushPendingReports()

        let inventory = try session.receiveBackup().objects
        guard let stored = inventory.first(where: { $0.name == name && $0.type == .program }) else {
            print("  ✗ not stored under “\(name)”")
            return
        }

        // Compare the stored program's *text* with what was sent, because a
        // program read back arrives in the container form.
        let storedText = (try? PrimeProgramFile.decode(stored.content))?.source
            ?? PrimeTextContent.decode(stored.content)
        let expectedText = (try? PrimeProgramFile.decode(payload))?.source
            ?? PrimeTextContent.decode(payload)

        print("  sent \(expectedText.count) chars, stored \(storedText.count) chars")
        if storedText == expectedText {
            print("  ✓ STORED INTACT")
        } else {
            print("  ✗ differs")
            print("    sent:   \(String(expectedText.prefix(60)).debugDescription)")
            print("    stored: \(String(storedText.prefix(60)).debugDescription)")
        }
    }

    static func hex(_ bytes: [UInt8], limit: Int = 64) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? "\(shown) … (\(bytes.count))" : shown
    }
}

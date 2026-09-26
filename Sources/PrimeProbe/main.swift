import Foundation
import HPLink

/// A command-line diagnostic for talking to an attached HP Prime.
///
/// The link protocol has changed between firmware generations, and the only
/// authority on what a given calculator accepts is the calculator itself. This
/// tool exists so that can be established by experiment rather than inferred: it
/// enumerates the attached devices, reports their USB identity and report size,
/// and then exercises the protocol against the real hardware.
///
/// It is also useful on its own for checking whether a calculator is reachable
/// and whether macOS is permitting access to it.
///
/// Usage:
/// ```
/// swift run PrimeProbe                    # enumerate and probe
/// swift run PrimeProbe --framing 64       # force a report size
/// swift run PrimeProbe --skip-write       # read-only checks
/// ```
@main
struct PrimeProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        let forcedFraming: Int? = {
            guard let index = arguments.firstIndex(of: "--framing"), index + 1 < arguments.count
            else { return nil }
            return Int(arguments[index + 1])
        }()
        let skipWrite = arguments.contains("--skip-write")

        banner()
        guard let target = enumerate() else { return }

        if arguments.contains("--experiment") {
            do { try await WriteExperiment.run(descriptor: target) }
            catch { print("experiment failed: \(describe(error))") }
            return
        }

        let reportSize = forcedFraming ?? PrimeHIDConnection.maximumReportSize(for: target)
        print("\nUsing a \(reportSize)-byte report (\(reportSize - 1) payload bytes).")

        print("\nOpening the device…")
        let connection: PrimeHIDConnection
        do {
            connection = try PrimeHIDConnection(descriptor: target, reportSize: reportSize)
        } catch {
            reportOpenFailure(error)
            return
        }
        defer { connection.close() }
        print("  opened. Payload capacity \(connection.payloadCapacity) bytes.")

        let session = PrimeSession(transport: connection)

        probeReadiness(session)
        probeInformation(session)
        probeScreen(session)
        probeBackup(session)
        if !skipWrite { await probeWrite(session, connection: connection) }

        print("\nDone.")
    }

    // MARK: - Discovery

    static func banner() {
        print("Prime Connection Kit — link diagnostic")
        print(String(repeating: "=", count: 60))
    }

    static func enumerate() -> PrimeDeviceDescriptor? {
        let devices = PrimeHIDEnumerator.connectedDevices()
        print("\nDevices matching HP (vendor 0x\(String(format: "%04X", PrimeUSB.vendorID))):")
        if devices.isEmpty { print("  none") }

        for device in devices {
            print("""
              • \(device.discoveryLabel)
                  product ID   0x\(String(format: "%04X", device.productID))
                  reports      \(device.maximumInputReportSize) in / \(device.maximumOutputReportSize) out\
            \(device.usesLargeReports ? "  (large framing)" : "  (small framing)")
                  registry ID  \(device.id)
                  location     0x\(String(format: "%X", device.locationID))
                  serial       \(device.serialNumber ?? "—")
            """)
        }

        // A new firmware revision would otherwise be invisible, which is exactly
        // how the 1024-byte generation escaped the published sources.
        let unrecognised = PrimeHIDEnumerator.allHewlettPackardDevices()
            .filter { !PrimeUSB.knownProductIDs.contains($0.productID) }
        if !unrecognised.isEmpty {
            print("\nHP devices with an unrecognised product ID:")
            for device in unrecognised {
                print("  • \(device.discoveryLabel)  product ID 0x\(String(format: "%04X", device.productID))")
            }
        }

        guard let target = devices.first else {
            print("\nNo calculator to probe.")
            return nil
        }
        return target
    }

    static func reportOpenFailure(_ error: Error) {
        print("  FAILED: \(describe(error))")
        if case HPLinkError.deviceOpenFailed = error {
            print("""

              macOS refused access to the HID device. Grant the terminal (or the
              app) permission under System Settings → Privacy & Security →
              Input Monitoring, then try again.
              """)
        }
    }

    // MARK: - Checks

    /// Readiness, with the raw reply shown because the two firmware generations
    /// answer differently.
    static func probeReadiness(_ session: PrimeSession) {
        print("\nReadiness probe (0xFF)…")
        do {
            let raw = try session.rawExchange(PrimeCommandBuilder.checkReady(), timeout: 5)
            print("  reply: \(hex(raw))")
            print("  interpreted as: \(try session.checkReady(timeout: 5) ? "ready" : "not ready")")
        } catch {
            print("  FAILED: \(describe(error))")
        }
    }

    static func probeInformation(_ session: PrimeSession) {
        print("\nDevice information (0xFA)…")
        do {
            let information = try session.deviceInformation(timeout: 8)
            print("  reply of \(information.raw.count) bytes")
            for (label, value) in information.summaryLines {
                print("    \(label): \(value)")
            }
        } catch {
            print("  FAILED: \(describe(error))")
        }
    }

    static func probeScreen(_ session: PrimeSession) {
        print("\nScreen capture (0xFC)…")
        do {
            let image = try session.captureScreen(timeout: 15)
            print("  received \(image.count) bytes; PNG: \(PrimeScreenReply.isPNG(image))")
            let path = "/tmp/prime-probe-screen.png"
            try Data(image).write(to: URL(fileURLWithPath: path))
            print("  written to \(path)")
        } catch {
            print("  FAILED: \(describe(error))")
        }
    }

    /// Reads a named object.
    ///
    /// The calculator does not answer a `0xF8` request for a name it does not
    /// recognise, and its reply to one it does hold is worth inspecting, so this
    /// shows the raw bytes either way. The backup stream is the reliable way to
    /// enumerate content; this is for looking at one object closely.
    static func probeNamedObject(_ session: PrimeSession) {
        print("\nNamed object request (0xF8)…")
        do {
            let raw = try session.rawExchange(
                try PrimeCommandBuilder.requestFile(name: "first_primes", type: .program),
                timeout: 4
            )
            print("  reply: \(hex(raw, limit: 48))")
            if let object = try? PrimeFileReply.parse(raw) {
                let decoded = try? PrimeProgramFile.decode(object.content)
                print("  parsed: \(object.type.displayName) “\(object.name)”, \(object.content.count) bytes")
                if let decoded {
                    print("  source is \(decoded.source.count) characters")
                    print("  contains “marker-from-app”: \(decoded.source.contains("marker-from-app"))")
                }
            }
        } catch {
            print("  no reply (the calculator only answers for names it holds).")
        }
    }

    /// The backup stream: the only reliable way to enumerate what a calculator
    /// contains, and the strongest check that both directions of framing work.
    static func probeBackup(_ session: PrimeSession) -> [PrimeObject] {
        print("\nBackup stream (0xF9)…")
        do {
            let result = try session.receiveBackup(timeout: 8)
            print("  received \(result.objects.count) objects, \(result.damagedCount) damaged")
            var byType: [PrimeFileType: Int] = [:]
            for object in result.objects { byType[object.type, default: 0] += 1 }
            for (type, count) in byType.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("    \(count)  \(type.displayName)")
            }

            // Show each object's exact name and type. The names are what the
            // calculator reports on the wire, which is what the on-disk naming has
            // to agree with — HP's settings objects, for instance, already carry
            // their `.hpsettings` suffix in the name itself.
            if CommandLine.arguments.contains("--dump-names") {
                for object in result.objects.sorted(by: { $0.name < $1.name }) {
                    print("    \(object.type.displayName)\t<\(object.name)>")
                }
            }

            // Show each program's source, which is how an edit made in the app can
            // be seen to have reached the calculator.
            for object in result.objects where object.type == .program {
                let decoded = try? PrimeProgramFile.decode(object.content)
                let text = decoded?.source ?? PrimeTextContent.decode(object.content)
                let marker = text.contains("marker-from-app") ? "  ← contains app's edit" : ""
                print("    \(object.name): \(object.content.count) bytes, \(text.count) chars\(marker)")
                if object.content.count < 64 {
                    print("        hex: " + hex(object.content, limit: 64))
                }
            }
            return result.objects
        } catch {
            print("  FAILED: \(describe(error))")
            return []
        }
    }

    /// Settles whether a write reaches the calculator.
    ///
    /// The calculator sends no acknowledgement for a file write, so the only
    /// evidence that one landed is that the object appears afterwards. The
    /// calculator's contents are listed before and after the write and the
    /// difference is reported.
    static func probeWrite(_ session: PrimeSession, connection: PrimeHIDConnection) async {
        print("\nWrite test (backup / send / backup)…")
        let probeName = "PCKProbe"
        do {
            let before = try session.receiveBackup(timeout: 8)
            let namesBefore = Set(before.objects.map(\.name))
            print("  before: \(before.objects.count) objects")

            let source = "EXPORT PCKProbe(N)\nBEGIN\n  RETURN N*2;\nEND;"
            let program = (try? PrimeProgramFile.encode(source: source, name: probeName))
                ?? PrimeTextContent.encode(source)
            let outgoing = PrimeObject(name: probeName, type: .program, content: program)

            let message = try PrimeCommandBuilder.sendFile(outgoing)
            let packets = PrimePacketCodec.fragment(message.bytes, payloadCapacity: connection.payloadCapacity)
            print("  sending \(probeName): \(program.count) bytes, \(message.bytes.count) framed, \(packets.count) report(s)")
            print("  header: \(hex(Array(message.bytes.prefix(24))))")

            do {
                try session.sendObject(outgoing, timeout: 3)
                print("  acknowledged.")
            } catch HPLinkError.timeout {
                print("  no acknowledgement (this firmware sends none).")
            }

            // Let the calculator commit to flash, then re-list.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            connection.flushPendingReports()
            let after = try session.receiveBackup(timeout: 8)
            let appeared = Set(after.objects.map(\.name)).subtracting(namesBefore)

            print("  after: \(after.objects.count) objects")
            if appeared.contains(probeName) {
                print("  ✓ \(probeName) is now on the calculator — the write landed.")
            } else if appeared.isEmpty {
                print("  ✗ no new object: the write did not land.")
            } else {
                print("  new objects: \(appeared.sorted().joined(separator: ", "))")
            }
        } catch {
            print("  FAILED: \(describe(error))")
        }
    }

    // MARK: - Helpers

    /// Renders bytes as hex for inspection.
    static func hex(_ bytes: [UInt8], limit: Int = 64) -> String {
        let shown = bytes.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > limit ? "\(shown) … (\(bytes.count) bytes)" : shown
    }

    /// Renders an error usefully.
    static func describe(_ error: Error) -> String {
        if let linkError = error as? HPLinkError, let description = linkError.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }
}

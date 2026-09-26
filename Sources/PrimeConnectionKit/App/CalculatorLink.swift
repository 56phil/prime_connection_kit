import Foundation
import HPLink

/// Blocking calculator operations, deliberately outside the main actor.
///
/// Everything here waits on the USB link: a readiness probe takes a moment, a
/// device-information reply a little longer, and a full backup roughly twenty
/// seconds. Running any of it on the main actor freezes the interface, which is
/// exactly what happened before this was split out — connecting to a real
/// calculator blocked the window for minutes.
///
/// The type is a plain namespace rather than an actor because the session
/// serialises its own wire access and the calls are made from a detached task.
/// Nothing here touches application state.
enum CalculatorLink {
    /// The result of reading everything a calculator holds.
    struct Inventory: Sendable {
        var information: PrimeDeviceInformation
        var objects: [PrimeObject]
    }

    /// Opens a device and reads its identity and contents.
    ///
    /// - Throws: ``HPLinkError`` when the device cannot be opened or does not
    ///   answer. The caller reports the failure; this function never throws away
    ///   a connection on a recoverable error, because the caller owns its
    ///   lifetime.
    static func openAndInventory(_ descriptor: PrimeDeviceDescriptor) throws -> (PrimeHIDConnection, PrimeSession, Inventory) {
        let connection = try PrimeHIDConnection(descriptor: descriptor)
        let session = PrimeSession(transport: connection)

        do {
            guard try session.checkReady(timeout: 5) else {
                throw HPLinkError.transportFailure("the calculator did not answer the readiness check")
            }
            let information = try session.deviceInformation(timeout: 8)
            let objects = try inventory(from: session)
            return (connection, session, Inventory(information: information, objects: objects))
        } catch {
            // The caller receives no connection, so this is where it is closed.
            connection.close()
            throw error
        }
    }

    /// Object types the Connectivity Kit lists for a calculator, in its order.
    static let enumeratedTypes: [PrimeFileType] = [
        .application, .real, .complex, .list, .matrix, .note, .program, .examConfiguration,
    ]

    /// Names to probe for each enumerated type.
    ///
    /// The protocol has no "list the objects" command: an object is fetched by
    /// name, and names normally come from the backup stream. The Home variables
    /// have fixed names, so they can also be requested directly.
    static func probeNames(for type: PrimeFileType) -> [String] {
        switch type {
        case .real:
            // A–Z plus theta.
            (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) } + ["\u{03B8}"]
        case .complex:
            (0...9).map { "Z\($0)" }
        case .list:
            (0...9).map { "L\($0)" }
        case .matrix:
            (0...9).map { "M\($0)" }
        case .application, .note, .program, .examConfiguration, .appNote, .appProgram, .settings:
            []
        }
    }

    /// Reads a calculator's contents.
    ///
    /// The backup stream is the authoritative and by far the fastest way to learn
    /// what a calculator holds: one request returns every object with its real
    /// name, measured at roughly twenty seconds for a full calculator, and it is
    /// what the Connectivity Kit itself uses to populate its calculator pane.
    ///
    /// The alternative — requesting the Home variables by name — costs a
    /// multi-second timeout for every name the calculator does *not* hold, and
    /// there are fifty-seven of them. Trying that on real hardware blocked the
    /// session for minutes and made the application unusable, so named requests
    /// are only used to fill gaps, and always with a short timeout.
    static func inventory(from session: PrimeSession) throws -> [PrimeObject] {
        var objects: [PrimeObject] = []
        var seen = Set<String>()

        let backup = try session.receiveBackup()
        for object in backup.objects where !seen.contains(object.id) {
            seen.insert(object.id)
            objects.append(object)
        }

        for type in enumeratedTypes where !probeNames(for: type).isEmpty {
            for name in probeNames(for: type) {
                let id = "\(type.rawValue):\(name)"
                guard !seen.contains(id) else { continue }
                guard let object = try? session.receiveObject(name: name, type: type, timeout: 0.6),
                      !object.content.isEmpty
                else { continue }
                seen.insert(id)
                objects.append(object)
            }
        }

        return objects
    }

    /// Sends an object and mirrors it, off the main actor.
    static func send(_ object: PrimeObject, to session: PrimeSession) throws {
        try session.sendObject(object)
    }
}

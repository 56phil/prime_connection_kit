import Foundation

/// A live protocol session with one HP Prime.
///
/// The session owns the request/response discipline: it fragments a command into
/// reports, drains the reply, and validates framing. Every operation is
/// synchronous; callers run them off the main thread.
///
/// Requests are serialised by ``operationLock`` so concurrent callers cannot
/// interleave reports on the wire, which the calculator would reject.
public final class PrimeSession: @unchecked Sendable {
    /// How long to wait for the first report of a reply.
    ///
    /// The Connectivity Kit allows eight seconds because a screenshot can take
    /// several seconds to begin arriving.
    public static let defaultReplyTimeout: TimeInterval = 8

    private let transport: PrimeTransport
    private let operationLock = NSRecursiveLock()
    private var isOpen = true

    public init(transport: PrimeTransport) {
        self.transport = transport
    }

    /// Whether the session is still usable.
    public var isUsable: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return isOpen
    }

    /// Marks the session closed. Subsequent operations fail fast.
    public func close() {
        operationLock.lock()
        isOpen = false
        operationLock.unlock()
    }

    // MARK: - Liveness

    /// Probes the calculator.
    ///
    /// Two reply shapes are in use, both established from real hardware and from
    /// the reference implementation:
    ///
    /// * The older generation echoes the command byte, `0xFF`.
    /// * Current firmware answers `'Y'` (`0x59`), which is what a Prime reporting
    ///   itself as `V2.060.650` sends, measured on attached hardware.
    ///
    /// Both mean ready. This matters because the readiness probe is the first
    /// thing every session does: treating `'Y'` as failure would make a
    /// perfectly reachable calculator look unreachable.
    ///
    /// - Returns: `true` if the calculator answered.
    public func checkReady(timeout: TimeInterval = defaultReplyTimeout) throws -> Bool {
        let reply = try perform(.checkReady, timeout: timeout)
        guard let first = reply.first else { return false }
        return first == PrimeCommand.checkReady.rawValue || first == Self.affirmativeReply
    }

    /// The reply current firmware gives to a readiness probe.
    public static let affirmativeReply: UInt8 = 0x59  // 'Y'

    // MARK: - Device information

    /// Fetches the calculator's self-description.
    public func deviceInformation(timeout: TimeInterval = defaultReplyTimeout) throws -> PrimeDeviceInformation {
        let reply = try perform(.getInfos, timeout: timeout)
        return PrimeDeviceInformation(raw: reply)
    }

    /// Sets the calculator's clock.
    public func setDateTime(_ date: Date, timeout: TimeInterval = defaultReplyTimeout) throws {
        // The calculator acknowledges writes with a ready-check, so a failed
        // probe afterwards is the only observable signal of a rejected value.
        _ = try perform(.setDateTime, timeout: timeout, expectingReply: false)
        if transport.hasPendingReport { transport.flushPendingReports() }
        _ = try? checkReady(timeout: timeout)
    }

    // MARK: - Screen capture

    /// Captures the calculator's display.
    ///
    /// - Returns: the image bytes, which for ``PrimeScreenshotFormat/png320x240x16``
    ///   are a PNG file.
    public func captureScreen(
        format: PrimeScreenshotFormat = .png320x240x16,
        timeout: TimeInterval = defaultReplyTimeout
    ) throws -> [UInt8] {
        let reply = try perform(.recvScreen, argument: [format.rawValue], timeout: timeout)
        return try PrimeScreenReply.parse(reply, format: format)
    }

    // MARK: - Files

    /// Asks the calculator for one object.
    ///
    /// - Returns: the object, or `nil` when the calculator reported that it does
    ///   not hold one by that name.
    public func receiveObject(
        name: String,
        type: PrimeFileType,
        timeout: TimeInterval = defaultReplyTimeout
    ) throws -> PrimeObject? {
        let message = try PrimeCommandBuilder.requestFile(name: name, type: type)
        let reply = try perform(message, timeout: timeout)
        return try PrimeFileReply.parse(reply)
    }

    /// Sends one object to the calculator.
    ///
    /// Acknowledging behaviour differs by firmware generation, and both cases are
    /// handled:
    ///
    /// * Older firmware answers with a readiness reply, and a `0xF9` frame means
    ///   it refused the transfer.
    /// * Current firmware — measured on a Prime reporting `V2.060.650` — sends
    ///   **nothing at all**. Waiting for a reply there would report a failure for
    ///   a write that in fact succeeded, which was confirmed by listing the
    ///   calculator's contents before and after.
    ///
    /// A late acknowledgement is harmless: every request discards buffered reports
    /// before it sends, so a stale reply cannot be mistaken for the next answer.
    /// Transport failures still propagate, because those mean the write genuinely
    /// did not happen.
    public func sendObject(_ object: PrimeObject, timeout: TimeInterval = defaultReplyTimeout) throws {
        let message = try PrimeCommandBuilder.sendFile(object)

        do {
            let reply = try perform(message, timeout: min(timeout, Self.writeAcknowledgementWindow))
            // An F9 frame means the calculator refused the transfer, which
            // happens when its firmware is too old to accept content.
            if reply.first == PrimeCommand.recvBackup.rawValue {
                throw HPLinkError.unsupportedOperation(
                    "The calculator refused the transfer. Its firmware may be too old; update it from a Windows computer first."
                )
            }
        } catch HPLinkError.timeout {
            // No acknowledgement, which is normal on current firmware.
        }
    }

    /// How long to wait for a write acknowledgement before assuming the firmware
    /// does not send one.
    ///
    /// Short on purpose: nothing arrives at all in the no-acknowledgement case, so
    /// waiting longer only slows every transfer down.
    public static let writeAcknowledgementWindow: TimeInterval = 1.5

    /// Sends several objects in sequence.
    public func sendObjects(_ objects: [PrimeObject], timeout: TimeInterval = defaultReplyTimeout) throws {
        for object in objects {
            try sendObject(object, timeout: timeout)
        }
    }

    // MARK: - Backup

    /// Downloads the whole calculator, one object at a time.
    ///
    /// The calculator streams objects until it sends a terminator. Frames that
    /// fail their checksum are reported rather than silently dropped, because a
    /// truncated backup would look like data loss.
    public func receiveBackup(timeout: TimeInterval = defaultReplyTimeout) throws -> (objects: [PrimeObject], damagedCount: Int) {
        _ = try perform(.recvBackup, timeout: timeout, expectingReply: false)

        var objects: [PrimeObject] = []
        var damaged = 0
        let maximumObjects = 20_000

        for _ in 0..<maximumObjects {
            let reply = try readReply(for: .recvFile, timeout: timeout)

            // An F9 frame is the end-of-dump marker.
            if reply.first == PrimeCommand.recvBackup.rawValue { break }

            guard let object = try? PrimeFileReply.parse(reply) else {
                if reply.isEmpty { break }
                damaged += 1
                continue
            }
            objects.append(object)
        }
        return (objects, damaged)
    }

    // MARK: - Chat

    /// Sends a message to the calculator's Message Center.
    public func sendMessage(_ text: String, timeout: TimeInterval = defaultReplyTimeout) throws {
        _ = try perform(.chat, argument: Array(PrimeCommandBuilder.sendChat(text).payload.dropFirst()), timeout: timeout, expectingReply: false)
        if transport.hasPendingReport { transport.flushPendingReports() }
    }

    // MARK: - Request plumbing

    /// Sends a pre-built message and returns its raw reply.
    ///
    /// This is the same path every operation takes; it is exposed so the reply
    /// parsers, and the diagnostic tool, can see the bytes as received.
    public func rawExchange(_ message: PrimeMessage, timeout: TimeInterval = defaultReplyTimeout) throws -> [UInt8] {
        try withOperation {
            transport.flushPendingReports()
            try send(message)
            return try readReply(for: message.command, timeout: timeout)
        }
    }

    /// Sends a command and waits for its reply, validating the framing.
    private func perform(
        _ command: PrimeCommand,
        argument: [UInt8] = [],
        timeout: TimeInterval,
        expectingReply: Bool = true
    ) throws -> [UInt8] {
        try withOperation {
            // A stale reply from a previous timeout must not be mistaken for
            // this request's answer.
            transport.flushPendingReports()

            try send(PrimeMessage(command: command, payload: argument))
            guard expectingReply else { return [] }
            return try readReply(for: command, timeout: timeout)
        }
    }

    private func perform(
        _ message: PrimeMessage,
        timeout: TimeInterval,
        expectingReply: Bool = true
    ) throws -> [UInt8] {
        try withOperation {
            transport.flushPendingReports()
            try send(message)
            guard expectingReply else { return [] }
            return try readReply(for: message.command, timeout: timeout)
        }
    }

    /// Fragments and writes a message.
    private func send(_ message: PrimeMessage) throws {
        for packet in PrimePacketCodec.fragment(message.bytes, payloadCapacity: transport.payloadCapacity) {
            try transport.send(packet)
        }
    }

    /// Reassembles a reply, using the command's declared length to know when to
    /// stop rather than waiting for a timeout.
    private func readReply(for command: PrimeCommand, timeout: TimeInterval) throws -> [UInt8] {
        var reassembler = PrimePacketCodec.Reassembler(payloadCapacity: transport.payloadCapacity)
        var expectedLength: Int?

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HPLinkError.timeout }

            let report = try transport.readReport(timeout: remaining)
            let packet = PrimeRawPacket(parsing: report, capacity: transport.payloadCapacity)

            let complete = try reassembler.append(packet)

            // Once the first report has arrived the reply declares its own size.
            if expectedLength == nil, reassembler.message.count >= 6 || command == .checkReady {
                expectedLength = try PrimePacketCodec.declaredReplyLength(
                    for: command,
                    firstBytes: reassembler.message
                )
            }

            if let expectedLength {
                if reassembler.message.count >= expectedLength {
                    return Array(reassembler.message.prefix(expectedLength))
                }
                // A terminating short report before the declared length means the
                // calculator truncated the transfer.
                if complete {
                    throw HPLinkError.truncatedReply(
                        expectedBytes: expectedLength,
                        actualBytes: reassembler.message.count
                    )
                }
            } else if complete {
                return reassembler.message
            }
        }
    }

    /// Runs `body` with the wire held exclusively.
    private func withOperation<T>(_ body: () throws -> T) throws -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard isOpen else { throw HPLinkError.sessionClosed }
        return try body()
    }
}

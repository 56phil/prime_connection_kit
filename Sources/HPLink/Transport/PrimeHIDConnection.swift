import Foundation
import IOKit
import IOKit.hid

/// USB identifiers for HP Prime calculators.
///
/// Three product IDs are in use. The first two come from the public
/// reverse-engineering work; the third was read from a real calculator attached
/// to this machine, which reports it and is not covered by any published source.
public enum PrimeUSB {
    /// Hewlett-Packard's USB vendor ID.
    public static let vendorID = 0x03F0

    /// Prime running early firmware, with 64-byte HID reports.
    public static let productIDPrime1 = 0x0441
    /// A product ID the prior art cites for firmware build 8151 or later.
    public static let productIDPrime2 = 0x1541
    /// The current generation, observed on real hardware: a Prime reporting
    /// 1024-byte input and output reports.
    public static let productIDPrime3 = 0x2441

    /// Every product ID we attempt to drive.
    public static let knownProductIDs = [productIDPrime1, productIDPrime2, productIDPrime3]

    /// Names for the product IDs, used when reporting what was found.
    public static func name(forProductID productID: Int) -> String? {
        switch productID {
        case productIDPrime1: "HP Prime (64-byte reports)"
        case productIDPrime2: "HP Prime (64-byte reports)"
        case productIDPrime3: "HP Prime (1024-byte reports)"
        default: nil
        }
    }
}

/// An attached HP Prime calculator.
public struct PrimeDeviceDescriptor: Identifiable, Hashable, Sendable {
    /// IORegistry entry ID, stable for the lifetime of the attachment. Used to
    /// reopen the device after enumeration.
    public let id: UInt64
    public let vendorID: Int
    public let productID: Int
    public let productName: String?
    public let serialNumber: String?
    public let locationID: Int
    /// The maximum input report the device declares, in bytes.
    ///
    /// This is the authority on the framing to use: real hardware reports 1024,
    /// while the older 64-byte generation reports 64. It is read from the device
    /// rather than assumed, because guessing wrong makes every message
    /// unintelligible to the calculator.
    public let maximumInputReportSize: Int
    /// The maximum output report the device declares.
    public let maximumOutputReportSize: Int

    /// Whether this is the 1024-byte generation.
    public var usesLargeReports: Bool { maximumInputReportSize > 64 }

    /// Label for the calculator pane. The Connectivity Kit names calculators by
    /// their *calculator name*, which is only known once a session is open, so
    /// this is a discovery-time placeholder.
    public var discoveryLabel: String {
        if let productName, !productName.isEmpty { return productName }
        return PrimeUSB.name(forProductID: productID) ?? "HP Prime Calculator"
    }
}

/// Errors specific to the IOKit layer.
enum PrimeHIDDiagnostic {
    /// Renders an `IOReturn` the way `mach_error_string` would.
    static func describe(_ code: IOReturn) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        let printable = !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber }
        return String(format: "0x%08X%@", code, printable ? " (\(text))" : "")
    }
}

/// Enumerates attached HP Prime calculators through IOKit.
///
/// Matching is done on the IOService plane rather than through an `IOHIDManager`,
/// so no run loop is required to discover devices.
public enum PrimeHIDEnumerator {
    /// Every attached Prime, in IORegistry order.
    public static func connectedDevices() -> [PrimeDeviceDescriptor] {
        var descriptors: [PrimeDeviceDescriptor] = []
        for productID in PrimeUSB.knownProductIDs {
            descriptors.append(contentsOf: devices(vendorID: PrimeUSB.vendorID, productID: productID))
        }
        return descriptors
    }

    /// Every attached HP HID device, including product IDs we do not recognise.
    ///
    /// A new firmware revision would otherwise be invisible, which is exactly the
    /// situation that hid the 1024-byte generation from the published sources.
    public static func allHewlettPackardDevices() -> [PrimeDeviceDescriptor] {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) else { return [] }
        let properties = unsafeBitCast(matching, to: NSMutableDictionary.self)
        properties[kIOHIDVendorIDKey] = PrimeUSB.vendorID

        return collect(from: matching)
    }

    private static func devices(vendorID: Int, productID: Int) -> [PrimeDeviceDescriptor] {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) else { return [] }

        // `IOServiceMatching` returns a +1 dictionary whose ownership transfers to
        // `IOServiceGetMatchingServices`. Fields are set before that hand-off,
        // because a `CFMutableDictionary` is only bridgeable to
        // `NSMutableDictionary` after a cast.
        let properties = unsafeBitCast(matching, to: NSMutableDictionary.self)
        properties[kIOHIDVendorIDKey] = vendorID
        properties[kIOHIDProductIDKey] = productID

        return collect(from: matching)
    }

    /// Runs a matching query and describes every device it yields.
    ///
    /// Takes ownership of `matching`, which `IOServiceGetMatchingServices`
    /// consumes.
    private static func collect(from matching: CFMutableDictionary) -> [PrimeDeviceDescriptor] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [PrimeDeviceDescriptor] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS,
                  let device = IOHIDDeviceCreate(kCFAllocatorDefault, entry)
            else { continue }

            result.append(
                PrimeDeviceDescriptor(
                    id: entryID,
                    vendorID: Self.integer(device, kIOHIDVendorIDKey) ?? 0,
                    productID: Self.integer(device, kIOHIDProductIDKey) ?? 0,
                    productName: Self.string(device, kIOHIDProductKey),
                    serialNumber: Self.string(device, kIOHIDSerialNumberKey),
                    locationID: Self.integer(device, kIOHIDLocationIDKey) ?? 0,
                    maximumInputReportSize: Self.integer(device, kIOHIDMaxInputReportSizeKey) ?? 64,
                    maximumOutputReportSize: Self.integer(device, kIOHIDMaxOutputReportSizeKey) ?? 64
                )
            )
        }
        return result
    }

    private static func integer(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

/// A live connection to one HP Prime, speaking the report layer of the protocol.
///
/// ## Report size
///
/// Two framings are in use, and they are not interchangeable: a message sent with
/// the wrong one arrives as unintelligible bytes. The older generation uses
/// 64-byte reports carrying 63 payload bytes; the current generation declares
/// 1024-byte reports carrying 1023. The size is taken from the device descriptor
/// rather than assumed, which is also why ``PrimePacketCodec`` is parameterised
/// by it.
///
/// Writing is done directly from the caller's thread, matching `hidapi`. Reading
/// relies on an input-report callback, which IOKit only delivers on a run loop, so
/// the device is scheduled on a run loop owned by a dedicated thread.
public final class PrimeHIDConnection: PrimeTransport, @unchecked Sendable {
    private let descriptor: PrimeDeviceDescriptor
    /// Payload bytes per report, which is the framing this connection uses.
    public let reportSize: Int
    private let device: IOHIDDevice
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferLength: CFIndex

    /// Guards ``pendingReports`` and drives ``readReport(timeout:)``.
    private let condition = NSCondition()
    private var pendingReports: [[UInt8]] = []
    private var isClosed = false
    private var removalError: String?

    private var runLoop: CFRunLoop?
    private let threadReady = DispatchSemaphore(value: 0)
    private let threadFinished = DispatchSemaphore(value: 0)

    /// The framing a device should be driven with.
    ///
    /// The device's declared report size is authoritative, but it is clamped to
    /// the two framings the protocol is known to use, so a device advertising
    /// something unexpected does not produce arbitrary behaviour.
    public static func maximumReportSize(for descriptor: PrimeDeviceDescriptor) -> Int {
        descriptor.usesLargeReports ? PrimeRawPacket.largeReportSize
                                     : PrimeRawPacket.smallReportSize
    }

    /// Opens the device identified by `descriptor`.
    ///
    /// - Parameter reportSize: the payload capacity per report. Defaults to what
    ///   the device declares.
    /// - Throws: ``HPLinkError/deviceNotFound`` if the device has been detached,
    ///   or ``HPLinkError/deviceOpenFailed(_:)`` if IOKit refuses the open, which
    ///   on macOS normally means a missing Input Monitoring entitlement.
    public init(descriptor: PrimeDeviceDescriptor, reportSize: Int? = nil) throws {
        self.descriptor = descriptor
        self.reportSize = reportSize ?? PrimeHIDConnection.maximumReportSize(for: descriptor)

        guard let entry = PrimeHIDConnection.serviceEntry(id: descriptor.id),
              let device = IOHIDDeviceCreate(kCFAllocatorDefault, entry)
        else {
            throw HPLinkError.deviceNotFound
        }
        self.device = device
        IOObjectRelease(entry)

        // IOKit delivers reports without the report ID, so the buffer is one byte
        // shorter than the wire report.
        let declared = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue
            ?? PrimeRawPacket.smallReportSize
        self.inputBufferLength = CFIndex(max(declared, self.reportSize))
        self.inputBuffer = .allocate(capacity: self.inputBufferLength)
        self.inputBuffer.initialize(repeating: 0, count: self.inputBufferLength)

        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            inputBuffer.deinitialize(count: self.inputBufferLength)
            inputBuffer.deallocate()
            throw HPLinkError.deviceOpenFailed(PrimeHIDDiagnostic.describe(status))
        }

        startRunLoopThread()
    }

    deinit { close() }

    /// The device this connection is attached to.
    public var deviceDescriptor: PrimeDeviceDescriptor { descriptor }

    /// Payload bytes per report: the report size less the sequence byte.
    public var payloadCapacity: Int { reportSize - 1 }

    // MARK: - Run loop thread

    private func startRunLoopThread() {
        let thread = Thread { [self] in
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                device, inputBuffer, inputBufferLength, primeInputReportCallback, context
            )
            IOHIDDeviceRegisterRemovalCallback(device, primeDeviceRemovalCallback, context)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

            runLoop = CFRunLoopGetCurrent()
            threadReady.signal()

            // Idles until `close()` stops the loop; the timeout keeps the thread
            // responsive to cancellation.
            while !isClosed {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            threadFinished.signal()
        }
        thread.name = "com.primeconnectionkit.hid"
        thread.qualityOfService = .userInitiated
        thread.start()
        threadReady.wait()
    }

    // MARK: - PrimeTransport

    /// Sends one report. `bytes` carries the leading report ID byte that the HID
    /// stack expects for unnumbered reports, and the length is not padded so a
    /// short report still signals the end of a message.
    public func write(report bytes: [UInt8]) throws {
        guard !isClosed else { throw HPLinkError.sessionClosed }
        guard !bytes.isEmpty else { throw HPLinkError.transportFailure("empty report") }

        // The Prime uses unnumbered reports: report ID 0, and the identifier is
        // not transmitted. Anything else would prepend a byte on the wire.
        let reportID = bytes[0]
        let body = Array(bytes.dropFirst())
        guard !body.isEmpty else { throw HPLinkError.transportFailure("report has no payload") }

        let status = body.withUnsafeBufferPointer { buffer -> IOReturn in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), buffer.baseAddress!, body.count)
        }
        guard status == kIOReturnSuccess else {
            throw HPLinkError.transportFailure("write failed: \(PrimeHIDDiagnostic.describe(status))")
        }
    }

    /// Waits for the next report from the device.
    ///
    /// - Throws: ``HPLinkError/timeout`` if nothing arrives, or
    ///   ``HPLinkError.transportFailure(_:)`` if the device was detached.
    public func readReport(timeout: TimeInterval) throws -> [UInt8] {
        condition.lock()
        defer { condition.unlock() }

        let deadline = Date().addingTimeInterval(timeout)
        while pendingReports.isEmpty {
            if isClosed { throw HPLinkError.sessionClosed }
            if let removalError { throw HPLinkError.transportFailure(removalError) }
            guard condition.wait(until: deadline) else { throw HPLinkError.timeout }
        }
        return pendingReports.removeFirst()
    }

    /// Reports whether a report is already buffered, without blocking.
    public var hasPendingReport: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !pendingReports.isEmpty
    }

    /// Discards buffered reports. Used to resynchronise after a timeout.
    public func flushPendingReports() {
        condition.lock()
        pendingReports.removeAll(keepingCapacity: true)
        condition.unlock()
    }

    // MARK: - Teardown

    /// Unschedules, closes and joins the run loop thread. Safe to call twice.
    public func close() {
        condition.lock()
        if isClosed {
            condition.unlock()
            return
        }
        isClosed = true
        condition.broadcast()
        condition.unlock()

        // Stopping the run loop lets the thread observe `isClosed` and exit,
        // after which the device may be unscheduled safely.
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
            threadFinished.wait()
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputBufferLength, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(device, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deinitialize(count: inputBufferLength)
        inputBuffer.deallocate()
    }

    // MARK: - Callbacks

    fileprivate func deliverInputReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))

        condition.lock()
        pendingReports.append(bytes)
        // Keep a bounded backlog: the protocol is request/response, so a large
        // queue only ever means we are not draining stale traffic.
        if pendingReports.count > 256 { pendingReports.removeFirst() }
        condition.broadcast()
        condition.unlock()
    }

    fileprivate func deviceRemoved(status: IOReturn) {
        condition.lock()
        isClosed = true
        removalError = "the calculator was disconnected (\(PrimeHIDDiagnostic.describe(status)))"
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Helpers

    private static func serviceEntry(id: UInt64) -> io_service_t? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        return entry == 0 ? nil : entry
    }
}

// MARK: - C callback trampolines

private func primeInputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    Unmanaged<PrimeHIDConnection>.fromOpaque(context).takeUnretainedValue()
        .deliverInputReport(report, length: reportLength)
}

private func primeDeviceRemovalCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<PrimeHIDConnection>.fromOpaque(context).takeUnretainedValue()
        .deviceRemoved(status: result)
}

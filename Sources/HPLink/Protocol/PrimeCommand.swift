import Foundation

/// Commands exchanged with an HP Prime calculator over the HID link.
///
/// Values are taken from `libhpcalcs/src/prime_cmd.h`, which documents them as
/// empirically derived from USB packet captures.
public enum PrimeCommand: UInt8, Sendable {
    /// Liveness probe. Reply is a single packet.
    case checkReady = 0xFF
    /// Request device information. Reply carries a big-endian length.
    case getInfos = 0xFA
    /// Capture the display. Payload byte selects the screenshot format.
    case recvScreen = 0xFC
    /// Request a full memory dump, delivered as a stream of ``requestFile`` replies.
    case recvBackup = 0xF9
    /// Calculator-initiated notification that a file transfer follows.
    case requestFile = 0xF8
    /// File content, in both directions.
    case recvFile = 0xF7
    /// Bidirectional text message channel.
    case chat = 0xF2
    /// Inject a key press (remote control).
    case sendKey = 0xEC
    /// Set the calculator's real-time clock.
    case setDateTime = 0xE7
}

/// Format selector for ``PrimeCommand/recvScreen``.
///
/// The 320×240 16-colour PNG (`8`) is what the calculator reports as its native
/// screen size; the remaining values are believed to be downscaled or
/// reduced-palette variants.
public enum PrimeScreenshotFormat: UInt8, CaseIterable, Sendable {
    case png320x240x16 = 8
    case png320x240x4 = 9
    case png160x120x16 = 10
    case png160x120x4 = 11

    public var pixelSize: (width: Int, height: Int) {
        switch self {
        case .png320x240x16, .png320x240x4: (320, 240)
        case .png160x120x16, .png160x120x4: (160, 120)
        }
    }
}

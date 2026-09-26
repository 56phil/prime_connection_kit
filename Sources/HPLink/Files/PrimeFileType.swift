import Foundation

/// File type codes used on the wire and in the calculator's memory dump.
///
/// These match `libhpcalcs/src/typesprime.h`; the naming follows HP's own
/// terminology in the Connectivity Kit user guide.
public enum PrimeFileType: UInt8, CaseIterable, Sendable {
    case settings = 0x00
    case application = 0x02
    case list = 0x03
    case matrix = 0x04
    case note = 0x05
    case program = 0x06
    case appNote = 0x07
    case appProgram = 0x08
    case complex = 0x09
    case real = 0x0A
    case examConfiguration = 0x0B

    /// Human-readable name, matching the Connectivity Kit's own labels.
    public var displayName: String {
        switch self {
        case .settings: "Settings"
        case .application: "Application"
        case .list: "List"
        case .matrix: "Matrix"
        case .note: "Note"
        case .program: "Program"
        case .appNote: "App Note"
        case .appProgram: "App Program"
        case .complex: "Complex"
        case .real: "Real"
        case .examConfiguration: "Exam Configuration"
        }
    }
}

/// On-disk file extensions for calculator content.
///
/// The Connectivity Kit uses these in its working folder, and the calculator
/// uses the same extensions in backups. The mapping follows `PRIME_CONST` in
/// `libhpcalcs/src/typesprime.c` plus the additional extensions the Connectivity
/// Kit itself writes, which are visible in `~/Documents/HP Connectivity Kit`.
public enum PrimeFileExtension {
    /// Extensions the Connectivity Kit is known to produce, keyed by type.
    public static func `default`(for type: PrimeFileType) -> String {
        switch type {
        case .settings: "hpsettings"
        case .application: "hpapp"
        case .list: "hplist"
        case .matrix: "hpmat"
        case .note: "hpnote"
        case .program: "hpprgm"
        case .appNote: "hpappnote"
        case .appProgram: "hpappprgm"
        case .complex: "hpcomplex"
        case .real: "hpreal"
        case .examConfiguration: "hpexammode"
        }
    }

    /// Every extension accepted when importing a file dragged onto the app.
    ///
    /// `hpmatrix` is the alternate spelling `libhpcalcs` records, and
    /// `hpappvars` is the variable bag the Connectivity Kit stores beside an app.
    public static let allKnown: [String: PrimeFileType] = {
        var map: [String: PrimeFileType] = [:]
        for type in PrimeFileType.allCases {
            map[`default`(for: type)] = type
        }
        map["hpmatrix"] = .matrix
        return map
    }()

    /// Resolves a file extension to a content type, case-insensitively.
    public static func type(forExtension ext: String) -> PrimeFileType? {
        allKnown[ext.lowercased()]
    }
}

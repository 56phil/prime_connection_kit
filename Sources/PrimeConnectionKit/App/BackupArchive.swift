import Foundation
import HPLink

/// The Backup and Restore archive format.
///
/// The Connectivity Kit writes a zip file containing one entry per calculator
/// object, named the way the calculator's own memory holds them. Using an
/// ordinary zip keeps backups inspectable and means a backup taken here can be
/// opened by any archiver.
///
/// ## Member naming
///
/// Members keep the calculator's own file names and extensions, so the archive is
/// self-describing:
///
/// ```
/// <Calculator Name>/<Name>.hpprgm
/// <Calculator Name>/<Name>.hpnote
/// <Calculator Name>/<&App>.hpappdir/<&App>.hpapp
/// ```
///
/// The format is implemented on top of `Foundation`'s archive support rather than
/// a zip library, so the app has no third-party dependencies.
public enum BackupArchive {
    /// Writes objects into a zip file, returning its URL.
    public static func write(
        objects: [PrimeObject],
        calculatorName: String,
        into directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter.primeBackupFormatter.string(from: Date())
        let safeName = calculatorName.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeName) \(stamp).zip")

        // Stage the objects in a temporary directory, then archive that, because
        // Foundation's archiving works from existing files.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("prime-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let root = staging.appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for object in objects {
            let prefix = object.isBuiltIn ? String(PrimeObjectName.builtInPrefix) : ""
            if object.type == .application || object.type == .appNote || object.type == .appProgram {
                let package = root.appendingPathComponent("\(prefix)\(object.name).hpappdir", isDirectory: true)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let extensionName = PrimeFileExtension.default(for: object.type)
                try Data(object.content).write(
                    to: package.appendingPathComponent("\(prefix)\(object.name).\(extensionName)")
                )
            } else {
                let file = root.appendingPathComponent(
                    PrimeObjectName.diskName(for: object.name, type: object.type, isBuiltIn: object.isBuiltIn)
                )
                try Data(object.content).write(to: file)
            }
        }

        try archiveDirectory(at: staging, to: url)
        return url
    }

    /// Reads objects back out of a backup archive.
    public static func read(_ url: URL) throws -> [PrimeObject] {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("prime-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try extractArchive(at: url, into: staging)

        // The archive may or may not have a top-level calculator folder; look for
        // content from whichever level holds files.
        let folder = PrimeWorkingFolder(root: staging)
        var objects = (try? folder.contentObjects()) ?? []
        if objects.isEmpty {
            // Descend into a single child directory, which is the calculator
            // folder the writer created.
            let children = (try? FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDirectory else { continue }
                objects.append(contentsOf: (try? PrimeWorkingFolder(root: child).contentObjects()) ?? [])
            }
        }

        guard !objects.isEmpty else {
            throw HPLinkError.malformedContent("the archive contains no recognisable calculator objects")
        }
        return objects
    }

    // MARK: - Archive plumbing

    /// Creates a zip file from a directory using `ditto`, which is present on
    /// every macOS installation and preserves the directory structure and
    /// resource metadata that Finder and the Connectivity Kit both produce.
    private static func archiveDirectory(at source: URL, to destination: URL) throws {
        try runDitto(["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path])
    }

    /// Expands a zip file into a directory.
    private static func extractArchive(at source: URL, into destination: URL) throws {
        try runDitto(["-x", "-k", source.path, destination.path])
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw HPLinkError.transportFailure("the archive tool failed: \(message)")
        }
    }
}

extension ISO8601DateFormatter {
    /// Timestamp format used in backup file names, matching the Connectivity
    /// Kit's readable style while staying filename-safe.
    static let primeBackupFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withColonSeparatorInTime]
        return formatter
    }()
}

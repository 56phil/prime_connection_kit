import Foundation

/// Reads and writes the Connectivity Kit's working folder.
///
/// The layout reproduces exactly what the Connectivity Kit leaves on disk, so the
/// two applications can share one folder and neither will be surprised by the
/// other's files:
///
/// ```
/// <root>/
/// ├── Calculators/<Calculator Name>/
/// │   ├── Custom Mode.hpexammode
/// │   ├── <Name>.hpprgm, <Name>.hpnote, <Name>.hplist, …
/// │   └── <&App>.hpappdir/
/// │       ├── <&App>.hpapp        application variable bag
/// │       ├── <&App>.hpappnote    application Info note
/// │       └── <&App>.hpappprgm    application program
/// ├── Content/
/// │   ├── Exam Modes/
/// │   └── Results/
/// ├── Backups/
/// ├── Documentation/
/// ├── Firmware/
/// └── Temp/
/// ```
public final class PrimeWorkingFolder: @unchecked Sendable {
    /// Directory names, matching the Connectivity Kit verbatim.
    public enum Directory {
        public static let calculators = "Calculators"
        public static let content = "Content"
        public static let examModes = "Exam Modes"
        public static let results = "Results"
        public static let backups = "Backups"
        public static let documentation = "Documentation"
        public static let firmware = "Firmware"
        public static let temp = "Temp"
    }

    /// The folder the Connectivity Kit uses by default on this system.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/HP Connectivity Kit", isDirectory: true)
    }

    public let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    /// Creates any missing top-level folders. Called before the first write so
    /// the app can adopt a fresh location without requiring manual setup.
    @discardableResult
    public func createLayoutIfNeeded() throws -> Bool {
        var created = false
        for relative in [
            Directory.calculators,
            "\(Directory.content)/\(Directory.examModes)",
            "\(Directory.content)/\(Directory.results)",
            Directory.backups,
            Directory.documentation,
            Directory.firmware,
            Directory.temp,
        ] {
            let url = root.appendingPathComponent(relative, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                created = true
            }
        }
        return created
    }

    // MARK: - Locations

    public var calculatorsURL: URL { root.appendingPathComponent(Directory.calculators, isDirectory: true) }
    public var contentURL: URL { root.appendingPathComponent(Directory.content, isDirectory: true) }
    public var backupsURL: URL { root.appendingPathComponent(Directory.backups, isDirectory: true) }
    public var tempURL: URL { root.appendingPathComponent(Directory.temp, isDirectory: true) }

    /// The folder holding one calculator's mirrored content.
    public func calculatorURL(named name: String) -> URL {
        calculatorsURL.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Calculator folders

    /// Calculator folders present on disk, sorted by name.
    public func calculatorNames() throws -> [String] {
        guard fileManager.fileExists(atPath: calculatorsURL.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: calculatorsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Deletes a calculator's mirrored folder.
    public func removeCalculatorFolder(named name: String) throws {
        let url = calculatorURL(named: name)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Renames a calculator's mirrored folder.
    public func renameCalculatorFolder(from oldName: String, to newName: String) throws {
        let source = calculatorURL(named: oldName)
        let destination = calculatorURL(named: newName)
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.moveItem(at: source, to: destination)
    }

    // MARK: - Reading

    /// Every object mirrored for one calculator.
    ///
    /// Failures on individual entries are skipped rather than propagated, so one
    /// unreadable file cannot hide the rest of the calculator's contents.
    public func objects(inCalculatorFolder name: String) throws -> [PrimeObject] {
        let folder = calculatorURL(named: name)
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        return try objects(in: folder, builtInNames: Self.builtInAppNames())
    }

    /// Every object stored in the content pane's folders.
    public func contentObjects() throws -> [PrimeObject] {
        guard fileManager.fileExists(atPath: contentURL.path) else { return [] }
        var result: [PrimeObject] = []
        let entries = try fileManager.contentsOfDirectory(
            at: contentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                result.append(contentsOf: (try? objects(in: entry, builtInNames: [])) ?? [])
            } else if let object = try? readObject(at: entry, builtInNames: []) {
                result.append(object)
            }
        }
        return result
    }

    /// Scans a directory for calculator content.
    private func objects(in directory: URL, builtInNames: Set<String>) throws -> [PrimeObject] {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var result: [PrimeObject] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                // An `.hpappdir` is one application plus its sidecar files.
                if entry.pathExtension.lowercased() == "hpappdir",
                   let app = try? readApplicationPackage(at: entry) {
                    result.append(contentsOf: app)
                } else {
                    result.append(contentsOf: (try? objects(in: entry, builtInNames: builtInNames)) ?? [])
                }
            } else if let object = try? readObject(at: entry, builtInNames: builtInNames) {
                result.append(object)
            }
        }
        return result
    }

    /// Reads a single content file.
    private func readObject(at url: URL, builtInNames: Set<String>) throws -> PrimeObject {
        guard let type = Self.contentType(for: url) else {
            throw HPLinkError.malformedContent("unrecognised extension “.\(url.pathExtension)”")
        }
        let parsed = PrimeObjectName.parse(diskName: url.lastPathComponent, type: type)
        return PrimeObject(
            name: parsed.name,
            type: type,
            // The `&` prefix marks factory objects. Two kinds are additionally
            // recognised by name, because the Connectivity Kit does not mark them
            // on disk:
            //   * applications that ship with the calculator, so a copy saved under
            //     a new name is still recognised as factory content;
            //   * the “Custom Mode” exam configuration, which is the one the
            //     calculator always provides — the user guide states that at least
            //     one configuration must always exist, and that this one can be
            //     reset but not deleted.
            isBuiltIn: parsed.isBuiltIn
                || (type == .application && builtInNames.contains(parsed.name))
                || (type == .examConfiguration && parsed.name == Self.builtInExamConfigurationName),
            content: Array(try Data(contentsOf: url))
        )
    }

    /// The exam configuration every calculator has and which cannot be removed.
    public static let builtInExamConfigurationName = "Custom Mode"

    /// Resolves a working-folder file to its content type.
    ///
    /// Most files are identified by their extension. Settings are the exception:
    /// the Connectivity Kit stores them under names the calculator itself chose —
    /// `calc.hpsettings`, `cas.hpsettings`, `calc.hpvars` and `settings` — so two
    /// of the four have no extension this app recognises, and `settings` has none
    /// at all. They are matched by name instead, which is also what keeps
    /// `calc.hpvars` (whose `.hpvars` suffix belongs to its name) from being read
    /// as some future type that happens to share the extension.
    public static func contentType(for url: URL) -> PrimeFileType? {
        let fileName = url.lastPathComponent.lowercased()
        if Self.settingsFileNames.contains(fileName) { return .settings }
        return PrimeFileExtension.type(forExtension: url.pathExtension)
    }

    /// The settings files the Connectivity Kit writes, by their exact names.
    ///
    /// Measured from a real working folder and confirmed against the calculator,
    /// which reports these same four names as its Settings objects.
    public static let settingsFileNames: Set<String> = [
        "settings", "calc.hpsettings", "cas.hpsettings", "calc.hpvars",
    ]

    /// Reads an `.hpappdir` into the application plus its sidecar objects.
    ///
    /// The Connectivity Kit stores an application as up to three files sharing
    /// the app's name: the variable bag (`.hpapp`, the application itself), the
    /// Info note (`.hpappnote`) and the program (`.hpappprgm`). The `&` prefix is
    /// applied to the directory *and* to every file inside it.
    private func readApplicationPackage(at directory: URL) throws -> [PrimeObject] {
        let parsedDirectory = PrimeObjectName.parse(diskName: directory.lastPathComponent)
        var objects: [PrimeObject] = []

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for entry in entries {
            let extensionName = entry.pathExtension.lowercased()
            guard let type: PrimeFileType = switch extensionName {
            case "hpapp": .application
            case "hpappnote": .appNote
            case "hpappprgm": .appProgram
            default: nil
            } else { continue }

            let parsed = PrimeObjectName.parse(diskName: entry.lastPathComponent)
            objects.append(
                PrimeObject(
                    name: parsed.name,
                    type: type,
                    isBuiltIn: parsed.isBuiltIn || parsedDirectory.isBuiltIn,
                    content: Array(try Data(contentsOf: entry))
                )
            )
        }

        // A directory with no `.hpapp` still represents an app; synthesise an
        // empty application so it does not vanish from the pane.
        if !objects.contains(where: { $0.type == .application }) {
            objects.insert(
                PrimeObject(
                    name: parsedDirectory.name,
                    type: .application,
                    isBuiltIn: parsedDirectory.isBuiltIn,
                    content: []
                ),
                at: 0
            )
        }
        return objects
    }

    // MARK: - Writing

    /// Writes an object into a calculator folder, creating the folder and the
    /// application package as needed.
    public func save(_ object: PrimeObject, toCalculatorFolder calculator: String) throws {
        let folder = calculatorURL(named: calculator)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(object, into: folder)
    }

    /// Writes an object into the content pane.
    public func saveToContent(_ object: PrimeObject, folder subfolder: String? = nil) throws {
        var destination = contentURL
        if let subfolder { destination.appendPathComponent(subfolder, isDirectory: true) }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try write(object, into: destination)
    }

    private func write(_ object: PrimeObject, into directory: URL) throws {
        try PrimeObjectName.validate(object.name)

        let prefix = object.isBuiltIn ? String(PrimeObjectName.builtInPrefix) : ""

        if object.type == .application || object.type == .appNote || object.type == .appProgram {
            let package = directory.appendingPathComponent(
                "\(prefix)\(object.name).hpappdir", isDirectory: true
            )
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)

            // Sidecar files share the app directory's `&` state.
            let fileName: String
            switch object.type {
            case .application: fileName = "\(prefix)\(object.name).hpapp"
            case .appNote: fileName = "\(prefix)\(object.name).hpappnote"
            default: fileName = "\(prefix)\(object.name).hpappprgm"
            }
            try Data(object.content).write(to: package.appendingPathComponent(fileName))
            return
        }

        let fileName = PrimeObjectName.diskName(for: object.name, type: object.type, isBuiltIn: object.isBuiltIn)
        try Data(object.content).write(to: directory.appendingPathComponent(fileName))
    }

    /// Deletes an object, removing an application's whole package directory.
    public func delete(_ object: PrimeObject, fromCalculatorFolder calculator: String) throws {
        let folder = calculatorURL(named: calculator)
        try delete(object, in: folder)
    }

    /// Deletes an object from the content pane.
    public func deleteFromContent(_ object: PrimeObject, folder subfolder: String? = nil) throws {
        var destination = contentURL
        if let subfolder { destination.appendPathComponent(subfolder, isDirectory: true) }
        try delete(object, in: destination)
    }

    private func delete(_ object: PrimeObject, in directory: URL) throws {
        guard object.isDeletable else {
            throw HPLinkError.unsupportedOperation(
                "“\(object.name)” is a built-in \(object.type.displayName.lowercased()) and cannot be deleted."
            )
        }

        let prefix = object.isBuiltIn ? String(PrimeObjectName.builtInPrefix) : ""

        if object.type == .application {
            // Deleting an application removes its entire package.
            let package = directory.appendingPathComponent("\(prefix)\(object.name).hpappdir", isDirectory: true)
            if fileManager.fileExists(atPath: package.path) {
                try fileManager.removeItem(at: package)
            }
            return
        }

        if object.type == .appNote || object.type == .appProgram {
            let package = directory.appendingPathComponent("\(prefix)\(object.name).hpappdir", isDirectory: true)
            let extensionName = PrimeFileExtension.default(for: object.type)
            let file = package.appendingPathComponent("\(prefix)\(object.name).\(extensionName)")
            if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
            return
        }

        let fileName = PrimeObjectName.diskName(for: object.name, type: object.type, isBuiltIn: object.isBuiltIn)
        let file = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: file.path) { try fileManager.removeItem(at: file) }
    }

    /// Replaces an object's payload with nothing while keeping the object, which
    /// is what the Connectivity Kit's *Clear* command does for variables.
    public func clear(_ object: PrimeObject, inCalculatorFolder calculator: String) throws {
        guard object.isClearable else {
            throw HPLinkError.unsupportedOperation(
                "“\(object.name)” does not hold clearable data."
            )
        }
        var emptied = object
        emptied.content = []
        try save(emptied, toCalculatorFolder: calculator)
    }

    // MARK: - Backups

    /// The `.zip` files the Connectivity Kit produced, newest first.
    public func backups() -> [URL] {
        guard fileManager.fileExists(atPath: backupsURL.path),
              let entries = try? fileManager.contentsOfDirectory(
                at: backupsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        return entries
            .filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
    }

    // MARK: - Built-in applications

    /// Names of the applications that ship with the Prime, used to decide
    /// whether a copied app is still factory content.
    ///
    /// Taken from the folders the Connectivity Kit created in this working
    /// folder, cross-checked against the Connectivity Kit's own application
    /// vocabulary.
    public static func builtInAppNames() -> Set<String> {
        [
            "Advanced Graphing", "Data Streamer", "Explorer", "Finance", "Function",
            "Geometry", "Graph 3D", "Inference", "Linear Solver", "Parametric",
            "Polar", "Sequence", "Solve", "Spreadsheet", "Statistics 1Var",
            "Statistics 2Var", "Triangle Solver",
        ]
    }
}


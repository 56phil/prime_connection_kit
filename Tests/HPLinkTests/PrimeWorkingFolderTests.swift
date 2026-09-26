import Foundation
import Testing
@testable import HPLink

/// Exercises the working-folder store against a realistic tree laid out the way
/// the Connectivity Kit leaves it on disk.
///
/// A temporary directory is built for each test, so nothing here depends on the
/// machine's own working folder.
@Suite("Working folder")
struct PrimeWorkingFolderTests {
    /// Creates a throwaway working folder with the standard layout.
    static func makeFolder() throws -> PrimeWorkingFolder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prime-work-folder-\(UUID().uuidString)", isDirectory: true)
        let folder = PrimeWorkingFolder(root: root)
        try folder.createLayoutIfNeeded()
        return folder
    }

    /// Removes a folder created by ``makeFolder()``.
    static func cleanUp(_ folder: PrimeWorkingFolder) {
        try? FileManager.default.removeItem(at: folder.root)
    }

    @Test("the standard layout is created")
    func layoutCreation() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        let manager = FileManager.default
        for relative in [
            "Calculators",
            "Content/Exam Modes",
            "Content/Results",
            "Backups",
            "Documentation",
            "Firmware",
            "Temp",
        ] {
            let url = folder.root.appendingPathComponent(relative)
            #expect(manager.fileExists(atPath: url.path), "\(relative) was not created")
        }

        // Creating twice is a no-op rather than an error.
        #expect(try folder.createLayoutIfNeeded() == false)
    }

    @Test("an object saved for a calculator reads back unchanged")
    func calculatorRoundTrip() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        let content: [UInt8] = Array("EXPORT F() BEGIN END;".utf8)
        let program = PrimeObject(name: "Demo", type: .program, content: content)
        try folder.save(program, toCalculatorFolder: "MyCalc")

        let objects = try folder.objects(inCalculatorFolder: "MyCalc")
        let loaded = try #require(objects.first { $0.type == .program })
        #expect(loaded.name == "Demo")
        #expect(loaded.content == content)
        #expect(loaded.isBuiltIn == false)
    }

    @Test("an application is stored as a package directory with its sidecars")
    func applicationPackage() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        let appBytes: [UInt8] = [0x7C, 0x61, 0x8A, 0xB2] + [UInt8](repeating: 0, count: 20)
        let app = PrimeObject(name: "Function", type: .application, isBuiltIn: true, content: appBytes)
        let note = PrimeObject(name: "Function", type: .appNote, isBuiltIn: true, content: PrimeNoteFile.encode(text: "", reusing: nil, isAppNote: true))

        try folder.save(app, toCalculatorFolder: "MyCalc")
        try folder.save(note, toCalculatorFolder: "MyCalc")

        // The package layout must match the Connectivity Kit's, including the
        // built-in marker on the directory and on every file inside it.
        let manager = FileManager.default
        let package = folder.calculatorURL(named: "MyCalc").appendingPathComponent("&Function.hpappdir")
        #expect(manager.fileExists(atPath: package.appendingPathComponent("&Function.hpapp").path))
        #expect(manager.fileExists(atPath: package.appendingPathComponent("&Function.hpappnote").path))

        let objects = try folder.objects(inCalculatorFolder: "MyCalc")
        #expect(objects.contains { $0.type == .application && $0.isBuiltIn })
        #expect(objects.contains { $0.type == .appNote })

        let reloadedApp = try #require(objects.first { $0.type == .application })
        #expect(reloadedApp.content == appBytes)
    }

    @Test("a saved application container is never rewritten")
    func applicationContentPreserved() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        // A realistic container: the magic plus an arbitrary body.
        var bytes = PrimeProgramFile.containerMagic
        bytes.append(contentsOf: (0..<200).map { UInt8($0 % 251) })
        let app = PrimeObject(name: "Custom", type: .application, content: bytes)
        try folder.save(app, toCalculatorFolder: "MyCalc")

        let reloaded = try #require(
            try folder.objects(inCalculatorFolder: "MyCalc").first { $0.type == .application }
        )
        #expect(reloaded.content == bytes)
    }

    @Test("calculator names come from the folders on disk")
    func calculatorListing() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        // Two names that sort differently from the order they are created in, so
        // the listing is shown to be sorted rather than merely to be complete.
        try folder.save(PrimeObject(name: "P", type: .program, content: [0x41]), toCalculatorFolder: "Zeta")
        try folder.save(PrimeObject(name: "P", type: .program, content: [0x41]), toCalculatorFolder: "Alpha")

        let names = try folder.calculatorNames()
        #expect(names == ["Alpha", "Zeta"])
    }

    @Test("renaming a calculator moves its folder")
    func calculatorRename() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        try folder.save(PrimeObject(name: "P", type: .program, content: [0x41]), toCalculatorFolder: "Old")
        try folder.renameCalculatorFolder(from: "Old", to: "New")

        #expect(try folder.calculatorNames() == ["New"])
        #expect(try folder.objects(inCalculatorFolder: "New").count == 1)
    }

    @Test("a built-in application cannot be deleted, only a user one can")
    func deletionRules() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        let builtIn = PrimeObject(name: "Function", type: .application, isBuiltIn: true)
        #expect(builtIn.isDeletable == false)
        #expect(throws: HPLinkError.self) {
            try folder.delete(builtIn, fromCalculatorFolder: "MyCalc")
        }

        let userApp = PrimeObject(name: "MyApp", type: .application, isBuiltIn: false, content: [0x01])
        try folder.save(userApp, toCalculatorFolder: "MyCalc")
        #expect(try folder.objects(inCalculatorFolder: "MyCalc").count == 1)
        try folder.delete(userApp, fromCalculatorFolder: "MyCalc")
        #expect(try folder.objects(inCalculatorFolder: "MyCalc").isEmpty)
    }

    @Test("an exam configuration is not deletable when built in")
    func examModeDeletionRule() {
        // At least one configuration must always exist, so the built-in one is
        // resettable but not removable.
        #expect(PrimeObject(name: "Custom Mode", type: .examConfiguration, isBuiltIn: true).isDeletable == false)
        #expect(PrimeObject(name: "Midterm", type: .examConfiguration, isBuiltIn: false).isDeletable)
    }

    @Test("deleting a program removes only that file")
    func programDeletion() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        try folder.save(PrimeObject(name: "Keep", type: .program, content: [0x01]), toCalculatorFolder: "MyCalc")
        try folder.save(PrimeObject(name: "Drop", type: .program, content: [0x02]), toCalculatorFolder: "MyCalc")
        try folder.delete(PrimeObject(name: "Drop", type: .program), fromCalculatorFolder: "MyCalc")

        let remaining = try folder.objects(inCalculatorFolder: "MyCalc")
        #expect(remaining.map(\.name) == ["Keep"])
    }

    @Test("content-pane objects are grouped by the folder they came from")
    func contentObjects() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        try folder.saveToContent(PrimeObject(name: "Quiz", type: .program, content: [0x01]), folder: "Programs")
        try folder.saveToContent(PrimeObject(name: "Midterm", type: .examConfiguration, content: [0x02]), folder: "Exam Modes")

        let objects = try folder.contentObjects()
        #expect(objects.count == 2)
        #expect(objects.contains { $0.name == "Quiz" })
        #expect(objects.contains { $0.name == "Midterm" })
    }

    @Test("unrecognised files are skipped rather than failing the scan")
    func foreignFilesIgnored() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        try folder.save(PrimeObject(name: "Good", type: .program, content: [0x01]), toCalculatorFolder: "MyCalc")
        // Something a user might have dropped in by hand.
        try Data("not calculator content".utf8).write(
            to: folder.calculatorURL(named: "MyCalc").appendingPathComponent("notes.txt")
        )
        try Data([0xDE, 0xAD]).write(
            to: folder.calculatorURL(named: "MyCalc").appendingPathComponent(".hidden")
        )

        let objects = try folder.objects(inCalculatorFolder: "MyCalc")
        #expect(objects.map(\.name) == ["Good"])
    }

    @Test("backups are listed newest first")
    func backupListing() throws {
        let folder = try Self.makeFolder()
        defer { Self.cleanUp(folder) }

        let older = folder.backupsURL.appendingPathComponent("older.zip")
        let newer = folder.backupsURL.appendingPathComponent("newer.zip")
        try Data([0x50, 0x4B]).write(to: older)
        try Data([0x50, 0x4B]).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: newer.path
        )
        // A non-zip file must not be mistaken for a backup.
        try Data([0x00]).write(to: folder.backupsURL.appendingPathComponent("stray.bin"))

        #expect(folder.backups().map(\.lastPathComponent) == ["newer.zip", "older.zip"])
    }

    @Test("the built-in application names cover the calculator's library")
    func builtInAppNames() {
        let names = PrimeWorkingFolder.builtInAppNames()
        // These are the applications the Connectivity Kit marks with `&` on this
        // machine, so a saved copy of one is still recognised as factory content.
        for expected in ["Function", "Advanced Graphing", "Statistics 2Var", "Geometry", "Solve"] {
            #expect(names.contains(expected), "\(expected) is missing")
        }
        #expect(names.count == 17)
    }
}

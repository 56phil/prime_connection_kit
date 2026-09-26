import Foundation
import Testing
@testable import HPLink

/// Pins the content codecs against real files, so the formats are verified rather
/// than assumed.
///
/// The fixtures are genuine calculator content: two `.hpprgm` programs, an app
/// note, two `.hpapp` application containers (one from a calculator, one from a
/// project template) and an exam-mode configuration produced by HP's Connectivity
/// Kit on this machine.
@Suite("Content formats")
struct ContentFormatTests {
    /// Loads a fixture, failing loudly when it is missing.
    static func fixture(_ name: String) throws -> [UInt8] {
        // `resources: [.copy("Fixtures")]` copies the directory itself, so the
        // files live in a `Fixtures` subdirectory of the resource bundle.
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: nil)
        else {
            throw HPLinkError.malformedContent("the fixture “\(name)” is missing from the test bundle")
        }
        return Array(try Data(contentsOf: url))
    }

    // MARK: - Programs

    @Test("a real program parses and reports its embedded name")
    func programWithName() throws {
        let bytes = try Self.fixture("Graphics.hpprgm")
        let decoded = try PrimeProgramFile.decode(bytes)

        guard case .plain(named: true) = decoded.layout else {
            Issue.record("expected the plain named layout, got \(decoded.layout)")
            return
        }
        #expect(decoded.embeddedName == "Graphics")
        #expect(decoded.preservesVariables)

        // The real file's program text starts with a pragma and is 750 bytes.
        #expect(decoded.source.contains("#pragma mode"))
        #expect(decoded.source.contains("BEGIN"))
        #expect(decoded.source.contains("END;"))
    }

    @Test("the named layout's length field is where the parser expects it")
    func programHeaderArithmetic() throws {
        let bytes = try Self.fixture("Graphics.hpprgm")

        // The fixture is 790 bytes with an 8-character name. Independently
        // recompute the offsets the parser relies on.
        #expect(bytes.count == 790)
        #expect(PrimeProgramFile.readUInt32(bytes, at: 8) == 1)
        #expect(PrimeProgramFile.readUInt16(bytes, at: 16) == 0x0031)

        // Name occupies 18..33, terminator at 34..35, size at 36.
        let size = try #require(PrimeProgramFile.readUInt32(bytes, at: 36))
        #expect(size == 750)
        #expect(40 + Int(size) == bytes.count)
    }

    @Test("a program survives a decode and encode round trip")
    func programRoundTrip() throws {
        let bytes = try Self.fixture("Graphics.hpprgm")
        let decoded = try PrimeProgramFile.decode(bytes)

        // Re-encoding the decoded source with the same name must reproduce the
        // original file, byte for byte.
        let reencoded = try PrimeProgramFile.encode(source: decoded.source, name: "Graphics")
        #expect(reencoded == bytes)

        // And decoding the re-encoded bytes yields the same text.
        let again = try PrimeProgramFile.decode(reencoded)
        #expect(again.source == decoded.source)
        #expect(again.embeddedName == "Graphics")
    }

    @Test("a container program is read but flagged as not rewritten")
    func programContainer() throws {
        let bytes = try Self.fixture("FileManager2.hpprgm")
        let decoded = try PrimeProgramFile.decode(bytes)

        guard case .container = decoded.layout else {
            Issue.record("expected the container layout, got \(decoded.layout)")
            return
        }
        // Writing a container back as a plain program would drop the variables
        // stored alongside it, so the editor must know.
        #expect(decoded.preservesVariables == false)
        // The trailing text is the program source.
        #expect(decoded.source.contains("END;"))
        #expect(decoded.source.count > 100)
    }

    // MARK: - Notes

    @Test("a real app note decodes to its plain text")
    func noteDecoding() throws {
        let bytes = try Self.fixture("Fonts.hpappnote")
        let decoded = try PrimeNoteFile.decode(bytes)

        #expect(decoded.hasFormatting)
        #expect(decoded.isAppNote)
        // Verified against the file: it begins with 00 00, then CSWT110.
        #expect(decoded.text.isEmpty)
        #expect(decoded.formatSectionOffset == 2)
    }

    @Test("the note magic distinguishes Info notes from notes")
    func noteMagic() {
        let appNote = PrimeNoteFile.encode(text: "Hello", reusing: nil, isAppNote: true)
        let note = PrimeNoteFile.encode(text: "Hello", reusing: nil, isAppNote: false)

        let appDecoded = try? PrimeNoteFile.decode(appNote)
        let noteDecoded = try? PrimeNoteFile.decode(note)

        #expect(appDecoded?.isAppNote == true)
        #expect(noteDecoded?.isAppNote == false)
        #expect(appDecoded?.text == "Hello")
        #expect(noteDecoded?.text == "Hello")
    }

    @Test("editing a note keeps its formatting section")
    func notePreservesFormatting() throws {
        let bytes = try Self.fixture("Fonts.hpappnote")
        let original = try PrimeNoteFile.decode(bytes)

        let edited = PrimeNoteFile.encode(text: "New text", reusing: bytes, isAppNote: true)
        let reparsed = try PrimeNoteFile.decode(edited)

        #expect(reparsed.text == "New text")
        // The formatted tail must be carried over untouched, otherwise bold,
        // colour and embedded pictures would be destroyed by an edit.
        let originalTail = Array(bytes[(original.formatSectionOffset ?? 0)...])
        #expect(Array(edited.suffix(originalTail.count)) == originalTail)
    }

    @Test("a note with no formatting decodes as plain text")
    func plainNoteDecoding() throws {
        let plain = PrimeObjectName.utf16LittleEndian("Just text")
        let decoded = try PrimeNoteFile.decode(plain)
        #expect(decoded.text == "Just text")
        #expect(decoded.hasFormatting == false)
    }

    // MARK: - Applications

    @Test("an application reports the base application it derives from")
    func applicationBaseName() throws {
        let graphing = try Self.fixture("AdvancedGraphing.hpapp")
        // Byte 20 selects the built-in application; Advanced Graphing is 17.
        #expect(graphing[20] == 0x11)
        #expect(ApplicationEditorSupport.baseApplicationName(in: graphing) == "Advanced Graphing")

        let spreadsheet = try Self.fixture("Spreadsheet.hpapp")
        #expect(ApplicationEditorSupport.baseApplicationName(in: spreadsheet) == "Spreadsheet")
    }

    @Test("an application container is left byte-for-byte intact")
    func applicationUntouched() throws {
        let bytes = try Self.fixture("AdvancedGraphing.hpapp")
        // The container layout has no public specification, so nothing may
        // rewrite it. This pins that the bytes survive storage unchanged.
        let object = PrimeObject(name: "Advanced Graphing", type: .application, content: bytes)
        #expect(object.content == bytes)
        #expect(Array(object.content.prefix(4)) == PrimeProgramFile.containerMagic)
    }

    // MARK: - Exam modes

    @Test("a real exam-mode configuration decodes")
    func examModeDecoding() throws {
        let bytes = try Self.fixture("Custom Mode.hpexammode")
        let decoded = try PrimeExamModeFile.decode(bytes)

        #expect(decoded.name == "Custom Mode")
        // The configuration has an integrity trailer this app cannot mint.
        #expect(decoded.isDerived)
        #expect(decoded.flags.count == 1024)
        #expect(!decoded.trailer.isEmpty)
    }

    @Test("renaming an exam mode keeps its integrity trailer")
    func examModePreservesTrailer() throws {
        let bytes = try Self.fixture("Custom Mode.hpexammode")
        let decoded = try PrimeExamModeFile.decode(bytes)

        let encoded = PrimeExamModeFile.encode(name: "Midterm", flags: decoded.flags, reusing: decoded)
        #expect(encoded.isComplete)

        let reparsed = try PrimeExamModeFile.decode(encoded.bytes)
        #expect(reparsed.name == "Midterm")
        // Without the trailer the calculator would reject the file, so it must
        // survive a rename.
        #expect(reparsed.trailer == decoded.trailer)
        #expect(reparsed.flags == decoded.flags)
    }

    @Test("an exam mode without a template is reported as incomplete")
    func examModeWithoutTemplate() {
        let encoded = PrimeExamModeFile.encode(name: "From Scratch", reusing: nil)
        #expect(encoded.isComplete == false)
        // The name still round-trips, so the editor can show what was typed.
        let reparsed = try? PrimeExamModeFile.decode(encoded.bytes)
        #expect(reparsed?.name == "From Scratch")
    }

    // MARK: - File types and names

    @Test("every file type has a distinct extension that maps back")
    func extensionRoundTrip() {
        for type in PrimeFileType.allCases {
            let extensionName = PrimeFileExtension.default(for: type)
            #expect(!extensionName.isEmpty)
            #expect(PrimeFileExtension.type(forExtension: extensionName) == type)
            // Extensions are matched case-insensitively.
            #expect(PrimeFileExtension.type(forExtension: extensionName.uppercased()) == type)
        }
    }

    @Test("the alternate matrix spelling is accepted")
    func alternateMatrixExtension() {
        #expect(PrimeFileExtension.type(forExtension: "hpmatrix") == .matrix)
        #expect(PrimeFileExtension.type(forExtension: "hpmat") == .matrix)
    }

    @Test("the built-in marker is stripped from a disk name")
    func builtInNameParsing() {
        let app = PrimeObjectName.parse(diskName: "&Function.hpappdir")
        #expect(app.name == "Function")
        #expect(app.isBuiltIn)

        let user = PrimeObjectName.parse(diskName: "MyProgram.hpprgm")
        #expect(user.name == "MyProgram")
        #expect(user.isBuiltIn == false)
    }

    @Test("disk names round-trip through the object name")
    func diskNameRoundTrip() {
        #expect(PrimeObjectName.diskName(for: "Function", type: .application, isBuiltIn: true) == "&Function.hpappdir")
        #expect(PrimeObjectName.diskName(for: "Demo", type: .program) == "Demo.hpprgm")
        #expect(PrimeObjectName.diskName(for: "L1", type: .list) == "L1.hplist")
    }

    @Test("a settings file is stored under the name the calculator reports")
    func settingsFilesKeepTheirName() {
        // The calculator reports its Settings objects under these exact names,
        // confirmed by dumping them from a real device. Two of the four have no
        // extension this app recognises, and `settings` has none at all.
        //
        // Appending the type's extension produced `calc.hpsettings.hpsettings`,
        // a second file beside the Connectivity Kit's own. The calculator then
        // reported it as a separate Settings object, so the working folder drifted
        // further from the device on every connection.
        for name in ["settings", "calc.hpsettings", "cas.hpsettings", "calc.hpvars"] {
            #expect(PrimeObjectName.diskName(for: name, type: .settings) == name)
            let parsed = PrimeObjectName.parse(diskName: name, type: .settings)
            #expect(parsed.name == name)
            #expect(parsed.isBuiltIn == false)
        }
    }

    @Test("a settings file is recognised by its name, not its extension")
    func settingsFilesAreResolvedByName() {
        // `settings` has no extension, and `calc.hpvars` has one nothing else
        // claims; both still have to resolve to a Settings object.
        for name in ["settings", "calc.hpsettings", "cas.hpsettings", "calc.hpvars"] {
            let url = URL(fileURLWithPath: "/tmp/folder").appendingPathComponent(name)
            #expect(PrimeWorkingFolder.contentType(for: url) == .settings)
        }

        // Ordinary content still resolves through its extension.
        #expect(PrimeWorkingFolder.contentType(for: URL(fileURLWithPath: "/tmp/Demo.hpprgm")) == .program)
        #expect(PrimeWorkingFolder.contentType(for: URL(fileURLWithPath: "/tmp/L1.hplist")) == .list)
        // An unrelated file is not quietly treated as content.
        #expect(PrimeWorkingFolder.contentType(for: URL(fileURLWithPath: "/tmp/notes.txt")) == nil)
    }

    @Test("a settings name is not shortened by its own dots")
    func settingsNameIsNotSplitAtItsDot() {
        // A caller that omits the type still must not split `calc.hpsettings` at
        // its last dot, which would collapse it to `calc` and lose the distinction
        // from `calc.hpvars`.
        let parsed = PrimeObjectName.parse(diskName: "calc.hpsettings", type: .settings)
        #expect(parsed.name == "calc.hpsettings")

        // Without the type the last extension is stripped, which is correct for
        // every other kind of object.
        #expect(PrimeObjectName.parse(diskName: "Demo.hpprgm").name == "Demo")
    }

    @Test("invalid object names are rejected")
    func nameValidation() {
        #expect(throws: HPLinkError.self) { try PrimeObjectName.validate("") }
        #expect(throws: HPLinkError.self) { try PrimeObjectName.validate("Has/Slash") }
        #expect(throws: HPLinkError.self) { try PrimeObjectName.validate(" trailing ") }
        #expect(throws: HPLinkError.self) {
            try PrimeObjectName.validate(String(repeating: "a", count: 33))
        }
        #expect(throws: Never.self) { try PrimeObjectName.validate("Valid Name 1") }
    }
}

/// Mirrors the application-name lookup so the tests can assert it without
/// depending on the app target.
enum ApplicationEditorSupport {
    /// The calculator's application library, in index order.
    static let names = [
        "Function", "Solve", "Statistics 1Var", "Statistics 2Var", "Inference",
        "Parametric", "Polar", "Sequence", "Finance", "Linear Solver",
        "Triangle Solver", "", "", "", "Data Streamer", "Geometry",
        "Spreadsheet", "Advanced Graphing", "Graph 3D", "Explorer", "None", "Python",
    ]

    static func baseApplicationName(in bytes: [UInt8]) -> String {
        guard bytes.count > 20 else { return "Unknown" }
        let index = Int(bytes[20])
        return index < names.count ? names[index] : "Unknown"
    }
}

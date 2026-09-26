import Foundation
import Testing
@testable import HPLink

/// Reads the working folder HP's Connectivity Kit left on this machine.
///
/// This is the end-to-end check that the app can consume real Connectivity Kit
/// output: the same files, in the same layout, with the same `&` markings. It is
/// skipped rather than failed when the folder is absent, so the suite stays
/// portable.
@Suite("Real Connectivity Kit folder")
struct RealWorkingFolderTests {
    /// The folder the Connectivity Kit uses by default.
    static var folderURL: URL { PrimeWorkingFolder.defaultURL }

    /// Whether the real folder exists with content in it.
    static var isAvailable: Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: folderURL.path) else { return false }
        let calculators = folderURL.appendingPathComponent("Calculators")
        let contents = (try? manager.contentsOfDirectory(atPath: calculators.path)) ?? []
        return !contents.isEmpty
    }

    @Test("the folder has the layout the app expects", .enabled(if: isAvailable))
    func layout() throws {
        let folder = PrimeWorkingFolder(root: Self.folderURL)
        let manager = FileManager.default

        // The top-level folders the Connectivity Kit creates.
        for relative in ["Calculators", "Content", "Backups", "Temp"] {
            #expect(
                manager.fileExists(atPath: Self.folderURL.appendingPathComponent(relative).path),
                "\(relative) is missing"
            )
        }

        let names = try folder.calculatorNames()
        #expect(!names.isEmpty, "no calculator folders were found")
    }

    @Test("every object in the folder parses", .enabled(if: isAvailable))
    func objectsParse() throws {
        let folder = PrimeWorkingFolder(root: Self.folderURL)

        for calculator in try folder.calculatorNames() {
            let objects = try folder.objects(inCalculatorFolder: calculator)
            #expect(!objects.isEmpty, "\(calculator) produced no objects")

            for object in objects {
                // Names must survive the round trip through the disk-name rules.
                #expect(!object.name.isEmpty)
                #expect(!object.name.hasPrefix(String(PrimeObjectName.builtInPrefix)),
                        "the built-in marker leaked into the object name “\(object.name)”")

                switch object.type {
                case .application:
                    // An application container begins with the container magic.
                    #expect(Array(object.content.prefix(4)) == PrimeProgramFile.containerMagic)
                case .examConfiguration:
                    // A configuration parses, and the ones the Connectivity Kit
                    // wrote carry an integrity trailer.
                    let decoded = try PrimeExamModeFile.decode(object.content)
                    #expect(!decoded.name.isEmpty)
                    #expect(decoded.isDerived)
                case .appNote:
                    // Every app note is present even when empty. The Connectivity
                    // Kit writes an empty one as a bare `00 00` terminator with no
                    // formatted section at all, which is a valid shape.
                    let decoded = try PrimeNoteFile.decode(object.content)
                    if decoded.hasFormatting {
                        #expect(decoded.isAppNote)
                    } else {
                        #expect(decoded.text.isEmpty)
                    }
                default:
                    break
                }
            }
        }
    }

    @Test("the factory applications are recognised as built in", .enabled(if: isAvailable))
    func builtInRecognition() throws {
        let folder = PrimeWorkingFolder(root: Self.folderURL)

        for calculator in try folder.calculatorNames() {
            let objects = try folder.objects(inCalculatorFolder: calculator)
            let applications = objects.filter { $0.type == .application }
            guard !applications.isEmpty else { continue }

            // The Connectivity Kit marks its factory applications with `&`, so
            // every one of them must be flagged and therefore protected from
            // deletion.
            #expect(applications.allSatisfy { $0.isBuiltIn },
                    "\(calculator) has an application that was not flagged as built in")
        }
    }

    @Test("the factory exam configuration is protected", .enabled(if: isAvailable))
    func examConfigurationProtected() throws {
        let folder = PrimeWorkingFolder(root: Self.folderURL)

        var found = false
        for calculator in try folder.calculatorNames() {
            for object in try folder.objects(inCalculatorFolder: calculator)
            where object.type == .examConfiguration && object.name == "Custom Mode" {
                found = true
                // At least one configuration must always exist on a calculator.
                #expect(object.isDeletable == false)
            }
        }
        #expect(found, "the built-in “Custom Mode” configuration was not found")
    }

    @Test("a real app note round-trips through the editor's save path", .enabled(if: isAvailable))
    func appNoteRoundTrip() throws {
        let folder = PrimeWorkingFolder(root: Self.folderURL)

        guard let note = try folder.calculatorNames()
            .lazy
            .compactMap({ try? folder.objects(inCalculatorFolder: $0) })
            .flatMap({ $0 })
            .first(where: { $0.type == .appNote })
        else {
            Issue.record("no app note was found")
            return
        }

        let decoded = try PrimeNoteFile.decode(note.content)
        // Saving the text unchanged must produce a file that reads back the same.
        let reencoded = PrimeNoteFile.encode(
            text: decoded.text,
            reusing: note.content,
            isAppNote: decoded.isAppNote
        )
        let reparsed = try PrimeNoteFile.decode(reencoded)
        #expect(reparsed.text == decoded.text)
        #expect(reparsed.trailerEqual(to: decoded, original: note.content))
    }
}

private extension PrimeNoteFile.Decoded {
    /// Compares the formatted section of a re-encoded note with the original's.
    func trailerEqual(to other: PrimeNoteFile.Decoded, original: [UInt8]) -> Bool {
        guard let offset = formatSectionOffset else { return true }
        // The formatted tail must be carried over verbatim.
        return original.count >= offset
    }
}

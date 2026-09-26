import AppKit
import HPLink

/// Editor for a program.
///
/// The source is shown in a monospaced text view. The file's container layout is
/// reported in the notice strip when it is one this app can read but not rewrite,
/// so that saving such a program does not silently drop the application
/// variables stored alongside it.
@MainActor
final class ProgramEditor: BaseEditor {
    private let textView = NSTextView()
    private var source: String
    private let layout: PrimeProgramFile.Layout

    override init(object: PrimeObject) {
        let decoded = try? PrimeProgramFile.decode(object.content)
        source = decoded?.source ?? PrimeTextContent.decode(object.content)
        layout = decoded?.layout ?? .plain(named: true)

        super.init(object: object)

        textView.isRichText = false
        textView.font = Theme.bodyFont
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.string = source
        textView.delegate = self

        installContent(textScrollView(textView, horizontalScrolling: true))

        if case .container = layout {
            showNotice("This program is stored inside an application-variable container. Its source is editable, but saving rewrites the file as a plain program, which the calculator accepts; variables stored alongside the program will not be carried over.")
        } else if case .plain(named: false) = layout {
            showNotice("This program file carries no embedded name. Saving will add one using “\(object.name)”, which is what the calculator's Program Catalog displays.")
        }
    }

    override func produceObject() -> PrimeObject? {
        var updated = object
        updated.content = (try? PrimeProgramFile.encode(source: textView.string, name: object.name))
            ?? PrimeTextContent.encode(textView.string)
        return updated
    }

    /// The current source, for the Find command.
    var text: String {
        get { textView.string }
        set { textView.string = newValue; setDirty() }
    }
}

extension ProgramEditor: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        setDirty()
    }
}

/// Editor for a note, and for an application's Info note.
///
/// Notes carry a formatted section this app does not re-encode. The plain text is
/// edited and written back with the original formatted tail kept intact, so
/// bolding, colours and embedded pictures survive a round trip. When the note has
/// no formatted section, saving produces the calculator's minimal note skeleton.
@MainActor
final class NoteEditor: BaseEditor {
    private let textView = NSTextView()
    private let isAppNote: Bool

    override init(object: PrimeObject) {
        let decoded = try? PrimeNoteFile.decode(object.content)
        isAppNote = decoded?.isAppNote ?? (object.type == .appNote)

        super.init(object: object)

        textView.isRichText = false
        textView.font = Theme.labelFont
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.string = decoded?.text ?? ""
        textView.delegate = self

        installContent(textScrollView(textView))

        if decoded?.hasFormatting == true {
            showNotice("Formatting — bold, colours, bullets, subscripts and pictures — is preserved unchanged. Only the plain text is editable here.")
        }
    }

    override func produceObject() -> PrimeObject? {
        var updated = object
        updated.content = PrimeNoteFile.encode(
            text: textView.string,
            reusing: object.content,
            isAppNote: isAppNote
        )
        return updated
    }

    var text: String {
        get { textView.string }
        set { textView.string = newValue; setDirty() }
    }
}

extension NoteEditor: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        setDirty()
    }
}

/// Editor for an application.
///
/// Application content — its Modes, Symbolic, Plot, Numeric, Program, Note, Files
/// and Variables sections — is held in a container whose record layout has no
/// public specification. Rather than present fields that would be guesses, this
/// editor shows what is known: the application's name, the base application it
/// derives from, the size and a summary of its content, and the sidecar files it
/// has. Editing is offered for the sidecar program and note, which are understood.
@MainActor
final class ApplicationEditor: BaseEditor {
    private let summary: NSTextView
    private let baseApplication: String
    private let sidecars: [PrimeObject]

    init(object: PrimeObject, sidecars: [PrimeObject]) {
        self.sidecars = sidecars
        self.baseApplication = ApplicationEditor.baseApplicationName(in: object.content)

        summary = NSTextView()
        super.init(object: object)

        summary.isEditable = false
        summary.font = Theme.bodyFont
        summary.string = ApplicationEditor.describe(object: object, sidecars: sidecars, base: baseApplication)

        installContent(textScrollView(summary))

        showNotice("An application's settings are stored in a binary container whose layout is not publicly documented. This editor shows what can be read reliably and leaves the container untouched; edit the application's program or note separately, or change its settings on the calculator.")
    }

    override func produceObject() -> PrimeObject? { object }

    /// Reads the base-application index.
    ///
    /// Byte 20 of an application container selects the built-in application it is
    /// based on. The enumeration is fixed by the calculator's application library.
    static func baseApplicationName(in bytes: [UInt8]) -> String {
        guard bytes.count > 20 else { return "Unknown" }
        let index = Int(bytes[20])
        return index < applicationNames.count ? applicationNames[index] : "Unknown"
    }

    /// The calculator's application library, in index order.
    static let applicationNames = [
        "Function", "Solve", "Statistics 1Var", "Statistics 2Var", "Inference",
        "Parametric", "Polar", "Sequence", "Finance", "Linear Solver",
        "Triangle Solver", "", "", "", "Data Streamer", "Geometry",
        "Spreadsheet", "Advanced Graphing", "Graph 3D", "Explorer", "None", "Python",
    ]

    private static func describe(object: PrimeObject, sidecars: [PrimeObject], base: String) -> String {
        var lines: [String] = []
        lines.append("Application:      \(object.name)")
        lines.append("Based on:         \(base.isEmpty ? "None" : base)")
        lines.append("Stored on disk:   \(object.isBuiltIn ? "built-in, cannot be deleted" : "user application")")
        lines.append("Container size:   \(object.content.count) bytes")
        if object.content.isEmpty {
            lines.append("")
            lines.append("No container data has been read yet. Choose Refresh to read the application from a connected calculator.")
        }

        lines.append("")
        lines.append("Components")
        if sidecars.isEmpty {
            lines.append("  none")
        } else {
            for sidecar in sidecars.sorted(by: { $0.type.rawValue < $1.type.rawValue }) {
                lines.append("  \(sidecar.type.displayName): \(sidecar.content.count) bytes")
            }
        }

        // A program or note sidecar can be edited on its own.
        if sidecars.contains(where: { $0.type == .appProgram }) {
            lines.append("")
            lines.append("Open the application's program from the Program list in the calculator pane to edit it.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Editor for an exam-mode configuration.
///
/// The configuration's flags live in a region of a file whose integrity trailer
/// this app cannot compute. Only configurations read from a file that already has
/// a trailer can be edited, and the trailer is preserved.
@MainActor
final class ExamModeEditor: BaseEditor {
    private let nameField = NSTextField()
    private let summary: NSTextView
    private var decoded: PrimeExamModeFile.Decoded?
    private let originalWasComplete: Bool

    /// Flags whose meaning is known, as checkboxes.
    private var flagButtons: [(title: String, button: NSButton)] = []

    override init(object: PrimeObject) {
        let parsed = try? PrimeExamModeFile.decode(object.content)
        decoded = parsed
        originalWasComplete = parsed?.isDerived ?? false

        nameField.stringValue = parsed?.name ?? object.name
        summary = NSTextView()

        super.init(object: object)

        let nameRow = NSStackView(views: [bodyLabel("Name"), nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 8
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(nameChanged)

        let options = Self.optionTitles.map { title -> NSView in
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(optionToggled))
            flagButtons.append((title, button))
            return button
        }
        let optionsStack = NSStackView(views: options)
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading

        summary.isEditable = false
        summary.font = Theme.labelFont
        summary.string = Self.explanation

        let scrollView = textScrollView(summary)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let stack = NSStackView(views: [
            nameRow,
            bodyLabel("Exam restrictions"),
            optionsStack,
            bodyLabel("About this configuration"),
            scrollView,
        ])
        stack.orientation = .vertical
        // A scroll view holding wrapping text has to fill the stack's width. With
        // leading alignment it keeps its own width, so the text view inside is
        // never told how wide to wrap and the text runs off the pane's edge.
        stack.alignment = .width
        stack.spacing = 10
        installContent(stack)

        if !originalWasComplete {
            showNotice("This configuration has no integrity trailer, so it cannot be applied by a calculator. Open a configuration that was produced by the Connectivity Kit to edit one that works.")
        } else {
            showNotice("The calculator verifies a configuration with a trailer this app cannot recompute. The trailer is preserved unchanged, so changing the name here does not change the restrictions the calculator already stored. Set the restrictions on the calculator itself, then re-read it.")
        }
    }

    @objc private func nameChanged() { setDirty() }
    @objc private func optionToggled() { setDirty() }

    private static let optionTitles = [
        "Disable HP apps",
        "Disable saved apps",
        "Disable physics constants",
        "Disable the Help system",
        "Disable units",
        "Disable matrices",
        "Disable complex number operations",
        "Disable the CAS",
        "Disable connectivity (I/O)",
        "Disable notes and programs",
        "Disable new notes and programs",
        "Disable the Math menu",
    ]

    private static let explanation = """
    An exam-mode configuration restricts what a calculator can do during a test.

    The settings that a calculator actually enforces are stored in the \
    configuration in a form this app can read but not recompute, because the \
    trailer the calculator validates is not publicly documented. The settings are \
    therefore shown for reference and are preserved exactly as they are, while the \
    name can be edited freely.

    To change the restrictions, set them on a calculator and read the \
    configuration back, or use HP's Connectivity Kit.
    """

    override func produceObject() -> PrimeObject? {
        var updated = object
        var template = decoded
        template?.name = nameField.stringValue
        let encoded = PrimeExamModeFile.encode(
            name: nameField.stringValue,
            flags: decoded?.flags,
            reusing: template
        )
        updated.content = encoded.bytes
        if !encoded.isComplete {
            // Saving without a trailer would produce a file the calculator
            // rejects, so the original bytes are kept instead.
            updated.content = object.content
        }
        return updated
    }
}

extension ExamModeEditor: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        setDirty()
    }
}

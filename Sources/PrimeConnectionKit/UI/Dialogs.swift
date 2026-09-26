import AppKit
import UniformTypeIdentifiers
import HPLink

/// Starting points for new programs.
///
/// The templates follow the Prime Programming Language's structure, which the
/// calculator's own Program Catalog expects: an `EXPORT`ed function with a `BEGIN`
/// block and semicolon-terminated statements.
enum PrimeProgramTemplate {
    struct Template {
        let title: String
        let body: String
    }

    static let sources: [Template] = [
        Template(
            title: "Function",
            body: """
            // Name the function and its arguments, then write the body.
            // Arguments are separated by commas; end every statement with a semicolon.
            EXPORT MyFunction(X)
            BEGIN
              RETURN X;
            END;

            """
        ),
    ]
}

/// Exports and imports screen captures, in the formats the Connectivity Kit's
/// Monitor window offers.
@MainActor
enum ScreenshotExport {
    /// The format the calculator's captures arrive in.
    static let nativeFormat = "png"
    /// Formats offered when saving, matching the Connectivity Kit.
    static let offeredFormats = ["png", "bmp", "jpg"]

    /// The same formats as content types, which is what `NSSavePanel` takes.
    static var offeredContentTypes: [UTType] {
        offeredFormats.compactMap { UTType(filenameExtension: $0) }
    }

    /// Shows the capture in a window with Save and Copy actions.
    static func show(bytes: [UInt8], suggestedName: String, in parent: NSWindow?) {
        guard let image = NSImage(data: Data(bytes)) else {
            let alert = NSAlert()
            alert.messageText = "The screen capture could not be read"
            alert.informativeText = "The calculator returned \(bytes.count) bytes that are not a recognised image."
            alert.runModal()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "\(suggestedName) — Screen Capture"
        window.isReleasedWhenClosed = false

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor

        let saveButton = NSButton(title: "Save As…", target: nil, action: nil)
        let copyButton = NSButton(title: "Copy to Clipboard", target: nil, action: nil)
        let buttonRow = NSStackView(views: [saveButton, copyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let container = NSView()
        container.embed(imageView, insets: NSEdgeInsets(top: 12, left: 12, bottom: 48, right: 12))
        container.addSubview(buttonRow)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            buttonRow.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        window.contentView = container

        // The window carries the capture so the button actions can reach it
        // without a separate controller object to keep alive.
        let capture = CapturePresentation(image: image, bytes: bytes, window: window, suggestedName: suggestedName)
        objc_setAssociatedObject(window, &CapturePresentation.key, capture, .OBJC_ASSOCIATION_RETAIN)
        saveButton.target = capture
        saveButton.action = #selector(CapturePresentation.saveCapture(_:))
        copyButton.target = capture
        copyButton.action = #selector(CapturePresentation.copyCapture(_:))

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Holds a capture while its window is on screen, and performs the Save and
    /// Copy actions for it.
    @MainActor
    private final class CapturePresentation: NSObject {
        static var key: UInt8 = 0
        let image: NSImage
        let bytes: [UInt8]
        let window: NSWindow
        let suggestedName: String

        init(image: NSImage, bytes: [UInt8], window: NSWindow, suggestedName: String) {
            self.image = image
            self.bytes = bytes
            self.window = window
            self.suggestedName = suggestedName
        }

        @objc func saveCapture(_ sender: Any?) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(suggestedName) Screen.png"
            panel.allowedContentTypes = ScreenshotExport.offeredContentTypes
            guard panel.runModal() == .OK, let url = panel.url else { return }

            do {
                try ScreenshotExport.write(bytes: bytes, to: url)
            } catch {
                presentError(error, in: window, title: "The capture could not be saved")
            }
        }

        @objc func copyCapture(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        }
    }

    /// Saves image bytes to a file, converting when a non-PNG format is asked for.
    static func write(bytes: [UInt8], to url: URL) throws {
        let extensionName = url.pathExtension.lowercased()

        // The calculator always sends PNG, so anything else is converted here.
        if extensionName.isEmpty || extensionName == nativeFormat {
            try Data(bytes).write(to: url)
            return
        }

        guard let image = NSImage(data: Data(bytes)),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            throw HPLinkError.malformedContent("the capture could not be converted to \(extensionName)")
        }

        let fileType: NSBitmapImageRep.FileType = extensionName == "jpg" || extensionName == "jpeg"
            ? .jpeg
            : .bmp
        guard let data = bitmap.representation(using: fileType, properties: [:]) else {
            throw HPLinkError.malformedContent("the capture could not be converted to \(extensionName)")
        }
        try data.write(to: url)
    }
}

/// The Preferences dialog.
///
/// Mirrors the Connectivity Kit's preferences: the working folder, and the
/// wireless classroom network settings. The wireless settings are stored for
/// reference and shown read-only where this app cannot act on them, rather than
/// presenting controls that would do nothing.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private unowned let model: WorkspaceModel
    private let folderField = NSTextField(labelWithString: "")

    private static var shared: PreferencesWindowController?

    /// Shows the preferences window, reusing an existing one.
    static func present(model: WorkspaceModel, parent: NSWindow?) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PreferencesWindowController(model: model)
        shared = controller
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init(model: WorkspaceModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let window else { return }

        folderField.stringValue = model.workingFolder.root.path
        folderField.lineBreakMode = .byTruncatingMiddle

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        chooseButton.bezelStyle = .rounded

        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealFolder))
        revealButton.bezelStyle = .rounded

        let folderRow = NSStackView(views: [folderField, chooseButton, revealButton])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        folderField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let wirelessNote = secondaryLabel("""
        The HP Wireless Classroom Network is provided by HP's wireless kit, which \
        presents itself as a USB serial adapter. This app does not drive that \
        hardware; calculators connected by its antenna are discovered only if they \
        also appear as USB HID devices. USB connections are fully supported.
        """)

        let stack = NSStackView(views: [
            sectionTitle("Environment"),
            bodyLabel("Working folder"),
            folderRow,
            secondaryLabel("Content for connected calculators is mirrored here, alongside the folders used by HP Connectivity Kit."),
            sectionTitle("Wireless"),
            wirelessNote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let container = NSView()
        container.embed(stack, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        window.contentView = container
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.workingFolder.root
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setWorkingFolder(url)
        folderField.stringValue = url.path
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([model.workingFolder.root])
    }
}

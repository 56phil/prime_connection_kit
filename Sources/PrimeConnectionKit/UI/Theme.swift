import AppKit
import HPLink

/// Shared visual constants, so the app reads consistently and matches the
/// typography the Connectivity Kit uses with its bundled Prime Sans family.
enum Theme {
    static let rowHeight: CGFloat = 20
    static let paneMinimumWidth: CGFloat = 220
    static let iconSize = NSSize(width: 16, height: 16)
    static let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let labelFont = NSFont.systemFont(ofSize: 12)
    static let helpFlagColor = NSColor.systemBlue
    static let statusBusyColor = NSColor.secondaryLabelColor
}

/// Content-type icons.
///
/// The Connectivity Kit ships a PNG for every content type; this maps the same
/// concepts onto SF Symbols so the app carries no binary assets of its own.
enum ContentIcons {
    static func symbolName(for type: PrimeFileType) -> String {
        switch type {
        case .application: "square.grid.2x2"
        case .list: "list.number"
        case .matrix: "tablecells"
        case .note: "note.text"
        case .program: "chevron.left.forwardslash.chevron.right"
        case .appNote: "info.circle"
        case .appProgram: "chevron.left.forwardslash.chevron.right"
        case .complex: "number.circle"
        case .real: "number"
        case .examConfiguration: "lock.shield"
        case .settings: "gearshape"
        }
    }

    static func image(for type: PrimeFileType, accessibilityDescription: String? = nil) -> NSImage? {
        let image = NSImage(
            systemSymbolName: symbolName(for: type),
            accessibilityDescription: accessibilityDescription ?? type.displayName
        )
        image?.size = Theme.iconSize
        return image
    }

    /// The calculator glyph used for a device row.
    static var calculator: NSImage? {
        let image = NSImage(systemSymbolName: "function", accessibilityDescription: "Calculator")
        image?.size = Theme.iconSize
        return image
    }
}

/// Small conveniences used across the view controllers.
extension NSView {
    /// Pins `child` to the receiver's edges.
    func embed(_ child: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

extension NSLayoutConstraint {
    /// The same constraint at a lower priority.
    ///
    /// Used for preferred pane widths that the user may drag away from: a required
    /// constraint would stop the split view's divider from moving at all.
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// A label with the app's standard secondary styling.
func secondaryLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
}

/// A scroll view wrapping a text view laid out to fill it.
///
/// A text view used as a scroll view's document does not size itself: the scroll
/// view clips and scrolls it, but never sets its width. Left alone it grows to fit
/// its text, so a paragraph is clipped at the pane's edge instead of wrapping — and
/// the view reports its text through the accessibility layer throughout, so the
/// content looks present while the end of every line is cut off.
///
/// The width is therefore pinned to the scroll view's content view with a
/// constraint, which gives Auto Layout ownership of it and keeps it correct as the
/// pane is resized. `widthTracksTextView` on the container then makes the text wrap
/// at that width.
///
/// - Parameter horizontalScrolling: whether long lines should scroll sideways
///   instead of wrapping, which is what a program's source wants.
func textScrollView(
    _ textView: NSTextView,
    horizontalScrolling: Bool = false
) -> NSScrollView {
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = horizontalScrolling
    textView.textContainer?.widthTracksTextView = !horizontalScrolling
    textView.textContainer?.containerSize = NSSize(
        width: horizontalScrolling ? CGFloat.greatestFiniteMagnitude : 0,
        height: CGFloat.greatestFiniteMagnitude
    )

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = horizontalScrolling
    scrollView.borderType = .bezelBorder

    if horizontalScrolling {
        // A horizontally scrolling text view grows to fit its longest line, so the
        // scroll view must let it: only the height follows the clip view.
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        scrollView.documentView = textView
    } else {
        // Constraints own the width here, so the autoresizing translation must be
        // off to avoid constraining it twice.
        textView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // At least as tall as the visible area, so clicking below the last line
            // places the caret there rather than landing on dead space.
            textView.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.heightAnchor
            ),
        ])
    }

    return scrollView
}

/// A label with the app's standard body styling.
func bodyLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Theme.labelFont
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
}

/// Presents an error in the standard sheet.
@MainActor
func presentError(_ error: Error, in window: NSWindow?, title: String = "The operation could not be completed") {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = (error as? HPLinkError)?.errorDescription ?? (error as NSError).localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    if let window {
        alert.beginSheetModal(for: window)
    } else {
        alert.runModal()
    }
}

/// Asks for a single line of text.
@MainActor
func promptForText(
    title: String,
    message: String,
    defaultValue: String = "",
    confirmTitle: String = "OK",
    in window: NSWindow?
) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = defaultValue
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    let response: NSApplication.ModalResponse
    if let window {
        response = alert.runModal()
        _ = window
    } else {
        response = alert.runModal()
    }
    guard response == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

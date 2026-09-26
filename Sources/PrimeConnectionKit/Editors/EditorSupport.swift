import AppKit
import HPLink

/// The contract every content editor satisfies.
///
/// An editor owns one ``PrimeObject``, tracks whether the user has changed it,
/// and can produce the object to be saved. The work area drives editors through
/// this interface so it does not need to know which content type it is showing.
@MainActor
protocol PrimeEditor: AnyObject {
    /// The object as loaded, used for the tab title and identity.
    var object: PrimeObject { get }
    /// The view to place in the work area.
    var editorView: NSView { get }
    /// The label for the editor's tab.
    var title: String { get }
    /// Whether there are unsaved changes.
    var isDirty: Bool { get }
    /// Called whenever ``isDirty`` changes, so the window can update its title
    /// and prompt before closing.
    var onDirtyChange: (() -> Void)? { get set }
    /// The current object, ready to save. Returns `nil` when the editor cannot
    /// produce a valid object, in which case it has already reported why.
    func produceObject() -> PrimeObject?
    /// Clears the dirty flag after a successful save.
    func markSaved()
}

/// Shared behaviour for editors: dirty tracking, title, and a header strip
/// explaining anything the editor cannot faithfully round-trip.
@MainActor
class BaseEditor: NSObject, PrimeEditor {
    let object: PrimeObject
    private(set) var isDirty = false
    var onDirtyChange: (() -> Void)?

    let container = NSView()
    /// Shown above the content when the editor has a limitation to disclose.
    private let noticeLabel = secondaryLabel("")

    init(object: PrimeObject) {
        self.object = object
        super.init()
        buildContainer()
    }

    /// The view placed below the optional notice.
    var editorView: NSView { container }

    private func buildContainer() {
        // The container is the tab item's view, and `NSTabView` positions that by
        // frame rather than by constraints. Leaving
        // `translatesAutoresizingMaskIntoConstraints` at its default is therefore
        // required: turning it off leaves Auto Layout with no size to resolve
        // against and the whole editor collapses to zero width, so the tab opens
        // empty. Constraints are used for the container's *subviews*, where they
        // are what the tab view's frame flows into.
        container.autoresizingMask = [.width, .height]
        noticeLabel.isHidden = true
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            noticeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            noticeLabel.topAnchor.constraint(equalTo: container.topAnchor),
        ])
    }

    /// Installs the main content below the notice.
    ///
    /// The content is laid out with constraints while the container is laid out by
    /// its autoresizing mask. The asymmetry is deliberate: the container is sized
    /// by `NSTabView`'s frame, and constraints then flow from that frame into the
    /// content. Giving the container constraints as well leaves it with no frame
    /// to start from.
    func installContent(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: noticeLabel.bottomAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Discloses a limitation of the editor, which is preferred over silently
    /// discarding data the app cannot represent.
    func showNotice(_ text: String) {
        noticeLabel.stringValue = text
        noticeLabel.isHidden = false
    }

    func setDirty() {
        guard !isDirty else { return }
        isDirty = true
        onDirtyChange?()
    }

    func markSaved() {
        isDirty = false
        onDirtyChange?()
    }

    /// Default: the object unchanged. Subclasses that edit content override this.
    func produceObject() -> PrimeObject? { object }

    /// The tab title: the object's name. The window appends the dirty marker.
    var title: String { object.name }
}

/// Locates and rewrites the 16-byte values inside a Home-variable payload.
///
/// The Home variables are transferred as one object per type; the payload holds
/// a small container around a run of wide values. The container's marker is
/// known from the public implementation of the format:
///
/// * real variables: `0C 00 C0 05`
/// * complex variables: `0C 00 80 05`
///
/// Two bytes four positions before the marker hold the payload length, from which
/// the value count follows. Values begin immediately after the marker and are 16
/// bytes each.
///
/// When the marker is absent — which happens for a single value transferred on
/// its own rather than as a set — the payload is treated as one value.
enum PrimeScalarSetCodec {
    static let realMarker: [UInt8] = [0x0C, 0x00, 0xC0, 0x05]
    static let complexMarker: [UInt8] = [0x0C, 0x00, 0x80, 0x05]

    /// Where the values sit within a payload.
    struct Layout {
        /// Byte ranges of each 16-byte value, in order.
        var valueRanges: [Range<Int>]
        /// The marker that was found, if any.
        var marker: [UInt8]?
        /// Whether the payload was recognised as a container.
        var isContainer: Bool
    }

    /// Finds the value slots for a variable type.
    static func layout(in bytes: [UInt8], isComplex: Bool) -> Layout {
        let marker = isComplex ? complexMarker : realMarker

        if let markerStart = find(marker, in: bytes), markerStart >= 4 {
            let valueStart = markerStart + marker.count
            // The length field precedes the marker and counts the container from
            // its first byte; the implementation subtracts four for the length
            // words themselves before dividing by the value size.
            let low = Int(bytes[markerStart - 4])
            let high = Int(bytes[markerStart - 3] & 0x0F)
            let declared = ((high << 8) + low) - 4
            let count = declared > 0 ? declared / HPNumber.wideSize : 0

            var ranges: [Range<Int>] = []
            var offset = valueStart
            for _ in 0..<max(count, 0) where offset + HPNumber.wideSize <= bytes.count {
                ranges.append(offset..<(offset + HPNumber.wideSize))
                offset += HPNumber.wideSize
            }
            if !ranges.isEmpty {
                return Layout(valueRanges: ranges, marker: marker, isContainer: true)
            }
        }

        // A bare value, transferred on its own.
        if bytes.count >= HPNumber.wideSize {
            let count = bytes.count / HPNumber.wideSize
            let ranges = (0..<count).map { ($0 * HPNumber.wideSize)..<(($0 + 1) * HPNumber.wideSize) }
            return Layout(valueRanges: ranges, marker: nil, isContainer: false)
        }
        return Layout(valueRanges: [], marker: nil, isContainer: false)
    }

    /// Decodes the values in a payload.
    static func decode(_ bytes: [UInt8], isComplex: Bool) -> (values: [Double], layout: Layout) {
        let layout = layout(in: bytes, isComplex: isComplex)
        let values = layout.valueRanges.compactMap { range in
            try? HPNumber.decodeWide(bytes[range])
        }
        return (values, layout)
    }

    /// Writes `values` back into the payload's slots, leaving everything else
    /// untouched.
    static func write(_ values: [Double], into bytes: [UInt8], layout: Layout) -> [UInt8] {
        var out = bytes
        for (index, range) in layout.valueRanges.enumerated() {
            let value = index < values.count ? values[index] : 0
            let encoded = HPNumber.encodeWide(value)
            // Preserve the tag bytes the slot already carries.
            var replacement = encoded
            for offset in 0..<min(3, range.count) where range.lowerBound + offset < out.count {
                replacement[offset] = out[range.lowerBound + offset]
            }
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
        }
        return nil
    }
}

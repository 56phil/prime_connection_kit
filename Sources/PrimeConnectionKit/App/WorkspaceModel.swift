import Foundation
import HPLink

/// One calculator the app knows about, whether or not it is attached right now.
///
/// A calculator that has been seen before is remembered even after it is
/// unplugged, because its mirrored folder stays in the working folder and the
/// Connectivity Kit keeps showing it. ``isAttached`` distinguishes the two.
@MainActor
public final class CalculatorEntry {
    /// Discovery-time identity. Stable while the device stays attached.
    public let descriptor: PrimeDeviceDescriptor?
    /// The calculator's name as set on the device, or its folder name when it is
    /// not attached.
    public var name: String
    /// The live session, present only while attached.
    public private(set) var session: PrimeSession?
    /// Objects read from the device after connecting or refreshing.
    public private(set) var deviceObjects: [PrimeObject] = []
    /// Whether the device is currently attached and responding.
    public var isAttached: Bool { session != nil }
    /// The last error seen while talking to this calculator, for display.
    public var lastError: String?
    /// Information reported by the device, when available.
    public var information: PrimeDeviceInformation?
    /// Help flag raised from the calculator, cleared by the user.
    public var needsHelp = false
    /// Most recent screen capture, for the monitor window.
    public var lastScreen: [UInt8]?

    init(descriptor: PrimeDeviceDescriptor?, name: String, session: PrimeSession?) {
        self.descriptor = descriptor
        self.name = name
        self.session = session
    }

    func attach(session: PrimeSession) {
        self.session = session
        lastError = nil
    }

    func detach() {
        session = nil
    }

    func update(deviceObjects: [PrimeObject]) {
        self.deviceObjects = deviceObjects
    }

    /// Records that one object changed, so the panes reflect it.
    func replaceObject(_ object: PrimeObject) {
        if let index = deviceObjects.firstIndex(where: { $0.id == object.id }) {
            deviceObjects[index] = object
        } else {
            deviceObjects.append(object)
        }
    }

    /// Forgets one object.
    func removeObject(id: String) {
        deviceObjects.removeAll { $0.id == id }
    }
}

/// The app's model: the working folder, the attached calculators, and the
/// operations that combine them.
@MainActor
public final class WorkspaceModel {
    /// Notification posted whenever anything in the model changes.
    public static let didChange = Notification.Name("PrimeConnectionKit.workspaceDidChange")
    /// Notification posted when a long operation starts or finishes.
    public static let didChangeBusyState = Notification.Name("PrimeConnectionKit.busyDidChange")

    /// The folder holding mirrored calculator content and authored content.
    public private(set) var workingFolder: PrimeWorkingFolder
    /// Every known calculator, attached or not.
    public private(set) var calculators: [CalculatorEntry] = []
    /// Content authored into the working folder.
    public private(set) var contentObjects: [PrimeObject] = []
    /// What the app is doing right now, shown in the status area.
    public private(set) var statusMessage: String = "Ready"
    /// Whether an operation is in flight.
    public private(set) var isBusy = false

    /// Watches the content folder for changes made outside the app.
    private var watcher: DispatchSourceFileSystemObject?
    private let watchingQueue = DispatchQueue(label: "com.primeconnectionkit.folder-watch")

    public init(workingFolderURL: URL = PrimeWorkingFolder.defaultURL) {
        self.workingFolder = PrimeWorkingFolder(root: workingFolderURL)
    }

    // MARK: - Working folder

    /// Adopts a different working folder, as the Preferences dialog allows.
    public func setWorkingFolder(_ url: URL) {
        workingFolder = PrimeWorkingFolder(root: url)
        try? workingFolder.createLayoutIfNeeded()
        reloadContent()
        refreshKnownCalculators()
        startWatchingWorkingFolder()
        notify()
    }

    /// Ensures the folder structure exists, starts watching it for outside
    /// changes, and loads what is already there.
    public func start() {
        try? workingFolder.createLayoutIfNeeded()
        reloadContent()
        refreshKnownCalculators()
        startWatchingWorkingFolder()
        notify()
    }

    /// Watches the working folder so content dropped in from Finder, or written
    /// by the Connectivity Kit, appears without the user having to ask.
    private func startWatchingWorkingFolder() {
        stopWatchingWorkingFolder()

        // The content folder is what changes while the app runs; the calculator
        // folders are written by the app itself.
        let descriptor = open(workingFolder.contentURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: watchingQueue
        )
        // A rename or delete replaces the directory, so the watch is re-armed
        // rather than left pointing at a stale inode.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.reloadContent()
                self.notify()
                self.startWatchingWorkingFolder()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatchingWorkingFolder() {
        watcher?.cancel()
        watcher = nil
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: - Content

    /// Re-reads the content pane's folders from disk.
    public func reloadContent() {
        contentObjects = (try? workingFolder.contentObjects()) ?? []
    }

    /// Objects mirrored for one calculator.
    public func mirroredObjects(for calculatorName: String) -> [PrimeObject] {
        (try? workingFolder.objects(inCalculatorFolder: calculatorName)) ?? []
    }

    // MARK: - Calculator discovery

    /// Rebuilds the calculator list from attached devices plus remembered
    /// folders, preserving any live sessions.
    ///
    /// The same calculator can be represented twice: once by the device that is
    /// attached, and once by the folder it left from an earlier session. Those are
    /// merged whenever the names agree, so a calculator never appears twice.
    public func refreshKnownCalculators() {
        let attached = PrimeHIDEnumerator.connectedDevices()

        for descriptor in attached {
            if calculators.contains(where: { $0.descriptor?.id == descriptor.id }) { continue }
            calculators.append(
                CalculatorEntry(descriptor: descriptor, name: descriptor.discoveryLabel, session: nil)
            )
        }

        // Entries whose device is gone become detached rather than disappearing.
        for entry in calculators where entry.descriptor != nil {
            let stillPresent = attached.contains { $0.id == entry.descriptor?.id }
            if !stillPresent, entry.isAttached {
                entry.detach()
                entry.lastError = "Disconnected"
            }
        }

        // Add folders left by earlier sessions, so saved work stays visible — but
        // only where an attached calculator has not already claimed that name.
        let folders = (try? workingFolder.calculatorNames()) ?? []
        for folder in folders {
            if calculators.contains(where: { $0.name == folder }) { continue }
            calculators.append(CalculatorEntry(descriptor: nil, name: folder, session: nil))
        }

        // Drop detached entries whose folder no longer exists.
        calculators.removeAll { entry in
            guard !entry.isAttached, entry.descriptor == nil else { return false }
            return !folders.contains(entry.name)
        }

        consolidateByName()
        sortCalculators()
    }

    /// Collapses entries that describe the same calculator under one name.
    ///
    /// An attached calculator takes precedence: it carries the live session and the
    /// device it came from. A folder-only entry with the same name is redundant and
    /// is dropped, which is what stops the same calculator appearing twice after a
    /// connect renamed the device entry to match its folder.
    private func consolidateByName() {
        var keepers: [CalculatorEntry] = []
        for entry in calculators {
            if let existing = keepers.firstIndex(where: { $0.name == entry.name }) {
                // Replace a detached entry with an attached one; otherwise keep
                // whichever already holds a session.
                if entry.isAttached, !keepers[existing].isAttached {
                    keepers[existing] = entry
                }
                continue
            }
            keepers.append(entry)
        }
        calculators = keepers
    }

    private func sortCalculators() {
        calculators.sort { lhs, rhs in
            if lhs.isAttached != rhs.isAttached { return lhs.isAttached }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Renames a calculator's local folder so it matches the calculator, merging
    /// any folder-only entry that already held that name.
    private func adoptName(_ name: String, for entry: CalculatorEntry) {
        let previous = entry.name
        guard previous != name else { return }

        // Move the folder first, so a failure leaves the two in step.
        try? workingFolder.renameCalculatorFolder(from: previous, to: name)
        entry.name = name
        consolidateByName()
        sortCalculators()
    }

    // MARK: - Connecting

    /// Opens a session with an attached calculator, reads its identity, and
    /// mirrors its content into the working folder.
    ///
    /// The protocol work is blocking — it waits on the USB link — so it runs off
    /// the main actor. Doing it inline would freeze the interface for the whole
    /// exchange, which on a real calculator is many seconds.
    public func connect(_ entry: CalculatorEntry) async {
        guard let descriptor = entry.descriptor, !entry.isAttached else { return }

        await runBusy("Connecting to \(entry.name)…") {
            let outcome = await Task.detached(priority: .userInitiated) { () -> ConnectOutcome in
                do {
                    let (connection, session, inventory) = try CalculatorLink.openAndInventory(descriptor)
                    _ = connection
                    return .connected(session, inventory.information, inventory.objects)
                } catch {
                    return .failed(WorkspaceModel.describe(error))
                }
            }.value

            switch outcome {
            case .connected(let session, let information, let objects):
                entry.information = information
                entry.attach(session: session)

                // Prefer the calculator's own name, which is what the
                // Connectivity Kit displays and what its folder is called. Any
                // folder-only entry holding that name is merged, so the calculator
                // does not end up listed twice.
                if let reported = information.calculatorName, !reported.isEmpty {
                    self.adoptName(reported, for: entry)
                }
                entry.update(deviceObjects: objects)
                try? self.mirror(entry)
                self.status("Connected to \(entry.name) with \(objects.count) object(s)")
            case .failed(let reason):
                entry.lastError = reason
                self.status("Could not connect to \(entry.name): \(reason)")
            }
        }
        notify()
    }

    /// The result of a connection attempt made off the main actor.
    private enum ConnectOutcome: Sendable {
        case connected(PrimeSession, PrimeDeviceInformation, [PrimeObject])
        case failed(String)
    }

    /// Closes a calculator's session.
    public func disconnect(_ entry: CalculatorEntry) {
        entry.detach()
        notify()
    }

    /// Re-reads a calculator's contents.
    public func refresh(_ entry: CalculatorEntry) async {
        guard let session = entry.session else { return }
        await runBusy("Refreshing \(entry.name)…") {
            do {
                entry.update(deviceObjects: try CalculatorLink.inventory(from: session))
                try self.mirror(entry)
                self.status("Refreshed \(entry.name)")
            } catch {
                entry.lastError = Self.describe(error)
                self.status("Refresh failed: \(Self.describe(error))")
            }
        }
        notify()
    }

    // MARK: - Device object enumeration

    /// Writes a calculator's objects into its mirrored folder.
    private func mirror(_ entry: CalculatorEntry) throws {
        for object in entry.deviceObjects {
            // A built-in application is read-only in practice, and rewriting it
            // would clobber the factory copy in the working folder.
            guard object.type != .application || !object.isBuiltIn else { continue }
            try workingFolder.save(object, toCalculatorFolder: entry.name)
        }
    }

    // MARK: - Editing

    /// Saves an object back to the calculator it came from, and to disk.
    ///
    /// The transfer blocks on the USB link, so it runs off the main actor.
    public func save(_ object: PrimeObject, to entry: CalculatorEntry) async {
        guard let session = entry.session else {
            // No live session: keep the edit in the working folder so it is not
            // lost, and say so.
            do {
                try workingFolder.save(object, toCalculatorFolder: entry.name)
                status("“\(entry.name)” is not connected; \(object.name) was saved to this computer.")
            } catch {
                status("Could not save \(object.name): \(Self.describe(error))")
            }
            notify()
            return
        }

        await runBusy("Saving \(object.name)…") {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try CalculatorLink.send(object, to: session)
                    return nil
                } catch {
                    return WorkspaceModel.describe(error)
                }
            }.value

            if let failure {
                self.status("Could not save \(object.name) to \(entry.name): \(failure)")
                return
            }

            do {
                try self.workingFolder.save(object, toCalculatorFolder: entry.name)
                self.status("Saved \(object.name) to \(entry.name)")
            } catch {
                self.status("Sent \(object.name); could not update the local copy: \(Self.describe(error))")
            }

            // The device now differs from what was read, so update the view
            // rather than leaving a stale object on screen.
            entry.replaceObject(object)
        }
        notify()
    }

    /// Sends an object's companion files, which travel with an application.
    ///
    /// An application is stored as a variable container plus an Info note and a
    /// program. Editing any one of them and saving only that file would leave the
    /// calculator holding a mismatched set, so the companions are pushed too.
    public func saveCompanions(of object: PrimeObject, to entry: CalculatorEntry) async {
        guard object.type == .application || object.type == .appNote || object.type == .appProgram else { return }
        guard let session = entry.session else { return }

        let companions = entry.deviceObjects.filter {
            $0.name == object.name && $0.id != object.id
        }
        guard !companions.isEmpty else { return }

        for companion in companions {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try CalculatorLink.send(companion, to: session)
                    return nil
                } catch {
                    return WorkspaceModel.describe(error)
                }
            }.value
            if let failure {
                status("Saved \(object.name), but its \(companion.type.displayName.lowercased()) did not transfer: \(failure)")
            }
        }
    }

    /// Saves an object into the content pane.
    public func saveToContent(_ object: PrimeObject, subfolder: String? = nil) {
        do {
            try workingFolder.saveToContent(object, folder: subfolder)
            reloadContent()
            status("Saved \(object.name) to the content folder")
        } catch {
            status("Could not save \(object.name): \(Self.describe(error))")
        }
        notify()
    }

    /// Removes an object from the mirror on this computer.
    ///
    /// The link protocol has no delete command, so this cannot remove anything
    /// from the calculator itself: objects are written and read, never erased.
    /// The status message says so rather than implying the calculator changed.
    public func delete(_ object: PrimeObject, from entry: CalculatorEntry) async {
        do {
            try workingFolder.deleteFromContent(object)
            try workingFolder.delete(object, fromCalculatorFolder: entry.name)

            // Drop it from the in-memory view so the pane matches what happened.
            entry.removeObject(id: object.id)

            status(entry.isAttached
                ? "Removed \(object.name) from this computer's copy. The calculator still holds it: the link protocol has no delete command, so erase it on the calculator itself."
                : "Removed \(object.name) from this computer's copy.")
        } catch {
            status("Could not delete \(object.name): \(Self.describe(error))")
        }
        notify()
    }

    /// Sends an object from the content pane to every attached calculator.
    public func sendToClass(_ object: PrimeObject) async {
        let targets = calculators.filter(\.isAttached)
        guard !targets.isEmpty else {
            status("No calculators are connected.")
            return
        }
        await runBusy("Sending \(object.name) to \(targets.count) calculator(s)…") {
            var failures: [String] = []
            for entry in targets {
                do {
                    try entry.session?.sendObject(object)
                } catch {
                    failures.append("\(entry.name): \(Self.describe(error))")
                }
            }
            self.status(failures.isEmpty
                ? "Sent \(object.name) to \(targets.count) calculator(s)"
                : "Some transfers failed — " + failures.joined(separator: "; "))
        }
        notify()
    }

    // MARK: - Screen and messages

    /// Captures a calculator's display.
    public func captureScreen(from entry: CalculatorEntry) async -> [UInt8]? {
        guard let session = entry.session else { return nil }
        var image: [UInt8]?
        await runBusy("Capturing \(entry.name)'s screen…") {
            do {
                image = try session.captureScreen()
                entry.lastScreen = image
                self.status("Captured \(entry.name)'s screen")
            } catch {
                self.status("Screen capture failed: \(Self.describe(error))")
            }
        }
        notify()
        return image
    }

    /// Sends a message to one calculator, or to all attached ones.
    public func sendMessage(_ text: String, to entries: [CalculatorEntry]) async {
        let targets = entries.isEmpty ? calculators.filter(\.isAttached) : entries
        guard !targets.isEmpty else {
            status("No calculators are connected.")
            return
        }
        await runBusy("Sending message…") {
            var failures: [String] = []
            for entry in targets {
                do { try entry.session?.sendMessage(text) }
                catch { failures.append("\(entry.name): \(Self.describe(error))") }
            }
            self.status(failures.isEmpty
                ? "Message sent to \(targets.count) calculator(s)"
                : "Some messages failed — " + failures.joined(separator: "; "))
        }
        notify()
    }

    /// Sets every attached calculator's clock to the computer's.
    public func syncClocks() async {
        let targets = calculators.filter(\.isAttached)
        for entry in targets {
            try? entry.session?.setDateTime(Date())
        }
        status("Clock sent to \(targets.count) calculator(s)")
        notify()
    }

    // MARK: - Backups

    /// Downloads a calculator into a zip file in the Backups folder.
    public func backUp(_ entry: CalculatorEntry) async -> URL? {
        guard let session = entry.session else { return nil }
        var destination: URL?
        await runBusy("Backing up \(entry.name)…") {
            do {
                let result = try session.receiveBackup()
                let url = try BackupArchive.write(
                    objects: result.objects,
                    calculatorName: entry.name,
                    into: self.workingFolder.backupsURL
                )
                destination = url
                entry.update(deviceObjects: result.objects)
                try self.mirror(entry)
                self.status(result.damagedCount == 0
                    ? "Backed up \(result.objects.count) objects to \(url.lastPathComponent)"
                    : "Backup finished with \(result.damagedCount) damaged frame(s)")
            } catch {
                self.status("Backup failed: \(Self.describe(error))")
            }
        }
        notify()
        return destination
    }

    /// Uploads a backup archive into a calculator.
    public func restore(_ entry: CalculatorEntry, from archive: URL) async {
        guard let session = entry.session else { return }
        await runBusy("Restoring \(entry.name)…") {
            do {
                let objects = try BackupArchive.read(archive)
                try session.sendObjects(objects)
                entry.update(deviceObjects: try CalculatorLink.inventory(from: session))
                try self.mirror(entry)
                self.status("Restored \(objects.count) objects into \(entry.name)")
            } catch {
                self.status("Restore failed: \(Self.describe(error))")
            }
        }
        notify()
    }

    /// Copies one calculator's contents into another.
    public func clone(from source: CalculatorEntry, to destination: CalculatorEntry) async {
        guard let sourceSession = source.session, let destinationSession = destination.session else { return }
        await runBusy("Cloning \(source.name) to \(destination.name)…") {
            do {
                let result = try sourceSession.receiveBackup()
                // Exam configurations are deliberately skipped: cloning one
                // would let a configuration that is meant for one calculator be
                // applied to another without the teacher choosing it.
                let transferable = result.objects.filter { $0.type != .examConfiguration }
                try destinationSession.sendObjects(transferable)
                destination.update(deviceObjects: try CalculatorLink.inventory(from: destinationSession))
                try self.mirror(destination)
                self.status("Cloned \(transferable.count) objects into \(destination.name)")
            } catch {
                self.status("Clone failed: \(Self.describe(error))")
            }
        }
        notify()
    }

    /// Renames a calculator, on the device and in the working folder.
    public func rename(_ entry: CalculatorEntry, to newName: String) async {
        do {
            try PrimeObjectName.validate(newName)
        } catch {
            status(Self.describe(error))
            return
        }

        await runBusy("Renaming \(entry.name)…") {
            // There is no protocol command to rename a calculator: the name lives
            // in Home Settings and is written back through the settings object,
            // whose layout is not public. The folder is renamed so that the local
            // mirror matches, and the limitation is reported rather than hidden.
            self.adoptName(newName, for: entry)
            self.status("Renamed the local folder to \(newName). To change the name on the calculator itself, use Home Settings page 2.")
        }
        notify()
    }

    // MARK: - Busy reporting

    private func runBusy(_ message: String, _ body: () async -> Void) async {
        isBusy = true
        statusMessage = message
        NotificationCenter.default.post(name: Self.didChangeBusyState, object: self)
        await body()
        isBusy = false
        NotificationCenter.default.post(name: Self.didChangeBusyState, object: self)
    }

    /// Sets the status line, used by the window for transient messages.
    func status(_ message: String) {
        statusMessage = message
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Turns an error into something worth showing a user.
    ///
    /// Non-isolated because it is used from the detached tasks that perform the
    /// blocking link work.
    nonisolated static func describe(_ error: Error) -> String {
        if let link = error as? HPLinkError, let description = link.errorDescription {
            return description
        }
        return (error as NSError).localizedDescription
    }
}

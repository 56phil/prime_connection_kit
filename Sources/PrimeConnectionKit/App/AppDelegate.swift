import AppKit
import HPLink

/// The application entry point.
///
/// An explicit `main()` is used rather than `@main` on the delegate, because the
/// delegate alone does not guarantee that `NSApplication.run()` is reached: the
/// process would start, install no delegate callbacks, and sit idle with no
/// window and the default menu bar.
@main
enum PrimeConnectionKitMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

/// The application delegate: owns the model, the main window and the device poll.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var model: WorkspaceModel?
    private var devicePollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = WorkspaceModel()
        self.model = model
        model.start()

        let controller = MainWindowController(model: model)
        mainWindowController = controller
        NSApplication.shared.mainMenu = MainWindowController.makeMenuBar(target: controller)

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Devices can be attached at any time, and there is no notification for
        // the link layer, so the device list is polled.
        devicePollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak controller] _ in
            Task { @MainActor in controller?.pollForDevices() }
        }

        if ProcessInfo.processInfo.environment["PRIME_CONNECTION_KIT_DEMO"] == "1" {
            // Diagnostic mode: exercise the UI without hardware.
            controller.openDemoContent()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let mainWindowController else { return .terminateNow }
        return mainWindowController.reviewUnsavedWork() ? .terminateNow : .terminateCancel
    }
}

extension MainWindowController {
    /// Opens sample content so the interface can be exercised without a
    /// calculator attached, used by the diagnostic mode.
    func openDemoContent() {
        let program = PrimeProgramTemplate.sources[0]
        let programBytes = (try? PrimeProgramFile.encode(source: program.body, name: "Demo"))
            ?? PrimeTextContent.encode(program.body)
        open(PrimeObject(name: "Demo", type: .program, content: programBytes))

        open(PrimeObject(
            name: "DemoNote",
            type: .note,
            content: PrimeNoteFile.encode(text: "A sample note.", reusing: nil, isAppNote: false)
        ))

        open(PrimeObject(
            name: "L1",
            type: .list,
            content: (try? PrimeListCodec.encode([
                PrimeListCodec.Element(real: 1),
                PrimeListCodec.Element(real: 2.5),
                PrimeListCodec.Element(real: -3),
            ])) ?? []
        ))

        open(PrimeObject(
            name: "M1",
            type: .matrix,
            content: (try? PrimeMatrixCodec.encode(.init(
                rows: 2,
                columns: 2,
                cells: [
                    .init(real: 1), .init(real: 2),
                    .init(real: 3), .init(real: 4),
                ]
            ))) ?? []
        ))
    }
}

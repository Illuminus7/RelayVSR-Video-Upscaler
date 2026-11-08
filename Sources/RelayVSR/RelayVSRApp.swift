import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One copy of the app at a time: a second copy brings the first to the front and quits.
    /// This also makes it safe to clear leftover engine processes at launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
            other.activate()
            exit(0)
        }
    }

    /// Closing the window quits the app, which then stops the engine.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct RelayVSRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Always dark, regardless of the system setting.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        // A single window: no File ▸ New Window.
        Window("RelayVSR", id: "main") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

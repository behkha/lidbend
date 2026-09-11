import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.start()
        menuBar.install()

        // Nothing is configured on a first launch, so open the settings window.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            menuBar.openSettings()
        }
    }

    /// Opening the app again from Finder or `open` should surface the settings
    /// window; a menu-bar app has no document window to restore on its own.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        menuBar.openSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

@main
enum Lidbend {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

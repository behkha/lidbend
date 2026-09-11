import AppKit
import SwiftUI
import Combine

/// Status-bar item and the settings window.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let controller = AppController.shared
    private let settings = AppSettings.shared

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let angleItem = NSMenuItem(title: "Hinge: —", action: nil, keyEquivalent: "")

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macbook",
                                     accessibilityDescription: "Lidbend")
        item.button?.image?.isTemplate = true
        item.menu = makeMenu()
        statusItem = item

        controller.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in
                self?.statusItem?.button?.alphaValue = progress > 0.002 ? 1.0 : 0.75
            }
            .store(in: &cancellables)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        angleItem.isEnabled = false
        menu.addItem(angleItem)
        menu.addItem(.separator())

        menu.addItem(item("Effect Enabled", #selector(toggleEnabled), tag: 1))
        menu.addItem(item("Pause", #selector(togglePause), key: "p", tag: 2))
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for (index, style) in BendStyle.allCases.enumerated() {
            let entry = item(style.title, #selector(selectStyle(_:)), tag: 100 + index)
            entry.representedObject = style.rawValue
            styleMenu.addItem(entry)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Lidbend", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector,
                      key: String = "", tag: Int = 0) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.tag = tag
        return entry
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let angle = settings.angleSource == .manual
            ? settings.manualAngle : controller.lidAngle
        angleItem.title = angle.map { "Hinge: \(Int($0.rounded()))°  ·  bend \(Int((controller.progress * 100).rounded()))%" }
            ?? "Hinge: no sensor"

        for entry in menu.items {
            switch entry.tag {
            case 1: entry.state = settings.enabled ? .on : .off
            case 2:
                entry.state = controller.isPaused ? .on : .off
                entry.title = controller.isPaused ? "Resume" : "Pause"
            default: break
            }
        }
        for entry in menu.item(withTitle: "Style")?.submenu?.items ?? [] {
            entry.state = (entry.representedObject as? String) == settings.style.rawValue ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func togglePause() { controller.isPaused.toggle() }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = BendStyle(rawValue: raw) else { return }
        settings.style = style
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc func openSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Lidbend"
        // The sidebar runs up under the traffic lights, System Settings style.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()

        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

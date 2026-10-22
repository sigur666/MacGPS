import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// Opens the main window; captured from SwiftUI's `openWindow` once a scene has appeared.
    static var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dock click while the app is still running (it keeps running for the menu bar icon):
    /// bring the closed main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = sender.windows.first(where: { $0.isMiniaturized }) {
                window.deminiaturize(nil)
            } else {
                Self.openMainWindow?()
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

@main
struct MacGPSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacGPS", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    delegate.model = model
                    (AppIcon(rawValue: UserDefaults.standard.string(forKey: "appIcon") ?? "") ?? .default).apply()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("Copy Coordinates") { model.copyCoordinates() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Open in Maps") { model.openInMaps() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!model.tpv.hasFix)
            }
        }

        Settings {
            IconSettingsView()
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.tpv.hasFix ? "location.fill" : (model.gpsdRunning ? "location" : "location.slash"))
        }
        .menuBarExtraStyle(.window)
    }
}

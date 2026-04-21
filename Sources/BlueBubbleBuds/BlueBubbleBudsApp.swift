import SwiftUI
import AppKit

@main
struct BlueBubbleBudsApp: App {
    init() {
        // `swift run` launches the binary without an Info.plist, so macOS
        // defaults the activation policy to .prohibited and the window
        // never surfaces. Force .regular + activate so dev-mode runs
        // show a foreground window. Harmless inside the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Blue Bubble Buds") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}

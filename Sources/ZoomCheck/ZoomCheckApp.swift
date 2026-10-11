import AppKit
import SwiftUI

@main
struct ZoomCheckApp: App {
    init() {
        // Makes `swift run` behave like a normal app (Dock icon, focus).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("ZoomCheck") {
            ContentView()
                .frame(minWidth: 880, minHeight: 580)
        }
        .windowResizability(.contentMinSize)
    }
}

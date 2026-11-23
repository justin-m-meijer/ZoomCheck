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
        .commands {
            CommandGroup(replacing: .help) {
                Button("Report a Problem or Ask a Question…") {
                    NSWorkspace.shared.open(SupportForm.url)
                }
            }
        }
    }
}

/// The support form turns a report into a GitHub issue. Opened in the browser with the app and the system
/// filled in; nothing is sent until the user presses the button on that page.
enum SupportForm {
    static var url: URL {
        var c = URLComponents(string: "https://support.justinmeijer.nl/")!
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        c.queryItems = [
            URLQueryItem(name: "app", value: "zoomcheck"),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "os", value: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString),
            URLQueryItem(name: "lang", value: "en"),
        ]
        return c.url!
    }
}

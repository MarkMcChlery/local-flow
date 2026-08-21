import SwiftUI
import KeyboardShortcuts

// Global hotkey definitions. Users can remap both in Settings.
extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", default: .init(.space, modifiers: [.option]))
    static let commandMode = Self("commandMode", default: .init(.space, modifiers: [.option, .shift]))
}

@main
struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.state.symbolName)
        }

        Window("Local Flow Settings", id: "settings") {
            SettingsView()
                .environmentObject(controller)
                .frame(minWidth: 560, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppController.shared.startup()
    }
}

struct MenuContent: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.statusLine)

        if !controller.permissionsOK {
            Button("Finish setup (permissions needed)…") { openSettings() }
        }

        Divider()

        Button("Undo last insert") { controller.undoLastInsert() }
            .disabled(controller.history.isEmpty)

        Menu("Recent dictations") {
            if controller.history.isEmpty {
                Text("Nothing yet")
            }
            ForEach(controller.history) { item in
                Button(item.preview) { controller.copyToClipboard(item.text) }
            }
        }

        Divider()

        Button("Settings…") { openSettings() }
        Button("Quit Local Flow") { NSApp.terminate(nil) }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

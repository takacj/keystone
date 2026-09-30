import SwiftUI

@main
struct SecreterApp: App {
    @State private var model = UITestSupport.isActive ? AppModel.uiTest() : AppModel()
    @State private var lock = LockModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .appLock()
                .environment(lock)
        }
        Settings {
            SettingsView()
                .environment(model)
        }
        .commands {
            SecreterCommands()
            CommandGroup(after: .appSettings) {
                Button("Lock Secreter") { lock.lock() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!lock.isEnabled)
            }
        }
    }
}

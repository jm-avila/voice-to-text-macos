import AppKit

/// Starts the CLI when there is a command after the app's name, else the app.
@main
enum Main {
    static func main() {
        if let code = AgentCLI.runIfRequested() { exit(code) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu bar app: no Dock icon, no main menu.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

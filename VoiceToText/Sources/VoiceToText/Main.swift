import AppKit

/// Starts the CLI when there is a command after the app's name, else the app.
@main
enum Main {
    static func main() {
        // A CLI or MCP client that quits before its reply would otherwise kill the app on write.
        signal(SIGPIPE, SIG_IGN)
        if let code = AgentCLI.runIfRequested() { exit(code) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // A menu bar app: no Dock icon, no main menu.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

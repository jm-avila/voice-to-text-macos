import AppKit
import VoiceToTextKit

// VoiceToText: push-to-talk dictation in the menu bar.
//   VoiceToText                       the app (menu bar only, no Dock icon)
//   APP_STORE=<folder> VoiceToText    use another folder for history and settings (tests, experiments)
//   APP_SNAPSHOT=<dir> VoiceToText    save PNGs of the HUD states and Settings in light and dark, then quit
//   APP_SEED=1 VoiceToText            fill an empty /tmp store with sample history (tools/snap.sh)
//   VoiceToText --selftest            run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   vtt help                          the agent CLI (Agent/, linked to ~/.local/bin/vtt by build.sh)

/// Builds every part once and wires them together. The app, the agent
/// commands, the self-test, and snapshot mode all go through it.
final class Services {
    let store: Store
    let permissions = Permissions()
    let hotkeys = HotkeyCenter.shared
    let loginItem = LoginItem()
    let dictation: Dictation
    let hud: RecordingHUD
    private(set) var statusItem: StatusItem!
    private(set) var settingsWindow: SettingsWindow!

    init(recorder: AudioRecording, transcriber: Transcribing, pasteboard: NSPasteboard) {
        store = Store()
        dictation = Dictation(store: store, recorder: recorder, transcriber: transcriber, paster: Paster(pasteboard: pasteboard))
        hud = RecordingHUD(dictation: dictation)
        settingsWindow = SettingsWindow { [unowned self] in self }
        statusItem = StatusItem(dictation: dictation, hotkeys: hotkeys) { [unowned self] in settingsWindow.show() }
        dictation.onChange = { [unowned self] in
            hud.refresh()
            statusItem.refresh()
        }
    }

    /// The real microphone, OpenAI, and the clipboard.
    static func live() -> Services {
        let base = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"].flatMap(URL.init(string:))
        let transcriber = OpenAITranscriber(baseURL: base ?? URL(string: "https://api.openai.com/v1")!) { APIKey.read() }
        return Services(recorder: MicRecorder(), transcriber: transcriber, pasteboard: .general)
    }

    /// Fakes for the self-test and snapshots: no microphone, no network, a private pasteboard, silent.
    static func testing() -> Services {
        let services = Services(recorder: FakeRecorder(), transcriber: FakeTranscriber(),
                                pasteboard: NSPasteboard(name: NSPasteboard.Name("com.jmavila.voicetotext.selftest")))
        services.dictation.paster.postsPaste = false
        services.dictation.sounds.audible = false
        return services
    }

    func start() {
        permissions.startPolling()
        // A test copy (APP_STORE) never takes the global shortcut from the real app.
        if !Store.isOverridden {
            hotkeys.register(.dictate) { [weak self] in
                guard let self else { return }
                Task { await self.dictation.toggle() }
            }
        }
        statusItem.refresh()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = SelfTest.requested || Snapshot.requested ? Services.testing() : Services.live()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AgentRouter.services = services
        SeedData.insertIfRequested(into: services)
        if SelfTest.runIfRequested(services: services) { return }
        if Snapshot.runIfRequested(services: services) { return }
        // After the checks above: a refused test run must not take over the real app's socket.
        AgentSocket.listen { await AgentRouter.handle($0) }
        services.start()
    }

    /// Opening the app again (Finder, Spotlight) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services.settingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

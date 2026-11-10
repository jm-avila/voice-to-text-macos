import AppKit
import VoiceToTextKit

// VoiceToText: push-to-talk dictation in the menu bar.
//   VoiceToText                       the app (menu bar only, no Dock icon)
//   APP_STORE=<folder> VoiceToText    use another folder for history and settings (tests, experiments)
//   APP_SNAPSHOT=<dir> VoiceToText    save PNGs of the HUD states and Settings in light and dark, then quit
//   APP_FAKE_MIC=<file> (with APP_STORE)  the "microphone" plays that audio file (tools/latency.sh)
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
    /// The local model, kept loaded while it is selected. nil with the fakes.
    let server: WhisperServer?
    /// Parakeet, kept loaded while it is selected. nil with the fakes.
    let parakeet: ParakeetTranscriber?
    let shortcutRecorder: ShortcutRecorder
    let hud: RecordingHUD
    private(set) var statusItem: StatusItem!
    private(set) var settingsWindow: SettingsWindow!

    init(recorder: AudioRecording, transcriber: Transcribing, streamer: ChunkTranscribing?, server: WhisperServer? = nil,
         parakeet: ParakeetTranscriber? = nil, sampler: SampleTranscribing? = nil, pasteboard: NSPasteboard) {
        store = Store()
        self.server = server
        self.parakeet = parakeet
        dictation = Dictation(store: store, recorder: recorder, transcriber: transcriber, streamer: streamer,
                              sampler: sampler ?? parakeet, paster: Paster(pasteboard: pasteboard))
        hud = RecordingHUD(dictation: dictation, permissions: permissions)
        shortcutRecorder = ShortcutRecorder(hotkeys: hotkeys, dictation: dictation)
        settingsWindow = SettingsWindow { [unowned self] in self }
        statusItem = StatusItem(dictation: dictation, hotkeys: hotkeys, permissions: permissions) { [unowned self] in settingsWindow.show() }
        dictation.onChange = { [unowned self] in
            hud.refresh()
            statusItem.refresh()
        }
        dictation.ready = { [unowned self] in permissions.missing.isEmpty }
        permissions.residency = { [server, parakeet] in
            // The fakes have neither: the self-test and snapshots set them by hand.
            guard server != nil || parakeet != nil else { return nil }
            return (server?.residency ?? .off, parakeet?.residency ?? .off)
        }
        dictation.blocked = { [unowned self] in
            guard !permissions.missing.isEmpty else { return false }
            settingsWindow.show()
            return true
        }
    }

    /// The real microphone, OpenAI or the local model, and the clipboard.
    static func live() -> Services {
        let base = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"].flatMap(URL.init(string:))
        let openAI = OpenAITranscriber(baseURL: base ?? URL(string: "https://api.openai.com/v1")!) { APIKey.read() }
        let server = WhisperServer()
        let parakeet = ParakeetTranscriber()
        let transcriber = RoutingTranscriber(openAI: openAI, local: LocalTranscriber(server: server), parakeet: parakeet)
        // A test copy can take its "microphone" from a file (tools/latency.sh).
        let fakeMic = Store.isOverridden ? ProcessInfo.processInfo.environment["APP_FAKE_MIC"].map(URL.init(fileURLWithPath:)) : nil
        let recorder: AudioRecording = fakeMic.map(FileRecorder.init(source:)) ?? MicRecorder()
        return Services(recorder: recorder, transcriber: transcriber, streamer: server, server: server,
                        parakeet: parakeet, pasteboard: .general)
    }

    /// Fakes for the self-test and snapshots: no microphone, no network, a private pasteboard, silent.
    static func testing() -> Services {
        let transcriber = FakeTranscriber()
        let services = Services(recorder: FakeRecorder(), transcriber: transcriber, streamer: transcriber,
                                sampler: transcriber, pasteboard: NSPasteboard(name: NSPasteboard.Name("com.jmavila.voicetotext.selftest")))
        services.dictation.paster.postsPaste = false
        services.dictation.sounds.audible = false
        return services
    }

    /// The local Whisper server runs while Whisper is selected, and stops (freeing
    /// 1.6 GB) when another model is chosen. Parakeet loads (the first time,
    /// downloads) when it is chosen and is freed when another one is.
    func syncServer() {
        let model = dictation.settings.model
        // Settings, the HUD, and `vtt status` show the result (loaded, or failed and why) at once.
        if let server {
            if model == LocalWhisper.model, LocalWhisper.status == .ready {
                Task { await server.start(); permissions.refresh() }
            } else {
                server.stop()
            }
        }
        if let parakeet {
            if model == Parakeet.model {
                // A failure (no network for the first download) shows in Settings; the next dictation loads again.
                Task { _ = try? await parakeet.load(); permissions.refresh() }
            } else {
                parakeet.unload()
            }
        }
        permissions.refresh()
    }

    func start() {
        syncServer()
        dictation.onSettingsChange = { [unowned self] in syncServer() }
        permissions.startPolling()
        permissions.onChange = { [unowned self] in
            // Monitors added before Accessibility see nothing: add them again.
            if permissions.accessibility, !hotkeys.isRegistered { hotkeys.retry() }
            statusItem.refresh()
        }
        // A test copy (APP_STORE) never takes the global shortcut from the real app.
        if !Store.isOverridden {
            hotkeys.register(dictation.settings.shortcut) { [weak self] in
                guard let self else { return }
                Task { await self.dictation.toggle() }
            }
            // ⌥⌘ and the like fire on release: open the mic on the press, so the first words are heard.
            hotkeys.onEarly = { [weak self] event in
                guard let self else { return }
                if event == .pressed { dictation.openEarly() } else { dictation.dropEarly() }
            }
            dictation.onEarlyExpired = { [weak self] in self?.hotkeys.spoilTap() }
        } else {
            // Shows the saved one without registering it.
            _ = hotkeys.change(to: dictation.settings.shortcut)
        }
        statusItem.refresh()
        // Ask up front, not on the first dictation: macOS's mic prompt, then Settings with what is missing.
        if permissions.microphone == .notAsked { Task { _ = await permissions.requestMicrophone() } }
        if !permissions.missing.isEmpty { settingsWindow.show() }
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
        guard AgentSocket.listen(handle: { await AgentRouter.handle($0) }) else {
            // Started from a terminal while the app runs: one copy owns the hotkey and the socket.
            print("VoiceToText is already running. Use `vtt help`.")
            NSApp.terminate(nil)
            return
        }
        services.start()
    }

    /// Opening the app again (Finder, Spotlight) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        services.settingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.server?.stop()
        services.parakeet?.unload()
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

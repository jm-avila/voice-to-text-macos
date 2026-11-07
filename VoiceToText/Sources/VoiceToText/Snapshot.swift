import AppKit
import IOKit.pwr_mgt
import VoiceToTextKit

/// Screenshot mode for agents.
///   APP_STORE=/tmp/VoiceToText-test.store APP_SEED=1 APP_SNAPSHOT=/tmp/VoiceToText-shots ~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText
/// drives a real dictation with the fake mic and transcriber and writes
/// hud-<state>-light.png and -dark.png for every HUD state, then
/// settings-light.png and -dark.png (and settings-custom-, settings-recording-),
/// then quits. Each PNG gets a
/// <name>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=hud,settings limits the groups.
enum Snapshot {
    static var requested: Bool { !(ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? "").isEmpty }

    /// True when snapshot mode runs (the app does not start normally).
    static func runIfRequested(services: Services) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard requested, let dir = env["APP_SNAPSHOT"] else { return false }
        // Snapshots never run against the real history.
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE to a folder in /tmp")
            NSApp.terminate(nil)
            return true
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ group: String) -> Bool { only?.contains(group) ?? true }
        let dictation = services.dictation
        guard let recorder = dictation.recorder as? FakeRecorder,
              let transcriber = dictation.transcriber as? FakeTranscriber else { return false }
        // Settings takes keys while it is shown. Typing in another app during a run would land in it.
        _ = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in nil }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1))
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func shoot(_ name: String, _ mode: String) {
                capture(to: "\(dir)/\(name)-\(mode).png", window: services.hud.window, activate: false)
                // The menu bar icon in the same state (the menu bar follows the wallpaper, not the mode).
                capture(to: "\(dir)/menubar-\(name.replacingOccurrences(of: "hud-", with: ""))-\(mode).png",
                        window: services.statusItem.window, activate: false)
            }
            if wanted("hud") {
                for mode in ["light", "dark"] {
                    setAppearance(mode)
                    // Opening the mic, then live for a bit over a second.
                    recorder.startDelay = .seconds(1.2)
                    let starting = Task { try? await dictation.start() }
                    await pause(0.5)
                    shoot("hud-starting", mode)
                    await starting.value
                    await pause(0.3)
                    shoot("hud-speak", mode)   // the mic just went live
                    await pause(1.4)
                    shoot("hud-recording", mode)
                    // Transcribing, then pasted.
                    dictation.paster.canPaste = { true }
                    transcriber.reply = .success("Can you move our sync to Thursday at 4?")
                    transcriber.delay = .seconds(1.2)
                    let stopping = Task { _ = try? await dictation.stop(paste: true) }
                    await pause(0.5)
                    shoot("hud-transcribing", mode)
                    await stopping.value
                    await pause(0.2)
                    shoot("hud-pasted", mode)
                    // Copied only (no Accessibility), then an API error.
                    recorder.startDelay = .milliseconds(50)
                    transcriber.delay = .milliseconds(50)
                    dictation.paster.canPaste = { false }
                    try? await dictation.start()
                    _ = try? await dictation.stop(paste: true)
                    await pause(0.2)
                    shoot("hud-copied", mode)
                    transcriber.reply = .failure(TranscriptionError.api(status: 401, message:
                        "Incorrect API key provided: sk-proj-****abcd. You can find your API key at https://platform.openai.com/account/api-keys."))
                    try? await dictation.start()
                    _ = try? await dictation.stop(paste: true)
                    await pause(0.2)
                    shoot("hud-error", mode)
                    await pause(4.2)
                    capture(to: "\(dir)/menubar-failed-\(mode).png", window: services.statusItem.window, activate: false)
                }
            }
            if wanted("settings") {
                for mode in ["light", "dark"] {
                    setAppearance(mode)
                    services.settingsWindow.show()
                    await pause(1)
                    capture(to: "\(dir)/settings-\(mode).png", window: services.settingsWindow.nsWindow)
                    // S-011: a changed shortcut (Reset shows), then recording one after a refused ⇧D.
                    let custom = Shortcut(keyCode: 2, modifiers: Shortcut.option | Shortcut.command, key: "D")
                    _ = services.hotkeys.change(to: custom)
                    dictation.settings.shortcut = custom
                    await pause(0.5)
                    capture(to: "\(dir)/settings-custom-\(mode).png", window: services.settingsWindow.nsWindow)
                    services.settingsWindow.show()   // key again, or recording cancels at once
                    services.shortcutRecorder.start()
                    _ = services.shortcutRecorder.handle(NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                        characters: "D", charactersIgnoringModifiers: "D", isARepeat: false, keyCode: 2)!)
                    await pause(0.5)
                    capture(to: "\(dir)/settings-recording-\(mode).png", window: services.settingsWindow.nsWindow)
                    services.shortcutRecorder.reset()
                }
                services.settingsWindow.close()
            }
            print("SNAPSHOT done \(dir)")
            NSApp.terminate(nil)
        }
        return true
    }

    private static func setAppearance(_ mode: String) {
        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
    }

    /// Captures the real window with screencapture, so glass and materials
    /// look exactly as on screen. That needs Screen Recording permission for
    /// the app that started this one (your terminal, or Claude). Without it,
    /// falls back to drawing the view hierarchy, which leaves glass blank.
    private static func capture(to path: String, window: NSWindow?, activate: Bool = true) {
        // Another app can hide this one while snapshots run. Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window else {
            print("SNAPSHOT no window for \(path)")
            return
        }
        if activate {
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKey()
        }
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, glass is blank)")
        }
    }
}

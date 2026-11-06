import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import Observation
import VoiceToTextKit

/// Posts Command-V to the front app. Needs Accessibility. The marker lets
/// other tools tell this event from a real key press.
enum SyntheticEvents {
    static let marker: Int64 = 0x5654_5458   // "VTTX"

    static func paste() {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = marker
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cgSessionEventTap)
        }
    }
}

/// Accessibility (to paste), the microphone, and the local model, checked every second so
/// Settings updates within 2 s of a change, without a restart.
@Observable
final class Permissions {
    enum Microphone: String {
        case granted, notAsked, denied
    }

    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var microphone = Permissions.readMicrophone()
    /// Polled too, so Settings shows "Downloaded" once tools/get-model.sh finishes.
    private(set) var localModel = LocalWhisper.status
    @ObservationIgnored private var timer: Timer?

    func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
        let mic = Self.readMicrophone()
        if mic != microphone { microphone = mic }
        let local = LocalWhisper.status
        if local != localModel { localModel = local }
    }

    /// Asks for the microphone the first time; true when it may record.
    func requestMicrophone() async -> Bool {
        if microphone == .notAsked {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        }
        return microphone == .granted
    }

    /// Shows the system prompt and opens the Accessibility pane.
    func requestAccessibility() {
        // The key's value, kAXTrustedCheckOptionPrompt, as a literal: the C global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPane("Privacy_Accessibility")
    }

    func openPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    private static func readMicrophone() -> Microphone {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }
}

/// Reading a shortcut from a key press, and showing it in a menu.
extension Shortcut {
    /// Keys whose character is blank or a control code, by key code.
    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    init(event: NSEvent) {
        // The key's own character, as printed on it (⌥D gives "D", not "∂").
        let key = Self.name(keyCode: Int(event.keyCode), plain: event.characters(byApplyingModifiers: []) ?? "")
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.modifiers(event.modifierFlags), key: key)
    }

    /// AppKit's flags in Carbon bits.
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= Shortcut.control }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        if flags.contains(.command) { modifiers |= Shortcut.command }
        return modifiers
    }

    /// The key as printed on it, from its character with no modifiers. "" when it has no name.
    static func name(keyCode: Int, plain: String) -> String {
        if let name = names[keyCode] { return name }
        let plain = plain.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        // Other special keys (Help, keypad Clear) give a private-use glyph: no name, so refused.
        guard plain.count == 1, !plain.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return "" }
        // Uppercase unless that changes its length (ß would become SS).
        let upper = plain.uppercased()
        return upper.count == 1 ? upper : plain
    }

    /// For NSMenuItem.keyEquivalent: printable keys only, "" for the rest (no hint shown).
    var menuKey: String { key.count == 1 && Self.names[Int(keyCode)] == nil ? key.lowercased() : "" }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Shortcut.control != 0 { flags.insert(.control) }
        if modifiers & Shortcut.option != 0 { flags.insert(.option) }
        if modifiers & Shortcut.shift != 0 { flags.insert(.shift) }
        if modifiers & Shortcut.command != 0 { flags.insert(.command) }
        return flags
    }
}

/// One global shortcut through Carbon's RegisterEventHotKey: no permission,
/// and the key never reaches the front app. Registered exclusively, so it
/// fails (and Settings says so) while another app, like the Hammerspoon
/// version of this tool, owns ⌃. — both would record at once otherwise.
/// The combo comes from settings.json; Settings changes it. Modifiers alone
/// (⌥⌘) have no Carbon hotkey: event monitors watch for the tap instead.
/// Those see other apps' events only with Accessibility, which paste needs too.
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private(set) var combo = Shortcut.standard
    /// noErr when registered. Anything else: another app owns the combo.
    private(set) var status: OSStatus = noErr
    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var tap = ModifierTap(0)
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var handlerInstalled = false

    /// A modifiers-only tap also needs Accessibility: without it the monitors see nothing.
    var isRegistered: Bool { status == noErr && (ref != nil || (!monitors.isEmpty && AXIsProcessTrusted())) }
    /// Registering failed: another app owns the combo. False before the first
    /// try, so a test copy (which never registers) shows no warning.
    var isTaken: Bool { status != noErr }

    func register(_ combo: Shortcut, action: @escaping () -> Void) {
        unregister()
        self.combo = combo
        self.action = action
        if combo.isModifiersOnly {
            watchTap(combo.modifiers)
            status = noErr
            return
        }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5654_5458), id: 1)   // 'VTTX', 1
        status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(),
                                     OptionBits(kEventHotKeyExclusive), &ref)
        if status != noErr { ref = nil }
    }

    /// Tries again with the same combo and action (after the other app let go).
    func retry() {
        guard let action else { return }
        register(combo, action: action)
    }

    /// Moves to another combo. When another app owns it, keeps the old one and returns false.
    func change(to new: Shortcut) -> Bool {
        // A test copy never registers: only remember the combo.
        guard let action else { combo = new; return true }
        let old = combo
        register(new, action: action)
        if isRegistered { return true }
        register(old, action: action)
        return false
    }

    /// Lets go of the combo while Settings records a new one, so pressing the
    /// current one doesn't start dictating. resume() takes it back.
    func pause() { unregister() }
    func resume() { retry() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func fire() { action?() }

    /// Global monitors see other apps' events, the local one this app's (Settings).
    private func watchTap(_ modifiers: UInt32) {
        tap = ModifierTap(modifiers)
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events) { event in
                MainActor.assumeIsolated { HotkeyCenter.shared.handleTap(event) }
            },
            NSEvent.addLocalMonitorForEvents(matching: events) { event in
                HotkeyCenter.shared.handleTap(event)
                return event
            },
        ].compactMap { $0 }
    }

    func handleTap(_ event: NSEvent) {
        guard !monitors.isEmpty else { return }
        if event.type == .flagsChanged {
            if tap.changed(to: Shortcut.modifiers(event.modifierFlags)) { fire() }
        } else {
            tap.otherInput()
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotkeyCenter.shared.fire() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Settings' "Change…": the next key press with ⌃ or ⌥ becomes the
/// shortcut, saved to settings.json. Two or more modifiers pressed and let
/// go with no key become a modifiers-only one. Escape cancels.
@Observable
final class ShortcutRecorder {
    private(set) var isRecording = false
    /// Why the last press was not used. Shown under the row.
    private(set) var problem: String?
    @ObservationIgnored private let hotkeys: HotkeyCenter
    @ObservationIgnored private let dictation: Dictation
    @ObservationIgnored private var monitor: Any?
    /// Every modifier held since the last time none were.
    @ObservationIgnored private var peak: UInt32 = 0

    init(hotkeys: HotkeyCenter, dictation: Dictation) {
        self.hotkeys = hotkeys
        self.dictation = dictation
    }

    func start() {
        guard !isRecording else { return }
        problem = nil
        peak = 0
        isRecording = true
        hotkeys.pause()
        // Settings is the key window while recording, so a local monitor sees the press
        // before any menu shortcut does. Returning nil swallows it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    func cancel() { finish() }

    /// Uses a key press. True when it was meant for the recorder.
    func handle(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.type == .flagsChanged { return modifiersChanged(Shortcut.modifiers(event.modifierFlags)) }
        peak = 0   // a key came: the modifiers go with it
        let shortcut = Shortcut(event: event)
        if shortcut.modifiers == 0, Int(event.keyCode) == kVK_Escape {
            finish()
        } else if let problem = shortcut.problem {
            self.problem = problem
        } else {
            use(shortcut)
        }
        return true
    }

    /// Modifiers alone: used when let go, if two or more were held. Passed on
    /// (false) so the window still sees them.
    private func modifiersChanged(_ held: UInt32) -> Bool {
        if held != 0 { peak |= held; return false }
        let shortcut = Shortcut.modifiersOnly(peak)
        let count = peak.nonzeroBitCount
        peak = 0
        guard count >= 2 else { return false }   // one modifier: still choosing
        if let problem = shortcut.problem { self.problem = problem } else { use(shortcut) }
        return false
    }

    func reset() { use(.standard) }

    private func use(_ shortcut: Shortcut) {
        finish()
        if hotkeys.change(to: shortcut) {
            dictation.settings.shortcut = shortcut
            problem = nil
        } else {
            problem = "Another app uses \(shortcut.symbols). Pick another one."
        }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        hotkeys.resume()
    }
}

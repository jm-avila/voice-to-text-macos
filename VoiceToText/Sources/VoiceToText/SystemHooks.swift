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

/// A key and modifiers in Carbon terms, with the symbols people read.
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let dictate = KeyCombo(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(controlKey), key: ".")

    var symbols: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }
}

/// One global shortcut through Carbon's RegisterEventHotKey: no permission,
/// and the key never reaches the front app. Registered exclusively, so it
/// fails (and Settings says so) while another app, like the Hammerspoon
/// version of this tool, owns ⌃. — both would record at once otherwise.
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private(set) var combo = KeyCombo.dictate
    /// noErr when registered. Anything else: another app owns the combo.
    private(set) var status: OSStatus = noErr
    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var action: (() -> Void)?
    @ObservationIgnored private var handlerInstalled = false

    var isRegistered: Bool { ref != nil && status == noErr }
    /// Registering failed: another app owns the combo. False before the first
    /// try, so a test copy (which never registers) shows no warning.
    var isTaken: Bool { status != noErr }

    func register(_ combo: KeyCombo, action: @escaping () -> Void) {
        unregister()
        self.combo = combo
        self.action = action
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

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    func fire() { action?() }

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

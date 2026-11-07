import AppKit
import ServiceManagement
import SwiftUI
import VoiceToTextKit

/// One small Settings window: what to dictate with, what it needs, where
/// the history is. Opened from the menu, ⌘, in the menu, or by opening the app again.
final class SettingsWindow {
    private let services: () -> Services
    private var window: NSWindow?

    init(services: @escaping () -> Services) {
        self.services = services
    }

    var nsWindow: NSWindow? { window }
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        services().dictation.reloadHistory()
        let window = self.window ?? make()
        if !window.isVisible { window.center() }
        // A menu bar app is never active on its own; bring the window to the front.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func make() -> NSWindow {
        let services = services()
        let root = SettingsView(dictation: services.dictation, permissions: services.permissions,
                                hotkeys: services.hotkeys, recorder: services.shortcutRecorder, login: services.loginItem)
            .themed()
            .noInitialFocus()
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: controller)
        window.title = "VoiceToText Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Closing the window, or clicking another app, while it records a shortcut gives
        // the old one back: the local monitor only sees keys while Settings is key.
        // (SwiftUI's onDisappear does not run: the window only orders out.)
        let recorder = services.shortcutRecorder
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { recorder.cancel() }
            }
        }
        self.window = window
        return window
    }
}

/// Open at Login, through the system's login items.
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var needsApproval = SMAppService.mainApp.status == .requiresApproval
    private(set) var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
        needsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

struct SettingsView: View {
    @Bindable var dictation: Dictation
    let permissions: Permissions
    let hotkeys: HotkeyCenter
    let recorder: ShortcutRecorder
    let login: LoginItem
    /// Looked up when the window opens: it asks Keychain through /usr/bin/security.
    @ViewState private var keyFound: Bool?

    var body: some View {
        Form {
            if !permissions.missing.isEmpty {
                Section {
                    ForEach(permissions.missing) { need in
                        LabeledContent {
                            Button(permissions.fixTitle(need)) { permissions.fix(need) }
                                .buttonStyle(.borderedProminent)
                        } label: {
                            Label(need.title, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.primary, .orange)
                            Text(need.why)
                        }
                    }
                } header: {
                    Text("Needed before you dictate")
                }
            }
            Section("Dictation") {
                LabeledContent("Shortcut") {
                    HStack(spacing: Space.sm) {
                        if recorder.isRecording {
                            Text("Type a shortcut…")
                                .foregroundStyle(.secondary)
                            Button("Cancel") { recorder.cancel() }
                        } else {
                            KeyCap(text: hotkeys.combo.symbols)
                            Button("Change…") { recorder.start() }
                            if hotkeys.combo != .standard {
                                Button("Reset") { recorder.reset() }
                                    .help("Back to \(Shortcut.standard.symbols)")
                            }
                        }
                    }
                }
                if let problem = recorder.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if hotkeys.isTaken {
                    LabeledContent {
                        Button("Try Again") { hotkeys.retry() }
                    } label: {
                        Label(hotkeys.combo == .standard
                              ? "Another app uses \(hotkeys.combo.symbols), maybe the Hammerspoon version. Turn it off there."
                              : "Another app uses \(hotkeys.combo.symbols). Turn it off there, or change the shortcut.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Picker("Model", selection: $dictation.settings.model) {
                    ForEach(DictationSettings.models, id: \.self) { Text(DictationSettings.modelName($0)).tag($0) }
                }
                Picker("Language", selection: $dictation.settings.language) {
                    ForEach(DictationSettings.languages, id: \.self) { Text(Self.languageName($0)).tag($0) }
                }
                Toggle(isOn: $dictation.settings.sounds) {
                    Text("Sounds")
                    Text("Tink when the mic is live, Pop when it stops.")
                }
                Toggle(isOn: $dictation.settings.clickToDictate) {
                    Text("Click Icon to Dictate")
                    Text("Right-click or ⌥-click the icon for the menu.")
                }
                Toggle(isOn: $dictation.settings.hideWhenIdle) {
                    Text("Hide Icon When Idle")
                    Text("It shows while dictating. Open VoiceToText again for Settings.")
                }
                Toggle("Open at Login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval || login.error != nil {
                    Text(login.error ?? "Allow VoiceToText in System Settings › General › Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("OpenAI key") {
                    switch keyFound {
                    case nil: ProgressView().controlSize(.small)
                    case true?: Status(ok: true, text: "In Keychain")
                    case false?: Status(ok: false, text: "Missing")
                    }
                }
                LabeledContent("Local model") {
                    switch permissions.localModel {
                    case .ready: Status(ok: true, text: "Downloaded")
                    case .noModel: Status(ok: false, text: "Not downloaded")
                    case .noCLI: Status(ok: false, text: "Needs whisper.cpp")
                    }
                }
                // Missing ones are at the top, with their button.
                if permissions.microphone == .granted {
                    LabeledContent("Microphone") { Status(ok: true, text: "Allowed") }
                }
                if permissions.accessibility {
                    LabeledContent("Accessibility") { Status(ok: true, text: "Allowed") }
                }
            } header: {
                Text("Access")
            } footer: {
                Text(footer)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(dictation.history.count == 1 ? "1 transcript" : "\(dictation.history.count) transcripts") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([dictation.store.historyURL])
                    }
                    .disabled(dictation.history.isEmpty)
                }
            } header: {
                Text("History")
            }
        }
        .formStyle(.grouped)
        // Every row shows without scrolling on a 13" screen.
        .fitsContent(max: 760)
        .frame(width: 480)
        .task { keyFound = await Task.detached { APIKey.read() != nil }.value }
    }

    /// The one hint that matters most for the model in use.
    private var footer: String {
        let local = dictation.settings.model == LocalWhisper.model
        if local, permissions.localModel != .ready {
            return "For the local model, run VoiceToText/tools/get-model.sh (whisper.cpp and 1.6 GB of model)."
        }
        if !local, keyFound == false { return "Add your key: secret set OPENAI_API_KEY -p openai --clip" }
        return "Accessibility lets VoiceToText paste. Without it, press ⌘V yourself."
    }

    static func languageName(_ code: String) -> String {
        code.isEmpty ? "Detect automatically" : Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}

private struct Status: View {
    var ok: Bool
    var text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(.secondary, ok ? .green : .red)
    }
}

/// A key as printed on the keyboard: ⌃.
struct KeyCap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.body.monospaced().weight(.medium))
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 2)
            .background(.quaternary, in: .rect(cornerRadius: 4))
    }
}

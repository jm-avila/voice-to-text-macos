import AppKit
import UniformTypeIdentifiers
import VoiceToTextKit

/// The menu bar icon and its menu. The icon follows the dictation:
///   waveform          ready (a red dot: the last try failed and the menu hasn't been opened since,
///                     or the mic or Accessibility is missing)
///   mic, dimmed       the mic is opening: don't talk yet
///   level bars, 0:07  the mic is live: its level and the time. Not a mic, which
///                     would repeat macOS's orange mic indicator next to it
///   three dots        transcribing, one lit at a time
///   checkmark / ✕     for a moment after a paste or copy, or a failure
/// Settings can make a click dictate (right-click or ⌥-click opens the menu)
/// and hide the icon while idle. An audio file dropped on it is transcribed and copied.
final class StatusItem: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let dictation: Dictation
    private let hotkeys: HotkeyCenter
    private let permissions: Permissions
    private let openSettings: () -> Void
    /// What is on screen, for the self-test: an SF Symbol name, or "level" / "dots" for the drawn ones.
    private(set) var symbolName = ""
    /// The time beside the level bars while recording; "" otherwise.
    private(set) var title = ""
    /// The last try failed and the menu hasn't been opened since.
    var hasFailureDot: Bool { dictation.lastError != nil && dictation.failures > seenFailures }
    /// The mic or Accessibility is missing. The dot stays until it is allowed.
    var needsAccess: Bool { !permissions.missing.isEmpty }
    var isShown: Bool { item.isVisible }
    /// The icon's window, for snapshots.
    var window: NSWindow? { item.button?.window }
    var clickDictates: Bool { item.menu == nil }
    private var seenFailures = 0
    private var menuIsOpen = false
    private let dot = NSView()
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    /// Which of the three dots is lit while transcribing.
    private var frame = 0

    init(dictation: Dictation, hotkeys: HotkeyCenter, permissions: Permissions, openSettings: @escaping () -> Void) {
        self.dictation = dictation
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            // Used only when a click dictates: with a menu set, a click opens it instead.
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = Self.dotSize / 2
            dot.isHidden = true
            button.addSubview(dot)
            // Files dropped on the icon reach the window's delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        refresh()
    }

    private static let dotSize: CGFloat = 6

    /// After any change of state, notice, or settings.
    func refresh() {
        let settings = dictation.settings
        if !menuIsOpen { item.menu = settings.clickToDictate ? nil : menu }
        let busy = dictation.state != .idle || dictation.notice != nil
        item.isVisible = busy || hasFailureDot || needsAccess || !settings.hideWhenIdle
        updateTimer()
        redraw()
    }

    /// The icon and title. Runs on every timer tick while recording or transcribing.
    private func redraw() {
        guard let button = item.button else { return }
        var image: NSImage?
        var tip: String
        title = ""
        switch (dictation.state, dictation.notice) {
        case (.idle, .pasted?), (.idle, .copied?):
            symbolName = "checkmark"
            tip = "Done"
        case (.idle, .error?):
            symbolName = "xmark"
            tip = "Failed"
        case (.idle, _):
            symbolName = "waveform"
            tip = needsAccess ? "VoiceToText needs \(permissions.missing.map(\.title).joined(separator: " and ")). Open the menu"
                : hasFailureDot ? "VoiceToText: the last try failed. Open the menu" : "VoiceToText: press \(hotkeys.combo.symbols) to dictate"
        case (.starting, _):
            symbolName = "mic"
            tip = "Opening the mic. Wait to talk"
        case (.recording, _):
            symbolName = "level"
            image = Self.levelBars(dictation.recorder.level())
            title = Elapsed.text(dictation.elapsed)
            tip = "Recording. Press \(hotkeys.combo.symbols) to stop"
        case (.transcribing, _):
            symbolName = "dots"
            image = Self.dots(lit: frame % 3)
            tip = permissions.waiting(for: dictation.settings.model) ?? "Transcribing"
        }
        if image == nil {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tip)
            image?.isTemplate = true
        }
        button.image = image
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(string: title.isEmpty ? "" : " \(title)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular),
        ])
        button.appearsDisabled = dictation.state == .starting
        // Only on change: redraw runs 10 times a second, and resetting a tooltip hides it.
        if button.toolTip != tip {
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
        }
        dot.isHidden = !((hasFailureDot || needsAccess) && symbolName == "waveform")
        if !dot.isHidden {
            button.layoutSubtreeIfNeeded()
            let size = Self.dotSize
            // Top right of the glyph. The status bar button may be flipped.
            let top = button.isFlipped ? 4 : button.bounds.maxY - size - 4
            dot.frame = NSRect(x: button.bounds.maxX - size - 4, y: top, width: size, height: size)
            // Stays at the top right if the button resizes while it shows.
            dot.autoresizingMask = [.minXMargin, button.isFlipped ? .maxYMargin : .minYMargin]
        }
    }

    private func updateTimer() {
        let interval: TimeInterval? = switch dictation.state {
        case .recording: 0.1
        case .transcribing: 0.3
        case .idle, .starting: nil
        }
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        frame = 0
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame += 1
                self.redraw()
            }
        }
        // .common: it keeps ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Five red bars that grow with the input level, like the HUD's meter.
    static func levelBars(_ level: Float) -> NSImage {
        let weights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            for (index, weight) in weights.enumerated() {
                let height = max(3, (CGFloat(max(0, min(1, level))) * rect.height * weight).rounded())
                let bar = NSRect(x: 1 + CGFloat(index) * 3, y: (rect.height - height) / 2, width: 2, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        // Not a template, or the menu bar paints it gray.
        image.isTemplate = false
        return image
    }

    /// Three dots with one lit, in the menu bar's own color.
    static func dots(lit: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            for index in 0..<3 {
                NSColor.black.withAlphaComponent(index == lit ? 1 : 0.3).setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 6, y: rect.midY - 2, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Click

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
            || event?.modifierFlags.contains(.control) == true
        switch dictation.state {
        case .idle where !wantsMenu, .recording where !wantsMenu:
            Task { await dictation.toggle() }
        default:
            // Also while the mic opens or it transcribes: the menu can cancel.
            showMenu()
        }
    }

    private func showMenu() {
        item.menu = menu
        item.button?.performClick(nil)   // returns when the menu closes
        item.menu = dictation.settings.clickToDictate ? nil : menu
    }

    // MARK: Drop

    /// Audio, or an MP4 or QuickTime movie: what both OpenAI and afconvert (the local model) read.
    static func audioFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.audio, .mpeg4Movie, .quickTimeMovie].contains { type.conforms(to: $0) }
    }

    private func droppedFile(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard dictation.state == .idle, let urls, urls.count == 1, let url = urls.first, Self.audioFile(url) else { return nil }
        return url
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFile(sender) == nil ? [] : .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedFile(sender) else { return false }
        Task { _ = try? await dictation.transcribeDropped(url) }
        return true
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        seenFailures = dictation.failures
        dot.isHidden = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        dictation.reloadHistory()
        let combo = hotkeys.combo
        let shortcut = combo.symbols
        let missing = permissions.missing
        if !missing.isEmpty {
            menu.addItem(.sectionHeader(title: "Needed before you dictate"))
            for need in missing {
                let item = action(need.menuTitle) { [permissions] in permissions.fix(need) }
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                item.toolTip = need.why
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: headline))
        switch dictation.state {
        case .idle:
            menu.addItem(action("Start Dictation", key: combo.menuKey, modifiers: combo.menuModifiers) { [dictation] in
                Task { await dictation.toggle() }
            })
            if let retryable = dictation.retryable {
                let title = switch retryable {
                case .recording: "Retry Last Recording"
                case .file(let file): "Retry \(Self.short(file.lastPathComponent, limit: 32))"
                }
                menu.addItem(action(title) { [dictation] in
                    Task { _ = try? await dictation.retry(paste: true) }
                })
            }
        case .starting, .recording:
            if case .recording = dictation.state {
                menu.addItem(action("Stop and Paste", key: combo.menuKey, modifiers: combo.menuModifiers) { [dictation] in
                    Task { _ = try? await dictation.stop(paste: true) }
                })
            }
            menu.addItem(action("Cancel Recording") { [dictation] in Task { await dictation.cancel() } })
        case .transcribing:
            // A long wait (Parakeet's first download): stop waiting; Retry sends it again later.
            menu.addItem(action("Cancel Transcription") { [dictation] in Task { await dictation.cancel() } })
        }
        if hotkeys.isTaken {
            menu.addItem(disabled("\(shortcut) is taken by another app. See Settings"))
        }

        // One click between the two languages the person speaks. Pinning one is
        // faster than detecting it, but speech in the other one comes out translated.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Language"))
        let current = dictation.settings.language
        for code in Self.quickLanguages + (Self.quickLanguages.contains(current) ? [] : [current]) {
            let item = action(SettingsView.languageName(code)) { [dictation] in dictation.settings.language = code }
            item.state = code == current ? .on : .off
            menu.addItem(item)
        }

        let recent = dictation.history.suffix(5).reversed()
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent: click to copy"))
            for entry in recent {
                let item = action(Self.short(entry.text)) { [dictation] in dictation.copy(entry.text) }
                item.toolTip = entry.text
                menu.addItem(item)
            }
        }
        menu.addItem(action("Open History") { [dictation] in
            NSWorkspace.shared.open(dictation.store.historyURL)
        })
        menu.items.last?.isEnabled = FileManager.default.fileExists(atPath: dictation.store.historyURL.path)

        menu.addItem(.separator())
        menu.addItem(action("Settings…", key: ",") { [openSettings] in openSettings() })
        menu.addItem(action("Quit VoiceToText", key: "q") { NSApp.terminate(nil) })
    }

    /// Spanish first: the default the person picked.
    static let quickLanguages = ["es", "en"]

    private var headline: String {
        switch dictation.state {
        case .idle: dictation.lastError.map { "Last try failed: \(Self.short($0))" } ?? "Press \(hotkeys.combo.symbols) to dictate"
        case .starting: "Opening the mic…"
        case .recording: "Recording \(Elapsed.text(dictation.elapsed))"
        case .transcribing: permissions.waiting(for: dictation.settings.model) ?? "Transcribing…"
        }
    }

    static func short(_ text: String, limit: Int = 48) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                        run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
        let action = MenuAction(run)
        item.target = action
        // The target is weak; the item keeps the action alive.
        item.representedObject = action
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}

/// The target of a menu item that runs a closure.
private final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func fire() { run() }
}

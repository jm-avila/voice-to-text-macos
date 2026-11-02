import AppKit
import VoiceToTextKit

/// The menu bar icon and its menu. The icon follows the dictation:
///   waveform        ready
///   mic, dimmed     the mic is opening: don't talk yet
///   mic, red        the mic is live
///   ellipsis        transcribing
final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dictation: Dictation
    private let hotkeys: HotkeyCenter
    private let openSettings: () -> Void
    /// The symbol on screen, for the self-test.
    private(set) var symbolName = ""

    init(dictation: Dictation, hotkeys: HotkeyCenter, openSettings: @escaping () -> Void) {
        self.dictation = dictation
        self.hotkeys = hotkeys
        self.openSettings = openSettings
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        let (name, tip): (String, String) = switch dictation.state {
        case .idle: ("waveform", "VoiceToText: press \(hotkeys.combo.symbols) to dictate")
        case .starting: ("mic", "Opening the mic. Wait to talk")
        case .recording: ("mic.fill", "Recording. Press \(hotkeys.combo.symbols) to stop")
        case .transcribing: ("ellipsis", "Transcribing")
        }
        symbolName = name
        guard let button = item.button else { return }
        var image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
        if case .recording = dictation.state {
            // Red, like a recording light. Not a template, or the menu bar paints it gray.
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.appearsDisabled = dictation.state == .starting
        button.toolTip = tip
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        dictation.reloadHistory()
        let shortcut = hotkeys.combo.symbols
        menu.addItem(.sectionHeader(title: headline))
        switch dictation.state {
        case .idle:
            menu.addItem(action("Start Dictation", key: ".", modifiers: .control) { [dictation] in
                Task { try? await dictation.start() }
            })
            if dictation.canRetry {
                menu.addItem(action("Retry Last Recording") { [dictation] in
                    Task { _ = try? await dictation.retry(paste: true) }
                })
            }
        case .starting, .recording:
            if case .recording = dictation.state {
                menu.addItem(action("Stop and Paste", key: ".", modifiers: .control) { [dictation] in
                    Task { _ = try? await dictation.stop(paste: true) }
                })
            }
            menu.addItem(action("Cancel Recording") { [dictation] in Task { await dictation.cancel() } })
        case .transcribing:
            break
        }
        if hotkeys.isTaken {
            menu.addItem(disabled("\(shortcut) is taken by another app. See Settings"))
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

    private var headline: String {
        switch dictation.state {
        case .idle: dictation.lastError.map { "Last try failed: \(Self.short($0))" } ?? "Press \(hotkeys.combo.symbols) to dictate"
        case .starting: "Opening the mic…"
        case .recording: "Recording \(Elapsed.text(dictation.elapsed))"
        case .transcribing: "Transcribing…"
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

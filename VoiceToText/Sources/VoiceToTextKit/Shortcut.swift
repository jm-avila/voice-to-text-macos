import Foundation

/// The dictation shortcut: a key and modifiers in Carbon terms (what
/// RegisterEventHotKey takes), plus the key as printed, so Settings and the
/// menu can show it without a keyboard layout lookup.
public struct Shortcut: Codable, Equatable, Sendable {
    // Carbon's modifier bits (cmdKey, shiftKey, optionKey, controlKey), here so the Kit needs no Carbon.
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// ⌃. : kVK_ANSI_Period with Control.
    public static let standard = Shortcut(keyCode: 0x2F, modifiers: control, key: ".")

    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
        self.key = key
    }

    /// In Apple's order: ⌃⌥⇧⌘ then the key.
    public var symbols: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    /// Why this can't be the shortcut, or nil when it can. A key with only ⇧
    /// (or nothing) would fire on every capital letter you type.
    public var problem: String? {
        if key.isEmpty { return "That key can't be a shortcut." }
        if modifiers & (Self.control | Self.option | Self.command) == 0 { return "Hold ⌃, ⌥ or ⌘ with the key." }
        return nil
    }
}

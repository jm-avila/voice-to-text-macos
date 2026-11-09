import Foundation

/// The dictation shortcut: a key and modifiers in Carbon terms (what
/// RegisterEventHotKey takes), plus the key as printed, so Settings and the
/// menu can show it without a keyboard layout lookup. Or modifiers alone
/// (⌥⌘), pressed and let go with no key between.
public struct Shortcut: Codable, Equatable, Sendable {
    // Carbon's modifier bits (cmdKey, shiftKey, optionKey, controlKey), here so the Kit needs no Carbon.
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// ⌃. : kVK_ANSI_Period with Control.
    public static let standard = Shortcut(keyCode: 0x2F, modifiers: control, key: ".")
    /// The key code of a shortcut with no key. No real key has it.
    public static let noKey: UInt32 = 0xFFFF

    /// Modifiers alone, like ⌥⌘.
    public static func modifiersOnly(_ modifiers: UInt32) -> Shortcut {
        Shortcut(keyCode: noKey, modifiers: modifiers, key: "")
    }

    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
        self.key = key
    }

    /// Through init, so stray bits in a hand-edited file are dropped too.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                  modifiers: try container.decode(UInt32.self, forKey: .modifiers),
                  key: try container.decode(String.self, forKey: .key))
    }

    public var isModifiersOnly: Bool { keyCode == Self.noKey }

    /// In Apple's order: ⌃⌥⇧⌘ then the key.
    public var symbols: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    /// Why this can't be the shortcut, or nil when it can. It needs ⌃ or ⌥:
    /// with only ⇧ it would fire on every capital letter, and ⌘ alone takes
    /// apps' own shortcuts (⌘W, ⌘Q) away from every app. Modifiers alone
    /// need two, so a lone ⌥ tap doesn't start dictating.
    public var problem: String? {
        if isModifiersOnly {
            if modifiers.nonzeroBitCount < 2 { return "Hold two modifiers, or add a key." }
        } else if key.isEmpty { return "That key can't be a shortcut." }
        if modifiers & (Self.control | Self.option) == 0 { return "Hold ⌃ or ⌥ with the key." }
        return nil
    }
}

/// Watches modifier changes for a modifiers-only shortcut. It fires when the
/// modifiers go back to none after being exactly the shortcut's, with no key,
/// click, or extra modifier in between, so ⌥⌘I and ⌥⌘-click still reach apps.
/// It also says the moment they are first held (`pressed`), so the mic can
/// start opening before the release, and when such a press turns out to be
/// another shortcut (`spoiled`), so it can be dropped.
public struct ModifierTap: Sendable {
    public enum Event: Equatable, Sendable {
        /// Exactly the shortcut's modifiers are held: maybe a tap.
        case pressed
        /// Let go with nothing in between: a tap.
        case released
        /// After `pressed`, a key, click, or extra modifier: not a tap.
        case spoiled
    }

    public let modifiers: UInt32
    private var held: UInt32 = 0
    private var reached = false
    private var spoiled = false

    public init(_ modifiers: UInt32) { self.modifiers = modifiers }

    /// The modifiers now held.
    public mutating func changed(to now: UInt32) -> Event? {
        held = now
        if now == 0 {
            defer { reached = false; spoiled = false }
            return reached && !spoiled ? .released : nil
        }
        if now & ~modifiers != 0 { return spoil() }
        if now == modifiers, !reached, !spoiled {
            reached = true
            return .pressed
        }
        return nil
    }

    /// A key or click. Spoils the tap if modifiers are held.
    public mutating func otherInput() -> Event? {
        held != 0 ? spoil() : nil
    }

    private mutating func spoil() -> Event? {
        defer { spoiled = true }
        return reached && !spoiled ? .spoiled : nil
    }
}

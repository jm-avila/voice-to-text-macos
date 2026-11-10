import Testing
@testable import VoiceToTextKit

@Suite("S-018 A modifiers-only shortcut is a clean tap")
struct ModifierTapTests {
    let optionCommand = Shortcut.option | Shortcut.command

    @Test("Held exactly, then let go: pressed, then released")
    func tap() {
        var tap = ModifierTap(optionCommand)
        #expect(tap.changed(to: Shortcut.option) == nil)
        #expect(tap.changed(to: optionCommand) == .pressed)
        #expect(tap.changed(to: Shortcut.command) == nil)
        #expect(tap.changed(to: 0) == .released)
    }

    @Test("A key or click after the press spoils it once, and the release fires nothing")
    func spoiledByKey() {
        var tap = ModifierTap(optionCommand)
        _ = tap.changed(to: optionCommand)
        #expect(tap.otherInput() == .spoiled)
        #expect(tap.otherInput() == nil)
        #expect(tap.changed(to: 0) == nil)
        // The next tap is clean again.
        #expect(tap.changed(to: optionCommand) == .pressed)
        #expect(tap.changed(to: 0) == .released)
    }

    @Test("An extra modifier spoils it; holding it before the shortcut never presses")
    func extraModifier() {
        var tap = ModifierTap(optionCommand)
        _ = tap.changed(to: optionCommand)
        #expect(tap.changed(to: optionCommand | Shortcut.shift) == .spoiled)
        #expect(tap.changed(to: 0) == nil)
        #expect(tap.changed(to: Shortcut.shift) == nil)
        #expect(tap.changed(to: Shortcut.shift | optionCommand) == nil)
        #expect(tap.changed(to: optionCommand) == nil)
        #expect(tap.changed(to: 0) == nil)
    }

    @Test("A key with no modifiers held is not part of a tap")
    func keyAlone() {
        var tap = ModifierTap(optionCommand)
        #expect(tap.otherInput() == nil)
        #expect(tap.changed(to: optionCommand) == .pressed)
    }
}

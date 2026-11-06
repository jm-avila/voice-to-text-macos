# VoiceToText

A native macOS menu bar app in Swift and SwiftUI: press ⌃. to record, ⌃. again to
transcribe with OpenAI or a local Whisper model and paste at the cursor. It replaces the Hammerspoon + bash
version one folder up (`../SPEC.md`) and shares its files.

## Layout

- `Sources/VoiceToText/` the app.
  - `Dictation.swift` the one state machine (idle, starting, recording, transcribing). Hotkey, menu, and CLI all go through it.
  - `Recorder.swift` the mic (`AudioRecording`), `SystemHooks.swift` hotkey, permissions, ⌘V.
  - `StatusItem.swift` the menu bar icon (level + timer, dots, ✓/✕, failure dot; click to dictate, hide when idle, file drop) and menu, `HUD.swift` the floating pill, `SettingsView.swift` the one Settings window.
  - `App.swift` wires `Services` (live, or `testing()` with the fakes in `Fakes.swift`).
  - `Agent/` the `vtt` CLI, its socket, and the MCP server. Commands live in `Agent/AgentCommands.swift`.
- `Sources/VoiceToTextKit/` logic with no AppKit: transcript cleanup, `history.md` format, the OpenAI request, the local whisper-cli transcriber (`LocalWhisper.swift`), settings. Tests in `Tests/VoiceToTextKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs (ad hoc), installs `~/Applications/VoiceToText.app`, and links `~/.local/bin/vtt`.
- `tools/draw_icon.swift` the icon, drawn in code. `build.sh` turns it into `Resources/AppIcon.icns`.
- `docs/` the brief and the user stories (S-001…S-012).

## Files

- Store: `~/Library/Application Support/voice-to-text/` (the bash tool's folder): `history.md`, `settings.json`, `last-recording.m4a`.
- `history.md` keeps the bash tool's format (`## yyyy-MM-dd HH:mm:ss`, blank line, text). Both tools read and append it.
- The OpenAI key: env `OPENAI_API_KEY`, else Keychain through `/usr/bin/security` (account `agent-secrets`, service `OPENAI_API_KEY`).
- The local model: `models/ggml-large-v3-turbo.bin` and `models/ggml-silero-v5.1.2.bin` in the real store, even with `APP_STORE` (one 1.6 GB copy). `tools/get-model.sh` gets them and whisper.cpp.
- `APP_STORE=<folder>` moves the store. A copy started with it never takes the global shortcut.
- The shortcut: `shortcut` in settings.json (default ⌃.), changed in Settings (`ShortcutRecorder` in `SystemHooks.swift`). `vtt status` shows it. Modifiers alone (⌥⌘, key code `0xFFFF`) fire on release with no key or click between (`ModifierTap`); they use event monitors, so they need Accessibility.

## Build and check

This Mac has Command Line Tools only (no Xcode). See the `mac-app` skill for the fixes.

- Build and install: `./build.sh`. `--open` restarts the app. Fix every warning.
- Unit tests: `tools/test.sh .`
- Self-test with fakes (no mic, no API, no paste): `tools/selftest.sh`. Exit 0 when every check passes. Add a check per story to `SelfTest.swift`.
- End to end against the real API (a few `say` clips): `tools/e2e.sh`. `--mic` also records 3 s from the real mic.
- Agent CLI rules: `APP_STORE=/tmp/VoiceToText-cli.store ~/Repositories/references/bama/skills/code/agent-cli/scripts/check-agent-cli.sh vtt`
- Snapshots: `tools/snap.sh` writes `/tmp/VoiceToText-shots/hud-<state>-light|dark.png`, `menubar-<state>-…png` (drawn from the view: the menu bar window can't be screencaptured) and `settings-light|dark.png`. Open and judge every one after a UI change.
- Grid: `tools/grid-lint.sh && swift tools/check-layout.swift /tmp/VoiceToText-shots/*-layout.json`
- Never test against the real store. Self-test, seed data, and snapshots refuse without `APP_STORE`.

## Design rules

- Minimal UI: a menu bar icon, a HUD pill while dictating, one Settings window. No main window, no Dock icon (`LSUIElement`).
- Apple's controls and system styles. Colors from `UI/Theme.swift` (`Palette`), spacing from `Space` in `UI/Grid.swift` (4 pt grid). No hard-coded colors or sizes in views.
- The HUD never takes focus or clicks: the text must land in the app you were typing in.
- Liquid Glass on the HUD only.

## Git

Commit after each working change, with a message that says what the user can now do.

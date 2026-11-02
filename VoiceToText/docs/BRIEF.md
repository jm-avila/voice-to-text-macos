# VoiceToText

Push-to-talk dictation for one person: press ⌃., speak, press ⌃. again, and the text is typed where the cursor is.

## Replaces
The Hammerspoon + bash + ffmpeg version one folder up (`../SPEC.md`). Same shortcut, same files, no Hammerspoon or ffmpeg.

## Main jobs
1. Dictate into any app with one shortcut, in English or Spanish.
2. Know at a glance whether the mic is opening, live, or transcribing.
3. Get an older transcript back, or retry one that failed.

## Data
- `history.md`: `## yyyy-MM-dd HH:mm:ss`, a blank line, the text. Shared with the bash tool.
- `settings.json`: model, language ("" detects it), sounds.
- `last-recording.m4a`: the last recording, kept for a retry. AAC, mono, 16 kHz, 48 kbps.
- Folder: `~/Library/Application Support/voice-to-text/`. The OpenAI key stays in Keychain.

## Shape
Menu bar only (LSUIElement): a status icon with a menu, a glass HUD at the bottom of the screen while dictating, and one Settings window.
macOS 26 or later. OpenAI `/audio/transcriptions` (`gpt-4o-transcribe` by default). A `vtt` CLI and MCP server for agents.

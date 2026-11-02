# VoiceToText: developer notes

The native Swift app. **Users: see the [main README](../README.md)** for screenshots, requirements, permissions, setup
and troubleshooting. This page covers how it is built and checked.

## Build

```sh
./build.sh            # release build, installs ~/Applications/VoiceToText.app, links ~/.local/bin/vtt
./build.sh --open     # same, then restarts the app
tools/get-model.sh    # local model: whisper.cpp + ggml-large-v3-turbo.bin + ggml-silero-v5.1.2.bin
```

A Swift package (swift-tools 6.2, macOS 26+) built with the Command Line Tools only. Ad hoc signing means every
rebuild resets the Microphone and Accessibility grants.

## Architecture

| Part | File | Role |
|---|---|---|
| State machine | `Sources/VoiceToText/Dictation.swift` | idle → starting → recording → transcribing. Hotkey, menu and CLI all go through it. |
| Microphone | `Recorder.swift` | `AVAudioRecorder` behind `AudioRecording`. "Live" once `currentTime > 0`. |
| Transcription | `Sources/VoiceToTextKit/Transcription.swift`, `LocalWhisper.swift` | `Transcribing` protocol. `RoutingTranscriber` picks `OpenAITranscriber` or `LocalWhisperTranscriber` by model id. |
| Local model | `LocalWhisper.swift` | `afconvert` → 16 kHz WAV, then `whisper-cli --vad`. Drops segments that are only a noise tag; treats `error:` on stderr as a failure (whisper-cli exits 0 on some errors). |
| Paste | `Dictation.swift` (`Paster`), `SystemHooks.swift` | Pasteboard, then a synthetic ⌘V when Accessibility is granted. |
| UI | `StatusItem.swift`, `HUD.swift`, `SettingsView.swift` | Menu bar item, glass pill, Settings window. Colors in `UI/Theme.swift`, spacing in `UI/Grid.swift`. |
| Agent | `Agent/` | `vtt` CLI over a Unix socket, and an MCP server. |
| Wiring | `App.swift` | `Services.live()` or `Services.testing()` with the fakes in `Fakes.swift`. |

Logic without AppKit lives in `VoiceToTextKit` and is unit tested. Each boundary (recorder, transcriber, pasteboard)
is a protocol, so the self-test runs with fakes.

## For agents: `vtt`

```sh
vtt status --json                         # state, settings, key/mic/Accessibility, history count
vtt transcribe ~/Desktop/memo.m4a --json  # any audio file, not saved to history
vtt start && sleep 5 && vtt stop --json   # record from the mic, print the text, save to history
vtt history list --limit 3 --json
vtt settings update --language es --json
vtt mcp                                   # the same commands as an MCP server on stdin/stdout
```

Exit codes: 0 ok, 1 error, 2 usage, 3 not found, 4 app not running. The skill for agents is
`.claude/skills/vtt/SKILL.md`.

## Checks

| Check | Command | Result |
| --- | --- | --- |
| Unit tests | `tools/test.sh .` | 24 tests (transcript cleanup, history format, request, settings, local model) pass |
| Self-test | `tools/selftest.sh` | 51 checks pass, with a fake mic and transcriber |
| End to end | `tools/e2e.sh` | 20 checks pass against the real API and the local model: `say` clips in English and Spanish, silence, CLI, MCP, restart |
| Agent CLI | BAMA's `check-agent-cli.sh` | PASS |
| Snapshots | `tools/snap.sh` | 6 HUD states and Settings, light and dark, judged by eye |
| Grid | `tools/grid-lint.sh`, `tools/check-layout.swift` | PASS |

Not covered by an automated check: the real microphone (`tools/e2e.sh --mic` records 3 s) and the real ⌃. press.

## Review

Two rounds of independent review found 18 issues. All were fixed except one:

| Fixed | Check |
| --- | --- |
| A CLI client that hung up killed the app (SIGPIPE) | e2e |
| A second copy took over the socket; `vtt` alone ran the app in the terminal | e2e |
| A failed history append could replace history.md | self-test |
| History was read only at launch | self-test |
| Retry offered a recording a new start had deleted | self-test |
| A press shorter than 0.3 s was sent to the API | self-test |
| A mic that dropped mid-dictation lost the recording (clock reads 0) | read only |
| Two copies starting at once; start racing a pending cancel; cancel ordering | read only |
| `vtt status` ran `security` on the main thread; 3-letter languages; timeouts; accept() spin; error text | read only |

The local model (PR #5) had two more rounds and 6 findings, all fixed:
- An e2e check that passed on error.
- A regex that deleted spoken parentheses.
- A stale Settings status.
- Unknown languages failing silently.
- A pipe deadlock risk.
- `-nt` merging segments.

Not fixed: ⌘V is sent as the V key position, so on Dvorak it sends another key. Fine for QWERTY and Spanish layouts.

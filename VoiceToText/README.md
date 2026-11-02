# VoiceToText (native app)

The Swift version of voice-to-text: press ⌃., speak, press ⌃. again, and the text is pasted at your cursor.
No Hammerspoon, no ffmpeg. It uses the same history file and the same Keychain key as the bash tool, so both read the
same history.

![Recording](docs/hud-recording.png)

## What you see

| Where | What |
| --- | --- |
| Menu bar | A waveform when ready, a dimmed mic while the mic opens (don't talk yet), a red mic while recording, an ellipsis while transcribing. Click it for Start/Stop, Retry, the last 5 transcripts (click to copy), Open History, and Settings (⌘,). |
| Bottom of the screen | A small glass pill while dictating, showing a level meter and the time, then "Pasted", "Copied", or the error. It never takes focus. |
| Settings | Shortcut, model, language, sounds, Open at Login, and whether the OpenAI key, the microphone, and Accessibility are set up. |

## Install

```sh
cd VoiceToText
./build.sh            # builds, installs ~/Applications/VoiceToText.app, links ~/.local/bin/vtt
open ~/Applications/VoiceToText.app
```

Needs macOS 26 and the Command Line Tools (no Xcode). The key is the bash tool's: Keychain `OPENAI_API_KEY`
(account `agent-secrets`), or `OPENAI_API_KEY` in the environment.

### Switch from the Hammerspoon version

Both want ⌃.. While Hammerspoon holds it, Settings shows "Another app uses ⌃." with Try Again.

1. Remove the `dofile(".../voice-to-text.lua")` line from `~/.hammerspoon/init.lua` and reload Hammerspoon.
2. In VoiceToText Settings, press Try Again (or quit and reopen the app).
3. Grant **Microphone** (asked on the first recording) and **Accessibility** (Settings > Allow) to VoiceToText.

To go back, quit VoiceToText and restore the line. The history file is the same either way.

`build.sh` signs with your Apple Development certificate when there is one. With ad hoc signing, every rebuild resets
the Microphone and Accessibility grants. Without Accessibility, the text is copied and you press ⌘V.

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
| Unit tests | `tools/test.sh .` | 17 tests (transcript cleanup, history format, request, settings) pass |
| Self-test | `tools/selftest.sh` | 51 checks pass, with a fake mic and transcriber |
| End to end | `tools/e2e.sh` | 16 checks pass against the real API: `say` clips in English and Spanish, CLI, MCP, restart |
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

Not fixed: ⌘V is sent as the V key position, so on Dvorak it sends another key. Fine for QWERTY and Spanish layouts.

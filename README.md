# voice-to-text

Press a hotkey, speak, press it again — the transcript is pasted where your cursor is.
macOS only. Uses [Hammerspoon](https://www.hammerspoon.org/) for the hotkey,
`ffmpeg` to record the microphone, and the OpenAI transcription API.

```
ctrl+.  →  Hammerspoon (Lua)  →  voice-to-text (bash)  →  ffmpeg (mic → .m4a)
                                                        →  OpenAI API (audio → text)
        ←  cmd+v at cursor    ←  transcript on stdout   →  history.md
```

## Features

- Toggle hotkey: `ctrl+.` to start, `ctrl+.` again to stop.
- Menu-bar indicator: `● REC` while recording, `…` while transcribing.
- Pastes at the cursor; the transcript also stays on the clipboard.
- Keeps a timestamped history of every transcript.
- Works with any language the model supports (tested in English and Spanish).
- Survives restarts (Hammerspoon launches at login).

## Install

Requirements: macOS, [Homebrew](https://brew.sh), an [OpenAI API key](https://platform.openai.com/api-keys).

```sh
git clone https://github.com/jm-avila/voice-to-text-macos.git
cd voice-to-text-macos
./install.sh
```

`install.sh` is safe to re-run. It:

1. Installs `ffmpeg` and Hammerspoon with Homebrew if missing.
2. Adds `dofile("<repo>/voice-to-text.lua")` to `~/.hammerspoon/init.lua`.
3. Asks for your OpenAI key and stores it in the macOS Keychain as `openai-api-key`.
4. Turns on Hammerspoon's launch at login and reloads its config.

Then grant, in **System Settings → Privacy & Security**:

| Permission | App | Why |
|---|---|---|
| Accessibility | Hammerspoon | To send `cmd+v` (paste) |
| Microphone | Hammerspoon | ffmpeg runs under Hammerspoon; asked on first recording |

<details>
<summary>Manual install</summary>

```sh
brew install ffmpeg
brew install --cask hammerspoon
security add-generic-password -U -a "$USER" -s openai-api-key -w 'sk-...'
echo 'dofile("'"$PWD"'/voice-to-text.lua")' >> ~/.hammerspoon/init.lua
```

Open Hammerspoon → Preferences → enable **Launch Hammerspoon at login**, then **Reload Config**.
</details>

## Usage

| Action | How |
|---|---|
| Start recording | `ctrl+.` |
| Stop, transcribe, paste | `ctrl+.` again |
| Show recent transcripts | `./voice-to-text history` (last 10) or `./voice-to-text history 3` |

The script also works on its own, without Hammerspoon:

```sh
./voice-to-text start               # record in the background
./voice-to-text stop                # stop, transcribe, print text
./voice-to-text toggle              # start if idle, else stop
./voice-to-text status              # "recording" or "idle"
./voice-to-text transcribe file.m4a # transcribe any audio file
./voice-to-text --help
```

## How it works

### 1. Hotkey — `voice-to-text.lua`

Hammerspoon is a macOS automation app scripted in Lua. On start it runs
`~/.hammerspoon/init.lua`, which loads `voice-to-text.lua`. That file:

- Binds the global hotkey: `hs.hotkey.bind({ "ctrl" }, ".", M.toggle)`.
- Tracks state (`idle` → `recording` → `transcribing`); presses while transcribing are ignored.
- Runs the bash script asynchronously with `hs.task`, so the UI never freezes.
- On success: `hs.pasteboard.setContents(text)` then `hs.eventtap.keyStroke({ "cmd" }, "v")`.
- Shows errors with `hs.alert`.

### 2. Recording — `voice-to-text start`

```sh
ffmpeg -f avfoundation -i ":default" -ac 1 -ar 16000 -c:a aac -b:a 48k recording.m4a &
```

- `avfoundation` is macOS's capture framework; `:default` is the current input device.
- Mono, 16 kHz AAC: small uploads (~6 KB/s), plenty for speech.
- ffmpeg runs in the background; its PID is written to `ffmpeg.pid` so a later `stop` can find it.

### 3. Stopping — `voice-to-text stop`

Sends `SIGTERM` to ffmpeg, which finalizes the file and exits. (`SIGINT` is not used:
background jobs started from a non-interactive script ignore it.)

### 4. Transcription

```sh
curl https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $KEY" \
  -F model=gpt-4o-transcribe -F response_format=text -F file=@recording.m4a
```

- The key is read from Keychain (`security find-generic-password -s openai-api-key -w`),
  because Hammerspoon does not load your shell profile. `OPENAI_API_KEY` overrides it.
- The text is collapsed to one line, appended to the history file and printed to stdout.

## Configuration

| Setting | Where | Default |
|---|---|---|
| Hotkey | `M.hotkey` in `voice-to-text.lua` | `ctrl+.` |
| Model | `VTT_MODEL` env | `gpt-4o-transcribe` (also: `gpt-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1`) |
| Microphone | `VTT_MIC` env | `:default` (list devices: `ffmpeg -f avfoundation -list_devices true -i ""`) |
| History file | `VTT_HISTORY` env | `~/Library/Application Support/voice-to-text/history.md` |
| State dir | `VTT_DIR` env | `~/Library/Caches/voice-to-text` |
| API base URL | `OPENAI_BASE_URL` env | `https://api.openai.com/v1` |

Env vars set in your shell don't reach Hammerspoon. To change them for the hotkey,
edit the defaults at the top of `voice-to-text`.

After editing `voice-to-text.lua`, reload: Hammerspoon menu → **Reload Config** (or `hs -c 'hs.reload()'`).

## Where data is stored

| What | Where | Retention |
|---|---|---|
| Audio | `~/Library/Caches/voice-to-text/recording.m4a` | Latest recording only; replaced on the next one |
| Transcripts | `~/Library/Application Support/voice-to-text/history.md` | Kept forever (append-only) |
| Clipboard | macOS pasteboard | Until you copy something else |
| ffmpeg errors | `~/Library/Caches/voice-to-text/ffmpeg.log` | Overwritten each recording |

Audio is uploaded to OpenAI for transcription. See OpenAI's
[API data usage policy](https://openai.com/policies/api-data-usage-policies) for retention.

History format:

```markdown
## 2026-09-27 13:14:48

Hello, this is a test of the voice-to-text tool.
```

## Tests

```sh
bash test.sh          # fake ffmpeg + fake API: state, errors, trimming, history
bash test.sh --live   # also transcribes a `say`-generated clip with the real API
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing happens on `ctrl+.` | Hammerspoon not running, or config not loaded: open it → Reload Config |
| Transcript copied but not pasted | Grant Accessibility to Hammerspoon |
| "empty recording" | Grant Microphone to Hammerspoon; check `~/Library/Caches/voice-to-text/ffmpeg.log` |
| "no API key" | `security add-generic-password -U -a "$USER" -s openai-api-key -w 'sk-...'` |
| "API error 401" | Key invalid or revoked; update it with the command above |
| Stuck in `● REC` after a crash | `./voice-to-text stop`, or delete `~/Library/Caches/voice-to-text/ffmpeg.pid` |
| Hotkey conflicts with an app | Change `M.hotkey` in `voice-to-text.lua` and reload |

## Files

| File | Purpose |
|---|---|
| `voice-to-text` | Bash CLI: record, stop, transcribe, history |
| `voice-to-text.lua` | Hammerspoon hotkey, menu-bar indicator, paste |
| `install.sh` | One-shot setup |
| `test.sh` | Tests |

## License

[MIT](LICENSE)

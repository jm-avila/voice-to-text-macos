---
name: vtt
description: Drive the VoiceToText dictation app on this Mac from the shell with the `vtt` command. Transcribe an audio file (OpenAI or the local Whisper model), record from the microphone and get the text back, read the user's past dictations, or change the model and language. Use when the user asks to transcribe audio, wants to know what they dictated, asks you to listen or take a voice note, or names VoiceToText or vtt.
---

# vtt

`vtt` runs commands in the VoiceToText menu bar app. The HUD and menu bar show what you do, live.
If the app is closed, the command opens it in the background.

## Rules

- Always add `--json` and read the JSON. Exit 0 means ok. Otherwise read `error.code` and `error.message`, and do what
  the message says (exit 2 usage, 3 not found, 4 app not running).
- `transcribe` with an OpenAI model sends the file to OpenAI and costs a little; the local models are free and offline. Use it on files the user pointed you to.
- `start` records the user's microphone. Only start it when the user asks you to listen. Tell them when it is
  live, and always `stop` or `cancel` it.
- History holds what the user said out loud. Quote only what the task needs.
- To try things without real data, put `APP_STORE=/tmp/vtt-test.store` in front of every command. That starts a
  separate test copy that does not take the ⌃. shortcut.

## Main commands

| Command | Does |
| --- | --- |
| `vtt status --json` | state (idle, starting, recording, transcribing), model, language, key/mic/Accessibility, history count, last error |
| `vtt transcribe <file> --json` | `{"text": ...}` for an m4a, mp3, wav, … with the current model and language. Not saved |
| `vtt start --json` | Opens the mic and returns once it is live: speech before that is lost |
| `vtt stop --json` | Stops, transcribes, saves to history: `{"text", "saved", "streamed", "latencyMs"}` (key-up to text; `streamed`: the local model transcribed it while it was spoken). `--paste` also pastes into the front app |
| `vtt cancel --json` | Stops recording and throws the audio away |
| `vtt history list --limit N --json` | Past transcripts, newest first: `{"entries": [{date, text}], "total", "file"}` |
| `vtt settings update [--model M] [--language es\|auto] [--sounds true\|false] --json` | Only the options given change |

Models: `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1` (OpenAI), `whisper-large-v3-turbo-local` (whisper.cpp on this Mac; `localModel` in status says whether it is ready, `localModelLoaded` whether it is loaded and waiting), and `parakeet-ultra-local` (the default and the fastest: ~0.1 s for a file, on the Neural Engine; `parakeetModel` / `parakeetLoaded` in status; the first pick downloads 610 MB). With Whisper pick the language (`es` or `en`): detection is slower, and a fixed language translates speech in the other one. Parakeet detects the language itself and never translates.
Everything else: `vtt help`, and `vtt help <command>` for its options.

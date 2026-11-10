# Stories

Checks: [unit] `tools/test.sh .`, [self] `tools/selftest.sh`, [e2e] `tools/e2e.sh`, [snap] `tools/snap.sh`, [manual] by hand.

### S-001 Dictate into any app
As the user, I press ⌃., speak, press ⌃. again, and the text is pasted at my cursor.
Acceptance:
- [self] The second press transcribes and pastes; the HUD says Pasted, then hides.
- [self] The model and language from Settings go to OpenAI.
- [e2e] A spoken English file comes back as the same sentence from the real API.
- [manual] With the real mic and hotkey, the text lands in the app that was in front.
Status: done (manual check pending)

### S-002 See what it is doing
As the user, I can tell whether the mic is opening, live, or transcribing.
Screens: hud-starting, hud-recording, hud-transcribing
Acceptance:
- [self] Starting: dimmed mic in the menu bar, HUD "Opening the mic… wait". Live: red mic, Tink, level meter and timer. Transcribing: ellipsis, Pop.
- [self] The HUD never takes focus or clicks.
- [snap] Each state in light and dark.
Status: done

### S-003 Presses that make no sense are ignored
Acceptance:
- [self] A press while the mic opens or while transcribing does nothing.
- [self] A recording under 0.3 s is not sent.
Status: done

### S-004 Paste or copy
Acceptance:
- [self] The text stays on the clipboard after the paste.
- [self] Without Accessibility the text is only copied; the HUD says "Copied. Press ⌘V to paste".
- [self] Nothing heard: no paste, no history entry, HUD says so.
Status: done

### S-005 History
Acceptance:
- [self] Every transcript is appended to history.md in the bash tool's format.
- [self] Entries the bash tool appends show in the menu without a restart.
- [self] A history.md that cannot be written is never replaced; the error shows.
- [e2e] `vtt history list` reads a file the bash tool wrote.
- [manual] Recent in the menu copies an older transcript.
Status: done

### S-006 Errors and retry
Acceptance:
- [self] An API error shows in the HUD for 4 s; the recording is kept and Retry sends it again.
- [self] A mic that sends no audio within 10 s shows an error and goes back to ready.
- [self] After a new start, the old recording is no longer offered for retry.
- [snap] hud-error with a long API message.
Status: done

### S-007 Settings
Screens: settings
Acceptance:
- [self] Model, language, and sounds are saved to settings.json and used.
- [e2e] `vtt settings update` refuses an unknown model; Spanish with the mini model works; settings survive a restart.
- [snap] Settings shows every row without scrolling.
- [manual] Open at Login; Microphone and Accessibility buttons open the right panes.
Status: done

### S-008 Agents
Acceptance:
- [self] status, start, stop, toggle, cancel, transcribe, history list, settings update through the router.
- [e2e] The CLI starts a test copy; MCP tools/call works; a client that hangs up does not kill the app; a second copy quits.
- [e2e] BAMA's CLI checker passes.
Status: done

### S-009 Cancel
Acceptance:
- [self] Cancel while recording throws the audio away without transcribing.
- [self] Cancel while the mic opens stops it as soon as it is open.
Status: done

### S-010 Dictate with a local model
As the user, I pick Whisper large-v3-turbo in Settings and dictate with no key and no network.
Acceptance:
- [unit] Picking "Whisper large-v3-turbo (on this Mac)" sends recordings to whisper-cli; every other model goes to OpenAI.
- [unit] Missing whisper.cpp or model files fail with how to fix them.
- [e2e] English and Spanish (detected) come back right; 2 s of silence comes back empty, not "Thank you.".
- [e2e] `vtt status` reports `localModel: ready` after `tools/get-model.sh`.
Status: done

### S-011 Change the shortcut
As the user, I pick my own dictation shortcut in Settings; ⌃. stays the default.
Screens: settings
Acceptance:
- [unit] The default is ⌃.; it is saved in settings.json; a key without ⌃ or ⌥ is refused (⌘W, ⌘Q stay with apps); a bad saved one falls back to ⌃.
- [unit] Modifiers alone (⌥⌘) need two, with ⌃ or ⌥; the tap fires on release, not when a key, click, or extra modifier came while held.
- [self] Two modifiers pressed and let go become the shortcut; one is ignored; a key with them wins.
- [self] Change… records the next press; ⇧ alone is refused and recording goes on; Escape cancels; Reset goes back to ⌃.; closing Settings stops recording; status shows the new one.
- [snap] Settings shows the changed shortcut with Reset, and the recording state with a refused press.
- [manual] The new shortcut starts and stops dictation in another app; one another app owns is refused and the old one stays.
Status: done

### S-012 A menu bar icon that says more
As the user, I glance at the menu bar and see how long I've been talking and whether it worked; I can dictate with a click, hide the icon, or drop a file on it.
Acceptance:
- [self] Recording shows the level and the time (not a mic: macOS already shows an orange one); transcribing shows dots; ✓ after a paste or copy, ✕ after a failure.
- [self] A failure leaves a red dot until the menu opens; a good try clears it.
- [self] Click to dictate and hide when idle are off by default, saved, and set by `vtt settings update`; a hidden icon shows while dictating and after a failure.
- [self] A dropped audio or video file is transcribed, saved, and copied; other files are refused.
- [snap] `menubar-<state>` shots for every state, with the dot.
- [manual] A real click, right-click, ⌥-click and a file drag on the icon.
Status: done

### S-013 Know what's missing before dictating
As the user, I learn at launch that the mic or Accessibility is missing, with a button to allow it, instead of finding out after I talked.
Screens: settings, menu
Acceptance:
- [self] Missing access shows first in the menu with a fix, keeps a dot on the icon, and the shortcut opens Settings instead of recording; the CLI still records; all allowed, no warning.
- [snap] Settings starts with "Needed before you dictate", one row per missing permission with its button.
- [manual] Launch asks for the mic and opens Settings; allowing Accessibility makes ⌥⌘ work without a restart.
Status: done

### S-014 The local model answers fast
As the user, I dictate with the local model and the text lands about half a second after I let go, however long I talked.
Acceptance:
- [unit] whisper-server is started once with the model and the voice detector, on 127.0.0.1:8178; one already answering there is used; each request carries the language and the text before it.
- [unit] Pieces are cut in pauses (≥ 4 s of speech, then ≥ 0.6 s quiet), or at 25 s with no pause; silence is never sent; digital zeros and a noisy room don't hide the pauses.
- [unit] Pieces go out in order while the person talks; a failed piece fails the stream; whole files fall back to whisper-cli when the server is down or fails.
- [self] The local model streams; at key-up only the rest is sent; a failed piece falls back to the whole file; no stream while the server loads or with OpenAI; `vtt stop` reports `latencyMs` and `streamed`.
- [e2e] `tools/latency.sh`: 4–9 s clips ~0.5 s through the server (1.4–1.6 s with whisper-cli and auto language); `--file-mic` a 23 s dictation with pauses 0.55 s streamed (1.76 s before), same text.
- [manual] Dictate 20 s or more with real pauses into another app.
Status: done

### S-015 Spanish or English in one click
As the user, I switch between Spanish and English from the menu bar; the language is fixed, so no time goes on detecting it.
Screens: menu
Acceptance:
- [self] The menu lists Español and English with the current one ticked (and any other language picked in Settings); a click switches and saves it.
- [manual] Pick English, dictate English; pick Español, dictate Spanish.
Status: done

### S-016 Parakeet, the fastest local model
As the user, I pick Parakeet Ultra and my dictation is text about a quarter of a second after I let go, whatever the length, in Spanish or English without switching.
Screens: Settings
Acceptance:
- [unit] Parakeet routes to its transcriber; the language is only a script hint; an empty recording fails without loading the model.
- [unit] With the model downloaded: Spanish and English come back in their own language with Español chosen; switching away mid-transcription still returns that text and frees the model.
- [self] Parakeet sends the whole recording at key-up (no stream), with its model id and language; Settings and the CLI offer it by name.
- [e2e] Spanish, English with Español chosen (not translated), and silence (nothing heard).
- [manual] Pick Parakeet (the first time it downloads 610 MB), dictate 20 s in Spanish, then a sentence in English without switching.
Status: done

### S-017 Parakeet from memory
As the user, my long dictations are text in under 0.2 s too: Parakeet takes the samples the recorder already has instead of waiting for the file.
Screens: none
Acceptance:
- [unit] The sample buffer keeps order across threads; under 0.25 s is nothing heard without loading the model; the real model gives the same text from memory as from the file.
- [self] With Parakeet the recorder's samples are kept, all of them go at key-up in the chosen language, and the file is not read; with samples missing, or a failure, the whole file goes instead.
- [manual] `vtt stop --json` shows `"inMemory": true` and a lower `latencyMs` for a 20 s dictation.
Status: done

### S-018 Talk as soon as I press
As the user, with a modifiers-only shortcut (⌥⌘) my first word is not lost: the mic opens while I hold the keys, and the pill says "Speak now" once it hears me.
Screens: HUD
Acceptance:
- [unit] The tap says `pressed` when exactly the shortcut's modifiers are held, `spoiled` when a key, click or extra modifier follows, `released` only for a clean tap.
- [self] Holding opens the mic with nothing shown; letting go records with no second start; another shortcut closes it silently; held past 3 s it closes; with the mic or paste not allowed nothing opens.
- [snap] The pill shows "Speak now" in red for the first 1.5 s of recording, then the shortcut to stop.
- [manual] Press ⌥⌘ and start talking at once: the first word is in the text. ⌥⌘I in Safari still opens the inspector.
Status: done

### S-019 One state to trust
As the user, the pill and menu never contradict what is happening, I can stop a long wait, and Retry resends what actually failed. As an agent, `vtt status` tells me what I can do now.
Screens: HUD (hud-loading), Settings (settings-failed)
Acceptance:
- [unit] Each local model reports off, loading, ready, or failed with the reason; a canceled dictation leaves Whisper's server loaded; the modifier tap is waiting, pressed, or spoiled.
- [self] `vtt status` lists `actions` for idle, recording and transcribing, and `phase` priming while ⌥⌘ is held; copying a Recent item while recording keeps the recording on the pill; cancel while transcribing stops waiting, drops the late text, and `vtt retry` sends it again; a failed dropped file is what Retry resends; while Parakeet loads the menu says so and offers Cancel; a model that did not load says why in status.
- [snap] The pill says "Loading Parakeet…"; Settings shows "Did not load" with Try Again and the reason in the footer.
- [manual] Pick Whisper: `vtt status` goes loading → ready; pick Parakeet with no network the first time: Settings says Did not load, Try Again loads it.
Status: done

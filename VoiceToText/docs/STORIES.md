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

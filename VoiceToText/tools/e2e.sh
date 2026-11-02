#!/bin/zsh
# End-to-end check of the installed app against the real OpenAI API.
# Starts a test copy (APP_STORE in /tmp, never your history; it does not take
# the ⌃. shortcut), then drives it from outside like an agent would: speaks
# a sentence with `say`, transcribes it through the `vtt` CLI, reads a history
# file written in the bash tool's format, changes settings, calls the MCP
# server, kills and relaunches it.
# Costs a few cents' fraction: two short transcriptions with your OpenAI key.
# Also transcribes with the local model (tools/get-model.sh first).
# Usage: tools/e2e.sh          (after ./build.sh)
#        tools/e2e.sh --mic    also record 3 s from the real microphone
#                              (macOS asks for mic access the first time)
set -uo pipefail
cli=~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText
export APP_STORE=/tmp/VoiceToText-e2e.store
export APP_AGENT_SOCKET=$APP_STORE.sock
work=$(mktemp -d)
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
# Reads one value from a JSON reply. The expressions are fixed strings in this script.
json() { python3 -I -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2], {'d': d}))" "$1" "$2" 2>/dev/null; }
has() { [[ ${(L)1} == *${(L)2}* ]]; }
quit_copy() { local pid=$(lsof -t "$APP_AGENT_SOCKET" 2>/dev/null | head -1); [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; sleep 0.5; }
cleanup() { quit_copy; rm -rf "$work"; }
trap cleanup EXIT
quit_copy; rm -rf "$APP_STORE"

# A history file as the bash tool writes it: the app reads the same file.
mkdir -p "$APP_STORE"
printf '## 2026-11-01 09:30:00\n\nWritten by the bash tool.\n\n' > "$APP_STORE/history.md"

# The CLI starts the test copy in the background (open -g -n --env APP_STORE=...).
st=$("$cli" status --json)
[[ $(json "$st" "d['state']") == idle ]] && pass "the CLI starts a test copy of the app" || fail "the CLI starts a test copy ($st)"
[[ $(json "$st" "d['shortcutRegistered']") == False ]] && pass "the test copy leaves ⌃. alone" || fail "test copy took the shortcut ($st)"
[[ $(json "$st" "d['openAIKey']") == found ]] && pass "the OpenAI key is found in Keychain" || fail "no OpenAI key ($st)"

# S-005 History: the bash tool's file, newest first.
hist=$("$cli" history list --json)
[[ $(json "$hist" "d['total']") == 1 && $(json "$hist" "d['entries'][0]['text']") == "Written by the bash tool." ]] \
  && pass "S-005 history list reads the bash tool's history.md" || fail "S-005 history ($hist)"

# S-008 Transcribe a file through the real API. A relative path works from any folder.
say -o "$work/hello.aiff" "Please send the quarterly report to Maria before Friday."
afconvert -f m4af -d aac "$work/hello.aiff" "$work/hello.m4a"
tr=$(cd "$work" && "$cli" transcribe hello.m4a --json)
text=$(json "$tr" "d['text']")
has "$text" "quarterly report" && has "$text" "friday" && pass "S-008 transcribe sends a file to OpenAI: \"$text\"" || fail "S-008 transcribe ($tr)"
[[ $(json "$("$cli" history list --json)" "d['total']") == 1 ]] && pass "S-008 transcribe of a file is not saved to history" || fail "transcribe saved to history"

"$cli" transcribe "$work/missing.m4a" --json >/dev/null 2>&1; code=$?
[[ $code == 3 ]] && pass "agent: a missing file exits 3" || fail "missing file exit $code"
"$cli" stop --json >/dev/null 2>&1; code=$?
[[ $code == 1 ]] && pass "agent: stop when not recording exits 1" || fail "stop while idle exit $code"

# S-007 Settings: language and model, validated, saved, used.
"$cli" settings update --model gpt-5 --json >/dev/null 2>&1; code=$?
[[ $code == 2 ]] && pass "S-007 an unknown model is refused (exit 2)" || fail "unknown model exit $code"
up=$("$cli" settings update --language es --model gpt-4o-mini-transcribe --json)
[[ $(json "$up" "d['language']") == es ]] && rg -q '"language" *: *"es"' "$APP_STORE/settings.json" \
  && pass "S-007 settings update saves settings.json" || fail "S-007 settings ($up)"
# "Eddy" alone is the German voice: name a Spanish one.
say -v Mónica -o "$work/hola.aiff" "Mañana compramos pan y leche en el mercado."
afconvert -f m4af -d aac "$work/hola.aiff" "$work/hola.m4a"
es=$("$cli" transcribe "$work/hola.m4a" --json)
has "$(json "$es" "d['text']")" "mercado" && pass "S-007 Spanish with the mini model: \"$(json "$es" "d['text']")\"" || fail "S-007 Spanish ($es)"

# S-010 The local model: no key, no network. Needs tools/get-model.sh first.
[[ $(json "$st" "d['localModel']") == ready ]] && pass "S-010 status: the local model is ready" || fail "S-010 local model not ready ($st); run tools/get-model.sh"
"$cli" settings update --model whisper-large-v3-turbo-local --language auto --json >/dev/null
lo=$("$cli" transcribe "$work/hello.m4a" --json)
has "$(json "$lo" "d['text']")" "quarterly report" && pass "S-010 local model, English: \"$(json "$lo" "d['text']")\"" || fail "S-010 local English ($lo)"
lo=$("$cli" transcribe "$work/hola.m4a" --json)
has "$(json "$lo" "d['text']")" "mercado" && pass "S-010 local model, Spanish detected: \"$(json "$lo" "d['text']")\"" || fail "S-010 local Spanish ($lo)"
say -o "$work/quiet.aiff" "[[slnc 2000]]"
afconvert -f m4af -d aac "$work/quiet.aiff" "$work/quiet.m4a"
lo=$("$cli" transcribe "$work/quiet.m4a" --json)
[[ -z $(json "$lo" "d['text']") ]] && pass "S-010 local model hears nothing in silence (no \"Thank you.\")" || fail "S-010 silence ($lo)"
"$cli" settings update --language es --model gpt-4o-mini-transcribe --json >/dev/null

# MCP: one tool call over stdin and stdout.
mcp=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"history_list","arguments":{"limit":1}}}' | "$cli" mcp)
python3 -I -c '
import json, sys
reply = json.loads(sys.argv[1].splitlines()[1])["result"]
assert not reply["isError"]
assert json.loads(reply["content"][0]["text"])["total"] == 1
' "$mcp" 2>/dev/null && pass "mcp: tools/call history_list answers from the running app" || fail "mcp tools/call ($mcp)"

# A client that hangs up before its reply must not kill the app (SIGPIPE).
pid=$(lsof -t "$APP_AGENT_SOCKET" 2>/dev/null | head -1)
python3 -I -c '
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((json.dumps({"command": "transcribe", "args": {"file": sys.argv[2]}}) + "\n").encode()); s.close()
' "$APP_AGENT_SOCKET" "$work/hello.m4a"
sleep 4
[[ $(lsof -t "$APP_AGENT_SOCKET" 2>/dev/null | head -1) == "$pid" ]] && pass "agent: a client that hangs up mid-command leaves the app running" || fail "app died after a client hung up"

# A second copy started from a terminal leaves the running one alone.
second=$("$cli" 2>&1 & sleep 3; kill $! 2>/dev/null)
[[ $second == *"already running"* && $(lsof -t "$APP_AGENT_SOCKET" 2>/dev/null | head -1) == "$pid" ]] \
  && pass "a second copy quits and the first keeps its socket" || fail "second copy ($second)"
~/.local/bin/vtt | rg -q '^vtt: drive the app' && pass "agent: vtt alone prints help, it does not start the app in the terminal" || fail "bare vtt"

# Settings survive a restart.
quit_copy
after=$("$cli" status --json)
[[ $(json "$after" "d['language']") == es && $(json "$after" "d['model']") == gpt-4o-mini-transcribe ]] \
  && pass "S-007 after a kill, the CLI relaunches the app with the same settings" || fail "restart ($after)"

# S-001..S-004 with the real microphone: record, transcribe, save.
if [[ ${1:-} == --mic ]]; then
  "$cli" settings update --language auto --json >/dev/null
  started=$("$cli" start --json)
  if [[ $(json "$started" "d['state']") == recording ]]; then
    say "This is a microphone test."
    sleep 0.5
    stopped=$("$cli" stop --json)
    [[ $(json "$stopped" "d['saved']") == True ]] && pass "S-001 mic: \"$(json "$stopped" "d['text']")\" saved to history" || fail "S-001 mic ($stopped)"
    [[ -s "$APP_STORE/last-recording.m4a" ]] && pass "S-001 the recording is kept for a retry" || fail "no last-recording.m4a"
  else
    fail "S-001 mic did not start ($started)"
  fi
fi

[[ $fails == 0 ]] && { echo "PASS e2e"; exit 0; }
echo "FAIL e2e: $fails checks"; exit 1

#!/usr/bin/env bash
# Tests for voice-to-text with fake ffmpeg and curl (no mic, no network).
# Run: bash test.sh            (add --live to also hit the real OpenAI API)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/voice-to-text"
tmp="$(mktemp -d)"
trap 'pkill -f "$tmp/bin/ffmpeg" 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# Fake ffmpeg: write some bytes to the output file, run until SIGTERM.
cat > "$tmp/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
out="${@: -1}"
trap 'echo audio > "$out"; exit 0' TERM
: > "$out"
while true; do sleep 0.1; done
EOF
# Fake curl: echo body + status from env.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s' "$FAKE_BODY" "${FAKE_CODE:-200}"
EOF
chmod +x "$tmp/bin/"*

HIST="$tmp/history.md"
run() { VTT_DIR="$tmp/state" VTT_HISTORY="$HIST" OPENAI_API_KEY=test "$SCRIPT" "$@"; }
# The script pins PATH; a copy with the fakes first on PATH.
sed "s#^export PATH=.*#export PATH=\"$tmp/bin:/opt/homebrew/bin:/usr/bin:/bin\"#" "$SCRIPT" > "$tmp/vtt"
chmod +x "$tmp/vtt"; SCRIPT="$tmp/vtt"

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; fail=1; fi; }

check "idle at start" "idle" "$(run status)"
run start
check "recording after start" "recording" "$(run status)"
run start 2>/dev/null && code=0 || code=$?
check "double start fails" "1" "$code"

check "stop returns trimmed one-line text" "Hola mundo. Second line" \
  "$(FAKE_BODY=$'  Hola mundo.\nSecond line  \n' run stop)"
check "idle after stop" "idle" "$(run status)"

run stop 2>/dev/null && code=0 || code=$?
check "stop when idle fails" "1" "$code"

run toggle
check "toggle starts" "recording" "$(run status)"
err="$(FAKE_BODY='{"error":"bad key"}' FAKE_CODE=401 run toggle 2>&1 >/dev/null || true)"
check "API error surfaced" 'voice-to-text: API error 401: {"error":"bad key"}' "$err"
check "idle after failed stop" "idle" "$(run status)"

err="$(run transcribe /nonexistent 2>&1 || true)"
check "missing file" "voice-to-text: no audio file: /nonexistent" "$err"

# History: successful stops are appended; failed ones are not.
check "history has 1 entry" "1" "$(grep -c '^## ' "$HIST")"
check "history text" "Hola mundo. Second line" "$(sed -n '3p' "$HIST")"
for t in two three; do run start; FAKE_BODY="entry $t" run stop >/dev/null; done
check "history has 3 entries" "3" "$(grep -c '^## ' "$HIST")"
check "history 2 shows last two" "entry two|entry three" "$(run history 2 | grep -v '^##' | grep . | paste -sd'|' -)"
check "history timestamp format" "1" "$(head -1 "$HIST" | grep -cE '^## [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$')"
run start; FAKE_BODY="   " run stop >/dev/null
check "empty transcript not saved" "3" "$(grep -c '^## ' "$HIST")"
rm "$HIST"
check "history when none" "no history yet: $HIST" "$(run history 2>&1)"

if [ "${1:-}" = "--live" ]; then
  say -o "$tmp/live.aiff" "Hello from the live test."
  ffmpeg -loglevel error -i "$tmp/live.aiff" -ac 1 -ar 16000 -c:a aac "$tmp/live.m4a"
  out="$("$HERE/voice-to-text" transcribe "$tmp/live.m4a")"
  check "live API transcription" "Hello from the live test." "$out"
fi

exit $fail

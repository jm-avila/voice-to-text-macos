#!/usr/bin/env bash
# Install voice-to-text: dependencies, Hammerspoon hook, API key.
#
# Usage:
#   ./install.sh          # install (safe to re-run)
#   ./install.sh --help
#
# Steps:
#   1. brew install ffmpeg + Hammerspoon (if missing)
#   2. add a dofile() line to ~/.hammerspoon/init.lua (once)
#   3. store your OpenAI API key in Keychain as "openai-api-key" (if missing)
#   4. enable Hammerspoon launch at login and reload it

set -euo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
INIT="$HOME/.hammerspoon/init.lua"
LINE="dofile(\"$HERE/voice-to-text.lua\")"

command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh" >&2; exit 1; }
command -v ffmpeg >/dev/null || brew install ffmpeg
[ -d /Applications/Hammerspoon.app ] || brew install --cask hammerspoon

mkdir -p "$(dirname "$INIT")"
touch "$INIT"
grep -qF 'require("hs.ipc")' "$INIT" || printf 'require("hs.ipc") -- enables the `hs` CLI\n' >> "$INIT"
if grep -q 'voice-to-text.lua' "$INIT"; then
  grep -qF "$LINE" "$INIT" || echo "note: $INIT already loads a voice-to-text.lua; left as is"
else
  printf '%s\n' "$LINE" >> "$INIT"
fi
echo "Hammerspoon config: $INIT"

if ! security find-generic-password -s openai-api-key >/dev/null 2>&1; then
  read -rsp "OpenAI API key (sk-...): " key; echo
  [ -n "$key" ] || { echo "no key entered" >&2; exit 1; }
  security add-generic-password -U -a "$USER" -s openai-api-key -w "$key"
  echo "API key stored in Keychain as 'openai-api-key'"
fi

chmod +x "$HERE/voice-to-text"
open -a Hammerspoon
sleep 2
# `hs` can hang while Hammerspoon reloads; cap each call at 5s.
hs_cmd() { perl -e 'alarm 5; exec @ARGV' hs -c "$1" 2>/dev/null; }
if command -v hs >/dev/null && [ "$(hs_cmd 'hs.autoLaunch(true); return "ok"')" = "ok" ]; then
  hs_cmd 'hs.reload()' >/dev/null || true  # reload drops the connection; errors are expected
  echo "Hammerspoon: launch at login on, config reloaded"
else
  echo "Open Hammerspoon > Preferences: enable 'Launch at login', then 'Reload Config'"
fi

cat <<'EOF'

Grant in System Settings > Privacy & Security:
  - Accessibility: Hammerspoon (to paste)
  - Microphone:    Hammerspoon (asked on first recording)

Press ctrl+. to record, ctrl+. again to transcribe and paste.
EOF

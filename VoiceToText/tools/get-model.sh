#!/bin/zsh
# Sets up the local model: whisper.cpp, Whisper large-v3-turbo (1.6 GB),
# and the Silero voice detector (1 MB). Safe to re-run: skips what is there.
#
# Usage: tools/get-model.sh
set -euo pipefail
[[ "${1:-}" == (-h|--help) ]] && { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

dir="$HOME/Library/Application Support/voice-to-text/models"

if ! [[ -x /opt/homebrew/bin/whisper-cli || -x /usr/local/bin/whisper-cli ]]; then
  echo "installing whisper.cpp"
  brew install whisper-cpp
fi

fetch() {  # fetch <file> <url>
  if [[ -f "$dir/$1" ]]; then echo "already downloaded: $1"; return; fi
  mkdir -p "$dir"
  # A .part file, so an interrupted download never looks finished. -C - resumes it.
  curl -fL -C - --progress-bar -o "$dir/$1.part" "$2"
  mv "$dir/$1.part" "$dir/$1"
  echo "downloaded: $1"
}
fetch ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
fetch ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin

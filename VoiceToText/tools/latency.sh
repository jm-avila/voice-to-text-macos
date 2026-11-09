#!/bin/zsh
# How fast the local model answers, in a test copy of the installed app
# (APP_STORE in /tmp: never your history or settings, never the ⌃. shortcut).
#   files  the same `say` clips through whisper-cli (model loaded each time),
#          through the app (model kept loaded by whisper-server), and through
#          Parakeet in the app (kept loaded; downloads 610 MB the first time)
#   --mic  also dictates through the real microphone: `vtt start`, `say` plays
#          a clip through the speakers, `vtt stop` reports key-up to text
#          (latencyMs), for Parakeet and Whisper, and how long `vtt start` took to
#          open the mic. Turn the volume up; macOS asks for mic access once.
#          The laptop's speaker into its own mic is poor audio: pauses barely
#          stand out, so the stream rarely cuts. --file-mic measures streaming.
#   --file-mic  a second test copy whose "microphone" plays a 23 s clip with
#          three pauses in real time (APP_FAKE_MIC): key-up to text when the
#          dictation streamed, against the same clip sent whole.
# Free: everything runs on this Mac. Needs tools/get-model.sh first.
# Usage: tools/latency.sh [--mic] [--file-mic] [--runs N]
#        tools/latency.sh --help
set -uo pipefail
if [[ ${1:-} == -h || ${1:-} == --help ]]; then sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; fi
mic=false; filemic=false; runs=3
while (( $# )); do
  case $1 in
    --mic) mic=true ;;
    --file-mic) filemic=true ;;
    --runs) runs=$2; shift ;;
    *) echo "unknown option: $1 (see --help)"; exit 2 ;;
  esac
  shift
done
cli=~/Applications/VoiceToText.app/Contents/MacOS/VoiceToText
models="$HOME/Library/Application Support/voice-to-text/models"
export APP_STORE=/tmp/VoiceToText-latency.store
export APP_AGENT_SOCKET=$APP_STORE.sock
work=$(mktemp -d)
# Reads one value from a JSON reply. The expressions are fixed strings in this script.
json() { python3 -I -c "import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2], {'d': d}))" "$1" "$2" 2>/dev/null; }
quit_copy() { local pid=$(lsof -t "$APP_AGENT_SOCKET" 2>/dev/null | head -1); [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; sleep 0.5; }
# Milliseconds a command takes.
ms() { local t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'); "$@" >/dev/null 2>&1
       echo $(( $(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000') - t0 )); }
cleanup() { "$cli" settings update --model gpt-4o-transcribe --json >/dev/null 2>&1; quit_copy; rm -rf "$work"; }
trap cleanup EXIT
quit_copy; rm -rf "$APP_STORE"; mkdir -p "$APP_STORE"

typeset -A text=(
  es-short "Hola, esto es una prueba de dictado."
  es-long "Hola, esto es una prueba de dictado para medir cuánto tarda la transcripción local con el modelo turbo de Whisper en este Mac. Después de una pausa sigo hablando un poco más, para que la grabación tenga varias frases."
  en-short "This is a quick dictation test."
)
typeset -A voice=(es-short Mónica es-long Mónica en-short Samantha)
for clip in ${(k)text}; do
  say -v $voice[$clip] -o "$work/$clip.aiff" "$text[$clip]"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$work/$clip.aiff" "$work/$clip.wav"
  afconvert -f m4af -d aac "$work/$clip.aiff" "$work/$clip.m4a"
done

"$cli" settings update --model whisper-large-v3-turbo-local --language es --json >/dev/null
for i in {1..60}; do [[ $(json "$("$cli" status --json)" "d['localModelLoaded']") == True ]] && break; sleep 0.5; done
[[ $(json "$("$cli" status --json)" "d['localModelLoaded']") == True ]] || { echo "FAIL the model did not load"; exit 1; }

printf '%-10s %-16s %8s\n' clip route median_ms
for clip in es-short es-long en-short; do
  lang=${clip%%-*}
  "$cli" settings update --language $lang --json >/dev/null
  for route in whisper-cli-auto whisper-cli server; do
    times=()
    for r in $(seq $runs); do
      case $route in
        whisper-cli-auto) times+=$(ms whisper-cli -m "$models/ggml-large-v3-turbo.bin" --vad -vm "$models/ggml-silero-v5.1.2.bin" -f "$work/$clip.wav" -l auto -np) ;;
        whisper-cli) times+=$(ms whisper-cli -m "$models/ggml-large-v3-turbo.bin" --vad -vm "$models/ggml-silero-v5.1.2.bin" -f "$work/$clip.wav" -l $lang -np) ;;
        server) times+=$(ms "$cli" transcribe "$work/$clip.m4a" --json) ;;
      esac
    done
    printf '%-10s %-16s %8s\n' $clip $route ${${(on)times}[$(( (runs + 1) / 2 ))]}
  done
done
"$cli" settings update --model parakeet-ultra-local --language es --json >/dev/null
for i in {1..600}; do [[ $(json "$("$cli" status --json)" "d['parakeetLoaded']") == True ]] && break; sleep 0.5; done
for clip in es-short es-long en-short; do
  times=()
  for r in $(seq $runs); do times+=$(ms "$cli" transcribe "$work/$clip.m4a" --json); done
  printf '%-10s %-16s %8s  %s\n' $clip parakeet ${${(on)times}[$(( (runs + 1) / 2 ))]} "$(json "$("$cli" transcribe "$work/$clip.m4a" --json)" "d['text'][:60]")"
done
"$cli" settings update --model whisper-large-v3-turbo-local --json >/dev/null
echo "(server and parakeet include the vtt round trip and reading the m4a; parakeet ran with Español chosen)"

if $mic; then
  # Mic open: `vtt start` returns once the mic is live (what you wait for after ⌃.; ⌥⌘ opens it while you hold).
  echo
  printf '%-10s %-10s %8s %10s %9s  %s\n' model clip open_ms key-up_ms inMemory text
  for model in parakeet-ultra-local whisper-large-v3-turbo-local; do
    "$cli" settings update --model $model --json >/dev/null
    for i in {1..60}; do
      [[ $(json "$("$cli" status --json)" "d['parakeetLoaded'] or d['localModelLoaded']") == True ]] && break; sleep 0.5
    done
    for clip in es-short es-long en-short; do
      "$cli" settings update --language ${clip%%-*} --json >/dev/null
      open_ms=$(ms "$cli" start --json)
      [[ $(json "$("$cli" status --json)" "d['state']") == recording ]] || { echo "FAIL mic did not start"; exit 1; }
      say -v $voice[$clip] "$text[$clip]"
      sleep 0.3
      stopped=$("$cli" stop --json)
      printf '%-10s %-10s %8s %10s %9s  %s\n' ${model%%-*} $clip $open_ms "$(json "$stopped" "d.get('latencyMs')")" \
        "$(json "$stopped" "d.get('inMemory')")" "$(json "$stopped" "d['text'][:50]")"
    done
  done
fi

if $filemic; then
  echo
  say -v Mónica -o "$work/pauses.aiff" "Primero quiero revisar el informe de ventas del trimestre y ver qué clientes han crecido más. [[slnc 900]] Después hay que preparar la propuesta para el cliente nuevo, con los precios actualizados y las condiciones de pago. [[slnc 900]] Por último, enviar un resumen al equipo antes del viernes, para que todos sepan qué toca la semana que viene. [[slnc 900]] Y recordad que la reunión del lunes empieza a las diez en punto, no a las once."
  afconvert -f m4af -d aac "$work/pauses.aiff" "$work/pauses.m4a"
  seconds=$(afinfo "$work/pauses.m4a" | awk '/estimated duration/ {print $3}')
  quit_copy; rm -rf "$APP_STORE"; mkdir -p "$APP_STORE"
  export APP_FAKE_MIC="$work/pauses.m4a"
  "$cli" settings update --model whisper-large-v3-turbo-local --language es --json >/dev/null
  for i in {1..60}; do [[ $(json "$("$cli" status --json)" "d['localModelLoaded']") == True ]] && break; sleep 0.5; done
  printf '%-22s %10s  %s\n' route key-up_ms text
  for r in $(seq $runs); do
    "$cli" start --json >/dev/null
    sleep $(( seconds + 0.3 ))
    stopped=$("$cli" stop --json)
    printf '%-22s %10s  %s\n' "streamed=$(json "$stopped" "d.get('streamed')")" "$(json "$stopped" "d.get('latencyMs')")" "$(json "$stopped" "d['text'][:70]")…"
  done
  printf '%-22s %10s\n' "whole file (server)" "$(ms "$cli" transcribe "$work/pauses.m4a" --json)"
  "$cli" settings update --model parakeet-ultra-local --json >/dev/null
  for i in {1..600}; do [[ $(json "$("$cli" status --json)" "d['parakeetLoaded']") == True ]] && break; sleep 0.5; done
  for r in $(seq $runs); do
    "$cli" start --json >/dev/null
    sleep $(( seconds + 0.3 ))
    stopped=$("$cli" stop --json)
    printf '%-22s %10s  %s\n' "parakeet" "$(json "$stopped" "d.get('latencyMs')")" "$(json "$stopped" "d['text'][:70]")…"
  done
  unset APP_FAKE_MIC
fi

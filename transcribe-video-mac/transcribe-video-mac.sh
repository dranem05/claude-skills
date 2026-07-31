#!/usr/bin/env bash
#
# transcribe-video-mac.sh — extract a transcript from a local video (or audio)
# file using whisper.cpp (a C/C++ port of OpenAI's Whisper model). macOS only:
# fast on Apple Silicon via Metal, and it auto-installs deps through Homebrew.
# Writes <video>.txt and <video>.srt next to the source file.
#
# Usage:
#   transcribe-video-mac.sh [--model NAME] [--lang CODE] [--keep-wav] <video-file>
#
# Options:
#   --model NAME   Whisper model to use (default: base.en). Common choices:
#                  tiny.en base.en small.en medium.en  (English-only, faster)
#                  tiny base small medium large-v3      (multilingual)
#   --lang  CODE   Force a language (e.g. en, es, fr). Default: auto-detect
#                  (ignored by .en models, which are English-only).
#   --keep-wav     Also keep the intermediate 16kHz mono WAV, as
#                  <video>.16k.wav next to the source file.
#   -h, --help     Show this help.
#
# One file per call — a second input is refused rather than half-processed. Loop
# in the caller for a batch.
#
# Existing <video>.txt / <video>.srt are REPLACED (each replacement is announced on
# stderr). Nothing is touched unless the transcription succeeds: outputs are written
# to a temp directory first and moved into place only once they exist.
#
# Environment:
#   WHISPER_MODELS_DIR  Where model .bin files are cached
#                       (default: ~/.cache/whisper-cpp).
#
# Dependencies (auto-installed via Homebrew if missing): ffmpeg, whisper-cpp.
# Model files are downloaded on first use from the whisper.cpp HuggingFace repo.

set -euo pipefail

MODEL="base.en"
LANG_CODE=""
KEEP_WAV=0
VIDEO=""

err() { printf 'transcribe-video: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

# Print the leading comment block (skip the shebang, stop at the first blank
# line that follows it) as help text, stripping the leading "# ".
show_help() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="${2:-}"; [[ -n "$MODEL" ]] || die "--model needs a value"; shift 2;;
    --lang)  LANG_CODE="${2:-}"; [[ -n "$LANG_CODE" ]] || die "--lang needs a value"; shift 2;;
    --keep-wav) KEEP_WAV=1; shift;;
    -h|--help) show_help; exit 0;;
    # "--" is the only way to pass a filename that starts with "-", so it gets the
    # same one-input guard as the normal path rather than silently dropping the rest.
    --) shift
        [[ $# -gt 0 ]] || die "-- given with no input file"
        [[ -z "$VIDEO" ]] || die "more than one input file given ('$VIDEO', then '$1') — one file per call; loop for a batch."
        VIDEO="$1"; shift
        [[ $# -eq 0 ]] || die "unexpected arguments after the input file: $* — one file per call; options must precede --."
        break;;
    -*) die "unknown option: $1 (try --help)";;
    # Refuse a second input rather than silently transcribing only one of them.
    *) [[ -z "$VIDEO" ]] || die "more than one input file given ('$VIDEO', then '$1') — one file per call; loop for a batch."
       VIDEO="$1"; shift;;
  esac
done

[[ -n "$VIDEO" ]] || die "no input file given (try --help)"
[[ -f "$VIDEO" ]] || die "file not found: $VIDEO"

# The model name is interpolated into both a local filename and a download URL.
case "$MODEL" in
  */*|*..*) die "invalid model name: '$MODEL' (expected e.g. base.en, small, large-v3)";;
esac

# This skill is macOS-specific: it relies on Homebrew for dependency install and
# is tuned for Apple Silicon (Metal). Bail clearly elsewhere rather than half-run.
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only — this skill uses Homebrew + whisper.cpp (Apple Silicon). Not supported on $(uname -s)."

# --- Resolve dependencies ------------------------------------------------------

ensure_brew_pkg() {
  # $1 = command to look for, $2 = brew formula that provides it
  local cmd="$1" formula="$2"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  command -v brew >/dev/null 2>&1 || die "$cmd not found and Homebrew is unavailable; install $formula manually."
  err "$cmd not found — installing $formula via Homebrew (one-time)…"
  brew install "$formula" >&2 || die "failed to install $formula"
}

ensure_brew_pkg ffmpeg ffmpeg

# whisper.cpp installs its CLI as `whisper-cli` on modern builds; older builds used
# `whisper-cpp`. Older still shipped it as plain `main`, which is deliberately NOT
# probed: `main` is a common name for an unrelated locally-built binary, and finding
# one on PATH would hand it whisper's argv.
WHISPER_BIN="$(command -v whisper-cli || command -v whisper-cpp || true)"
if [[ -z "$WHISPER_BIN" ]]; then
  ensure_brew_pkg whisper-cli whisper-cpp
  WHISPER_BIN="$(command -v whisper-cli || command -v whisper-cpp || true)"
  [[ -n "$WHISPER_BIN" ]] || die "whisper-cpp installed but no CLI binary found on PATH."
fi

# --- Resolve model file --------------------------------------------------------

MODELS_DIR="${WHISPER_MODELS_DIR:-$HOME/.cache/whisper-cpp}"
MODEL_FILE="$MODELS_DIR/ggml-$MODEL.bin"
if [[ ! -f "$MODEL_FILE" ]]; then
  mkdir -p "$MODELS_DIR"
  URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
  err "model '$MODEL' not cached — downloading (one-time) from HuggingFace…"
  err "  $URL"
  # Download to a private temp path then rename, so neither an interrupted download
  # nor a second concurrent run can leave a truncated file that later runs would
  # treat as valid. The name must be unique per process: a shared ".part" lets two
  # first-runs of the same model interleave and commit a corrupt cache entry.
  PART="$(mktemp "$MODELS_DIR/.ggml-$MODEL.part.XXXXXX")"
  if ! curl -L --fail --progress-bar -o "$PART" "$URL"; then
    rm -f "$PART"
    die "could not download model '$MODEL' — check the name (e.g. base.en, small, large-v3)."
  fi
  mv "$PART" "$MODEL_FILE"
fi

# --- Extract audio → 16kHz mono WAV (what whisper.cpp expects) -----------------

TMPDIR_W="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_W"; }
trap cleanup EXIT

WAV="$TMPDIR_W/audio.wav"
err "extracting audio from '$VIDEO'…"
ffmpeg -nostdin -y -i "$VIDEO" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$WAV" >/dev/null 2>&1 \
  || die "ffmpeg failed to extract audio (is this a valid media file?)"

# --- Transcribe ----------------------------------------------------------------

# Output basename = the source path minus its extension, so .txt/.srt land beside the
# input. Strip the extension from the *basename* only: "${VIDEO%.*}" over the whole
# path truncates at the last dot anywhere in it, so an extensionless file under a
# dotted directory (~/host.example.com/videos/recording) would silently write its
# outputs two levels up as host.example.txt.
VIDEO_DIR="$(dirname "$VIDEO")"
VIDEO_BASE="$(basename "$VIDEO")"
case "$VIDEO_BASE" in
  ?*.*) OUT_STEM="${VIDEO_BASE%.*}" ;;  # has an extension → drop the last one
  *)    OUT_STEM="$VIDEO_BASE" ;;       # no extension at all (a bare dotfile included)
esac
OUT_BASE="$VIDEO_DIR/$OUT_STEM"

# An output path can collide with the input itself — ffmpeg sniffs content rather than
# extension, so a media file named "notes.txt" transcribes fine and would then be
# overwritten by its own transcript. Compare by inode, since the same file reached by
# different path spellings is still the same file.
DESTS=("$OUT_BASE.txt" "$OUT_BASE.srt")
[[ "$KEEP_WAV" -eq 1 ]] && DESTS+=("$OUT_BASE.16k.wav")
for f in "${DESTS[@]}"; do
  if [[ -e "$f" ]] && [[ "$f" -ef "$VIDEO" ]]; then
    die "refusing to run: output '$f' is the input file itself — give the source a media extension and retry."
  fi
done

# Write outputs to the temp directory first, then move them into place. whisper.cpp
# exits 0 even when it cannot write its outputs, and an existence check at the final
# destination cannot tell "written by this run" from "left by an earlier one" — so a
# failed run would otherwise hand back a stale transcript as a fresh result. Staging
# also means a failure leaves any existing transcript untouched.
STAGE="$TMPDIR_W/out"
WHISPER_ARGS=(-m "$MODEL_FILE" -f "$WAV" -otxt -osrt -of "$STAGE")
[[ -n "$LANG_CODE" ]] && WHISPER_ARGS+=(-l "$LANG_CODE")

err "transcribing with $(basename "$WHISPER_BIN") (model: $MODEL)…"
"$WHISPER_BIN" "${WHISPER_ARGS[@]}" >&2 || die "whisper transcription failed."

for ext in txt srt; do
  [[ -f "$STAGE.$ext" ]] || die "whisper exited 0 but produced no .$ext — its own error is above (an unsupported --lang value does this)."
done

for ext in txt srt; do
  dest="$OUT_BASE.$ext"
  [[ -e "$dest" ]] && err "replacing existing $dest"
  mv -f "$STAGE.$ext" "$dest" || die "could not write '$dest' — is '$VIDEO_DIR' writable?"
done

if [[ "$KEEP_WAV" -eq 1 ]]; then
  KEPT_WAV="$OUT_BASE.16k.wav"
  [[ -e "$KEPT_WAV" ]] && err "replacing existing $KEPT_WAV"
  mv -f "$WAV" "$KEPT_WAV" || die "could not write '$KEPT_WAV' — is '$VIDEO_DIR' writable?"
fi

echo "$OUT_BASE.txt"
echo "$OUT_BASE.srt"
[[ "$KEEP_WAV" -eq 1 ]] && echo "$OUT_BASE.16k.wav"
err "done."

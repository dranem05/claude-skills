---
name: transcribe-video-mac
description: "macOS only, fastest on Apple Silicon. Extract a text transcript from a LOCAL video or audio file using OpenAI's Whisper model (via whisper.cpp). Runs a bundled script that installs deps through Homebrew, transcribes offline, and writes .txt + .srt next to the source file (one file per call; same-named outputs are replaced). Use when the user has a local media file (mp4, mov, m4a, mp3, wav, etc.) they want transcribed. Not for remote sources — if the session already has tooling that returns a transcript for a URL or a hosted meeting recording, prefer that."
---

# /transcribe-video-mac

Transcribe a **local** video or audio file to text, entirely offline, using
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) — a C/C++ port of OpenAI's
Whisper model. Fast on Apple Silicon via Metal.

> **Platform: macOS only.** The bundled script installs `ffmpeg` and `whisper-cpp`
> through Homebrew and is tuned for Apple Silicon. It refuses to run on non-Darwin
> systems. On an Intel Mac it works but without Metal acceleration (slower).

This is a **script-backed** skill: the transcription is done by
`transcribe-video-mac.sh` in this directory, not by hand.

## Inputs

- `$1`: path to a local media file (`.mp4`, `.mov`, `.mkv`, `.m4a`, `.mp3`, `.wav`, …).
  **One file per call** — a second path is refused, not queued. Loop for a batch.
- Optional `--model NAME`: Whisper model (default `base.en`). Bigger = more
  accurate, slower: `tiny.en` < `base.en` < `small.en` < `medium.en`; drop the
  `.en` suffix for multilingual variants (`small`, `large-v3`, …).
- Optional `--lang CODE`: force a language (e.g. `es`, `fr`); default auto-detect.
  Ignored by `.en` models.
- Optional `--keep-wav`: also keep the intermediate 16 kHz mono WAV, as
  `<video>.16k.wav` next to the source.

## Procedure

1. **Confirm the input path.** Get the absolute path to the media file from the
   user. Verify it exists before running.
2. **Pick a model if the user cares about accuracy vs speed.** Default `base.en`
   is a good balance for English. Suggest `small.en` or `medium.en` for noisy
   audio or important transcripts; `large-v3` for best-quality / non-English.
3. **Warn first if you would replace something.** If `<video>.txt` or `<video>.srt`
   already exists next to the source, say so before running — a hand-corrected `.srt`
   beside a video, or notes in `<name>.txt` beside `<name>.mp3`, are common layouts and
   they will be replaced. (The script announces each replacement on stderr and leaves
   them untouched if the transcription fails, but it does not ask.)
4. **Run the script** via Bash — `transcribe-video-mac.sh` from *this skill's own
   directory*, i.e. the directory containing this SKILL.md, not a path relative to the
   current working directory. When installed per the repo README that is
   `~/.claude/skills/transcribe-video-mac/`; a project-local or plugin install differs.
   Quote the media path (media filenames often have spaces):
   ```bash
   <skill-dir>/transcribe-video-mac.sh "<path-to-file>"
   # e.g. with a larger model:
   <skill-dir>/transcribe-video-mac.sh --model small.en "<path>"
   ```
   - **First run is slow:** it may `brew install ffmpeg whisper-cpp` and download
     the model (~150 MB for `base.en`, up to ~3 GB for `large-v3`). Cached after.
     Long files can take minutes — run it in the background if needed and report
     when done.
   - **stdout is the result contract:** two paths (`.txt`, `.srt`), or three with
     `--keep-wav`. Progress and install/download chatter go to stderr.
   - **A nonzero exit means nothing was written** — report the failure rather than
     the paths. Note that an unsupported `--lang` value (e.g. `es-MX` instead of `es`)
     is a common cause; whisper's own error is on stderr.
5. **Report results.** Give the user the `.txt` and `.srt` paths. `.txt` is the
   plain transcript; `.srt` has timestamps for subtitles/seeking.
6. **Offer follow-ups (don't do automatically):** e.g. summarize the transcript, or
   hand it to whatever note-capture skills the current project provides — a meeting
   note if it's a meeting, a source note if it's a talk or lecture worth keeping.

## Outputs

All written next to the source file, replacing same-named files if present:

- `<video>.txt` — plain transcript.
- `<video>.srt` — timestamped subtitles.
- `<video>.16k.wav` — the intermediate audio, only with `--keep-wav`.

Outputs are staged in a temp directory and moved into place only after they exist, so a
failed run leaves whatever was already there alone. If an output path would *be* the
input file (a media file named `notes.txt`, say), the script refuses rather than
overwrite the source.

## Notes

- **Offline & private.** No audio leaves the machine; only the model file is
  fetched (once) from HuggingFace.
- **Models cache** at `~/.cache/whisper-cpp/` (override with `WHISPER_MODELS_DIR`).
- **Not for remote sources.** This script transcribes a file already on disk. If the
  source is a URL, or a recording held by a meeting-notetaker service, and your session
  has tooling that can fetch a transcript directly, prefer that — it is cheaper than
  downloading the media and re-transcribing it. If it doesn't, download the file and
  point this script at it.
- **Word-level timestamps.** The script emits segment-level `.txt`/`.srt` only. If you
  need per-word timing (e.g. filler-word editing), call `whisper-cli` directly with
  `-oj`/`-ojf` plus `-sow`/`-ml 1`, or `-dtw MODEL` for token-level.

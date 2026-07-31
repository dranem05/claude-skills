# claude-skills

Generically useful [Claude Code](https://claude.com/claude-code) skills. Nothing personal or project-specific lands here — each skill is self-contained and usable on any machine.

## Installing a skill

Clone this repo somewhere stable (local disk, not cloud-synced storage — symlinks into mounted volumes dangle when the volume isn't there), then symlink the skill into your user-global skills directory:

```bash
git clone https://github.com/dranem05/claude-skills.git ~/claude-skills
ln -s ~/claude-skills/airdrop              ~/.claude/skills/airdrop
ln -s ~/claude-skills/gdoc-sync            ~/.claude/skills/gdoc-sync
ln -s ~/claude-skills/transcribe-video-mac ~/.claude/skills/transcribe-video-mac
```

**If a skill directory of that name already exists, remove it first.** `ln -s` against an existing *directory* silently creates a symlink *inside* it (`~/.claude/skills/gdoc-sync/gdoc-sync`) and exits 0 — nothing is installed, and the old copy keeps loading. Check with `ls -l ~/.claude/skills/`: an installed skill shows as `name -> /path/to/repo/name`.

Skills load at session start; the skill is available as a slash command (e.g. `/airdrop`) in every Claude Code session from the next session on. Update with `git pull` — changes take effect at the next session start.

## Skills

### airdrop (macOS)

Send file(s) to a nearby Apple device via AirDrop from the terminal — opens the macOS share window pre-loaded and reports a **verified outcome** (`SENT` / `DISMISSED` / `FAILED` / `TIMEOUT`) programmatically, rather than guessing from the window closing.

The interesting part: macOS's `NSSharingServiceDelegate` is blind to cancel-vs-sent (`didShareItems` fires identically for both), so the helper snapshots a `sharingd` preference key that advances only when a transfer actually starts, and degrades to an honest `CLOSED` verdict when the key is unavailable. Details in `airdrop/SKILL.md`.

Works from any cwd; the only human steps are the ones macOS keeps human by design (picking the receiving device, and the Accept prompt on a different-Apple-ID receiver).

### transcribe-video-mac (macOS)

Transcribe a local video or audio file to `.txt` + `.srt` entirely offline, via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — Metal-accelerated on Apple Silicon. Deps (`ffmpeg`, `whisper-cpp`) install through Homebrew on first run; the model is fetched once and cached. No audio leaves the machine.

The interesting part: `whisper-cli` exits **0** when it writes nothing at all — an unsupported `--lang` value, or an unwritable destination — so a naive wrapper hands back output paths for files it never produced, and on a re-run those paths hold the *previous* run's transcript. This script writes to a temp directory and moves results into place only once they exist, which also means a failed run can't destroy a transcript that was already there. Output paths are derived from the input's *basename*, since stripping the extension off the whole path truncates at any dot in a parent directory name. Details in `transcribe-video-mac/SKILL.md`.

One file per call, and it refuses to run when an output path would be the input file itself — ffmpeg sniffs content rather than extension, so a media file named `notes.txt` transcribes happily and would otherwise be overwritten by its own transcript.

```bash
bash transcribe-video-mac/tests/run            # 21 cases; prints "0 failed"
bash transcribe-video-mac/tests/run --canary   # reverts each fix, asserts the suite goes red
```

The suite synthesizes its own fixtures with ffmpeg, so it needs no sample media, and it refuses to download a model — no cached model is a distinct `CANNOT-RUN` (exit 3) rather than a pass or a silent multi-gigabyte fetch. Every case states the consequence it prevents, and `--canary` reports a "hole" for any reverted fix the tests fail to catch.

### gdoc-sync

Reconcile a single Google Doc with a local markdown working copy — `pull-only`, `push-only`, or a `two-way` merge, with Drive treated as head. Takes an explicit local path plus a Drive doc ID, so it's document-agnostic; a domain-specific caller can resolve its own identifiers and delegate the mechanics here.

The interesting part: the obvious pull path silently loses data. `docs_read_document` drops **every table**, blanks person-chips, and reads only one tab per call — it accepts a `tabId`, but omit it and you silently get just the default tab, so a multi-tab doc comes back quietly incomplete. The skill pulls via `drive_download_file`'s native `files.export` instead, which is faithful on all three counts and returns every tab in one call, and diffs through a normalizer tuned to swallow Google's export cosmetics (heading anchors, backslash escapes, emphasis markers, table separators) so real edits aren't buried in noise. Pushes go through surgical `docs_find_and_replace` calls that verify `occurrencesChanged` per edit. Details in `gdoc-sync/SKILL.md`.

**External dependency — unlike `airdrop`, this skill is not self-sufficient.** It needs an MCP server in your session that can reach Google Docs and Drive, exposing `drive_download_file` (for the pull) and `docs_find_and_replace` (only for pushes). Those exact tool names are a per-server convention rather than a standard, so the skill confirms they exist up front and stops rather than falling back to the lossy path.

Any Google account will do — this is not a Workspace feature. It needs two ordinary OAuth scopes, `auth/documents` and `auth/drive`, both grantable on a consumer `@gmail.com` account. (A custom-domain Workspace account is the fussier case: an admin may have to approve the OAuth client first.) Invocation takes named inputs — `mode` (`pull-only` / `push-only` / `two-way`), `local` (path), `docId` — plus optional `account`, `label`, and `conventions`.

The whole non-MCP engine lives in `gdoc-sync/scripts/gdsync` — a single entry point with subcommands (`init`, `adopt`, `diff`, `swap`, `checkfind`, `cleanup`, `selftest`) and exit codes keyed to action rather than severity: `3` means stop, `4` means ask the user, and `4` is deliberately not `0` so an ambiguous run cannot be skimmed past. `SKILL.md` carries no executable code at all, only judgment and choreography.

That split is a correctness measure, not tidiness. Shell pasted into an agent harness may not run in the language it was written for — under one common harness the interpreter is zsh with `grep` replaced by a shim that ignores the POSIX `[^]]` bracket idiom, so a link-extraction pattern that works in a file silently matches nothing, exits 0, and reports "no changes." Code in a file gets real bash and real `grep`, and can be tested.

```bash
bash gdoc-sync/tests/run            # 42 cases; prints "0 failed"
bash gdoc-sync/tests/run --canary   # mutates the engine, asserts the suite goes red
```

The suite is built to resist passing vacuously: every case must state the consequence it prevents, a guard counts as covered only if some case actually made it *fire*, and `--canary` reports a "hole" for any deliberate mutation the tests fail to catch. Also ships `scripts/strip-base64-images.sh`, usable standalone (`strip-base64-images.sh <file.md | dir>`).

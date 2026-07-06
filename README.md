# claude-skills

Generically useful [Claude Code](https://claude.com/claude-code) skills. Nothing personal or project-specific lands here — each skill is self-contained and usable on any machine.

## Installing a skill

Clone this repo somewhere stable (local disk, not cloud-synced storage — symlinks into mounted volumes dangle when the volume isn't there), then symlink the skill into your user-global skills directory:

```bash
git clone https://github.com/dranem05/claude-skills.git ~/claude-skills
ln -s ~/claude-skills/airdrop ~/.claude/skills/airdrop
```

Skills load at session start; the skill is available as a slash command (e.g. `/airdrop`) in every Claude Code session from the next session on. Update with `git pull` — changes take effect at the next session start.

## Skills

### airdrop (macOS)

Send file(s) to a nearby Apple device via AirDrop from the terminal — opens the macOS share window pre-loaded and reports a **verified outcome** (`SENT` / `DISMISSED` / `FAILED` / `TIMEOUT`) programmatically, rather than guessing from the window closing.

The interesting part: macOS's `NSSharingServiceDelegate` is blind to cancel-vs-sent (`didShareItems` fires identically for both), so the helper snapshots a `sharingd` preference key that advances only when a transfer actually starts, and degrades to an honest `CLOSED` verdict when the key is unavailable. Details in `airdrop/SKILL.md`.

Works from any cwd; the only human steps are the ones macOS keeps human by design (picking the receiving device, and the Accept prompt on a different-Apple-ID receiver).

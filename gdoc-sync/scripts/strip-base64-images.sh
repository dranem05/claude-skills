#!/usr/bin/env bash
# Strip base64-encoded images from markdown files, preserving alt text.
#
# Handles the shapes Google Docs' markdown export actually emits, plus the
# hand-exported variants:
#   ![alt](data:image/png;base64,AAAA)              -> ![alt]()
#   ![alt](<data:image/png;base64,AAAA>)            -> ![alt]()
#   ![alt](data:image/png;name=x.png;base64,AAAA)   -> ![alt]()   (extra params)
#   ![alt](data:image/PNG;BASE64,AAAA)              -> ![alt]()   (token is
#                                                     case-insensitive per RFC 2397)
#   [id]: <data:image/png;base64,AAAA>              -> line deleted
#   [id]: data:image/png;base64,AAAA                -> line deleted
#   [id]: <data:image/png;base64,AAAA               -> line and its wrapped
#   BBBB>                                             continuation deleted
#
# Usage:
#   strip-base64-images.sh path/to/file.md   # a single file
#   strip-base64-images.sh path/to/dir       # every *.md under a directory
#
# Invoke by absolute path (see SKILL.md Phase 1, step 3) — there is no default
# target, so a missing argument is an error rather than a silent no-op.
#
# Scope: only *base64* payloads are touched. Other data: URIs (e.g.
# data:image/svg+xml;utf8,<svg .../>) are left alone, because their payloads can
# contain ')' and matching to a close-paren would corrupt surrounding text.
#
# Writes are atomic: the transform goes to a temp file in the same directory,
# then rename(2) replaces the target, so an interrupted or failing run leaves
# the original intact. Permissions are copied onto the replacement and symlinks
# are resolved to their target. Consequence of rename: hard links to the file
# are broken (the same trade-off `sed -i` makes), and the *directory* must be
# writable — a read-only file inside a writable directory is rewritten, as with
# `sed -i`.

set -uo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <file.md | directory>" >&2
  exit 2
fi

target="$1"
failures=0
stripped=0
untouched=0

# --- the transform -----------------------------------------------------------
# Kept in one place so single-file and directory mode cannot diverge.
read -r -d '' AWK_PROG <<'AWK' || true
BEGIN {
  MT     = "[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+"
  PARAMS = "(;[A-Za-z0-9!#$&^_.+=%-]*)*"
  B64    = ";[Bb][Aa][Ss][Ee]64,"
  INLINE = "\\(<?data:" MT PARAMS B64 "[^)]*>?\\)"
  REFDEF = "^[[:space:]]*\\[.*\\][[:space:]]*:[[:space:]]*<?data:" MT PARAMS B64
  wrapped = 0
}
{
  if (wrapped) {                      # inside a line-wrapped reference payload
    if ($0 ~ />/) wrapped = 0
    next
  }
  if ($0 ~ REFDEF) {                  # whole reference definition goes away
    if ($0 ~ "<data:" && $0 !~ />/) wrapped = 1
    next
  }
  gsub(INLINE, "()")
  print
}
AWK

resolve() {                           # follow symlinks so we rewrite the target
  local p="$1"
  if command -v readlink >/dev/null 2>&1 && readlink -f "$p" >/dev/null 2>&1; then
    readlink -f "$p"
  else
    printf '%s\n' "$p"
  fi
}

strip_file() {
  local f before after tmp dir mode
  f=$(resolve "$1")
  dir=$(dirname "$f")

  if [ ! -r "$f" ]; then
    printf 'FAILED (not readable): %s\n' "$1" >&2
    failures=$((failures + 1)); return 1
  fi
  if [ ! -w "$dir" ]; then
    printf 'FAILED (directory not writable, cannot replace atomically): %s\n' "$1" >&2
    failures=$((failures + 1)); return 1
  fi

  if ! tmp=$(mktemp "$dir/.strip-base64.XXXXXX" 2>/dev/null); then
    printf 'FAILED (cannot create temp file in %s): %s\n' "$dir" "$1" >&2
    failures=$((failures + 1)); return 1
  fi

  before=$(wc -c < "$f")
  if ! awk "$AWK_PROG" "$f" > "$tmp" 2>/dev/null; then
    printf 'FAILED (transform error): %s\n' "$1" >&2
    rm -f "$tmp"; failures=$((failures + 1)); return 1
  fi

  mode=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null || echo 644)
  chmod "$mode" "$tmp" 2>/dev/null || true

  if ! mv -f "$tmp" "$f"; then        # atomic: original survives a failure here
    printf 'FAILED (replace error): %s\n' "$1" >&2
    rm -f "$tmp"; failures=$((failures + 1)); return 1
  fi

  after=$(wc -c < "$f")
  if [ "$before" -eq "$after" ]; then
    untouched=$((untouched + 1))
    printf 'no base64 payload: %s\n' "$f"
  else
    stripped=$((stripped + 1))
    printf 'stripped %s (%d → %d bytes)\n' "$f" "$before" "$after"
  fi
}

if [ -d "$target" ]; then
  list=$(mktemp) || { echo "cannot create temp file" >&2; exit 1; }
  trap 'rm -f "$list"' EXIT
  # -L so symlinked .md files are included. find's status is captured rather
  # than discarded — an unreadable subdirectory must not report success.
  find_rc=0
  find -L "$target" -type f -name '*.md' -print0 > "$list" 2>/dev/null || find_rc=$?
  if [ "$find_rc" -ne 0 ]; then
    printf 'FAILED: could not fully traverse %s (find exit %d) — results are incomplete\n' \
      "$target" "$find_rc" >&2
    failures=$((failures + 1))
  fi
  while IFS= read -r -d '' f; do
    strip_file "$f" || true
  done < "$list"
  printf '%d stripped, %d already clean, %d failed\n' "$stripped" "$untouched" "$failures"
elif [ -f "$target" ] || [ -L "$target" ]; then
  strip_file "$target" || true
else
  echo "Not found: $target" >&2
  exit 1
fi

[ "$failures" -eq 0 ] || exit 1

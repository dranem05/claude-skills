---
name: gdoc-sync
description: Sync a single Google Doc (Drive = head) with a local markdown working copy — pull-only (Drive→Local), push-only (Local→Drive), or two-way merge. Faithful native-export pull (tables + all tabs), export-noise-aware diffing, surgical case-sensitive find_and_replace push. Takes an explicit local path + Drive doc ID, so domain-specific callers can resolve their own conventions and delegate here. Use for any Google Doc that needs to reconcile with a local markdown copy.
---

# gdoc-sync

Generic bidirectional sync between **one** Google Doc (Drive is head — the live collaborative source of truth) and its local markdown working copy (working tree, where AI-assisted edits happen).

This is the **engine**. It knows nothing about any particular document set, product, or naming scheme — it operates on two things: a local file path and a Drive doc ID. Callers that carry domain conventions resolve their specifics and delegate here (see [Adapters](#adapters)).

## Requirements

An MCP server in this session that can reach **Google Docs and Drive** for the account owning the doc, exposing **`drive_download_file`** (required, for the pull) and **`docs_find_and_replace`** (required only for `push-only` / `two-way`). `docs_list_tabs` is not needed by any phase here — the native export returns all tabs in one call — so treat it as optional and unverified (see gotcha 9).

Tool names are usually namespaced per connected account (e.g. `mcp__google_<account>__drive_download_file`), and those exact names are a convention of whichever server you use rather than a standard. Confirm the ones you need exist before starting; if they don't, say so and stop rather than improvising a lossy substitute.

**Any Google account works — none of this is a Google Workspace feature.** The skill needs exactly two OAuth scopes, `auth/documents` and `auth/drive`, both of which a consumer `@gmail.com` account can grant; nothing here touches an admin or directory scope. If anything a Workspace account is the *harder* case, since a custom-domain account may additionally need an administrator to approve the OAuth client (Admin → Security → API controls → App access control). Beware the terminology: "Google Workspace documents" in Drive's API docs and tool descriptions is a **file-type** term for native Docs/Sheets/Slides — the only types `files.export` accepts — and says nothing about account tier.

## Inputs

**Required:**
1. **mode** — `pull-only`, `push-only`, or `two-way`. Ask if not provided. Default `pull-only` unless the caller has clearly made local edits intended for Drive.
2. **local** — path to the local markdown working copy. May be given relative (an adapter often knows only its own project-root-relative path); resolve it to an **absolute** path immediately and verify it exists, since every later phase depends on it and no later phase can recover the caller's cwd.
3. **docId** — Drive doc ID (from the URL `docs.google.com/document/d/<ID>/edit`).

**Optional:**
4. **account** — which connected Google account's tools to use, as a concrete MCP slug or as an indirection an adapter resolves (e.g. a per-operator capability name). Pass this whenever more than one account is connected. **An adapter that knows the answer must pass it** — resolving by asking the user is the fallback for direct invocation, not the mechanism. If it is absent and exactly one account is connected, use that one; if several are and nothing was passed, ask, and say plainly that the caller should be supplying it.
5. **label** — short slug for snapshot and working filenames (default: the basename of `local` without extension).
6. **conventions** — freeform notes from a calling adapter about doc-specific rules to honor during classification (frozen sections, subtab-header duplicates, per-hunk authority). Advisory; surfaced to the user at classify time.

## Modes

| Mode | When | Phases |
| --- | --- | --- |
| **pull-only** | Someone edited Drive; bring it into local. Or you've been away and want the latest before deciding anything. | 1–4, 6 (optional), 7. No MCP writes. Local-only (B) items are noted but stay local. |
| **push-only** | You made local edits; send them to Drive. Still pulls a fresh Drive snapshot first (needed for accurate `find` strings). | 1–3, 5–7. Drive-only (A) items flagged, not pulled. |
| **two-way** | Both sides moved; full reconciliation. | 1–7. |

## THE #1 RULE — pull with the native export, never the serializer

Pull with **`drive_download_file`** (`mimeType: text/markdown`) — Google's **native** `files.export`. It is faithful: real pipe tables, person-chips rendered as text, **and it returns every tab** of a multi-tab doc in one call.

Do **NOT** pull with `docs_read_document`:
- `format=markdown` **drops every table** and blanks person-chips (a lossy MCP-side serializer).
- `format=text` keeps table cell text but drops heading levels + bold.
- it reads **one tab per call**. It accepts a `tabId`, but with none supplied you silently get only the default tab — so a naive call on a multi-tab doc returns a partial document that looks complete. Enumerating tabs via `docs_list_tabs` and looping is strictly more work than the native export, for a worse result.

Verified 2026-07-01 against a real 8-table, multi-tab proposal doc: `docs_read_document` lost all 8 tables and returned only the default tab; `drive_download_file` returned everything. This distinction is the whole reason a naive pull loses data.

## Process

### Phase 1: Pull (all modes)

1. Call `drive_download_file` with `fileId=<docId>`, `mimeType: "text/markdown"`. It returns `{ name, mimeType, path, bytes }`, having written the markdown to a server-chosen cache path.
2. Move it next to the local file — **don't work from the returned path**, which lives in a cache the server prunes after 24h. Write the run's paths to a small env file in the same step:
   ```bash
   LOCAL="$(cd "$(dirname "<local-path>")" && pwd)/$(basename "<local-path>")"
   [ -f "$LOCAL" ] || { echo "FATAL: local file not found: $LOCAL" >&2; exit 1; }
   LABEL="<label>"
   WORK="${TMPDIR:-/tmp}/gdoc-sync-$LABEL"; mkdir -p "$WORK"
   DRIVE="$(dirname "$LOCAL")/$LABEL-drive.md"
   DRIVE2="$(dirname "$LOCAL")/$LABEL-drive2.md"
   mv "<returned-path>" "$DRIVE"

   # printf, not a heredoc: a heredoc terminator must sit at column 0, and this
   # block is indented inside a list — copied as-is, an indented EOF silently
   # swallows every following line instead of ending the heredoc.
   printf 'LOCAL=%q\nLABEL=%q\nWORK=%q\nDRIVE=%q\nDRIVE2=%q\n' \
     "$LOCAL" "$LABEL" "$WORK" "$DRIVE" "$DRIVE2" > "$WORK/env.sh"
   echo "env: $WORK/env.sh"
   ```
   **Shell state does not survive between tool calls.** Variables and functions defined in one Bash invocation are gone by the next — only the working directory persists, and cwd is exactly what must not be relied on. So every later Bash call in this skill must begin by re-establishing state:
   ```bash
   source "<work-dir>/env.sh"          # the path echoed above
   ```
   Phases 2, 6, and 7 also need the helper functions defined in Phase 2; define them in the same call that uses them, or append them to `env.sh` once and source them with it. **Every path in every later phase is derived from `$LOCAL`** — never a bare relative filename, which resolves against whatever cwd the session happens to have.
3. Strip base64 image data, invoking the bundled script by its **absolute path inside this skill's own directory** — the "Base directory for this skill" you're given at invocation — so it resolves from any cwd:
   ```bash
   bash "<skill-base-dir>/scripts/strip-base64-images.sh" "$DRIVE"
   ```
   Substitute `<skill-base-dir>` with the absolute base directory shown for this skill. **Do not** use a cwd-relative path like `./scripts/strip-base64-images.sh`.
4. Sanity-check the size (a doc with images drops from MBs to a couple hundred KB).

Fallback if the MCP fails: ask the user to export manually (File → Download → Markdown), then run the strip.

### Phase 2: Diff with normalization (all modes)

Normalize both files to filter Google-export cosmetics, then diff.

```bash
source "<work-dir>/env.sh"   # re-establish $LOCAL/$DRIVE/$WORK — see Phase 1 step 2

# Filters, in order: {#heading-anchors} · ](url) and mailto tails · residual '['
# · bold markers · heading markers (see note *) · trailing then leading
# whitespace · backslash escapes · table separator rows · blank lines.
normalize() {
  sed -E -e 's/\{#[^}]*\}//g' \
         -e 's/\]\((mailto:)?[^)]*\)//g' \
         -e 's/\[//g' \
         -e 's/\*\*//g' \
         -e 's/^#+[[:space:]]*//' \
         -e 's/[[:space:]]+$//' \
         -e 's/^[[:space:]]+//' -- "$1" \
  | tr -d '\\' \
  | grep -vE '^\|?[[:space:]:|-]+\|?$' \
  | { grep -v '^[[:space:]]*$' || true; }
}

normalize "$LOCAL" > "$WORK/local-n.md"
normalize "$DRIVE" > "$WORK/drive-n.md"
diff "$WORK/local-n.md" "$WORK/drive-n.md" > "$WORK/diff.txt" || true
```

The trailing `|| true` on the final `grep` matters because `grep` exits nonzero when it selects no lines — POSIX behaviour, on GNU and BSD alike — so without it an empty normalize output makes the whole function look like a failure. (The genuinely BSD-only trap is `grep -c` / `-vc` exiting nonzero on a zero *count*; this snippet avoids those.)

**Guard before classifying anything — a bad snapshot here is the worst failure this skill has.** If `$DRIVE` is missing, truncated, or is actually a Google "Request access" interstitial rather than the document, the Drive side under-normalizes, local lines read as one-sided hunks, and Phase 3 classifies them as **"push to Drive"** — which in `push-only`/`two-way` means writing content into a live document from find-strings never read from it. `diff` exits cleanly with structured output, so none of this looks like an error.

A pure existence-and-non-empty check is **not sufficient**: the realistic failures are *partial*, not empty. A truncated export or an access-denied body is non-empty and normalizes non-empty, so it sails through byte-count tests. Run all four tiers:

```bash
# 1. exists and non-empty
for f in "$LOCAL" "$DRIVE" "$WORK/local-n.md" "$WORK/drive-n.md"; do
  [ -s "$f" ] || { echo "FATAL: missing or empty: $f" >&2; exit 1; }
done

# 2. is it the document, or an access interstitial?
if grep -qiE 'request access|you need access|access denied|sign in to continue' "$DRIVE"; then
  echo "FATAL: \$DRIVE looks like an access-denied page, not the document" >&2; exit 1
fi

# 3. plausible size — a partial export is the common failure
L=$(grep -c '' "$WORK/local-n.md" || true); D=$(grep -c '' "$WORK/drive-n.md" || true)
if [ "$D" -lt $(( L * 60 / 100 )) ]; then
  echo "FATAL: Drive side is $D lines vs local $L — looks truncated. Re-pull before continuing." >&2
  exit 1
fi

# 4. lopsidedness — two levels, because no threshold can separate a partial
#    export from a large genuine local-side edit. Hard-stop the clear cases;
#    hand the ambiguous middle to the user instead of guessing.
ONLY_LOCAL=$(grep -c '^<' "$WORK/diff.txt" || true)
PCT=0; [ "$L" -gt 0 ] && PCT=$(( ONLY_LOCAL * 100 / L ))
if [ "$PCT" -ge 15 ] && [ "$PCT" -lt 40 ]; then
  echo "CONFIRM: ${ONLY_LOCAL}/${L} local lines (${PCT}%) appear Drive-absent. Either a large" >&2
  echo "         genuine local edit or a partial export. Show the user the hunk list and get" >&2
  echo "         explicit approval before any Phase 5 write." >&2
fi
if [ "$PCT" -ge 40 ]; then
  echo "FATAL: ${ONLY_LOCAL}/${L} local lines (${PCT}%) appear Drive-absent. Suspect snapshot," >&2
  echo "       not ${ONLY_LOCAL} B-items. Re-pull before continuing." >&2
  exit 1
fi
```

Tier 4 is deliberately a **proportion**, not an "everything is one-sided" test. A truncated export that loses 40 of 41 lines leaves one matching line, and an access-denied body can even produce an A-item — either way an all-or-nothing check cannot fire while the wrong outcome still happens.

**Also diff link targets separately, as anchor→target pairs.** The normalizer deletes `](url)` wholesale to suppress export noise, so a Drive-side **link retarget under unchanged anchor text is invisible** to the main diff — and a changed registration URL, Zoom link, or moved-doc link is among the most ordinary edits a collaborator makes.

```bash
link_pairs() {
  [ -s "$1" ] || { echo "FATAL: link pass got no file: $1" >&2; return 1; }
  grep -oE '\[[^]]*\]\([^)]*\)' -- "$1" || true
}
link_pairs "$LOCAL" > "$WORK/local-links.txt" || exit 1
link_pairs "$DRIVE" > "$WORK/drive-links.txt" || exit 1
diff "$WORK/local-links.txt" "$WORK/drive-links.txt" || true
```

**Keep the anchor with the target, and do not `sort | uniq` them.** Reducing links to a bare multiset of URLs hides the most ordinary correction of all — two links swapped between anchors — because the set of targets is unchanged. Keeping pairs in document order surfaces it. The explicit non-empty check matters too: a `grep` over a missing file otherwise returns empty with exit 0, and an empty-vs-empty diff reports clean.

Treat any difference here as a real hunk to classify in Phase 3, not as noise.

\* Heading markers are stripped so the systematic local-`##` vs export-`# **bold**` offset doesn't drown the diff. **Documented trade-offs — the normalizer hides these by design:** a pure heading-**level** change; a hyperlink retarget (covered by the link pass above); and a table row whose cells are all `-` placeholders (`| - | - |`), which the separator-row filter removes, so an edit to such a row surfaces as an unexplained one-sided addition. If document structure or link integrity is in scope, also eyeball the raw (un-normalized) diff.

Read hunk headers first (`grep -E '^[0-9]' "$WORK/diff.txt"`) for a structural map; locate each hunk's section heading for context before reading content.

### Phase 3: Classify each hunk into A / B / C (all modes)

- **A — Drive-only → merge into local.** Someone edited Drive; local lacks it. Default: pull in.
- **B — Local-only → push to Drive.** AI-assisted local edit not yet on Drive. Default: push.
- **C — cosmetic export noise → ignore.** Person-chips expanding to full names, `*italic*` / `**` emphasis markers, `-` vs `*` bullet glyphs, backslash escapes, mailto wraps, `{#anchor}` tags, `:---` vs `---` separators. These round-trip naturally.

**Needs explicit user decision:** true conflicts (both sides edited the same span), a Drive change that reverses a prior local change, Drive deletions, link-target changes from the link pass, date/label discrepancies with a possible domain reason. Also honor any caller-supplied `conventions` (frozen sections, etc.). **Surface the classification (e.g. `$WORK/merge-plan.md`) before mass-applying.**

If the classification comes out as "every line is a B-item," stop — that is the Phase-2 path-failure signature, not a real result.

### Phase 4: Apply A-items to local (pull-only, two-way)

For each A-item, read the local section around the hunk and apply with `Edit`. For multi-line block swaps, use Python via Bash with regex-anchored replace:

```python
import re, sys

local_path = "<absolute-path-to-local>"   # $LOCAL
drive_path = "<absolute-path-to-drive>"   # $DRIVE
START = "<unique-start>"                  # literal text, not a regex
END   = "<unique-end>"

# encoding= is explicit: open() otherwise follows the locale, and a C/POSIX
# locale raises UnicodeDecodeError on the smart quotes and em dashes that
# every real Google Docs export contains.
with open(local_path, encoding='utf-8') as f: local = f.read()
with open(drive_path, encoding='utf-8') as f: drive = f.read()

# re.escape both anchors. The canonical export heading shape is '# **Bold**',
# and pipe-table rows are full of '|' — interpolated raw, the first raises
# "multiple repeat" and the second becomes an alternation that matches the
# empty string, which then "matches" everywhere.
pat = re.compile(re.escape(START) + '.*?(?=' + re.escape(END) + ')', re.DOTALL)

new_hits = pat.findall(drive)
old_hits = pat.findall(local)
if len(new_hits) != 1:
    sys.exit(f'anchor matches {len(new_hits)} places in DRIVE — refusing; lengthen the anchor')
if len(old_hits) != 1:
    sys.exit(f'anchor matches {len(old_hits)} places in LOCAL — refusing; lengthen the anchor')

with open(local_path, 'w', encoding='utf-8') as f:
    f.write(local.replace(old_hits[0], new_hits[0], 1))
```

**Both occurrence checks are required, and the Drive-side one matters most.** An unbounded `str.replace` rewrites every match, and docs that carry frozen or duplicated sections (a repeated transcript block, duplicated subtab headers, a boilerplate footer) legitimately contain the same text twice. Checking only the local side is worse than useless: the all-tabs native export is precisely the file most likely to hold a *stale frozen copy* of the block you want, and taking Drive's first match silently pulls the stale one into local while the check reports clean. Phase 5 polices over-matching on the push side; this is the same discipline on the pull side, where nothing else would catch it.

### Phase 5: Push B-items to Drive (push-only, two-way)

For each B-item, call `docs_find_and_replace`: `documentId=<docId>`, `find`=Drive's **current** text (unescaped — export backslashes don't exist in the live body), `replace`=local's target, and **`matchCase: true`**.

**Always set `matchCase: true` explicitly.** It defaults to **`false`**, so an unqualified call is a case-insensitive rewrite of a live collaborative document: a find string of `Summary:` also hits `summary:` and `SUMMARY:`. Prevention beats the `occurrencesChanged` check, which can only tell you the damage is already done.

**Track `occurrencesChanged` in every response, and treat all three outcomes as distinct:**
- **`1`** — the only success.
- **`>1`** — you over-matched. Restore immediately and re-find with a longer, more-specific context string.
- **`0`** — the push silently did nothing. This is the normal aftermath of a stale or partial snapshot, so do **not** report the B-item as pushed. Stop, re-pull, and re-derive the find string; if several B-items return `0`, the snapshot is wrong and Phase 2's guards should have caught it.

If your server doesn't return the field at all, say so rather than treating its absence as success — the check is this phase's only backstop, and a silently-absent field makes it pass vacuously.

### Phase 6: Verify

Begin with `source "<work-dir>/env.sh"` and redefine `normalize` / `link_pairs` — see Phase 1 step 2.

- **pull-only:** optional. Re-diff local vs the same snapshot; expect only cosmetic residue.
- **push-only / two-way:** required. Re-export to **`$DRIVE2`** (defined in Phase 1 — an absolute path; never a bare `$LABEL-drive2.md`, which lands wherever cwd happens to be), strip base64, then two diffs: (a) `$DRIVE` vs `$DRIVE2` should show exactly the pushed B-items; (b) `$LOCAL` vs `$DRIVE2` should show only cosmetic residue. Re-run the link-pair pass too.

  **Re-run Phase 2's guard tiers against `$DRIVE2` before believing either diff.** A failed or partial re-export makes verification report clean for the same reason a bad first snapshot fooled classification, and this is the *required* check for the mode that has already written to a live document. Surface any formatting regressions (see gotchas) for manual Drive-UI fix.

### Phase 7: Cleanup (all modes)

- Delete the snapshots and work dir by absolute path — `rm -f "$DRIVE" "$DRIVE2"; rm -rf "$WORK"` — once verification passes (or once the user is satisfied, in pull-only). A bare `$LABEL-drive*.md` glob resolves against cwd, which for an adapter whose local file sits in a subdirectory leaves a multi-MB snapshot behind in a possibly version-controlled directory.
- Emit the report.
- If a caller persists the docId somewhere, remind it to.

### Report format

```
Sync mode: <pull-only | push-only | two-way>
Doc: <label> (<docId>)   Account: <slug used>

Drive → Local pulled: <n> A-items (<labels>)
Local → Drive pushed: <n> B-items (<labels>)
Link-target changes: <n> (<which, resolution>)
Noted divergence (not synced): <n> (<which side, why>)
Formatting regressions to fix in Drive UI: <list | none>
Snapshots deleted: <list>
```

## MCP gotchas

Verified against the Google Docs/Drive MCP schemas available 2026-07. Where a claim is behavioral rather than visible in a schema it is marked — **re-check anything marked *observed* against your own server on a scratch doc before relying on it.** This caveat covers THE #1 RULE and the deferred-enhancement note below as much as this list.

1. **`docs_find_and_replace` defaults to `matchCase: false`.** Schema-confirmed. Always pass `true`. See Phase 5.
2. **`docs_find_and_replace` inherits formatting from the first char of the match** (*observed*). Match starts bold → whole replacement goes bold. Surface for manual un-bold.
3. **Cross-paragraph deletes work** (*observed*) — literal `\n` in the find string spans paragraphs; use to remove a whole bullet (`prev tail + target + next head` → `prev + next`).
4. **Cross-paragraph replace can drop bold on a trailing label** (*observed*). Note and hand to the user.
5. **`docs_replace_with_markdown` replaces the *entire body*** — schema-confirmed (its own description says so), so it is destructive to all existing body content including native tables and chips. Never use it for a partial update. Exactly what survives outside the body is *unverified*: the file title is metadata rather than body content, and anchored comments are more likely orphaned than deleted. Don't rely on either without testing.
6. **Markdown rendering on push is unresolved — test before trusting.** `docs_replace_with_markdown` / `docs_append_markdown` advertise markdown in their own descriptions, but were *observed* inserting **literal** text (`**bold**`, `[link](url)`, `<br>` landing as characters). Servers differ and may have improved. Verify on a scratch doc; until you have, match the doc's existing inline convention and push plain text via `find_and_replace`.
7. **`docs_read_document` is lossy, and reads one tab per call** — see THE #1 RULE. It accepts `tabId`, so it is not tab-blind, but omitting it silently yields only the default tab. Never pull with it.
8. **Tables can't be created via `find_and_replace`** — needs `docs_insert_table_with_data` or a manual paste.
9. **The content-write tools take no `tabId`.** Schema-confirmed for `docs_find_and_replace`, `docs_append_markdown`, and `docs_replace_with_markdown`. (Tab-*metadata* tools do — `docs_rename_tab` requires one.) So content destined for a specific non-default tab must be Pasted-as-Markdown by the human. The native-export **pull** in Phase 1 reads all tabs; only writing into a chosen one is blocked. Whether `docs_add_tab` and `docs_list_tabs` behave usefully on manually-created tabs is *unverified* — check before depending on either.

## Deferred enhancement: markdown-aware (rendering) push

Every push here uses `docs_find_and_replace`, which writes literal text, so formatting-bearing replacements (`<br>` cell line-breaks, embedded `**bold**`, nested bullets, new tables) may not render — see gotcha #6, and test your server first. If it genuinely can't render, the underlying capability is a real Drive **import**: `files.create` / `files.update` with `mimeType: application/vnd.google-apps.document`, which converts markdown to native Docs formatting server-side. An MCP server exposing that (or a markdown→`batchUpdate` translator) is what closes this gap; route formatting-bearing pushes through it when one exists, and keep plain text on `find_and_replace`.

## Quality checks before returning

- [ ] The required MCP tools were confirmed present before starting (see Requirements).
- [ ] All four Phase 2 guard tiers passed — existence, access-interstitial, size plausibility, and the 40% lopsidedness stop — and, for push-only/two-way, again against `$DRIVE2` in Phase 6.
- [ ] The link-pair diff was run on a file confirmed non-empty, and any difference was classified, not ignored.
- [ ] **push-only / two-way:** every push passed `matchCase: true` and showed `occurrencesChanged: 1`; any `>1` was investigated and collateral restored; any `0` was treated as "not pushed" and traced to its snapshot; a missing field was reported rather than assumed fine.
- [ ] **pull-only:** no MCP write tool was called.
- [ ] Any Phase-4 block swap escaped its anchors and confirmed exactly one match on **both** the local and the Drive side.
- [ ] Verification diff shows only cosmetic residue in untouched content.
- [ ] Formatting regressions flagged to the user.
- [ ] Snapshots and `$WORK` deleted by absolute path, only after verification.
- [ ] Any caller that persists the docId was reminded.

## Adapters

A domain-specific caller can wrap this engine instead of reimplementing it. The adapter contract: resolve your own identifier (an event ID, a project name, a ticket) to this skill's required inputs — `mode`, `local`, `docId` — and pass whatever else it knows: `account` (which it usually does know, and should always pass rather than leaving the engine to ask), plus optional `label` and a `conventions` note. The adapter owns *which* doc and *what rules*; this skill owns the sync mechanics. Keeping the adapter's invocation contract stable means its callers never learn that the mechanics moved.

For any one-off Google Doc, invoke `gdoc-sync` directly with an explicit `local` + `docId`.

## Related

- `scripts/strip-base64-images.sh` — required Phase-1 preprocessing. Invoke by absolute path (see Phase 1, step 3). Strips base64 payloads only; leaves other `data:` URIs alone. Skips non-writable files loudly rather than rewriting them, and in directory mode completes the sweep before exiting nonzero.

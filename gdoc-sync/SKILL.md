---
name: gdoc-sync
description: Sync a single Google Doc (Drive = head) with a local markdown working copy — pull-only (Drive→Local), push-only (Local→Drive), or two-way merge. Faithful native-export pull (tables + all tabs), export-noise-aware diffing with snapshot guards, surgical case-sensitive find_and_replace push. Takes an explicit local path + Drive doc ID, so domain-specific callers can resolve their own conventions and delegate here. Use for any Google Doc that needs to reconcile with a local markdown copy.
---

# gdoc-sync

Bidirectional sync between **one** Google Doc (Drive is head — the live collaborative source of truth) and its local markdown working copy.

**All the mechanics live in `scripts/gdsync`.** This document holds only what a script cannot: which MCP call to issue when, how to classify a hunk, and when to stop and ask a human. Do not reimplement the engine inline — see [Why the engine is a script](#why-the-engine-is-a-script), which is a correctness argument, not a style preference.

## Requirements

An MCP server in this session that can reach **Google Docs and Drive** for the account owning the doc, exposing **`drive_download_file`** (required, for the pull) and **`docs_find_and_replace`** (required only for `push-only` / `two-way`). Tool names are usually namespaced per connected account (e.g. `mcp__google_<account>__drive_download_file`) and are a per-server convention, not a standard. Confirm the ones you need exist before starting; if they don't, say so and stop rather than improvising a lossy substitute.

**Any Google account works — none of this is a Google Workspace feature.** It needs two ordinary OAuth scopes, `auth/documents` and `auth/drive`, both grantable on a consumer `@gmail.com` account; no admin or directory scope is involved. A custom-domain Workspace account is if anything the fussier case, since an administrator may have to approve the OAuth client first. Beware the terminology: "Google Workspace documents" in Drive's API docs means native Docs/Sheets/Slides *file types* — the only types `files.export` accepts — and says nothing about account tier.

Also needed: `bash`, `awk`, `sed`, `diff`, `python3`. All present on macOS and Linux.

## Inputs

**Required:** **mode** (`pull-only` | `push-only` | `two-way` — ask if not given; default `pull-only` unless the caller has clearly made local edits meant for Drive) · **local** (path to the working copy; may be relative, the engine resolves and verifies it) · **docId** (from `docs.google.com/document/d/<ID>/edit`).

**Optional:** **account** (which connected Google account's tools to use — an adapter that knows this must pass it; asking the user is the fallback for direct invocation, not the mechanism) · **label** (slug for the run directory; defaults to the local basename) · **conventions** (freeform notes from an adapter about doc-specific rules — frozen sections, duplicated subtab headers, per-hunk authority — surfaced at classify time).

## Modes

| Mode | When | Phases |
| --- | --- | --- |
| **pull-only** | Someone edited Drive; bring it into local. | 1–4, 7 |
| **push-only** | You made local edits; send them to Drive. Still pulls a fresh snapshot first, because the `find` strings must come from Drive's current text. | 1–3, 5–7 |
| **two-way** | Both sides moved. | 1–7 |

## THE #1 RULE — pull with the native export, never the serializer

Pull with **`drive_download_file`** (`mimeType: text/markdown`) — Google's native `files.export`. It is faithful: real pipe tables, person-chips as text, **and every tab of a multi-tab doc in one call**.

Do **not** pull with `docs_read_document`:
- `format=markdown` **drops every table** and blanks person-chips.
- `format=text` keeps cell text but loses heading levels and bold.
- it reads **one tab per call**. It accepts a `tabId`, so it is not tab-blind — but omit that and you silently get only the default tab, so a naive call on a multi-tab doc returns a partial document that looks complete.

Verified 2026-07-01 against a real 8-table, multi-tab doc: `docs_read_document` lost all 8 tables and returned only the default tab; `drive_download_file` returned everything. Note the framing: the native export is the right choice because it is *at least as good on every axis*, so this instruction stands even if a future server fixes the serializer.

## Exit codes — what each one obliges you to do

Every `gdsync` command uses these. They key to **action**, not severity.

| Code | Meaning | Your obligation |
| --- | --- | --- |
| **0** | OK | Proceed. |
| **2** | Usage / run not initialised | Fix the invocation. Never work around it by inlining shell. |
| **3** | **FATAL** | Stop. Do not write to Drive or to the local file. Re-pull or report and halt. |
| **4** | **CONFIRM** | Ambiguous. Show the user the evidence and get explicit approval. **This is not a pass.** |
| **1** | Internal error | A bug in the engine. Report it; don't route around it. |

A `3` or `4` is also written to `<run>/verdict.rc`, so the gate survives losing your context, and `gdsync swap` refuses on its own if the recorded verdict was FATAL.

## Process

Substitute `<skill-base-dir>` with the absolute base directory shown for this skill at invocation. Never a cwd-relative path.

### Phase 1 — Pull

1. Issue the MCP call: `drive_download_file` with `fileId=<docId>`, `mimeType: "text/markdown"`. It returns `{ name, mimeType, path, bytes }`.
2. Hand the returned path to the engine, which moves it out of the server's 24h cache, strips base64 image payloads, and creates the run:

   `bash "<skill-base-dir>/scripts/gdsync" init --local <path> --mode <mode> --label <slug> --doc-id <id> --export <returned-path>`

3. Keep the printed `RUN=…` value. That single token is the only state you carry between phases; every later command re-reads the rest from disk.

If the MCP call fails, ask the user to export manually (File → Download → Markdown) and pass that file as `--export`.

### Phase 2 — Diff and guard

`bash "<skill-base-dir>/scripts/gdsync" diff --run <run>`

Normalizes both sides, diffs them, extracts anchor→target link pairs, and runs the snapshot guards. Read the exit code before reading the diff. On **3**, stop — the snapshot is not the document (missing, truncated, or an access interstitial), and no classification of it is meaningful. On **4**, the run is ambiguous: bring the user the numbers and the hunk list.

The guards are **mode-aware by necessity**: "local has lines the snapshot lacks" is a failure signal in `pull-only` and the *premise* in `push-only`. A mode-blind threshold makes `push-only` unusable — it reports truncation and prescribes a re-pull that can never clear.

**`LINK_CHANGES` is not cosmetic** — with one known exception. The normalizer deletes URLs to suppress export noise, so a Drive-side retarget under unchanged anchor text never appears in the main diff; any non-zero `LINK_CHANGES` is a hunk to classify. The exception, measured live: Google **auto-links bare URLs** in the export, so a plain `https://…` in the local copy comes back as `[https://…](https://…)` and shows up here as an added pair whose anchor equals its target. That shape is export noise. A pair whose anchor differs from its target is real.

### Phase 3 — Classify each hunk (judgment; this is your job, not the engine's)

- **A — Drive-only → merge into local.** Someone edited Drive; local lacks it. Default: pull it in.
- **B — Local-only → push to Drive.** A local edit not yet on Drive. Default: push.
- **C — cosmetic export noise → ignore.** Person-chips expanding to full names, `**` bold markers, backslash escapes, mailto wraps, `{#anchor}` tags, `:---` vs `---` separators, `> ` blockquote markers wrapped around ordinary paragraphs, and bare URLs auto-linked into `[url](url)` pairs. The normalizer removes all but the last, so they should not reach you as hunks; if one does, treat it as a real change.

**Needs an explicit user decision, never a default:** true conflicts (both sides edited the same span) · a Drive change that reverses a prior local change · Drive deletions · anything from `LINK_CHANGES` · date or label discrepancies with a possible domain reason · anything the caller's `conventions` marks as pinned or authoritative.

**Do not infer a hunk's direction from the document's overall recency.** This is the error that matters most here, and it has been made: a local copy carrying several obviously newer facts was treated as newer *everywhere*, and a Drive-side correction of a date was pushed back to the stale value. Each side can be authoritative on different facts at the same time — that is the normal shape of a two-way merge, not an anomaly. Classify per hunk, on the merits, and ask.

Two cheap tells worth using while classifying: an **internally inconsistent** line is usually the stale one (a date given as "Thursday 2026-03-06" where that date is a Friday), and a `# <tab name>` line (gotcha 11) is structure that has no local counterpart and should never be pulled.

Surface the classification before applying anything in bulk.

### Phase 4 — Apply A-items to local (`pull-only`, `two-way`)

Small edits: use `Edit` directly. Whole-block swaps from Drive:

`bash "<skill-base-dir>/scripts/gdsync" swap --run <run> --start '<literal text>' --end '<literal text>'`

Anchors are literal text, not regexes. Exit **4** means an anchor is not unique on one side — lengthen it, don't force it. That check matters most on the Drive side: the all-tabs export is exactly the file likely to hold a *stale duplicate* of the block you want, and taking the first match would pull the stale one in silently.

### Phase 5 — Push B-items to Drive (`push-only`, `two-way`)

For each B-item, **pre-flight the find string before writing**:

`bash "<skill-base-dir>/scripts/gdsync" checkfind --run <run> --find '<drive current text>'`

**3** = the string is not in the snapshot (stale snapshot or wrong text — do not push, re-pull). **4** = it occurs more than once and a push would over-match — lengthen it. **0** = exactly one occurrence; proceed.

**Never build a find string out of a table row.** The export renders a native table as `| a | b |`, but the live document has cells and contains no `|` there — so a piped row pre-flights as unique and then pushes `occurrencesChanged: 0`, silently. Measured live. Target the text of a *single cell* (`Thu 2026-03-05`), which is real text. `checkfind` now refuses this shape (`TRIP: find-spans-table-cells`), but the check is narrow by necessity: a pipe can be genuine body text, so it only fires when the matched line is itself a table row.

**`checkfind` counts occurrences in the snapshot, not in the live document, and that difference has teeth.** If the export dropped a tab whose content duplicates a retained section — an appendix that repeats an earlier section, or a repeated subtab header, is exactly this shape — then a string that is unique *in the snapshot* is not unique *live*, `checkfind` returns `0`, and the push over-matches. `docs_list_tabs` cannot help: verified 2026-07-28, it reports a single `"default"` tab for a document whose export carries many. So:

- Never wave through a Phase-2 `CONFIRM` on a document known to duplicate content by convention. That guard is the only signal that a tab may be missing; case `085` pins the fact that `checkfind` passes this case while the guard flags it.
- **When an entire section or tab is duplicated, "lengthen the anchor" does not work.** If two copies are byte-identical, no string inside them can be made unique by extending it — verified live on a doc with a tab that duplicates a section of the main tab. The options are to include context from *outside* the duplicated region, or to resolve the duplication first. Saying "lengthen it" in that situation sends the caller in circles.
- Prefer a find string long enough to include surrounding unique context, rather than the shortest string that happens to be unique in the snapshot.
- Read `occurrencesChanged` as the ground truth it is: a `>1` here means this happened, and the fix is to restore immediately.

Then issue `docs_find_and_replace` with `documentId=<docId>`, `find` = Drive's **current** text (unescaped — export backslashes don't exist in the live body), `replace` = your target, and **`matchCase: true`**.

Per-hunk `find_and_replace` is the default because most pushes are a few targeted edits, and surgical writes stay recoverable. It is not the only option: when the user wants the document replaced wholesale from local, or the doc is a generated artifact, `docs_replace_with_markdown` is the right call — see gotcha 5 for what it discards, and confirm that intent explicitly first, because it cannot be undone from here.

**Always pass `matchCase: true` explicitly, because you want a case-sensitive rewrite** — not because of any particular server default. Stating it as an intent rather than a workaround keeps the instruction correct regardless of what the default is.

Read `occurrencesChanged` on every response and treat three outcomes as distinct: **1** is the only success · **>1** means you over-matched, so restore immediately and re-find with more context · **0** means the push silently did nothing, so do *not* report it as pushed. The field is present on the server this was verified against (2026-07-28: `{"success": true, "occurrencesChanged": 1}`). If yours omits it, say so rather than assuming success — it is the only post-write backstop, and a silently-absent field makes the check pass vacuously.

### Phase 6 — Verify (required for `push-only` / `two-way`)

Re-export via `drive_download_file`, then:

`bash "<skill-base-dir>/scripts/gdsync" adopt --run <run> --from <returned-path> --as drive2`
`bash "<skill-base-dir>/scripts/gdsync" diff --run <run> --side drive2`

Same guards, same code path — no restatement, which is where verification used to drift. Expect the local-vs-drive2 delta to be exactly the B-items you pushed and nothing else. Anything extra is either a formatting regression (see gotchas) or a push that hit more than you intended.

### Phase 7 — Cleanup and report

`bash "<skill-base-dir>/scripts/gdsync" cleanup --run <run>`

Report format:

```
Sync mode: <mode>      Doc: <label> (<docId>)      Account: <slug used>
Verdict: <OK | CONFIRM (approved by user) | FATAL>
Drive → Local pulled: <n> A-items (<labels>)
Local → Drive pushed: <n> B-items (<labels>)
Link-target changes: <n> (<which, resolution>)
Noted divergence (not synced): <n> (<which side, why>)
Formatting regressions to fix in Drive UI: <list | none>
```

## MCP gotchas

Checked against live schemas 2026-07. **Schema-confirmed** means visible in the tool's parameters today; ***observed*** means someone saw the behaviour once and nothing rechecks it — verify those on a scratch doc before relying on them. Where possible the procedure above is written so that being wrong about one of these changes nothing.

1. **`docs_find_and_replace` takes `matchCase`** (schema-confirmed). Phase 5 always passes `true`, so its default doesn't matter.
2. **It inherits formatting from the first character of the match** (*observed*). Match starts bold → the whole replacement goes bold. Surface for manual un-bold.
3. **Cross-paragraph deletes work** (*observed*) — a literal `\n` in the find string spans paragraphs.
4. **Cross-paragraph replace can drop bold on a trailing label** (*observed*).
5. **`docs_replace_with_markdown` does NOT render markdown, and does NOT replace the whole document.** Both halves measured live on a three-tab doc, 2026-07-28:
   - **Content lands as literal, escaped characters.** A payload of headings, bold, italic, a link, bullets, a numbered list, a blockquote, inline code and a table came back as `\#`, `\*\*bold\*\*`, `\[link\](url)`, `\-`, `1\.`, `\>`, `` \` `` — every construct a character. Its own description says "markdown content"; that description is wrong.
   - **It replaces only the DEFAULT TAB.** On a three-tab doc it wiped the default tab and left the other two untouched — 660 lines in, 160 surviving. So on any multi-tab doc it produces a half-replaced document.
   - **Native tables in the replaced tab are destroyed**, converted to literal pipe text that is no longer a table.

   So it is not a whole-document tool and not a markdown tool. Use it only when you want *literal text* in the default tab and have said so. It remains legitimate for that; what it cannot do is the job its name implies.
6. **`docs_append_markdown` is unverified** and shares gotcha 5's description problem, so assume it also inserts literal text until tested. Push formatting-bearing content via `find_and_replace` against text that already carries the formatting you want.
7. **`docs_read_document` is lossy and reads one tab per call** — see THE #1 RULE.
8. **Tables can't be created via `find_and_replace`** — needs `docs_insert_table_with_data` or a manual paste.
9. **The content-write tools take no `tabId`** (schema-confirmed for `find_and_replace`, `append_markdown`, `replace_with_markdown`; tab-*metadata* tools like `docs_rename_tab` do take one). So content destined for a specific non-default tab must be pasted by a human. The Phase-1 pull reads all tabs; only writing into a chosen one is blocked.
10. **`docs_list_tabs` is blind to real tabs** — confirmed, not merely unverified. On a document with three tabs it returned a single entry, `{"tabId": "default", "title": "<document name>"}`. So it cannot be used to enumerate tabs, and no tab-count completeness check is available.
11. **The export marks each tab with a `# <tab name>` line.** Those lines are *structure*, not content, and a local single-file copy has no counterpart for them — so they will always surface as Drive-only additions. Recognise them and do not "pull" them. They also explain apparent duplication: a tab whose name matches a section heading inside it exports as two consecutive identical `#` lines.

## Keep the local copy on asterisk emphasis

Google's export always emits `*italic*`. A local copy written with `_italic_` makes every emphasised line a false hunk: measured on a real 536-line document, converting the local side cut the diff from **55 hunks to 22**. The engine deliberately does *not* normalise this, because stripping `_…_` pairs corrupts query strings — `utm_source=news&utm_medium=` becomes `utmsource=news&utmmedium=`. It is a content convention to hold, not something the tool can fix for you.

## Normalizer blind spots

Three things the filter chain hides **by design**, each pinned by a test so a future edit can't change them silently: a pure heading-**level** change · a hyperlink retarget under unchanged anchor text (which is why `LINK_CHANGES` exists) · a table row whose cells are all `-` placeholders. Full notes in the header comment of `scripts/gdsync`. If document structure or link integrity is in scope, also read the raw un-normalized diff.

## This skill is a workaround layer — delete parts of it as the MCP improves

Most of what is above exists because the Google Docs MCP tools cannot yet do something directly. When a server gains the missing capability, the corresponding workaround should be **removed**, not kept around for safety. The map, so a future reader knows what to delete:

| If the server gains… | Then delete… |
| --- | --- |
| A faithful markdown *render* on push (a real Drive import, or markdown→`batchUpdate`) | Gotchas 5 and 6, and Phase 5's plain-text-only constraint |
| `tabId` on the content-write tools | Gotcha 9 and the "a human must paste it" limitation |
| A working `docs_list_tabs` | Gotchas 10 and 11, and the untestable partial-export gap (case `085`) |
| Table-cell addressing on writes | `checkfind`'s table-row refusal and Phase 5's cell-targeting rule |
| An occurrence count *before* writing | Most of `checkfind` |
| A fixed, non-lossy `docs_read_document` | Nothing — the native export is still at least as good, so THE #1 RULE stands on its own |

## Why the engine is a script

Snippets pasted into the harness do not run in the language they were written for. The Bash tool executes **zsh**, with `grep` replaced by a shell-function shim that does not honour the POSIX `[^]]` bracket idiom — so a link-extraction pattern that works correctly in a file matches *nothing* when pasted, exits 0, and reports "no link changes." Scripts invoked as `bash <path>` get real bash and real `grep`.

Two further reasons: harness tool calls do not persist shell state, so multi-phase inline shell must re-establish everything from disk on every call and silently misbehaves when it doesn't; and code in a markdown fence cannot be executed by a test, which is how a normalizer once shipped as invalid bash while labelled "validated."

## Quality checks before returning

- [ ] The required MCP tools were confirmed present before starting.
- [ ] Every `gdsync` exit code was acted on per the table — no `3` or `4` treated as a pass.
- [ ] Any `4` was taken to the user with evidence and approved explicitly before proceeding.
- [ ] `LINK_CHANGES` was non-zero → each pair change was classified, not ignored.
- [ ] **push-only / two-way:** every push was pre-flighted with `checkfind`, passed `matchCase: true`, and showed `occurrencesChanged: 1`; any `0` was reported as *not pushed*.
- [ ] **push-only / two-way:** Phase 6 verification ran and its delta was exactly the pushed B-items.
- [ ] **pull-only:** no MCP write tool was called.
- [ ] Cleanup ran; the report quotes the verdict verbatim.
- [ ] **If you edited anything under `scripts/`:** `bash "<skill-base-dir>/tests/run"` printed `0 failed`, `bash "<skill-base-dir>/tests/run" --canary` printed `baseline green` and `0 hole(s)`, and you pasted both lines.

## Adapters

A domain-specific caller wraps this engine rather than reimplementing it: resolve your own identifier (an event ID, a client, a ticket) to `mode` + `local` + `docId`, pass `account` (which you usually know and should not make the engine ask for), plus optional `label` and `conventions`, then delegate. The adapter owns *which* doc and *what rules*; this skill owns the mechanics. Keeping the adapter's invocation contract stable means its own callers never learn the mechanics moved.

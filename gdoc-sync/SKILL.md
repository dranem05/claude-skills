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

**`LINK_CHANGES` is not cosmetic.** The normalizer deletes URLs to suppress export noise, so a Drive-side retarget under unchanged anchor text never appears in the main diff. Any non-zero `LINK_CHANGES` is a real hunk to classify.

### Phase 3 — Classify each hunk (judgment; this is your job, not the engine's)

- **A — Drive-only → merge into local.** Someone edited Drive; local lacks it. Default: pull it in.
- **B — Local-only → push to Drive.** A local edit not yet on Drive. Default: push.
- **C — cosmetic export noise → ignore.** Person-chips expanding to full names, `**` bold markers, backslash escapes, mailto wraps, `{#anchor}` tags, `:---` vs `---` separators. The normalizer already removes these, so they should not reach you as hunks at all; if one does, treat it as a real change.

**Needs an explicit user decision, never a default:** true conflicts (both sides edited the same span) · a Drive change that reverses a prior local change · Drive deletions · anything from `LINK_CHANGES` · date or label discrepancies with a possible domain reason · anything the caller's `conventions` marks as pinned or authoritative.

Surface the classification before applying anything in bulk.

### Phase 4 — Apply A-items to local (`pull-only`, `two-way`)

Small edits: use `Edit` directly. Whole-block swaps from Drive:

`bash "<skill-base-dir>/scripts/gdsync" swap --run <run> --start '<literal text>' --end '<literal text>'`

Anchors are literal text, not regexes. Exit **4** means an anchor is not unique on one side — lengthen it, don't force it. That check matters most on the Drive side: the all-tabs export is exactly the file likely to hold a *stale duplicate* of the block you want, and taking the first match would pull the stale one in silently.

### Phase 5 — Push B-items to Drive (`push-only`, `two-way`)

For each B-item, **pre-flight the find string before writing**:

`bash "<skill-base-dir>/scripts/gdsync" checkfind --run <run> --find '<drive current text>'`

**3** = the string is not in the snapshot (stale snapshot or wrong text — do not push, re-pull). **4** = it occurs more than once and a push would over-match — lengthen it. **0** = exactly one occurrence; proceed.

Then issue `docs_find_and_replace` with `documentId=<docId>`, `find` = Drive's **current** text (unescaped — export backslashes don't exist in the live body), `replace` = your target, and **`matchCase: true`**.

**Always pass `matchCase: true` explicitly, because you want a case-sensitive rewrite** — not because of any particular server default. Stating it as an intent rather than a workaround keeps the instruction correct regardless of what the default is.

Read `occurrencesChanged` on every response and treat three outcomes as distinct: **1** is the only success · **>1** means you over-matched, so restore immediately and re-find with more context · **0** means the push silently did nothing, so do *not* report it as pushed. If the field is absent from the response, say so rather than assuming success.

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
5. **`docs_replace_with_markdown` replaces the *entire body*** (schema-confirmed, from its own description) — destructive to all existing body content. Never use it for a partial update. What survives outside the body (file title, anchored comments) is *unverified*.
6. **Markdown rendering on push is unresolved.** `docs_replace_with_markdown` / `docs_append_markdown` advertise markdown in their descriptions but were *observed* inserting literal text. Test on a scratch doc before trusting either; until then push plain text via `find_and_replace`.
7. **`docs_read_document` is lossy and reads one tab per call** — see THE #1 RULE.
8. **Tables can't be created via `find_and_replace`** — needs `docs_insert_table_with_data` or a manual paste.
9. **The content-write tools take no `tabId`** (schema-confirmed for `find_and_replace`, `append_markdown`, `replace_with_markdown`; tab-*metadata* tools like `docs_rename_tab` do take one). So content destined for a specific non-default tab must be pasted by a human. The Phase-1 pull reads all tabs; only writing into a chosen one is blocked.

## Normalizer blind spots

Three things the filter chain hides **by design**, each pinned by a test so a future edit can't change them silently: a pure heading-**level** change · a hyperlink retarget under unchanged anchor text (which is why `LINK_CHANGES` exists) · a table row whose cells are all `-` placeholders. Full notes in the header comment of `scripts/gdsync`. If document structure or link integrity is in scope, also read the raw un-normalized diff.

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
- [ ] **If you edited anything under `scripts/`:** `bash tests/run` printed `0 failed`, `bash tests/run --canary` printed `0 hole(s)`, and you pasted both lines.

## Adapters

A domain-specific caller wraps this engine rather than reimplementing it: resolve your own identifier (an event ID, a client, a ticket) to `mode` + `local` + `docId`, pass `account` (which you usually know and should not make the engine ask for), plus optional `label` and `conventions`, then delegate. The adapter owns *which* doc and *what rules*; this skill owns the mechanics. Keeping the adapter's invocation contract stable means its own callers never learn the mechanics moved.

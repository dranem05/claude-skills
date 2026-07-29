# gdoc-sync — findings not yet folded into SKILL.md

**Status: a staging layer, deliberately separate.** `SKILL.md` and `scripts/gdsync` are the version that was exercised against real document copies and then a live production merge. Nothing here has earned that yet, so it is kept out of the tested artifact until someone decides, case by case, that it should go in.

Everything below is **measured, not reasoned**. Dates are when the measurement was taken.

---

## 1. The export flattens line breaks *inside* a table cell (2026-07-28)

The native export is faithful about table **structure** — real pipe rows — but not about line structure **within a cell**. A cell holding a ten-item list comes back as one space-joined line.

```
live cell (docs_get_table):  "Step one\nStep two\nStep three\n…"          (10 lines)
markdown export:             "Step one Step two Step three …"               (1 line)
local mirror:                 same as the export
diff:                         no hunk
```

Consequences:

- The diff is **structurally blind** to it — both sides agree on the flattened text, so the two copies look identical while they are not.
- A markdown table row cannot represent the structure, so a local mirror is **necessarily lossy** for these cells.
- **Replacing the whole cell from a single-line source collapses the list, and the post-push re-export flattens the damage identically — so the verify step cannot detect it.** This is the only corruption in this system that cannot be caught after the fact.
- **Editing text within one line of such a cell is safe.** Only the whole-cell replace destroys structure. Targeting a substring inside the cell avoids the question entirely.

**Working rule:** before replacing the whole of a table cell, read that cell with `docs_get_table` and confirm it is genuinely single-line.

### A guard for this was built and reverted — read before rebuilding it

Shipped as `TRIP: find-replaces-whole-cell` (exit 4) and reverted the same day. The reasoning, so it is not rediscovered the hard way:

- A single-line cell and a flattened multi-line one are **indistinguishable in the export**, so the check had to fire on *every* whole-cell find.
- Measured across two real documents: the **median table cell is 12 characters**. One document had **1 cell over 120 chars out of 128** — roughly **1% precision**.
- It converted pushes that had **already been verified against production** into refusals — a real single-line date-cell edit became an exit 4.
- A gate that stops the operator 127 times out of 128 gets waved through on the 128th. That is worse than no gate.
- Narrowing it by cell length or word count would be **inferring cell shape from text**, which this engine does not do.

**What would make it worth rebuilding:** a cell read that preserves intra-cell line breaks, or a write that addresses a cell's lines. Either removes the need to guess. Until then this stays a judgement call.

### And a lesson about the fixtures, not the feature

The guard passed 49 hand-written fixtures and a mutation canary, and was still wrong. Run against a **real export** it silently failed: the export escapes `#`, `~`, `+` and `-` that the document does not contain, so the snapshot holds `\~Mar 3` while an operator reading the live cell correctly types `~Mar 3`. A raw-to-raw comparison found no cell match and returned `RESULT: ok` — and the occurrence counter's de-escaped pass then matched the same string anyway, letting the whole-cell replace through unguarded.

The fixtures could not have caught it: they were authored from a mental model of the export format, and **the model was the thing that was wrong**. Self-authored fixtures test code against the author's assumptions. Only real input tests the assumptions.

---

## 2. Comments survive surgical pushes (2026-07-28)

Measured against a live document carrying **ten unresolved comment threads**: after ten `find_and_replace` writes — including one that rewrote text **inside** a commented range — all ten survived with identical ids, bodies and unresolved state. A targeted push does not endanger review threads, which matters when a document is under active review while you work on it.

Two things to know:

- A comment's `quotedFileContent` is a **snapshot frozen at creation**, so after an in-range edit it reads stale. That is API metadata, **not** evidence of damage — it is easy to misread as loss.
- Whether the margin anchor still renders (as against "Original content deleted") is **not observable through the API**. Only a human looking at the document can confirm it.

**Working rule:** inventory with `docs_list_comments` before and after a push session and compare ids, so real loss is caught rather than assumed. Adjacent and in-line edits need no special handling. Do not replace a whole commented block.

---

## 3. A deliberate gate-probe poisons the run it runs in (2026-07-28)

The recorded verdict in `<run>/verdict.rc` is **monotonic** — by design, so a gate survives context loss. But if you feed a command a knowingly-bad input to watch a refusal fire, that `4` stays on the run, and the *next* command with good input refuses with `TRIP: swap-needs-approval`.

Correct behaviour; awkward consequence. In a run whose only `4` you manufactured yourself, the obvious next move is to wave through an approval for a problem that does not exist.

**Working rule:** probe in a scratch run, or re-run the real work in a fresh one. Never clear a self-induced refusal with `--approved-by-user`.

---

## 4. Second measurement of the underscore→asterisk effect (2026-07-28)

`SKILL.md` records **55 hunks → 22** on a 536-line document. Reproduced on a second, unrelated document: **54 → 21**, over 74 spans. Two independent measurements, so this is the dominant source of phantom divergence rather than a quirk of one file.

If you convert a local copy, do it with a **word-boundary match** and **assert the counts first**: every `utm_*` parameter and every underscore-delimited filename must survive unchanged, aborting on any mismatch rather than inspecting the diff afterwards. One shape resists automation — a line carrying *both* emphasis and an underscore-delimited filename, since the emphasis span cannot cross the filename's underscores. Convert those by hand or leave them.

---

## Retirement — what would let these be deleted rather than folded in

| If the server gains… | Then… |
| --- | --- |
| A cell read that preserves intra-cell line breaks, **or** line-addressed writes | Finding 1's hazard largely goes away, and the reverted guard becomes worth rebuilding |
| Comment-aware writes, or an anchor-integrity signal | Finding 2's inventory advice becomes unnecessary |

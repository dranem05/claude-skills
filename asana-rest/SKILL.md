---
name: asana-rest
description: Escape hatch for Asana operations the local asana_* MCP servers cannot do — chiefly editing an existing comment (story), which is REST-only. Use when an Asana action has no matching MCP tool, or when an MCP tool exists but rejects the shape you need. Triggers on "edit that Asana comment", "fix the comment I posted", "update a story", "the Asana MCP can't do X".
---

# Asana REST escape hatch

The local `asana_*` MCP servers cover most of the API. A few operations have no tool. Reach for raw REST only for those — prefer the MCP tool whenever one exists, since it handles pagination, field selection, and validation for you.

## Auth

Personal access tokens live in `~/.config/openbrain/.env` as `ASANA_PAT_WORK` and `ASANA_PAT_PERSONAL`, one per workspace. Source the file in a subshell and reference the variable. **Never echo a token, pass it as a command argument, or write it into a file** — arguments are visible in process listings.

```bash
set -a; source ~/.config/openbrain/.env; set +a
curl -s -H "Authorization: Bearer $ASANA_PAT_WORK" ...
```

Match the token to the workspace. A work-workspace gid with the personal PAT returns 404, not 403, which reads like a missing object rather than the wrong key.

## Editing an existing comment

The known gap. `asana_create_task_story` posts a comment; nothing edits one.

1. **Get the story gid** via the MCP: `asana_get_task_stories` on the task, then pick the story whose `type` is `comment`. Do not guess it from a permalink.
2. **PUT the new body.** Send the whole body; this replaces, it does not patch.

```bash
set -a; source ~/.config/openbrain/.env; set +a
curl -s -X PUT "https://app.asana.com/api/1.0/stories/<STORY_GID>" \
  -H "Authorization: Bearer $ASANA_PAT_WORK" -H "Content-Type: application/json" \
  -d @- <<'JSON'
{"data":{"html_text":"<body>…</body>"}}
JSON
```

3. **Verify**, don't trust the 200: re-fetch with `?opt_fields=html_text,is_edited` and confirm `is_edited` is true and the body reads as intended.

**You can only edit comments you authored.** Someone else's story returns 403. Asana marks an edited comment "edited" in the UI permanently; there is no silent fix.

## Rich text rules

Same subset as the MCP's `html_notes` / `html_text`: wrap in `<body>`, escape `&` as `&amp;`, use `<ul>/<li>`, `<strong>`, `<em>`, `<a href>`. Markdown is not rendered — a `- ` bullet shows up literally.

**Link tasks by permalink and Asana upgrades them for free.** Pass `<a href="https://app.asana.com/1/<WORKSPACE_GID>/task/<TASK_GID>">any text</a>` and Asana rewrites it into a dynamic chip carrying `data-asana-dynamic="true"`, which renders the target's *current* name and shows a ✓ once it completes. Your anchor text is discarded, so do not labor over it. This beats writing a bare gid, which is unreadable, or a hand-typed name, which goes stale on rename.

`@mention` a person with `<a data-asana-gid="USER_GID"/>` — resolve gids via `asana_typeahead`. Mentioning also adds them as a follower.

## Any other gap: the method

Only the comment-edit recipe above has been run for real. For anything else, work the pattern rather than trusting a remembered endpoint:

1. **Confirm the gap is real.** Search the MCP tool list first. Most "missing" operations are a tool you did not find, or an existing tool refusing your input shape — which is a different problem and usually a better error message.
2. **Read the endpoint in Asana's API docs**, do not recall it. The shapes are inconsistent (`PUT` for stories, `POST` for most sub-resource adds) and a wrong-verb call often returns a plausible-looking error rather than an obvious one.
3. **Every write is `{"data": {...}}`.** Asana wraps request and response bodies in `data`; a flat payload fails confusingly.
4. **Dry-run on something disposable** when the operation destroys or reorders — a scratch task in your own workspace, not the record you care about.
5. **Verify by re-fetching**, never by the status code. A 200 confirms the request parsed, not that the field changed. Re-`GET` with `opt_fields` naming exactly the fields you touched.
6. **Write the verified recipe back into this file**, marked as verified and dated. That is what keeps this skill worth reading.

## Also verified (2026-09-01, against scratch objects since deleted)

**Delete a comment** — `DELETE /stories/<gid>`, same authorship rule as editing. Returns 200; the story then 404s. **Not undoable, and unlike an edit it leaves no trace** — an edited comment is at least marked "edited" in the UI, a deleted one is simply gone.

```bash
curl -s -X DELETE "https://app.asana.com/api/1.0/stories/<STORY_GID>" \
  -H "Authorization: Bearer $ASANA_PAT_WORK"
```

**Reorder a task within a project** — `POST /tasks/<gid>/addProject` with `insert_before` or `insert_after` set to another task's gid.

```bash
curl -s -X POST "https://app.asana.com/api/1.0/tasks/<TASK_GID>/addProject" \
  -H "Authorization: Bearer $ASANA_PAT_WORK" -H "Content-Type: application/json" \
  -d '{"data":{"project":"<PROJECT_GID>","insert_before":"<OTHER_TASK_GID>"}}'
```

**The non-obvious part: `addProject` is the reorder verb even when the task is already in the project.** The name reads like it would error or double-add; it does neither, it just moves the task. Confirmed by observing project order flip from `[C, B, A]` to `[A, C, B]` after one call. Verify with `GET /projects/<gid>/tasks`, which returns tasks in display order — the order *is* the response order, there is no position field to read.

Before adding a recipe, re-check whether an MCP tool has appeared for it — the local build tracks upstream and gaps close over time.

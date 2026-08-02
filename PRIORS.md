# Priors — defect classes worth checking before publishing a skill here

Recurring failure shapes caught by review passes on skills in this repo, kept so the next
one doesn't re-derive them. Each is something a reading of the code missed and a test
against real inputs found.

Distinct from `gdoc-sync/FINDINGS.md`, which is a skill-scoped staging layer for
measurements not yet folded into that skill. This file is repo-wide and is about
*classes*, not one skill's behaviour.

---

## 1. An upstream tool can exit 0 having done nothing

`whisper-cli` returns 0 when it rejects its own arguments and writes no files at all — an
unsupported `--lang` value (`es-MX`, `pt-BR`, anything region-tagged) does it, as does an
unwritable destination. A wrapper that treats exit 0 as success reports paths for files it
never produced.

**Working rule:** never infer success from an exit code alone. Verify the artifact.

Same shape for in-process APIs, not just subprocesses. DaVinci Resolve's
`ImportTimelineFromFile` returns `true` and creates no timeline when the timeline name is
already taken; a caller trusting the return value reports a successful handoff and leaves
an empty project. Verify by observable state change — count the objects before and after —
not by what the call says it did.

## 2. Existence is not freshness

The obvious follow-on fix — check the output file exists after the run — is still wrong.
An existence check at the final destination cannot tell "written by this run" from "left
there by an earlier one," so on any re-run a *failed* transcription hands back the
previous run's output as the current result. Verified: the wrapper printed both paths,
exit 0, while the file held a different recording's transcript.

**Working rule:** write to a temp directory, verify there, then move into place. That
distinguishes fresh from stale *and* leaves existing files untouched when the run fails.

## 3. Default to not destroying; put the choice in a flag, not a prompt

Conventions among neighbours split three ways: `ffmpeg` refuses (prompts when it can,
errors with "Not overwriting" when stdin isn't a tty), `wget` and `yt-dlp` rename or skip,
and transcriber CLIs generally overwrite in silence. The overwriting group is the one that
loses data — `whisper-cli` will replace a good transcript with an *empty* file at exit 0
when it finds no speech.

An interactive prompt is not the answer: these tools run under agents and in batches where
stdin isn't a tty, so a prompt hangs or silently takes the default.

**Working rule:** never clobber by default. Shift to a numbered set, or refuse. Offer
`--overwrite` for the caller who wants replacement. If outputs come as a set, move the
whole set together — a fresh `.txt` beside a stale `.srt` is worse than either outcome.

## 4. Derive output paths from the basename, not the whole path

`"${VAR%.*}"` over a full path truncates at the last dot *anywhere in it*. For an
extensionless input under a directory whose name contains a dot, outputs land in a parent
directory under a mangled name. This is not exotic: it fires for any input under a home
directory or host-named folder containing a dot.

**Working rule:** split with `dirname`/`basename`, strip the extension from the basename,
rejoin. Test with an extensionless file under a dotted directory.

## 5. A new guard must cover every branch that can set the thing it guards

A one-input-per-call check was added to the normal argument branch and not to the `--`
branch — and `--` is the documented escape hatch for filenames starting with `-`, so the
one path users are pushed toward was the one hole. The silent wrong-outcome the guard
existed to prevent remained reachable.

**Working rule:** when adding a guard, grep for every assignment to the guarded variable
and cover each one. Then write the test against the escape hatch, not the common path.

## 6. Decide destinations before doing expensive work

A refusal that arrives after a multi-minute transcode is a bad refusal. Resolving output
paths, collision checks and clobber policy up front makes rejection free.

## 7. Canary discipline — a mutation that breaks everything proves nothing

Three ways a canary lies:

- **The mutant doesn't parse.** Every case fails for the wrong reason and looks like
  perfect detection. Assert `bash -n` on the mutated copy before running the suite.
- **One mutation breaks several fixes at once.** Mutate one fix at a time, and assert the
  *specific* case covering it goes red.
- **A case stays green and gets quietly dropped from the list.** Sometimes that's a real
  hole; sometimes the outcome is defended by several independent layers, so reverting one
  still catches it. Both look identical from the summary line. Find out which, record the
  reason next to the exclusion, and never exclude a case without one.

## 8. The fixture generator can be the bug

Two suite cases went red on a defect that was in the test harness, not the code: `ffmpeg`
infers the output container from the file extension, so synthesizing a fixture directly to
an extensionless path silently produced no file and the case ran with no input at all.

**Working rule:** a newly-red case is a claim about the code *or* the harness. Confirm
which before changing either.

## 9. Publishing a private skill leaks by coupling, not just by keywords

A keyword scrub (names, employer, project vocabulary) is necessary and not sufficient. The
things that actually survived a clean keyword sweep:

- **Host-project coupling** — invocation paths relative to one repo's cwd, follow-ups
  pointing at sibling skills that only exist in the private setup, routing advice naming
  services only that setup had. All break or mislead on a fresh install.
- **Commit identity.** Content scrubs don't look at `%ae`. Check the author address on the
  commits, not only the diff.
- **Shape-based sweeps beat keyword lists** — grep for the *shape* of an email, URL,
  absolute path, IP or long token, then read what comes back. A keyword list only finds
  the terms you already thought of.

Use a documentation-reserved domain (`example.com`) in fixtures rather than a real one.

## 10. A clean negative can mean the probe was aimed at the wrong object

The inverse of #8, and worse, because nothing announces it. A fidelity harness reported
"markers: 0" on four consecutive runs. The markers were being attached to one object
(an OTIO `Track`) while the readback queried a different one (Resolve's *timeline*-level
`GetMarkers()`). The probe was structurally incapable of ever returning non-zero, and every
run was measuring nothing.

It survived four rounds because a clean negative is *comfortable*: it was internally
consistent, it agreed with a plausible prior ("interchange formats lose markers, everyone
knows that"), and it closed a question instead of opening one. It got written into a
findings doc as a measured fact and was nearly published as guidance. A red result would
have been investigated immediately; a tidy zero got believed.

**Working rule:** before recording that something is absent, lost, unsupported, or clean,
prove the probe can see that thing *when it is definitely present*. A positive control is
one extra case and it converts "we found nothing" into "we would have found it." Where no
positive control is possible, record the result as **unverified**, never as negative.

**Smell test:** any finding phrased as an absence — "no drift," "no matches," "nothing
incoming," "markers not supported," "zero fillers" — is a claim that a detector both ran
*and* pointed at the right place. Absence findings should cost more scrutiny than presence
findings, not less. The habit that catches these is asking "what would this probe do if the
thing were there?" before believing that it isn't.

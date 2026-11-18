# Audit protocol

How MediaPull is audited, so that coverage accumulates and each audit finds what the previous ones could not.

## Rules

- **Uncapped.** An audit reports every defect it can prove, not its top few.
- **Spec-driven.** Walk [SPEC.md](SPEC.md) section by section against the code, using [CONFORMANCE.md](CONFORMANCE.md) to find
  where each requirement lives, then look at the code for the cause categories below.
- **Proved.** Every finding quotes the code (`file:line`) and gives a concrete failure: the inputs or state, and the wrong
  result. A suspicion that cannot be shown either way says so and is not counted as a finding.
- **Graded.** Critical: a broken read-only contract, or a crash on ordinary input. Major: data lost or misplaced (a file
  deleted, cut short, overwritten, hidden, put in the wrong folder, or downloaded again after being deleted on purpose) in
  a plausible use. Minor: everything else, including something reported or counted wrongly, a message or note that is
  wrong, a missing progress or status, a spec requirement met differently without losing data, and any rare sequence
  (several quick actions, two windows racing, a crash at an exact moment) that loses no data.
- **Ledger.** Each audit is written to `docs/audits/<date>-<n>.md` with its findings and a "checked and fine" list of what
  it read and found sound, so the next audit can go where this one did not.
- **Closed by a test.** A finding is closed only with a regression test or self-test step, and a lint or helper when it is
  a pattern.

## Scope (from round 18 of the 1.8 audit)

Scope is frozen: rounds only fix. In the closing rounds (from round 23) only majors are fixed, with wording, docs and
tests; a minor that would change behaviour is recorded in the ledger and left, since two such fixes in a row caused
majors (A21-m3, B22-m1). A fix bigger than a few lines needs a simpler rule written in the spec first (a D-nn
entry), not another patch to the last one. Earlier rules that were patched round after round were replaced by simpler
ones (D-93 Undo, D-98 earlier versions' memory, D-102 playlist Retry); an auditor does not re-report those designs, only
code that does not do what they say.

## Cause categories (from the 1.8 review, plan section C)

1. Spec drift: a requirement written but not built, or built differently.
2. An invariant kept by convention at each call site instead of by construction: main-actor file work, shortcuts that fire
   in hidden panes, per-hop network policy, path comparison (case and Unicode), sanitising before checking.
3. Data lifecycle: something created with no matching delete or prune.
4. Scale and edges: tens of thousands of files, empty folders, huge or odd input, Unicode names.
5. Third-party behaviour assumed rather than pinned by a test (gallery-dl, yt-dlp, ffmpeg, ImageIO, WebKit).
6. Silent failure: `try?`, `continue` or `|| true` where the person loses work without being told.
7. Window and task lifecycle: work that outlives its window, descriptors and watchers left open.

## Exit criterion for a release

Two consecutive independent audits with no new confirmed finding above minor.

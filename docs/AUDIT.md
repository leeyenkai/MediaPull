# Audit protocol

How MediaPull is audited, so that coverage accumulates and each audit finds what the previous ones could not.

## Rules

- **Uncapped.** An audit reports every defect it can prove, not its top few.
- **Spec-driven.** Walk [SPEC.md](SPEC.md) section by section against the code, using [CONFORMANCE.md](CONFORMANCE.md) to find
  where each requirement lives, then look at the code for the cause categories below.
- **Proved.** Every finding quotes the code (`file:line`) and gives a concrete failure: the inputs or state, and the wrong
  result. A suspicion that cannot be shown either way says so and is not counted as a finding.
- **Graded.** Critical (data loss, a broken read-only contract, a crash on ordinary input), major (wrong result a person
  would notice, a spec requirement not met), minor (polish, unlikely edge, wording).
- **Ledger.** Each audit is written to `docs/audits/<date>-<n>.md` with its findings and a "checked and fine" list of what
  it read and found sound, so the next audit can go where this one did not.
- **Closed by a test.** A finding is closed only with a regression test or self-test step, and a lint or helper when it is
  a pattern.

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

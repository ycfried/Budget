# Contributing — ios-clone (STAGE iOS app)

## Cloud-build polling discipline (F-30, build 61 audit)

The simulator and upload workflows run on macOS cloud runners and
are triggered by a commit, not by a button. The discipline below
keeps the trigger reliable and keeps GitHub API usage sane. It
lived only in audit docs until build 64 — that is how it got
forgotten once, and on Nov 13, 2026 `gh run watch` burned the
5,000-call API budget. Do not re-learn that lesson.

### Triggering a cloud build

A trigger commit MUST do both of these:

1. Start its message with `ci(ios-clone): approved cloud build`
   (the simulator workflow's `if:` only runs on that prefix).
2. Touch a file (any file — the workflows trigger on `push` with
   path filters, so an empty commit runs nothing).

Example: `ci(ios-clone): approved cloud build — build 64: <scope>`.

### Checking a run

- **Sparse 5-minute polls only.** Check the run status at most
  once every 5 minutes (e.g. `gh run list` / the Actions tab).
- **NEVER `gh run watch`.** It polls continuously and burns the
  API budget (5,000 calls, Nov 13, 2026). There is no live tail
  worth that cost — the run's summary and artefacts are written
  when it finishes.
- One run per commit SHA: the upload workflow gates on the
  simulator run for that SHA, so do not re-trigger or amend a
  commit whose run is already in flight; wait for it.

### What runs where

- **Simulator proof** (`.github/workflows/ios-clone-simulator.yml`):
  kit tests + iPhone UI tests + iPad leg on the
  `ios-clone-testflight` branch. ~65 min; 90-min timeout.
  See the F-24 comment at the top of that file before splitting it.
- **Upload to TestFlight** (`.github/workflows/ios-clone-testflight-upload.yml`):
  gates on the simulator run for the commit SHA. The upload
  workflow's own comments should also carry this discipline —
  that half of F-30 is still owed (the upload workflow is outside
  this file's scope).

## Server changes (SQL + Edge Functions)

- SQL files under `supabase/` are paste-ready: the owner applies
  them by hand via GitHub "Copy raw contents" (any other paste
  loses line breaks and silently no-ops). Keep each file
  self-contained, with verification steps as comments.
- Edge Functions under `supabase/functions/` deploy via a focused
  cherry-pick PR to main — never by the app upload, never by a
  wholesale merge. See `supabase/DEPLOY-BUILD64-SERVER.md` for the
  build-64 handoff (which SQL to paste in which order, which
  Edge Function files go in the PR).
- Never commit, push, or deploy from a work branch without the
  owner's go-ahead; never touch the live household or the live
  Supabase project from this repo.

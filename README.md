# GORM SQLite Driver for modernc.org/sqlite

[![CI](https://github.com/found-cake/gorm-sqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/found-cake/gorm-sqlite/actions/workflows/ci.yml)

A CGO-free fork of the official [GORM SQLite driver](https://github.com/go-gorm/sqlite), powered by [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite).

## Quick start

```shell
go get github.com/found-cake/gorm-sqlite
```

```go
import (
  "github.com/found-cake/gorm-sqlite"
  "gorm.io/gorm"
)

db, err := gorm.Open(sqlite.Open("gorm.db"), &gorm.Config{})
```

The public API stays compatible with the official driver. The default driver name is `sqlite`, and compatibility DSN defaults for time conversion and a five-second busy timeout are added without overriding explicitly supplied values.

## Upstream synchronization

- `master` contains the modernc.org/sqlite port.
- `sync/<upstream-commit>` branches contain proposed upstream updates.

The weekly `Sync upstream` workflow asks Git to merge the latest official driver into a commit-named sync branch. Three kinds of conflict resolve themselves, because their outcome never varies:

- Dependency metadata conflicts keep this fork's files.
- `error_translator_cgo.go` and `error_translator_nocgo.go` do not exist here, so upstream edits to them arrive as modify/delete conflicts and the deletion is kept.
- Conflicts limited to `sqlite.go` or `sqlite_test.go` are retried with the fork hunks preferred.

The last two discard upstream's work, and the merged tree shows no trace of what was discarded. So whenever either happens, the sync branch also carries `.github/upstream-sync-review/<upstream-commit>.patch` — upstream's own diff for exactly those files — the pull request is opened as a draft listing each discarded file next to the fork file that took over its job, and the `Upstream review patches resolved` CI check fails for as long as the patch is present. Read the patch, port anything this fork still needs, delete the patch, then mark the pull request ready.

Deleting a translator file does not mean upstream's error handling is ignored. `errCodes` lives in the shared `error_translator.go`, which merges normally, so a new error-code mapping reaches this fork on its own. Only a change to how the result code is read off the driver error, or to the control flow of `Translate`, has to be ported into `error_translator_modernc.go` by hand.

A successful merge with nothing discarded is tested and opened as a normal pull request; test failures produce a draft.

Any source conflict that still needs manual resolution is committed with its `<<<<<<<`, `=======`, and `>>>>>>>` markers intact and pushed to the sync branch without opening a pull request. A single open issue links to the branch and to the start of every conflict hunk that needs attention. The branch reaches the remote before the pull request or the issue exists, so a run that dies in between leaves a branch nothing tracks; the next run adopts that branch and finishes it rather than treating it as done.

### How the sync workflow is split

Merging upstream means running upstream's code: the merged tree is tested, and `test-gorm.sh` clones GORM and runs its suite. That must never happen where a write-capable token can be reached, so the workflow is two jobs.

- `merge` runs the merge and the tests. It has no secret, a read-only `GITHUB_TOKEN`, and a checkout that keeps no credentials. It writes nothing to the remote; it leaves a plan, a pull request body, and a git bundle of the sync branch as an artifact.
- `publish` pushes that bundle and calls the API. It holds `SYNC_TOKEN` and runs no code from the merged tree — it unpacks a bundle, pushes it, and opens the pull request. The script it runs is `master`'s copy, checked out fresh, never the merged one.

The plan crosses that boundary, so `publish` reads it key by key and rejects any field that does not look like what it should. It is never sourced, which would hand the untrusted side a shell in the job that holds the token.

`SYNC_TOKEN` is used instead of `GITHUB_TOKEN` because a branch pushed with `GITHUB_TOKEN` starts no workflow run, and the pull request would sit there unchecked. It is a fine-grained token on this repository with write access to Contents, Pull requests, Issues, and Workflows; the last is needed because an upstream merge can touch files under `.github/workflows/`, which Git refuses to push without it. The job fails with an explicit message when the secret is missing.

Dependency updates are handled separately by Dependabot for Go modules and GitHub Actions. Upstream syncs preserve `master`'s `go.mod`, `go.sum`, and `.github/dependabot.yml`, then run `go mod tidy` so dependencies required by merged source changes are still recorded. Dependency-only upstream changes do not open a sync pull request.

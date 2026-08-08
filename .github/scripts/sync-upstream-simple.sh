#!/usr/bin/env bash
set -euo pipefail

# This script runs in two phases so that no upstream code ever executes while a
# write-capable token is reachable.
#
#   merge   - fetches upstream, merges, resolves the known conflicts and runs the
#             tests. Runs untrusted code. Needs no token and writes nothing to
#             the remote; it leaves a plan and a git bundle in SYNC_STATE_DIR.
#   publish - reads that plan, pushes the bundle and talks to the GitHub API.
#             Holds the token and runs no code from the merged tree.
#
#   all     - both, in one process. For local runs and tests only; a CI run that
#             uses this phase puts the token back in reach of upstream code.
sync_phase=${SYNC_PHASE:-all}
case "$sync_phase" in
merge | publish | all) ;;
*)
	printf 'unknown SYNC_PHASE %s; expected merge, publish or all\n' "$sync_phase" >&2
	exit 2
	;;
esac

upstream_url=${UPSTREAM_URL:-https://github.com/go-gorm/sqlite.git}
upstream_branch=${UPSTREAM_BRANCH:-master}
target_branch=${TARGET_BRANCH:-master}
upstream_remote=upstream-sync
merge_issue_title='sync: upstream merge requires attention'
managed_dependency_files=(go.mod go.sum .github/dependabot.yml)
# Files the CGO-free port removed on purpose, each paired with the fork file
# that took over its job. Upstream still maintains them, so every upstream edit
# lands as a modify/delete conflict that is always resolved the same way: keep
# the deletion. Keeping the deletion is not the same as ignoring the change, so
# the counterpart is named in the pull request for porting.
fork_deleted_files=(
	'error_translator_cgo.go:error_translator_modernc.go'
	'error_translator_nocgo.go:error_translator_modernc.go'
)
github_server_url=${GITHUB_SERVER_URL:-https://github.com}
github_repository=${GITHUB_REPOSITORY:-found-cake/gorm-sqlite}
repository_url=${REPOSITORY_URL:-$github_server_url/$github_repository}

state_dir=${SYNC_STATE_DIR:-${RUNNER_TEMP:-/tmp}/gorm-sqlite-sync-state}
mkdir -p "$state_dir"
plan_file="$state_dir/plan.env"
bundle_file="$state_dir/sync.bundle"
pr_body="$state_dir/pr-body.md"
issue_body="$state_dir/issue-body.md"

# record_plan <none|issue|pr> <push:0|1> <draft:0|1>
record_plan() {
	{
		printf 'SYNC_ACTION=%s\n' "$1"
		printf 'SYNC_PUSH=%s\n' "$2"
		printf 'SYNC_PR_DRAFT=%s\n' "$3"
		printf 'SYNC_BRANCH=%s\n' "${sync_branch:-}"
		printf 'SYNC_PR_TITLE=%s\n' "${pr_title:-}"
		printf 'SYNC_UPSTREAM_COMMIT=%s\n' "${upstream_commit:-}"
	} >"$plan_file"
	printf 'plan: action=%s push=%s draft=%s branch=%s\n' "$1" "$2" "$3" "${sync_branch:-none}"
}

find_open_merge_issue() {
	gh issue list \
		--state open \
		--search "\"$merge_issue_title\" in:title" \
		--json number,title \
		--jq ".[] | select(.title == \"$merge_issue_title\") | .number" |
		sed -n '1p'
}

plan_value() {
	sed -n "s/^$1=//p" "$plan_file" | sed -n '1p'
}

require_plan_match() {
	if [[ ! $2 =~ $3 ]]; then
		printf 'plan field %s is not usable: %q\n' "$1" "$2" >&2
		exit 1
	fi
}

run_publish_phase() {
	local action push draft branch title commit existing_issue
	local -a pr_args

	if [[ ! -f "$plan_file" ]]; then
		printf 'no plan at %s; the merge phase produced nothing to publish\n' "$plan_file"
		return 0
	fi

	# The plan crosses a trust boundary: the merge phase runs upstream code and
	# GORM's test suite, and this phase holds the token. So the plan is read key
	# by key and checked against what each field is allowed to look like. It is
	# never sourced, which would hand that phase a shell.
	action=$(plan_value SYNC_ACTION)
	require_plan_match SYNC_ACTION "$action" '^(none|issue|pr)$'
	if [[ $action == none ]]; then
		printf 'nothing to publish\n'
		return 0
	fi

	push=$(plan_value SYNC_PUSH)
	draft=$(plan_value SYNC_PR_DRAFT)
	branch=$(plan_value SYNC_BRANCH)
	title=$(plan_value SYNC_PR_TITLE)
	commit=$(plan_value SYNC_UPSTREAM_COMMIT)
	require_plan_match SYNC_PUSH "$push" '^[01]$'
	require_plan_match SYNC_PR_DRAFT "$draft" '^[01]$'
	require_plan_match SYNC_BRANCH "$branch" '^sync/[0-9a-f]{12}$'
	require_plan_match SYNC_UPSTREAM_COMMIT "$commit" '^[0-9a-f]{40}$'
	require_plan_match SYNC_PR_TITLE "$title" '^sync: upstream [0-9a-f]{12}$'

	if [[ $push == 1 ]]; then
		# In CI this phase is a fresh checkout that has never seen the branch, so
		# the bundle is how the merge reaches it. Running both phases in one
		# process leaves the branch already present, and Git refuses to fetch
		# over a branch that is checked out.
		if ! git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
			git fetch "$bundle_file" "refs/heads/$branch:refs/heads/$branch"
		fi
		git push origin "refs/heads/$branch:refs/heads/$branch"
	fi

	if [[ $action == issue ]]; then
		existing_issue=$(find_open_merge_issue)
		if [[ -z "$existing_issue" ]]; then
			gh issue create --title "$merge_issue_title" --body-file "$issue_body"
		elif gh issue view "$existing_issue" --json body,comments --jq '[.body, .comments[].body] | join("\n")' |
			grep -q "$commit"; then
			printf 'merge issue #%s already contains upstream %s\n' "$existing_issue" "$commit"
		else
			gh issue comment "$existing_issue" --body-file "$issue_body"
		fi
		return 0
	fi

	pr_args=(
		--base "$target_branch"
		--head "$branch"
		--title "$title"
		--body-file "$pr_body"
	)
	if [[ $draft == 1 ]]; then
		pr_args+=(--draft)
	fi
	gh pr create "${pr_args[@]}"

	existing_issue=$(find_open_merge_issue)
	if [[ -n "$existing_issue" ]]; then
		gh issue close "$existing_issue" \
			--comment "Upstream \`$commit\` is now tracked by \`$title\`."
	fi
}

if [[ $sync_phase == publish ]]; then
	run_publish_phase
	exit 0
fi

# ---------------------------------------------------------------------------
# merge phase
# ---------------------------------------------------------------------------

record_plan none 0 0

if git remote get-url "$upstream_remote" >/dev/null 2>&1; then
	git remote set-url "$upstream_remote" "$upstream_url"
else
	git remote add "$upstream_remote" "$upstream_url"
fi

git fetch --no-tags "$upstream_remote" "$upstream_branch"
git fetch --no-tags origin "$target_branch"

upstream_ref="$upstream_remote/$upstream_branch"
target_ref="origin/$target_branch"
upstream_commit=$(git rev-parse "$upstream_ref")
target_commit=$(git rev-parse "$target_ref")
base_commit=$(git merge-base "$target_ref" "$upstream_ref")
short_upstream=${upstream_commit:0:12}
sync_branch="sync/$short_upstream"
pr_title="sync: upstream $short_upstream"

if git merge-base --is-ancestor "$upstream_ref" "$target_ref"; then
	printf 'upstream is already contained in %s at %s\n' "$target_branch" "$upstream_commit"
	exit 0
fi

existing_pr=$(gh pr list \
	--state all \
	--search "$short_upstream in:title" \
	--json number,state,title \
	--jq ".[] | select(.title == \"$pr_title\") | \"#\(.number) \(.state)\"" |
	sed -n '1p')
if [[ -n "$existing_pr" ]]; then
	printf 'upstream %s is already tracked by PR %s\n' "$upstream_commit" "$existing_pr"
	exit 0
fi

# The branch is pushed before the pull request or the issue is created, so a
# branch that nothing tracks means an earlier run died in between. Treating that
# as "already handled" would wedge the sync for good, so it is finished instead.
resume_orphan_branch=0
if git ls-remote --exit-code --heads origin "$sync_branch" >/dev/null 2>&1; then
	printf 'sync branch %s exists but no pull request tracks it; finishing that run\n' "$sync_branch"
	resume_orphan_branch=1
fi

analysis_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/gorm-sqlite-sync.XXXXXX")
merge_log="$analysis_root/merge.log"
conflict_files="$analysis_root/conflicts.txt"
conflict_locations="$analysis_root/conflict-locations.txt"
auto_merge_conflicts="$analysis_root/auto-merge-conflicts.txt"
auto_deleted_files="$analysis_root/auto-deleted-files.txt"
review_artifact=
: >"$conflict_files"
: >"$conflict_locations"
: >"$auto_merge_conflicts"
: >"$auto_deleted_files"

compose_merge_issue() {
	{
		printf 'The weekly upstream sync could not merge `%s` into `%s`.\n\n' "$upstream_commit" "$target_commit"
		if [[ -n "${conflict_branch_url:-}" ]]; then
			printf 'The unresolved merge was committed with conflict markers to branch [`%s`](%s). No pull request was opened.\n\n' "$sync_branch" "$conflict_branch_url"
		fi
		printf '## Conflicting files\n\n'
		if [[ -s "$conflict_files" ]]; then
			while IFS= read -r conflicted_file; do
				printf -- '- `%s`\n' "$conflicted_file"
			done <"$conflict_files"
		else
			printf 'Git did not report an unmerged path. Inspect the merge log below.\n'
		fi
		if [[ -s "$conflict_locations" ]]; then
			printf '\n## Conflict locations\n\n'
			while IFS=$'\t' read -r conflicted_file line_number; do
				printf -- '- [`%s:L%s`](%s/blob/%s/%s#L%s)\n' \
					"$conflicted_file" "$line_number" "$repository_url" "$conflict_snapshot_commit" \
					"$conflicted_file" "$line_number"
			done <"$conflict_locations"
		fi
		printf '\n## Merge log\n\n```text\n'
		sed -n '1,200p' "$merge_log"
		if [[ -n "${conflict_branch_url:-}" ]]; then
			printf '```\n\nResolve every conflict marker on the sync branch, run `go mod tidy` and the tests, then open a pull request. Close this issue after that pull request is merged.\n'
		else
			printf '```\n\nInspect the failed merge above, then close this issue after the upstream change is handled.\n'
		fi
	} >"$issue_body"
}

# A modify/delete conflict where the fork is the side that deleted leaves the
# base and upstream stages in the index but no "ours" stage.
is_fork_delete_conflict() {
	local staged
	staged=$(git ls-files -u -- "$1" | awk '{ print $3 }' | sort -u | tr '\n' ' ')
	[[ $staged == '1 3 ' ]]
}

# Resolve the conflicts whose outcome never varies, then record whatever Git
# still reports as unmerged. Safe to call after each merge attempt: `git merge
# --abort` discards these resolutions, and `-Xours` does not resolve
# modify/delete conflicts on its own.
resolve_known_conflicts() {
	local dependency_file deleted_entry deleted_file counterpart

	for dependency_file in "${managed_dependency_files[@]}"; do
		if git ls-files -u -- "$dependency_file" | grep -q .; then
			git checkout --ours -- "$dependency_file"
			git add "$dependency_file"
		fi
	done

	: >"$auto_deleted_files"
	for deleted_entry in "${fork_deleted_files[@]}"; do
		deleted_file=${deleted_entry%%:*}
		counterpart=${deleted_entry#*:}
		if is_fork_delete_conflict "$deleted_file"; then
			git rm --quiet --force -- "$deleted_file"
			printf '%s\t%s\n' "$deleted_file" "$counterpart" >>"$auto_deleted_files"
		fi
	done

	git diff --name-only --diff-filter=U >"$conflict_files"
}

materialize_conflict_markers() {
	while IFS= read -r conflicted_file; do
		if [[ -f "$conflicted_file" ]] && grep -a -q '^<<<<<<< ' "$conflicted_file"; then
			continue
		fi

		mkdir -p "$(dirname "$conflicted_file")"
		{
			printf '<<<<<<< fork (%s)\n' "$target_branch"
			git show ":2:$conflicted_file" 2>/dev/null || true
			printf '\n=======\n'
			git show ":3:$conflicted_file" 2>/dev/null || true
			printf '\n>>>>>>> upstream (%s)\n' "$short_upstream"
		} >"$conflicted_file"
	done <"$conflict_files"
}

record_conflict_locations() {
	while IFS= read -r conflicted_file; do
		while IFS= read -r line_number; do
			printf '%s\t%s\n' "$conflicted_file" "$line_number"
		done < <(awk '/^<<<<<<< / { print FNR }' "$conflicted_file")
	done <"$conflict_files" >"$conflict_locations"
}

bundle_sync_branch() {
	git bundle create "$bundle_file" "refs/heads/$sync_branch" --not "$target_commit"
}

stage_conflict_snapshot() {
	for dependency_file in "${managed_dependency_files[@]}"; do
		git restore --source "$target_ref" --staged --worktree -- "$dependency_file"
	done

	materialize_conflict_markers
	record_conflict_locations
	git add -A
	git commit -m 'Record unresolved upstream merge conflicts'
	conflict_snapshot_commit=$(git rev-parse HEAD)
	conflict_branch_url="$repository_url/tree/$sync_branch"
	bundle_sync_branch
	compose_merge_issue
	record_plan issue 1 0
}

git config user.name github-actions
git config user.email github-actions@github.com

# Adopt a branch an earlier run left behind. Its merge is already done and
# pushed; all that is missing is the pull request or the issue, so the branch is
# read back to work out which one it needed.
if [[ $resume_orphan_branch == 1 ]]; then
	git fetch --no-tags origin "$sync_branch"
	git switch --force-create "$sync_branch" "origin/$sync_branch"
	conflict_snapshot_commit=$(git rev-parse HEAD)
	conflict_branch_url="$repository_url/tree/$sync_branch"
	git grep -l -a -I -e '^<<<<<<< ' HEAD -- | sed 's|^HEAD:||' >"$conflict_files" || :
	printf 'branch %s was pushed by an earlier run; no merge was attempted now\n' \
		"$sync_branch" >"$merge_log"

	if [[ -s "$conflict_files" ]]; then
		record_conflict_locations
		compose_merge_issue
		record_plan issue 0 0
	else
		review_artifact=$(git ls-files ".github/upstream-sync-review/$short_upstream.patch")
		{
			printf 'Upstream `%s` was merged into `%s` by an earlier run that pushed' "$upstream_commit" "$target_commit"
			printf ' `%s` and then failed before opening this pull request. The branch is' "$sync_branch"
			printf ' unchanged; only the pull request is new.\n\n'
			if [[ -n "$review_artifact" ]]; then
				printf 'That run discarded upstream work, and `%s` holds what it discarded.' "$review_artifact"
				printf ' Review it, port anything this fork still needs, then delete the patch'
				printf ' before marking this pull request ready.\n\n'
			fi
			printf 'The driver and GORM tests were **not** run for this pull request; CI covers it.\n'
		} >"$pr_body"
		record_plan pr 0 1
	fi

	if [[ $sync_phase == all ]]; then
		run_publish_phase
	fi
	exit 0
fi

git switch --force-create "$sync_branch" "$target_ref"

set +e
git merge --no-ff --no-commit "$upstream_ref" >"$merge_log" 2>&1
merge_status=$?
set -e
cat "$merge_log"

if [[ $merge_status -ne 0 ]]; then
	resolve_known_conflicts
fi

if [[ -s "$conflict_files" ]]; then
	auto_merge=1
	while IFS= read -r conflicted_file; do
		case "$conflicted_file" in
		sqlite.go | sqlite_test.go) ;;
		*) auto_merge=0 ;;
		esac
	done <"$conflict_files"

	if [[ $auto_merge == 1 ]]; then
		cp "$conflict_files" "$auto_merge_conflicts"
		git merge --abort
		printf '\nRetrying known SQLite conflicts with the fork hunks preferred.\n' >>"$merge_log"
		set +e
		git merge --no-ff --no-commit -Xours "$upstream_ref" >>"$merge_log" 2>&1
		merge_status=$?
		set -e
		resolve_known_conflicts
	fi
fi

if [[ -s "$conflict_files" ]]; then
	stage_conflict_snapshot
	if [[ $sync_phase == all ]]; then
		run_publish_phase
	fi
	exit 0
fi

if ! git rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
	git merge --abort >/dev/null 2>&1 || true
	compose_merge_issue
	record_plan issue 0 0
	if [[ $sync_phase == all ]]; then
		run_publish_phase
	fi
	exit 0
fi

git commit --no-edit

for dependency_file in "${managed_dependency_files[@]}"; do
	git restore --source "$target_ref" --staged --worktree -- "$dependency_file"
done
go mod tidy
if ! git diff --quiet -- "${managed_dependency_files[@]}" ||
	! git diff --cached --quiet -- "${managed_dependency_files[@]}"; then
	git add -A -- "${managed_dependency_files[@]}"
	git commit -m 'Preserve fork dependency metadata after upstream sync'
fi

# Every path resolved without reading upstream's intent: fork hunks preferred,
# or the fork's deletion kept. The merged tree shows none of what upstream
# wanted there, so the diff alone is not reviewable.
review_paths=()
while IFS= read -r discarded_file; do
	review_paths+=("$discarded_file")
done < <({ cat "$auto_merge_conflicts"; cut -f1 "$auto_deleted_files"; } | sort -u)

if [[ ${#review_paths[@]} -eq 0 ]] && git diff --quiet "$target_ref" HEAD --; then
	printf 'upstream produced no source changes after dependency metadata was restored\n'
	exit 0
fi

if [[ ${#review_paths[@]} -gt 0 ]]; then
	review_artifact=".github/upstream-sync-review/$short_upstream.patch"
	mkdir -p "$(dirname "$review_artifact")"
	git diff --binary "$base_commit" "$upstream_ref" -- "${review_paths[@]}" >"$review_artifact"
	git add "$review_artifact"
	git commit -m 'Add upstream conflict patch for review'
fi

set +e
CGO_ENABLED=0 go test -count=1 ./...
driver_test_status=$?
bash .github/scripts/test-gorm.sh
gorm_test_status=$?
CGO_ENABLED=0 go list -deps ./... | grep -q 'github.com/mattn/go-sqlite3'
mattn_dependency_status=$?
set -e

test_summary=passed
if [[ $driver_test_status -ne 0 || $gorm_test_status -ne 0 || $mattn_dependency_status -eq 0 ]]; then
	test_summary=failed
fi

{
	printf 'Upstream `%s` merged into `%s`.\n\n' "$upstream_commit" "$target_commit"
	if [[ -s "$auto_merge_conflicts" ]]; then
		printf 'Conflicting hunks were resolved by preferring the fork side, so upstream'
		printf ' changes to these files are **not** in the diff below:\n\n'
		while IFS= read -r conflicted_file; do
			printf -- '- `%s`\n' "$conflicted_file"
		done <"$auto_merge_conflicts"
		printf '\n'
	fi
	if [[ -s "$auto_deleted_files" ]]; then
		printf 'Upstream still maintains these files, which this fork deleted. The'
		printf ' deletion was kept, so the upstream edits are in no file here.'
		printf ' Port whatever still applies into the counterpart:\n\n'
		while IFS=$'\t' read -r deleted_file counterpart; do
			printf -- '- [ ] `%s` &rarr; `%s`\n' "$deleted_file" "$counterpart"
		done <"$auto_deleted_files"
		printf '\n'
		printf 'Note that `errCodes` lives in the shared `error_translator.go` and merges'
		printf ' normally, so a new error-code mapping needs no porting. What does need'
		printf ' porting is a change to how the result code is pulled off the driver'
		printf ' error, or to the control flow of `Translate`.\n\n'
	fi
	if [[ -n "$review_artifact" ]]; then
		printf 'What upstream actually changed in those files is stored at `%s`.' "$review_artifact"
		printf ' Review it, port anything this fork still needs, then delete the patch'
		printf ' before marking the pull request ready.\n\n'
	fi
	printf 'CGO-free driver and GORM tests: **%s**.\n' "$test_summary"
} >"$pr_body"

bundle_sync_branch
pr_draft=0
if [[ $test_summary == failed || -n "$review_artifact" ]]; then
	pr_draft=1
fi
record_plan pr 1 "$pr_draft"

if [[ $sync_phase == all ]]; then
	run_publish_phase
fi

#!/bin/sh

test_description="git-grep performance in various modes"

. ./perf-lib.sh

test_perf_large_repo
test_checkout_worktree

test_expect_success 'select a tracked file' '
	tracked_file=$(git ls-files | sed -n 1p) &&
	test -n "$tracked_file" &&
	test_export tracked_file
'

test_perf 'grep --cached, fixed string in one file' '
	git grep --cached --quiet -F some_nonexistent_string \
		-- "$tracked_file" || :
'

grep_pattern="__git_perf_absent_$$"
test_export grep_pattern

test_perf 'grep worktree, cheap regex' '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep "$grep_pattern"
'
test_perf 'grep worktree, cheap regex, 1 thread' '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep --threads=1 "$grep_pattern"
'
test_perf 'grep worktree, cheap regex, 8 threads' --prereq PTHREADS '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep --threads=8 "$grep_pattern"
'
test_perf 'grep worktree, expensive regex' '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep "^.* *$grep_pattern$"
'
test_perf 'grep --cached, cheap regex' '
	test_expect_code 1 git grep --cached "$grep_pattern"
'
test_perf 'grep --cached, expensive regex' '
	test_expect_code 1 git grep --cached "^.* *$grep_pattern$"
'

test_expect_success 'setup fsmonitor' '
	hooks=$(git rev-parse --git-path hooks) &&
	mkdir -p "$hooks" &&
	write_script "$hooks/fsmonitor-empty" <<-\EOF &&
	printf "last_update_token\0"
	EOF
	git config core.fsmonitor "$hooks/fsmonitor-empty" &&
	git config grep.worktreeBlobCache true &&
	git update-index --fsmonitor &&
	git status --porcelain >/dev/null &&
	worktree_cache=$(git rev-parse --git-path index).grep-worktree &&
	rm -f "$worktree_cache" worktree-cache-trace &&
	test_expect_code 1 "$MODERN_GIT" grep --threads=1 \
		"$grep_pattern" >/dev/null &&
	test_path_is_file "$worktree_cache" &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/worktree-cache-trace" \
		"$MODERN_GIT" grep --threads=1 "$grep_pattern" >/dev/null &&
	test_grep \
		"\"key\":\"worktree_blob/hits\",\"value\":\"[1-9][0-9]*\"" \
		worktree-cache-trace &&
	rm -f "$worktree_cache" worktree-cache-trace &&
	test_export worktree_cache
'

test_perf 'grep worktree cache, first scan' \
	--setup 'rm -f "$worktree_cache"' '
	test_expect_code 1 git grep --threads=1 "$grep_pattern"
'

test_perf 'grep worktree cache, first scan, 8 threads' \
	--prereq PTHREADS --setup 'rm -f "$worktree_cache"' '
	test_expect_code 1 git grep --threads=8 "$grep_pattern"
'

test_perf 'grep worktree cache, second scan, 1 thread' \
	--setup '
		rm -f "$worktree_cache" &&
		test_expect_code 1 git grep --threads=1 \
			"$grep_pattern" >/dev/null
	' '
	test_expect_code 1 git grep --threads=1 "$grep_pattern"
'

test_perf 'grep worktree cache, second scan, 8 threads' \
	--prereq PTHREADS --setup '
		rm -f "$worktree_cache" &&
		test_expect_code 1 git grep --threads=1 \
			"$grep_pattern" >/dev/null
	' '
	test_expect_code 1 git grep --threads=8 "$grep_pattern"
'

test_expect_success 'setup threaded --quiet fixture' '
	"$MODERN_GIT" init -q quiet &&
	hit=$(printf "threaded-quiet-hit\n" |
		"$MODERN_GIT" -C quiet hash-object -w --stdin) &&
	miss=$(printf "threaded-quiet-miss\n" |
		"$MODERN_GIT" -C quiet hash-object -w --stdin) &&
	{
		printf "100644 %s\t!00000-hit.txt\n" "$hit" &&
		test_seq -f "100644 $miss\tfile%05g.txt" 1 50000
	} | "$MODERN_GIT" -C quiet update-index --index-info
'

test_perf 'grep --cached, threaded early --quiet hit' \
	--prereq PTHREADS '
	git -C quiet grep --cached --threads=8 --fixed-strings --quiet \
		threaded-quiet-hit
'

test_perf 'grep --cached, threaded --quiet miss' --prereq PTHREADS '
	test_must_fail git -C quiet grep --cached --threads=8 \
		--fixed-strings --quiet threaded-quiet-absent
'

test_done

#!/bin/sh

test_description="git-grep performance in various modes"

. ./perf-lib.sh

test_perf_large_repo
test_checkout_worktree

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
	git config index.skipHash true &&
	git config grep.worktreeBlobCache auto &&
	git update-index --force-write-index &&
	git update-index --fsmonitor &&
	git status --porcelain >/dev/null &&
	worktree_cache=$(git rev-parse --git-path index).grep-worktree &&
	auto_min_bytes=1048576 &&
	GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=$auto_min_bytes &&
	rm -f "$worktree_cache" worktree-cache-trace &&
	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=$auto_min_bytes \
		"$MODERN_GIT" grep --threads=1 "$grep_pattern" >/dev/null &&
	test_path_is_file "$worktree_cache" &&
	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=$auto_min_bytes \
		GIT_TRACE2_EVENT="$PWD/worktree-cache-trace" \
		"$MODERN_GIT" grep --threads=1 "$grep_pattern" >/dev/null &&
	test_grep \
		"\"key\":\"worktree_blob/hits\",\"value\":\"[1-9][0-9]*\"" \
		worktree-cache-trace &&
	rm -f "$worktree_cache" worktree-cache-trace &&
	test_export worktree_cache \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES
'

test_perf 'grep worktree, auto 1 MiB threshold, first scan' \
	--setup 'rm -f "$worktree_cache"' '
	test_expect_code 1 git grep --threads=1 "$grep_pattern"
'

test_perf 'grep worktree, auto 1 MiB threshold, first scan, 8 threads' \
	--prereq PTHREADS --setup 'rm -f "$worktree_cache"' '
	test_expect_code 1 git grep --threads=8 "$grep_pattern"
'

test_perf 'grep worktree, auto 1 MiB threshold, second scan, 1 thread' \
	--setup '
		rm -f "$worktree_cache" &&
		test_expect_code 1 git grep --threads=1 \
			"$grep_pattern" >/dev/null
	' '
	test_expect_code 1 git grep --threads=1 "$grep_pattern"
'

test_perf 'grep worktree, auto 1 MiB threshold, second scan, 8 threads' \
	--prereq PTHREADS --setup '
		rm -f "$worktree_cache" &&
		test_expect_code 1 git grep --threads=1 \
			"$grep_pattern" >/dev/null
	' '
	test_expect_code 1 git grep --threads=8 "$grep_pattern"
'

test_done

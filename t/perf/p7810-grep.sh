#!/bin/sh

test_description="git-grep performance in various modes"

. ./perf-lib.sh

test_perf_large_repo
test_checkout_worktree

test_perf 'grep worktree, cheap regex' '
	git grep some_nonexistent_string || :
'
test_perf 'grep worktree, expensive regex' '
	git grep "^.* *some_nonexistent_string$" || :
'
test_perf 'grep --cached, cheap regex' '
	git grep --cached some_nonexistent_string || :
'
test_perf 'grep --cached, expensive regex' '
	git grep --cached "^.* *some_nonexistent_string$" || :
'

test_perf_fresh_repo repeated

test_expect_success 'setup repeated revision grep' '
	test_seq 1 131072 >repeated/shared &&
	git -C repeated add shared &&
	git -C repeated commit -m base &&
	test_commit_bulk -C repeated --filename=other \
		--contents=unchanged --notick 256 &&
	git -C repeated rev-list --max-count=256 HEAD >repeated-revisions
'

test_perf 'grep repeated revisions, no match, 1 thread' '
	git -C repeated grep --threads=1 not-in-shared \
		$(cat repeated-revisions) -- shared >/dev/null || :
'

test_perf 'grep repeated revisions, no match, 8 threads' \
	--prereq PTHREADS '
	git -C repeated grep --threads=8 not-in-shared \
		$(cat repeated-revisions) -- shared >/dev/null || :
'

test_perf 'grep repeated revisions, matching, 1 thread' '
	git -C repeated grep --threads=1 131072 \
		$(cat repeated-revisions) -- shared >/dev/null
'

test_done

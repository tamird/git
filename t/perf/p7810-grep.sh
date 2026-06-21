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

test_done

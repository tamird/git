#!/bin/sh

test_description='Tests indexed pickaxe performance'
. ./perf-lib.sh

if ! test_have_prereq FSMONITOR_DAEMON
then
	skip_all='fsmonitor--daemon is not supported on this platform'
	test_done
fi

test_perf_fresh_repo

test_expect_success 'setup indexed history' '
	git commit --allow-empty -m base &&
	test_commit_bulk --filename=indexed-%s --notick 256 &&
	git grep-index --no-progress &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	test_atexit "test_might_fail git fsmonitor--daemon stop" &&
	test_expect_code 1 git grep --cached \
		__git_perf_absent_pickaxe__ >/dev/null
'

# Force activation to isolate repeated small-batch backend overhead.
test_perf 'pickaxe across small diff queues' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --no-renames --format=%H \
		-S__git_perf_absent_pickaxe__ HEAD~256..HEAD -- >/dev/null
'

test_perf 'regex pickaxe across small diff queues' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --no-renames --format=%H --pickaxe-regex \
		-S"__git_perf_absent_[p]ickaxe__" \
		HEAD~256..HEAD -- >/dev/null
'

test_perf 'diff grep across small diff queues' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --no-renames --format=%H \
		-G"__git_perf_absent_[p]ickaxe__" \
		HEAD~256..HEAD -- >/dev/null
'

test_perf 'possible diff grep across small diff queues' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --no-renames --format=%H -G"content" \
		HEAD~256..HEAD -- >/dev/null
'

test_expect_success 'stop fsmonitor daemon' '
	git fsmonitor--daemon stop
'

test_done

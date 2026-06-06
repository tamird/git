#!/bin/sh

test_description='git blame performance'
. ./perf-lib.sh

test_perf_fresh_repo

test_expect_success 'setup history with unchanged spans' '
	echo base >target &&
	git add target &&
	git commit -m base &&
	for block in $(test_seq 1 64)
	do
		test_commit_bulk --filename=unrelated --notick 1024 &&
		echo "$block" >>target &&
		git add target &&
		git commit -m "target $block" || return 1
	done &&
	test_commit_bulk --filename=unrelated --notick 1024 &&
	git commit-graph write --reachable --changed-paths
'

test_perf 'blame across unchanged first-parent spans' '
	for i in $(test_seq 1 3)
	do
		git blame target >/dev/null || return 1
	done
'

test_done

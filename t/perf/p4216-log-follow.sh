#!/bin/sh

test_description='Tests log --follow performance'
. ./perf-lib.sh

test_perf_fresh_repo

test_expect_success 'setup merge-heavy history' '
	echo base >tracked-0 &&
	git add tracked-0 &&
	git commit -m base &&

	for block in 0 1 2 3 4 5 6 7
	do
		for branch in 0 1 2 3
		do
			side=side-$block-$branch &&
			git branch "$side" &&
			test_commit_bulk --ref="refs/heads/$side" \
				--filename=unrelated --notick 2048 &&
			git merge -s ours --no-commit --no-ff "$side" &&
			echo "$side" >>merge-marker &&
			git add merge-marker &&
			git commit -m "merge $side" &&
			git branch -d "$side" || return 1
		done &&
		next=$((block + 1)) &&
		git mv "tracked-$block" "tracked-$next" &&
		git commit -m "rename $block"
	done &&

	git commit-graph write --reachable --changed-paths
'

test_perf 'git log --follow (20 runs)' '
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
	do
		git log --format=%H --follow -- tracked-8 >/dev/null ||
		return 1
	done
'

test_done

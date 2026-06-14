#!/bin/sh

test_description='performance of range-diff'
. ./perf-lib.sh

test_perf_fresh_repo

commit_count=500

test_expect_success 'setup' '
	test_commit_bulk --ref=refs/heads/base --id=base 1 &&
	git branch many base &&
	git branch one base &&
	test_commit_bulk --ref=refs/heads/many --id=old $commit_count &&
	test_commit_bulk --ref=refs/heads/one \
		--start=$((commit_count / 2)) \
		--message="new %s" \
		--filename="old-%s.t" \
		--contents="old changed %s" 1
'

test_perf 'one patch against many patches' '
	git range-diff --no-color --no-patch \
		base..many base..one >/dev/null
'

test_done

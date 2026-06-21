#!/bin/sh

test_description='Performance of log --follow with changed-path Bloom filters'
. ./perf-lib.sh

test_perf_fresh_repo

test_expect_success 'setup' '
	echo base >old &&
	echo base >unrelated &&
	git add old unrelated &&
	git commit -m base &&
	test_commit_bulk --notick --filename=unrelated \
		--contents="before rename %s" 20000 &&
	git mv old new &&
	echo rename >unrelated &&
	git add unrelated &&
	git commit -m rename &&
	test_commit_bulk --notick --start=20001 --filename=unrelated \
		--contents="after rename %s" 20000 &&
	git commit-graph write --reachable --changed-paths
'

test_perf 'log --follow through unchanged history' '
	git log --format=%H --follow -- new >/dev/null
'

test_perf 'log --follow with path changed in every commit' '
	git log --format=%H --follow -- unrelated >/dev/null
'

test_done

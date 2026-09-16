#!/bin/sh
#
# Copyright (c) 2007 Andy Parkins
#

test_description='for-each-ref test'

. ./test-lib.sh

test_lazy_prereq ODB_MONOTONIC_CLOCK '
	test-tool trace2 012monotonic_clock
'

test_expect_success "for-each-ref does not crash with -h" '
	git for-each-ref -h >usage &&
	test_grep "[Uu]sage: git for-each-ref " usage &&
	nongit git for-each-ref -h >usage &&
	test_grep "[Uu]sage: git for-each-ref " usage
'

. "$TEST_DIRECTORY"/for-each-ref-tests.sh

test_expect_success ODB_MONOTONIC_CLOCK 'preload samples packed MIDX lookups' '
	test_when_finished "rm -rf packed-graph-repo" &&
	git init packed-graph-repo &&
	(
		cd packed-graph-repo &&
		test_commit first &&
		test_commit second &&
		git branch -m current &&
		git branch earlier HEAD^ &&
		git commit-graph write --reachable &&
		git repack -ad &&
		git multi-pack-index write &&
		cat >expect <<-\EOF &&
		refs/heads/earlier
		refs/heads/current
		EOF
		GIT_TRACE2_EVENT="$PWD/preload.trace" \
			git for-each-ref --sort=committerdate \
			--format="%(refname)" refs/heads >actual &&
		test_cmp expect actual &&
		test_trace2_data ref-filter \
			object_metadata/preload/graph-hits 2 <preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-lookup-selected-checks-total 2 \
			<preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-attempts-total 2 \
			<preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-midx-searches-total 2 \
			<preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-midx-resolves-total 2 \
			<preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-fallbacks-total 0 \
			<preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-invalid-total 0 \
			<preload.trace &&
		test_trace2_data ref-filter \
			object_metadata/preload/packed-attempt-us-total \
			"[0-9][0-9]*" <preload.trace
	)
'

test_done

#!/bin/sh

test_description='Tests performance of reading a split index'

. ./perf-lib.sh

test_perf_fresh_repo interleaved
test_perf_fresh_repo append-only

test_expect_success 'setup' '
	empty=$(git -C interleaved hash-object -w --stdin </dev/null) &&
	git -C append-only hash-object -w --stdin </dev/null >/dev/null &&
	test_seq 0 99999 |
	awk -v oid="$empty" \
		"{ printf \"100644 %s 0\\tfiles/%06d\\n\", oid, \$1 * 2 }" |
	tee base |
	git -C interleaved update-index --index-info &&
	git -C append-only update-index --index-info <base &&
	git -C interleaved config splitIndex.maxPercentChange 100 &&
	git -C append-only config splitIndex.maxPercentChange 100 &&
	git -C interleaved update-index --split-index &&
	git -C append-only update-index --split-index &&
	test_seq 0 49999 |
	awk -v oid="$empty" \
		"{ printf \"100644 %s 0\\tfiles/%06d\\n\", oid, \$1 * 2 + 1 }" |
	git -C interleaved update-index --index-info &&
	test_seq 0 49999 |
	awk -v oid="$empty" \
		"{ printf \"100644 %s 0\\tfiles/%06d\\n\", oid, \$1 + 200000 }" |
	git -C append-only update-index --index-info
'

test_perf 'read split index with interleaved additions' '
	git -C interleaved ls-files >/dev/null
'

test_perf 'read split index with append-only additions' '
	git -C append-only ls-files >/dev/null
'

test_done

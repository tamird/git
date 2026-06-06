#!/bin/sh

test_description='Tests performance of reading a split index'

. ./perf-lib.sh

test_expect_success 'setup' '
	test_create_repo repo &&
	(
		cd repo &&
		empty=$(git hash-object -w --stdin </dev/null) &&
		test_seq 0 99999 |
		awk -v oid="$empty" \
			"{ printf \"100644 %s 0\\tfiles/%06d\\n\", oid, \$1 * 2 }" |
		git update-index --index-info &&
		git config splitIndex.maxPercentChange 100 &&
		git update-index --split-index &&
		test_seq 0 49999 |
		awk -v oid="$empty" \
			"{ printf \"100644 %s 0\\tfiles/%06d\\n\", oid, \$1 * 2 + 1 }" |
		git update-index --index-info
	)
'

test_perf 'read split index with many additions' '
	git -C repo ls-files >/dev/null
'

test_done

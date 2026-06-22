#!/bin/sh

test_description='Test worktree diff output performance'

. ./perf-lib.sh

test_perf_fresh_repo

test_expect_success 'setup' '
	git config filter.expensive.clean "tr 0 0 | tr 1 1" &&
	echo "filtered filter=expensive" >.gitattributes &&
	test_seq 1 500000 >large &&
	cp large filtered &&
	test_seq 1 5000000 >threshold &&
	git add . &&
	git commit -q -m base &&
	echo changed >>large &&
	echo changed >>filtered &&
	echo changed >>threshold
'

for output in stat check
do
	test_perf "large file, --$output" "
		git diff --$output -- large >/dev/null
	"

	test_perf "expensive clean filter, --$output" "
		git diff --$output -- filtered >/dev/null
	"
done

test_perf 'big file threshold, --stat' '
	git -c core.bigFileThreshold=1 diff --stat -- threshold >/dev/null
'

test_done

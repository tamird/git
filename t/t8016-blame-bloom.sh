#!/bin/sh

test_description='git blame with changed-path Bloom filters'
GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

GIT_TEST_COMMIT_GRAPH=0
GIT_TEST_COMMIT_GRAPH_CHANGED_PATHS=0

sane_unset GIT_TRACE2 GIT_TRACE2_PERF GIT_TRACE2_EVENT
sane_unset GIT_TRACE2_PERF_BRIEF
sane_unset GIT_TRACE2_CONFIG_PARAMS

check_blame () {
	repo=$1 &&
	shift &&
	rm -f "$TRASH_DIRECTORY/trace.perf" &&
	git -C "$repo" -c core.commitGraph=false blame "$@" >expect &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.perf" \
		git -C "$repo" -c core.commitGraph=true blame "$@" >actual &&
	test_cmp expect actual &&
	test_grep "bloom/response-no:[1-9]" \
		"$TRASH_DIRECTORY/trace.perf"
}

test_expect_success 'blame follows renames across unchanged commits' '
	git init rename &&
	test_commit -C rename base old line &&
	test_commit -C rename before unrelated before &&
	git -C rename mv old new &&
	git -C rename commit -m rename &&
	test_commit -C rename after unrelated after &&
	git -C rename commit-graph write --reachable --changed-paths &&

	check_blame rename --porcelain new &&
	base=$(git -C rename rev-parse base) &&
	test_grep "^$base " actual &&
	test_grep "^filename old$" actual
'

test_expect_success 'blame handles ignored revisions' '
	git init ignore &&
	test_write_lines line1 line2 >ignore/file &&
	git -C ignore add file &&
	git -C ignore commit -m base &&
	git -C ignore tag base &&
	test_commit -C ignore before unrelated before &&
	sed "s/line1/line-one/" ignore/file >ignore/file.tmp &&
	mv ignore/file.tmp ignore/file &&
	git -C ignore add file &&
	git -C ignore commit -m ignored &&
	git -C ignore tag ignored &&
	test_commit -C ignore after unrelated after &&
	git -C ignore commit-graph write --reachable --changed-paths &&

	check_blame ignore --line-porcelain --ignore-rev ignored file &&
	base=$(git -C ignore rev-parse base) &&
	sed -n "1s/ .*//p" actual >actual.commit &&
	echo "$base" >expect.commit &&
	test_cmp expect.commit actual.commit
'

test_expect_success 'blame follows the first parent of an unchanged merge' '
	git init merge &&
	test_commit -C merge base file line &&
	git -C merge checkout -b side &&
	test_commit -C merge side file changed &&
	git -C merge checkout main &&
	test_commit -C merge main unrelated main &&
	git -C merge merge -s ours -m merge side &&
	test_commit -C merge after unrelated after &&
	git -C merge commit-graph write --reachable --changed-paths &&

	check_blame merge --porcelain file &&
	base=$(git -C merge rev-parse base) &&
	test_grep "^$base " actual
'

test_expect_success 'blame stops at revision boundaries' '
	git init boundary &&
	test_commit -C boundary base file line &&
	test_commit -C boundary boundary unrelated boundary &&
	test_commit -C boundary one unrelated one &&
	test_commit -C boundary two unrelated two &&
	git -C boundary commit-graph write --reachable --changed-paths &&

	check_blame boundary --porcelain boundary..HEAD -- file &&
	boundary=$(git -C boundary rev-parse boundary) &&
	test_grep "^$boundary " actual &&
	test_grep "^boundary$" actual
'

test_expect_success 'blame stops at age boundaries' '
	git init age &&
	test_commit -C age base file line &&
	test_commit -C age old unrelated old &&
	old_date=$(git -C age show -s --format=%ct old) &&
	test_commit -C age one unrelated one &&
	test_commit -C age two unrelated two &&
	git -C age commit-graph write --reachable --changed-paths &&

	cutoff=$((old_date + 1)) &&
	check_blame age --porcelain --since="@$cutoff" file &&
	old=$(git -C age rev-parse old) &&
	test_grep "^$old " actual &&
	test_grep "^boundary$" actual
'

test_expect_success 'blame converges collapsed branch histories' '
	git init converge &&
	test_write_lines line1 line2 line3 line4 >converge/file &&
	git -C converge add file &&
	git -C converge commit -m base &&
	git -C converge tag base &&

	git -C converge checkout -b left &&
	sed "s/line1/line-one/" converge/file >converge/file.tmp &&
	mv converge/file.tmp converge/file &&
	git -C converge add file &&
	git -C converge commit -m left &&
	git -C converge tag left-change &&
	test_commit -C converge left-gap left-unrelated gap &&

	git -C converge checkout -b right base &&
	sed "s/line4/line-four/" converge/file >converge/file.tmp &&
	mv converge/file.tmp converge/file &&
	git -C converge add file &&
	git -C converge commit -m right &&
	git -C converge tag right-change &&
	test_commit -C converge right-gap right-unrelated gap &&

	git -C converge checkout left &&
	git -C converge merge -m merge right &&
	test_commit -C converge after after-unrelated after &&
	git -C converge commit-graph write --reachable --changed-paths &&

	check_blame converge --line-porcelain \
		--ignore-rev left-change --ignore-rev right-change file &&
	sed -n "s/^\\([0-9a-f][0-9a-f]*\\) .*/\\1/p" actual |
		sort -u >actual.commits &&
	git -C converge rev-parse base >expect.commits &&
	test_cmp expect.commits actual.commits &&

	check_blame converge --incremental \
		--ignore-rev left-change --ignore-rev right-change file
'

test_done

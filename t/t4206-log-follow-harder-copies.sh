#!/bin/sh
#
# Copyright (c) 2010 Bo Yang
#

test_description='Test --follow should always find copies hard in git log.

'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-diff.sh

test_follow_full_tree_trace () {
	full_tree_trace="$1"
	test "$(grep -c '"event":"timer".*"category":"diff","name":"follow-pickaxe/tree-paths",' "$full_tree_trace")" = 1 &&
	full_tree_intervals=$(sed -n \
		's/.*"event":"timer".*"category":"diff","name":"follow-pickaxe\/tree-paths","intervals":\([0-9][0-9]*\),.*/\1/p' \
		"$full_tree_trace") &&
	test "$full_tree_intervals" -ge 2 || return 1

	# The first new assertion follows the existing output and timer checks.
	test_trace2_data diff follow-full-tree/count 1 <"$full_tree_trace" &&
	test_trace2_data diff follow-full-tree-us "[0-9][0-9]*" <"$full_tree_trace" &&
	test_trace2_data diff follow-full-tree-max-us "[0-9][0-9]*" <"$full_tree_trace" &&
	test "$(grep -c '"key":"follow-full-tree' "$full_tree_trace")" = 3 &&
	test "$(grep -c '"event":"data".*"thread":"main".*"nesting":1,"category":"diff","key":"follow-full-tree' "$full_tree_trace")" = 3 &&
	test "$(grep -c '"event":"timer".*"category":"diff","name":"follow-full-tree",' "$full_tree_trace")" = 1 &&
	test_grep '"event":"timer".*"category":"diff","name":"follow-full-tree","intervals":1,' "$full_tree_trace" &&
	test_grep ! '"event":"th_timer".*"category":"diff","name":"follow-full-tree"' "$full_tree_trace" &&
	test_grep ! '"event":"region_[^"]*".*"category":"diff","label":"follow-full-tree"' "$full_tree_trace" || return 1

	full_tree_us=$(sed -n \
		's/.*"key":"follow-full-tree-us","value":"\([0-9][0-9]*\)".*/\1/p' \
		"$full_tree_trace") &&
	full_tree_max_us=$(sed -n \
		's/.*"key":"follow-full-tree-max-us","value":"\([0-9][0-9]*\)".*/\1/p' \
		"$full_tree_trace") &&
	test "$full_tree_us" = "$full_tree_max_us" || return 1

	full_tree_seconds=$(sed -n \
		's/.*"event":"timer".*"category":"diff","name":"follow-full-tree",.*"t_total":\([0-9][0-9]*\.[0-9][0-9]*\),.*/\1/p' \
		"$full_tree_trace") &&
	test -n "$full_tree_seconds" &&
	full_tree_rounded_us=$(awk -v seconds="$full_tree_seconds" \
		'BEGIN { printf "%.0f\n", seconds * 1000000 }') &&
	test "$full_tree_us" -le "$full_tree_rounded_us" &&
	test "$full_tree_rounded_us" -le "$((full_tree_us + 1))"
}

echo >path0 'Line 1
Line 2
Line 3
'

test_expect_success 'add a file path0 and commit.' '
	git add path0 &&
	git commit -m "Add path0"
'

echo >path0 'New line 1
New line 2
New line 3
'
test_expect_success 'Change path0.' '
	git add path0 &&
	git commit -m "Change path0"
'

cat <path0 >path1
test_expect_success 'copy path0 to path1.' '
	git add path1 &&
	git commit -m "Copy path1 from path0"
'

test_expect_success 'find the copy path0 -> path1 harder' '
	git log --follow --name-status --pretty="format:%s"  path1 > current
'

cat >expected <<\EOF
Copy path1 from path0
C100	path0	path1

Change path0
M	path0

Add path0
A	path0
EOF

test_expect_success 'validate the output.' '
	compare_diff_patch current expected
'

test_expect_success 'metadata-only final --follow commit skips harder copy detection' '
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	printf "%s\n" "Copy path1 from path0" >expect &&
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/follow-final-explicit.event" \
		git log --follow --format=%s -n1 -- path1 >actual &&
	test_cmp expect actual &&
	test_region ! diff "exact renames" \
		"$TRASH_DIRECTORY/follow-final-explicit.event" &&
	test_grep ! follow-full-tree \
		"$TRASH_DIRECTORY/follow-final-explicit.event"
'

test_expect_success 'implicit follow skips harder copy detection for final commit' '
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	printf "%s\n" "Copy path1 from path0" >expect &&
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/follow-final-implicit.event" \
		git -c log.follow=true log --format=%s -n1 -- path1 >actual &&
	test_cmp expect actual &&
	test_region ! diff "exact renames" \
		"$TRASH_DIRECTORY/follow-final-implicit.event" &&
	test_grep ! follow-full-tree \
		"$TRASH_DIRECTORY/follow-final-implicit.event"
'

test_expect_success 'following a second commit still detects the harder copy' '
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	printf "%s\n" "Copy path1 from path0" "Change path0" >expect &&
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/follow-more.event" \
		git log --follow --format=%s -n2 -- path1 >actual &&
	test_cmp expect actual &&
	test_region diff "exact renames" "$TRASH_DIRECTORY/follow-more.event" &&
	test_follow_full_tree_trace "$TRASH_DIRECTORY/follow-more.event"
'

test_expect_success 'visible final copy still reports its harder-copy status' '
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	printf "%s\n\n" "Copy path1 from path0" >expect &&
	printf "C100\tpath0\tpath1\n" >>expect &&
	GIT_TRACE2_EVENT="$TRASH_DIRECTORY/follow-final-visible.event" \
		git log --follow --name-status --format=%s -n1 -- path1 >actual &&
	test_cmp expect actual &&
	test_follow_full_tree_trace "$TRASH_DIRECTORY/follow-final-visible.event"
'

test_expect_success 'log --follow -B does not BUG' '
	git switch --orphan break_and_follow_are_icky_so_use_both &&

	test_seq 1 127 >numbers &&
	git add numbers &&
	git commit -m "numbers" &&

	printf "%s\n" A B C D E F G H I J K L M N O Q R S T U V W X Y Z >pool &&
	echo changed >numbers &&
	git add pool numbers &&
	git commit -m "pool" &&

	git log -1 -B --raw --follow -- "p*"
'

test_expect_success 'log --follow -B does not die or use uninitialized memory' '
	printf "%s\n" A B C D E F G H I J K L M N O P Q R S T U V W X Y Z >z &&
	git add z &&
	git commit -m "Initial" &&

	test_seq 1 130 >z &&
	echo lame >somefile &&
	git add z somefile &&
	git commit -m "Rewrite z, introduce lame somefile" &&

	echo Content >somefile &&
	git add somefile &&
	git commit -m "Rewrite somefile" &&

	git log -B --follow somefile
'

test_done

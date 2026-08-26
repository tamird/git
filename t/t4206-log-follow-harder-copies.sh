#!/bin/sh
#
# Copyright (c) 2010 Bo Yang
#

test_description='Test --follow should always find copies hard in git log.

'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-diff.sh

test_follow_additions_trace () {
	follow_additions_trace="$1"
	follow_additions_expected="$2"
	follow_additions_completed="$3"

	test_trace2_data diff follow-full-tree/eligible-additions \
		"$follow_additions_expected" <"$follow_additions_trace" &&
	test_trace2_data diff follow-full-tree/count \
		"$follow_additions_completed" <"$follow_additions_trace" &&
	test "$(grep -c '"key":"follow-full-tree/eligible-additions"' "$follow_additions_trace")" = 1 &&
	test_grep "\"event\":\"data\".*\"thread\":\"main\".*\"nesting\":1,\"category\":\"diff\",\"key\":\"follow-full-tree/eligible-additions\",\"value\":\"$follow_additions_expected\"" "$follow_additions_trace" &&
	test "$(grep -c '"event":"counter".*"category":"diff","name":"follow-full-tree/completed",' "$follow_additions_trace")" = 1 &&
	test_grep "\"event\":\"counter\".*\"category\":\"diff\",\"name\":\"follow-full-tree/completed\",\"count\":$follow_additions_completed}" "$follow_additions_trace" &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"follow-full-tree\",\"intervals\":$follow_additions_completed," "$follow_additions_trace" &&
	test_grep ! '"event":"th_counter".*"category":"diff","name":"follow-full-tree/' "$follow_additions_trace" &&
	test_grep ! '"key":"follow-full-tree/completed"' "$follow_additions_trace" || return 1

	if test "$follow_additions_expected" = 0
	then
		test_grep ! '"event":"counter".*"category":"diff","name":"follow-full-tree/eligible-additions",' "$follow_additions_trace"
	else
		test "$(grep -c '"event":"counter".*"category":"diff","name":"follow-full-tree/eligible-additions",' "$follow_additions_trace")" = 1 &&
		test_grep "\"event\":\"counter\".*\"category\":\"diff\",\"name\":\"follow-full-tree/eligible-additions\",\"count\":$follow_additions_expected}" "$follow_additions_trace"
	fi
}

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
	test_follow_additions_trace "$full_tree_trace" 0 1 &&
	test "$(grep -c '"key":"follow-full-tree' "$full_tree_trace")" = 4 &&
	test "$(grep -c '"event":"data".*"thread":"main".*"nesting":1,"category":"diff","key":"follow-full-tree' "$full_tree_trace")" = 4 &&
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

test_expect_success 'follow harder copies reads an unchanged subtree once' '
	test_create_repo follow-shared-subtree &&
	(
		cd follow-shared-subtree &&
		mkdir shared &&
		echo unrelated >shared/aaa &&
		echo content >shared/source &&
		git add shared &&
		test_tick &&
		git commit -m source &&
		cp shared/source destination &&
		git add destination &&
		test_tick &&
		git commit -m copy &&

		shared_tree=$(git rev-parse HEAD:shared) &&
		parent_shared_tree=$(git rev-parse HEAD^:shared) &&
		test "$shared_tree" = "$parent_shared_tree" &&
		git repack -a -d -f --window=0 &&
		set -- .git/objects/pack/*.idx &&
		test "$#" = 1 &&
		test_path_is_file "$1" &&
		pack_index=$1 &&
		pack_stem=${pack_index##*/} &&
		pack_stem=${pack_stem%.idx} &&
		git show-index <"$pack_index" >pack-index &&
		awk -v oid="$shared_tree" '\''$2 == oid { print $1 }'\'' \
			pack-index >shared-offset &&
		test_line_count = 1 shared-offset &&
		shared_offset=$(cat shared-offset) &&
		git verify-pack -v "$pack_index" >pack-verify &&
		test_grep "^$shared_tree tree[[:space:]][[:space:]]*[0-9][0-9]* [0-9][0-9]* $shared_offset$" \
			pack-verify &&
		awk "NF == 7 { print }" pack-verify >delta-objects &&
		test_must_be_empty delta-objects &&

		printf "%s\n" copy source >expect &&
		git log --follow --format=%s -- destination >actual &&
		test_cmp expect actual &&
		printf "%s\n\n" copy >expect &&
		printf "C100\tshared/source\tdestination\n" >>expect &&
		sane_unset GIT_TRACE2_EVENT_NESTING &&
		GIT_TRACE2_EVENT="$PWD/follow.event" \
		GIT_TRACE_PACK_ACCESS="$PWD/pack-access" \
			git log --follow --name-status --format=%s -n1 \
				-- destination >actual &&
		test_cmp expect actual &&
		test_follow_full_tree_trace "$PWD/follow.event" &&
		grep "/$pack_stem[.]pack $shared_offset$" pack-access >shared-access &&
		test_line_count = 1 shared-access
	)
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

test_expect_success 'follow counts eligible additions across completed full-tree walks' '
	test_create_repo follow-eligible-additions &&
	(
		cd follow-eligible-additions &&
		echo content >source &&
		git add source &&
		test_tick &&
		git commit -m source &&

		git mv source middle &&
		mkdir first-noise &&
		echo one >first-noise/one &&
		echo two >first-noise/two &&
		git add first-noise &&
		test_tick &&
		git commit -m first &&

		git mv middle destination &&
		mkdir second-noise &&
		echo three >second-noise/three &&
		echo four >second-noise/four &&
		echo five >second-noise/five &&
		git add second-noise &&
		test_tick &&
		git commit -m second &&

		cat >expect <<-\EOF &&
		second

		R100	middle	destination
		first

		R100	source	middle
		EOF
		git log --follow --name-status --format=%s -n2 -- destination \
			>actual 2>err &&
		test_cmp expect actual &&
		test_must_be_empty err &&
		sane_unset GIT_TRACE2_EVENT_NESTING &&
		GIT_TRACE2_EVENT="$PWD/follow.event" \
			git log --follow --name-status --format=%s -n2 -- destination \
			>actual-traced 2>err-traced &&
		test_cmp actual actual-traced &&
		test_cmp err err-traced &&
		test_trace2_data diff follow-full-tree/count 2 <follow.event &&
		test_grep '\''"event":"timer".*"category":"diff","name":"follow-full-tree","intervals":2,'\'' follow.event &&
		test_trace2_data diff follow-full-tree/eligible-additions 5 <follow.event &&
		test_follow_additions_trace "$PWD/follow.event" 5 2
	)
'

test_expect_success 'follow counts completed walks but excludes additions with -B' '
	(
		cd follow-eligible-additions &&
		git log -B --follow --name-status --format=%s -n2 -- destination \
			>actual-break 2>err-break &&
		test_cmp expect actual-break &&
		test_must_be_empty err-break &&
		GIT_TRACE2_EVENT_NESTING=2 GIT_TRACE2_EVENT="$PWD/break.event" \
			git log -B --follow --name-status --format=%s -n2 -- destination \
			>actual-break-traced 2>err-break-traced &&
		test_cmp actual-break actual-break-traced &&
		test_cmp err-break err-break-traced &&
		test_follow_additions_trace "$PWD/break.event" 0 2
	)
'

test_expect_success 'follow counts completed walks but excludes additions with an orderfile' '
	(
		cd follow-eligible-additions &&
		printf "%s\n" destination middle >order &&
		git -c diff.orderFile=order log --follow --name-status \
			--format=%s -n2 -- destination >actual-order 2>err-order &&
		test_cmp expect actual-order &&
		test_must_be_empty err-order &&
		GIT_TRACE2_EVENT_NESTING=2 GIT_TRACE2_EVENT="$PWD/order.event" \
			git -c diff.orderFile=order log --follow --name-status \
			--format=%s -n2 -- destination \
			>actual-order-traced 2>err-order-traced &&
		test_cmp actual-order actual-order-traced &&
		test_cmp err-order err-order-traced &&
		test_follow_additions_trace "$PWD/order.event" 0 2
	)
'

test_expect_success SYMLINKS 'follow counts added symlinks but not gitlinks or old-side paths' '
	(
		cd follow-eligible-additions &&
		git mv destination final &&
		ln -s unrelated new-symlink &&
		git add new-symlink &&
		gitlink_oid=$(git rev-parse HEAD) &&
		git update-index --add --cacheinfo 160000,$gitlink_oid,new-submodule &&
		git update-index --chmod=+x first-noise/one &&
		echo changed >first-noise/two &&
		git add first-noise/two &&
		git rm second-noise/four &&
		test_tick &&
		git commit -m types &&
		printf "%s\n\n" types >expect-types &&
		printf "R100\tdestination\tfinal\n" >>expect-types &&
		git log --follow --name-status --format=%s -n1 -- final \
			>actual-types 2>err-types &&
		test_cmp expect-types actual-types &&
		test_must_be_empty err-types &&
		GIT_TRACE2_EVENT_NESTING=2 GIT_TRACE2_EVENT="$PWD/types.event" \
			git log --follow --name-status --format=%s -n1 -- final \
			>actual-types-traced 2>err-types-traced &&
		test_cmp actual-types actual-types-traced &&
		test_cmp err-types err-types-traced &&
		test_follow_additions_trace "$PWD/types.event" 1 1
	)
'

test_expect_success 'an incomplete full-tree walk does not publish pending additions' '
	test_create_repo follow-incomplete-additions &&
	(
		cd follow-incomplete-additions &&
		echo content >source &&
		git add source &&
		git ls-tree "$(git write-tree)" >tree-input &&
		printf "040000 tree %s\tzzz\n" "$ZERO_OID" >>tree-input &&
		broken_tree=$(git mktree --missing <tree-input) &&
		test_tick &&
		broken_commit=$(echo broken | git commit-tree "$broken_tree") &&
		git mv source destination &&
		echo unrelated >aaa &&
		git add aaa &&
		test_tick &&
		commit=$(echo copy | git commit-tree "$(git write-tree)" -p "$broken_commit") &&
		git update-ref HEAD "$commit" &&
		test_expect_code 128 git log --follow --name-status \
			--format=%s -n1 -- destination >actual-incomplete 2>err-incomplete &&
		test_grep "unable to read tree ($ZERO_OID)" err-incomplete &&
		GIT_TRACE2_EVENT_NESTING=2 GIT_TRACE2_EVENT="$PWD/incomplete.event" \
			test_expect_code 128 git log --follow --name-status \
			--format=%s -n1 -- destination \
			>actual-incomplete-traced 2>err-incomplete-traced &&
		test_cmp actual-incomplete actual-incomplete-traced &&
		test_cmp err-incomplete err-incomplete-traced &&
		test_grep ! follow-full-tree incomplete.event
	)
'

test_done

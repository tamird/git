#!/bin/sh

test_description='git show'

. ./test-lib.sh

test_show_timers () {
	show_trace=$1 &&
	shift &&
	if test "$#" -eq 0
	then
		test_grep ! "\"event\":\"timer\".*\"category\":\"show\"," \
			"$show_trace" || return 1
	else
		grep "\"event\":\"timer\".*\"category\":\"show\"," \
			"$show_trace" >.git/show-control-timers &&
		test_line_count = "$#" .git/show-control-timers &&
		for show_timer
		do
			test_grep "\"name\":\"$show_timer\",\"intervals\":1," \
				.git/show-control-timers || return 1
		done || return 1
	fi &&
	test_grep ! "\"event\":\"th_timer\".*\"category\":\"show\"," \
		"$show_trace" &&
	test_grep ! "\"event\":\"data\".*\"category\":\"show\"," \
		"$show_trace"
}

test_expect_success setup '
	echo hello world >foo &&
	H=$(git hash-object -w foo) &&
	git tag -a foo-tag -m "Tags $H" $H &&
	HH=$(expr "$H" : "\(..\)") &&
	H38=$(expr "$H" : "..\(.*\)") &&
	rm -f .git/objects/$HH/$H38
'

test_expect_success 'showing a tag that point at a missing object' '
	test_must_fail git --no-pager show foo-tag >actual 2>err &&
	GIT_TRACE2_EVENT="$PWD/.git/show-missing-tag-event" \
	GIT_TRACE2_EVENT_NESTING=2 \
		test_expect_code 255 git --no-pager show foo-tag \
		>actual.traced 2>err.traced &&
	test_cmp actual actual.traced &&
	test_cmp err err.traced &&
	test_show_timers .git/show-missing-tag-event execution setup dispatch
'

test_expect_success 'set up a bit of history' '
	test_commit main1 &&
	test_commit main2 &&
	test_commit main3 &&
	git tag -m "annotated tag" annotated &&
	git checkout -b side HEAD^^ &&
	test_commit side2 &&
	test_commit side3 &&
	test_merge merge main3
'

test_expect_success 'showing two commits' '
	cat >expect <<-EOF &&
	commit $(git rev-parse main2)
	commit $(git rev-parse main3)
	EOF
	git show main2 main3 >actual &&
	grep ^commit actual >actual.filtered &&
	test_cmp expect actual.filtered &&
	GIT_TRACE2_EVENT="$PWD/.git/show-commits-event" \
		git show main2 main3 >actual.traced 2>actual.traced.err &&
	test_cmp actual actual.traced &&
	test_must_be_empty actual.traced.err &&
	grep "\"event\":\"timer\".*\"category\":\"show\"," \
		.git/show-commits-event >.git/show-timers &&
	test_line_count = 3 .git/show-timers &&
	for name in execution setup dispatch
	do
		test_grep "\"name\":\"$name\",\"intervals\":1," \
			.git/show-timers || return 1
	done &&
	test_grep ! "\"event\":\"th_timer\".*\"category\":\"show\"," \
		.git/show-commits-event &&
	test_grep ! "\"event\":\"data\".*\"category\":\"show\"," \
		.git/show-commits-event
'

test_expect_success 'show timers cover object dispatch and revision walks' '
	for show_case in range tree tag blob
	do
		case "$show_case" in
		range) set -- main1..main3 ;;
		tree) set -- main1: ;;
		tag) set -- annotated ;;
		blob) set -- main1:main1.t ;;
		esac &&
		git show "$@" >actual 2>err &&
		GIT_TRACE2_EVENT="$PWD/.git/show-$show_case-event" \
		GIT_TRACE2_EVENT_NESTING=2 \
			git show "$@" >actual.traced 2>err.traced &&
		test_cmp actual actual.traced &&
		test_cmp err err.traced &&
		test_show_timers ".git/show-$show_case-event" \
			execution setup dispatch || return 1
	done
'

test_expect_success 'show timers include normal nonzero returns' '
	test_expect_code 1 git show --exit-code main2 >actual 2>err &&
	GIT_TRACE2_EVENT="$PWD/.git/show-exit-code-event" \
	GIT_TRACE2_EVENT_NESTING=2 \
		test_expect_code 1 git show --exit-code main2 \
		>actual.traced 2>err.traced &&
	test_cmp actual actual.traced &&
	test_cmp err err.traced &&
	test_show_timers .git/show-exit-code-event execution setup dispatch
'

test_expect_success 'showing a tree' '
	cat >expected <<-EOF &&
	tree main1:

	main1.t
	EOF
	git show main1: >actual &&
	test_cmp expected actual
'

test_expect_success 'showing two trees' '
	cat >expected <<-EOF &&
	tree main1^{tree}

	main1.t

	tree main2^{tree}

	main1.t
	main2.t
	EOF
	git show main1^{tree} main2^{tree} >actual &&
	test_cmp expected actual
'

test_expect_success 'showing a trees is not recursive' '
	git worktree add not-recursive main1 &&
	mkdir not-recursive/a &&
	test_commit -C not-recursive a/file &&
	cat >expected <<-EOF &&
	tree HEAD^{tree}

	a/
	main1.t
	EOF
	git -C not-recursive show HEAD^{tree} >actual &&
	test_cmp expected actual
'

test_expect_success 'showing a range walks (linear)' '
	cat >expect <<-EOF &&
	commit $(git rev-parse main3)
	commit $(git rev-parse main2)
	EOF
	git show main1..main3 >actual &&
	grep ^commit actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success 'showing a range walks (Y shape, ^ first)' '
	cat >expect <<-EOF &&
	commit $(git rev-parse main3)
	commit $(git rev-parse main2)
	EOF
	git show ^side3 main3 >actual &&
	grep ^commit actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success 'showing a range walks (Y shape, ^ last)' '
	cat >expect <<-EOF &&
	commit $(git rev-parse main3)
	commit $(git rev-parse main2)
	EOF
	git show main3 ^side3 >actual &&
	grep ^commit actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success 'showing with -N walks' '
	cat >expect <<-EOF &&
	commit $(git rev-parse main3)
	commit $(git rev-parse main2)
	EOF
	git show -2 main3 >actual &&
	grep ^commit actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success 'showing annotated tag' '
	cat >expect <<-EOF &&
	tag annotated
	commit $(git rev-parse annotated^{commit})
	EOF
	git show annotated >actual &&
	grep -E "^(commit|tag)" actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success 'showing annotated tag plus commit' '
	cat >expect <<-EOF &&
	tag annotated
	commit $(git rev-parse annotated^{commit})
	commit $(git rev-parse side3)
	EOF
	git show annotated side3 >actual &&
	grep -E "^(commit|tag)" actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success 'showing range' '
	cat >expect <<-EOF &&
	commit $(git rev-parse main3)
	commit $(git rev-parse main2)
	EOF
	git show ^side3 annotated >actual &&
	grep -E "^(commit|tag)" actual >actual.filtered &&
	test_cmp expect actual.filtered
'

test_expect_success '-s suppresses diff' '
	cat >expect <<-\EOF &&
	merge
	main3
	EOF
	git show -s --format=%s merge main3 >actual &&
	test_cmp expect actual
'

test_expect_success '--quiet suppresses diff' '
	echo main3 >expect &&
	git show --quiet --format=%s main3 >actual &&
	test_cmp expect actual
'

test_expect_success 'no-patch output does not access the tree' '
	cat >commit <<-EOF &&
	tree $(test_oid 001)
	author A U Thor <author@example.com> 1112911993 -0700
	committer A U Thor <author@example.com> 1112911993 -0700

	broken tree
	EOF
	commit=$(git hash-object -t commit -w commit) &&
	echo "broken tree" >expect &&

	git show -s --format=%s $commit >actual &&
	test_cmp expect actual &&
	git show --quiet --format=%s $commit >actual &&
	test_cmp expect actual &&
	test_must_fail git show --no-patch --exit-code --format=%s $commit \
		>actual 2>err &&
	test_must_be_empty actual &&
	test_grep "unable to read tree" err &&
	GIT_TRACE2_EVENT="$PWD/.git/show-broken-tree-event" \
	GIT_TRACE2_EVENT_NESTING=2 \
		test_expect_code 128 git show --no-patch --exit-code --format=%s \
		$commit >actual.traced 2>err.traced &&
	test_cmp actual actual.traced &&
	test_cmp err err.traced &&
	test_show_timers .git/show-broken-tree-event setup &&
	test_must_fail git show $commit
'

test_expect_success 'show --graph is forbidden' '
	test_must_fail git show --graph HEAD >actual 2>err &&
	GIT_TRACE2_EVENT="$PWD/.git/show-graph-event" \
	GIT_TRACE2_EVENT_NESTING=2 \
		test_expect_code 128 git show --graph HEAD \
		>actual.traced 2>err.traced &&
	test_cmp actual actual.traced &&
	test_cmp err err.traced &&
	test_show_timers .git/show-graph-event
'

test_expect_success 'show unmerged index' '
	git reset --hard &&

	git switch -C base &&
	echo "base" >conflicting &&
	git add conflicting &&
	git commit -m "base" &&

	git branch hello &&
	git branch goodbye &&

	git switch hello &&
	echo "hello" >conflicting &&
	git commit -am "hello" &&

	git switch goodbye &&
	echo "goodbye" >conflicting &&
	git commit -am "goodbye" &&

	git switch hello &&
	test_must_fail git merge goodbye &&
	git show --merge HEAD
'

test_done

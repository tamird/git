#!/bin/sh

test_description='Test --follow follows renames across merges'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=master
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

test_expect_success 'setup subtree-merged repository' '
	git init inner &&
	echo inner >inner/inner.txt &&
	git -C inner add inner.txt &&
	git -C inner commit -m "inner init" &&

	git init outer &&
	echo outer >outer/outer.txt &&
	git -C outer add outer.txt &&
	git -C outer commit -m "outer init" &&

	git -C outer fetch ../inner master &&
	git -C outer merge -s ours --no-commit --allow-unrelated-histories \
		FETCH_HEAD &&
	git -C outer read-tree --prefix=inner/ -u FETCH_HEAD &&
	git -C outer commit -m "Merge inner repo into inner/ subdirectory"
'

test_expect_success '--follow finds the pre-merge commit through a subtree merge' '
	test_when_finished "rm -f log-follow-merge.trace" &&
	GIT_TRACE2_EVENT="$PWD/log-follow-merge.trace" \
		git -C outer log --follow --pretty=tformat:%s inner/inner.txt >actual &&
	echo "inner init" >expect &&
	test_cmp expect actual &&
	test "$(grep -c \
		"\"event\":\"timer\".*\"category\":\"log\",\"name\":\"follow-parent\"," \
		log-follow-merge.trace)" = 1 &&
	test_grep \
		"\"event\":\"timer\".*\"category\":\"log\",\"name\":\"follow-parent\",\"intervals\":2," \
		log-follow-merge.trace &&
	test_grep ! \
		"\"event\":\"th_timer\".*\"category\":\"log\",\"name\":\"follow-parent\"" \
		log-follow-merge.trace &&
	test_grep ! \
		"\"event\":\"region_[^\"]*\".*\"category\":\"log\",\"label\":\"follow-parent\"" \
		log-follow-merge.trace
'

test_expect_success 'setup merge of two branches that both renamed a file to README' '
	git init foo &&
	mkdir foo/foo &&
	echo "foo readme" >foo/foo/README &&
	git -C foo add foo/README &&
	git -C foo commit -m "add foo README" &&

	git -C foo mv foo/README README &&
	git -C foo commit -m "promote foo README to toplevel" &&

	echo "foo c" >foo/foo.c &&
	git -C foo add foo.c &&
	git -C foo commit -m "add foo C impl" &&

	git init bar &&
	mkdir bar/bar &&
	echo "bar readme" >bar/bar/README &&
	git -C bar add bar/README &&
	git -C bar commit -m "add bar README" &&

	git -C bar mv bar/README README &&
	git -C bar commit -m "promote bar README to toplevel" &&

	echo "bar c" >bar/bar.c &&
	git -C bar add bar.c &&
	git -C bar commit -m "add bar C impl" &&

	git -C foo fetch ../bar master &&
	git -C foo merge -s ours --no-commit --allow-unrelated-histories \
		FETCH_HEAD &&
	git -C foo checkout FETCH_HEAD -- bar.c &&
	git -C foo commit -m "merge bar into foo"
'

test_expect_success '--follow follows renames across both sides of a merge' '
	git -C foo log --follow --pretty=tformat:%s README >actual &&
	sort actual >actual.sorted &&
	cat >expect <<-\EOF &&
	add bar README
	add foo README
	promote bar README to toplevel
	promote foo README to toplevel
	EOF
	test_cmp expect actual.sorted
'

test_expect_success 'setup diamond with renames on both sides of a fork' '
	git init diamond &&
	test_lines="line 1\nline 2\nline 3\nline 4\nline 5\n" &&

	printf "$test_lines" >diamond/path0 &&
	git -C diamond add path0 &&
	git -C diamond commit -m "A: add path0" &&

	git -C diamond checkout -b upper &&
	printf "line 1\nline 2\nline 3 modified by B\nline 4\nline 5\n" \
		>diamond/path0 &&
	git -C diamond commit -am "B: modify path0 on upper" &&
	echo upper >diamond/upper &&
	git -C diamond add upper &&
	git -C diamond commit -m "upper: unrelated" &&
	git -C diamond mv path0 path1 &&
	git -C diamond commit -m "X: rename path0 to path1" &&

	git -C diamond checkout -b lower master &&
	printf "line 1\nline 2\nline 3 modified by C\nline 4\nline 5\n" \
		>diamond/path0 &&
	git -C diamond commit -am "C: modify path0 on lower" &&
	echo lower >diamond/lower &&
	git -C diamond add lower &&
	git -C diamond commit -m "lower: unrelated" &&
	git -C diamond mv path0 path2 &&
	git -C diamond commit -m "Y: rename path0 to path2" &&

	git -C diamond checkout upper &&
	git -C diamond merge -s ours --no-commit lower &&
	git -C diamond rm path1 &&
	printf "line 1\nline 2\nline 3 merged\nline 4\nline 5\n" \
		>diamond/path &&
	git -C diamond add path &&
	git -C diamond commit -m "M: merge with rename to path" &&

	printf "line 1\nline 2\nline 3 merged again\nline 4\nline 5\n" \
		>diamond/path &&
	git -C diamond commit -am "Z: modify path" &&
	git -C diamond commit-graph write --reachable --changed-paths
'

test_expect_success '--follow follows renames through a fork in a single history' '
	git -C diamond log --follow --pretty=tformat:%s path >actual &&
	sort actual >actual.sorted &&
	cat >expect <<-\EOF &&
	A: add path0
	B: modify path0 on upper
	C: modify path0 on lower
	X: rename path0 to path1
	Y: rename path0 to path2
	Z: modify path
	EOF
	test_cmp expect actual.sorted
'

test_expect_success '--follow honors the rename threshold across a merge' '
	printf "%s\n" "Z: modify path" >expect &&
	git -C diamond log --follow -M100% --pretty=tformat:%s path >actual &&
	test_cmp expect actual
'

test_expect_success '--follow refreshes Bloom keys for each history line' '
	git -C diamond -c core.commitGraph=false log \
		--follow --pretty=tformat:%s path >expect &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.perf" \
		git -C diamond -c core.commitGraph=true log \
		--follow --pretty=tformat:%s path >actual &&
	test_grep "\"definitely_not\":[1-9]" "$TRASH_DIRECTORY/trace.perf" &&
	test_cmp expect actual
'

test_expect_success 'setup repeated commit across a rename' '
	git init repeated &&
	test_commit -C repeated A old &&
	git -C repeated mv old new &&
	git -C repeated commit --message=B &&
	git -C repeated tag B &&
	test_commit -C repeated C new &&
	test_commit -C repeated D unrelated &&

	git -C repeated update-ref --create-reflog -m C \
		refs/heads/revisit C &&
	git -C repeated update-ref -m B refs/heads/revisit B &&
	git -C repeated update-ref -m C-again refs/heads/revisit C &&
	git -C repeated update-ref -m D refs/heads/revisit D
'

test_expect_success '--follow restores paths when a reflog revisits a commit' '
	cat >expect <<-\EOF &&
	C
	B
	C
	EOF
	git -C repeated log --walk-reflogs --follow --format=%s \
		refs/heads/revisit -- new >actual &&
	test_cmp expect actual
'

test_expect_success '--follow restores paths when diff-tree --stdin revisits a commit' '
	cat >expect <<-\EOF &&
	C
	B
	C
	EOF
	git -C repeated rev-parse D C B C >input &&
	git -C repeated diff-tree --stdin --format=%s --no-patch \
		--follow -- new <input >actual &&
	test_cmp expect actual
'

test_done

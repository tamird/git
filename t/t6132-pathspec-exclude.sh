#!/bin/sh

test_description='test case exclude pathspec'

. ./test-lib.sh

test_expect_success 'setup' '
	for p in file sub/file sub/sub/file sub/file2 sub/sub/sub/file sub2/file; do
		if echo $p | grep /; then
			mkdir -p $(dirname $p)
		fi &&
		: >$p &&
		git add $p &&
		git commit -m $p || return 1
	done &&
	git log --oneline --format=%s >actual &&
	cat <<EOF >expect &&
sub2/file
sub/sub/sub/file
sub/file2
sub/sub/file
sub/file
file
EOF
	test_cmp expect actual
'

test_expect_success 'exclude only pathspec uses default implicit pathspec' '
	git log --oneline --format=%s -- . ":(exclude)sub" >expect &&
	git log --oneline --format=%s -- ":(exclude)sub" >actual &&
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude sub' '
	git log --oneline --format=%s -- . ":(exclude)sub" >actual &&
	cat <<EOF >expect &&
sub2/file
file
EOF
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude sub/sub/file' '
	git log --oneline --format=%s -- . ":(exclude)sub/sub/file" >actual &&
	cat <<EOF >expect &&
sub2/file
sub/sub/sub/file
sub/file2
sub/file
file
EOF
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude sub using mnemonic' '
	git log --oneline --format=%s -- . ":!sub" >actual &&
	cat <<EOF >expect &&
sub2/file
file
EOF
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude :(icase)SUB' '
	git log --oneline --format=%s -- . ":(exclude,icase)SUB" >actual &&
	cat <<EOF >expect &&
sub2/file
file
EOF
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude sub2 from sub' '
	(
	cd sub &&
	git log --oneline --format=%s -- :/ ":/!sub2" >actual &&
	cat <<EOF >expect &&
sub/sub/sub/file
sub/file2
sub/sub/file
sub/file
file
EOF
	test_cmp expect actual
	)
'

test_expect_success 't_e_i() exclude sub/*file' '
	git log --oneline --format=%s -- . ":(exclude)sub/*file" >actual &&
	cat <<EOF >expect &&
sub2/file
sub/file2
file
EOF
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude :(glob)sub/*/file' '
	git log --oneline --format=%s -- . ":(exclude,glob)sub/*/file" >actual &&
	cat <<EOF >expect &&
sub2/file
sub/sub/sub/file
sub/file2
sub/file
file
EOF
	test_cmp expect actual
'

test_expect_success 'm_p_d() exclude sub' '
	git ls-files -- . ":(exclude)sub" >actual &&
	cat <<EOF >expect &&
file
sub2/file
EOF
	test_cmp expect actual
'

test_expect_success 'm_p_d() exclude sub/sub/file' '
	git ls-files -- . ":(exclude)sub/sub/file" >actual &&
	cat <<EOF >expect &&
file
sub/file
sub/file2
sub/sub/sub/file
sub2/file
EOF
	test_cmp expect actual
'

test_expect_success 'm_p_d() exclude sub using mnemonic' '
	git ls-files -- . ":!sub" >actual &&
	cat <<EOF >expect &&
file
sub2/file
EOF
	test_cmp expect actual
'

test_expect_success 'm_p_d() exclude :(icase)SUB' '
	git ls-files -- . ":(exclude,icase)SUB" >actual &&
	cat <<EOF >expect &&
file
sub2/file
EOF
	test_cmp expect actual
'

test_expect_success 'm_p_d() exclude sub2 from sub' '
	(
	cd sub &&
	git ls-files -- :/ ":/!sub2" >actual &&
	cat <<EOF >expect &&
../file
file
file2
sub/file
sub/sub/file
EOF
	test_cmp expect actual
	)
'

test_expect_success 'm_p_d() exclude sub/*file' '
	git ls-files -- . ":(exclude)sub/*file" >actual &&
	cat <<EOF >expect &&
file
sub/file2
sub2/file
EOF
	test_cmp expect actual
'

test_expect_success 'm_p_d() exclude :(glob)sub/*/file' '
	git ls-files -- . ":(exclude,glob)sub/*/file" >actual &&
	cat <<EOF >expect &&
file
sub/file
sub/file2
sub/sub/sub/file
sub2/file
EOF
	test_cmp expect actual
'

test_expect_success 'multiple exclusions' '
	git ls-files -- ":^*/file2" ":^sub2" >actual &&
	cat <<-\EOF >expect &&
	file
	sub/file
	sub/sub/file
	sub/sub/sub/file
	EOF
	test_cmp expect actual
'

test_expect_success 't_e_i() exclude case #8' '
	test_when_finished "rm -fr case8" &&
	git init case8 &&
	(
		cd case8 &&
		echo file >file1 &&
		echo file >file2 &&
		git add file1 file2 &&
		git commit -m twofiles &&
		git grep -l file HEAD :^file2 >actual &&
		echo HEAD:file1 >expected &&
		test_cmp expected actual &&
		git grep -l file HEAD :^file1 >actual &&
		echo HEAD:file2 >expected &&
		test_cmp expected actual
	)
'

test_expect_success 'grep --untracked PATTERN' '
	# This test is not an actual test of exclude patterns, rather it
	# is here solely to ensure that if any tests are inserted, deleted, or
	# changed above, that we still have untracked files with the expected
	# contents for the NEXT two tests.
	cat <<-\EOF >expect-grep &&
	actual
	expect
	sub/actual
	sub/expect
	EOF
	git grep -l --untracked file -- >actual-grep &&
	test_cmp expect-grep actual-grep
'

test_expect_success 'grep --untracked PATTERN :(exclude)DIR' '
	cat <<-\EOF >expect-grep &&
	actual
	expect
	EOF
	git grep -l --untracked file -- ":(exclude)sub" >actual-grep &&
	test_cmp expect-grep actual-grep
'

test_expect_success 'grep --untracked PATTERN :(exclude)*FILE' '
	cat <<-\EOF >expect-grep &&
	actual
	sub/actual
	EOF
	git grep -l --untracked file -- ":(exclude)*expect" >actual-grep &&
	test_cmp expect-grep actual-grep
'

# Depending on the command, all negative pathspec needs to subtract
# either from the full tree, or from the current directory.
#
# The sample tree checked out at this point has:
# file
# sub/file
# sub/file2
# sub/sub/file
# sub/sub/sub/file
# sub2/file
#
# but there may also be some cruft that interferes with "git clean"
# and "git add" tests.

test_expect_success 'archive with all negative' '
	git reset --hard &&
	git clean -f &&
	git -C sub archive --format=tar HEAD -- ":!sub/" >archive &&
	"$TAR" tf archive >actual &&
	cat >expect <<-\EOF &&
	file
	file2
	EOF
	test_cmp expect actual
'

test_expect_success 'add with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	git clean -f &&
	test_when_finished "git reset --hard $H" &&
	for path in file sub/file sub/sub/file sub2/file
	do
		echo smudge >>"$path" || return 1
	done &&
	git -C sub add -- ":!sub/" &&
	git diff --name-only --no-renames --cached >actual &&
	cat >expect <<-\EOF &&
	file
	sub/file
	sub2/file
	EOF
	test_cmp expect actual &&
	git diff --name-only --no-renames >actual &&
	echo sub/sub/file >expect &&
	test_cmp expect actual
'

test_expect_success 'add -p with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	git clean -f &&
	test_when_finished "git reset --hard $H" &&
	for path in file sub/file sub/sub/file sub2/file
	do
		echo smudge >>"$path" || return 1
	done &&
	yes | git -C sub add -p -- ":!sub/" &&
	git diff --name-only --no-renames --cached >actual &&
	cat >expect <<-\EOF &&
	file
	sub/file
	sub2/file
	EOF
	test_cmp expect actual &&
	git diff --name-only --no-renames >actual &&
	echo sub/sub/file >expect &&
	test_cmp expect actual
'

test_expect_success 'clean with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	test_when_finished "git reset --hard $H && git clean -f" &&
	git clean -f &&
	for path in file9 sub/file9 sub/sub/file9 sub2/file9
	do
		echo cruft >"$path" || return 1
	done &&
	git -C sub clean -f -- ":!sub" &&
	test_path_is_file file9 &&
	test_path_is_missing sub/file9 &&
	test_path_is_file sub/sub/file9 &&
	test_path_is_file sub2/file9
'

test_expect_success 'commit with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	test_when_finished "git reset --hard $H" &&
	for path in file sub/file sub/sub/file sub2/file
	do
		echo smudge >>"$path" || return 1
	done &&
	git -C sub commit -m sample -- ":!sub/" &&
	git diff --name-only --no-renames HEAD^ HEAD >actual &&
	cat >expect <<-\EOF &&
	file
	sub/file
	sub2/file
	EOF
	test_cmp expect actual &&
	git diff --name-only --no-renames HEAD >actual &&
	echo sub/sub/file >expect &&
	test_cmp expect actual
'

test_expect_success 'reset with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	test_when_finished "git reset --hard $H" &&
	for path in file sub/file sub/sub/file sub2/file
	do
		echo smudge >>"$path" &&
		git add "$path" || return 1
	done &&
	git -C sub reset --quiet -- ":!sub/" &&
	git diff --name-only --no-renames --cached >actual &&
	echo sub/sub/file >expect &&
	test_cmp expect actual
'

test_expect_success 'grep with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	test_when_finished "git reset --hard $H" &&
	for path in file sub/file sub/sub/file sub2/file
	do
		echo "needle $path" >>"$path" || return 1
	done &&
	git -C sub grep -h needle -- ":!sub/" >actual &&
	cat >expect <<-\EOF &&
	needle sub/file
	EOF
	test_cmp expect actual
'

test_expect_success 'ls-files with all negative' '
	git reset --hard &&
	git -C sub ls-files -- ":!sub/" >actual &&
	cat >expect <<-\EOF &&
	file
	file2
	EOF
	test_cmp expect actual
'

test_expect_success 'rm with all negative' '
	git reset --hard &&
	test_when_finished "git reset --hard" &&
	git -C sub rm -r --cached -- ":!sub/" >actual &&
	git diff --name-only --no-renames --diff-filter=D --cached >actual &&
	cat >expect <<-\EOF &&
	sub/file
	sub/file2
	EOF
	test_cmp expect actual
'

test_expect_success 'stash with all negative' '
	H=$(git rev-parse HEAD) &&
	git reset --hard $H &&
	test_when_finished "git reset --hard $H" &&
	for path in file sub/file sub/sub/file sub2/file
	do
		echo smudge >>"$path" || return 1
	done &&
	git -C sub stash push -m sample -- ":!sub/" &&
	git diff --name-only --no-renames HEAD >actual &&
	echo sub/sub/file >expect &&
	test_cmp expect actual &&
	git stash show --name-only >actual &&
	cat >expect <<-\EOF &&
	file
	sub/file
	sub2/file
	EOF
	test_cmp expect actual
'

test_expect_success 'recursive excludes prune descendants but retain boundary reads' '
	cat >expect-exclude <<-\EOF &&
	HEAD:file
	HEAD:sub/file
	HEAD:sub/file2
	HEAD:sub2/file
	EOF
	>exclude-literal.trace &&
	GIT_TRACE2_EVENT="$PWD/exclude-literal.trace" \
		git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(glob)**/*" ":(exclude)sub/sub" >actual-exclude &&
	test_cmp expect-exclude actual-exclude &&
	test_trace2_data grep content_index_tree_directories 3 <exclude-literal.trace &&
	>exclude-recursive.trace &&
	GIT_TRACE2_EVENT="$PWD/exclude-recursive.trace" \
		git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(glob)**/*" ":(exclude)sub/sub/**" >actual-exclude &&
	test_cmp expect-exclude actual-exclude &&
	# Before the optimization this is 4: sub/sub/sub is unnecessarily read.
	test_trace2_data grep content_index_tree_directories 3 <exclude-recursive.trace
'

test_expect_success 'recursive excludes preserve other pathspec modes' '
	for excluded in \
		":(exclude,glob)sub/sub/**" \
		":(exclude,top)sub/sub/**" \
		":(exclude,icase)SUB/SUB/**" \
		":(exclude,attr:!prune)sub/sub/**" \
		":(exclude)sub/s*/**" \
		":(exclude)sub/sub/*"
	do
		>exclude-mode.trace &&
		GIT_TRACE2_EVENT="$PWD/exclude-mode.trace" \
			git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
			":(glob)**/*" "$excluded" >actual-exclude &&
		test_cmp expect-exclude actual-exclude &&
		test_trace2_data grep content_index_tree_directories 4 <exclude-mode.trace ||
		return 1
	done &&
	>exclude-mode.trace &&
	GIT_TRACE2_EVENT="$PWD/exclude-mode.trace" \
		git grep --no-content-index --threads=1 --max-depth=1 -L \
		"never matches" HEAD -- ":(glob)**/*" ":(exclude)sub/sub/**" \
		>actual-exclude &&
	test_cmp expect-exclude actual-exclude &&
	test_trace2_data grep content_index_tree_directories 4 <exclude-mode.trace &&
	>exclude-mode.trace &&
	GIT_TRACE2_EVENT="$PWD/exclude-mode.trace" \
		git grep --no-content-index --threads=1 --recurse-submodules -L \
		"never matches" HEAD -- ":(glob)**/*" ":(exclude)sub/sub/**" \
		>actual-exclude &&
	test_cmp expect-exclude actual-exclude &&
	test_trace2_data grep content_index_tree_directories 4 <exclude-mode.trace &&
	git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(glob)**/*" >expect-exclude-all &&
	git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(glob)**/*" ":(exclude,literal)sub/sub/**" >actual-exclude &&
	test_cmp expect-exclude-all actual-exclude &&
	git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(exclude)sub/sub/**" ":(glob)**/*" >actual-exclude &&
	test_cmp expect-exclude actual-exclude &&
	git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(exclude)sub/sub/**" >actual-exclude &&
	test_cmp expect-exclude actual-exclude &&
	git -C sub grep --no-content-index --threads=1 --full-name -L \
		"never matches" HEAD -- ":(glob)**/*" ":(exclude)sub/**" >actual-exclude &&
	printf "HEAD:sub/file\nHEAD:sub/file2\n" >expect-exclude-prefix &&
	test_cmp expect-exclude-prefix actual-exclude
'

test_expect_success 'setup distinct excluded trees and non-directory entries' '
	exclude_blob=$(git rev-parse HEAD:file) &&
	exclude_kept=$(git rev-parse HEAD:sub2) &&
	exclude_commit=$(git rev-parse HEAD) &&
	exclude_deep=$(printf "100644 blob %s\tonly-excluded\n" "$exclude_blob" |
		git mktree) &&
	test "$exclude_deep" != "$exclude_kept" &&
	exclude_boundary=$({
		printf "100644 blob %s\ta\n" "$exclude_blob" &&
		printf "160000 commit %s\tgitlink\n" "$exclude_commit" &&
		printf "120000 blob %s\tlink\n" "$exclude_blob" &&
		printf "040000 tree %s\tz\n" "$exclude_deep"
	} | git mktree) &&
	exclude_outer=$({
		printf "100644 blob %s\tfile\n" "$exclude_blob" &&
		printf "040000 tree %s\tsub\n" "$exclude_boundary"
	} | git mktree) &&
	exclude_root=$({
		printf "100644 blob %s\tfile\n" "$exclude_blob" &&
		printf "040000 tree %s\tsub\n" "$exclude_outer" &&
		printf "040000 tree %s\tsub2\n" "$exclude_kept"
	} | git mktree) &&
	printf "%s:file\n%s:sub/file\n%s:sub2/file\n" \
		"$exclude_root" "$exclude_root" "$exclude_root" >expect-exclude-objects &&
	git grep --no-content-index --threads=1 -L "never matches" "$exclude_root" -- \
		":(glob)**/*" ":(exclude)sub/sub/**" >actual-exclude &&
	test_cmp expect-exclude-objects actual-exclude &&
	git grep --no-content-index --threads=1 -L "never matches" HEAD -- \
		":(glob)**/*" ":(exclude)file/**" >actual-exclude &&
	test_cmp expect-exclude-all actual-exclude
'

test_expect_success 'recursive excludes still parse the already-read boundary buffer' '
	git cat-file tree "$exclude_boundary" >exclude-corrupt.raw &&
	printf broken >>exclude-corrupt.raw &&
	exclude_corrupt=$(git hash-object --literally -w -t tree exclude-corrupt.raw) &&
	exclude_corrupt_outer=$(printf "040000 tree %s\tsub\n" "$exclude_corrupt" |
		git mktree) &&
	exclude_corrupt_root=$(printf "040000 tree %s\tsub\n" "$exclude_corrupt_outer" |
		git mktree) &&
	test_must_fail git grep --no-content-index --threads=1 -L "never matches" \
		"$exclude_corrupt_root" -- ":(glob)**/*" ":(exclude,glob)sub/sub/**" \
		>expect-exclude-corrupt 2>expect-exclude-error &&
	test_must_fail git grep --no-content-index --threads=1 -L "never matches" \
		"$exclude_corrupt_root" -- ":(glob)**/*" ":(exclude)sub/sub/**" \
		>actual-exclude-corrupt 2>actual-exclude-error &&
	test_cmp expect-exclude-corrupt actual-exclude-corrupt &&
	test_cmp expect-exclude-error actual-exclude-error &&
	test_grep "too-short tree object" actual-exclude-error
'

test_expect_success 'recursive excludes avoid missing descendants, not boundary or included trees' '
	exclude_deep_path=.git/objects/$(test_oid_to_path "$exclude_deep") &&
	exclude_boundary_path=.git/objects/$(test_oid_to_path "$exclude_boundary") &&
	test_path_is_file "$exclude_deep_path" &&
	test_path_is_file "$exclude_boundary_path" &&
	mv "$exclude_deep_path" "$exclude_deep_path.save" &&
	test_when_finished "mv \"$exclude_deep_path.save\" \"$exclude_deep_path\"" &&
	git grep --no-content-index --threads=1 -L "never matches" "$exclude_root" -- \
		":(glob)**/*" ":(exclude)sub/sub/**" >actual-exclude 2>exclude-error &&
	test_cmp expect-exclude-objects actual-exclude &&
	test_must_be_empty exclude-error &&
	test_must_fail git grep --no-content-index --threads=1 -L "never matches" \
		"$exclude_root" -- ":(glob)**/*" >actual-exclude 2>exclude-error &&
	test_grep "$exclude_deep" exclude-error &&
	mv "$exclude_boundary_path" "$exclude_boundary_path.save" &&
	test_when_finished "test ! -f \"$exclude_boundary_path.save\" ||
		mv \"$exclude_boundary_path.save\" \"$exclude_boundary_path\"" &&
	test_must_fail git grep --no-content-index --threads=1 -L "never matches" \
		"$exclude_root" -- ":(glob)**/*" ":(exclude)sub/sub/**" \
		>actual-exclude 2>exclude-error &&
	test_grep "$exclude_boundary" exclude-error &&
	mv "$exclude_boundary_path.save" "$exclude_boundary_path" &&
	# Both the prefetch walk and the main walk must leave the missing descendant alone.
	test_config remote.exclude-missing.promisor true &&
	test_config remote.exclude-missing.url "$PWD/exclude-missing-remote" &&
	>exclude-promisor.trace &&
	GIT_TRACE2_EVENT="$PWD/exclude-promisor.trace" \
		git grep --no-content-index --threads=1 -L "never matches" "$exclude_root" -- \
		":(glob)**/*" ":(exclude)sub/sub/**" >actual-exclude 2>exclude-error &&
	test_cmp expect-exclude-objects actual-exclude &&
	test_must_be_empty exclude-error &&
	test_region grep prefetch_blobs exclude-promisor.trace &&
	test_grep ! "\"key\":\"fetch_count\"" exclude-promisor.trace &&
	>exclude-promisor.trace &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/exclude-promisor.trace" \
		git grep --no-content-index --threads=1 -L "never matches" "$exclude_root" -- \
		":(glob)**/*" >actual-exclude 2>exclude-error &&
	test_trace2_data promisor fetch_count 1 <exclude-promisor.trace
'

test_done

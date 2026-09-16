#!/bin/sh

test_description="Test whether cache-tree is properly updated

Tests whether various commands properly update and/or rewrite the
cache-tree extension.
"

 . ./test-lib.sh

test_lazy_prereq ODB_MONOTONIC_CLOCK '
	test-tool trace2 012monotonic_clock
'

cmp_cache_tree () {
	test-tool dump-cache-tree | sed -e '/#(ref)/d' >actual &&
	sed "s/$OID_REGEX/SHA/" <actual >filtered &&
	test_cmp "$1" filtered &&
	rm filtered
}

# We don't bother with actually checking the SHA1:
# test-tool dump-cache-tree already verifies that all existing data is
# correct.
generate_expected_cache_tree () {
	pathspec="$1" &&
	dir="$2${2:+/}" &&
	git ls-tree --name-only HEAD -- "$pathspec" >files &&
	git ls-tree --name-only -d HEAD -- "$pathspec" >subtrees &&
	printf "SHA %s (%d entries, %d subtrees)\n" "$dir" $(wc -l <files) $(wc -l <subtrees) &&
	while read subtree
	do
		generate_expected_cache_tree "$pathspec/$subtree/" "$subtree" || return 1
	done <subtrees
}

test_cache_tree () {
	generate_expected_cache_tree "." >expect &&
	cmp_cache_tree expect &&
	rm expect actual files subtrees &&
	git status --porcelain -- ':!status' ':!expected.status' >status &&
	if test -n "$1"
	then
		test_cmp "$1" status
	else
		test_must_be_empty status
	fi
}

test_invalid_cache_tree () {
	printf "invalid                                  %s ()\n" "" "$@" >expect &&
	test-tool dump-cache-tree |
	sed -n -e "s/[0-9]* subtrees//" -e '/#(ref)/d' -e '/^invalid /p' >actual &&
	test_cmp expect actual
}

test_no_cache_tree () {
	>expect &&
	cmp_cache_tree expect
}

test_cache_tree_object_check_time () {
	object_check_trace="$1"
	object_check_count="$2"
	test_trace2_data cache_tree validate/object-check-us-total \
		"[0-9][0-9]*" <"$object_check_trace" || return 1
	object_check_us=$(sed -n \
		"s/.*\"key\":\"validate\\/object-check-us-total\",\"value\":\"\\([0-9][0-9]*\\)\".*/\\1/p" \
		"$object_check_trace" | tail -n 1) || return 1
	test_grep ! "\"event\":\"th_timer\".*\"name\":\"validate/object-check\"" \
		"$object_check_trace" || return 1
	if test "$object_check_count" = 0
	then
		test "$object_check_us" = 0 &&
		test_grep ! "\"event\":\"timer\".*\"name\":\"validate/object-check\"" \
			"$object_check_trace"
	else
		test "$(grep -c "\"event\":\"timer\".*\"category\":\"cache_tree\",\"name\":\"validate/object-check\"" \
			"$object_check_trace")" = 1 &&
		test_grep "\"event\":\"timer\".*\"category\":\"cache_tree\",\"name\":\"validate/object-check\",\"intervals\":$object_check_count," \
			"$object_check_trace" &&
		object_check_total=$(sed -n \
			"s/.*\"name\":\"validate\\/object-check\".*\"t_total\":\\([0-9][0-9]*[.][0-9][0-9]*\\),.*/\\1/p" \
			"$object_check_trace") &&
		test -n "$object_check_total" &&
		awk -v elapsed="$object_check_us" -v total="$object_check_total" '
		BEGIN {
			total *= 1000000
			if (elapsed > total + 1 || elapsed < total - 1)
				exit 1
		}'
	fi
}

run_cache_tree_update_trace () {
	update_trace="$1" &&
	update_output="$2" &&
	shift 2 &&
	(
		sane_unset GIT_TRACE2_EVENT_NESTING &&
		GIT_TRACE2=0 GIT_TRACE2_PERF=0 GIT_TRACE2_EVENT="$update_trace" \
			"$@" >"$update_output" 2>"$update_output.err"
	)
}

setup_cache_tree_update_repo () {
	git init "$1" &&
	(
		cd "$1" &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		git config core.fsmonitor false &&
		git config gc.auto 0 &&
		mkdir a b &&
		echo one >a/file &&
		echo two >b/file &&
		git add a b &&
		git commit -m base &&
		git rev-parse HEAD^{tree} >.git/base.tree
	)
}

snapshot_cache_tree_validation_state () {
	cp .git/index .git/validate-only.expect.index &&
	test-tool chmtime --get .git/index >.git/validate-only.expect.mtime &&
	git count-objects -v >.git/validate-only.expect.objects &&
	ls .git/objects/pack >.git/validate-only.expect.packs
}

test_cache_tree_validation_state_unchanged () {
	test_cmp_bin .git/validate-only.expect.index .git/index &&
	test-tool chmtime --get .git/index >.git/validate-only.actual.mtime &&
	test_cmp .git/validate-only.expect.mtime .git/validate-only.actual.mtime &&
	git count-objects -v >.git/validate-only.actual.objects &&
	test_cmp .git/validate-only.expect.objects .git/validate-only.actual.objects &&
	ls .git/objects/pack >.git/validate-only.actual.packs &&
	test_cmp .git/validate-only.expect.packs .git/validate-only.actual.packs &&
	test_path_is_missing .git/index.lock
}

cache_tree_update_value () {
	sed -n "s/.*\"key\":\"update\\/$2-total\",\"value\":\"\\([0-9][0-9]*\\)\".*/\\1/p" "$1"
}

test_cache_tree_update_time () {
	update_trace="$1" &&
	update_timer="$2" &&
	update_count="$3" &&
	test_trace2_data cache_tree "update/$update_timer-us-total" \
		"[0-9][0-9]*" <"$update_trace" &&
	update_us=$(cache_tree_update_value "$update_trace" "$update_timer-us") &&
	test_grep ! "\"event\":\"th_timer\".*\"name\":\"update/$update_timer\"" \
		"$update_trace" || return 1

	if test "$update_count" = 0
	then
		test "$update_us" = 0 &&
		test_grep ! "\"event\":\"timer\".*\"name\":\"update/$update_timer\"" \
			"$update_trace"
	else
		grep "\"event\":\"timer\".*\"category\":\"cache_tree\",\"name\":\"update/$update_timer\"" \
			"$update_trace" >"$update_trace.timer" &&
		test_line_count = 1 "$update_trace.timer" &&
		test_grep "\"intervals\":$update_count," "$update_trace.timer" &&
		update_total=$(sed -n \
			"s/.*\"t_total\":\\([0-9][0-9]*[.][0-9][0-9]*\\),.*/\\1/p" \
			"$update_trace.timer") &&
		test -n "$update_total" &&
		awk -v elapsed="$update_us" -v total="$update_total" '
		BEGIN {
			total *= 1000000
			if (elapsed > total + 1 || elapsed < total - 1)
				exit 1
		}'
	fi
}

test_cache_tree_update_metrics () {
	update_trace="$1" &&
	shift &&
	for update_key in calls failed nodes reused sparse-nodes \
		hash-only-nodes object-write-calls owned-odb-commit-calls
	do
		test_trace2_data cache_tree "update/$update_key-total" "$1" \
			<"$update_trace" >"$update_trace.data" &&
		test_line_count = 1 "$update_trace.data" || return 1
		shift
	done &&
	test_trace2_data cache_tree update/entries-visited-total \
		'[0-9][0-9]*' <"$update_trace" >/dev/null &&
	test_trace2_data cache_tree update/entry-object-checks-total \
		'[0-9][0-9]*' <"$update_trace" >/dev/null &&
	for update_key in entry-object-check-us reused-child-parent-checks \
		reused-child-parent-check-us reuse-object-checks \
		reuse-object-check-us reuse-object-probed-checks repair-tree-checks \
		repair-tree-check-us hash-only-us \
		reuse-packed-attempts reuse-packed-attempt-us reuse-packed-prepares \
		reuse-packed-prepare-us reuse-packed-midx-searches \
		reuse-packed-midx-search-us reuse-packed-midx-resolves \
		reuse-packed-midx-resolve-us reuse-packed-fallbacks \
		reuse-packed-fallback-us reuse-packed-invalid
	do
		test_trace2_data cache_tree "update/$update_key-total" \
			'[0-9][0-9]*' <"$update_trace" >/dev/null || return 1
	done &&
	grep '"event":"data".*"category":"cache_tree","key":"update/' \
		"$update_trace" >"$update_trace.data" &&
	test_line_count = 32 "$update_trace.data" &&
	grep '"nesting":1,' "$update_trace.data" >"$update_trace.depth" &&
	test_line_count = 32 "$update_trace.depth" &&
	update_writes=$(cache_tree_update_value "$update_trace" object-write-calls) &&
	update_commits=$(cache_tree_update_value "$update_trace" owned-odb-commit-calls) &&
	test_cache_tree_update_time "$update_trace" object-write "$update_writes" &&
	test_cache_tree_update_time "$update_trace" owned-odb-commit "$update_commits"
}


test_cache_tree_update_bound () {
	update_trace="$1" &&
	update_calls="$2" &&
	update_entry_us=$(cache_tree_update_value "$update_trace" entry-object-check-us) &&
	update_reuse_us=$(cache_tree_update_value "$update_trace" reuse-object-check-us) &&
	update_repair_us=$(cache_tree_update_value "$update_trace" repair-tree-check-us) &&
	update_hash_us=$(cache_tree_update_value "$update_trace" hash-only-us) &&
	update_write_us=$(cache_tree_update_value "$update_trace" object-write-us) &&
	update_commit_us=$(cache_tree_update_value "$update_trace" owned-odb-commit-us) &&
	# This fixture retains all returning regions, all on the main thread.
	awk -v work="$((update_entry_us + update_reuse_us + update_repair_us + \
		update_hash_us + update_write_us + update_commit_us))" \
		-v calls="$update_calls" '
	/"event":"region_leave"/ && /"thread":"main"/ &&
	/"category":"cache_tree","label":"update"/ {
		elapsed = $0
		sub(/^.*"t_rel":/, "", elapsed)
		sub(/,.*/, "", elapsed)
		total += elapsed * 1000000
		regions++
	}
	END {
		if (regions != calls || work > total + calls + 2)
			exit 1
	}' "$update_trace"
}

test_commit_as_is_timer () {
	trace_file="$1"
	timer_name="$2"
	timer_count="$3"
	test_grep ! "\"event\":\"th_timer\".*\"category\":\"commit\",\"name\":\"as-is/$timer_name\"" "$trace_file" &&
	if test "$timer_count" = absent
	then
		test_grep ! "\"event\":\"timer\".*\"category\":\"commit\",\"name\":\"as-is/$timer_name\"" "$trace_file"
	else
		test_grep "\"event\":\"timer\".*\"category\":\"commit\",\"name\":\"as-is/$timer_name\",\"intervals\":$timer_count," "$trace_file"
	fi
}

test_expect_success 'initial commit has cache-tree' '
	test_commit foo &&
	test_cache_tree
'

test_expect_success 'ls-files and grep defer cache-tree parsing' '
	GIT_TRACE2_PERF="$(pwd)/.git/ls-files.trace" git ls-files >/dev/null &&
	test_grep ! "cache_tree.*label:read" .git/ls-files.trace &&

	GIT_TRACE2_PERF="$(pwd)/.git/grep.trace" git grep --cached --quiet foo &&
	test_grep ! "cache_tree.*label:read" .git/grep.trace
'

test_expect_success 'threaded read materializes deferred cache-tree' '
	test_config index.threads 2 &&
	git read-tree HEAD &&
	GIT_TRACE2_PERF="$(pwd)/.git/materialize.trace" \
		test-tool dump-cache-tree >/dev/null &&
	test_grep "cache_tree.*label:read" .git/materialize.trace &&
	test_cache_tree
'

test_expect_success 'git-add invalidates cache-tree' '
	test_when_finished "git reset --hard; git read-tree HEAD" &&
	echo "I changed this file" >foo &&
	git add foo &&
	test_invalid_cache_tree
'

test_expect_success 'git-add in subdir invalidates cache-tree' '
	test_when_finished "git reset --hard; git read-tree HEAD" &&
	mkdir dirx &&
	echo "I changed this file" >dirx/foo &&
	git add dirx/foo &&
	test_invalid_cache_tree
'

test_expect_success 'git-add in subdir does not invalidate sibling cache-tree' '
	git tag no-children &&
	test_when_finished "git reset --hard no-children; git read-tree HEAD" &&
	mkdir dir1 dir2 &&
	test_commit dir1/a &&
	test_commit dir2/b &&
	echo "I changed this file" >dir1/a &&
	test_when_finished "rm before" &&
	cat >before <<-\EOF &&
	SHA  (3 entries, 2 subtrees)
	SHA dir1/ (1 entries, 0 subtrees)
	SHA dir2/ (1 entries, 0 subtrees)
	EOF
	cmp_cache_tree before &&
	echo "I changed this file" >dir1/a &&
	git add dir1/a &&
	cat >expect <<-\EOF &&
	invalid                                   (2 subtrees)
	invalid                                  dir1/ (0 subtrees)
	SHA dir2/ (1 entries, 0 subtrees)
	EOF
	cmp_cache_tree expect
'

test_expect_success 'update-index invalidates cache-tree' '
	test_when_finished "git reset --hard; git read-tree HEAD" &&
	echo "I changed this file" >foo &&
	git update-index --add foo &&
	test_invalid_cache_tree
'

test_expect_success 'write-tree establishes cache-tree' '
	test-tool scrap-cache-tree &&
	git write-tree &&
	test_cache_tree
'

test_expect_success '--no-optional-locks skips cache-tree persistence' '
	test_when_finished "rm -f .git/index.lock && git reset --hard" &&
	echo changed >foo.t &&
	git add foo.t &&
	test-tool scrap-cache-tree &&
	test_no_cache_tree &&
	test_set_magic_mtime .git/index &&
	>.git/index.lock &&
	tree=$(git --no-optional-locks write-tree) &&
	test_is_magic_mtime .git/index &&
	test_no_cache_tree &&
	rm .git/index.lock &&
	git diff-index --cached --quiet "$tree" -- &&
	default_tree=$(git write-tree) &&
	test "$tree" = "$default_tree" &&
	cat >expected.status <<-\EOF &&
	M  foo.t
	EOF
	test_cache_tree expected.status
'

test_expect_success 'write-tree configuration can skip cache-tree persistence' '
	test_when_finished "rm -f .git/index.lock && git reset --hard" &&
	echo configured >foo.t &&
	git add foo.t &&
	test-tool scrap-cache-tree &&
	test_no_cache_tree &&
	test_set_magic_mtime .git/index &&
	>.git/index.lock &&
	tree=$(git -c writeTree.persistCacheTree=false write-tree) &&
	test_is_magic_mtime .git/index &&
	test_no_cache_tree &&
	override_tree=$(git -c writeTree.persistCacheTree=true \
		--no-optional-locks write-tree) &&
	test "$tree" = "$override_tree" &&
	test_is_magic_mtime .git/index &&
	test_no_cache_tree &&
	rm .git/index.lock &&
	git diff-index --cached --quiet "$tree" -- &&
	default_tree=$(git write-tree) &&
	test "$tree" = "$default_tree" &&
	cat >expected.status <<-\EOF &&
	M  foo.t
	EOF
	test_cache_tree expected.status
'

test_expect_success 'threaded read discards deferred cache-tree' '
	test_config index.threads 2 &&
	git read-tree HEAD &&
	GIT_TRACE2_PERF="$(pwd)/.git/discard.trace" \
		test-tool scrap-cache-tree &&
	test_grep ! "cache_tree.*label:read" .git/discard.trace &&
	test_no_cache_tree
'

test_expect_success 'second commit has cache-tree' '
	test_commit bar &&
	test_cache_tree
'

test_expect_success 'commit --interactive gives cache-tree on partial commit' '
	test_when_finished "git reset --hard" &&
	cat <<-\EOT >foo.c &&
	int foo()
	{
		return 42;
	}
	int bar()
	{
		return 42;
	}
	EOT
	git add foo.c &&
	test_invalid_cache_tree &&
	git commit -m "add a file" &&
	test_cache_tree &&
	cat <<-\EOT >foo.c &&
	int foo()
	{
		return 43;
	}
	int bar()
	{
		return 44;
	}
	EOT
	test_write_lines p 1 "" s n y q |
	git commit --interactive -m foo &&
	cat <<-\EOF >expected.status &&
	 M foo.c
	EOF
	test_cache_tree expected.status
'

test_expect_success 'commit -p with shrinking cache-tree' '
	mkdir -p deep/very-long-subdir &&
	echo content >deep/very-long-subdir/file &&
	git add deep &&
	git commit -m add &&
	git rm -r deep &&

	before=$(wc -c <.git/index) &&
	git commit -m delete -p &&
	after=$(wc -c <.git/index) &&

	# double check that the index shrank
	test $before -gt $after &&

	# and that our index was not corrupted
	git fsck
'

test_expect_success 'commit in child dir has cache-tree' '
	mkdir dir &&
	>dir/child.t &&
	git add dir/child.t &&
	git commit -m dir/child.t &&
	test_cache_tree
'

test_expect_success 'reset --hard gives cache-tree' '
	test-tool scrap-cache-tree &&
	GIT_TRACE2_EVENT="$PWD/.git/reset-cold.trace" git reset --hard &&
	test_region cache-tree prime_cache_tree .git/reset-cold.trace &&
	test_cache_tree
'

test_expect_success 'reset reuses unchanged cache-tree subtrees' '
	test_when_finished "rm -rf reset-cache-tree" &&
	git init reset-cache-tree &&
	(
		cd reset-cache-tree &&
		mkdir -p changed/deep unchanged/deep removed/deep &&
		echo before >changed/deep/file &&
		echo unchanged >unchanged/deep/file &&
		echo removed >removed/deep/file &&
		git add . &&
		git commit -m before &&
		before=$(git rev-parse HEAD) &&

		echo after >changed/deep/file &&
		git rm -r removed &&
		git add changed/deep/file &&
		git commit -m after &&
		after=$(git rev-parse HEAD) &&

		GIT_TRACE2_EVENT="$PWD/.git/reset-add.trace" \
			git reset --hard "$before" &&
		test_region cache_tree update .git/reset-add.trace &&
		test_region ! cache-tree prime_cache_tree .git/reset-add.trace &&
		test_path_is_file removed/deep/file &&
		test-tool dump-cache-tree >.git/reset-add.cache-tree &&
		test_grep "unchanged/deep/" .git/reset-add.cache-tree &&
		test_grep "removed/deep/" .git/reset-add.cache-tree &&
		test "$(git rev-parse HEAD^{tree})" = "$(git write-tree)" &&

		GIT_TRACE2_EVENT="$PWD/.git/reset-remove.trace" \
			git reset --hard "$after" &&
		test_region cache_tree update .git/reset-remove.trace &&
		test_region ! cache-tree prime_cache_tree .git/reset-remove.trace &&
		test_path_is_missing removed &&
		test-tool dump-cache-tree >.git/reset-remove.cache-tree &&
		test_grep "unchanged/deep/" .git/reset-remove.cache-tree &&
		test_grep ! "removed/" .git/reset-remove.cache-tree &&
		test "$(git rev-parse HEAD^{tree})" = "$(git write-tree)"
	)
'

test_expect_success 'reset --hard without index gives cache-tree' '
	rm -f .git/index &&
	git clean -fd &&
	GIT_TRACE2_EVENT="$PWD/.git/reset-no-index.trace" \
		git reset --hard &&
	test_region cache-tree prime_cache_tree .git/reset-no-index.trace &&
	test_cache_tree
'

test_expect_success 'checkout gives cache-tree' '
	git tag current &&
	git checkout HEAD^ &&
	test_cache_tree
'

test_expect_success 'checkout -b gives cache-tree' '
	git checkout current &&
	git checkout -b prev HEAD^ &&
	test_cache_tree
'

test_expect_success 'checkout -B gives cache-tree' '
	git checkout current &&
	git checkout -B prev HEAD^ &&
	test_cache_tree
'

test_expect_success 'merge --ff-only maintains cache-tree' '
	git checkout current &&
	git checkout -b changes &&
	test_commit llamas &&
	test_commit pachyderm &&
	test_cache_tree &&
	git checkout current &&
	test_cache_tree &&
	git merge --ff-only changes &&
	test_cache_tree
'

test_expect_success 'merge maintains cache-tree' '
	git checkout current &&
	git checkout -b changes2 &&
	test_commit alpacas &&
	test_cache_tree &&
	git checkout current &&
	test_commit struthio &&
	test_cache_tree &&
	git merge changes2 &&
	test_cache_tree
'

test_expect_success 'partial commit gives cache-tree' '
	git checkout -b partial no-children &&
	test_commit one &&
	test_commit two &&
	echo "some change" >one.t &&
	git add one.t &&
	echo "some other change" >two.t &&
	git commit two.t -m partial &&
	cat <<-\EOF >expected.status &&
	M  one.t
	EOF
	test_cache_tree expected.status
'

test_expect_success 'no phantom error when switching trees' '
	mkdir newdir &&
	>newdir/one &&
	git add newdir/one &&
	git checkout 2>errors &&
	test_must_be_empty errors
'

test_expect_success 'switching trees does not invalidate shared index' '
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git update-index --split-index &&
		>split &&
		git add split &&
		test-tool dump-split-index .git/index | grep -v ^own >before &&
		git -c splitIndex.maxPercentChange=100 commit -m "as-is" &&
		test-tool dump-split-index .git/index | grep -v ^own >after &&
		test_cmp before after
	)
'

test_expect_success 'as-is commit times cache-tree preparation' '
	test_when_finished "rm -rf commit-prep" &&
	git init commit-prep &&
	(
		cd commit-prep &&
		mkdir dir &&
		echo base >dir/file &&
		git add dir/file &&
		git commit -m base &&
		GIT_TRACE2_EVENT="$PWD/.git/valid.trace" \
			git commit --allow-empty -m empty &&
		test_trace2_data commit as-is/cache-tree-checked 1 <.git/valid.trace &&
		test_trace2_data commit as-is/cache-tree-valid 1 <.git/valid.trace &&
		test_trace2_data commit as-is/cache-tree-validate/nodes 2 <.git/valid.trace &&
		test_trace2_data commit as-is/cache-tree-validate/object-checks 2 <.git/valid.trace &&
		(test_have_prereq MINGW ||
		 test_trace2_data commit as-is/cache-tree-validate/major-faults "[0-9][0-9]*" <.git/valid.trace) &&
		test_grep ! "\"event\":\"timer\".*\"category\":\"cache_tree\",\"name\":\"validate/object-check\"" .git/valid.trace &&
		test_commit_as_is_timer .git/valid.trace cache-tree-validate 1 &&
		test_commit_as_is_timer .git/valid.trace cache-tree-update absent &&
		test_commit_as_is_timer .git/valid.trace write-index 1 &&
		current_branch=$(git symbolic-ref --short HEAD) &&
		GIT_TRACE2_EVENT="$PWD/.git/checkout.trace" git switch "$current_branch" &&
		test_trace2_data checkout cache-tree-validate/nodes 2 <.git/checkout.trace &&
		test_trace2_data checkout cache-tree-validate/object-checks 2 <.git/checkout.trace &&
		test_trace2_data checkout cache-tree-validate/valid 1 <.git/checkout.trace &&
		(test_have_prereq MINGW ||
		 test_trace2_data checkout cache-tree-validate/major-faults "[0-9][0-9]*" <.git/checkout.trace) &&
		test_grep "\"event\":\"timer\".*\"category\":\"checkout\",\"name\":\"cache-tree-validate\",\"intervals\":1," .git/checkout.trace &&
		echo changed >dir/file &&
		git add dir/file &&
		GIT_TRACE2_EVENT="$PWD/.git/invalid.trace" git commit -m changed &&
		test_trace2_data commit as-is/cache-tree-checked 1 <.git/invalid.trace &&
		test_trace2_data commit as-is/cache-tree-valid 0 <.git/invalid.trace &&
		test_trace2_data commit as-is/cache-tree-validate/nodes 1 <.git/invalid.trace &&
		test_trace2_data commit as-is/cache-tree-validate/object-checks 0 <.git/invalid.trace &&
		(test_have_prereq MINGW ||
		 test_trace2_data commit as-is/cache-tree-validate/major-faults "[0-9][0-9]*" <.git/invalid.trace) &&
		test_commit_as_is_timer .git/invalid.trace cache-tree-validate 1 &&
		test_commit_as_is_timer .git/invalid.trace cache-tree-update 1 &&
		test_commit_as_is_timer .git/invalid.trace write-index 1 &&
		test-tool chmtime =-60 dir/file &&
		GIT_TRACE2_EVENT="$PWD/.git/refresh.trace" \
			git -c core.fsmonitor=false commit --allow-empty -m refreshed &&
		test_trace2_data commit as-is/cache-tree-checked 0 <.git/refresh.trace &&
		test_trace2_data commit as-is/cache-tree-valid 0 <.git/refresh.trace &&
		test_grep ! "\"key\":\"as-is/cache-tree-validate/nodes\"" .git/refresh.trace &&
		test_grep ! "\"key\":\"as-is/cache-tree-validate/object-checks\"" .git/refresh.trace &&
		test_grep ! "\"key\":\"as-is/cache-tree-validate/major-faults\"" .git/refresh.trace &&
		test_commit_as_is_timer .git/refresh.trace cache-tree-validate absent &&
		test_commit_as_is_timer .git/refresh.trace cache-tree-update 1 &&
		test_commit_as_is_timer .git/refresh.trace write-index 1 &&
		git rev-parse HEAD^{tree} >expect &&
		git write-tree >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'OID-ordered validation falls back for a missing nested tree' '
	test_when_finished "rm -fr oid-order-missing" &&
	git init oid-order-missing &&
	(
		cd oid-order-missing &&
		git config gc.auto 0 &&
		mkdir nested sibling &&
		printf "%s\n" nested >nested/file &&
		printf "%s\n" sibling >sibling/file &&
		git add nested sibling &&
		git commit -m base &&
		git rev-parse HEAD^{tree} >expect &&
		nested_oid=$(git rev-parse HEAD:nested) &&
		nested_path="$(git rev-parse --git-path objects)/$(test_oid_to_path "$nested_oid")" &&
		rm "$nested_path" &&
		snapshot_cache_tree_validation_state &&
		GIT_TEST_CACHE_TREE_OID_ORDER=0 \
		GIT_TRACE2_EVENT="$PWD/.git/validate-default.trace" \
			test_must_fail git write-tree --validate-cache-tree-only >actual 2>err &&
		test_must_be_empty actual &&
		test_grep "existing cache-tree is missing or invalid" err &&
		test_cache_tree_validation_state_unchanged &&
		test_path_is_missing "$nested_path" &&
		test_trace2_data cache_tree validate/valid-total 0 <.git/validate-default.trace &&
		test_trace2_data cache_tree validate/object-checks-total 2 <.git/validate-default.trace &&
		test_cache_tree_object_check_time .git/validate-default.trace 2 &&
		test_grep ! "\"category\":\"cache_tree\",\"label\":\"update\"" .git/validate-default.trace &&
		GIT_TEST_CACHE_TREE_OID_ORDER=1 \
		GIT_TRACE2_EVENT="$PWD/.git/validate-ordered.trace" \
			test_must_fail git write-tree --validate-cache-tree-only >actual 2>err &&
		test_must_be_empty actual &&
		test_cache_tree_validation_state_unchanged &&
		test_path_is_missing "$nested_path" &&
		test_trace2_data cache_tree validate/oid-order/probes "[1-3]" <.git/validate-ordered.trace &&
		validate_probes=$(sed -n "s|.*validate/oid-order/probes\",\"value\":\"\([1-3]\)\".*|\1|p" .git/validate-ordered.trace) &&
		test -n "$validate_probes" &&
		test_trace2_data cache_tree validate/valid-total 0 <.git/validate-ordered.trace &&
		test_trace2_data cache_tree validate/object-checks-total "$((2 + validate_probes))" <.git/validate-ordered.trace &&
		test_cache_tree_object_check_time .git/validate-ordered.trace "$((2 + validate_probes))" &&
		test_grep ! "\"category\":\"cache_tree\",\"label\":\"update\"" .git/validate-ordered.trace &&
		GIT_TEST_CACHE_TREE_OID_ORDER=0 \
		GIT_TRACE2_EVENT="$PWD/.git/default.trace" \
			git commit --allow-empty -m default &&
		git rev-parse HEAD^{tree} >actual &&
		test_cmp expect actual &&
		test_grep ! "\"key\":\"validate/oid-order/probes\"" .git/default.trace &&
		test_trace2_data commit as-is/cache-tree-valid 0 <.git/default.trace &&
		test_trace2_data commit as-is/cache-tree-validate/nodes 2 <.git/default.trace &&
		test_trace2_data commit as-is/cache-tree-validate/object-checks 2 <.git/default.trace &&
		test_commit_as_is_timer .git/default.trace cache-tree-update 1 &&
		rm -f "$nested_path" &&
		GIT_TEST_CACHE_TREE_OID_ORDER=1 \
		GIT_TRACE2_EVENT="$PWD/.git/ordered.trace" \
			git commit --allow-empty -m ordered &&
		git rev-parse HEAD^{tree} >actual &&
		test_cmp expect actual &&
		test_trace2_data cache_tree validate/oid-order/probes "[1-3]" <.git/ordered.trace &&
		probes=$(sed -n "s|.*validate/oid-order/probes\",\"value\":\"\([1-3]\)\".*|\1|p" .git/ordered.trace) &&
		test -n "$probes" &&
		test_trace2_data cache_tree validate/oid-order/fallback 1 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-checked 1 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-valid 0 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-validate/nodes 2 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-validate/object-checks "$((2 + probes))" <.git/ordered.trace &&
		test_commit_as_is_timer .git/ordered.trace cache-tree-update 1
	)
'

test_expect_success 'OID-ordered validation bypasses promised object fetches' '
	test_when_finished "rm -fr oid-order-promisor-client oid-order-promisor-server" &&
	git init --bare oid-order-promisor-server &&
	git init oid-order-promisor-client &&
	(
		cd oid-order-promisor-client &&
		git config gc.auto 0 &&
		mkdir nested &&
		printf "%s\n" content >nested/file &&
		git add nested &&
		git commit -m base &&
		nested_oid=$(git rev-parse HEAD:nested) &&
		git remote add origin ../oid-order-promisor-server &&
		git push origin HEAD:refs/heads/for-test &&
		git -C ../oid-order-promisor-server config \
			uploadpack.allowanysha1inwant true &&
		git config core.repositoryformatversion 1 &&
		git config extensions.partialclone origin &&
		git config remote.origin.promisor true &&
		rm "$(git rev-parse --git-path objects)/$(test_oid_to_path "$nested_oid")" &&
		snapshot_cache_tree_validation_state &&
		GIT_TEST_CACHE_TREE_OID_ORDER=1 \
		GIT_TRACE2_EVENT="$PWD/.git/validation-reject.trace" \
			test_must_fail git write-tree --validate-cache-tree-only >actual 2>err &&
		test_must_be_empty actual &&
		test_grep "unavailable with a promisor remote" err &&
		test_cache_tree_validation_state_unchanged &&
		test_path_is_missing "$(git rev-parse --git-path objects)/$(test_oid_to_path "$nested_oid")" &&
		test_grep ! "\"category\":\"cache_tree\",\"label\":\"validate\"" .git/validation-reject.trace &&
		GIT_TEST_CACHE_TREE_OID_ORDER=1 \
		GIT_TRACE2_EVENT="$PWD/.git/ordered.trace" \
			git commit --allow-empty -m fetched &&
		test_grep ! "\"key\":\"validate/oid-order/probes\"" .git/ordered.trace &&
		test_trace2_data cache_tree validate/oid-order/promisor-bypass 1 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-checked 1 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-valid 1 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-validate/nodes 2 <.git/ordered.trace &&
		test_trace2_data commit as-is/cache-tree-validate/object-checks 2 <.git/ordered.trace &&
		test_commit_as_is_timer .git/ordered.trace cache-tree-update absent &&
		git cat-file -e "$nested_oid"
	)
'

test_expect_success 'cache-tree is used by write-tree when valid' '
	test_commit use-valid &&
	test_when_finished "git checkout -- use-valid.t &&
		rm -f .git/cache-tree-validate.trace .git/cache-tree-ordered.trace \
			.git/cache-tree-validate-only-default.trace \
			.git/cache-tree-validate-only-ordered.trace \
			.git/cache-tree-ignore.trace \
			.git/cache-tree-stash.trace .git/validate-only.*" &&
	test-tool dump-cache-tree >actual &&
	nodes=$(grep -cv "#(ref)" actual) &&
	git rev-parse HEAD^{tree} >expect &&

	# write-tree with a valid cache-tree should skip cache_tree_update
	GIT_TRACE2_PERF="$(pwd)/trace.output" \
	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-validate.trace" \
	GIT_TRACE2_EVENT_NESTING=1 git write-tree >actual &&
	test_cmp expect actual &&
	test_grep ! region_enter.*cache_tree.*update trace.output &&
	test_trace2_data cache_tree validate/calls-total 1 <.git/cache-tree-validate.trace &&
	test_trace2_data cache_tree validate/valid-total 1 <.git/cache-tree-validate.trace &&
	test_trace2_data cache_tree validate/skipped-total 0 <.git/cache-tree-validate.trace &&
	test_trace2_data cache_tree validate/nodes-total "$nodes" <.git/cache-tree-validate.trace &&
	test_trace2_data cache_tree validate/object-checks-total "$nodes" <.git/cache-tree-validate.trace &&
	test_cache_tree_object_check_time .git/cache-tree-validate.trace "$nodes" &&

	GIT_TEST_CACHE_TREE_OID_ORDER=1 \
	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-ordered.trace" \
	GIT_TRACE2_EVENT_NESTING=2 git write-tree >actual &&
	test_cmp expect actual &&
	test_trace2_data cache_tree validate/oid-order/probes "$nodes" <.git/cache-tree-ordered.trace &&
	test_grep ! "\"key\":\"validate/oid-order/fallback\"" .git/cache-tree-ordered.trace &&
	test_trace2_data cache_tree validate/valid-total 1 <.git/cache-tree-ordered.trace &&
	test_trace2_data cache_tree validate/nodes-total "$nodes" <.git/cache-tree-ordered.trace &&
	test_trace2_data cache_tree validate/object-checks-total "$nodes" <.git/cache-tree-ordered.trace &&
	test_cache_tree_object_check_time .git/cache-tree-ordered.trace "$nodes" &&
	snapshot_cache_tree_validation_state &&
	GIT_TEST_CACHE_TREE_OID_ORDER=0 \
	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-validate-only-default.trace" \
	GIT_TRACE2_EVENT_NESTING=2 git write-tree --validate-cache-tree-only >actual &&
	test_cmp expect actual &&
	test_cache_tree_validation_state_unchanged &&
	test_trace2_data cache_tree validate/valid-total 1 <.git/cache-tree-validate-only-default.trace &&
	test_trace2_data cache_tree validate/object-checks-total "$nodes" <.git/cache-tree-validate-only-default.trace &&
	test_cache_tree_object_check_time .git/cache-tree-validate-only-default.trace "$nodes" &&
	GIT_TEST_CACHE_TREE_OID_ORDER=1 \
	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-validate-only-ordered.trace" \
	GIT_TRACE2_EVENT_NESTING=2 git write-tree --validate-cache-tree-only >actual &&
	test_cmp expect actual &&
	test_cache_tree_validation_state_unchanged &&
	test_trace2_data cache_tree validate/oid-order/probes "$nodes" <.git/cache-tree-validate-only-ordered.trace &&
	test_trace2_data cache_tree validate/valid-total 1 <.git/cache-tree-validate-only-ordered.trace &&
	test_trace2_data cache_tree validate/object-checks-total "$nodes" <.git/cache-tree-validate-only-ordered.trace &&
	test_cache_tree_object_check_time .git/cache-tree-validate-only-ordered.trace "$nodes" &&
	GIT_TRACE2_EVENT="$PWD/.git/validate-only.incompatible.trace" \
		test_must_fail git write-tree --validate-cache-tree-only \
			--ignore-cache-tree >actual 2>err &&
	test_must_be_empty actual &&
	test_grep "cannot be combined" err &&
	test_grep ! "\"category\":\"cache_tree\",\"label\":\"validate\"" \
		.git/validate-only.incompatible.trace &&
	test_cache_tree_validation_state_unchanged &&
	test_must_fail git write-tree --validate-cache-tree-only \
		--prefix=use-valid/ >actual 2>err &&
	test_must_be_empty actual &&
	test_grep "cannot be combined" err &&
	test_cache_tree_validation_state_unchanged &&

	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-ignore.trace" \
	GIT_TRACE2_EVENT_NESTING=2 \
		git --no-optional-locks write-tree --ignore-cache-tree >actual &&
	test_cmp expect actual &&
	test_trace2_data cache_tree validate/calls-total 1 <.git/cache-tree-ignore.trace &&
	test_trace2_data cache_tree validate/valid-total 0 <.git/cache-tree-ignore.trace &&
	test_trace2_data cache_tree validate/skipped-total 1 <.git/cache-tree-ignore.trace &&
	test_trace2_data cache_tree validate/nodes-total 0 <.git/cache-tree-ignore.trace &&
	test_trace2_data cache_tree validate/object-checks-total 0 <.git/cache-tree-ignore.trace &&
	test_cache_tree_object_check_time .git/cache-tree-ignore.trace 0 &&

	echo changed >>use-valid.t &&
	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-stash.trace" \
	GIT_TRACE2_EVENT_NESTING=2 git stash create >/dev/null &&
	test_trace2_data cache_tree validate/calls-total 2 <.git/cache-tree-stash.trace &&
	test_trace2_data cache_tree validate/valid-total 1 <.git/cache-tree-stash.trace >actual &&
	test_line_count = 2 actual &&
	test_trace2_data cache_tree validate/skipped-total 0 <.git/cache-tree-stash.trace >actual &&
	test_line_count = 2 actual &&
	test_trace2_data cache_tree validate/nodes-total "$((nodes + 1))" <.git/cache-tree-stash.trace &&
	test_trace2_data cache_tree validate/object-checks-total "$nodes" <.git/cache-tree-stash.trace >actual &&
	test_line_count = 2 actual &&
	test_cache_tree_object_check_time .git/cache-tree-stash.trace "$nodes" &&
	# The second validation rejects an invalid node before its ODB lookup.
	sed -n \
		"s/.*\"key\":\"validate\\/object-check-us-total\",\"value\":\"\\([0-9][0-9]*\\)\".*/\\1/p" \
		.git/cache-tree-stash.trace >actual &&
	test_line_count = 2 actual &&
	uniq actual >expect &&
	test_line_count = 1 expect
'

test_expect_success 'cache-tree lookup timing includes a failed validation but not rebuilding' '
	git write-tree >expect &&
	tree_oid=$(cat expect) &&
	tree_object=.git/objects/$(test_oid_to_path "$tree_oid") &&
	test_path_is_file "$tree_object" &&
	mv "$tree_object" "$tree_object.save" &&
	test_when_finished "rm -f \"$tree_object\" &&
		mv \"$tree_object.save\" \"$tree_object\"" &&
	test_when_finished "rm -f .git/cache-tree-missing.trace" &&
	GIT_TRACE2_EVENT="$PWD/.git/cache-tree-missing.trace" \
	GIT_TRACE2_EVENT_NESTING=2 \
		git --no-optional-locks write-tree >actual &&
	test_cmp expect actual &&
	git cat-file -e "$tree_oid^{tree}" &&
	test_region cache_tree update .git/cache-tree-missing.trace &&
	test_trace2_data cache_tree validate/calls-total 1 \
		<.git/cache-tree-missing.trace &&
	test_trace2_data cache_tree validate/valid-total 0 \
		<.git/cache-tree-missing.trace &&
	test_trace2_data cache_tree validate/skipped-total 0 \
		<.git/cache-tree-missing.trace &&
	test_trace2_data cache_tree validate/nodes-total 1 \
		<.git/cache-tree-missing.trace &&
	test_trace2_data cache_tree validate/object-checks-total 1 \
		<.git/cache-tree-missing.trace &&
	test_cache_tree_object_check_time .git/cache-tree-missing.trace 1
'

test_expect_success 'cache-tree update reports rebuilding and subtree reuse' '
	test_when_finished "rm -rf update-reuse" &&
	setup_cache_tree_update_repo update-reuse &&
	(
		cd update-reuse &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		git repack -ad &&
		git multi-pack-index write &&
		b_tree=$(git rev-parse HEAD:b) &&
		test_path_is_file .git/objects/pack/multi-pack-index &&
		test_path_is_missing ".git/objects/$(test_oid_to_path "$b_tree")" &&
		echo changed >a/file &&
		git add a/file &&
		cp .git/index .git/invalid.index &&
		run_cache_tree_update_trace 0 .git/expect git write-tree &&
		cp .git/index .git/expect.index &&
		cp .git/invalid.index .git/index &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			git write-tree &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		git cat-file -e "$(cat .git/actual)^{tree}" &&
		test_region cache_tree update .git/update.trace &&
		test_trace2_data cache_tree validate/valid-total 0 <.git/update.trace &&
		test_cache_tree_update_metrics .git/update.trace 1 0 3 1 0 0 2 1 &&
		test_trace2_data cache_tree update/entries-visited-total 3 <.git/update.trace &&
		test_trace2_data cache_tree update/entry-object-checks-total 3 <.git/update.trace &&
		test_trace2_data cache_tree update/reused-child-parent-checks-total 1 <.git/update.trace &&
		test_trace2_data cache_tree update/reuse-object-checks-total 1 <.git/update.trace &&
		test_trace2_data cache_tree update/reuse-object-probed-checks-total 1 <.git/update.trace &&
		if test_have_prereq ODB_MONOTONIC_CLOCK
		then
			test_trace2_data cache_tree update/reuse-packed-attempts-total 1 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-midx-searches-total 1 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-midx-resolves-total 1 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-fallbacks-total 0 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-invalid-total 0 <.git/update.trace
		else
			test_trace2_data cache_tree update/reuse-packed-attempts-total 0 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-invalid-total 1 <.git/update.trace
		fi &&
		test_trace2_data cache_tree update/repair-tree-checks-total 0 <.git/update.trace
	)
'

test_expect_success 'cache-tree update samples large reuse checks' '
	test_when_finished "rm -rf update-probes" &&
	setup_cache_tree_update_repo update-probes &&
	(
		cd update-probes &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		blob=$(git rev-parse HEAD:b/file) &&
		test_seq -f "d%04d/file" 1 1100 |
			sed "s|^|100644 $blob	|" |
			git update-index --index-info &&
		git commit -m many-directories &&
		git repack -ad &&
		git multi-pack-index write &&
		echo changed >a/file &&
		git add a/file &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			git write-tree &&
		git cat-file -e "$(cat .git/actual)^{tree}" &&
		test_trace2_data cache_tree update/reuse-object-checks-total 1101 <.git/update.trace &&
		test_trace2_data cache_tree update/reuse-object-probed-checks-total 1026 <.git/update.trace &&
		if test_have_prereq ODB_MONOTONIC_CLOCK
		then
			test_trace2_data cache_tree update/reuse-packed-attempts-total 1026 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-invalid-total 0 <.git/update.trace
		else
			test_trace2_data cache_tree update/reuse-packed-attempts-total 0 <.git/update.trace &&
			test_trace2_data cache_tree update/reuse-packed-invalid-total 1026 <.git/update.trace
		fi
	)
'

test_expect_success 'valid write-tree skips update diagnostics' '
	test_when_finished "rm -rf update-valid" &&
	setup_cache_tree_update_repo update-valid &&
	(
		cd update-valid &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		cp .git/index .git/expect.index &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			git write-tree &&
		test_cmp .git/base.tree .git/actual &&
		test_must_be_empty .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_region ! cache_tree update .git/update.trace &&
		test_grep ! "\"category\":\"cache_tree\",\"key\":\"update/" .git/update.trace &&
		test_grep ! "\"category\":\"cache_tree\",\"name\":\"update/" .git/update.trace
	)
'

test_expect_success 'ignoring cache-tree reports all rebuilt nodes without index writes' '
	test_when_finished "rm -rf update-ignore" &&
	setup_cache_tree_update_repo update-ignore &&
	(
		cd update-ignore &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		cp .git/index .git/expect.index &&
		run_cache_tree_update_trace 0 .git/expect git --no-optional-locks \
			write-tree --ignore-cache-tree &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			git --no-optional-locks write-tree --ignore-cache-tree &&
		test_cmp .git/base.tree .git/actual &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_region ! index do_write_index .git/update.trace &&
		test_trace2_data cache_tree validate/skipped-total 1 <.git/update.trace &&
		test_cache_tree_update_metrics .git/update.trace 1 0 3 0 0 0 3 1
	)
'

test_expect_success 'cache-tree repair reports hash-only work' '
	test_when_finished "rm -rf update-repair" &&
	setup_cache_tree_update_repo update-repair &&
	(
		cd update-repair &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",a/gitlink &&
		git write-tree >/dev/null &&
		cp .git/index .git/expect.index &&
		run_cache_tree_update_trace 0 .git/expect test-tool cache-tree --empty update &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			test-tool cache-tree --empty update &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_cache_tree_update_metrics .git/update.trace 1 0 3 0 0 3 0 1 &&
		test_trace2_data cache_tree update/entries-visited-total 5 <.git/update.trace &&
		test_trace2_data cache_tree update/entry-object-checks-total 4 <.git/update.trace &&
		test_trace2_data cache_tree update/repair-tree-checks-total 3 <.git/update.trace &&
		test_trace2_data cache_tree update/reuse-object-checks-total 0 <.git/update.trace
	)
'

test_expect_success 'cache-tree dry-run reports hash-only work' '
	test_when_finished "rm -rf update-dryrun" &&
	setup_cache_tree_update_repo update-dryrun &&
	(
		cd update-dryrun &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		cp .git/index .git/expect.index &&
		run_cache_tree_update_trace 0 .git/expect test-tool dump-cache-tree &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			test-tool dump-cache-tree &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_cache_tree_update_metrics .git/update.trace 1 0 3 0 0 3 0 1 &&
		test_trace2_data cache_tree update/repair-tree-checks-total 0 <.git/update.trace
	)
'

test_expect_success 'cache-tree update does not count an enclosing ODB commit' '
	test_when_finished "rm -rf update-inflight" &&
	setup_cache_tree_update_repo update-inflight &&
	(
		cd update-inflight &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		cp .git/index .git/expect.index &&
		run_cache_tree_update_trace 0 .git/expect test-tool cache-tree --empty --transaction update &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			test-tool cache-tree --empty --transaction update &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_cache_tree_update_metrics .git/update.trace 1 0 3 0 0 3 0 0
	)
'

test_expect_success 'cache-tree update counts sparse-directory shortcuts separately' '
	test_when_finished "rm -rf update-sparse" &&
	setup_cache_tree_update_repo update-sparse &&
	(
		cd update-sparse &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		git sparse-checkout set --cone --sparse-index a &&
		git ls-files --sparse >.git/entries &&
		test_line_count = 2 .git/entries &&
		test_grep "^b/$" .git/entries &&
		cp .git/index .git/expect.index &&
		run_cache_tree_update_trace 0 .git/expect git --no-optional-locks \
			write-tree --ignore-cache-tree &&
		run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			git --no-optional-locks write-tree --ignore-cache-tree &&
		test_cmp .git/base.tree .git/actual &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_cache_tree_update_metrics .git/update.trace 1 0 3 0 1 0 2 1 &&
		test_trace2_data cache_tree update/reused-child-parent-checks-total 0 <.git/update.trace
	)
'

test_expect_success 'cache-tree update reports returned failures' '
	test_when_finished "rm -rf update-failure" &&
	setup_cache_tree_update_repo update-failure &&
	(
		cd update-failure &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		echo missing >a/file &&
		git add a/file &&
		cp .git/index .git/expect.index &&
		blob=$(git rev-parse :a/file) &&
		mv ".git/objects/$(test_oid_to_path "$blob")" .git/missing-blob &&
		test_expect_code 128 run_cache_tree_update_trace 0 .git/expect \
			git --no-optional-locks write-tree &&
		test_expect_code 128 run_cache_tree_update_trace "$PWD/.git/update.trace" .git/actual \
			git --no-optional-locks write-tree &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		test_region cache_tree update .git/update.trace &&
		test_cache_tree_update_metrics .git/update.trace 1 1 2 0 0 0 0 1
	)
'

test_expect_success 'cache-tree update totals accumulate across returning regions' '
	test_when_finished "rm -rf update-repeat" &&
	setup_cache_tree_update_repo update-repeat &&
	(
		cd update-repeat &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		echo staged >a/file &&
		git add a/file &&
		echo unstaged >b/file &&
		cp .git/index .git/invalid.index &&
		test_tick &&
		run_cache_tree_update_trace 0 .git/expect git stash create &&
		cp .git/index .git/expect.index &&
		cp .git/invalid.index .git/index &&
		GIT_TRACE2=0 GIT_TRACE2_PERF=0 \
		GIT_TRACE2_EVENT="$PWD/.git/update.trace" GIT_TRACE2_EVENT_NESTING=100 \
			git stash create >.git/actual 2>.git/actual.err &&
		test_cmp .git/expect .git/actual &&
		test_cmp .git/expect.err .git/actual.err &&
		test_cmp .git/expect.index .git/index &&
		git cat-file -e "$(cat .git/actual)^{commit}" &&
		update_calls=$(grep -c "\"event\":\"region_leave\".*\"category\":\"cache_tree\",\"label\":\"update\"" \
			.git/update.trace) &&
		test "$update_calls" -ge 2 &&
		test_cache_tree_update_metrics .git/update.trace "$update_calls" 0 \
			"[0-9][0-9]*" "[0-9][0-9]*" 0 "[0-9][0-9]*" \
			"[0-9][0-9]*" "$update_calls" &&
		update_nodes=$(cache_tree_update_value .git/update.trace nodes) &&
		update_reused=$(cache_tree_update_value .git/update.trace reused) &&
		update_hash_only=$(cache_tree_update_value .git/update.trace hash-only-nodes) &&
		update_writes=$(cache_tree_update_value .git/update.trace object-write-calls) &&
		test "$update_writes" -gt 0 &&
		test "$update_nodes" = "$((update_reused + update_hash_only + update_writes))" &&
		test_cache_tree_update_bound .git/update.trace "$update_calls"
	)
'

test_expect_success 'validation-only keeps a split shared index unchanged' '
	test_when_finished "rm -rf validate-only-split" &&
	setup_cache_tree_update_repo validate-only-split &&
	(
		cd validate-only-split &&
		git update-index --split-index &&
		base=$(test-tool dump-split-index .git/index | sed -n "s/^base //p") &&
		test -n "$base" &&
		shared=".git/sharedindex.$base" &&
		test_path_is_file "$shared" &&
		test-tool chmtime =-3600 "$shared" &&
		test-tool chmtime --get "$shared" >.git/expect.shared.mtime &&
		snapshot_cache_tree_validation_state &&
		GIT_TRACE2_EVENT="$PWD/.git/valid.trace" \
			git write-tree --validate-cache-tree-only >actual &&
		test_cmp .git/base.tree actual &&
		test_cache_tree_validation_state_unchanged &&
		test-tool chmtime --get "$shared" >.git/actual.shared.mtime &&
		test_cmp .git/expect.shared.mtime .git/actual.shared.mtime &&
		test_trace2_data cache_tree validate/valid-total 1 <.git/valid.trace &&
		test_cache_tree_object_check_time .git/valid.trace 3 &&
		echo changed >a/file &&
		git add a/file &&
		test_invalid_cache_tree a/ &&
		base=$(test-tool dump-split-index .git/index | sed -n "s/^base //p") &&
		test -n "$base" &&
		shared=".git/sharedindex.$base" &&
		test_path_is_file "$shared" &&
		test-tool chmtime =-3600 "$shared" &&
		test-tool chmtime --get "$shared" >.git/expect.shared.mtime &&
		snapshot_cache_tree_validation_state &&
		GIT_TRACE2_EVENT="$PWD/.git/invalid.trace" \
			test_must_fail git write-tree --validate-cache-tree-only >actual 2>err &&
		test_must_be_empty actual &&
		test_grep "existing cache-tree is missing or invalid" err &&
		test_cache_tree_validation_state_unchanged &&
		test-tool chmtime --get "$shared" >.git/actual.shared.mtime &&
		test_cmp .git/expect.shared.mtime .git/actual.shared.mtime &&
		test_trace2_data cache_tree validate/valid-total 0 <.git/invalid.trace &&
		test_trace2_data cache_tree validate/object-checks-total 0 <.git/invalid.trace &&
		test_cache_tree_object_check_time .git/invalid.trace 0 &&
		test_grep ! "\"category\":\"cache_tree\",\"label\":\"update\"" .git/invalid.trace
	)
'

test_expect_success 'validation-only avoids sparse conversion and config writes' '
	test_when_finished "rm -rf validate-only-sparse" &&
	setup_cache_tree_update_repo validate-only-sparse &&
	(
		cd validate-only-sparse &&
		sane_unset GIT_TEST_SPLIT_INDEX GIT_TEST_SPARSE_INDEX &&
		git sparse-checkout set --cone --no-sparse-index a &&
		git write-tree >actual &&
		test_cmp .git/base.tree actual &&
		test_path_is_file .git/config.worktree &&
		cp .git/config .git/expect.config &&
		cp .git/config.worktree .git/expect.config.worktree &&
		snapshot_cache_tree_validation_state &&
		GIT_TEST_SPARSE_INDEX=1 \
		GIT_TRACE2_EVENT="$PWD/.git/sparse.trace" \
			git write-tree --validate-cache-tree-only >actual &&
		test_cmp .git/base.tree actual &&
		test_cache_tree_validation_state_unchanged &&
		test_cmp_bin .git/expect.config .git/config &&
		test_cmp_bin .git/expect.config.worktree .git/config.worktree &&
		test_trace2_data cache_tree validate/valid-total 1 <.git/sparse.trace &&
		test_cache_tree_object_check_time .git/sparse.trace 3 &&
		test_grep ! "\"category\":\"index\",\"label\":\"convert_to_sparse\"" .git/sparse.trace
	)
'

test_expect_success 'validation-only skips an enabled FSMonitor hook' '
	test_when_finished "rm -rf validate-only-fsmonitor" &&
	setup_cache_tree_update_repo validate-only-fsmonitor &&
	(
		cd validate-only-fsmonitor &&
		git config fsmonitor.allowRemote true &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			echo invoked >.git/fsmonitor-invoked
			printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_path_is_file .git/fsmonitor-invoked &&
		rm .git/fsmonitor-invoked &&
		snapshot_cache_tree_validation_state &&
		GIT_TRACE2_EVENT="$PWD/.git/fsmonitor.trace" \
			git write-tree --validate-cache-tree-only >actual &&
		test_cmp .git/base.tree actual &&
		test_cache_tree_validation_state_unchanged &&
		test_path_is_missing .git/fsmonitor-invoked &&
		test_trace2_data cache_tree validate/valid-total 1 <.git/fsmonitor.trace &&
		test_cache_tree_object_check_time .git/fsmonitor.trace 3
	)
'

test_expect_success 'validation-only rejects an index without cache-tree' '
	test_when_finished "rm -rf validate-only-absent" &&
	setup_cache_tree_update_repo validate-only-absent &&
	(
		cd validate-only-absent &&
		test-tool scrap-cache-tree &&
		test_no_cache_tree &&
		snapshot_cache_tree_validation_state &&
		GIT_TRACE2_EVENT="$PWD/.git/absent.trace" \
			test_must_fail git write-tree --validate-cache-tree-only >actual 2>err &&
		test_must_be_empty actual &&
		test_grep "existing cache-tree is missing or invalid" err &&
		test_cache_tree_validation_state_unchanged &&
		test_trace2_data cache_tree validate/valid-total 0 <.git/absent.trace &&
		test_trace2_data cache_tree validate/object-checks-total 0 <.git/absent.trace &&
		test_cache_tree_object_check_time .git/absent.trace 0 &&
		test_grep ! "\"category\":\"cache_tree\",\"label\":\"update\"" \
			.git/absent.trace
	)
'

test_done

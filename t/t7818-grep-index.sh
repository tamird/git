#!/bin/sh

test_description='git grep content index'

. ./test-lib.sh

test_lazy_prereq ENHANCED_BRE '
	test-tool regex --silent "a\|b" a
'

test_lazy_prereq BRE_WORD_BOUNDARY '
	test-tool regex --silent "\\bfoo\\b" foo
'

test_lazy_prereq MULTI_CPU '
	test "$(test-tool online-cpus)" -gt 1
'

test_lazy_prereq PCRE2_UTF8_LOCALE '
	test_have_prereq LIBPCRE2 &&
	LC_ALL=en_US.UTF-8 git -C "$TRASH_DIRECTORY" grep --cached \
		--no-content-index --quiet -i \
		"non-ascii k contents" -- non-ascii
'

test_lazy_prereq REGEX_MATCH_ERROR '
	invalid=$(printf "\\377foo") &&
	LC_ALL=C test-tool regex --silent "foo|bar" "$invalid" EXTENDED &&
	invalid_status=$(
		LC_ALL=en_US.UTF-8 test-tool regex --silent \
			"foo|bar" "$invalid" EXTENDED
		echo $?
	) &&
	nomatch_status=$(
		LC_ALL=en_US.UTF-8 test-tool regex --silent \
			"foo|bar" absent EXTENDED
		echo $?
	) &&
	test "$invalid_status" -ne 0 &&
	test "$invalid_status" != "$nomatch_status"
'

test_lazy_prereq SJIS_REGEX_NOMATCH '
	invalid=$(printf "\\202foo") &&
	LC_ALL=C test-tool regex --silent \
		"foo|absent" "$invalid" EXTENDED &&
	sjis_status=$(
		LC_ALL=ja_JP.SJIS test-tool regex --silent \
			"foo|absent" "$invalid" EXTENDED
		echo $?
	) &&
	nomatch_status=$(
		LC_ALL=ja_JP.SJIS test-tool regex --silent \
			absent present EXTENDED
		echo $?
	) &&
	test "$sjis_status" -ne 0 &&
	test "$sjis_status" = "$nomatch_status"
'

wait_for_file_value () {
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
	do
		test -f "$1" && test "$(cat "$1")" = "$2" && return 0
		sleep 1
	done
	return 1
}

wait_for_file_sum () {
	expected=$1
	shift
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
	do
		sum=0
		complete=t
		for file
		do
			if ! test -f "$file"
			then
				complete=
				break
			fi
			value=$(cat "$file")
			case "$value" in
			""|*[!0-9]*)
				complete=
				break
				;;
			esac
			sum=$((sum + value))
		done
		test -n "$complete" && test "$sum" = "$expected" && return 0
		sleep 1
	done
	return 1
}

test_expect_success 'setup' '
	printf x >short &&
	printf ab >fixed-pcre &&
	echo "present needle" >present &&
	echo "import sample_ext.vendor_internal" >agent-regex &&
	echo "ordinary contents" >ordinary &&
	echo "abc bcd cde def efg fgh gh(" >negative-required-ere &&
	echo "abcdefgh(" >positive-required-ere &&
	echo "Xabcdefgh(" >negative-context-ere &&
	echo "import sample_ext.__private" >escaped-dot &&
	echo "present.needle" >escaped-dot-ere &&
	echo ".a" >escaped-dot-quantified &&
	echo "resolve_reference xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx (" \
		>escaped-call-negative &&
	echo "resolve_reference(" >escaped-call-positive &&
	echo "foobar" >escaped-call-optional &&
	echo "foo(ar" >escaped-call-right-quantified &&
	echo "other_call[" >escaped-call-alternative &&
	echo ".ab" >escaped-bridge-positive &&
	echo "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx .zz" \
		>escaped-bridge-negative &&
	cat >escaped-literal-positive <<-\EOF &&
	star_left*star_right
	question_left?question_right
	bracket_left[bracket_right
	bracket_pair_left[bracket_pair_right]
	slash_left\slash_right
	dollar_left$dollar_right
	open_left(open_right
	close_left)close_right
	plus_left+plus_right
	dot_left.dot_right
	caret_left^caret_right
	brace_left{brace_right
	pipe_left|pipe_right
	EOF
	printf "non-ascii \342\204\252 contents\n" >non-ascii &&
	printf "long \305\277 value\n" >long-s &&
	echo "from _private" >outer-from &&
	echo "import _private" >outer-import &&
	echo "from _p)" >outer-boundary &&
	echo "from unicorn_sfi.eval.chz" >mixed-unicorn &&
	echo "import gunicorn.conf" >mixed-gunicorn &&
	echo "class Image" >escaped-ere-atom &&
	echo "from present.private" >structured-from &&
	echo "import ordinary.internal" >structured-import &&
	echo "from libdemo_cpp.internal" >structured-middle-from &&
	echo "import libdemo_cpp_ext.private" >structured-middle-import &&
	echo "frm present" >structured-optional &&
	echo "global_ test dev _requirements" >ere-concat &&
	echo "global_test_requirements" >ere-concat-test &&
	echo "global_dev_requirements" >ere-concat-dev &&
	echo "standalone_present" >ere-mixed-plain &&
	echo "prefoo.suf" >ere-concat-foo &&
	echo "prebarsuf" >ere-concat-bar &&
	echo "xfoobary" >ere-concat-repeat &&
	echo "NAME = require_monorepo()" >quantified-ordinary-assignment &&
	echo "prefixsuffix" >quantified-ordinary-zero &&
	echo "prefixxsuffix" >quantified-ordinary-one &&
	printf "%s\n" "literal|()[]\\suffix" >escaped-ere &&
	for i in $(test_seq 1 40)
	do
		if test "$i" -le 20
		then
			prefix=a
		else
			prefix=z
		fi &&
		path=$(printf "literal-candidate-%s-%02d" "$prefix" "$i") &&
		echo "literal candidate contents $i" >"$path" ||
		return 1
	done &&
	echo "literal mixed candidate needle" >literal-candidate-z-40 &&
	git add short fixed-pcre present agent-regex ordinary \
		negative-required-ere positive-required-ere negative-context-ere \
		escaped-dot \
		escaped-dot-ere escaped-dot-quantified non-ascii outer-from \
		escaped-call-negative escaped-call-positive \
		escaped-call-optional escaped-call-right-quantified \
		escaped-call-alternative escaped-literal-positive \
		escaped-bridge-positive escaped-bridge-negative \
		long-s outer-import outer-boundary mixed-unicorn mixed-gunicorn \
		escaped-ere-atom structured-from structured-import \
		structured-middle-from structured-middle-import \
		structured-optional ere-concat ere-concat-test ere-concat-dev \
		ere-mixed-plain ere-concat-foo ere-concat-bar \
		ere-concat-repeat quantified-ordinary-assignment \
		quantified-ordinary-zero quantified-ordinary-one escaped-ere \
		literal-candidate-* &&
	git commit -m initial
'

test_expect_success 'content index query wire versions' '
	test-tool grep-index-ipc query-wire
'

test_expect_success FSMONITOR_DAEMON 'daemon shares concurrent grep workers' '
	test_when_finished "
		if test -n \"\$grep_worker_pids\"
		then
			kill \$grep_worker_pids 2>/dev/null || true
		fi &&
		touch release-1 release-2 release-3 release-4 release-5 \
			release-6 release-7 release-8 &&
		test_might_fail git fsmonitor--daemon stop &&
		test_might_fail git config --unset core.fsmonitor &&
		rm -f worker-start acquired-1 acquired-2 acquired-3 \
			release-1 release-2 release-3 worker-start-over \
			acquired-4 acquired-5 acquired-6 acquired-7 \
			acquired-8 release-4 release-5 release-6 release-7 \
			release-8" &&
	git config core.fsmonitor true &&
	GIT_TEST_GREP_WORKER_CAPACITY=4 \
		git fsmonitor--daemon start &&
	grep_worker_pids= &&
	{
		test-tool grep-index-ipc 4 worker-start acquired-1 release-1 &
		grep_worker_1=$!
	} &&
	grep_worker_pids="$grep_worker_1" &&
	{
		test-tool grep-index-ipc 4 worker-start acquired-2 release-2 &
		grep_worker_2=$!
	} &&
	grep_worker_pids="$grep_worker_pids $grep_worker_2" &&
	touch worker-start &&
	wait_for_file_value acquired-1 2 &&
	wait_for_file_value acquired-2 2 &&
	{
		test-tool grep-index-ipc 4 worker-start acquired-3 release-3 &
		grep_worker_3=$!
	} &&
	grep_worker_pids="$grep_worker_pids $grep_worker_3" &&
	wait_for_file_value acquired-3 1 &&
	wait_for_file_sum 4 acquired-1 acquired-2 acquired-3 &&
	test "$(cat acquired-1)" -ge 1 &&
	test "$(cat acquired-2)" -ge 1 &&
	kill "$grep_worker_1" &&
	! wait "$grep_worker_1" &&
	wait_for_file_value acquired-2 2 &&
	wait_for_file_value acquired-3 2 &&
	touch release-2 release-3 &&
	wait "$grep_worker_2" &&
	wait "$grep_worker_3" &&
	grep_worker_pids= &&
	{
		test-tool grep-index-ipc 4 worker-start-over \
			acquired-4 release-4 &
		grep_worker_4=$!
	} &&
	{
		test-tool grep-index-ipc 4 worker-start-over \
			acquired-5 release-5 &
		grep_worker_5=$!
	} &&
	{
		test-tool grep-index-ipc 4 worker-start-over \
			acquired-6 release-6 &
		grep_worker_6=$!
	} &&
	{
		test-tool grep-index-ipc 4 worker-start-over \
			acquired-7 release-7 &
		grep_worker_7=$!
	} &&
	{
		test-tool grep-index-ipc 4 worker-start-over \
			acquired-8 release-8 &
		grep_worker_8=$!
	} &&
	grep_worker_pids="$grep_worker_4 $grep_worker_5 $grep_worker_6 \
		$grep_worker_7 $grep_worker_8" &&
	touch worker-start-over &&
	wait_for_file_sum 4 acquired-4 acquired-5 acquired-6 \
		acquired-7 acquired-8 &&
	touch release-4 release-5 release-6 release-7 release-8 &&
	wait "$grep_worker_4" &&
	wait "$grep_worker_5" &&
	wait "$grep_worker_6" &&
	wait "$grep_worker_7" &&
	wait "$grep_worker_8" &&
	grep_worker_pids=
'

test_expect_success FSMONITOR_DAEMON,MULTI_CPU 'daemon holds content index in memory' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git config --unset core.fsmonitor" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	test_path_is_missing .git/objects/info/grep-index/chain &&
	test_when_finished "rm -f auto-thread.trace explicit-thread.trace configured-thread.trace" &&
	GIT_TRACE2_EVENT="$PWD/auto-thread.trace" \
		git grep --cached --no-content-index --threads=0 \
			"present needle" >/dev/null &&
	test_grep "\"key\":\"worker_lease/active\",\"value\":\"1\"" \
		auto-thread.trace &&
	test_grep "\"key\":\"worker_lease/released\",\"value\":\"1\"" \
		auto-thread.trace &&
	GIT_TRACE2_EVENT="$PWD/explicit-thread.trace" \
		git grep --cached --no-content-index --threads=3 \
			"present needle" >/dev/null &&
	! test_grep "worker_lease/" explicit-thread.trace &&
	GIT_TRACE2_EVENT="$PWD/configured-thread.trace" \
		git -c grep.threads=3 grep --cached --no-content-index \
			"present needle" >/dev/null &&
	! test_grep "worker_lease/" configured-thread.trace &&
	test_must_fail git grep --cached "absent daemon pattern" &&
	echo "present:present needle" >expect &&
	git grep --cached "present needle" -- present >actual &&
	test_cmp expect actual &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	if test_have_prereq LIBPCRE2
	then
		test_must_fail git grep --cached -i \
			"absent daemon pattern" &&
		mv "$object" "$object.memory-save" &&
		test_when_finished "test ! -e \"$object.memory-save\" ||
				    mv \"$object.memory-save\" \"$object\"" &&
		test_must_fail git grep --cached -i \
			"ABSENT DAEMON PATTERN" -- short 2>err-memory &&
		test_must_be_empty err-memory &&
		mv "$object.memory-save" "$object" &&

		non_ascii_oid=$(git rev-parse :non-ascii) &&
		non_ascii_object=.git/objects/$(test_oid_to_path \
			"$non_ascii_oid") &&
		mv "$non_ascii_object" "$non_ascii_object.memory-save" &&
		test_when_finished "test ! -e \
			\"$non_ascii_object.memory-save\" ||
			mv \"$non_ascii_object.memory-save\" \
				\"$non_ascii_object\"" &&
		test_must_fail git grep --cached -i \
			"absent daemon pattern" \
			-- non-ascii 2>err-memory-non-ascii &&
		test_must_be_empty err-memory-non-ascii &&
		mv "$non_ascii_object.memory-save" "$non_ascii_object"
	fi &&

	replacement=$(echo "absent daemon pattern" | git hash-object -w --stdin) &&
	git replace "$oid" "$replacement" &&
	echo "short:absent daemon pattern" >expect &&
	git grep --cached "absent daemon pattern" -- short >actual &&
	test_cmp expect actual &&
	git replace -d "$oid" &&

	git worktree add --detach daemon-wt &&
	test_when_finished "test_might_fail git -C daemon-wt \
				fsmonitor--daemon stop &&
			    git worktree remove --force daemon-wt" &&
	git -C daemon-wt fsmonitor--daemon status &&

	echo "daemon unknown contents" >daemon-unknown &&
	git add daemon-unknown &&
	test_when_finished "git reset --hard HEAD" &&
	unknown_oid=$(git rev-parse :daemon-unknown) &&
	git grep-index --no-progress &&
	test_when_finished "rm -rf .git/objects/info/grep-index" &&
	unknown_object=.git/objects/$(test_oid_to_path "$unknown_oid") &&
	mv "$unknown_object" "$unknown_object.save" &&
	test_when_finished "mv \"$unknown_object.save\" \"$unknown_object\"" &&
	test_must_fail git grep --cached "absent daemon pattern" \
		-- daemon-unknown 2>err-unknown &&
	test_must_be_empty err-unknown &&

	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent daemon pattern" 2>err &&
	test_must_fail git -C daemon-wt grep --cached \
		"absent daemon pattern" 2>err-wt &&
	test_must_be_empty err &&
	test_must_be_empty err-wt &&

	git fsmonitor--daemon stop &&
	test_must_fail git -C daemon-wt grep --cached \
		"absent daemon pattern" 2>err-takeover &&
	test_must_be_empty err-takeover
'

test_expect_success FSMONITOR_DAEMON 'daemon rotates saturated content cache' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git config --unset core.fsmonitor" &&
	git config core.fsmonitor true &&
	GIT_TEST_GREP_INDEX_MEMORY_MAX_BYTES=8 \
		git fsmonitor--daemon start &&
	echo "first saturated cache object" >saturated-first &&
	echo "second saturated cache object" >saturated-second &&
	git add saturated-first saturated-second &&
	test_when_finished "git reset --hard HEAD" &&
	first_oid=$(git rev-parse :saturated-first) &&
	second_oid=$(git rev-parse :saturated-second) &&
	test_must_fail git grep --cached "absent saturated pattern" \
		-- saturated-first &&
	test_must_fail git grep --cached "absent saturated pattern" \
		-- saturated-second &&
	first_object=.git/objects/$(test_oid_to_path "$first_oid") &&
	mv "$first_object" "$first_object.save" &&
	test_when_finished "test ! -e \"$first_object.save\" ||
			    mv \"$first_object.save\" \"$first_object\"" &&
	test_must_fail git grep --cached "different absent saturated pattern" \
		-- saturated-first 2>err-first &&
	test_must_be_empty err-first &&
	mv "$first_object.save" "$first_object" &&
	test_must_fail git grep --cached "absent saturated pattern" \
		-- saturated-second &&
	test_must_fail git grep --cached "absent saturated pattern" \
		-- saturated-second &&
	second_object=.git/objects/$(test_oid_to_path "$second_oid") &&
	mv "$second_object" "$second_object.save" &&
	test_when_finished "mv \"$second_object.save\" \"$second_object\"" &&
	test_must_fail git grep --cached "different absent saturated pattern" \
		-- saturated-second 2>err &&
	test_must_be_empty err
'

test_expect_success 'setup indexed pickaxe history' '
	echo "pickaxe needle old" >pickaxe-old &&
	echo "pickaxe daemon old" >pickaxe-daemon-history &&
	cp pickaxe-old pickaxe-deleted &&
	echo "pickaxe replacement" >pickaxe-new &&
	printf "pickaxe binary old\\0" >pickaxe-binary-old &&
	cp pickaxe-binary-old pickaxe-binary &&
	cp pickaxe-old pickaxe-history &&
	git add pickaxe-old pickaxe-new pickaxe-history \
		pickaxe-daemon-history pickaxe-deleted \
		pickaxe-binary-old pickaxe-binary &&
	git commit -m "pickaxe old" &&
	cp pickaxe-new pickaxe-history &&
	cp pickaxe-new pickaxe-daemon-history &&
	printf "pickaxe binary new\\0" >pickaxe-binary &&
	git rm pickaxe-deleted &&
	git add pickaxe-history pickaxe-daemon-history pickaxe-binary &&
	git commit -m "pickaxe new"
'

test_expect_success 'write shared content index' '
	git grep-index --no-progress &&
	test_path_is_file .git/objects/info/grep-index/chain &&
	test_line_count = 1 .git/objects/info/grep-index/chain &&
	segment=$(cat .git/objects/info/grep-index/chain) &&
	test_path_is_file .git/objects/info/grep-index/grep-$segment.idx
'

test_expect_success 'write commit edge and endpoint content indexes' '
	cp .git/objects/info/grep-index/chain commit-chain.before &&
	cp .git/objects/info/grep-index/chain-transposed \
		commit-chain-transposed.before &&
	test_when_finished "mv commit-chain.before \
		.git/objects/info/grep-index/chain &&
		mv commit-chain-transposed.before \
		.git/objects/info/grep-index/chain-transposed" &&
	rm .git/objects/info/grep-index/chain-transposed &&

	old_oid=$(git rev-parse :pickaxe-old) &&
	new_oid=$(git rev-parse :pickaxe-new) &&
	other_oid=$(echo "pickaxe sidecar endpoint" |
		git hash-object -w --stdin) &&
	old_tree=$(printf "100644 blob %s\tprobe\n" "$old_oid" |
		git mktree) &&
	new_tree=$(printf "100644 blob %s\tprobe\n" "$new_oid" |
		git mktree) &&
	other_tree=$(printf "100644 blob %s\tprobe\n" "$other_oid" |
		git mktree) &&
	old_commit=$(echo old | git commit-tree "$old_tree") &&
	middle_commit=$(echo middle |
		git commit-tree "$new_tree" -p "$old_commit") &&
	sibling_commit=$(echo sibling |
		git commit-tree "$other_tree" -p "$old_commit") &&
	new_commit=$(echo new |
		git commit-tree "$old_tree" -p "$middle_commit") &&
	git update-ref refs/grep-index-test/old "$old_commit" &&
	git update-ref refs/grep-index-test/middle "$middle_commit" &&
	git update-ref refs/grep-index-test/sibling "$sibling_commit" &&
	git update-ref refs/grep-index-test/new "$new_commit" &&
	git grep-index --commit-edges \
		refs/grep-index-test/old..refs/grep-index-test/middle \
		refs/grep-index-test/old..refs/grep-index-test/sibling &&
	test_path_is_file .git/objects/info/grep-index/commit-edges-chain &&
	test_line_count = 1 \
		.git/objects/info/grep-index/commit-edges-chain &&
	segment=$(cat .git/objects/info/grep-index/commit-edges-chain) &&
	test_path_is_file \
		.git/objects/info/grep-index/commit-edges-$segment.idx &&
	test_line_count = 2 .git/objects/info/grep-index/chain &&
	test_line_count = 1 .git/objects/info/grep-index/chain-transposed &&

	other_object=.git/objects/$(test_oid_to_path "$other_oid") &&
	mv "$other_object" "$other_object.save" &&
	test_when_finished "mv \"$other_object.save\" \"$other_object\"" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sabsent \
		refs/grep-index-test/sibling >actual 2>err &&
	test_must_be_empty actual &&
	test_must_be_empty err
'

test_expect_success 'commit index prunes pickaxe tree diff' '
	test_when_finished "rm -f pickaxe-commit-index.trace" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sneedle \
		refs/grep-index-test/new >actual-fixed &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s -Sneedle \
		refs/grep-index-test/new >expect-fixed &&
	test_cmp expect-fixed actual-fixed &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-commit-index.trace" \
		git log --format=%s -Sabsent \
		refs/grep-index-test/new >actual 2>err &&
	test_must_be_empty actual &&
	test_must_be_empty err &&
	test_grep "\"key\":\"commit_index/pruned\",\"value\":\"1\"" \
		pickaxe-commit-index.trace
'

test_expect_success 'commit index reads legacy sidecar' '
	chain=.git/objects/info/grep-index/commit-edges-chain &&
	segment=$(cat "$chain") &&
	index=.git/objects/info/grep-index/commit-edges-$segment.idx &&
	legacy=.git/objects/info/grep-index/commit-edges &&
	mv "$chain" "$chain.save" &&
	mv "$index" "$legacy" &&
	test_when_finished "mv \"$legacy\" \"$index\" &&
		mv \"$chain.save\" \"$chain\" &&
		rm -f pickaxe-legacy.trace" &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-legacy.trace" \
		git log --format=%s -Sabsent \
		refs/grep-index-test/new >actual-legacy &&
	test_must_be_empty actual-legacy &&
	test_grep "\"key\":\"commit_index/pruned\",\"value\":\"1\"" \
		pickaxe-legacy.trace
'

test_expect_success 'commit index safely prunes scoped pickaxe' '
	test_when_finished "rm -f pickaxe-scoped.trace" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-scoped.trace" \
		git log --format=%s -Sabsent refs/grep-index-test/new \
		-- probe >actual-scoped &&
	test_must_be_empty actual-scoped &&
	test_grep "\"key\":\"commit_index/pruned\",\"value\":\"1\"" \
		pickaxe-scoped.trace &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sneedle refs/grep-index-test/new \
		-- probe >actual-scoped-positive &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s -Sneedle refs/grep-index-test/new \
		-- probe >expect-scoped-positive &&
	test_file_not_empty expect-scoped-positive &&
	test_cmp expect-scoped-positive actual-scoped-positive
'

test_expect_success 'commit index bypasses harder copies' '
	test_when_finished "rm -f pickaxe-copies.trace" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-copies.trace" \
		git log --find-copies-harder --format=%s -Sabsent \
		refs/grep-index-test/new >actual-copies &&
	test_must_be_empty actual-copies &&
	test_grep "\"key\":\"commit_index/tested\",\"value\":\"0\"" \
		pickaxe-copies.trace
'

test_expect_success 'commit index binds records to commits' '
	test_when_finished "rm -f pickaxe-corrupt.trace" &&
	segment=$(cat .git/objects/info/grep-index/commit-edges-chain) &&
	index=.git/objects/info/grep-index/commit-edges-$segment.idx &&
	mv "$index" "$index.save" &&
	test_when_finished "mv \"$index.save\" \"$index\"" &&
	rawsz=$(test_oid rawsz) &&
	metadata_size=$((16 + 256 * 4 + 2 * rawsz + 3 * 8)) &&
	file_size=$(wc -c <"$index.save") &&
	data_size=$((file_size - metadata_size - rawsz)) &&
	test $data_size = $((2 * (data_size / 2))) &&
	record_size=$((data_size / 2)) &&
	test_copy_bytes "$metadata_size" <"$index.save" >"$index" &&
	dd if="$index.save" bs=1 skip=$((metadata_size + record_size)) \
		count="$record_size" >>"$index" 2>/dev/null &&
	dd if="$index.save" bs=1 skip="$metadata_size" \
		count="$record_size" >>"$index" 2>/dev/null &&
	dd if="$index.save" bs=1 skip=$((metadata_size + data_size)) \
		>>"$index" 2>/dev/null &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-corrupt.trace" \
		git log --format=%s -Sneedle \
		refs/grep-index-test/new >actual-corrupt &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s -Sneedle \
		refs/grep-index-test/new >expect-corrupt &&
	test_cmp expect-corrupt actual-corrupt &&
	test_grep "\"key\":\"commit_index/tested\",\"value\":\"0\"" \
		pickaxe-corrupt.trace
'

test_expect_success 'commit index falls back from a corrupt record' '
	cp .git/objects/info/grep-index/chain fallback-chain.before &&
	cp .git/objects/info/grep-index/chain-transposed \
		fallback-chain-transposed.before &&
	test_when_finished "mv fallback-chain.before \
		.git/objects/info/grep-index/chain &&
		mv fallback-chain-transposed.before \
		.git/objects/info/grep-index/chain-transposed" &&
	git grep-index --commit-edges \
		refs/grep-index-test/old..refs/grep-index-test/new &&
	git grep-index --commit-edges \
		refs/grep-index-test/old..refs/grep-index-test/new \
		refs/grep-index-test/old..refs/grep-index-test/sibling &&
	test_line_count = 3 \
		.git/objects/info/grep-index/commit-edges-chain &&
	segment=$(tail -n 1 \
		.git/objects/info/grep-index/commit-edges-chain) &&
	index=.git/objects/info/grep-index/commit-edges-$segment.idx &&
	mv "$index" "$index.save" &&
	test_when_finished "mv \"$index.save\" \"$index\" &&
		rm -f pickaxe-fallback.trace" &&
	rawsz=$(test_oid rawsz) &&
	metadata_size=$((16 + 256 * 4 + 3 * rawsz + 4 * 8)) &&
	file_size=$(wc -c <"$index.save") &&
	data_size=$((file_size - metadata_size - rawsz)) &&
	test $data_size = $((3 * (data_size / 3))) &&
	record_size=$((data_size / 3)) &&
	test_copy_bytes "$metadata_size" <"$index.save" >"$index" &&
	dd if="$index.save" bs=1 skip=$((metadata_size + record_size)) \
		count=$((2 * record_size)) >>"$index" 2>/dev/null &&
	dd if="$index.save" bs=1 skip="$metadata_size" \
		count="$record_size" >>"$index" 2>/dev/null &&
	dd if="$index.save" bs=1 skip=$((metadata_size + data_size)) \
		>>"$index" 2>/dev/null &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-fallback.trace" \
		git log --format=%s -Sabsent \
		refs/grep-index-test/new >actual-fallback &&
	test_must_be_empty actual-fallback &&
	test_grep "\"key\":\"commit_index/pruned\",\"value\":\"1\"" \
		pickaxe-fallback.trace
'

test_expect_success 'commit index ignores invalid manifest entries' '
	chain=.git/objects/info/grep-index/commit-edges-chain &&
	missing=$(test_oid zero) &&
	malformed=1${missing#?} &&
	cp "$chain" "$chain.save" &&
	test_when_finished "mv \"$chain.save\" \"$chain\" &&
		rm -f pickaxe-invalid-chain.trace \
		.git/objects/info/grep-index/commit-edges-$malformed.idx" &&
	test-tool genzeros 2048 \
		>.git/objects/info/grep-index/commit-edges-$malformed.idx &&
	chmod +w "$chain" &&
	echo invalid >>"$chain" &&
	echo "$missing" >>"$chain" &&
	echo "$malformed" >>"$chain" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-invalid-chain.trace" \
		git log --format=%s -Sabsent \
		refs/grep-index-test/new >actual-invalid-chain &&
	test_must_be_empty actual-invalid-chain &&
	test_grep "\"key\":\"commit_index/pruned\",\"value\":\"1\"" \
		pickaxe-invalid-chain.trace
'

test_expect_success 'commit index writer includes ignored gitlinks' '
	test_when_finished "rm -f pickaxe-missing-record.trace" &&
	old_commit=$(git rev-parse refs/grep-index-test/old) &&
	new_commit=$(git rev-parse refs/grep-index-test/middle) &&
	old_tree=$(printf "160000 commit %s\tsub\n" "$old_commit" |
		git mktree) &&
	new_tree=$(printf "160000 commit %s\tsub\n" "$new_commit" |
		git mktree) &&
	old_tip=$(echo gitlink-old | git commit-tree "$old_tree") &&
	new_tip=$(echo gitlink-new |
		git commit-tree "$new_tree" -p "$old_tip") &&
	git update-ref refs/grep-index-test/gitlink "$new_tip" &&
	test_config diff.ignoreSubmodules all &&
	git grep-index --commit-edges refs/grep-index-test/gitlink &&
	test_line_count = 4 \
		.git/objects/info/grep-index/commit-edges-chain &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-missing-record.trace" \
		git log --format=%s -Sabsent \
		refs/grep-index-test/new >actual-missing-record &&
	test_must_be_empty actual-missing-record &&
	test_grep "\"key\":\"commit_index/pruned\",\"value\":\"1\"" \
		pickaxe-missing-record.trace &&
	gitlink_oid=$(git rev-parse refs/grep-index-test/gitlink^:sub) &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --ignore-submodules=none --format=%s -S"$gitlink_oid" \
		refs/grep-index-test/gitlink >actual-gitlink &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --ignore-submodules=none --format=%s -S"$gitlink_oid" \
		refs/grep-index-test/gitlink >expect-gitlink &&
	test_file_not_empty expect-gitlink &&
	test_cmp expect-gitlink actual-gitlink
'

test_expect_success 'concurrent commit index writers preserve both segments' '
	test_create_repo concurrent-commit-index &&
	(
		cd concurrent-commit-index &&
		echo one >one &&
		git add one &&
		git commit -m one &&
		git branch one &&
		git switch --orphan two &&
		echo two >two &&
		git add two &&
		git commit -m two &&
		mkdir -p .git/objects/info/grep-index &&
		lock=.git/objects/info/grep-index/commit-edges-chain.lock &&
		>"$lock" &&

		{
			env GIT_TEST_GREP_INDEX_CHAIN_LOCK_READY="$PWD/ready.one" \
				git grep-index --no-progress --commit-edges refs/heads/one \
				>out.one 2>err.one &
		} &&
		pid_one=$! &&
		{
			env GIT_TEST_GREP_INDEX_CHAIN_LOCK_READY="$PWD/ready.two" \
				git grep-index --no-progress --commit-edges refs/heads/two \
				>out.two 2>err.two &
		} &&
		pid_two=$! &&
		trap "kill $pid_one $pid_two 2>/dev/null || : &&
			wait $pid_one $pid_two 2>/dev/null || :" 0 &&
		wait_for_file_value ready.one commit-edges-chain &&
		wait_for_file_value ready.two commit-edges-chain &&
		rm "$lock" &&
		wait "$pid_one"
		status_one=$? &&
		wait "$pid_two"
		status_two=$? &&
		trap - 0 &&
		test "$status_one" = 0 &&
		test "$status_two" = 0 &&
		test_must_be_empty out.one &&
		test_must_be_empty err.one &&
		test_must_be_empty out.two &&
		test_must_be_empty err.two &&
		test_line_count = 2 \
			.git/objects/info/grep-index/commit-edges-chain &&
		while read segment
		do
			test_path_is_file \
				.git/objects/info/grep-index/commit-edges-$segment.idx ||
			exit 1
		done <.git/objects/info/grep-index/commit-edges-chain
	)
'

test_expect_success 'content index prunes pickaxe blob reads' '
	old_oid=$(git rev-parse HEAD^:pickaxe-history) &&
	new_oid=$(git rev-parse HEAD:pickaxe-history) &&
	old_object=.git/objects/$(test_oid_to_path "$old_oid") &&
	new_object=.git/objects/$(test_oid_to_path "$new_oid") &&
	mv "$old_object" "$old_object.save" &&
	mv "$new_object" "$new_object.save" &&
	test_when_finished "mv \"$old_object.save\" \"$old_object\" &&
			    mv \"$new_object.save\" \"$new_object\"" &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual 2>err &&
	test_must_be_empty actual &&
	test_must_be_empty err &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"abs.nt" HEAD^..HEAD \
		-- pickaxe-history >actual-g 2>err-g &&
	test_must_be_empty actual-g &&
	test_must_be_empty err-g &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --pickaxe-regex -S"abs.nt" \
		HEAD^..HEAD -- pickaxe-history >actual-regex 2>err-regex &&
	test_must_be_empty actual-regex &&
	test_must_be_empty err-regex &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -i -G"ABS.NT" HEAD^..HEAD \
		-- pickaxe-history 2>err-icase-g &&
	test_grep "unable to read" err-icase-g &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -i --pickaxe-regex -S"ABS.NT" \
		HEAD^..HEAD -- pickaxe-history 2>err-icase-regex &&
	test_grep "unable to read" err-icase-regex &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"a.*b" HEAD^..HEAD \
		-- pickaxe-history 2>err-unsupported &&
	test_grep "unable to read" err-unsupported &&
	mv .git/objects/info/grep-index/chain-transposed \
		.git/objects/info/grep-index/chain-transposed.save &&
	test_when_finished "test ! -e \
		.git/objects/info/grep-index/chain-transposed.save ||
		mv .git/objects/info/grep-index/chain-transposed.save \
			.git/objects/info/grep-index/chain-transposed" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual-legacy 2>err-legacy &&
	test_must_be_empty actual-legacy &&
	test_must_be_empty err-legacy &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"abs.nt" HEAD^..HEAD \
		-- pickaxe-history >actual-legacy-g 2>err-legacy-g &&
	test_must_be_empty actual-legacy-g &&
	test_must_be_empty err-legacy-g &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --pickaxe-regex -S"abs.nt" \
		HEAD^..HEAD -- pickaxe-history >actual-legacy-regex \
		2>err-legacy-regex &&
	test_must_be_empty actual-legacy-regex &&
	test_must_be_empty err-legacy-regex &&
	mv .git/objects/info/grep-index/chain-transposed.save \
		.git/objects/info/grep-index/chain-transposed &&
	if test_have_prereq LIBPCRE2
	then
		GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
			git log --format=%s -i -SABSENT HEAD^..HEAD \
			-- pickaxe-history >actual-icase 2>err-icase &&
		test_must_be_empty actual-icase &&
		test_must_be_empty err-icase
	fi &&

	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history 2>err-no-index &&
	test_grep "unable to read" err-no-index
'

test_expect_success 'content index preserves regex pickaxe results' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"needle|replacement" \
		HEAD^..HEAD -- pickaxe-history >actual-g &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s -G"needle|replacement" \
		HEAD^..HEAD -- pickaxe-history >expect-g &&
	test_cmp expect-g actual-g &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --pickaxe-regex \
		-S"pickaxe|replacement" HEAD^..HEAD \
		-- pickaxe-history >actual-regex &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s --pickaxe-regex \
		-S"pickaxe|replacement" HEAD^..HEAD \
		-- pickaxe-history >expect-regex &&
	test_cmp expect-regex actual-regex &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --name-only --pickaxe-all \
		-G"needle" HEAD^..HEAD >actual-all &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s --name-only --pickaxe-all \
		-G"needle" HEAD^..HEAD >expect-all &&
	test_cmp expect-all actual-all
'

test_expect_success 'content index preserves add and delete results' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"needle" HEAD~2..HEAD \
		-- pickaxe-old pickaxe-deleted >actual-g &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s -G"needle" HEAD~2..HEAD \
		-- pickaxe-old pickaxe-deleted >expect-g &&
	test_cmp expect-g actual-g &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --pickaxe-regex -S"needle" \
		HEAD~2..HEAD -- pickaxe-old pickaxe-deleted >actual-regex &&
	GIT_TEST_PICKAXE_CONTENT_INDEX=0 \
		git log --format=%s --pickaxe-regex -S"needle" \
		HEAD~2..HEAD -- pickaxe-old pickaxe-deleted >expect-regex &&
	test_cmp expect-regex actual-regex
'

test_expect_success 'content index prunes pickaxe binary reads' '
	old_oid=$(git rev-parse HEAD^:pickaxe-binary) &&
	new_oid=$(git rev-parse HEAD:pickaxe-binary) &&
	old_object=.git/objects/$(test_oid_to_path "$old_oid") &&
	new_object=.git/objects/$(test_oid_to_path "$new_oid") &&
	mv "$old_object" "$old_object.save" &&
	mv "$new_object" "$new_object.save" &&
	test_when_finished "mv \"$old_object.save\" \"$old_object\" &&
			    mv \"$new_object.save\" \"$new_object\"" &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s \
		-G"__git_absent_binary_[p]attern__" HEAD^..HEAD \
		-- pickaxe-binary >actual 2>err &&
	test_must_be_empty actual &&
	test_must_be_empty err
'

test_expect_success 'content index preserves pickaxe binary behavior' '
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"binary" HEAD^..HEAD \
		-- pickaxe-binary >actual &&
	test_must_be_empty actual &&

	echo "pickaxe new" >expect &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --text --format=%s -G"binary" HEAD^..HEAD \
		-- pickaxe-binary >actual-text &&
	test_cmp expect actual-text &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --pickaxe-regex -S"old" \
		HEAD^..HEAD -- pickaxe-binary >actual-regex &&
	test_cmp expect actual-regex
'

test_expect_success 'pickaxe index threshold spans commits' '
	test_when_finished "rm -f pickaxe-threshold.trace \
			    pickaxe-regex-threshold.trace" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=2 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-threshold.trace" \
		git log --format=%s -Sabsent HEAD~2..HEAD \
		-- pickaxe-history >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"content_index/query\",\"value\":\"1\"" \
		pickaxe-threshold.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-threshold.trace &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=2 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-regex-threshold.trace" \
		git log --format=%s -G"abs.nt" HEAD~2..HEAD \
		-- pickaxe-history >actual-regex &&
	test_must_be_empty actual-regex &&
	test_grep "\"key\":\"content_index/query\",\"value\":\"1\"" \
		pickaxe-regex-threshold.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-regex-threshold.trace
'

test_expect_success FSMONITOR_DAEMON \
	'pickaxe selects content index backend' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git config --unset core.fsmonitor" &&
	git config core.fsmonitor true &&
	GIT_TEST_GREP_INDEX_IPC_PREPARED_MIN_OIDS=1 \
		GIT_TRACE2_EVENT="$PWD/daemon-prepared.trace" \
		git fsmonitor--daemon start &&
	test_when_finished "rm -f pickaxe-direct.trace pickaxe-ipc.trace \
			    pickaxe-g-direct.trace pickaxe-g-ipc.trace \
			    pickaxe-saturated.trace \
			    pickaxe-fallback.trace pickaxe-missing.trace \
			    daemon-prepared.trace" &&
	old_oid=$(git rev-parse HEAD^:pickaxe-history) &&
	new_oid=$(git rev-parse HEAD:pickaxe-history) &&
	old_object=.git/objects/$(test_oid_to_path "$old_oid") &&
	new_object=.git/objects/$(test_oid_to_path "$new_oid") &&
	mv "$old_object" "$old_object.save" &&
	mv "$new_object" "$new_object.save" &&
	test_when_finished "mv \"$old_object.save\" \"$old_object\" &&
			    mv \"$new_object.save\" \"$new_object\"" &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-g-direct.trace" \
		git log --format=%s -G"abs.nt" HEAD^..HEAD \
		-- pickaxe-history >actual-g-direct 2>err-g-direct &&
	test_must_be_empty actual-g-direct &&
	test_must_be_empty err-g-direct &&
	test_grep "\"key\":\"content_index/index\",\"value\":\"1\"" \
		pickaxe-g-direct.trace &&
	test_grep "\"key\":\"content_index/prepared\",\"value\":\"1\"" \
		pickaxe-g-direct.trace &&
	test_grep "\"key\":\"content_index/tested\",\"value\":\"2\"" \
		pickaxe-g-direct.trace &&
	test_grep "\"key\":\"content_index/ipc\",\"value\":\"0\"" \
		pickaxe-g-direct.trace &&
	test_grep "\"key\":\"content_index/persistent_only\",\"value\":\"1\"" \
		pickaxe-g-direct.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-g-direct.trace &&
	! test_grep "\"key\":\"ipc_query/" daemon-prepared.trace &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-direct.trace" \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual 2>err &&
	test_must_be_empty actual &&
	test_must_be_empty err &&
	test_grep "\"key\":\"content_index/prepared\",\"value\":\"0\"" \
		pickaxe-direct.trace &&
	test_grep "\"key\":\"content_index/ipc\",\"value\":\"1\"" \
		pickaxe-direct.trace &&
	test_grep "\"key\":\"content_index/direct_batches\",\"value\":\"1\"" \
		pickaxe-direct.trace &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"0\"" \
		pickaxe-direct.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-direct.trace &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sneedle HEAD^..HEAD \
		-- pickaxe-history 2>err-direct-positive &&
	test_grep "unable to read" err-direct-positive &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TEST_PICKAXE_CONTENT_INDEX_DIRECT_MAX_OIDS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-ipc.trace" \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual-ipc 2>err-ipc &&
	test_must_be_empty actual-ipc &&
	test_must_be_empty err-ipc &&
	test_grep "\"key\":\"content_index/ipc\",\"value\":\"1\"" \
		pickaxe-ipc.trace &&
	test_grep "\"key\":\"content_index/direct_batches\",\"value\":\"0\"" \
		pickaxe-ipc.trace &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"1\"" \
		pickaxe-ipc.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-ipc.trace &&
	test_grep "\"key\":\"ipc_query/prepared\",\"value\":\"1\"" \
		daemon-prepared.trace &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TEST_PICKAXE_CONTENT_INDEX_DIRECT_MAX_OIDS=0 \
		GIT_TEST_PICKAXE_CONTENT_INDEX_MAX_ENTRIES=1 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-saturated.trace" \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual-saturated 2>err-saturated &&
	test_must_be_empty actual-saturated &&
	test_must_be_empty err-saturated &&
	test_grep \
		"\"key\":\"content_index/batch_result_entries\",\"value\":\"1\"" \
		pickaxe-saturated.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-saturated.trace &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TEST_PICKAXE_CONTENT_INDEX_DIRECT_MAX_OIDS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-g-ipc.trace" \
		git log --text --format=%s -G"abs.nt" HEAD^..HEAD \
		-- pickaxe-history >actual-g-ipc 2>err-g-ipc &&
	test_must_be_empty actual-g-ipc &&
	test_must_be_empty err-g-ipc &&
	test_grep "\"key\":\"content_index/ipc\",\"value\":\"1\"" \
		pickaxe-g-ipc.trace &&
	test_grep "\"key\":\"content_index/persistent_only\",\"value\":\"0\"" \
		pickaxe-g-ipc.trace &&
	test_grep "\"key\":\"content_index/direct_batches\",\"value\":\"0\"" \
		pickaxe-g-ipc.trace &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"1\"" \
		pickaxe-g-ipc.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-g-ipc.trace &&

	daemon_old_oid=$(git rev-parse HEAD^:pickaxe-daemon-history) &&
	daemon_old_object=.git/objects/$(test_oid_to_path \
		"$daemon_old_oid") &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TEST_PICKAXE_CONTENT_INDEX_DIRECT_MAX_OIDS=0 \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-daemon-history >actual-prewarm &&
	test_must_be_empty actual-prewarm &&
	mv "$daemon_old_object" "$daemon_old_object.save" &&
	test_when_finished "mv \"$daemon_old_object.save\" \
			    \"$daemon_old_object\"" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-missing.trace" \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-daemon-history >actual-missing 2>err-missing &&
	test_must_be_empty actual-missing &&
	test_must_be_empty err-missing &&
	test_grep "\"key\":\"content_index/direct_batches\",\"value\":\"0\"" \
		pickaxe-missing.trace &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"1\"" \
		pickaxe-missing.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-missing.trace &&

	mv .git/objects/info/grep-index/chain-transposed \
		.git/objects/info/grep-index/chain-transposed.save &&
	test_when_finished "test ! -e \
		.git/objects/info/grep-index/chain-transposed.save ||
		mv .git/objects/info/grep-index/chain-transposed.save \
			.git/objects/info/grep-index/chain-transposed" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-fallback.trace" \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual-fallback 2>err-fallback &&
	test_must_be_empty actual-fallback &&
	test_must_be_empty err-fallback &&
	test_grep "\"key\":\"content_index/prepared\",\"value\":\"0\"" \
		pickaxe-fallback.trace &&
	test_grep "\"key\":\"content_index/ipc\",\"value\":\"1\"" \
		pickaxe-fallback.trace &&
	test_grep "\"key\":\"content_index/direct_batches\",\"value\":\"0\"" \
		pickaxe-fallback.trace &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"1\"" \
		pickaxe-fallback.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-fallback.trace &&
	mv .git/objects/info/grep-index/chain-transposed.save \
		.git/objects/info/grep-index/chain-transposed
'

test_expect_success FSMONITOR_DAEMON \
	'pickaxe caches exact counts for uncovered history' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git update-ref -d refs/heads/pickaxe-uncovered &&
			    rm -f pickaxe-uncovered-*.trace" &&
	git branch pickaxe-uncovered HEAD &&
	test_commit_bulk --ref=refs/heads/pickaxe-uncovered \
		--filename=pickaxe-uncovered --contents="needle %s" \
		--notick 8 &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-uncovered-absent.trace" \
		git log --no-renames --format=%s -Sabsent \
		pickaxe-uncovered~7..pickaxe-uncovered \
		-- pickaxe-uncovered >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"7\"" \
		pickaxe-uncovered-absent.trace &&
	test_grep \
		"\"key\":\"content_index/count_cache_hits\",\"value\":\"0\"" \
		pickaxe-uncovered-absent.trace &&
	test_grep \
		"\"key\":\"content_index/count_cache_updates\",\"value\":\"0\"" \
		pickaxe-uncovered-absent.trace &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-uncovered-positive.trace" \
		git log --no-renames --format=%s -Sneedle \
		pickaxe-uncovered~7..pickaxe-uncovered \
		-- pickaxe-uncovered >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"7\"" \
		pickaxe-uncovered-positive.trace &&
	test_grep \
		"\"key\":\"content_index/count_cache_hits\",\"value\":\"6\"" \
		pickaxe-uncovered-positive.trace &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-uncovered-regex.trace" \
		git log --no-renames --format=%s --pickaxe-regex \
		-S"needle.[0-9]" pickaxe-uncovered~7..pickaxe-uncovered \
		-- pickaxe-uncovered >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"7\"" \
		pickaxe-uncovered-regex.trace &&
	test_grep \
		"\"key\":\"content_index/count_cache_hits\",\"value\":\"6\"" \
		pickaxe-uncovered-regex.trace &&

	test_commit_bulk --ref=refs/heads/pickaxe-uncovered --start=9 \
		--filename=pickaxe-uncovered --contents="needle needle %s" \
		--notick 1 &&
	echo "commit 9" >expect &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-uncovered-change.trace" \
		git log --no-renames --format=%s -Sneedle \
		pickaxe-uncovered~8..pickaxe-uncovered \
		-- pickaxe-uncovered >actual &&
	test_cmp expect actual &&
	test_grep "\"key\":\"content_index/ipc_batches\",\"value\":\"8\"" \
		pickaxe-uncovered-change.trace &&
	test_grep \
		"\"key\":\"content_index/count_cache_hits\",\"value\":\"7\"" \
		pickaxe-uncovered-change.trace
'

test_expect_success 'possible pickaxe blobs use normal reads' '
	old_oid=$(git rev-parse HEAD^:pickaxe-history) &&
	new_oid=$(git rev-parse HEAD:pickaxe-history) &&
	old_object=.git/objects/$(test_oid_to_path "$old_oid") &&
	new_object=.git/objects/$(test_oid_to_path "$new_oid") &&
	mv "$new_object" "$new_object.save" &&
	test_when_finished "test ! -e \"$new_object.save\" ||
			    mv \"$new_object.save\" \"$new_object\"" &&

	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sneedle HEAD^..HEAD \
		-- pickaxe-history 2>err &&
	test_grep "unable to read" err &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"replac.ment" HEAD^..HEAD \
		-- pickaxe-history 2>err-g &&
	test_grep "unable to read" err-g &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s --pickaxe-regex -S"replac.ment" \
		HEAD^..HEAD -- pickaxe-history 2>err-regex &&
	test_grep "unable to read" err-regex &&

	mv "$new_object.save" "$new_object" &&
	mv "$old_object" "$old_object.save" &&
	test_when_finished "mv \"$old_object.save\" \"$old_object\"" &&
	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sreplacement HEAD^..HEAD \
		-- pickaxe-history 2>err-impossible &&
	test_grep "unable to read" err-impossible
'

test_expect_success 'pickaxe content index preserves textconv' '
	write_script pickaxe-textconv <<-\EOF &&
	if grep -q "needle old" "$1"
	then
		echo "converted pickaxe marker"
	fi
	EOF
	echo "pickaxe-history diff=pickaxe" >.gitattributes &&
	git add .gitattributes &&
	test_when_finished "git reset -- .gitattributes &&
			    rm -f .gitattributes pickaxe-textconv" &&
	test_config diff.pickaxe.textconv ./pickaxe-textconv &&

	echo "pickaxe new" >expect &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --textconv --format=%s \
		-S"converted pickaxe marker" HEAD^..HEAD \
		-- pickaxe-history >actual &&
	test_cmp expect actual &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --textconv --format=%s \
		-G"converted pickaxe marker" HEAD^..HEAD \
		-- pickaxe-history >actual-g &&
	test_cmp expect actual-g &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --textconv --format=%s --pickaxe-regex \
		-S"converted.*marker" HEAD^..HEAD \
		-- pickaxe-history >actual-regex &&
	test_cmp expect actual-regex
'

test_expect_success 'pickaxe content index honors replacements' '
	old_oid=$(git rev-parse HEAD^:pickaxe-history) &&
	replacement=$(echo "replacement-only-marker" |
		git hash-object -w --stdin) &&
	git replace "$old_oid" "$replacement" &&
	test_when_finished "git replace -d \"$old_oid\"" &&

	echo "pickaxe new" >expect &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sreplacement-only-marker \
		HEAD^..HEAD -- pickaxe-history >actual &&
	test_cmp expect actual &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -G"replacement-only-marker" \
		HEAD^..HEAD -- pickaxe-history >actual-g &&
	test_cmp expect actual-g
'

test_expect_success 'content index does not skip regex validation' '
	test_must_fail git -c grep.threads=8 grep --cached \
		"absent[9-0]" 2>err &&
	test_grep -i "invalid.*range" err
'

test_expect_success FSMONITOR_DAEMON 'daemon reuses persistent content index' '
	test_when_finished "git fsmonitor--daemon stop &&
			    git config --unset core.fsmonitor" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&

	mv .git/objects/info/grep-index/chain \
		.git/objects/info/grep-index/chain.save &&
	test_when_finished "mv .git/objects/info/grep-index/chain.save \
				.git/objects/info/grep-index/chain" &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent pattern" 2>err &&
	test_must_be_empty err
'

test_expect_success FSMONITOR_DAEMON 'daemon learns negative index results' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git reset --hard HEAD &&
			    rm -f negative-learn.trace negative-hit.trace \
				  negative-alt-*.trace" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	oid=$(git rev-parse :ordinary) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail git grep --cached foo -- ordinary 2>err-before &&
	test_grep "unable to read" err-before &&
	mv "$object.save" "$object" &&

	test_must_fail env GIT_TRACE2_EVENT="$PWD/negative-learn.trace" \
		git grep --cached foo -- ordinary &&
	test_trace2_data grep content_index_negative_cache_entries 1 \
		<negative-learn.trace &&
	mv "$object" "$object.save" &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/negative-hit.trace" \
		git grep --cached --text foo -- ordinary 2>err-after &&
	test_must_be_empty err-after &&
	test_trace2_data grep content_index_negative_cache_hits 1 \
		<negative-hit.trace &&
	mv "$object.save" "$object" &&
	echo "present:present needle" >expect-alt &&
	env GIT_TRACE2_EVENT="$PWD/negative-alt-learn.trace" \
		git grep --cached -E "conts|needle" -- ordinary present \
		>actual-alt &&
	test_cmp expect-alt actual-alt &&
	test_trace2_data grep content_index_negative_cache_entries 1 \
		<negative-alt-learn.trace &&
	mv "$object" "$object.save" &&
	env GIT_TRACE2_EVENT="$PWD/negative-alt-hit.trace" \
		git grep --cached -E "conts|needle" -- ordinary present \
		>actual-alt 2>err-alt &&
	test_must_be_empty err-alt &&
	test_cmp expect-alt actual-alt &&
	test_trace2_data grep content_index_negative_cache_hits 1 \
		<negative-alt-hit.trace &&
	mv "$object.save" "$object" &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/negative-alt-fixed.trace" \
		git grep --cached -F "conts|needle" -- ordinary &&
	test_trace2_data grep content_index_negative_cache_hits 0 \
		<negative-alt-fixed.trace &&

	printf "foo\0" >negative-binary &&
	git add negative-binary &&
	binary_oid=$(git rev-parse :negative-binary) &&
	binary_object=.git/objects/$(test_oid_to_path "$binary_oid") &&
	test_must_fail git grep --cached -I foo -- negative-binary &&
	mv "$binary_object" "$binary_object.save" &&
	test_when_finished "test ! -e \"$binary_object.save\" ||
			    mv \"$binary_object.save\" \"$binary_object\"" &&
	test_must_fail git grep --cached foo -- negative-binary \
		2>err-binary &&
	test_grep "unable to read" err-binary &&
	mv "$binary_object.save" "$binary_object" &&

	echo "foo contents" >ordinary &&
	git add ordinary &&
	echo "ordinary:foo contents" >expect &&
	git grep --cached foo -- ordinary >actual &&
	test_cmp expect actual
'

test_expect_success FSMONITOR_DAEMON \
	'daemon learns multi-pattern fixed negatives' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    rm -f negative-fixed-list-*.trace" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	test_must_fail env \
		GIT_TRACE2_EVENT="$PWD/negative-fixed-list-learn.trace" \
		git grep --cached -F -e foo -e "absent|two" \
		-- ordinary &&
	test_trace2_data grep content_index_negative_cache_entries 1 \
		<negative-fixed-list-learn.trace &&

	oid=$(git rev-parse :ordinary) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail env \
		GIT_TRACE2_EVENT="$PWD/negative-fixed-list-hit.trace" \
		git grep --cached -F -e foo -e "absent|two" \
		-- ordinary 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_negative_cache_hits 1 \
		<negative-fixed-list-hit.trace
'

test_expect_success FSMONITOR_DAEMON \
	'daemon learns ERE negatives from required literals' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git reset --hard HEAD &&
			    rm -f negative-required-ere-*.trace" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	pattern="(^|[^A-Z])abcdefgh\\(" &&
	echo "positive-required-ere:abcdefgh(" >expect &&
	env GIT_TRACE2_EVENT="$PWD/negative-required-ere-learn.trace" \
		git grep --cached -E "$pattern" -- \
		negative-required-ere positive-required-ere >actual &&
	test_cmp expect actual &&
	test_trace2_data grep content_index_negative_cache_entries 1 \
		<negative-required-ere-learn.trace &&

	oid=$(git rev-parse :negative-required-ere) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail env \
		GIT_TRACE2_EVENT="$PWD/negative-required-ere-hit.trace" \
		git grep --cached -E "$pattern" -- negative-required-ere \
		2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_negative_cache_hits 1 \
		<negative-required-ere-hit.trace &&
	mv "$object.save" "$object" &&

	test_must_fail git grep --cached -E "$pattern" -- \
		negative-context-ere &&
	oid=$(git rev-parse :negative-context-ere) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail git grep --cached -E "$pattern" -- \
		negative-context-ere 2>err &&
	test_grep "unable to read" err
'

test_expect_success FSMONITOR_DAEMON,REGEX_MATCH_ERROR \
	'daemon does not cache regex errors' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git reset --hard HEAD &&
			    rm -f negative-locale-*.trace" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	printf "\\377foo\\n" >negative-locale &&
	git add negative-locale &&
	oid=$(git rev-parse :negative-locale) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail env LC_ALL=en_US.UTF-8 \
		GIT_TRACE2_EVENT="$PWD/negative-locale-learn.trace" \
		git grep --cached -E "foo|bar" -- negative-locale &&
	mv "$object" "$object.save" &&
	test_must_fail env LC_ALL=en_US.UTF-8 \
		GIT_TRACE2_EVENT="$PWD/negative-locale-miss.trace" \
		git grep --cached -E "foo|bar" -- negative-locale \
		2>err-locale &&
	test_grep "unable to read" err-locale &&
	test_trace2_data grep content_index_negative_cache_hits 0 \
		<negative-locale-miss.trace
'

test_expect_success FSMONITOR_DAEMON,SJIS_REGEX_NOMATCH \
	'daemon verifies ERE negatives against blob bytes' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git reset --hard HEAD &&
			    rm -f negative-bytes-ere*.trace" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	printf "\\202foo\\n" >negative-bytes &&
	git add negative-bytes &&
	oid=$(git rev-parse :negative-bytes) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail env LC_ALL=ja_JP.SJIS \
		GIT_TRACE2_EVENT="$PWD/negative-bytes-ere.trace" \
		git grep --cached -E "foo|absent" -- negative-bytes &&
	mv "$object" "$object.save" &&
	test_must_fail env LC_ALL=ja_JP.SJIS \
		GIT_TRACE2_EVENT="$PWD/negative-bytes-ere-miss.trace" \
		git grep --cached -E "foo|absent" -- negative-bytes \
		2>err-ere-bytes &&
	test_grep "unable to read" err-ere-bytes &&
	test_trace2_data grep content_index_negative_cache_hits 0 \
		<negative-bytes-ere-miss.trace
'

test_expect_success FSMONITOR_DAEMON,SJIS_REGEX_NOMATCH,!LIBPCRE2 \
	'daemon verifies fixed negatives against blob bytes' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git reset --hard HEAD &&
			    rm -f negative-bytes-fixed*.trace" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	printf "\\202foo\\n" >negative-bytes &&
	git add negative-bytes &&
	oid=$(git rev-parse :negative-bytes) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&
	test_must_fail env LC_ALL=ja_JP.SJIS \
		GIT_TRACE2_EVENT="$PWD/negative-bytes-fixed.trace" \
		git grep --cached -F foo -- negative-bytes &&
	mv "$object" "$object.save" &&
	test_must_fail env LC_ALL=ja_JP.SJIS \
		GIT_TRACE2_EVENT="$PWD/negative-bytes-fixed-miss.trace" \
		git grep --cached -F foo -- negative-bytes 2>err-fixed-bytes &&
	test_grep "unable to read" err-fixed-bytes &&
	test_trace2_data grep content_index_negative_cache_hits 0 \
		<negative-bytes-fixed-miss.trace
'

test_expect_success FSMONITOR_DAEMON 'daemon overlays stale persistent index' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    test_might_fail git config --unset core.fsmonitor &&
			    git reset --hard HEAD &&
			    rm -f overlay-*.trace .git/index.grep-worktree \
				.git/index.grep-worktree-generation \
				.git/index.grep-worktree-recovery" &&
	test_path_is_file .git/objects/info/grep-index/chain-transposed &&
	printf "overlay unrelated contents\n" >overlay-absent &&
	printf "overlay present needle 7818\n" >overlay-present &&
	printf "overlay missing contents\n" >overlay-missing &&
	printf "overlay worktree contents\n" >overlay-worktree &&
	printf "overlay worktree missing needle 7818\n" \
		>overlay-worktree-missing &&
	git add overlay-absent overlay-present overlay-missing overlay-worktree \
		overlay-worktree-missing &&
	test_config grep.worktreeBlobCache true &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	git status --porcelain >/dev/null &&

	test_expect_code 1 env GIT_TRACE2_EVENT="$PWD/overlay-absent.trace" \
		git grep --cached "overlay absent needle 7818" \
		-- overlay-absent &&
	test_trace2_data grep content_index_overlay_objects 1 \
		<overlay-absent.trace &&
	test_trace2_data grep content_index_overlay_rejected 1 \
		<overlay-absent.trace &&
	test_trace2_data grep content_index_negative_cache_entries 1 \
		<overlay-absent.trace &&
	absent_oid=$(git rev-parse :overlay-absent) &&
	absent_object=.git/objects/$(test_oid_to_path "$absent_oid") &&
	mv "$absent_object" "$absent_object.save" &&
	test_when_finished "test ! -e \"$absent_object.save\" ||
			    mv \"$absent_object.save\" \"$absent_object\"" &&
	test_expect_code 1 env GIT_TRACE2_EVENT="$PWD/overlay-hit.trace" \
		git grep --cached "overlay absent needle 7818" \
		-- overlay-absent 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_negative_cache_hits 1 \
		<overlay-hit.trace &&
	! test_grep content_index_overlay_objects overlay-hit.trace &&
	mv "$absent_object.save" "$absent_object" &&

	echo "overlay-present:overlay present needle 7818" >expect &&
	GIT_TRACE2_EVENT="$PWD/overlay-present.trace" \
		git grep --cached "overlay present needle 7818" \
		-- overlay-present >actual &&
	test_cmp expect actual &&
	test_trace2_data grep content_index_overlay_objects 1 \
		<overlay-present.trace &&
	test_trace2_data grep content_index_overlay_rejected 0 \
		<overlay-present.trace &&

	missing_oid=$(git rev-parse :overlay-missing) &&
	missing_object=.git/objects/$(test_oid_to_path "$missing_oid") &&
	mv "$missing_object" "$missing_object.save" &&
	test_when_finished "test ! -e \"$missing_object.save\" ||
			    mv \"$missing_object.save\" \"$missing_object\"" &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/overlay-missing.trace" \
		git grep --cached "overlay absent missing needle 7818" \
		-- overlay-missing 2>err-missing &&
	test_grep "unable to read" err-missing &&
	mv "$missing_object.save" "$missing_object" &&

	test_expect_code 1 env GIT_TEST_GREP_LITERAL_PATHS=0 \
		git grep --no-content-index \
		"overlay worktree warmup needle 7818" -- overlay-worktree &&
	test_expect_code 1 env GIT_TEST_GREP_LITERAL_PATHS=0 \
		GIT_TRACE2_EVENT="$PWD/overlay-worktree.trace" \
		git grep "overlay absent worktree needle 7818" \
		-- overlay-worktree &&
	test_trace2_data grep content_index_overlay_objects 1 \
		<overlay-worktree.trace &&
	test_trace2_data grep content_index_overlay_rejected 1 \
		<overlay-worktree.trace &&
	test_trace2_data grep content_index_negative_cache_entries 1 \
		<overlay-worktree.trace &&

	test_expect_code 1 env GIT_TEST_GREP_LITERAL_PATHS=0 \
		git grep --no-content-index \
		"overlay present warmup absent 7818" -- overlay-present &&
	set -- overlay-worktree overlay-present literal-candidate-* &&
	echo "overlay-present:overlay present needle 7818" >expect &&
	env \
		GIT_TRACE2_EVENT="$PWD/overlay-literal.trace" \
		git grep "overlay present needle 7818" -- "$@" >actual &&
	test_cmp expect actual &&
	test_trace2_data grep literal_path_candidates 42 \
		<overlay-literal.trace &&
	test_trace2_data grep content_index_overlay_objects 2 \
		<overlay-literal.trace &&
	test_trace2_data grep content_index_overlay_rejected 1 \
		<overlay-literal.trace &&
	test_trace2_data grep content_index_literal_path_candidates 41 \
		<overlay-literal.trace &&
	test_trace2_data grep content_index_literal_path_rejected 1 \
		<overlay-literal.trace &&

	echo "overlay absent worktree needle 7818" >overlay-worktree &&
	git status --porcelain >/dev/null &&
	echo "overlay-worktree:overlay absent worktree needle 7818" >expect &&
	env GIT_TEST_GREP_LITERAL_PATHS=0 \
		GIT_TRACE2_EVENT="$PWD/overlay-worktree-changed.trace" \
		git grep "overlay absent worktree needle 7818" \
		-- overlay-worktree >actual &&
	test_cmp expect actual &&
	test_trace2_data grep content_index_negative_cache_hits 1 \
		<overlay-worktree-changed.trace &&
	git checkout -- overlay-worktree &&
	git status --porcelain >/dev/null &&

	test_expect_code 1 env GIT_TEST_GREP_LITERAL_PATHS=0 \
		git grep --no-content-index \
		"overlay worktree missing warmup 7818" \
		-- overlay-worktree-missing &&
	worktree_missing_oid=$(git rev-parse :overlay-worktree-missing) &&
	worktree_missing_object=.git/objects/$(test_oid_to_path \
		"$worktree_missing_oid") &&
	mv "$worktree_missing_object" "$worktree_missing_object.save" &&
	test_when_finished "test ! -e \"$worktree_missing_object.save\" ||
			    mv \"$worktree_missing_object.save\" \
				\"$worktree_missing_object\"" &&
	echo "overlay-worktree-missing:overlay worktree missing needle 7818" \
		>expect &&
	env GIT_TEST_GREP_LITERAL_PATHS=0 \
		GIT_TRACE2_EVENT="$PWD/overlay-worktree-missing.trace" \
		git grep "overlay worktree missing needle 7818" \
		-- overlay-worktree-missing >actual &&
	test_cmp expect actual &&
	test_trace2_data grep content_index_overlay_objects 1 \
		<overlay-worktree-missing.trace &&
	test_trace2_data grep content_index_overlay_rejected 0 \
		<overlay-worktree-missing.trace &&
	mv "$worktree_missing_object.save" "$worktree_missing_object"
'

test_expect_success 'content index prunes impossible blobs' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent pattern" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached "absent(pattern)" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -F "absent pattern" 2>err &&
	test_must_be_empty err &&
	if test_have_prereq LIBPCRE2
	then
		mv .git/objects/info/grep-index/chain-transposed \
			.git/objects/info/grep-index/chain-transposed.save &&
		test_when_finished "test ! -e \
			.git/objects/info/grep-index/chain-transposed.save ||
			mv .git/objects/info/grep-index/chain-transposed.save \
				.git/objects/info/grep-index/chain-transposed" &&
		test_must_fail git grep --cached -i "ABSENT PATTERN" \
			-- short 2>err &&
		test_must_be_empty err &&
		mv .git/objects/info/grep-index/chain-transposed.save \
			.git/objects/info/grep-index/chain-transposed
	fi &&
	test_must_fail git grep --cached --no-content-index \
		"absent pattern" 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git -c grep.useContentIndex=false grep --cached \
		"absent pattern" 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 \
	'content index prunes case-insensitive ASCII queries' '
	echo "present:present needle" >expect &&
	git grep --cached -i "PRESENT NEEDLE" -- present >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -i "ABSENT PATTERN" -- short 2>err &&
	test_must_fail git grep --cached -i -E \
		"ABSENT PATTERN" -- short 2>err-ere &&
	test_must_be_empty err-ere &&
	test_must_be_empty err
'

test_expect_success LIBPCRE2 \
	'content index keeps exact and folded filters' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "PRESENT NEEDLE" \
		-- present 2>err-exact &&
	test_must_be_empty err-exact &&
	test_must_fail git grep --cached -i "PRESENT NEEDLE" \
		-- present 2>err-folded &&
	test_grep "unable to read" err-folded
'

test_expect_success PCRE2_UTF8_LOCALE \
	'case-insensitive index preserves Unicode aliases' '
	LC_ALL=en_US.UTF-8 git grep --cached --quiet -i \
		"non-ascii k contents" -- non-ascii &&
	LC_ALL=en_US.UTF-8 git grep --cached --quiet -i \
		"long s value" -- long-s &&

	oid=$(git rev-parse :non-ascii) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&
	LC_ALL=en_US.UTF-8 test_must_fail git grep --cached -i \
		"non-ascii k contents" -- non-ascii 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 \
	'content index prunes case-insensitive PCRE queries' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -i -P \
		"ABSENT PATTERN" -- short 2>err &&
	test_must_be_empty err
'

test_expect_success LIBPCRE2 \
	'case-insensitive index prunes non-ASCII blobs' '
	oid=$(git rev-parse :non-ascii) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -i "absent pattern" \
		-- non-ascii 2>err &&
	test_must_be_empty err
'

test_expect_success 'case-insensitive index rejects non-ASCII patterns' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&
	pattern=$(printf "\342\204\252") &&

	test_must_fail git grep --cached -i "$pattern" -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'content index prunes cached worktree blobs' '
	GIT_TEST_GREP_LITERAL_PATHS=0 &&
	GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 &&
	export GIT_TEST_GREP_LITERAL_PATHS &&
	export GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES &&
	test_when_finished "unset GIT_TEST_GREP_LITERAL_PATHS \
		GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES" &&
	test_when_finished "rm -f .git/fsmonitor-ordinary \
			    .git/index.grep-worktree \
			    .git/index.grep-worktree-generation \
			    .git/index.grep-worktree-recovery \
			    .git/index.grep-worktree.save \
			    recovery-lookup.trace &&
			    git rm -f --ignore-unmatch ordinary-shift &&
			    git update-index --no-fsmonitor &&
			    git checkout -- ordinary" &&
	test_hook --setup --clobber fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-ordinary
		then
			printf "ordinary\0"
		fi
	EOF
	test_config core.fsmonitor .git/hooks/fsmonitor-test &&
	test_config grep.worktreeBlobCache true &&
	git update-index --fsmonitor &&
	git status --porcelain >/dev/null &&
	test_must_fail git grep "absent cached worktree" -- ordinary &&
	test_path_is_file .git/index.grep-worktree &&
	test_must_fail git grep "absent cached worktree" -- ordinary &&
	echo "ordinary shift" >ordinary-shift &&
	test-tool chmtime =-5 ordinary-shift &&
	git add ordinary-shift &&
	git status --porcelain >/dev/null &&
	cp .git/index.grep-worktree .git/index.grep-worktree.save &&
	echo "ordinary:ordinary contents" >expected &&
	env GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=2 \
		GIT_TRACE2_EVENT="$PWD/recovery-lookup.trace" \
		git grep "ordinary contents" -- ordinary >actual &&
	test_cmp expected actual &&
	test_trace2_data grep worktree_blob/recovered_identity 1 \
		<recovery-lookup.trace &&
	test_cmp .git/index.grep-worktree.save \
		.git/index.grep-worktree &&
	echo "worktree-only-needle" >ordinary &&
	>.git/fsmonitor-ordinary &&
	oid=$(git rev-parse :ordinary) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&

	echo "ordinary:worktree-only-needle" >expected &&
	git grep "worktree-only-needle" -- ordinary >actual 2>err &&
	test_cmp expected actual &&
	test_must_be_empty err
'

test_expect_success FSMONITOR_DAEMON \
	'content index selects worktree candidates first' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git checkout -- ordinary &&
			    rm -f .git/index.grep-worktree \
				.git/index.grep-worktree-generation \
				.git/index.grep-worktree-recovery \
				candidate-*.trace" &&
	test_config grep.worktreeBlobCache true &&
	test_config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	git status --porcelain >/dev/null &&

	echo "uncached worktree candidate needle" >ordinary &&
	git status --porcelain >/dev/null &&
	echo "ordinary:uncached worktree candidate needle" >expected &&
	GIT_TRACE2_EVENT="$PWD/candidate-unknown.trace" \
		git grep "uncached worktree candidate needle" \
		-- "ord*" >actual &&
	test_cmp expected actual &&
	test_trace2_data grep content_index_worktree_candidates 1 \
		<candidate-unknown.trace &&
	git checkout -- ordinary &&
	git status --porcelain >/dev/null &&

	echo "ordinary:ordinary contents" >expected &&
	GIT_TRACE2_EVENT="$PWD/candidate-clean.trace" \
		git grep "ordinary contents" -- "ord*" >actual &&
	test_cmp expected actual &&
	test_trace2_data grep content_index_worktree_candidates 1 \
		<candidate-clean.trace &&

	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/candidate-negative.trace" git grep \
		"absent candidate-only needle" -- "ord*" 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_worktree_candidates 0 \
		<candidate-negative.trace &&

	git update-index --no-fsmonitor-valid ordinary &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/candidate-unrefreshed.trace" git grep \
		"absent candidate-only needle" -- "ord*" 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_worktree_candidates 1 \
		<candidate-unrefreshed.trace &&
	test_grep ! '"category":"index","label":"refresh"' \
		candidate-unrefreshed.trace &&

	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1 \
		GIT_TRACE2_EVENT="$PWD/candidate-refreshed.trace" git grep \
		"absent candidate-only needle" -- "ord*" 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_worktree_candidates 0 \
		<candidate-refreshed.trace &&

	echo "unrefreshed worktree candidate needle" >ordinary &&
	echo "ordinary:unrefreshed worktree candidate needle" >expected &&
	GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1 \
		GIT_TRACE2_EVENT="$PWD/candidate-unrefreshed-dirty.trace" \
		git grep "unrefreshed worktree candidate needle" \
		-- "ord*" >actual &&
	test_cmp expected actual &&
	test_trace2_data grep content_index_worktree_candidates 1 \
		<candidate-unrefreshed-dirty.trace &&
	test_trace2_data grep worktree_blob/hits 0 \
		<candidate-unrefreshed-dirty.trace &&

	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1 \
		GIT_TRACE2_EVENT="$PWD/candidate-literal.trace" git grep \
		"absent literal needle" -- ordinary 2>err &&
	test_must_be_empty err &&
	test_grep ! '"category":"index","label":"refresh"' \
		candidate-literal.trace &&

	echo "worktree candidate-only needle" >ordinary &&
	git status --porcelain >/dev/null &&
	echo "ordinary:worktree candidate-only needle" >expected &&
	GIT_TRACE2_EVENT="$PWD/candidate-dirty.trace" \
		git grep "worktree candidate-only needle" -- "ord*" >actual &&
	test_cmp expected actual &&
	test_trace2_data grep content_index_worktree_candidates 1 \
		<candidate-dirty.trace &&

	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/candidate-excluded.trace" git grep \
		"worktree candidate-only needle" \
		-- "ord*" ":(exclude)ordinary" 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep content_index_worktree_candidates 0 \
		<candidate-excluded.trace
'

test_expect_success FSMONITOR_DAEMON \
	'content index prunes literal path candidates' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git checkout -- literal-candidate-a-01 &&
			    rm -f .git/index.grep-worktree \
				.git/index.grep-worktree-generation \
				.git/index.grep-worktree-recovery \
				candidate-literal-*.trace \
				literal-candidate-paths" &&
	test_config grep.worktreeBlobCache true &&
	test_config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	git status --porcelain >/dev/null &&

	git ls-files "literal-candidate-*" >literal-candidate-paths &&
	set -- &&
	while read path
	do
		set -- "$path" "$@" || return 1
	done <literal-candidate-paths &&
	set -- "$@" literal-candidate-a-01 &&
	test_path_is_missing .git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/candidate-literal-unknown.trace" \
		git --no-optional-locks grep \
			"absent literal candidate needle" -- "$@" 2>err &&
	test_must_be_empty err &&
	test_trace2_data grep literal_path_candidates 40 \
		<candidate-literal-unknown.trace &&
	! test_grep "content_index_literal_path_" \
		candidate-literal-unknown.trace &&
	test_expect_code 1 git grep --no-content-index \
		"absent literal candidate warmup" -- \
		"literal-candidate-*" \
		":(exclude)literal-candidate-a-02" &&
	test_path_is_file .git/index.grep-worktree &&

	echo "literal mixed candidate needle" >literal-candidate-a-01 &&
	git status --porcelain >/dev/null &&
	cat >expected <<-\EOF &&
	literal-candidate-a-01:literal mixed candidate needle
	literal-candidate-z-40:literal mixed candidate needle
	EOF
	GIT_TRACE2_EVENT="$PWD/candidate-literal-mixed.trace" \
		git grep "literal mixed candidate needle" \
			-- "$@" >actual &&
	test_cmp expected actual &&
	test_trace2_data grep literal_path_candidates 40 \
		<candidate-literal-mixed.trace &&
	test_trace2_data grep content_index_literal_path_candidates 3 \
		<candidate-literal-mixed.trace &&
	test_trace2_data grep content_index_literal_path_rejected 37 \
		<candidate-literal-mixed.trace
'

test_expect_success 'content index prunes impossible multiple patterns' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		-e "absent alpha" -e "absent beta" 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index intersects --all-match patterns' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached --all-match \
		-e "present needle" -e "absent alpha" -- present 2>err &&
	test_must_be_empty err
'

test_expect_success ENHANCED_BRE \
	'content index prunes impossible basic alternation' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"absent alpha\|absent beta" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"absent alpha|absent beta" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached \
		"absent alpha.*absent omega\|absent beta" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached \
		"from [A-Za-z]* absent\|import [0-9]* missing" \
		-- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached "absent.alpha" 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index prunes basic bracket expressions' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"present[[:space:]]*absent" -- present 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached \
		"present[ A-Za-z0-9_.]*absent" -- present 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index prunes agent basic bracket expression' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"import [A-Za-z0-9_.]*absent" -- agent-regex 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index bridges escaped dot literal' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"import [A-Za-z0-9_.]*\\.__[A-Za-z0-9_]*" \
		-- agent-regex 2>err &&
	test_must_be_empty err
'

test_expect_success ENHANCED_BRE \
	'content index bridges escaped dot alternation' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"from [A-Za-z0-9_.]* import __[A-Za-z0-9_]*\|import [A-Za-z0-9_.]*\\.__[A-Za-z0-9_]*" \
		-- agent-regex 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index bridges escaped ERE dot literal' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^present\\.needle$" -- present 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index bridges escaped ERE punctuation' '
	oid=$(git rev-parse :escaped-call-negative) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"resolve_reference\\(" -- escaped-call-negative 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index uses an escaped literal bridge alone' '
	oid=$(git rev-parse :escaped-bridge-negative) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"\\.ab" -- escaped-bridge-negative 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index prunes anchored escaped regexes' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^absent alpha\\.suffix$|^absent beta\\.suffix$" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^absent alpha\\.(internal|private|_[A-Za-z])|^absent beta\\.(internal|private|_[A-Za-z])" \
		2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"__absent_path__[[:space:]]*=|absent_extend_path|absent_declare_namespace" \
		2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^from (absent|missing)(\\.|[[:space:]])|^import (absent|missing)\\." \
		2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^from (absent_alpha|absent_beta)(\\.|[[:space:]])|^import (absent_alpha|absent_beta)\\." \
		2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^(absent_alpha|absent_beta)+$" 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached \
		"^absent alpha\\.suffix$" 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index combines required ERE groups' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^(present|ordinary) (absent_alpha|absent_beta) (contents|needle)$" \
		2>err &&
	test_must_be_empty err
'

test_expect_success 'content index combines ERE literals and groups' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&
	pattern="from (present|ordinary)(\\.[A-Za-z0-9_]*_private|\\._|\\.internal|\\.private)|import (present|ordinary)(\\.[A-Za-z0-9_]*_private|\\._|\\.internal|\\.private)" &&

	test_must_fail git grep --cached -E "$pattern" -- present 2>err &&
	test_must_be_empty err &&
	git grep --cached -E "$pattern" -- structured-from >actual &&
	cat >expect <<-\EOF &&
	structured-from:from present.private
	EOF
	test_cmp expect actual &&
	git grep --cached -E "$pattern" -- structured-import >actual &&
	cat >expect <<-\EOF &&
	structured-import:import ordinary.internal
	EOF
	test_cmp expect actual
'

test_expect_success 'content index prunes ERE group concatenations' '
	oid=$(git rev-parse :ere-concat) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"global_(test|dev)_requirements" \
		-- ere-concat 2>err &&
	test_must_be_empty err &&

	cat >expect <<-\EOF &&
	ere-concat-dev:global_dev_requirements
	ere-concat-test:global_test_requirements
	EOF
	git grep --cached -E "global_(test|dev)_requirements" \
		-- ere-concat-test ere-concat-dev >actual &&
	test_cmp expect actual
'

test_expect_success FSMONITOR_DAEMON \
	'daemon preserves mixed ERE queries' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git config --unset core.fsmonitor" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	test_when_finished "rm -f ere-boundary-ipc.trace" &&
	oid=$(git rev-parse :ere-concat) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail env \
		GIT_TRACE2_EVENT="$PWD/ere-boundary-ipc.trace" \
		git grep --cached -E \
		"global_(test|dev)_requirements|standalone_absent" \
		-- ere-concat 2>err &&
	test_must_be_empty err &&
	test_grep \
		"\"key\":\"content_index_ipc_candidates\",\"value\":\"0\"" \
		ere-boundary-ipc.trace
'

test_expect_success 'content index combines mixed ERE branches' '
	oid=$(git rev-parse :ere-concat) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"global_(test|dev)_requirements|standalone_absent" \
		-- ere-concat 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"standalone_absent|global_(test|dev)_requirements" \
		-- ere-concat 2>err &&
	test_must_be_empty err &&

	cat >expect <<-\EOF &&
	ere-concat-dev:global_dev_requirements
	ere-concat-test:global_test_requirements
	ere-mixed-plain:standalone_present
	EOF
	git grep --cached -E \
		"standalone_present|global_(test|dev)_requirements" \
		-- ere-concat-test ere-concat-dev ere-mixed-plain >actual &&
	test_cmp expect actual
'

test_expect_success 'mixed ERE branches preserve the alternative limit' '
	pattern= &&
	for i in $(test_seq 0 61)
	do
		term=$(printf "absent%02d" "$i") &&
		pattern="${pattern}${pattern:+|}${term}" || return 1
	done &&
	pattern="${pattern}|(foo|bar)" &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E "$pattern" -- short 2>err &&
	test_must_be_empty err
'

test_expect_success 'ERE boundaries use decoded alternatives' '
	cat >expect <<-\EOF &&
	ere-concat-bar:prebarsuf
	ere-concat-foo:prefoo.suf
	EOF
	git grep --cached -E "pre(foo\\.|b[a]r)suf" \
		-- ere-concat-foo ere-concat-bar >actual &&
	test_cmp expect actual
'

test_expect_success 'repeated ERE groups do not correlate alternatives' '
	echo "ere-concat-repeat:xfoobary" >expect &&

	git grep --cached -E "x(foo|bar)+y" \
		-- ere-concat-repeat >actual &&
	test_cmp expect actual
'

test_expect_success 'ERE boundaries preserve the query limit' '
	prefix=$(printf "%04096d" 0 | tr 0 a) &&
	pattern="${prefix}(foo|bar)z" &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E "$pattern" -- short 2>err &&
	test_must_be_empty err
'

test_expect_success 'escaped literal boundaries preserve the query limit' '
	prefix=$(printf "%04096d" 0 | tr 0 a) &&
	pattern="${prefix}\\(abc" &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E "$pattern" -- short 2>err &&
	test_must_be_empty err
'

test_expect_success 'required bridges replace optional enrichments' '
	pattern=baseline &&
	for i in $(test_seq 1 1400)
	do
		pattern="${pattern}\\(ab" || return 1
	done &&
	oid=$(git rev-parse :escaped-bridge-negative) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		-e "$pattern" -e "\\.ab" -- escaped-bridge-negative 2>err &&
	test_must_be_empty err &&

	oid=$(git rev-parse :escaped-bridge-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&
	test_must_fail git grep --cached -E \
		-e "$pattern" -e "\\.ab" -- escaped-bridge-positive 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'content index combines middle ERE literals and groups' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&
	pattern="(from|import) libdemo_cpp([._]| import).*(_|internal|private)|(from|import) libdemo_cpp_ext([._]| import).*(_|internal|private)" &&

	test_must_fail git grep --cached -E "$pattern" -- agent-regex 2>err &&
	test_must_be_empty err &&
	git grep --cached -E "$pattern" -- structured-middle-from >actual &&
	cat >expect <<-\EOF &&
	structured-middle-from:from libdemo_cpp.internal
	EOF
	test_cmp expect actual &&
	git grep --cached -E "$pattern" -- structured-middle-import >actual &&
	cat >expect <<-\EOF &&
	structured-middle-import:import libdemo_cpp_ext.private
	EOF
	test_cmp expect actual
'

test_expect_success 'optional ERE branch literal uses normal blob reads' '
	git grep --cached -E "fro?m (present|ordinary)" \
	-- structured-optional >actual &&
	cat >expect <<-\EOF &&
	structured-optional:frm present
	EOF
	test_cmp expect actual &&
	git grep --cached -E \
		"(foo|bar){0,2}(present|ordinary)" -- present >actual &&
	cat >expect <<-\EOF &&
	present:present needle
	EOF
	test_cmp expect actual
'

test_expect_success 'content index prefers stronger ERE literals' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"(from|import)[[:space:]]+unicorn_sfi\\.eval\\.chz" \
		-- agent-regex 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"(^|[[:space:]])(from|import)[[:space:]]+gunicorn\\.conf" \
		-- agent-regex 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index skips escaped regex atoms' '
	oid=$(git rev-parse :ordinary) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	if test_have_prereq BRE_WORD_BOUNDARY
	then
		test_must_fail git grep --cached \
			"\\bclass Image\\b" -- ordinary 2>err &&
		test_must_be_empty err
	fi &&
	test_must_fail git grep --cached -E \
		"class Image\\b" -- ordinary 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^class\\s* Image$" -- ordinary 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index decodes escaped ERE groups' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^(present|ordinary) (absent\\.alpha|absent\\.beta) (contents|needle)$" \
		2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^(present|ordinary) (absent\\|alpha|missing\\(beta\\)|never\\[gamma]|none\\\\delta) (contents|needle)$" \
		2>err &&
	test_must_be_empty err
'

test_expect_success 'content index decodes singleton ERE classes' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"(^| )(impor[t]|fro[m]) (applie[d]|qsta[r])(\.| import).*(_privat[e]|interna[l]|privat[e])" \
		-- agent-regex 2>err &&
	test_must_be_empty err
'

test_expect_success 'content index unwraps whole ERE group' '
	oid=$(git rev-parse :ordinary) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^(from _[A-Za-z0-9][A-Za-z0-9_]*|import _[A-Za-z0-9][A-Za-z0-9_]*)$" \
		-- ordinary 2>err &&
	test_must_be_empty err
'

test_expect_success 'unsupported searches use normal blob reads' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -i -E \
		"ABSENT[ ]PATTERN" -- short 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E "^|absent needle" -- short 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E "^(a\\.|b\\*)$" -- short 2>err &&
	test_grep "unable to read" err &&
	git grep --cached -L "absent pattern" >/dev/null 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached x -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'content index prunes impossible PCRE literal' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P "absent pattern" 2>err &&
	test_must_fail git grep --cached -P "^absent\\.pattern$" 2>err &&
	test_must_fail git grep --cached -P "absent \\w+" 2>err &&
	test_must_be_empty err
'

test_expect_success LIBPCRE2 'content index prunes simple PCRE groups' '
	echo "present:present needle" >expect &&
	git grep --cached -P \
		"present\\s*(?:optional\\.)?needle" -- present >actual &&
	test_cmp expect actual &&
	echo "agent-regex:import sample_ext.vendor_internal" >expect &&
	git grep --cached -P \
		"import\\s+(?:sample_ext\\.)?vendor_internal" \
		-- agent-regex >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"absent\\s*=\\s*(?:optional\\.)?needle" -- short 2>err &&
	test_must_be_empty err
'

test_expect_success LIBPCRE2 'content index prunes PCRE boundaries' '
	echo "agent-regex:import sample_ext.vendor_internal" >expect &&
	pattern="(^|[^[:alnum:]_])import[[:space:]]+" &&
	pattern="$pattern(sample_ext\\.)?vendor_internal" &&
	pattern="$pattern($|[^[:alnum:]_])" &&
	git grep --cached -P "$pattern" -- agent-regex >actual &&
	test_cmp expect actual &&
	git grep --cached -P \
		"\\bimport[[:space:]]+(sample_ext\\.)?vendor_internal\\b" \
		-- agent-regex >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"\\babsent[[:space:]]+(optional)?needle\\b" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -P \
		"(^|[^[:alnum:]_])absent(optional)?needle" -- short 2>err &&
	test_must_be_empty err
'

test_expect_success LIBPCRE2 'content index prunes PCRE wildcard ranges' '
	echo "agent-regex:import sample_ext.vendor_internal" >expect &&
	git grep --cached -P \
		"import.{0,20}vendor_internal" -- agent-regex >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"absent.{0,240}needle" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -P \
		"absent.{0,240}?needle" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -P \
		"absent.{,3}needle" -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'content index prunes PCRE negative lookaheads' '
	echo "agent-regex:import sample_ext.vendor_internal" >expect &&
	git grep --cached -P \
		"^(?!\\s*(#|from ))[^\\n]*vendor_internal" \
		-- agent-regex >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"^(?!\\s*(#|from |import ))[^\\n]*absent" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -P \
		"^(?!(?:prefix))absent" -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'content index prunes PCRE negative lookbehinds' '
	echo "agent-regex:import sample_ext.vendor_internal" >expect &&
	git grep --cached -P \
		"(?<![A-Z_])vendor_internal" -- agent-regex >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"(?<![A-Z_])absent" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -P \
		"(?<!(prefix))absent" -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'content index bridges escaped PCRE punctuation' '
	oid=$(git rev-parse :escaped-call-negative) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"resolve_reference\\(" -- escaped-call-negative 2>err &&
	test_must_be_empty err &&

	oid=$(git rev-parse :escaped-call-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&
	test_must_fail git grep --cached -P \
		"resolve_reference\\(" -- escaped-call-positive 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'quantified escaped PCRE punctuation reads blob' '
	oid=$(git rev-parse :escaped-call-optional) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"foo\\(?bar" -- escaped-call-optional 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -P \
		"foo\\({0}bar" -- escaped-call-optional 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'content index prunes escaped ERE classes' '
	echo "agent-regex:import sample_ext.vendor_internal" >expect &&
	git grep --cached -E \
		"import[^\\n]*vendor_internal" -- agent-regex >actual &&
	test_cmp expect actual &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"absent[^\\n]*needle" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"absent[^\\]]*needle" -- short 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"absent[\\[:alpha:]]needle" -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'complex PCRE groups use normal blob reads' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"absent(?:nested(group))needle" -- short 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -P \
		"absent(?:\\Q(group)\\E)needle" -- short 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -P \
		"absent[\\Q]\\E]needle" -- short 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -P \
		"(*ACCEPT)absent" -- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'content index prunes PCRE alternatives' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -i -P \
		"ABSENT ALPHA|MISSING BETA" -- short 2>err &&
	test_must_be_empty err &&

	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -i -P \
		"ABSENT ALPHA|PRESENT NEEDLE" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -P \
		"present\\|absent suffix" -- present 2>err &&
	test_must_be_empty err
'

test_expect_success 'possible matches use normal blob reads' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "present needle" 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible basic bracket expression uses normal blob reads' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"present[[:space:]]*needle" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached \
		"present[ A-Za-z0-9_.]*needle" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached \
		"present[0-9]* needle" -- present 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible agent basic bracket expression reads blob' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"import [A-Za-z0-9_.]*vendor_internal" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible escaped dot literal reads blob' '
	oid=$(git rev-parse :escaped-dot) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"import [A-Za-z0-9_.]*\\.__[A-Za-z0-9_]*" \
		-- escaped-dot 2>err &&
	test_grep "unable to read" err
'

test_expect_success ENHANCED_BRE \
	'possible escaped dot alternation reads blob' '
	oid=$(git rev-parse :escaped-dot) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"from [A-Za-z0-9_.]* import __[A-Za-z0-9_]*\|import [A-Za-z0-9_.]*\\.__[A-Za-z0-9_]*" \
		-- escaped-dot 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'quantified escaped dot suffix reads blob' '
	oid=$(git rev-parse :escaped-dot-quantified) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "\\.ab*" \
		-- escaped-dot-quantified 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 'fixed pattern follows PCRE2 matching semantics' '
	oid=$(git rev-parse :fixed-pcre) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -F "a\\E.*b" -- fixed-pcre 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible anchored escaped regex uses normal blob reads' '
	oid=$(git rev-parse :escaped-dot-ere) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^present\\.needle$" -- escaped-dot-ere 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible escaped ERE punctuation reads blob' '
	oid=$(git rev-parse :escaped-call-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"resolve_reference\\(" -- escaped-call-positive 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible escaped literal bridge alone reads blob' '
	oid=$(git rev-parse :escaped-bridge-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"\\.ab" -- escaped-bridge-positive 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'content index prunes escaped BRE closing bracket' '
	oid=$(git rev-parse :escaped-literal-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"absent_left\\[absent_right\\]" \
		-- escaped-literal-positive 2>err &&
	test_must_be_empty err
'

test_expect_success 'escaped ERE literals preserve positive results' '
	cat >patterns <<-\EOF &&
	star_left\*star_right
	question_left\?question_right
	bracket_left\[bracket_right
	slash_left\\slash_right
	dollar_left\$dollar_right
	open_left\(open_right
	close_left\)close_right
	plus_left\+plus_right
	dot_left\.dot_right
	caret_left\^caret_right
	brace_left\{brace_right
	pipe_left\|pipe_right
	EOF
	oid=$(git rev-parse :escaped-literal-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	while IFS= read -r pattern
	do
		test_must_fail git grep --cached -E "$pattern" \
			-- escaped-literal-positive 2>err &&
		test_grep "unable to read" err || return 1
	done <patterns
'

test_expect_success 'escaped BRE literals preserve positive results' '
	cat >patterns <<-\EOF &&
	dot_left\.dot_right
	bracket_left\[bracket_right
	bracket_pair_left\[bracket_pair_right\]
	slash_left\\slash_right
	star_left\*star_right
	caret_left\^caret_right
	dollar_left\$dollar_right
	EOF
	oid=$(git rev-parse :escaped-literal-positive) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	while IFS= read -r pattern
	do
		test_must_fail git grep --cached "$pattern" \
			-- escaped-literal-positive 2>err &&
		test_grep "unable to read" err || return 1
	done <patterns
'

test_expect_success 'escaped literal alternatives preserve their clauses' '
	oid_left=$(git rev-parse :escaped-call-positive) &&
	object_left=.git/objects/$(test_oid_to_path "$oid_left") &&
	mv "$object_left" "$object_left.save" &&
	test_when_finished "mv \"$object_left.save\" \"$object_left\"" &&
	oid_right=$(git rev-parse :escaped-call-alternative) &&
	object_right=.git/objects/$(test_oid_to_path "$oid_right") &&
	mv "$object_right" "$object_right.save" &&
	test_when_finished "mv \"$object_right.save\" \"$object_right\"" &&

	test_must_fail git grep --cached -E \
		"resolve_reference\\(|other_call\\[" \
		-- escaped-call-positive 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"resolve_reference\\(|other_call\\[" \
		-- escaped-call-alternative 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'quantified escaped ERE punctuation reads blob' '
	oid=$(git rev-parse :escaped-call-optional) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"foo\\(?bar" -- escaped-call-optional 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'exact-zero escaped ERE punctuation reads blob' '
	oid=$(git rev-parse :escaped-call-optional) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"foo\\({0}bar" -- escaped-call-optional 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'exact-zero escaped BRE punctuation reads blob' '
	oid=$(git rev-parse :escaped-call-optional) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"foo\\.\\{0\\}bar" -- escaped-call-optional 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'quantified ERE punctuation neighbor reads blob' '
	oid=$(git rev-parse :escaped-call-right-quantified) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"foo\\(b*ar" -- escaped-call-right-quantified 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'escaped BRE operators remain variable' '
	oid=$(git rev-parse :escaped-call-optional) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"foo\\(bar\\)" -- escaped-call-optional 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible escaped ERE group uses normal blob reads' '
	oid=$(git rev-parse :escaped-ere) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^(literal\\|\\(\\)\\[]\\\\suffix|absent)$" \
		-- escaped-ere 2>err &&
	test_grep "unable to read" err
'

test_expect_success LIBPCRE2 \
	'possible anchored escaped PCRE uses normal blob reads' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -P \
		"^import sample_ext\\.vendor_internal$" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'nested ERE group uses normal blob reads' '
	oid=$(git rev-parse :ordinary) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^absent((nested)|[)]|\\))*suffix$|^ordinary contents$" \
		-- ordinary 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^ordinary[[:space:]]+contents$" \
		-- ordinary 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible agent regex uses normal blob reads' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^from sample_ext\\.(internal|private|_[A-Za-z])|^import sample_ext\\.(vendor_internal|[[:space:]]|_[A-Za-z])|from sample_ext import (internal|private|_[A-Za-z])" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^from (absent_alpha|absent_beta)\\.|^import (sample_ext|absent_beta)\\." \
		-- agent-regex 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^(absent_alpha|import sample_ext.vendor_internal)+$" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^(absent|import) (sample_ext|missing)\\.(vendor_internal|private)$" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^(absent|import) (sample_ext\\.vendor_internal|missing\\.private)$" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'stronger ERE literals preserve possible matches' '
	unicorn_oid=$(git rev-parse :mixed-unicorn) &&
	unicorn_object=.git/objects/$(test_oid_to_path "$unicorn_oid") &&
	gunicorn_oid=$(git rev-parse :mixed-gunicorn) &&
	gunicorn_object=.git/objects/$(test_oid_to_path "$gunicorn_oid") &&
	mv "$unicorn_object" "$unicorn_object.save" &&
	mv "$gunicorn_object" "$gunicorn_object.save" &&
	test_when_finished "mv \"$unicorn_object.save\" \"$unicorn_object\"" &&
	test_when_finished "mv \"$gunicorn_object.save\" \"$gunicorn_object\"" &&

	test_must_fail git grep --cached -E \
		"(from|import)[[:space:]]+unicorn_sfi\\.eval\\.chz" \
		-- mixed-unicorn 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"(^|[[:space:]])(from|import)[[:space:]]+gunicorn\\.conf" \
		-- mixed-gunicorn 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'escaped regex atoms preserve possible matches' '
	oid=$(git rev-parse :escaped-ere-atom) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	if test_have_prereq BRE_WORD_BOUNDARY
	then
		test_must_fail git grep --cached \
			"\\bclass Image\\b" -- escaped-ere-atom 2>err &&
		test_grep "unable to read" err
	fi &&
	test_must_fail git grep --cached -E \
		"class Image\\b" -- escaped-ere-atom 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^class\\s* Image$" -- escaped-ere-atom 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible singleton ERE classes use normal blob reads' '
	oid=$(git rev-parse :agent-regex) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"(^| )(impor[t]|fro[m]) (sample_ex[t]|missing)(\.| import).*(vendor_interna[l]|private)" \
		-- agent-regex 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'quantified singleton ERE classes read blobs' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"(present[x]*|absent)" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"(present[x]?|absent)" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"(present[x]{0}|absent)" -- present 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'quantified ordinary atoms retain later literals' '
	git grep --cached -E \
		"^[_A-Z][A-Z0-9_]* *= *require_monorepo\\(\\)$" \
		-- quantified-ordinary-assignment &&
	git grep --cached "^prefixx*suffix$" \
		-- quantified-ordinary-zero &&
	git grep --cached -E "^prefixx+suffix$" \
		-- quantified-ordinary-one &&
	git grep --cached -E "^prefixx?suffix$" \
		-- quantified-ordinary-zero &&
	if test_have_prereq LIBPCRE2
	then
		git grep --cached -P "^prefixx*?suffix$" \
			-- quantified-ordinary-zero &&
		git grep --cached -P "^prefixx*+suffix$" \
			-- quantified-ordinary-zero
	fi &&

	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "x*absent suffix" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"x?absent suffix" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"x+absent suffix" -- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"^[_A-Z][A-Z0-9_]* *= *absent_monorepo\\(\\)$" \
		-- short 2>err &&
	test_must_be_empty err &&
	test_must_fail git grep --cached -E \
		"x*|absent suffix" -- short 2>err &&
	test_grep "unable to read" err &&
	if test_have_prereq LIBPCRE2
	then
		test_must_fail git grep --cached -P \
			"x*?absent suffix" -- short 2>err &&
		test_must_be_empty err &&
		test_must_fail git grep --cached -P \
			"x*+absent suffix" -- short 2>err &&
		test_must_be_empty err
	fi &&
	if test_have_prereq PCRE2_UTF8_LOCALE
	then
		multibyte=$(printf "\\342\\204\\252") &&
		test_must_fail env LC_ALL=en_US.UTF-8 git grep --cached -P \
			"ab${multibyte}*absent suffix" -- short 2>err &&
		test_grep "unable to read" err
	fi
'

test_expect_success 'whole ERE group matches use normal blob reads' '
	from_oid=$(git rev-parse :outer-from) &&
	from_object=.git/objects/$(test_oid_to_path "$from_oid") &&
	import_oid=$(git rev-parse :outer-import) &&
	import_object=.git/objects/$(test_oid_to_path "$import_oid") &&
	boundary_oid=$(git rev-parse :outer-boundary) &&
	boundary_object=.git/objects/$(test_oid_to_path "$boundary_oid") &&
	mv "$from_object" "$from_object.save" &&
	mv "$import_object" "$import_object.save" &&
	mv "$boundary_object" "$boundary_object.save" &&
	test_when_finished "mv \"$from_object.save\" \"$from_object\"" &&
	test_when_finished "mv \"$import_object.save\" \"$import_object\"" &&
	test_when_finished "mv \"$boundary_object.save\" \"$boundary_object\"" &&

	test_must_fail git grep --cached -E \
		"^(from _[A-Za-z0-9][A-Za-z0-9_]*|import _[A-Za-z0-9][A-Za-z0-9_]*)$" \
		-- outer-from 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^(from _[A-Za-z0-9][A-Za-z0-9_]*|import _[A-Za-z0-9][A-Za-z0-9_]*)$" \
		-- outer-import 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"^(from _[A-Za-z][)]|import _[A-Za-z]\\))$" \
		-- outer-boundary 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'quantified whole ERE group reads blob' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached -E \
		"^(from _[A-Za-z0-9][A-Za-z0-9_]*|import _[A-Za-z0-9][A-Za-z0-9_]*)*" \
		-- short 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'possible multiple pattern uses normal blob reads' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		-e "absent alpha" -e "present needle" 2>err &&
	test_grep "unable to read" err
'

test_expect_success ENHANCED_BRE \
	'possible basic alternation uses normal blob reads' '
	oid=$(git rev-parse :present) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		"absent alpha\|present needle" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached -E \
		"absent alpha|present needle" -- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached \
		"absent alpha.*absent omega\|present.*needle" \
		-- present 2>err &&
	test_grep "unable to read" err &&
	test_must_fail git grep --cached "present.needle" -- present 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'unknown blobs use normal blob reads' '
	printf y >unknown &&
	git add unknown &&
	oid=$(git rev-parse :unknown) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent pattern" 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'structurally invalid segment is ignored' '
	segment=$(cat .git/objects/info/grep-index/chain) &&
	index=.git/objects/info/grep-index/grep-$segment.idx &&
	transposed=$(awk -v segment="$segment" \
		"\$1 == segment { print \$2 }" \
		.git/objects/info/grep-index/chain-transposed) &&
	transposed_index=.git/objects/info/grep-index/grep-$transposed.idx &&
	cp "$index" "$index.save" &&
	cp "$transposed_index" "$transposed_index.save" &&
	test_when_finished "mv \"$index.save\" \"$index\" &&
			    mv \"$transposed_index.save\" \"$transposed_index\"" &&
	chmod +w "$index" &&
	chmod +w "$transposed_index" &&
	: >"$index" &&
	: >"$transposed_index" &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent pattern" 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'segment with truncated trailer is ignored' '
	segment=$(cat .git/objects/info/grep-index/chain) &&
	index=.git/objects/info/grep-index/grep-$segment.idx &&
	transposed=$(awk -v segment="$segment" \
		"\$1 == segment { print \$2 }" \
		.git/objects/info/grep-index/chain-transposed) &&
	transposed_index=.git/objects/info/grep-index/grep-$transposed.idx &&
	cp "$index" "$index.save" &&
	cp "$transposed_index" "$transposed_index.save" &&
	test_when_finished "mv \"$index.save\" \"$index\" &&
			    mv \"$transposed_index.save\" \"$transposed_index\"" &&
	chmod +w "$index" &&
	chmod +w "$transposed_index" &&
	size=$(wc -c <"$index") &&
	test_copy_bytes $((size - 1)) <"$index" >"$index.truncated" &&
	mv "$index.truncated" "$index" &&
	size=$(wc -c <"$transposed_index") &&
	test_copy_bytes $((size - 1)) <"$transposed_index" \
		>"$transposed_index.truncated" &&
	mv "$transposed_index.truncated" "$transposed_index" &&
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent pattern" 2>err &&
	test_grep "unable to read" err
'

test_expect_success 'writer retries unreadable blobs' '
	echo "retry alpha 0123456789" >retry-alpha &&
	echo "retry beta abcdefghij" >retry-beta &&
	echo "retry gamma klmnopqrst" >retry-gamma &&
	git add retry-alpha retry-beta retry-gamma &&
	git ls-files -s retry-alpha retry-beta retry-gamma |
		sort -k2,2 >retry-entries &&
	middle_oid=$(awk "NR == 2 { print \$2 }" retry-entries) &&
	middle_path=$(awk "NR == 2 { print \$4 }" retry-entries) &&
	middle_object=.git/objects/$(test_oid_to_path "$middle_oid") &&
	mv "$middle_object" "$middle_object.save" &&
	test_when_finished "test ! -e \"$middle_object.save\" ||
			    mv \"$middle_object.save\" \"$middle_object\"" &&

	git grep-index --no-progress &&
	test_line_count = 2 .git/objects/info/grep-index/chain &&
	while read mode oid stage path
	do
		test "$oid" = "$middle_oid" && continue
		object=.git/objects/$(test_oid_to_path "$oid") &&
		mv "$object" "$object.save" &&
		pattern=$(cat "$path") &&
		test_must_fail git grep --cached -F "$pattern" -- "$path" \
			2>err &&
		test_grep "$oid" err &&
		mv "$object.save" "$object" ||
		return 1
	done <retry-entries &&
	test_must_fail git grep --cached -F "absent retry needle" \
		-- "$middle_path" 2>err &&
	test_grep "$middle_oid" err &&

	mv "$middle_object.save" "$middle_object" &&
	git grep-index --no-progress &&
	test_line_count = 3 .git/objects/info/grep-index/chain &&
	mv "$middle_object" "$middle_object.save" &&
	test_must_fail git grep --cached -F "absent retry needle" \
		-- "$middle_path" 2>err &&
	test_must_be_empty err &&
	mv "$middle_object.save" "$middle_object"
'

test_expect_success 'write incremental segment' '
	cp .git/objects/info/grep-index/chain-transposed \
		chain-transposed.before &&
	printf z >incremental &&
	printf "incremental \342\204\252\n" >incremental-non-ascii &&
	git add incremental incremental-non-ascii &&
	git grep-index --no-progress &&
	test_line_count = 4 .git/objects/info/grep-index/chain &&
	test_line_count = 4 .git/objects/info/grep-index/chain-transposed &&
	head -n 3 .git/objects/info/grep-index/chain-transposed \
		>chain-transposed.old &&
	test_cmp chain-transposed.before chain-transposed.old &&
	oid=$(git rev-parse :incremental) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
			    mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached "absent pattern" 2>err &&
	test_must_be_empty err &&
	mv "$object.save" "$object" &&

	if test_have_prereq LIBPCRE2
	then
		non_ascii_oid=$(git rev-parse :incremental-non-ascii) &&
		non_ascii_object=.git/objects/$(test_oid_to_path \
			"$non_ascii_oid") &&
		mv "$non_ascii_object" "$non_ascii_object.save" &&
		test_when_finished "mv \"$non_ascii_object.save\" \
					\"$non_ascii_object\"" &&
		test_must_fail git grep --cached -i "absent pattern" \
			-- incremental-non-ascii 2>err-non-ascii &&
		test_must_be_empty err-non-ascii
	fi
'

test_expect_success 'writer includes linked worktree indexes' '
	git worktree add ../grep-index-worktree -b grep-index-worktree &&
	test_when_finished "git worktree remove --force ../grep-index-worktree &&
			    git branch -D grep-index-worktree" &&
	printf q >../grep-index-worktree/linked-short &&
	git -C ../grep-index-worktree add linked-short &&
	git grep-index --no-progress &&
	oid=$(git -C ../grep-index-worktree rev-parse :linked-short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git -C ../grep-index-worktree grep --cached \
		"absent pattern" 2>err &&
	test_must_be_empty err
'

test_expect_success 'writer includes reachable historical blobs' '
	test_create_repo reachable-index &&
	(
		cd reachable-index &&
		echo "historical contents" >historical &&
		echo "other historical contents" >other &&
		git add historical other &&
		git commit -m historical &&
		historical_oid=$(git rev-parse :historical) &&
		other_oid=$(git rev-parse :other) &&
		git rm historical other &&
		git commit -m deleted &&

		git grep-index --reachable --no-progress HEAD -- historical &&
		historical_object=.git/objects/$(test_oid_to_path \
			"$historical_oid") &&
		other_object=.git/objects/$(test_oid_to_path "$other_oid") &&
		mv "$historical_object" "$historical_object.save" &&
		mv "$other_object" "$other_object.save" &&
		GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
			git log --format=%s -Sabsent HEAD^..HEAD -- historical \
			>actual 2>err &&
		test_must_be_empty actual &&
		test_must_be_empty err &&
		test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
			git log --format=%s -Sabsent HEAD^..HEAD -- other \
			2>err &&
		test_grep "$other_oid" err
	)
'

test_done

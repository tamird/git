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
	echo "import sample_ext.__private" >escaped-dot &&
	echo "present.needle" >escaped-dot-ere &&
	echo ".a" >escaped-dot-quantified &&
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
	printf "%s\n" "literal|()[]\\suffix" >escaped-ere &&
	git add short fixed-pcre present agent-regex ordinary escaped-dot \
		escaped-dot-ere escaped-dot-quantified non-ascii outer-from \
		long-s outer-import outer-boundary mixed-unicorn mixed-gunicorn \
		escaped-ere-atom structured-from structured-import \
		structured-middle-from structured-middle-import \
		structured-optional ere-concat ere-concat-test ere-concat-dev \
		ere-mixed-plain ere-concat-foo ere-concat-bar \
		ere-concat-repeat escaped-ere &&
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

test_expect_success 'setup indexed pickaxe history' '
	echo "pickaxe needle old" >pickaxe-old &&
	echo "pickaxe daemon old" >pickaxe-daemon-history &&
	echo "pickaxe replacement" >pickaxe-new &&
	cp pickaxe-old pickaxe-history &&
	git add pickaxe-old pickaxe-new pickaxe-history \
		pickaxe-daemon-history &&
	git commit -m "pickaxe old" &&
	cp pickaxe-new pickaxe-history &&
	cp pickaxe-new pickaxe-daemon-history &&
	git add pickaxe-history pickaxe-daemon-history &&
	git commit -m "pickaxe new"
'

test_expect_success 'write shared content index' '
	git grep-index --no-progress &&
	test_path_is_file .git/objects/info/grep-index/chain &&
	test_line_count = 1 .git/objects/info/grep-index/chain &&
	segment=$(cat .git/objects/info/grep-index/chain) &&
	test_path_is_file .git/objects/info/grep-index/grep-$segment.idx
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

test_expect_success 'pickaxe index threshold spans commits' '
	test_when_finished "rm -f pickaxe-threshold.trace" &&
	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=2 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-threshold.trace" \
		git log --format=%s -Sabsent HEAD~2..HEAD \
		-- pickaxe-history >actual &&
	test_must_be_empty actual &&
	test_grep "\"key\":\"content_index/query\",\"value\":\"1\"" \
		pickaxe-threshold.trace &&
	test_grep \
		"\"key\":\"content_index/impossible_pairs\",\"value\":\"1\"" \
		pickaxe-threshold.trace
'

test_expect_success FSMONITOR_DAEMON \
	'pickaxe selects content index backend' '
	test_when_finished "test_might_fail git fsmonitor--daemon stop &&
			    git config --unset core.fsmonitor" &&
	git config core.fsmonitor true &&
	git fsmonitor--daemon start &&
	test_when_finished "rm -f pickaxe-direct.trace pickaxe-ipc.trace \
			    pickaxe-fallback.trace pickaxe-missing.trace" &&
	old_oid=$(git rev-parse HEAD^:pickaxe-history) &&
	new_oid=$(git rev-parse HEAD:pickaxe-history) &&
	old_object=.git/objects/$(test_oid_to_path "$old_oid") &&
	new_object=.git/objects/$(test_oid_to_path "$new_oid") &&
	mv "$old_object" "$old_object.save" &&
	mv "$new_object" "$new_object.save" &&
	test_when_finished "mv \"$old_object.save\" \"$old_object\" &&
			    mv \"$new_object.save\" \"$new_object\"" &&

	GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		GIT_TRACE2_EVENT="$PWD/pickaxe-direct.trace" \
		git log --format=%s -Sabsent HEAD^..HEAD \
		-- pickaxe-history >actual 2>err &&
	test_must_be_empty actual &&
	test_must_be_empty err &&
	test_grep "\"key\":\"content_index/prepared\",\"value\":\"1\"" \
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

test_expect_success 'possible pickaxe blobs use normal reads' '
	new_oid=$(git rev-parse HEAD:pickaxe-history) &&
	new_object=.git/objects/$(test_oid_to_path "$new_oid") &&
	mv "$new_object" "$new_object.save" &&
	test_when_finished "mv \"$new_object.save\" \"$new_object\"" &&

	test_must_fail env GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS=0 \
		git log --format=%s -Sneedle HEAD^..HEAD \
		-- pickaxe-history 2>err &&
	test_grep "unable to read" err
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
	test_cmp expect actual
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
	test_cmp expect actual
'

test_expect_success 'content index does not skip regex validation' '
	test_must_fail git -c grep.threads=8 grep --cached \
		"absent[9-0]" 2>err &&
	test_grep "Invalid range" err
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
	export GIT_TEST_GREP_LITERAL_PATHS &&
	test_when_finished "unset GIT_TEST_GREP_LITERAL_PATHS" &&
	test_when_finished "rm -f .git/fsmonitor-ordinary \
			    .git/index.grep-worktree &&
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
			    rm -f .git/index.grep-worktree candidate-*.trace" &&
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

	test_expect_code 1 git grep --no-content-index \
		"absent candidate warmup" -- "ord*" &&
	test_path_is_file .git/index.grep-worktree &&

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

test_expect_success 'content index prunes impossible multiple patterns' '
	oid=$(git rev-parse :short) &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "mv \"$object.save\" \"$object\"" &&

	test_must_fail git grep --cached \
		-e "absent alpha" -e "absent beta" 2>err &&
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
	test_must_fail git grep --cached "absent alpha*" 2>err &&
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

test_done

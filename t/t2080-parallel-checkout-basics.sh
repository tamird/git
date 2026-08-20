#!/bin/sh

test_description='parallel-checkout basics

Ensure that parallel-checkout basically works on clone and checkout, spawning
the required number of workers and correctly populating both the index and the
working tree.
'

TEST_NO_CREATE_REPO=1
. ./test-lib.sh
. "$TEST_DIRECTORY/lib-parallel-checkout.sh"

# Set queue_entry_intervals to the single summary timer's interval count.
test_queue_entry_timer () {
	test_grep ! \
		"\"event\":\"th_timer\".*\"category\":\"unpack_trees\",\"name\":\"queue-entries/$2\"" \
		"$1" &&
	test_grep ! \
		"\"event\":\"region_[^\"]*\".*\"category\":\"unpack_trees\",\"label\":\"queue-entries/$2\"" \
		"$1" &&
	if test "$3" = absent
	then
		queue_entry_intervals=0 &&
		test_grep ! \
			"\"event\":\"timer\".*\"category\":\"unpack_trees\",\"name\":\"queue-entries/$2\"," \
			"$1"
	else
		grep \
			"\"event\":\"timer\".*\"category\":\"unpack_trees\",\"name\":\"queue-entries/$2\"," \
			"$1" >count &&
		test_line_count = 1 count &&
		queue_entry_intervals=$(sed -n \
			"s#.*\"intervals\":\\([0-9][0-9]*\\),.*#\\1#p" count) &&
		case "$queue_entry_intervals" in
		""|*[!0-9]*|0*) return 1 ;;
		esac &&
		{
			test "$3" = any ||
			test "$queue_entry_intervals" = "$3"
		}
	fi
}

# Test parallel-checkout with a branch switch containing a variety of file
# creations, deletions, and modifications, involving different entry types.
# The branches B1 and B2 have the following paths:
#
#      B1                 B2
#  a/a (file)         a   (file)
#  b   (file)         b/b (file)
#
#  c/c (file)         c   (symlink)
#  d   (symlink)      d/d (file)
#
#  e/e (file)         e   (submodule)
#  f   (submodule)    f/f (file)
#
#  g   (submodule)    g   (symlink)
#  h   (symlink)      h   (submodule)
#
# Additionally, the following paths are present on both branches, but with
# different contents:
#
#  i   (file)         i   (file)
#  j   (symlink)      j   (symlink)
#  k   (submodule)    k   (submodule)
#
# And the following paths are only present in one of the branches:
#
#  l/l (file)         -
#  -                  m/m (file)
#
test_expect_success 'setup repo for checkout with various types of changes' '
	test_config_global protocol.file.allow always &&

	git init sub &&
	(
		cd sub &&
		git checkout -b B2 &&
		echo B2 >file &&
		git add file &&
		git commit -m file &&

		git checkout -b B1 &&
		echo B1 >file &&
		git add file &&
		git commit -m file
	) &&

	git init various &&
	(
		cd various &&

		git checkout -b B1 &&
		mkdir a c e &&
		echo a/a >a/a &&
		echo b >b &&
		echo c/c >c/c &&
		test_ln_s_add c d &&
		echo e/e >e/e &&
		git submodule add ../sub f &&
		git submodule add ../sub g &&
		test_ln_s_add c h &&

		echo "B1 i" >i &&
		test_ln_s_add c j &&
		git submodule add -b B1 ../sub k &&
		mkdir l &&
		echo l/l >l/l &&

		git add . &&
		git commit -m B1 &&

		git checkout -b B2 &&
		git rm -rf :^.gitmodules :^k &&
		mkdir b d f &&
		echo a >a &&
		echo b/b >b/b &&
		test_ln_s_add b c &&
		echo d/d >d/d &&
		git submodule add ../sub e &&
		echo f/f >f/f &&
		test_ln_s_add b g &&
		git submodule add ../sub h &&

		echo "B2 i" >i &&
		test_ln_s_add b j &&
		git -C k checkout B2 &&
		mkdir m &&
		echo m/m >m/m &&

		git add . &&
		git commit -m B2 &&

		git checkout --recurse-submodules B1
	)
'

test_expect_success 'feature.manyFiles enables bounded checkout workers' '
	git init many-files &&
	(
		cd many-files &&
		for i in $(test_seq 1 8)
		do
			echo "$i" >"file-$i" || return 1
		done &&
		git add . &&
		git commit -m files &&
		workers=$(test-tool online-cpus) &&
		if test "$workers" -gt 8
		then
			workers=8
		fi &&
		if test "$workers" -eq 1
		then
			workers=0
		fi &&

		rm file-* &&
		test_checkout_workers 0 git \
			-c feature.manyFiles=false \
			-c checkout.thresholdForParallelism=0 checkout . &&

		rm file-* &&
		test_checkout_workers 0 git \
			-c feature.manyFiles=true checkout . &&

		rm file-* &&
		test_checkout_workers "$workers" git \
			-c feature.manyFiles=true \
			-c checkout.thresholdForParallelism=0 checkout . &&

		rm file-* &&
		test_checkout_workers 0 git \
			-c feature.manyFiles=true \
			-c checkout.workers=1 \
			-c checkout.thresholdForParallelism=0 checkout . &&

		rm file-* &&
		test_checkout_workers 0 env GIT_TEST_CHECKOUT_WORKERS=1 git \
			-c feature.manyFiles=true \
			-c checkout.thresholdForParallelism=0 checkout .
	)
'

for mode in sequential parallel sequential-fallback
do
	case $mode in
	sequential)          workers=1 threshold=0 expected_workers=0 ;;
	parallel)            workers=2 threshold=0 expected_workers=2 ;;
	sequential-fallback) workers=2 threshold=100 expected_workers=0 ;;
	esac

	test_expect_success "$mode checkout" '
		repo=various_$mode &&
		cp -R -P various $repo &&

		# The just copied files have more recent timestamps than their
		# associated index entries. So refresh the cached timestamps
		# to avoid an "entry not up-to-date" error from `git checkout`.
		# We only have to do this for the submodules as `git checkout`
		# will already refresh the superproject index before performing
		# the up-to-date check.
		#
		git -C $repo submodule foreach "git update-index --refresh" &&

		set_checkout_config $workers $threshold &&
		trace_file="$(pwd)/$repo.trace" &&
		rm -f "$trace_file" &&
		test_checkout_workers $expected_workers \
			env GIT_TRACE2_EVENT="$trace_file" \
			git -C $repo checkout --recurse-submodules B2 &&
		root_sid=$(sed -n "1s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" "$trace_file") &&
		test -n "$root_sid" &&
		root_trace="$trace_file.root" &&
		grep -F "\"sid\":\"$root_sid\"" "$trace_file" >"$root_trace" &&
		for pair in "remove_entries 7" "queue_entries 13"
		do
			set -- $pair &&
			grep "\"category\":\"unpack_trees\",\"key\":\"$1/count\"" \
				"$root_trace" >count &&
			test_line_count = 1 count &&
			test_grep "\"value\":\"$2\"" count || return 1
		done &&
		if test "$mode" = sequential-fallback
		then
			grep "\"category\":\"pcheckout\",\"key\":\"queue/items\"" \
				"$root_trace" >count &&
			test_line_count = 1 count &&
			test_grep "\"value\":\"[1-9][0-9]*\"" count &&
			for region in sequential-write handle-results
			do
				for event in region_enter region_leave
				do
					grep "\"event\":\"$event\".*\"category\":\"pcheckout\",\"label\":\"$region\"" \
						"$root_trace" >region &&
					test_line_count = 1 region || return 1
				done || return 1
			done &&
			for region in setup dispatch-and-collect finish
			do
				test_grep ! "\"category\":\"pcheckout\",\"label\":\"$region\"" \
					"$root_trace" || return 1
			done
		fi &&
		verify_checkout $repo &&
		test_queue_entry_timer "$root_trace" prepare-entry 13 &&
		test_queue_entry_timer "$root_trace" attrs-and-enqueue any &&
		attrs_and_enqueue=$queue_entry_intervals &&
		test_queue_entry_timer "$root_trace" write-entry any &&
		write_entries=$queue_entry_intervals &&
		if test "$mode" = sequential
		then
			test_grep ! \
				"\"category\":\"pcheckout\",\"key\":\"queue/items\"" \
				"$root_trace" &&
			queued_entries=0
		else
			grep "\"event\":\"data\".*\"category\":\"pcheckout\",\"key\":\"queue/items\"," \
				"$root_trace" >count &&
			test_line_count = 1 count &&
			queued_entries=$(sed -n \
				"s#.*\"value\":\"\\([0-9][0-9]*\\)\".*#\\1#p" count) &&
			case "$queued_entries" in
			""|*[!0-9]*|0*) return 1 ;;
			esac
		fi &&
		test "$attrs_and_enqueue" -eq "$((queued_entries + write_entries))"
	'
done

for mode in parallel sequential-fallback
do
	case $mode in
	parallel)            workers=2 threshold=0 expected_workers=2 ;;
	sequential-fallback) workers=2 threshold=100 expected_workers=0 ;;
	esac

	test_expect_success "$mode checkout on clone" '
		test_config_global protocol.file.allow always &&
		repo=various_${mode}_clone &&
		set_checkout_config $workers $threshold &&
		test_checkout_workers $expected_workers \
			git clone --recurse-submodules --branch B2 various $repo &&
		verify_checkout $repo
	'
done

# Just to be paranoid, actually compare the working trees' contents directly.
test_expect_success 'compare the working trees' '
	rm -rf various_*/.git &&
	rm -rf various_*/*/.git &&

	# We use `git diff` instead of `diff -r` because the latter would
	# follow symlinks, and not all `diff` implementations support the
	# `--no-dereference` option.
	#
	git diff --no-index various_sequential various_parallel &&
	git diff --no-index various_sequential various_parallel_clone &&
	git diff --no-index various_sequential various_sequential-fallback &&
	git diff --no-index various_sequential various_sequential-fallback_clone
'

# Currently, each submodule is checked out in a separated child process, but
# these subprocesses must also be able to use parallel checkout workers to
# write the submodules' entries.
test_expect_success 'submodules can use parallel checkout' '
	set_checkout_config 2 0 &&
	git init super &&
	(
		cd super &&
		git init sub &&
		test_commit -C sub A &&
		test_commit -C sub B &&
		git submodule add ./sub &&
		git commit -m sub &&
		rm sub/* &&
		test_checkout_workers 2 git checkout --recurse-submodules .
	)
'

test_expect_success 'parallel checkout respects --[no]-force' '
	set_checkout_config 2 0 &&
	git init dirty &&
	(
		cd dirty &&
		mkdir D &&
		test_commit D/F &&
		test_commit F &&

		rm -rf D &&
		echo changed >D &&
		echo changed >F.t &&

		# We expect 0 workers because there is nothing to be done
		trace_file="$(pwd)/trace-noop" &&
		rm -f "$trace_file" &&
		test_checkout_workers 0 env GIT_TRACE2_EVENT="$trace_file" \
			git checkout HEAD &&
		root_sid=$(sed -n "1s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" "$trace_file") &&
		test -n "$root_sid" &&
		root_trace="$trace_file.root" &&
		grep -F "\"sid\":\"$root_sid\"" "$trace_file" >"$root_trace" &&
		for region in remove_entries queue_entries
		do
			grep "\"category\":\"unpack_trees\",\"key\":\"$region/count\"" \
				"$root_trace" >count &&
			test_line_count = 1 count &&
			test_grep "\"value\":\"0\"" count || return 1
		done &&
		test_grep ! "\"category\":\"pcheckout\"" "$root_trace" &&
		test_path_is_file D &&
		test_grep changed D &&
		test_grep changed F.t &&

		test_checkout_workers 2 git checkout --force HEAD &&
		test_path_is_dir D &&
		test_grep D/F D/F.t &&
		test_grep F F.t &&
		for phase in prepare-entry attrs-and-enqueue write-entry
		do
			test_queue_entry_timer "$root_trace" "$phase" absent ||
				return 1
		done
	)
'

test_expect_success 'parallel checkout refills worker queues' '
	set_checkout_config 2 0 &&
	git init refill &&
	(
		cd refill &&
		for i in $(test_seq 1 33)
		do
			echo "$i" >"file-$i" || return 1
		done &&
		git add . &&
		git commit -m files &&
		rm file-* &&

		test_checkout_workers 2 git checkout . &&
		git diff --exit-code
	)
'

test_expect_success 'parallel checkout traces worker load' '
	set_checkout_config 2 0 &&
	git init trace-load &&
	(
		cd trace-load &&
		test_write_lines a >a &&
		test_write_lines b >b &&
		test_write_lines c >c &&
		test_write_lines d >d &&
		git add . &&
		git commit -m files &&
		rm a b c d &&

		trace_file="$(pwd)/trace-event" &&
		rm -f "$trace_file" &&
		GIT_TRACE2_EVENT="$trace_file" git checkout . &&
		root_sid=$(sed -n "1s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" "$trace_file") &&
		test -n "$root_sid" &&
		root_trace="$trace_file.root" &&
		grep -F "\"sid\":\"$root_sid\"" "$trace_file" >"$root_trace" &&
		grep "\"category\":\"pcheckout\",\"key\":\"queue/items\"" \
			"$root_trace" >count &&
		test_line_count = 1 count &&
		test_grep "\"value\":\"4\"" count &&
		for region in setup dispatch-and-collect finish handle-results
		do
			for event in region_enter region_leave
			do
				grep "\"event\":\"$event\".*\"category\":\"pcheckout\",\"label\":\"$region\"" \
					"$root_trace" >region &&
				test_line_count = 1 region || return 1
			done || return 1
		done &&
		test_grep ! "\"category\":\"pcheckout\",\"label\":\"sequential-write\"" \
			"$root_trace" &&
		for pair in \
			"items 2" \
			"written 2" \
			"collided 0" \
			"failed 0" \
			"bytes 4" \
			"slowest-item-bytes 2"
		do
			set -- $pair &&
			grep "\"category\":\"pcheckout\",\"key\":\"worker/$1\",\"value\":\"$2\"" \
				"$trace_file" >"$1" &&
			test_line_count = 2 "$1" ||
			return 1
		done &&
		grep "\"category\":\"pcheckout\",\"key\":\"worker/slowest-item-us\"" \
			"$trace_file" >slowest-item-us &&
		test_line_count = 2 slowest-item-us
	)
'

test_expect_success SYMLINKS 'parallel checkout checks for symlinks in leading dirs' '
	set_checkout_config 2 0 &&
	git init symlinks &&
	(
		cd symlinks &&
		mkdir D untracked &&
		# Commit 2 files to have enough work for 2 parallel workers
		test_commit D/A &&
		test_commit D/B &&
		rm -rf D &&
		ln -s untracked D &&

		test_checkout_workers 2 git checkout --force HEAD &&
		! test -h D &&
		test_grep D/A D/A.t &&
		test_grep D/B D/B.t
	)
'

# This test is here (and not in e.g. t2022-checkout-paths.sh), because we
# check the final report including sequential, parallel, and delayed entries
# all at the same time. So we must have finer control of the parallel checkout
# variables.
test_expect_success '"git checkout ." report should not include failed entries' '
	test_config_global filter.delay.process \
		"test-tool rot13-filter --always-delay --log=delayed.log clean smudge delay" &&
	test_config_global filter.delay.required true &&
	test_config_global filter.cat.clean cat  &&
	test_config_global filter.cat.smudge cat  &&
	test_config_global filter.cat.required true  &&

	set_checkout_config 2 0 &&
	git init failed_entries &&
	(
		cd failed_entries &&
		cat >.gitattributes <<-EOF &&
		*delay*              filter=delay
		parallel-ineligible* filter=cat
		EOF
		echo a >missing-delay.a &&
		echo a >parallel-ineligible.a &&
		echo a >parallel-eligible.a &&
		echo b >success-delay.b &&
		echo b >parallel-ineligible.b &&
		echo b >parallel-eligible.b &&
		git add -A &&
		git commit -m files &&

		a_blob="$(git rev-parse :parallel-ineligible.a)" &&
		rm .git/objects/$(test_oid_to_path $a_blob) &&
		rm *.a *.b &&

		test_checkout_workers 2 test_must_fail git checkout . 2>err &&

		# All *.b entries should succeed and all *.a entries should fail:
		#  - missing-delay.a: the delay filter will drop this path
		#  - parallel-*.a: the blob will be missing
		#
		test_grep "Updated 3 paths from the index" err &&
		test_stdout_line_count = 3 ls *.b &&
		! ls *.a
	)
'

test_expect_success 'branch switch reports parallel checkout failures' '
	test_when_finished "rm -rf failed_switch" &&
	set_checkout_config 2 0 &&
	git init -b source failed_switch &&
	(
		cd failed_switch &&
		test_commit base &&
		git checkout -b target &&
		echo good >good &&
		echo bad >bad &&
		git add good bad &&
		git commit -m target &&

		git rev-parse HEAD >expect-head &&
		git symbolic-ref HEAD >expect-branch &&
		git ls-files --stage >expect-index &&
		cp good expect-good &&
		bad_blob=$(git rev-parse :bad) &&
		test "$bad_blob" != "$(git rev-parse :good)" &&
		test "$bad_blob" != "$(git rev-parse :base.t)" &&
		git checkout source &&
		rm .git/objects/$(test_oid_to_path "$bad_blob") &&
		test_must_fail git cat-file -e "$bad_blob" &&

		capture_switch_exit () {
			if GIT_TRACE2_EVENT="$PWD/switch-event.log" \
				git switch target 2>switch.err
			then
				switch_status=0
			else
				switch_status=$?
			fi &&
			printf "%s\n" "$switch_status" >switch.exit
		} &&
		test_checkout_workers 2 capture_switch_exit &&
		grep "\"category\":\"pcheckout\",\"key\":\"worker/failed\"" \
			switch-event.log >worker-failed &&
		test_line_count = 2 worker-failed &&
		grep "\"value\":\"1\"" worker-failed >failed-one &&
		test_line_count = 1 failed-one &&
		grep "\"value\":\"0\"" worker-failed >failed-zero &&
		test_line_count = 1 failed-zero &&
		test_grep "cannot read object $bad_blob" switch.err &&
		git rev-parse HEAD >actual-head &&
		test_cmp expect-head actual-head &&
		git symbolic-ref HEAD >actual-branch &&
		test_cmp expect-branch actual-branch &&
		git ls-files --stage >actual-index &&
		test_cmp expect-index actual-index &&
		test_cmp expect-good good &&
		test_path_is_missing bad &&

		echo 1 >expect-exit &&
		test_cmp expect-exit switch.exit &&
		root_sid=$(sed -n "1s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" switch-event.log) &&
		test -n "$root_sid" &&
		root_trace="$PWD/switch-event.log.root" &&
		grep -F "\"sid\":\"$root_sid\"" switch-event.log >"$root_trace" &&
		test_queue_entry_timer "$root_trace" prepare-entry 2 &&
		test_queue_entry_timer "$root_trace" attrs-and-enqueue 2 &&
		test_queue_entry_timer "$root_trace" write-entry absent
	)
'

test_done

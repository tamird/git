#!/bin/sh

test_description='git rebase + directory rename tests'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-rebase.sh

test_expect_success 'setup testcase where directory rename should be detected' '
	test_create_repo dir-rename &&
	(
		cd dir-rename &&

		mkdir x &&
		test_seq  1 10 >x/a &&
		test_seq 11 20 >x/b &&
		test_seq 21 30 >x/c &&
		test_write_lines a b c d e f g h i >l &&
		git add x l &&
		git commit -m "Initial" &&

		git branch O &&
		git branch A &&
		git branch B &&

		git checkout A &&
		git mv x y &&
		git mv l letters &&
		git commit -m "Rename x to y, l to letters" &&

		git checkout B &&
		echo j >>l &&
		test_seq 31 40 >x/d &&
		git add l x/d &&
		git commit -m "Modify l, add x/d"
	)
'

test_expect_success 'rebase --interactive: directory rename detected' '
	(
		cd dir-rename &&

		git checkout B^0 &&

		set_fake_editor &&
		FAKE_LINES="1" git -c merge.directoryRenames=true rebase --interactive A &&

		git ls-files -s >out &&
		test_line_count = 5 out &&

		test_path_is_file y/d &&
		test_path_is_missing x/d
	)
'

test_expect_failure 'rebase --apply: directory rename detected' '
	(
		cd dir-rename &&

		git checkout B^0 &&

		git -c merge.directoryRenames=true rebase --apply A &&

		git ls-files -s >out &&
		test_line_count = 5 out &&

		test_path_is_file y/d &&
		test_path_is_missing x/d
	)
'

test_expect_success 'rebase --merge: directory rename detected' '
	(
		cd dir-rename &&

		git checkout B^0 &&

		. "$TEST_DIRECTORY"/lib-parallel-checkout.sh &&
		trace_file="$(pwd)/trace-rebase" &&
		rm -f "$trace_file" &&
		# Restore the default nesting limit, overridden by test-lib.sh.
		GIT_TRACE2_EVENT_NESTING=2 \
		GIT_TRACE2_EVENT="$trace_file" \
		GIT_TEST_CHECKOUT_WORKERS=2 \
			git -c merge.directoryRenames=true rebase --merge A &&

		git ls-files -s >out &&
		test_line_count = 5 out &&

		test_path_is_file y/d &&
		test_path_is_missing x/d &&

		sed -n "/\"event\":\"cmd_name\".*\"name\":\"rebase\"/s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" \
			"$trace_file" >rebase-sid &&
		test_line_count = 1 rebase-sid &&
		read root_sid <rebase-sid &&
		test -n "$root_sid" &&
		case "$root_sid" in
		*/*) return 1 ;;
		esac &&
		grep -F "\"sid\":\"$root_sid\"" "$trace_file" >root-trace &&
		test_checkout_worker_sids "$trace_file" 4 &&

		sed -n "/\"event\":\"child_start\".*\"argv\":\\[\"git\",\"checkout--worker\"/s/.*\"child_id\":\\([0-9][0-9]*\\),.*/\\1/p" \
			root-trace >worker-child-ids &&
		test_line_count = 4 worker-child-ids &&
		sort -u worker-child-ids >worker-child-ids.sorted &&
		test_line_count = 4 worker-child-ids.sorted &&
		while read child_id
		do
			grep "\"event\":\"child_exit\".*\"child_id\":$child_id," \
				root-trace >child-exit &&
			test_line_count = 1 child-exit &&
			test_grep "\"code\":0," child-exit ||
			return 1
		done <worker-child-ids &&

		test_write_lines start "exit 0" "atexit 0" >expect-lifecycle &&
		cat rebase-sid worker-sids >checkout-sids &&
		total=0 &&
		while read sid
		do
			grep -F "\"sid\":\"$sid\"" "$trace_file" >process-trace &&
			sed -n \
				-e "s/.*\"event\":\"start\".*/start/p" \
				-e "s/.*\"event\":\"exit\".*\"code\":\\([0-9][0-9]*\\)}.*/exit \\1/p" \
				-e "s/.*\"event\":\"atexit\".*\"code\":\\([0-9][0-9]*\\)}.*/atexit \\1/p" \
				process-trace >actual-lifecycle &&
			test_cmp expect-lifecycle actual-lifecycle ||
			return 1

			if test "$sid" = "$root_sid"
			then
				continue
			fi &&

			case "$sid" in
			"$root_sid"/*/*) return 1 ;;
			"$root_sid"/?*) ;;
			*) return 1 ;;
			esac &&
			items=$(sed -n "/\"event\":\"data\".*\"category\":\"pcheckout\",\"key\":\"worker\/items\"/s/.*\"value\":\"\\([0-9][0-9]*\\)\".*/\\1/p" process-trace) &&
			case "$items" in
			1|2) ;;
			*) return 1 ;;
			esac &&
			for pair in "items $items" "written $items" "collided 0" "failed 0"
			do
				set -- $pair &&
				grep "\"event\":\"data\".*\"category\":\"pcheckout\",\"key\":\"worker/$1\"," \
					process-trace >worker-count &&
				test_line_count = 1 worker-count &&
				test_grep "\"value\":\"$2\"}" worker-count ||
				return 1
			done &&
			total=$((total + items)) ||
			return 1
		done <checkout-sids &&
		test "$total" = 6 &&

		# Only checkout_onto is visible; the nested replay also writes two.
		grep "\"event\":\"data\".*\"category\":\"pcheckout\",\"key\":\"queue/items\"," \
			root-trace >queue-count &&
		test_line_count = 1 queue-count &&
		test_grep "\"nesting\":2," queue-count &&
		test_grep "\"value\":\"4\"}" queue-count &&

		test_grep ! "\"event\":\"th_counter\".*\"category\":\"pcheckout\",\"name\":\"parallel/items-total\"," \
			root-trace &&
		grep "\"event\":\"counter\".*\"category\":\"pcheckout\",\"name\":\"parallel/items-total\"," \
			root-trace >parallel-count &&
		test_line_count = 1 parallel-count &&
		test_grep "\"count\":6}" parallel-count
	)
'

test_expect_failure 'am: directory rename detected' '
	(
		cd dir-rename &&

		git checkout A^0 &&

		git format-patch -1 B &&

		git -c merge.directoryRenames=true am --3way 0001*.patch &&

		git ls-files -s >out &&
		test_line_count = 5 out &&

		test_path_is_file y/d &&
		test_path_is_missing x/d
	)
'

test_expect_success 'setup testcase where directory rename should NOT be detected' '
	test_create_repo no-dir-rename &&
	(
		cd no-dir-rename &&

		mkdir x &&
		test_seq  1 10 >x/a &&
		test_seq 11 20 >x/b &&
		test_seq 21 30 >x/c &&
		echo original >project_info &&
		git add x project_info &&
		git commit -m "Initial" &&

		git branch O &&
		git branch A &&
		git branch B &&

		git checkout A &&
		echo v2 >project_info &&
		git add project_info &&
		git commit -m "Modify project_info" &&

		git checkout B &&
		mkdir y &&
		git mv x/c y/c &&
		echo v1 >project_info &&
		git add project_info &&
		git commit -m "Rename x/c to y/c, modify project_info"
	)
'

test_expect_success 'rebase --interactive: NO directory rename' '
	test_when_finished "git -C no-dir-rename rebase --abort" &&
	(
		cd no-dir-rename &&

		git checkout B^0 &&

		set_fake_editor &&
		test_must_fail env FAKE_LINES="1" git rebase --interactive A &&

		git ls-files -s >out &&
		test_line_count = 6 out &&

		test_path_is_file x/a &&
		test_path_is_file x/b &&
		test_path_is_missing x/c
	)
'

test_expect_success 'rebase (am): NO directory rename' '
	test_when_finished "git -C no-dir-rename rebase --abort" &&
	(
		cd no-dir-rename &&

		git checkout B^0 &&

		set_fake_editor &&
		test_must_fail git rebase A &&

		git ls-files -s >out &&
		test_line_count = 6 out &&

		test_path_is_file x/a &&
		test_path_is_file x/b &&
		test_path_is_missing x/c
	)
'

test_expect_success 'rebase --merge: NO directory rename' '
	test_when_finished "git -C no-dir-rename rebase --abort" &&
	(
		cd no-dir-rename &&

		git checkout B^0 &&

		set_fake_editor &&
		test_must_fail git rebase --merge A &&

		git ls-files -s >out &&
		test_line_count = 6 out &&

		test_path_is_file x/a &&
		test_path_is_file x/b &&
		test_path_is_missing x/c
	)
'

test_expect_success 'am: NO directory rename' '
	test_when_finished "git -C no-dir-rename am --abort" &&
	(
		cd no-dir-rename &&

		git checkout A^0 &&

		git format-patch -1 B &&

		test_must_fail git am --3way 0001*.patch &&

		git ls-files -s >out &&
		test_line_count = 6 out &&

		test_path_is_file x/a &&
		test_path_is_file x/b &&
		test_path_is_missing x/c
	)
'

test_done

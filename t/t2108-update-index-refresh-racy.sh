#!/bin/sh

test_description='update-index refresh tests related to racy timestamps'

. ./test-lib.sh

reset_files () {
	echo content >file &&
	echo content >other &&
	test_set_magic_mtime file &&
	test_set_magic_mtime other
}

update_assert_changed () {
	test_set_magic_mtime .git/index &&
	test_might_fail git update-index "$1" &&
	! test_is_magic_mtime .git/index
}

test_expect_success 'setup' '
	reset_files &&
	# we are calling reset_files() a couple of times during tests;
	# test-tool chmtime does not change the ctime; to not weaken
	# or even break our tests, disable ctime-checks entirely
	git config core.trustctime false &&
	git config core.fsmonitor false &&
	git add file other &&
	git commit -m "initial import"
'

test_expect_success '--refresh has no racy timestamps to fix' '
	reset_files &&
	# set the index time far enough to the future;
	# it must be at least 3 seconds for VFAT
	test_set_magic_mtime .git/index +60 &&
	GIT_TRACE2_EVENT="$PWD/.git/nonracy-event" \
		git update-index --refresh &&
	test_is_magic_mtime .git/index +60 &&
	test_grep ! "\"category\":\"index\",\"name\":\"racy-check\"" \
		.git/nonracy-event
'

test_expect_success '--refresh should fix racy timestamp' '
	reset_files &&
	GIT_TRACE2_EVENT="$PWD/.git/racy-event" \
	GIT_TRACE2_EVENT_NESTING=2 \
		update_assert_changed --refresh &&
	test_trace2_data index refresh/sum_scan 0 <.git/racy-event &&
	grep "\"event\":\"timer\".*\"category\":\"index\",\"name\":\"racy-check\"" \
		.git/racy-event >.git/racy-timers &&
	test_line_count = 1 .git/racy-timers &&
	test_grep "\"intervals\":2," .git/racy-timers &&
	test_grep ! "\"event\":\"th_timer\".*\"category\":\"index\",\"name\":\"racy-check\"" \
		.git/racy-event
'

test_expect_success 'assuming racy entries are dirty skips the fallback timer' '
	reset_files &&
	test_set_magic_mtime .git/index &&
	GIT_TRACE2_EVENT="$PWD/.git/assume-racy-event" \
		git add -u &&
	git diff --cached --exit-code &&
	test_grep ! "\"category\":\"index\",\"name\":\"racy-check\"" \
		.git/assume-racy-event
'

test_expect_success '--really-refresh should fix racy timestamp' '
	reset_files &&
	update_assert_changed --really-refresh
'

test_expect_success '--refresh should fix racy timestamp if other file needs update' '
	reset_files &&
	echo content2 >other &&
	test_set_magic_mtime other &&
	update_assert_changed --refresh
'

test_expect_success '--refresh should fix racy timestamp if racy file needs update' '
	reset_files &&
	echo content2 >file &&
	test_set_magic_mtime file &&
	update_assert_changed --refresh
'

test_done

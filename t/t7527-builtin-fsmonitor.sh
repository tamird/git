#!/bin/sh

test_description='built-in file system watcher'

. ./test-lib.sh

if ! test_have_prereq FSMONITOR_DAEMON
then
	skip_all="fsmonitor--daemon is not supported on this platform"
	test_done
fi

# Verify that the filesystem delivers events to the daemon.
# On some configurations (e.g., overlayfs with older kernels),
# inotify watches succeed but events are never delivered.  The
# cookie wait will time out and the daemon logs a trace message.
#
# Use "timeout" (if available) to guard each step against hangs.
maybe_timeout () {
	if type timeout >/dev/null 2>&1
	then
		timeout "$@"
	else
		shift
		"$@"
	fi
}

test_lazy_prereq FSMONITOR_WORKS '
	git init test_fsmonitor_smoke || return 1

	GIT_TRACE_FSMONITOR="$PWD/smoke.trace" &&
	export GIT_TRACE_FSMONITOR &&
	maybe_timeout 30 \
		git -C test_fsmonitor_smoke fsmonitor--daemon start \
			--start-timeout=10
	ret=$?
	unset GIT_TRACE_FSMONITOR
	if test $ret -ne 0
	then
		rm -rf test_fsmonitor_smoke smoke.trace
		return 1
	fi

	maybe_timeout 10 \
		test-tool -C test_fsmonitor_smoke fsmonitor-client query \
			--token 0 >/dev/null 2>&1
	maybe_timeout 5 \
		git -C test_fsmonitor_smoke fsmonitor--daemon stop 2>/dev/null
	! grep -q "cookie_wait timed out" "$PWD/smoke.trace" 2>/dev/null
	ret=$?
	rm -rf test_fsmonitor_smoke smoke.trace
	return $ret
'

if ! test_have_prereq FSMONITOR_WORKS
then
	skip_all="filesystem does not deliver fsmonitor events (container/overlayfs?)"
	test_done
fi

stop_daemon_delete_repo () {
	r=$1 &&
	{ maybe_timeout 30 git -C $r fsmonitor--daemon stop 2>/dev/null || :; } &&
	rm -rf $1
}

start_daemon () {
	r= tf= t2= tk= &&

	while test "$#" -ne 0
	do
		case "$1" in
		-C)
			r="-C ${2?}"
			shift
			;;
		--tf)
			tf="${2?}"
			shift
			;;
		--t2)
			t2="${2?}"
			shift
			;;
		--tk)
			tk="${2?}"
			shift
			;;
		-*)
			BUG "error: unknown option: '$1'"
			;;
		*)
			BUG "error: unbound argument: '$1'"
			;;
		esac
		shift
	done &&

	(
		if test -n "$tf"
		then
			GIT_TRACE_FSMONITOR="$tf"
			export GIT_TRACE_FSMONITOR
		fi &&

		if test -n "$t2"
		then
			GIT_TRACE2_PERF="$t2"
			export GIT_TRACE2_PERF
		fi &&

		if test -n "$tk"
		then
			GIT_TEST_FSMONITOR_TOKEN="$tk"
			export GIT_TEST_FSMONITOR_TOKEN
		fi &&

		git $r fsmonitor--daemon start --start-timeout=10 &&
		git $r fsmonitor--daemon status
	)
}

# Is a Trace2 data event present with the given catetory and key?
# We do not care what the value is.
#
have_t2_data_event () {
	c=$1 &&
	k=$2 &&

	grep -e '"event":"data".*"category":"'"$c"'".*"key":"'"$k"'"'
}

test_expect_success 'explicit daemon start and stop' '
	test_when_finished "stop_daemon_delete_repo test_explicit" &&

	git init test_explicit &&
	start_daemon -C test_explicit &&

	git -C test_explicit fsmonitor--daemon stop &&
	test_must_fail git -C test_explicit fsmonitor--daemon status
'

test_expect_success 'implicit daemon start' '
	test_when_finished "stop_daemon_delete_repo test_implicit" &&

	git init test_implicit &&
	test_must_fail git -C test_implicit fsmonitor--daemon status &&

	# query will implicitly start the daemon.
	#
	# for test-script simplicity, we send a V1 timestamp rather than
	# a V2 token.  either way, the daemon response to any query contains
	# a new V2 token.  (the daemon may complain that we sent a V1 request,
	# but this test case is only concerned with whether the daemon was
	# implicitly started.)

	GIT_TRACE2_EVENT="$PWD/.git/trace" \
		test-tool -C test_implicit fsmonitor-client query --token 0 >actual &&
	nul_to_q <actual >actual.filtered &&
	test_grep "builtin:" actual.filtered &&

	# confirm that a daemon was started in the background.
	#
	# since the mechanism for starting the background daemon is platform
	# dependent, just confirm that the foreground command received a
	# response from the daemon.

	have_t2_data_event fsm_client query/response-length <.git/trace &&

	git -C test_implicit fsmonitor--daemon status &&
	git -C test_implicit fsmonitor--daemon stop &&
	test_must_fail git -C test_implicit fsmonitor--daemon status
'

test_expect_success SYMLINKS 'daemon startup does not follow directory symlinks' '
	test_when_finished "stop_daemon_delete_repo test_startup_symlinks" &&
	test_when_finished "rm -rf test_startup_symlinks_outside" &&
	git init test_startup_symlinks &&
	mkdir -p test_startup_symlinks/real/nested \
		test_startup_symlinks_outside &&
	echo tracked >test_startup_symlinks/real/nested/tracked &&
	ln -s . test_startup_symlinks/loop &&
	ln -s ../test_startup_symlinks_outside \
		test_startup_symlinks/outside &&
	(
		cd test_startup_symlinks &&
		git add real/nested/tracked loop outside &&
		git commit -m initial &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true
	) &&
	start_daemon -C test_startup_symlinks &&
	echo visible >test_startup_symlinks/real/nested/visible &&
	echo outside >test_startup_symlinks_outside/untracked &&
	(
		cd test_startup_symlinks &&
		git status --porcelain >../startup-symlinks.actual &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain >../startup-symlinks.expect &&
		test_cmp ../startup-symlinks.expect \
			../startup-symlinks.actual &&
		test_grep "^?? real/nested/visible$" \
			../startup-symlinks.actual &&
		test_grep ! "outside" ../startup-symlinks.actual
	)
'

# Verify that the daemon has shutdown.  Spin a few seconds to
# make the test a little more robust during CI testing.
#
# We're looking for an implicit shutdown, such as when we delete or
# rename the ".git" directory.  Our delete/rename will cause a file
# system event that the daemon will see and the daemon will
# auto-shutdown as soon as it sees it.  But this is racy with our `git
# fsmonitor--daemon status` commands (and we cannot use a cookie file
# here to help us).  So spin a little and give the daemon a chance to
# see the event.  (This is primarily for underpowered CI build/test
# machines (where it might take a moment to wake and reschedule the
# daemon process) to avoid false alarms during test runs.)
#
IMPLICIT_TIMEOUT=5

verify_implicit_shutdown () {
	r=$1 &&

	k=0 &&
	while test "$k" -lt $IMPLICIT_TIMEOUT
	do
		git -C $r fsmonitor--daemon status || return 0

		sleep 1
		k=$(( $k + 1 ))
	done &&

	return 1
}

test_expect_success 'implicit daemon stop (delete .git)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_1" &&

	git init test_implicit_1 &&

	start_daemon -C test_implicit_1 &&

	# deleting the .git directory will implicitly stop the daemon.
	rm -rf test_implicit_1/.git &&

	# [1] Create an empty .git directory so that the following Git
	#     command will stay relative to the `-C` directory.
	#
	#     Without this, the Git command will override the requested
	#     -C argument and crawl out to the containing Git source tree.
	#     This would make the test result dependent upon whether we
	#     were using fsmonitor on our development worktree.
	#
	mkdir test_implicit_1/.git &&

	verify_implicit_shutdown test_implicit_1
'

test_expect_success 'implicit daemon stop (rename .git)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_2" &&

	git init test_implicit_2 &&

	start_daemon -C test_implicit_2 &&

	# renaming the .git directory will implicitly stop the daemon.
	mv test_implicit_2/.git test_implicit_2/.xxx &&

	# See [1] above.
	#
	mkdir test_implicit_2/.git &&

	verify_implicit_shutdown test_implicit_2
'

# File systems on Windows may or may not have shortnames.
# This is a volume-specific setting on modern systems.
# "C:/" drives are required to have them enabled.  Other
# hard drives default to disabled.
#
# This is a crude test to see if shortnames are enabled
# on the volume containing the test directory.  It is
# crude, but it does not require elevation like `fsutil`.
#
test_lazy_prereq SHORTNAMES '
	mkdir .foo &&
	test -d "FOO~1"
'

# Here we assume that the shortname of ".git" is "GIT~1".
test_expect_success MINGW,SHORTNAMES 'implicit daemon stop (rename GIT~1)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_1s" &&

	git init test_implicit_1s &&

	start_daemon -C test_implicit_1s &&

	# renaming the .git directory will implicitly stop the daemon.
	# this moves {.git, GIT~1} to {.gitxyz, GITXYZ~1}.
	# the rename-from FS Event will contain the shortname.
	#
	mv test_implicit_1s/GIT~1 test_implicit_1s/.gitxyz &&

	# See [1] above.
	# this moves {.gitxyz, GITXYZ~1} to {.git, GIT~1}.
	mv test_implicit_1s/.gitxyz test_implicit_1s/.git &&

	verify_implicit_shutdown test_implicit_1s
'

# Here we first create a file with LONGNAME of "GIT~1" before
# we create the repo.  This will cause the shortname of ".git"
# to be "GIT~2".
test_expect_success MINGW,SHORTNAMES 'implicit daemon stop (rename GIT~2)' '
	test_when_finished "stop_daemon_delete_repo test_implicit_1s2" &&

	mkdir test_implicit_1s2 &&
	echo HELLO >test_implicit_1s2/GIT~1 &&
	git init test_implicit_1s2 &&

	test_path_is_file test_implicit_1s2/GIT~1 &&
	test_path_is_dir  test_implicit_1s2/GIT~2 &&

	start_daemon -C test_implicit_1s2 &&

	# renaming the .git directory will implicitly stop the daemon.
	# the rename-from FS Event will contain the shortname.
	#
	mv test_implicit_1s2/GIT~2 test_implicit_1s2/.gitxyz &&

	# See [1] above.
	mv test_implicit_1s2/.gitxyz test_implicit_1s2/.git &&

	verify_implicit_shutdown test_implicit_1s2
'

test_expect_success 'cannot start multiple daemons' '
	test_when_finished "stop_daemon_delete_repo test_multiple" &&

	git init test_multiple &&

	start_daemon -C test_multiple &&

	test_must_fail git -C test_multiple fsmonitor--daemon start 2>actual &&
	test_grep "fsmonitor--daemon is already running" actual &&

	git -C test_multiple fsmonitor--daemon stop &&
	test_must_fail git -C test_multiple fsmonitor--daemon status
'

test_expect_success 'git diff reuses only a synchronized full index' '
	for split in false true
	do
		repo=test_diff_refresh_$split &&
		test_when_finished "stop_daemon_delete_repo $repo" &&
		git init "$repo" &&
		(
			cd "$repo" &&
			git config core.splitIndex "$split" &&
			test_commit base tracked &&
			if test "$split" = true
			then
				git update-index --split-index
			fi &&
			git config core.fsmonitor true
		) &&
		start_daemon -C "$repo" &&
		(
			cd "$repo" &&
			git status --porcelain >.git/diff-refresh-before &&
			test_must_be_empty .git/diff-refresh-before &&
			test-tool chmtime +10 tracked &&
			GIT_TRACE2_EVENT="$PWD/.git/diff-refresh.trace" \
				git diff --name-only >.git/diff-refresh-actual &&
			test_must_be_empty .git/diff-refresh-actual &&
			case "$split" in
			false) reuse=1 ;;
			true) reuse=0 ;;
			esac &&
			test_trace2_data index refresh/reuse "$reuse" \
				<.git/diff-refresh.trace &&
			git diff-files --name-only -- tracked \
				>.git/diff-refresh-after &&
			test_must_be_empty .git/diff-refresh-after
		) || return 1
	done
'

test_expect_success 'git diff rereads an index after a worktree change' '
	test_when_finished "stop_daemon_delete_repo test_diff_refresh_changed" &&
	git init test_diff_refresh_changed &&
	(
		cd test_diff_refresh_changed &&
		git config core.splitIndex false &&
		echo clean >clean &&
		echo trigger >trigger &&
		git add -- clean trigger &&
		git commit -m initial &&
		write_script .git/diff-refresh-race <<-\EOF &&
			echo concurrent >>clean
		EOF
		git config diff.external .git/diff-refresh-race &&
		git config core.fsmonitor true
	) &&
	start_daemon -C test_diff_refresh_changed &&
	(
		cd test_diff_refresh_changed &&
		git status --porcelain >.git/diff-refresh-before &&
		test_must_be_empty .git/diff-refresh-before &&
		test-tool chmtime +10 clean &&
		echo modified >>trigger &&
		GIT_TRACE2_EVENT="$PWD/.git/diff-refresh.trace" \
			git diff >.git/diff-refresh-actual &&
		test_must_be_empty .git/diff-refresh-actual &&
		test_trace2_data index refresh/reuse 0 \
			<.git/diff-refresh.trace &&
		printf " M clean\n M trigger\n" >.git/diff-refresh-expect &&
		git status --porcelain >.git/diff-refresh-after &&
		test_cmp .git/diff-refresh-expect .git/diff-refresh-after
	)
'

# These tests use the main repo in the trash directory

test_expect_success 'setup' '
	>tracked &&
	>modified &&
	>delete &&
	>rename &&
	mkdir dir1 &&
	>dir1/tracked &&
	>dir1/modified &&
	>dir1/delete &&
	>dir1/rename &&
	mkdir dir2 &&
	>dir2/tracked &&
	>dir2/modified &&
	>dir2/delete &&
	>dir2/rename &&
	mkdir dirtorename &&
	>dirtorename/a &&
	>dirtorename/b &&

	cat >.gitignore <<-\EOF &&
	.gitignore
	expect*
	actual*
	flush*
	trace*
	EOF

	mkdir -p T1/T2/T3/T4 &&
	echo 1 >T1/F1 &&
	echo 1 >T1/T2/F1 &&
	echo 1 >T1/T2/T3/F1 &&
	echo 1 >T1/T2/T3/T4/F1 &&
	echo 2 >T1/F2 &&
	echo 2 >T1/T2/F2 &&
	echo 2 >T1/T2/T3/F2 &&
	echo 2 >T1/T2/T3/T4/F2 &&

	git -c core.fsmonitor=false add . &&
	test_tick &&
	git -c core.fsmonitor=false commit -m initial &&

	git config core.fsmonitor true
'

# The test already explicitly stopped (or tried to stop) the daemon.
# This is here in case something else fails first.
#
redundant_stop_daemon () {
	test_might_fail git fsmonitor--daemon stop
}

test_expect_success 'update-index implicitly starts daemon' '
	test_when_finished redundant_stop_daemon &&

	test_must_fail git fsmonitor--daemon status &&

	GIT_TRACE2_EVENT="$PWD/.git/trace_implicit_1" \
		git update-index --fsmonitor &&

	git fsmonitor--daemon status &&
	test_might_fail git fsmonitor--daemon stop &&

	# Confirm that the trace2 log contains a record of the
	# daemon starting.
	test_subcommand git fsmonitor--daemon start <.git/trace_implicit_1
'

test_expect_success 'status implicitly starts daemon' '
	test_when_finished redundant_stop_daemon &&

	test_must_fail git fsmonitor--daemon status &&

	GIT_TRACE2_EVENT="$PWD/.git/trace_implicit_2" \
		git status >actual &&

	git fsmonitor--daemon status &&
	test_might_fail git fsmonitor--daemon stop &&

	# Confirm that the trace2 log contains a record of the
	# daemon starting.
	test_subcommand git fsmonitor--daemon start <.git/trace_implicit_2
'

edit_files () {
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	>dir1/untracked
}

delete_files () {
	rm -f delete &&
	rm -f dir1/delete &&
	rm -f dir2/delete
}

create_files () {
	echo 1 >new &&
	echo 2 >dir1/new &&
	echo 3 >dir2/new
}

rename_files () {
	mv rename renamed &&
	mv dir1/rename dir1/renamed &&
	mv dir2/rename dir2/renamed
}

file_to_directory () {
	rm -f delete &&
	mkdir delete &&
	echo 1 >delete/new
}

directory_to_file () {
	rm -rf dir1 &&
	echo 1 >dir1
}

move_directory_contents_deeper() {
	mkdir T1/_new_ &&
	mv T1/[A-Z]* T1/_new_
}

move_directory_up() {
	mv T1/T2/T3 T1
}

move_directory() {
	mv T1/T2/T3 T1/T2/NewT3
}

# The next few test cases confirm that our fsmonitor daemon sees each type
# of OS filesystem notification that we care about.  At this layer we just
# ensure we are getting the OS notifications and do not try to confirm what
# is reported by `git status`.
#
# We use retry_grep to handle races between the daemon writing events
# to the trace file and our check.
#
# We `reset` and `clean` at the bottom of each test (and before stopping the
# daemon) because these commands might implicitly restart the daemon.

clean_up_repo_and_stop_daemon () {
	git reset --hard HEAD &&
	git clean -fd &&
	test_might_fail git fsmonitor--daemon stop &&
	rm -f .git/trace
}

# Retry a grep up to RETRY_TIMEOUT times until it succeeds.
#
RETRY_TIMEOUT=5

retry_grep () {
	nr_tries_left=$RETRY_TIMEOUT
	until grep "$1" "$2" 2>/dev/null
	do
		if test $nr_tries_left -eq 0
		then
			grep "$1" "$2"
			return
		fi
		nr_tries_left=$(($nr_tries_left - 1))
		sleep 1
	done
}

test_expect_success 'edit some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	edit_files &&

	retry_grep "^event: dir1/modified$" .git/trace &&
	retry_grep "^event: dir2/modified$"  .git/trace &&
	retry_grep "^event: modified$"       .git/trace &&
	retry_grep "^event: dir1/untracked$" .git/trace
'

test_expect_success 'create some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	create_files &&

	retry_grep "^event: dir1/new$" .git/trace &&
	retry_grep "^event: dir2/new$" .git/trace &&
	retry_grep "^event: new$"      .git/trace
'

test_expect_success 'delete some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	delete_files &&

	retry_grep "^event: dir1/delete$" .git/trace &&
	retry_grep "^event: dir2/delete$" .git/trace &&
	retry_grep "^event: delete$"      .git/trace
'

test_expect_success 'rename some files' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	rename_files &&

	retry_grep "^event: dir1/rename$" .git/trace &&
	retry_grep "^event: dir2/rename$"  .git/trace &&
	retry_grep "^event: rename$"       .git/trace &&
	retry_grep "^event: dir1/renamed$" .git/trace &&
	retry_grep "^event: dir2/renamed$" .git/trace &&
	retry_grep "^event: renamed$"      .git/trace
'

test_expect_success 'rename directory' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	mv dirtorename dirrenamed &&

	retry_grep "^event: dirtorename/*$" .git/trace &&
	retry_grep "^event: dirrenamed/*$"  .git/trace
'

test_expect_success 'file changes to directory' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	file_to_directory &&

	retry_grep "^event: delete$" .git/trace &&
	retry_grep "^event: delete/new$" .git/trace
'

test_expect_success 'directory changes to a file' '
	test_when_finished clean_up_repo_and_stop_daemon &&

	start_daemon --tf "$PWD/.git/trace" &&

	directory_to_file &&

	retry_grep "^event: dir1$" .git/trace
'

test_expect_success 'rapid nested directory creation' '
	test_when_finished "git fsmonitor--daemon stop; rm -rf rapid" &&

	start_daemon --tf "$PWD/.git/trace" &&

	# Rapidly create nested directories to exercise race conditions
	# where directory watches may be added concurrently during
	# event processing and recursive scanning.
	for i in $(test_seq 1 20)
	do
		mkdir -p "rapid/nested/dir$i/subdir/deep" || return 1
	done &&

	# Give the daemon time to process all events
	sleep 1 &&

	test-tool fsmonitor-client query --token 0 &&

	# Verify daemon is still running (did not crash)
	git fsmonitor--daemon status
'

# The next few test cases exercise the token-resync code.  When filesystem
# drops events (because of filesystem velocity or because the daemon isn't
# polling fast enough), we need to discard the cached data (relative to the
# current token) and start collecting events under a new token.
#
# the 'test-tool fsmonitor-client flush' command can be used to send a
# "flush" message to a running daemon and ask it to do a flush/resync.

test_expect_success 'flush cached data' '
	test_when_finished "stop_daemon_delete_repo test_flush" &&

	git init test_flush &&

	start_daemon -C test_flush --tf "$PWD/.git/trace_daemon" --tk true &&

	# The daemon should have an initial token with no events in _0 and
	# then a few (probably platform-specific number of) events in _1.
	# These should both have the same <token_id>.

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000001:0" >actual_0 &&
	nul_to_q <actual_0 >actual_q0 &&

	test-tool -C test_flush fsmonitor-client query \
		--token "builtin:test_00000001:18446744073709551615" >actual_future &&
	nul_to_q <actual_future >actual_future_q &&
	test_grep "^builtin:test_00000001:[0-9][0-9]*Q/Q$" actual_future_q &&

	>test_flush/file_1 &&
	retry_grep "^event: file_1$" "$PWD/.git/trace_daemon" &&
	>test_flush/file_2 &&
	retry_grep "^event: file_2$" "$PWD/.git/trace_daemon" &&

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000001:0" >actual_1 &&
	nul_to_q <actual_1 >actual_q1 &&

	test_grep "file_1" actual_q1 &&
	test_grep "file_2" actual_q1 &&

	# Force a flush.  This will change the <token_id>, reset the <seq_nr>, and
	# flush the file data.  Then create some events and ensure that the file
	# again appears in the cache.  It should have the new <token_id>.

	test-tool -C test_flush fsmonitor-client flush >flush_0 &&
	nul_to_q <flush_0 >flush_q0 &&
	test_grep "^builtin:test_00000002:0Q/Q$" flush_q0 &&

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000002:0" >actual_2 &&
	nul_to_q <actual_2 >actual_q2 &&

	test_grep "^builtin:test_00000002:0Q$" actual_q2 &&

	>test_flush/file_3 &&

	test-tool -C test_flush fsmonitor-client query --token "builtin:test_00000002:0" >actual_3 &&
	nul_to_q <actual_3 >actual_q3 &&

	test_grep "file_3" actual_q3
'

# The next few test cases create repos where the .git directory is NOT
# inside the one of the working directory.  That is, where .git is a file
# that points to a directory elsewhere.  This happens for submodules and
# non-primary worktrees.

test_expect_success 'setup worktree base' '
	git init wt-base &&
	echo 1 >wt-base/file1 &&
	git -C wt-base add file1 &&
	git -C wt-base commit -m "c1"
'

test_expect_success 'worktree with .git file' '
	git -C wt-base worktree add ../wt-secondary &&

	start_daemon -C wt-secondary \
		--tf "$PWD/trace_wt_secondary" \
		--t2 "$PWD/trace2_wt_secondary" &&

	git -C wt-secondary fsmonitor--daemon stop &&
	test_must_fail git -C wt-secondary fsmonitor--daemon status
'

test_expect_success MACOS 'worktrees share one daemon' '
	test_when_finished "rm -rf shared-base shared-secondary" &&
	test_when_finished \
		"{ git -C shared-base fsmonitor--daemon stop 2>/dev/null || :; }" &&

	git init shared-base &&
	test_commit -C shared-base initial &&
	start_daemon -C shared-base &&
	git -C shared-base worktree add ../shared-secondary &&
	test_must_fail git -C shared-secondary fsmonitor--daemon status &&

	test-tool -C shared-base fsmonitor-client query --token 0 >base.0 &&
	test-tool -C shared-secondary fsmonitor-client query --token 0 >secondary.0 &&
	git -C shared-secondary fsmonitor--daemon status &&
	nul_to_q <base.0 >base.q0 &&
	nul_to_q <secondary.0 >secondary.q0 &&
	base_token=$(sed "s/Q.*//" base.q0) &&
	secondary_token=$(sed "s/Q.*//" secondary.q0) &&
	test "$base_token" != "$secondary_token" &&
	test "$(echo "$base_token" | cut -d. -f2)" = \
		"$(echo "$secondary_token" | cut -d. -f2)" &&

	>shared-base/base-only &&
	>shared-secondary/secondary-only &&
	test-tool -C shared-base fsmonitor-client query \
		--token "$base_token" >base.1 &&
	test-tool -C shared-secondary fsmonitor-client query \
		--token "$secondary_token" >secondary.1 &&
	nul_to_q <base.1 >base.q1 &&
	nul_to_q <secondary.1 >secondary.q1 &&
	test_grep base-only base.q1 &&
	test_grep ! secondary-only base.q1 &&
	test_grep secondary-only secondary.q1 &&
	test_grep ! base-only secondary.q1 &&

	git -C shared-secondary fsmonitor--daemon stop &&
	test_must_fail git -C shared-base fsmonitor--daemon status &&
	test_must_fail git -C shared-secondary fsmonitor--daemon status &&

	start_daemon -C shared-secondary &&
	test-tool -C shared-base fsmonitor-client query --token 0 >/dev/null &&
	git -C shared-base fsmonitor--daemon status
'

# NEEDSWORK: Repeat one of the "edit" tests on wt-secondary and
# confirm that we get the same events and behavior -- that is, that
# fsmonitor--daemon correctly watches BOTH the working directory and
# the external GITDIR directory and behaves the same as when ".git"
# is a directory inside the working directory.

test_expect_success 'cleanup worktrees' '
	stop_daemon_delete_repo wt-secondary &&
	stop_daemon_delete_repo wt-base
'

# The next few tests perform arbitrary/contrived file operations and
# confirm that status is correct.  That is, that the data (or lack of
# data) from fsmonitor doesn't cause incorrect results.  And doesn't
# cause incorrect results when the untracked-cache is enabled.

test_lazy_prereq UNTRACKED_CACHE '
	git update-index --test-untracked-cache
'

test_expect_success 'Matrix: setup for untracked-cache,fsmonitor matrix' '
	test_unconfig core.fsmonitor &&
	git update-index --no-fsmonitor &&
	test_might_fail git fsmonitor--daemon stop
'

matrix_clean_up_repo () {
	git reset --hard HEAD &&
	git clean -fd
}

matrix_try () {
	uc=$1 &&
	fsm=$2 &&
	fn=$3 &&

	if test $uc = true && test $fsm = false
	then
		# The untracked-cache is buggy when FSMonitor is
		# DISABLED, so skip the tests for this matrix
		# combination.
		#
		# We've observed random, occasional test failures on
		# Windows and MacOS when the UC is turned on and FSM
		# is turned off.  These are rare, but they do happen
		# indicating that it is probably a race condition within
		# the untracked cache itself.
		#
		# It usually happens when a test does F/D trickery and
		# then the NEXT test fails because of extra status
		# output from stale UC data from the previous test.
		#
		# Since FSMonitor is not involved in the error, skip
		# the tests for this matrix combination.
		#
		return 0
	fi &&

	test_expect_success "Matrix[uc:$uc][fsm:$fsm] $fn" '
		matrix_clean_up_repo &&
		$fn &&
		if test $uc = false && test $fsm = false
		then
			git status --porcelain=v1 >.git/expect.$fn
		else
			git status --porcelain=v1 >.git/actual.$fn &&
			test_cmp .git/expect.$fn .git/actual.$fn
		fi
	'
}

uc_values="false"
test_have_prereq UNTRACKED_CACHE && uc_values="false true"
for uc_val in $uc_values
do
	if test $uc_val = false
	then
		test_expect_success "Matrix[uc:$uc_val] disable untracked cache" '
			git config core.untrackedcache false &&
			git update-index --no-untracked-cache
		'
	else
		test_expect_success "Matrix[uc:$uc_val] enable untracked cache" '
			git config core.untrackedcache true &&
			git update-index --untracked-cache
		'
	fi

	fsm_values="false true"
	for fsm_val in $fsm_values
	do
		if test $fsm_val = false
		then
			test_expect_success "Matrix[uc:$uc_val][fsm:$fsm_val] disable fsmonitor" '
				test_unconfig core.fsmonitor &&
				git update-index --no-fsmonitor &&
				test_might_fail git fsmonitor--daemon stop
			'
		else
			test_expect_success "Matrix[uc:$uc_val][fsm:$fsm_val] enable fsmonitor" '
				git config core.fsmonitor true &&
				git fsmonitor--daemon start &&
				git update-index --fsmonitor
			'
		fi

		matrix_try $uc_val $fsm_val edit_files
		matrix_try $uc_val $fsm_val delete_files
		matrix_try $uc_val $fsm_val create_files
		matrix_try $uc_val $fsm_val rename_files
		matrix_try $uc_val $fsm_val file_to_directory
		matrix_try $uc_val $fsm_val directory_to_file

		matrix_try $uc_val $fsm_val move_directory_contents_deeper
		matrix_try $uc_val $fsm_val move_directory_up
		matrix_try $uc_val $fsm_val move_directory

		if test $fsm_val = true
		then
			test_expect_success "Matrix[uc:$uc_val][fsm:$fsm_val] disable fsmonitor at end" '
				test_unconfig core.fsmonitor &&
				git update-index --no-fsmonitor &&
				test_might_fail git fsmonitor--daemon stop
			'
		fi
	done
done

# Test Unicode UTF-8 characters in the pathname of the working
# directory root.  Use of "*A()" routines rather than "*W()" routines
# on Windows can sometimes lead to odd failures.
#
u1=$(printf "u_c3_a6__\xC3\xA6")
u2=$(printf "u_e2_99_ab__\xE2\x99\xAB")
u_values="$u1 $u2"
for u in $u_values
do
	test_expect_success "unicode in repo root path: $u" '
		test_when_finished "stop_daemon_delete_repo $u" &&

		git init "$u" &&
		echo 1 >"$u"/file1 &&
		git -C "$u" add file1 &&
		git -C "$u" config core.fsmonitor true &&

		start_daemon -C "$u" &&
		git -C "$u" status >actual &&
		test_grep "new file:   file1" actual
	'
done

# Test fsmonitor interaction with submodules.
#
# If we start the daemon in the super, it will see FS events for
# everything in the working directory cone and this includes any
# files/directories contained *within* the submodules.
#
# A `git status` at top level will get events for items within the
# submodule and ignore them, since they aren't named in the index
# of the super repo.  This makes the fsmonitor response a little
# noisy, but it doesn't alter the correctness of the state of the
# super-proper.
#
# When we have submodules, `git status` normally does a recursive
# status on each of the submodules and adds a summary row for any
# dirty submodules.  (See the "S..." bits in porcelain V2 output.)
#
# It is therefore important that the top level status not be tricked
# by the FSMonitor response to skip those recursive calls.  That is,
# even if FSMonitor says that the mtime of the submodule directory
# hasn't changed and it could be implicitly marked valid, we must
# not take that shortcut.  We need to force the recursion into the
# submodule so that we get a summary of the status *within* the
# submodule.

create_super () {
	super="$1" &&

	git init "$super" &&
	echo x >"$super/file_1" &&
	echo y >"$super/file_2" &&
	echo z >"$super/file_3" &&
	mkdir "$super/dir_1" &&
	echo a >"$super/dir_1/file_11" &&
	echo b >"$super/dir_1/file_12" &&
	mkdir "$super/dir_1/dir_2" &&
	echo a >"$super/dir_1/dir_2/file_21" &&
	echo b >"$super/dir_1/dir_2/file_22" &&
	git -C "$super" add . &&
	git -C "$super" commit -m "initial $super commit"
}

create_sub () {
	sub="$1" &&

	git init "$sub" &&
	echo x >"$sub/file_x" &&
	echo y >"$sub/file_y" &&
	echo z >"$sub/file_z" &&
	mkdir "$sub/dir_x" &&
	echo a >"$sub/dir_x/file_a" &&
	echo b >"$sub/dir_x/file_b" &&
	mkdir "$sub/dir_x/dir_y" &&
	echo a >"$sub/dir_x/dir_y/file_a" &&
	echo b >"$sub/dir_x/dir_y/file_b" &&
	git -C "$sub" add . &&
	git -C "$sub" commit -m "initial $sub commit"
}

my_match_and_clean () {
	git -C super --no-optional-locks status --porcelain=v2 >actual.with &&
	git -C super --no-optional-locks -c core.fsmonitor=false \
		status --porcelain=v2 >actual.without &&
	test_cmp actual.with actual.without &&

	git -C super --no-optional-locks diff-index --name-status HEAD >actual.with &&
	git -C super --no-optional-locks -c core.fsmonitor=false \
		diff-index --name-status HEAD >actual.without &&
	test_cmp actual.with actual.without &&

	git -C super/dir_1/dir_2/sub reset --hard &&
	git -C super/dir_1/dir_2/sub clean -d -f
}

test_expect_success 'submodule setup' '
	git config --global protocol.file.allow always
'

test_expect_success 'submodule always visited' '
	test_when_finished "git -C super fsmonitor--daemon stop; \
			    rm -rf super; \
			    rm -rf sub" &&

	create_super super &&
	create_sub sub &&

	git -C super submodule add ../sub ./dir_1/dir_2/sub &&
	git -C super commit -m "add sub" &&

	start_daemon -C super &&
	git -C super config core.fsmonitor true &&
	git -C super update-index --fsmonitor &&
	git -C super status &&

	# Now run pairs of commands w/ and w/o FSMonitor while we make
	# some dirt in the submodule and confirm matching output.

	# Completely clean status.
	my_match_and_clean &&

	# .M S..U
	echo z >super/dir_1/dir_2/sub/dir_x/dir_y/foobar_u &&
	my_match_and_clean &&

	# .M S.M.
	echo z >super/dir_1/dir_2/sub/dir_x/dir_y/foobar_m &&
	git -C super/dir_1/dir_2/sub add . &&
	my_match_and_clean &&

	# .M S.M.
	echo z >>super/dir_1/dir_2/sub/dir_x/dir_y/file_a &&
	git -C super/dir_1/dir_2/sub add . &&
	my_match_and_clean &&

	# .M SC..
	echo z >>super/dir_1/dir_2/sub/dir_x/dir_y/file_a &&
	git -C super/dir_1/dir_2/sub add . &&
	git -C super/dir_1/dir_2/sub commit -m "SC.." &&
	my_match_and_clean
'

# If a submodule has a `sub/.git/` directory (rather than a file
# pointing to the super's `.git/modules/sub`) and `core.fsmonitor`
# turned on in the submodule and the daemon is not yet started in
# the submodule, and someone does a `git submodule absorbgitdirs`
# in the super, Git will recursively invoke `git submodule--helper`
# to do the work and this may try to read the index.  This will
# try to start the daemon in the submodule.

test_expect_success "submodule absorbgitdirs implicitly starts daemon" '
	test_when_finished "rm -rf super; \
			    rm -rf sub;   \
			    rm super-sub.trace" &&

	create_super super &&
	create_sub sub &&

	# Copy rather than submodule add so that we get a .git dir.
	cp -R ./sub ./super/dir_1/dir_2/sub &&

	git -C super/dir_1/dir_2/sub config core.fsmonitor true &&

	git -C super submodule add ../sub ./dir_1/dir_2/sub &&
	git -C super commit -m "add sub" &&

	test_path_is_dir super/dir_1/dir_2/sub/.git &&

	cwd="$(cd super && pwd)" &&
	cat >expect <<-EOF &&
	Migrating git directory of '\''dir_1/dir_2/sub'\'' from
	'\''$cwd/dir_1/dir_2/sub/.git'\'' to
	'\''$cwd/.git/modules/dir_1/dir_2/sub'\''
	EOF
	GIT_TRACE2_EVENT="$PWD/super-sub.trace" \
		git -C super submodule absorbgitdirs >out 2>actual &&
	test_cmp expect actual &&
	test_must_be_empty out &&

	# Confirm that the trace2 log contains a record of the
	# daemon starting.
	test_subcommand git fsmonitor--daemon start <super-sub.trace
'

start_git_in_background () {
	git "$@" &
	git_pid=$!
	git_pgid=$(ps -o pgid= -p $git_pid 2>/dev/null ||
		awk '{print $5}' /proc/$git_pid/stat 2>/dev/null) &&
	git_pgid="${git_pgid## }" &&
	git_pgid="${git_pgid%% }"
	nr_tries_left=10
	while true
	do
		if test $nr_tries_left -eq 0
		then
			kill -- -$git_pgid
			exit 1
		fi
		sleep 1
		nr_tries_left=$(($nr_tries_left - 1))
	done >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- &
	watchdog_pid=$!
	wait $git_pid
}

stop_git () {
	test -n "$git_pgid" || return 0
	while kill -0 -- -$git_pgid 2>/dev/null
	do
		kill -- -$git_pgid 2>/dev/null
		sleep 1
	done
}

stop_watchdog () {
	while kill -0 $watchdog_pid
	do
		kill $watchdog_pid
		sleep 1
	done
}

test_expect_success !MINGW "submodule implicitly starts daemon by pull" '
	test_atexit "stop_watchdog" &&
	test_when_finished "set +m; stop_git; rm -rf cloned super sub" &&

	create_super super &&
	create_sub sub &&

	git -C super submodule add ../sub ./dir_1/dir_2/sub &&
	git -C super commit -m "add sub" &&
	git clone --recurse-submodules super cloned &&

	git -C cloned/dir_1/dir_2/sub config core.fsmonitor true &&
	set -m &&
	start_git_in_background -C cloned pull --recurse-submodules
'

# On a case-insensitive file system, confirm that the daemon
# notices when the .git directory is moved/renamed/deleted
# regardless of how it is spelled in the FS event.
# That is, does the FS event receive the spelling of the
# operation or does it receive the spelling preserved with
# the file/directory.
#
test_expect_success CASE_INSENSITIVE_FS 'case insensitive+preserving' '
	test_when_finished "stop_daemon_delete_repo test_insensitive" &&

	git init test_insensitive &&

	start_daemon -C test_insensitive --tf "$PWD/insensitive.trace" &&

	mkdir -p test_insensitive/abc/def &&
	echo xyz >test_insensitive/ABC/DEF/xyz &&

	test_path_is_dir test_insensitive/.git &&
	test_path_is_dir test_insensitive/.GIT &&

	# Rename .git using an alternate spelling to verify that
	# the daemon detects it and automatically shuts down.
	mv test_insensitive/.GIT test_insensitive/.FOO &&

	# See [1] above.
	mv test_insensitive/.FOO test_insensitive/.git &&

	verify_implicit_shutdown test_insensitive &&

	# Verify that events were reported using on-disk spellings of the
	# directories and files that we touched.  We may or may not get a
	# trailing slash on modified directories.
	#
	test_grep -E "^event: abc/?$"       ./insensitive.trace &&
	test_grep -E "^event: abc/def/?$"   ./insensitive.trace &&
	test_grep -E "^event: abc/def/xyz$" ./insensitive.trace
'

# The variable "unicode_debug" is defined in the following library
# script to dump information about how the (OS, FS) handles Unicode
# composition.  Uncomment the following line if you want to enable it.
#
# unicode_debug=true

. "$TEST_DIRECTORY/lib-unicode-nfc-nfd.sh"

# See if the OS or filesystem does NFC/NFD aliasing/munging.
#
# The daemon should err on the side of caution and send BOTH the
# NFC and NFD forms.  It does not know the original spelling of
# the pathname (how the user thinks it should be spelled), so
# emit both and let the client decide (when necessary).  This is
# similar to "core.precomposeUnicode".
#
test_expect_success !UNICODE_COMPOSITION_SENSITIVE 'Unicode nfc/nfd' '
	test_when_finished "stop_daemon_delete_repo test_unicode" &&

	git init test_unicode &&

	start_daemon -C test_unicode --tf "$PWD/unicode.trace" &&

	# Create a directory using an NFC spelling.
	#
	mkdir test_unicode/nfc &&
	mkdir test_unicode/nfc/c_${utf8_nfc} &&

	# Create a directory using an NFD spelling.
	#
	mkdir test_unicode/nfd &&
	mkdir test_unicode/nfd/d_${utf8_nfd} &&

	test-tool -C test_unicode fsmonitor-client query --token 0 &&

	if test_have_prereq UNICODE_NFC_PRESERVED
	then
		# We should have seen NFC event from OS.
		# We should not have synthesized an NFD event.
		test_grep -E    "^event: nfc/c_${utf8_nfc}/?$" ./unicode.trace &&
		test_grep -E -v "^event: nfc/c_${utf8_nfd}/?$" ./unicode.trace
	else
		# We should have seen NFD event from OS.
		# We should have synthesized an NFC event.
		test_grep -E "^event: nfc/c_${utf8_nfd}/?$" ./unicode.trace &&
		test_grep -E "^event: nfc/c_${utf8_nfc}/?$" ./unicode.trace
	fi &&

	# We assume UNICODE_NFD_PRESERVED.
	# We should have seen explicit NFD from OS.
	# We should have synthesized an NFC event.
	test_grep -E "^event: nfd/d_${utf8_nfd}/?$" ./unicode.trace &&
	test_grep -E "^event: nfd/d_${utf8_nfc}/?$" ./unicode.trace
'

test_expect_success 'split-index and FSMonitor work well together' '
	git init split-index &&
	test_when_finished "git -C \"$PWD/split-index\" \
		fsmonitor--daemon stop" &&
	(
		cd split-index &&
		git config core.splitIndex true &&
		# force split-index in most cases
		git config splitIndex.maxPercentChange 99 &&
		git config core.fsmonitor true &&

		# Create the following commit topology:
		#
		# *   merge three
		# |\
		# | * three
		# * | merge two
		# |\|
		# | * two
		# * | one
		# |/
		# * 5a5efd7 initial

		test_commit initial &&
		test_commit two &&
		test_commit three &&
		git reset --hard initial &&
		test_commit one &&
		test_tick &&
		git merge two &&
		test_tick &&
		git merge three &&

		git rebase --force-rebase -r one
	)
'

# The FSMonitor daemon reports the OBSERVED pathname of modified files
# and thus contains the OBSERVED spelling on case-insensitive file
# systems.  The daemon does not (and should not) load the .git/index
# file and therefore does not know the expected case-spelling.  Since
# it is possible for the user to create files/subdirectories with the
# incorrect case, a modified file event for a tracked will not have
# the EXPECTED case. This can cause `index_name_pos()` to incorrectly
# report that the file is untracked. This causes the client to fail to
# mark the file as possibly dirty (keeping the CE_FSMONITOR_VALID bit
# set) so that `git status` will avoid inspecting it and thus not
# present in the status output.
#
# The setup is a little contrived.
#
test_expect_success CASE_INSENSITIVE_FS 'fsmonitor subdir case wrong on disk' '
	test_when_finished "stop_daemon_delete_repo subdir_case_wrong" &&

	git init subdir_case_wrong &&
	(
		cd subdir_case_wrong &&
		echo x >AAA &&
		echo x >BBB &&

		mkdir dir1 &&
		echo x >dir1/file1 &&
		mkdir dir1/dir2 &&
		echo x >dir1/dir2/file2 &&
		mkdir dir1/dir2/dir3 &&
		echo x >dir1/dir2/dir3/file3 &&

		echo x >yyy &&
		echo x >zzz &&
		git add . &&
		git commit -m "data" &&

		# This will cause "dir1/" and everything under it
		# to be deleted.
		git sparse-checkout set --cone --sparse-index &&

		# Create dir2 with the wrong case and then let Git
		# repopulate dir3 -- it will not correct the spelling
		# of dir2.
		mkdir dir1 &&
		mkdir dir1/DIR2 &&
		git sparse-checkout add dir1/dir2/dir3
	) &&

	start_daemon -C subdir_case_wrong --tf "$PWD/subdir_case_wrong.trace" &&

	# Enable FSMonitor in the client. Run enough commands for
	# the .git/index to sync up with the daemon with everything
	# marked clean.
	git -C subdir_case_wrong config core.fsmonitor true &&
	git -C subdir_case_wrong update-index --fsmonitor &&
	git -C subdir_case_wrong status &&

	# Make some files dirty so that FSMonitor gets FSEvents for
	# each of them.
	echo xx >>subdir_case_wrong/AAA &&
	echo xx >>subdir_case_wrong/dir1/DIR2/dir3/file3 &&
	echo xx >>subdir_case_wrong/zzz &&

	GIT_TRACE_FSMONITOR="$PWD/subdir_case_wrong.log" \
		git -C subdir_case_wrong --no-optional-locks status --short \
			>"$PWD/subdir_case_wrong.out" &&

	# "git status" should have gotten file events for each of
	# the 3 files.
	#
	# "dir2" should be in the observed case on disk.
	grep "fsmonitor_refresh_callback" \
		<"$PWD/subdir_case_wrong.log" \
		>"$PWD/subdir_case_wrong.log1" &&

	test_grep -q "AAA.*pos 0" "$PWD/subdir_case_wrong.log1" &&
	test_grep -q "zzz.*pos 6" "$PWD/subdir_case_wrong.log1" &&

	test_grep -q "dir1/DIR2/dir3/file3.*pos -3" "$PWD/subdir_case_wrong.log1" &&

	# Verify that we get a mapping event to correct the case.
	test_grep -q "MAP:.*dir1/DIR2/dir3/file3.*dir1/dir2/dir3/file3" \
		"$PWD/subdir_case_wrong.log1" &&

	# The refresh-callbacks should have caused "git status" to clear
	# the CE_FSMONITOR_VALID bit on each of those files and caused
	# the worktree scan to visit them and mark them as modified.
	test_grep -q " M AAA" "$PWD/subdir_case_wrong.out" &&
	test_grep -q " M zzz" "$PWD/subdir_case_wrong.out" &&
	test_grep -q " M dir1/dir2/dir3/file3" "$PWD/subdir_case_wrong.out"
'

test_expect_success CASE_INSENSITIVE_FS 'fsmonitor file case wrong on disk' '
	test_when_finished "stop_daemon_delete_repo file_case_wrong" &&

	git init file_case_wrong &&
	(
		cd file_case_wrong &&
		echo x >AAA &&
		echo x >BBB &&

		mkdir dir1 &&
		mkdir dir1/dir2 &&
		mkdir dir1/dir2/dir3 &&
		echo x >dir1/dir2/dir3/FILE-3-B &&
		echo x >dir1/dir2/dir3/XXXX-3-X &&
		echo x >dir1/dir2/dir3/file-3-a &&
		echo x >dir1/dir2/dir3/yyyy-3-y &&
		mkdir dir1/dir2/dir4 &&
		echo x >dir1/dir2/dir4/FILE-4-A &&
		echo x >dir1/dir2/dir4/XXXX-4-X &&
		echo x >dir1/dir2/dir4/file-4-b &&
		echo x >dir1/dir2/dir4/yyyy-4-y &&

		echo x >yyy &&
		echo x >zzz &&
		git add . &&
		git commit -m "data"
	) &&

	start_daemon -C file_case_wrong --tf "$PWD/file_case_wrong.trace" &&

	# Enable FSMonitor in the client. Run enough commands for
	# the .git/index to sync up with the daemon with everything
	# marked clean.
	git -C file_case_wrong config core.fsmonitor true &&
	git -C file_case_wrong update-index --fsmonitor &&
	git -C file_case_wrong status &&

	# Make some files dirty so that FSMonitor gets FSEvents for
	# each of them.
	echo xx >>file_case_wrong/AAA &&
	echo xx >>file_case_wrong/zzz &&

	# Rename some files so that FSMonitor sees a create and delete
	# FSEvent for each.  (A simple "mv foo FOO" is not portable
	# between macOS and Windows. It works on both platforms, but makes
	# the test messy, since (1) one platform updates "ctime" on the
	# moved file and one does not and (2) it causes a directory event
	# on one platform and not on the other which causes additional
	# scanning during "git status" which causes a "H" vs "h" discrepancy
	# in "git ls-files -f".)  So old-school it and move it out of the
	# way and copy it to the case-incorrect name so that we get fresh
	# "ctime" and "mtime" values.

	mv file_case_wrong/dir1/dir2/dir3/file-3-a file_case_wrong/dir1/dir2/dir3/ORIG &&
	cp file_case_wrong/dir1/dir2/dir3/ORIG     file_case_wrong/dir1/dir2/dir3/FILE-3-A &&
	rm file_case_wrong/dir1/dir2/dir3/ORIG &&
	mv file_case_wrong/dir1/dir2/dir4/FILE-4-A file_case_wrong/dir1/dir2/dir4/ORIG &&
	cp file_case_wrong/dir1/dir2/dir4/ORIG     file_case_wrong/dir1/dir2/dir4/file-4-a &&
	rm file_case_wrong/dir1/dir2/dir4/ORIG &&

	# Run status enough times to fully sync.
	#
	# The first instance should get the create and delete FSEvents
	# for each pair.  Status should update the index with a new FSM
	# token (so the next invocation will not see data for these
	# events).

	GIT_TRACE_FSMONITOR="$PWD/file_case_wrong-try1.log" \
		git -C file_case_wrong status --short \
			>"$PWD/file_case_wrong-try1.out" &&
	test_grep -q "fsmonitor_refresh_callback.*FILE-3-A.*pos -3" "$PWD/file_case_wrong-try1.log" &&
	test_grep -q "fsmonitor_refresh_callback.*file-3-a.*pos 4"  "$PWD/file_case_wrong-try1.log" &&
	test_grep -q "fsmonitor_refresh_callback.*FILE-4-A.*pos 6"  "$PWD/file_case_wrong-try1.log" &&
	test_grep -q "fsmonitor_refresh_callback.*file-4-a.*pos -9" "$PWD/file_case_wrong-try1.log" &&

	# FSM refresh will have invalidated the FSM bit and cause a regular
	# (real) scan of these tracked files, so they should have "H" status.
	# (We will not see a "h" status until the next refresh (on the next
	# command).)

	git -C file_case_wrong ls-files -f >"$PWD/file_case_wrong-lsf1.out" &&
	test_grep -q "H dir1/dir2/dir3/file-3-a" "$PWD/file_case_wrong-lsf1.out" &&
	test_grep -q "H dir1/dir2/dir4/FILE-4-A" "$PWD/file_case_wrong-lsf1.out" &&


	# Try the status again. We assume that the above status command
	# advanced the token so that the next one will not see those events.

	GIT_TRACE_FSMONITOR="$PWD/file_case_wrong-try2.log" \
		git -C file_case_wrong status --short \
			>"$PWD/file_case_wrong-try2.out" &&
	test_grep ! -q "fsmonitor_refresh_callback.*FILE-3-A.*pos" "$PWD/file_case_wrong-try2.log" &&
	test_grep ! -q "fsmonitor_refresh_callback.*file-3-a.*pos" "$PWD/file_case_wrong-try2.log" &&
	test_grep ! -q "fsmonitor_refresh_callback.*FILE-4-A.*pos" "$PWD/file_case_wrong-try2.log" &&
	test_grep ! -q "fsmonitor_refresh_callback.*file-4-a.*pos" "$PWD/file_case_wrong-try2.log" &&

	# FSM refresh saw nothing, so it will mark all files as valid,
	# so they should now have "h" status.

	git -C file_case_wrong ls-files -f >"$PWD/file_case_wrong-lsf2.out" &&
	test_grep -q "h dir1/dir2/dir3/file-3-a" "$PWD/file_case_wrong-lsf2.out" &&
	test_grep -q "h dir1/dir2/dir4/FILE-4-A" "$PWD/file_case_wrong-lsf2.out" &&


	# We now have files with clean content, but with case-incorrect
	# file names.  Modify them to see if status properly reports
	# them.

	echo xx >>file_case_wrong/dir1/dir2/dir3/FILE-3-A &&
	echo xx >>file_case_wrong/dir1/dir2/dir4/file-4-a &&

	GIT_TRACE2_EVENT="$PWD/file_case_wrong-try3.trace2" \
	GIT_TRACE_FSMONITOR="$PWD/file_case_wrong-try3.log" \
		git -C file_case_wrong --no-optional-locks status --short \
			--untracked-files=no \
			>"$PWD/file_case_wrong-try3.out" &&
	test_trace2_data fsmonitor icase_index/resolved 2 \
		<"$PWD/file_case_wrong-try3.trace2" &&
	test_trace2_data fsmonitor icase_index/fallbacks 0 \
		<"$PWD/file_case_wrong-try3.trace2" &&

	# Verify that we get a mapping event to correct the case.
	test_grep -q "fsmonitor_refresh_callback MAP:.*dir1/dir2/dir3/FILE-3-A.*dir1/dir2/dir3/file-3-a" \
		"$PWD/file_case_wrong-try3.log" &&
	test_grep -q "fsmonitor_refresh_callback MAP:.*dir1/dir2/dir4/file-4-a.*dir1/dir2/dir4/FILE-4-A" \
		"$PWD/file_case_wrong-try3.log" &&

	# FSEvents are in observed case.
	test_grep -q "fsmonitor_refresh_callback.*FILE-3-A.*pos -3" "$PWD/file_case_wrong-try3.log" &&
	test_grep -q "fsmonitor_refresh_callback.*file-4-a.*pos -9" "$PWD/file_case_wrong-try3.log" &&

	# The refresh-callbacks should have caused "git status" to clear
	# the CE_FSMONITOR_VALID bit on each of those files and caused
	# the worktree scan to visit them and mark them as modified.
	test_grep -q " M dir1/dir2/dir3/file-3-a" "$PWD/file_case_wrong-try3.out" &&
	test_grep -q " M dir1/dir2/dir4/FILE-4-A" "$PWD/file_case_wrong-try3.out"
'

test_expect_success 'lock-free status reuses current untracked snapshot' '
	test_when_finished "stop_daemon_delete_repo test_untracked_snapshot" &&
	git init test_untracked_snapshot &&
	(
		cd test_untracked_snapshot &&
		test_commit base tracked &&
		mkdir -p steady/deep &&
		test_commit steady steady/deep/tracked &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		: >../untracked-snapshot.excludes &&
		git config core.excludesFile \
			"$PWD/../untracked-snapshot.excludes"
	) &&
	start_daemon -C test_untracked_snapshot \
		--t2 "$PWD/untracked-snapshot-daemon.trace" &&
	(
		cd test_untracked_snapshot &&
		git update-index --untracked-cache &&
		git hash-object .git/index >../untracked-snapshot-cold-index.before &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-cold.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-cold.out &&
		test_must_be_empty ../untracked-snapshot-cold.out &&
		test_trace2_data status index/optional-lock \
			disabled <../untracked-snapshot-cold.trace &&
		test_trace2_data status untracked-cache/restore \
			miss <../untracked-snapshot-cold.trace &&
		test_trace2_data status untracked/cache-root-present \
			0 <../untracked-snapshot-cold.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-snapshot-cold.trace &&
		git hash-object .git/index >../untracked-snapshot-cold-index.after &&
		test_cmp ../untracked-snapshot-cold-index.before \
			../untracked-snapshot-cold-index.after &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-locked.trace" \
			git status --porcelain >../untracked-snapshot-locked.out &&
		test_cmp ../untracked-snapshot-cold.out \
			../untracked-snapshot-locked.out &&
		test_trace2_data status index/optional-lock \
			acquired <../untracked-snapshot-locked.trace &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-snapshot-locked.trace &&
		test_trace2_data status untracked-cache/restore \
			hit <../untracked-snapshot-locked.trace &&
		test_trace2_data status untracked/cache-root-present \
			1 <../untracked-snapshot-locked.trace &&
		test_trace2_data status untracked/directories-visited \
			0 <../untracked-snapshot-locked.trace &&
		test_trace2_data status untracked/cache-opendir \
			0 <../untracked-snapshot-locked.trace &&
		! have_t2_data_event status untracked-cache/restore-reason \
			<../untracked-snapshot-locked.trace &&
		! have_t2_data_event fsmonitor untracked-cache/save-outcome \
			<../untracked-snapshot-locked.trace &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-warm-locked.trace" \
			git status --porcelain >../untracked-snapshot-warm-locked.out &&
		test_cmp ../untracked-snapshot-cold.out \
			../untracked-snapshot-warm-locked.out &&
		test_trace2_data status index/optional-lock \
			acquired <../untracked-snapshot-warm-locked.trace &&
		test_trace2_data status untracked-cache/restore-attempted \
			0 <../untracked-snapshot-warm-locked.trace &&
		! have_t2_data_event status untracked-cache/restore \
			<../untracked-snapshot-warm-locked.trace &&
		! have_t2_data_event status untracked-cache/restore-reason \
			<../untracked-snapshot-warm-locked.trace &&
		test_trace2_data status untracked/cache-root-present \
			1 <../untracked-snapshot-warm-locked.trace &&
		test_trace2_data status untracked/directories-visited \
			0 <../untracked-snapshot-warm-locked.trace &&
		test_trace2_data status untracked/cache-opendir \
			0 <../untracked-snapshot-warm-locked.trace &&
		! have_t2_data_event fsmonitor untracked-cache/save-outcome \
			<../untracked-snapshot-warm-locked.trace &&
		mkdir -p nested/one nested/two &&
		echo exclude >exclude-target &&
		echo one >nested/one/untracked &&
		echo two >nested/two/untracked &&
		git hash-object .git/index >../untracked-snapshot-index.before &&
		GIT_TEST_FSMONITOR_COMPRESS_UNTRACKED_CACHE=1 \
		GIT_TRACE2_EVENT_NESTING=2 \
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-first.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-first.out &&
		test_trace2_data status index/optional-lock \
			disabled <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked-cache/restore \
			miss <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked/cache-present \
			1 <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked/cache-root-present \
			1 <../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/cache-root-valid \
			<../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/cache-root-dirs \
			<../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/cache-root-can-skip \
			<../untracked-snapshot-first.trace &&
		test_trace2_data status untracked/cache-use-fsmonitor \
			1 <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked/cache-resync \
			0 <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked/requested-flags \
			6 <../untracked-snapshot-first.trace &&
		test_trace2_data status untracked/stored-flags \
			6 <../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/directories-visited \
			<../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/paths-visited \
			<../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/cache-opendir \
			<../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/cache-directory-invalidated \
			<../untracked-snapshot-first.trace &&
		have_t2_data_event status untracked/cache-gitignore-invalidated \
			<../untracked-snapshot-first.trace &&
		! have_t2_data_event status untracked-cache/restore-reason \
			<../untracked-snapshot-first.trace &&
		test_trace2_data fsmonitor untracked-cache/restore \
			miss <../untracked-snapshot-first.trace &&
		test_trace2_data fsmonitor untracked-cache/compressed \
			1 <../untracked-snapshot-first.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-snapshot-first.trace &&
		GIT_TRACE2_EVENT_NESTING=2 \
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-second.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-second.out &&
		test_cmp ../untracked-snapshot-first.out \
			../untracked-snapshot-second.out &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-snapshot-second.trace &&
		test_trace2_data status untracked-cache/restore \
			hit <../untracked-snapshot-second.trace &&
		test_trace2_data status untracked/cache-present \
			1 <../untracked-snapshot-second.trace &&
		test_trace2_data status untracked/requested-flags \
			6 <../untracked-snapshot-second.trace &&
		test_trace2_data status untracked/stored-flags \
			6 <../untracked-snapshot-second.trace &&
		have_t2_data_event status untracked/directories-visited \
			<../untracked-snapshot-second.trace &&
		have_t2_data_event status untracked/subtrees-pruned \
			<../untracked-snapshot-second.trace &&
		have_t2_data_event status untracked/cache-opendir \
			<../untracked-snapshot-second.trace &&
		! have_t2_data_event status untracked-cache/restore-reason \
			<../untracked-snapshot-second.trace &&
		test_trace2_data fsmonitor untracked-cache/restore \
			hit <../untracked-snapshot-second.trace &&
		test_trace2_data fsmonitor untracked-cache/decompressed \
			1 <../untracked-snapshot-second.trace &&
		test_trace2_data fsmonitor untracked-cache/hit \
			1 <../untracked-snapshot-second.trace &&
		test_grep "nested/$" ../untracked-snapshot-second.out &&
		test_grep ! "nested/one/untracked" \
			../untracked-snapshot-second.out &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-all.trace" \
			git --no-optional-locks status -z -uall \
			>../untracked-snapshot-all.out &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status -z -uall \
			>../untracked-snapshot-all.expect &&
		test_cmp ../untracked-snapshot-all.expect \
			../untracked-snapshot-all.out &&
		nul_to_q <../untracked-snapshot-all.out \
			>../untracked-snapshot-all.filtered &&
		test_grep "nested/one/untrackedQ" \
			../untracked-snapshot-all.filtered &&
		test_grep "nested/two/untrackedQ" \
			../untracked-snapshot-all.filtered &&
		test_grep ! "nested/Q" \
			../untracked-snapshot-all.filtered &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-snapshot-all.trace &&
		test_trace2_data status untracked-cache/restore \
			hit <../untracked-snapshot-all.trace &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-normal.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-normal.out &&
		test_cmp ../untracked-snapshot-second.out \
			../untracked-snapshot-normal.out &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-snapshot-normal.trace &&
		test_trace2_data status untracked-cache/restore \
			hit <../untracked-snapshot-normal.trace &&
		echo exclude-target >../untracked-snapshot.excludes &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-excluded.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-excluded.out &&
		test_trace2_data fsmonitor untracked-cache/hit \
			1 <../untracked-snapshot-excluded.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-snapshot-excluded.trace &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-unsupported.trace" \
			git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../untracked-snapshot-excluded.expect &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-snapshot-unsupported.trace &&
		test_trace2_data status untracked-cache/restore \
			unsupported <../untracked-snapshot-unsupported.trace &&
		test_trace2_data status untracked-cache/restore-reason \
			ineligible <../untracked-snapshot-unsupported.trace &&
		test_trace2_data fsmonitor untracked-cache/restore \
			unsupported <../untracked-snapshot-unsupported.trace &&
		test_trace2_data fsmonitor untracked-cache/restore-reason \
			ineligible <../untracked-snapshot-unsupported.trace &&
		test_cmp ../untracked-snapshot-excluded.expect \
			../untracked-snapshot-excluded.out &&
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-repaired.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-repaired.out &&
		test_cmp ../untracked-snapshot-excluded.out \
			../untracked-snapshot-repaired.out &&
		test_trace2_data fsmonitor untracked-cache/hit \
			1 <../untracked-snapshot-repaired.trace &&
		mkdir added &&
		echo added >added/untracked &&
		>../untracked-snapshot-repaired.trace &&
		GIT_TRACE2_EVENT_NESTING=2 \
		GIT_TRACE2_EVENT="$PWD/../untracked-snapshot-repaired.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-snapshot-added.out &&
		test_trace2_data fsmonitor apply_count "[1-9][0-9]*" \
			<../untracked-snapshot-repaired.trace &&
		test_trace2_data fsmonitor untracked-cache/directory-invalidated \
			"[1-9][0-9]*" <../untracked-snapshot-repaired.trace &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../untracked-snapshot-added.expect &&
		test_cmp ../untracked-snapshot-added.expect \
			../untracked-snapshot-added.out &&
		rm added/untracked &&
		rmdir added &&
		git --no-optional-locks status --porcelain \
			>../untracked-snapshot-removed.out &&
		test_cmp ../untracked-snapshot-excluded.out \
			../untracked-snapshot-removed.out &&
		git hash-object .git/index >../untracked-snapshot-index.after &&
		test_cmp ../untracked-snapshot-index.before \
			../untracked-snapshot-index.after &&
		echo "$(test_oid zero)" >../untracked-snapshot-zero.expect &&
		for mode in skip-hash many-files
		do
			case "$mode" in
			skip-hash)
				git config index.skipHash true
				;;
			many-files)
				git config --unset index.skipHash &&
				git config feature.manyFiles true
				;;
			esac &&
			git update-index --no-assume-unchanged -- tracked &&
			git update-index --refresh --force-write-index &&
			test_trailing_hash .git/index \
				>"../untracked-snapshot-$mode-trailer" &&
			test_cmp ../untracked-snapshot-zero.expect \
				"../untracked-snapshot-$mode-trailer" &&
			for rewrite in initial rewritten
			do
				if test "$rewrite" = rewritten
				then
					git update-index \
						--assume-unchanged -- tracked || return 1
				fi &&
				prefix="../untracked-snapshot-$mode-$rewrite" &&
				git hash-object .git/index \
					>"$prefix-index.before" &&
				GIT_TRACE2_EVENT="$PWD/$prefix-miss.trace" \
					git --no-optional-locks status --porcelain \
					>"$prefix-miss.out" &&
				test_cmp ../untracked-snapshot-removed.out \
					"$prefix-miss.out" &&
				test_trace2_data status untracked-cache/restore \
					miss <"$prefix-miss.trace" &&
				have_t2_data_event fsmonitor \
					untracked-cache/saved \
					<"$prefix-miss.trace" &&
				GIT_TRACE2_EVENT="$PWD/$prefix-hit.trace" \
					git --no-optional-locks status --porcelain \
					>"$prefix-hit.out" &&
				test_cmp "$prefix-miss.out" "$prefix-hit.out" &&
				test_trace2_data status untracked-cache/restore \
					hit <"$prefix-hit.trace" &&
				git hash-object .git/index \
					>"$prefix-index.after" &&
				test_cmp "$prefix-index.before" \
					"$prefix-index.after" || return 1
			done || return 1
		done &&
		for event in region_enter region_leave
		do
			test "$(grep -c \
				"\"event\":\"$event\".*\"category\":\"fsmonitor\".*\"label\":\"untracked-cache/save\"" \
				../untracked-snapshot-first.trace)" -eq 1 || return 1
		done &&
		test "$(have_t2_data_event fsmonitor \
			untracked-cache/save-outcome \
			<../untracked-snapshot-first.trace | wc -l)" -eq 1 &&
		test_trace2_data fsmonitor untracked-cache/save-outcome \
			7 <../untracked-snapshot-first.trace
	)
'

test_expect_success 'status reuses untracked snapshot when index lock is unavailable' '
	test_when_finished "stop_daemon_delete_repo test_untracked_snapshot_lock" &&
	git init test_untracked_snapshot_lock &&
	(
		cd test_untracked_snapshot_lock &&
		test_commit base tracked &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		mkdir -p nested/one nested/two &&
		echo one >nested/one/untracked &&
		echo two >nested/two/untracked
	) &&
	start_daemon -C test_untracked_snapshot_lock &&
	(
		cd test_untracked_snapshot_lock &&
		git status --porcelain >../untracked-lock-initial.out &&
		git hash-object .git/index >../untracked-lock-index.before &&
		GIT_TRACE2_EVENT="$PWD/../untracked-lock-warm.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-lock-warm.out &&
		test_trace2_data status index/optional-lock \
			disabled <../untracked-lock-warm.trace &&
		test_trace2_data status untracked-cache/restore \
			miss <../untracked-lock-warm.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-lock-warm.trace &&
		: >.git/index.lock &&
		GIT_TRACE2_EVENT="$PWD/../untracked-lock-contended.trace" \
			git status --porcelain >../untracked-lock-contended.out &&
		rm -f .git/index.lock &&
		test_cmp ../untracked-lock-warm.out \
			../untracked-lock-contended.out &&
		test_trace2_data status index/optional-lock \
			unavailable <../untracked-lock-contended.trace &&
		test_trace2_data status untracked-cache/restore-attempted \
			1 <../untracked-lock-contended.trace &&
		test_trace2_data status untracked-cache/restore \
			hit <../untracked-lock-contended.trace &&
		test_trace2_data fsmonitor untracked-cache/hit \
			1 <../untracked-lock-contended.trace &&
		git hash-object .git/index >../untracked-lock-index.after &&
		test_cmp ../untracked-lock-index.before \
			../untracked-lock-index.after
	)
'

test_expect_success 'lock-free status recovers untracked snapshot after daemon restart' '
	test_when_finished "stop_daemon_delete_repo test_untracked_snapshot_restart" &&
	git init test_untracked_snapshot_restart &&
	(
		cd test_untracked_snapshot_restart &&
		test_commit base tracked &&
		mkdir -p steady/deep &&
		test_commit clean-one steady/deep/tracked &&
		test_commit clean-two &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		: >../untracked-restart.excludes &&
		git config core.excludesFile \
			"$PWD/../untracked-restart.excludes" &&
		mkdir nested &&
		echo original >nested/original
	) &&
	start_daemon -C test_untracked_snapshot_restart &&
	(
		cd test_untracked_snapshot_restart &&
		git status --porcelain >../untracked-restart-initial.out &&
		git hash-object .git/index >../untracked-restart-index.before &&
		git fsmonitor--daemon stop &&
		echo modified >>tracked &&
		echo added >nested/added &&
		echo ignored >ignored &&
		echo ignored >../untracked-restart.excludes &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../untracked-restart.expect
	) &&
	start_daemon -C test_untracked_snapshot_restart &&
	(
		cd test_untracked_snapshot_restart &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-first.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-restart-first.out &&
		test_cmp ../untracked-restart.expect \
			../untracked-restart-first.out &&
		test_trace2_data status index/optional-lock disabled \
			<../untracked-restart-first.trace &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<../untracked-restart-first.trace &&
		test_trace2_data fsm_client query/trivial-reason \
			token-generation-changed <../untracked-restart-first.trace &&
		test_trace2_data status untracked-cache/restore miss \
			<../untracked-restart-first.trace &&
		test_trace2_data index preload/sum_lstat 2 \
			<../untracked-restart-first.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-restart-first.trace &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-second.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-restart-second.out &&
		test_cmp ../untracked-restart.expect \
			../untracked-restart-second.out &&
		test_trace2_data status index/optional-lock disabled \
			<../untracked-restart-second.trace &&
		test_trace2_data status untracked-cache/restore hit \
			<../untracked-restart-second.trace &&
		test_trace2_data fsmonitor untracked-cache/hit 1 \
			<../untracked-restart-second.trace &&
		test_trace2_data fsmonitor tracked-cache/restored 2 \
			<../untracked-restart-second.trace &&
		test_trace2_data index refresh/sum_lstat 1 \
			<../untracked-restart-second.trace &&
		! have_t2_data_event index preload/sum_lstat \
			<../untracked-restart-second.trace &&
		GIT_TRACE2_EVENT_NESTING=4 \
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-all.trace" \
			git --no-optional-locks status --porcelain -uall \
			>../untracked-restart-all.out &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain -uall \
			>../untracked-restart-all.expect &&
		test_cmp ../untracked-restart-all.expect \
			../untracked-restart-all.out &&
		test_trace2_data status untracked-cache/restore hit \
			<../untracked-restart-all.trace &&
		test_trace2_data status untracked/requested-flags 0 \
			<../untracked-restart-all.trace &&
		test_trace2_data status untracked/stored-flags 6 \
			<../untracked-restart-all.trace &&
		test_trace2_data untracked_cache negative-only 1 \
			<../untracked-restart-all.trace &&
		have_t2_data_event status untracked/subtrees-pruned \
			<../untracked-restart-all.trace &&
		! test_trace2_data status untracked/subtrees-pruned 0 \
			<../untracked-restart-all.trace &&
		echo changed >>steady/deep/tracked &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../untracked-restart-changed.expect &&
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-changed.trace" \
			git --no-optional-locks status --porcelain \
			>../untracked-restart-changed.out &&
		test_cmp ../untracked-restart-changed.expect \
			../untracked-restart-changed.out &&
		test_trace2_data status untracked-cache/restore miss \
			<../untracked-restart-changed.trace &&
		! have_t2_data_event fsmonitor tracked-cache/restored \
			<../untracked-restart-changed.trace &&
		git hash-object .git/index >../untracked-restart-index.after &&
		test_cmp ../untracked-restart-index.before \
			../untracked-restart-index.after &&
		rm nested/original nested/added &&
		git checkout -- tracked steady/deep/tracked &&
		git status --porcelain >../untracked-restart-clean.out &&
		test_must_be_empty ../untracked-restart-clean.out &&
		test_path_is_file ignored &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain -uall \
			>../untracked-restart-clean.expect &&
		test_must_be_empty ../untracked-restart-clean.expect &&
		git hash-object .git/index >../untracked-restart-clean-index.before &&
		git fsmonitor--daemon stop &&
		start_daemon -C . &&
		GIT_TRACE2_EVENT_NESTING=4 \
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-clean-first.trace" \
			git --no-optional-locks status --porcelain -uall \
			>../untracked-restart-clean-first.out &&
		test_cmp ../untracked-restart-clean.expect \
			../untracked-restart-clean-first.out &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<../untracked-restart-clean-first.trace &&
		test_trace2_data status untracked-cache/restore miss \
			<../untracked-restart-clean-first.trace &&
		test_trace2_data status untracked/cache-root-valid 0 \
			<../untracked-restart-clean-first.trace &&
		! have_t2_data_event untracked_cache \
			serialize/resync-invalidated-nodes \
			<../untracked-restart-clean-first.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-restart-clean-first.trace &&
		test_trace2_data fsmonitor untracked-cache/save-root-valid 0 \
			<../untracked-restart-clean-first.trace &&
		test "$(have_t2_data_event fsmonitor untracked-cache/save-root-valid \
			<../untracked-restart-clean-first.trace | wc -l)" -eq 1 &&
		test_trace2_data fsmonitor untracked-cache/save-root-can-skip 0 \
			<../untracked-restart-clean-first.trace &&
		test "$(have_t2_data_event fsmonitor untracked-cache/save-root-can-skip \
			<../untracked-restart-clean-first.trace | wc -l)" -eq 1 &&
		GIT_TRACE2_EVENT_NESTING=4 \
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-clean-second.trace" \
			git --no-optional-locks status --porcelain -uall \
			>../untracked-restart-clean-second.out &&
		test_cmp ../untracked-restart-clean.expect \
			../untracked-restart-clean-second.out &&
		test_trace2_data status untracked-cache/restore hit \
			<../untracked-restart-clean-second.trace &&
		test_trace2_data status untracked/cache-root-valid 0 \
			<../untracked-restart-clean-second.trace &&
		test_trace2_data untracked_cache negative-only 1 \
			<../untracked-restart-clean-second.trace &&
		have_t2_data_event status untracked/subtrees-repaired \
			<../untracked-restart-clean-second.trace &&
		! test_trace2_data status untracked/subtrees-repaired 0 \
			<../untracked-restart-clean-second.trace &&
		have_t2_data_event fsmonitor untracked-cache/saved \
			<../untracked-restart-clean-second.trace &&
		test_trace2_data fsmonitor untracked-cache/save-root-valid 1 \
			<../untracked-restart-clean-second.trace &&
		test "$(have_t2_data_event fsmonitor untracked-cache/save-root-valid \
			<../untracked-restart-clean-second.trace | wc -l)" -eq 1 &&
		test_trace2_data fsmonitor untracked-cache/save-root-can-skip 1 \
			<../untracked-restart-clean-second.trace &&
		test "$(have_t2_data_event fsmonitor untracked-cache/save-root-can-skip \
			<../untracked-restart-clean-second.trace | wc -l)" -eq 1 &&
		GIT_TRACE2_EVENT_NESTING=4 \
		GIT_TRACE2_EVENT="$PWD/../untracked-restart-clean-third.trace" \
			git --no-optional-locks status --porcelain -uall \
			>../untracked-restart-clean-third.out &&
		test_cmp ../untracked-restart-clean.expect \
			../untracked-restart-clean-third.out &&
		test_trace2_data status untracked-cache/restore hit \
			<../untracked-restart-clean-third.trace &&
		test_trace2_data status untracked/cache-root-valid 1 \
			<../untracked-restart-clean-third.trace &&
		test_trace2_data status untracked/subtrees-pruned 1 \
			<../untracked-restart-clean-third.trace &&
		test_trace2_data status untracked/directories-visited 0 \
			<../untracked-restart-clean-third.trace &&
		git hash-object .git/index >../untracked-restart-clean-index.after &&
		test_cmp ../untracked-restart-clean-index.before \
			../untracked-restart-clean-index.after
	)
'

test_expect_success PTHREADS \
	'parallel directory validation recovers after daemon restart' '
	test_when_finished "stop_daemon_delete_repo test_untracked_revalidate" &&
	git init test_untracked_revalidate &&
	(
		cd test_untracked_revalidate &&
		mkdir -p nested/deleted nested/renamed \
			nested/ignored nested/steady &&
		for dir in deleted renamed ignored steady
		do
			echo tracked >nested/$dir/tracked || return 1
		done &&
		echo hidden-before >nested/ignored/.gitignore &&
		git add nested &&
		git commit -m initial &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		: >../untracked-revalidate.excludes &&
		git config core.excludesFile \
			"$PWD/../untracked-revalidate.excludes" &&
		echo deleted >nested/deleted/remove &&
		echo renamed >nested/renamed/before &&
		echo steady >nested/steady/keep &&
		echo hidden >nested/ignored/hidden-before
	) &&
	start_daemon -C test_untracked_revalidate &&
	(
		cd test_untracked_revalidate &&
		git status --porcelain >../untracked-revalidate.initial &&
		git hash-object .git/index >../untracked-revalidate.index-before &&
		git fsmonitor--daemon stop &&
		rm nested/deleted/remove &&
		echo added >nested/deleted/added &&
		mv nested/renamed/before nested/renamed/after &&
		echo hidden-after >nested/ignored/.gitignore &&
		echo hidden >nested/ignored/hidden-after &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../untracked-revalidate.expect
	) &&
	start_daemon -C test_untracked_revalidate &&
	(
		cd test_untracked_revalidate &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=1 \
		GIT_TRACE2_EVENT="$PWD/../untracked-revalidate.trace" \
		GIT_TRACE2_PERF="$PWD/../untracked-revalidate.perf" \
			git --no-optional-locks status --porcelain \
			>../untracked-revalidate.actual &&
		test_cmp ../untracked-revalidate.expect \
			../untracked-revalidate.actual &&
		test_trace2_data fsm_client query/trivial-response 1 \
			<../untracked-revalidate.trace &&
		test_trace2_data untracked_cache \
			gitignore-invalidation/per-directory "[1-9][0-9]*" \
			<../untracked-revalidate.trace &&
		test_trace2_data untracked_cache \
			gitignore-invalidation/changed "[1-9][0-9]*" \
			<../untracked-revalidate.trace &&
		test_grep ! "gitignore-invalidation-source:" \
			../untracked-revalidate.trace &&
		test_grep "parallel-lstat:[1-9]" \
			../untracked-revalidate.perf &&
		test_grep "nested/deleted/added" \
			../untracked-revalidate.actual &&
		test_grep "nested/renamed/after" \
			../untracked-revalidate.actual &&
		test_grep "nested/ignored/hidden-before" \
			../untracked-revalidate.actual &&
		test_grep ! "nested/deleted/remove" \
			../untracked-revalidate.actual &&
		test_grep ! "nested/renamed/before" \
			../untracked-revalidate.actual &&
		test_grep ! "nested/ignored/hidden-after" \
			../untracked-revalidate.actual &&
		git hash-object .git/index >../untracked-revalidate.index-after &&
		test_cmp ../untracked-revalidate.index-before \
			../untracked-revalidate.index-after &&
		git status --porcelain >../untracked-revalidate.warmup &&
		echo modified >>nested/steady/tracked &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../untracked-revalidate.warm-expect &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=1 \
		GIT_TRACE2_PERF="$PWD/../untracked-revalidate.warm-perf" \
			git --no-optional-locks status --porcelain \
			>../untracked-revalidate.warm-actual &&
		test_cmp ../untracked-revalidate.warm-expect \
			../untracked-revalidate.warm-actual &&
		test_grep ! "parallel-lstat:[1-9]" \
			../untracked-revalidate.warm-perf
	)
'

test_expect_success 'daemon restart revalidates hidden skipped subtrees' '
	test_when_finished "stop_daemon_delete_repo test_untracked_skipped" &&
	test_when_finished "test ! -f test_untracked_skipped/stable/.gitignore ||
		chmod 600 test_untracked_skipped/stable/.gitignore" &&
	test_when_finished "test ! -f untracked-skipped-outside/.gitignore ||
		chmod 600 untracked-skipped-outside/.gitignore" &&
	git init test_untracked_skipped &&
	(
		cd test_untracked_skipped &&
		echo tracked >tracked &&
		mkdir stable &&
		echo one >stable/one &&
		echo two >stable/two &&
		echo three >stable/three &&
		echo ignored >stable/.gitignore &&
		git add tracked stable &&
		git commit -m initial &&
		git config core.fsmonitor true &&
		git config core.untrackedCache true &&
		git config index.version 2 &&
		git config index.skipHash false &&
		git config core.splitIndex false &&
		git config index.recordEndOfIndexEntries false &&
		git config index.recordOffsetTable false &&
		git config index.threads 1 &&
		git -c core.fsmonitor=false update-index --index-version 2 &&
		echo ignored >stable/ignored &&
		mkdir -p u/a-visible &&
		mkdir -p u/z-hidden &&
		printf ".gitignore\\nitem\\n" >u/z-hidden/.gitignore &&
		echo hidden >u/z-hidden/item
	) &&
	start_daemon -C test_untracked_skipped &&
	(
		cd test_untracked_skipped &&
		git status --porcelain >../untracked-skipped.initial &&
		test_must_be_empty ../untracked-skipped.initial &&
		echo visible >u/a-visible/file &&
		git status --porcelain >../untracked-skipped.visible &&
		test_grep "^?? u/$" ../untracked-skipped.visible &&
		GIT_TRACE2_PERF="$PWD/../untracked-skipped.prime-perf" \
			git ls-files --others --exclude-standard \
			>../untracked-skipped.prime &&
		test_grep "^u/a-visible/file$" \
			../untracked-skipped.prime &&
		test_grep ! "u/z-hidden/item" \
			../untracked-skipped.prime &&
		test-tool dump-untracked-cache \
			>../untracked-skipped.before-uno &&
		test_grep "^/stable/ .* valid$" \
			../untracked-skipped.before-uno &&
		git fsmonitor--daemon stop &&
		printf ".gitignore\\n" >u/z-hidden/.gitignore
	) &&
	start_daemon -C test_untracked_skipped &&
	(
		cd test_untracked_skipped &&
		GIT_TRACE2_EVENT="$PWD/../untracked-skipped.uno.trace" \
			git status --porcelain -uno \
			>../untracked-skipped.uno &&
		test_must_be_empty ../untracked-skipped.uno &&
		test_trace2_data status index/optional-lock acquired \
			<../untracked-skipped.uno.trace &&
		test_trace2_data fsm_client query/trivial-reason \
			token-generation-changed <../untracked-skipped.uno.trace &&
		test-tool dump-untracked-cache \
			>../untracked-skipped.after-uno &&
		test_grep "^/stable/ .* valid$" \
			../untracked-skipped.after-uno &&
		test-tool dump-untracked-cache state \
			>../untracked-skipped.pending-state &&
		test_grep "^pending " ../untracked-skipped.pending-state &&
		test-tool dump-untracked-cache inspect-index .git/index \
			>../untracked-skipped.inventory &&
		test_grep "^UNRV " ../untracked-skipped.inventory &&
		test_grep ! "^UNTR " ../untracked-skipped.inventory &&
		GIT_TRACE2_EVENT="$PWD/../untracked-skipped.second-uno.trace" \
			git status --porcelain -uno \
			>../untracked-skipped.second-uno &&
		test_must_be_empty ../untracked-skipped.second-uno &&
		test_trace2_data status index/optional-lock acquired \
			<../untracked-skipped.second-uno.trace &&
		have_t2_data_event fsmonitor apply_count \
			<../untracked-skipped.second-uno.trace &&
		! have_t2_data_event fsm_client query/trivial-response \
			<../untracked-skipped.second-uno.trace &&
		test_trace2_data index refresh/sum_lstat 0 \
			<../untracked-skipped.second-uno.trace &&
		test-tool dump-untracked-cache state \
			>../untracked-skipped.second-state &&
		test_cmp ../untracked-skipped.pending-state \
			../untracked-skipped.second-state &&
		test-tool dump-untracked-cache \
			>../untracked-skipped.second-dump &&
		test_grep "^/stable/ .* valid$" \
			../untracked-skipped.second-dump &&
		if test_have_prereq SANITY
		then
			ignore_oid=$(git hash-object stable/.gitignore) &&
			test_grep "^/stable/ $ignore_oid .* valid$" \
				../untracked-skipped.second-dump &&
			chmod 000 stable/.gitignore &&
			git --no-optional-locks -c core.fsmonitor=false \
				-c core.untrackedCache=false status --porcelain \
				>../untracked-skipped.pending-expect &&
			GIT_TEST_FSMONITOR_COMPRESS_UNTRACKED_CACHE=1 \
			GIT_TRACE2_EVENT_NESTING=4 \
			GIT_TRACE2_EVENT="$PWD/../untracked-skipped.pending-first.trace" \
				git --no-optional-locks status --porcelain \
				>../untracked-skipped.pending-first &&
			GIT_TEST_FSMONITOR_COMPRESS_UNTRACKED_CACHE=1 \
			GIT_TRACE2_EVENT_NESTING=4 \
			GIT_TRACE2_EVENT="$PWD/../untracked-skipped.pending-second.trace" \
				git --no-optional-locks status --porcelain \
				>../untracked-skipped.pending-second &&
			test_cmp ../untracked-skipped.pending-expect \
				../untracked-skipped.pending-first &&
			test_cmp ../untracked-skipped.pending-expect \
				../untracked-skipped.pending-second &&
			test_trace2_data status untracked-cache/restore miss \
				<../untracked-skipped.pending-first.trace &&
			have_t2_data_event fsmonitor apply_count \
				<../untracked-skipped.pending-first.trace &&
			! have_t2_data_event fsm_client query/trivial-response \
				<../untracked-skipped.pending-first.trace &&
			test_trace2_data status untracked/cache-resync 1 \
				<../untracked-skipped.pending-first.trace &&
			test_trace2_data fsmonitor untracked-cache/compressed 1 \
				<../untracked-skipped.pending-first.trace &&
			have_t2_data_event fsmonitor untracked-cache/saved \
				<../untracked-skipped.pending-first.trace &&
			test_trace2_data status untracked-cache/restore hit \
				<../untracked-skipped.pending-second.trace &&
			test_trace2_data fsmonitor untracked-cache/decompressed 1 \
				<../untracked-skipped.pending-second.trace &&
			have_t2_data_event fsmonitor apply_count \
				<../untracked-skipped.pending-second.trace &&
			! have_t2_data_event fsm_client query/trivial-response \
				<../untracked-skipped.pending-second.trace &&
			test_trace2_data status untracked/cache-resync 1 \
				<../untracked-skipped.pending-second.trace &&
			test_trace2_data fsmonitor tracked-cache/restored \
				"[1-9][0-9]*" <../untracked-skipped.pending-second.trace &&
			test-tool dump-untracked-cache state \
				>../untracked-skipped.snapshot-state &&
			test_cmp ../untracked-skipped.pending-state \
				../untracked-skipped.snapshot-state &&
			chmod 600 stable/.gitignore
		fi &&
		test-tool dump-untracked-cache rewrite-index \
			.git/index .git/legacy-topology \
			--node-name=1:../untracked-skipped-outside --legacy=only &&
		git status --porcelain >../untracked-skipped.first &&
		test_grep "^?? u/$" ../untracked-skipped.first &&
		git update-index --force-write-index &&
		GIT_TRACE2_PERF="$PWD/../untracked-skipped.detail-perf" \
			git ls-files --others --exclude-standard \
			>../untracked-skipped.detail-actual &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			ls-files --others --exclude-standard \
			>../untracked-skipped.detail-expect &&
		test_cmp ../untracked-skipped.detail-expect \
			../untracked-skipped.detail-actual &&
		test_grep "^u/z-hidden/item$" \
			../untracked-skipped.detail-actual &&
		rm u/a-visible/file &&
		git status --porcelain >../untracked-skipped.actual &&
		git -c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain >../untracked-skipped.expect &&
		test_cmp ../untracked-skipped.expect \
			../untracked-skipped.actual &&
		test_grep "^?? u/$" ../untracked-skipped.actual &&
		mkdir ../untracked-skipped-outside &&
		echo "*" >../untracked-skipped-outside/.gitignore &&
		if test_have_prereq SANITY
		then
			chmod 000 ../untracked-skipped-outside/.gitignore
		fi &&
		GIT_INDEX_FILE=.git/legacy-topology \
			test-tool dump-untracked-cache state \
			>../untracked-skipped.legacy-state &&
		echo trusted >../untracked-skipped.trusted-state &&
		test_cmp ../untracked-skipped.trusted-state \
			../untracked-skipped.legacy-state &&
		git fsmonitor--daemon stop &&
		start_daemon -C . &&
		GIT_INDEX_FILE=.git/legacy-topology GIT_OPTIONAL_LOCKS=0 \
			git -c core.fsmonitor=false -c core.untrackedCache=false \
			status --porcelain >../untracked-skipped.legacy-expect &&
		GIT_INDEX_FILE=.git/legacy-topology \
		GIT_TRACE2_EVENT="$PWD/../untracked-skipped.legacy.trace" \
			git status --porcelain >../untracked-skipped.legacy-actual \
			2>../untracked-skipped.legacy-err &&
		test_cmp ../untracked-skipped.legacy-expect \
			../untracked-skipped.legacy-actual &&
		test_grep ! "unable to access" ../untracked-skipped.legacy-err &&
		test_trace2_data fsm_client query/trivial-reason \
			token-generation-changed <../untracked-skipped.legacy.trace &&
		GIT_INDEX_FILE=.git/legacy-topology \
			test-tool dump-untracked-cache state \
			>../untracked-skipped.legacy-state &&
		echo absent >../untracked-skipped.absent-state &&
		test_cmp ../untracked-skipped.absent-state \
			../untracked-skipped.legacy-state
	)
'

test_expect_success MACOS 'worktree binding rejects same-gitdir aliases' '
	test_when_finished "git -C binding-a fsmonitor--daemon stop 2>/dev/null || :" &&
	git init --separate-git-dir="$PWD/binding-gitdir" binding-a &&
	mkdir binding-b &&
	cp binding-a/.git binding-b/.git &&
	(
		cd binding-a &&
		test_commit base tracked &&
		git config core.untrackedCache true &&
		git config core.fsmonitor true &&
		GIT_TRACE2_EVENT="$PWD/../binding-daemon.trace" \
			git status --porcelain=v2 >/dev/null &&
		git status --porcelain=v2 >/dev/null
	) &&
	cp binding-a/tracked binding-b/tracked &&
	echo changed >>binding-b/tracked &&
	git -C binding-b --no-optional-locks \
		-c core.fsmonitor=false -c core.untrackedCache=false \
		status --porcelain=v2 >binding.expect &&
	git -C binding-b --no-optional-locks \
		status --porcelain=v2 >binding.actual &&
	test_cmp binding.expect binding.actual &&
	test_grep "^1 \.M .* tracked$" binding.actual &&
	test_grep "\"key\":\"query/worktree-mismatch\",\"value\":\"1\"" \
		binding-daemon.trace &&
	git -C binding-a fsmonitor--daemon stop
'

test_done

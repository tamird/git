#!/bin/sh

test_description='simple command server'

. ./test-lib.sh

test-tool simple-ipc SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

stop_simple_IPC_server () {
	test-tool simple-ipc stop-daemon
}

wait_for_worker_trace () {
	tries=0
	while ! grep \
		"\"event\":\"thread_start\".*\"thread\":\"th[0-9]*:ipc-worker\"" \
		daemon.trace >workers
	do
		tries=$(($tries + 1))
		if test "$tries" -ge 5
		then
			return 1
		fi
		sleep 1
	done
}

wait_for_pids () {
	result=0
	for pid
	do
		wait "$pid" || result=1
	done
	test "$result" = 0
}

test_expect_success 'start simple command server' '
	test_atexit stop_simple_IPC_server &&
	GIT_TEST_SIMPLE_IPC_SLOW_STARTUP=1 \
	GIT_TRACE2_EVENT="$PWD/daemon.trace" \
		test-tool simple-ipc start-daemon --threads=8 &&
	test_grep \
		"\"category\":\"test-simple-ipc\".*\"key\":\"startup-probe\"" \
		daemon.trace >startup-probes &&
	test_line_count -ge 3 startup-probes &&
	test_line_count -lt 20 startup-probes
'

test_expect_success !MINGW 'worker pool starts with one thread' '
	wait_for_worker_trace &&
	test_line_count = 1 workers
'

test_expect_success 'simple command server' '
	test-tool simple-ipc send --token=ping >actual &&
	echo pong >expect &&
	test_cmp expect actual
'

test_expect_success 'servers cannot share the same path' '
	test_must_fail test-tool simple-ipc run-daemon &&
	test-tool simple-ipc is-active
'

test_expect_success 'big response' '
	test-tool simple-ipc send --token=big >actual &&
	test_line_count -ge 10000 actual &&
	test_grep -q "big: [0]*9999\$" actual
'

test_expect_success 'chunk response' '
	test-tool simple-ipc send --token=chunk >actual &&
	test_line_count -ge 10000 actual &&
	test_grep -q "big: [0]*9999\$" actual
'

test_expect_success MINGW 'slow response' '
	test-tool simple-ipc send --token=slow >actual &&
	test_line_count -ge 100 actual &&
	test_grep -q "big: [0]*99\$" actual
'

test_expect_success !MINGW 'worker pool grows on demand' '
	pids= &&
	for i in 1 2 3 4
	do
		{ test-tool simple-ipc send --token=slow >actual.$i & } &&
		pids="$pids $!" || return 1
	done &&
	wait_for_pids $pids &&
	for i in 1 2 3 4
	do
		test_line_count -ge 100 actual.$i &&
		grep -q "big: [0]*99\$" actual.$i || return 1
	done &&
	grep "\"event\":\"thread_start\".*\"thread\":\"th[0-9]*:ipc-worker\"" \
		daemon.trace >workers &&
	test_line_count -ge 4 workers &&
	test_line_count -lt 9 workers
'

# Send an IPC with n=100,000 bytes of ballast.  This should be large enough
# to force both the kernel and the pkt-line layer to chunk the message to the
# daemon and for the daemon to receive it in chunks.
#
test_expect_success 'sendbytes' '
	test-tool simple-ipc sendbytes --bytecount=100000 --byte=A >actual &&
	test_grep "sent:A00100000 rcvd:A00100000" actual
'

test_expect_success 'reject oversized request' '
	test_must_fail test-tool simple-ipc sendbytes \
		--bytecount=200000 --byte=A 2>err &&
	grep "could not .* IPC" err
'

# Start a series of <threads> client threads that each make <batchsize>
# IPC requests to the server.  Each (<threads> * <batchsize>) request
# will open a new connection to the server and randomly bind to a server
# thread.  Each client thread exits after completing its batch.  So the
# total number of live client threads will be smaller than the total.
# Each request will send a message containing at least <bytecount> bytes
# of ballast.  (Responses are small.)
#
# The purpose here is to test threading in the server and responding to
# many concurrent client requests (regardless of whether they come from
# 1 client process or many).  And to test that the server side of the
# named pipe/socket is stable.  (On Windows this means that the server
# pipe is properly recycled.)
#
# On Windows it also lets us adjust the connection timeout in the
# `ipc_client_send_command()`.
#
# Note it is easy to drive the system into failure by requesting an
# insane number of threads on client or server and/or increasing the
# per-thread batchsize or the per-request bytecount (ballast).
# On Windows these failures look like "pipe is busy" errors.
# So I've chosen fairly conservative values for now.
#
# We expect output of the form "sent:<letter><length> ..."
# With terms (7, 19, 13) we expect:
#   <letter> in [A-G]
#   <length> in [19+0 .. 19+(13-1)]
# and (7 * 13) successful responses.
#
test_expect_success 'stress test threads' '
	test-tool simple-ipc multiple \
		--threads=7 \
		--bytecount=19 \
		--batchsize=13 \
		>actual &&
	test_line_count = 92 actual &&
	test_grep "good 91" actual &&
	grep "sent:A" <actual >actual_a &&
	cat >expect_a <<-EOF &&
		sent:A00000019 rcvd:A00000019
		sent:A00000020 rcvd:A00000020
		sent:A00000021 rcvd:A00000021
		sent:A00000022 rcvd:A00000022
		sent:A00000023 rcvd:A00000023
		sent:A00000024 rcvd:A00000024
		sent:A00000025 rcvd:A00000025
		sent:A00000026 rcvd:A00000026
		sent:A00000027 rcvd:A00000027
		sent:A00000028 rcvd:A00000028
		sent:A00000029 rcvd:A00000029
		sent:A00000030 rcvd:A00000030
		sent:A00000031 rcvd:A00000031
	EOF
	test_cmp expect_a actual_a
'

test_expect_success 'stop-daemon works' '
	test-tool simple-ipc stop-daemon &&
	test_must_fail test-tool simple-ipc is-active &&
	test_must_fail test-tool simple-ipc send --token=ping
'

test_expect_success !MINGW,FSMONITOR_DAEMON 'connection errors report their original errno' '
	test_when_finished "rm -rf invalid-socket-repo invalid-socket-parent invalid-socket.trace" &&
	git init invalid-socket-repo &&
	: >invalid-socket-parent &&
	git -C invalid-socket-repo config fsmonitor.socketDir \
		"$PWD/invalid-socket-parent" &&
	GIT_TRACE2_EVENT="$PWD/invalid-socket.trace" \
	GIT_TRACE2_EVENT_NESTING=2 \
		test_must_fail test-tool -C invalid-socket-repo \
			fsmonitor-client query --token 0 &&
	test_trace2_data ipc-client try-connect/errno 20 \
		<invalid-socket.trace &&
	test_grep "\"category\":\"fsm_client\",\"key\":\"query/connect-errno\"" \
		invalid-socket.trace >actual &&
	test_line_count = 1 actual &&
	test_trace2_data fsm_client query/connect-errno 20 <actual &&
	test_grep "\"event\":\"data\".*\"nesting\":1," actual &&
	printf "%s\n" region_leave data >expect &&
	grep -e "\"event\":\"region_leave\".*\"category\":\"fsm_client\",\"label\":\"query\"" \
		-e "\"category\":\"fsm_client\",\"key\":\"query/connect-errno\"" \
		invalid-socket.trace |
	sed -n "s/.*\"event\":\"\\([^\"]*\\)\".*/\\1/p" >actual &&
	test_cmp expect actual
'

test_expect_success FSMONITOR_DAEMON 'untracked snapshot save uses the IPC response' '
	test_config core.fsmonitor false &&
	test_config core.untrackedCache true &&
	test_commit save-reply tracked &&
	GIT_TEST_SPLIT_INDEX=0 git update-index --no-split-index &&
	GIT_TEST_SPLIT_INDEX=0 git status --porcelain >save-reply-status.out &&
	git hash-object .git/index >save-reply-index.before &&
	git config core.fsmonitor true &&
	save_socket=$(test-tool fsmonitor-client ipc-path) &&
	test_when_finished "test-tool simple-ipc stop-daemon --name=\"$save_socket\" >/dev/null 2>&1 || :" &&
	: >save-reply.response &&
	test-tool simple-ipc start-daemon --name="$save_socket" --threads=1 \
		--reply-file="$PWD/save-reply.response" &&
	(
		sane_unset GIT_TRACE2_EVENT_NESTING &&
		for response in miss missing binary empty ok
		do
			case "$response" in
			miss|missing|ok) printf "%s" "$response" ;;
			binary) printf "miss-save-reply-private-canary\\000" ;;
			empty) : ;;
			esac >save-reply.response &&
			GIT_TRACE2_EVENT="$PWD/save-reply-$response.trace" \
				test-tool fsmonitor-client save-untracked-cache \
					--token=builtin:save-reply:1 \
					>"save-reply-$response.out" \
					2>"save-reply-$response.err" &&
			test_must_be_empty "save-reply-$response.out" &&
			test_must_be_empty "save-reply-$response.err" &&
			if test "$response" = ok
			then
				test_trace2_data fsmonitor untracked-cache/save-outcome 7 \
					<"save-reply-$response.trace" &&
				test_trace2_data fsmonitor untracked-cache/saved "[1-9][0-9]*" \
					<"save-reply-$response.trace" &&
				test_expect_code 1 test_trace2_data fsmonitor \
					untracked-cache/save-reply ".*" \
					<"save-reply-$response.trace"
			else
				test_trace2_data fsmonitor untracked-cache/save-outcome 6 \
					<"save-reply-$response.trace" &&
				test_expect_code 1 test_trace2_data fsmonitor \
					untracked-cache/saved ".*" \
					<"save-reply-$response.trace"
			fi || return 1
		done &&
		test-tool simple-ipc stop-daemon --name="$save_socket" &&
		GIT_TRACE2_EVENT="$PWD/save-reply-disconnected.trace" \
			test-tool fsmonitor-client save-untracked-cache \
				--token=builtin:save-reply:1 \
				>save-reply-disconnected.out \
				2>save-reply-disconnected.err &&
		test_must_be_empty save-reply-disconnected.out &&
		test_must_be_empty save-reply-disconnected.err &&
		test_trace2_data fsmonitor untracked-cache/save-outcome 5 \
			<save-reply-disconnected.trace &&
		test_expect_code 1 test_trace2_data fsmonitor \
			untracked-cache/save-reply ".*" \
			<save-reply-disconnected.trace &&
		test_expect_code 1 test_trace2_data fsmonitor \
			untracked-cache/saved ".*" \
			<save-reply-disconnected.trace
	) &&
	git hash-object .git/index >save-reply-index.after &&
	test_cmp save-reply-index.before save-reply-index.after
'

test_expect_success FSMONITOR_DAEMON 'untracked snapshot rejection reports only a fixed reply kind' '
	for response in miss missing binary empty
	do
		case "$response" in
		miss) reply=1 ;;
		missing) reply=2 ;;
		binary|empty) reply=3 ;;
		esac &&
		test_trace2_data fsmonitor untracked-cache/save-reply "$reply" \
			<"save-reply-$response.trace" &&
		test_trace2_data fsmonitor untracked-cache/save-reply ".*" \
			<"save-reply-$response.trace" >actual &&
		test_line_count = 1 actual &&
		test_grep "\"event\":\"data\".*\"thread\":\"main\".*\"nesting\":2," actual &&
		test_expect_code 1 grep save-reply-private-canary \
			"save-reply-$response.trace" || return 1
	done
'

test_done

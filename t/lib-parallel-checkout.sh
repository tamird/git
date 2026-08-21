# Helpers for tests invoking parallel-checkout

# Parallel checkout tests need full control of the number of workers
unset GIT_TEST_CHECKOUT_WORKERS

set_checkout_config () {
	if test $# -ne 2
	then
		BUG "usage: set_checkout_config <workers> <threshold>"
	fi &&

	test_config_global checkout.workers $1 &&
	test_config_global checkout.thresholdForParallelism $2
}

# Run "${@:2}" and check that $1 checkout workers were used
test_checkout_workers () {
	if test $# -lt 2
	then
		BUG "too few arguments to test_checkout_workers"
	fi &&

	local expected_workers="$1" &&
	shift &&

	local trace_file=trace-test-checkout-workers &&
	rm -f "$trace_file" &&
	(
		GIT_TRACE2="$(pwd)/$trace_file" &&
		export GIT_TRACE2 &&
		"$@" 2>&8
	) &&

	local workers="$(grep "child_start\[..*\] git checkout--worker" "$trace_file" | wc -l)" &&
	test $workers -eq $expected_workers &&
	rm "$trace_file"
} 8>&2 2>&4

# Select the exact worker SIDs; callers isolate each SID before checking timers.
test_checkout_worker_sids () {
	sed -n "/\"event\":\"cmd_name\".*\"name\":\"checkout--worker\"/s/.*\"sid\":\"\([^\"]*\)\".*/\1/p" \
		"$1" >worker-sids &&
	test_line_count = "$2" worker-sids &&
	sort -u worker-sids >worker-sids.sorted &&
	test_line_count = "$2" worker-sids.sorted
}

# Check one summary-only timer in an exact-SID trace.
test_checkout_content_timer () {
	local trace_file="$1" category="$2" name="$3" expected="$4" &&
	local intervals &&

	test_grep ! \
		"\"event\":\"th_timer\".*\"category\":\"$category\",\"name\":\"$name\"" \
		"$trace_file" &&
	test_grep ! \
		"\"event\":\"region_[^\"]*\".*\"category\":\"$category\",\"label\":\"$name\"" \
		"$trace_file" &&
	if test "$expected" = absent
	then
		test_grep ! \
			"\"event\":\"timer\".*\"category\":\"$category\",\"name\":\"$name\"," \
			"$trace_file"
	else
		grep \
			"\"event\":\"timer\".*\"category\":\"$category\",\"name\":\"$name\"," \
			"$trace_file" >phase-count &&
		test_line_count = 1 phase-count &&
		intervals=$(sed -n \
			"s#.*\"intervals\":\([0-9][0-9]*\),.*#\1#p" phase-count) &&
		case "$intervals" in
		""|*[!0-9]*|0*) return 1 ;;
		esac &&
		test "$intervals" = "$expected"
	fi
}

test_checkout_content_timers () {
	local trace_file="$1" pair &&
	shift &&
	for pair
	do
		set -- $pair &&
		test_checkout_content_timer "$trace_file" "$1" "$2" "$3" ||
		return 1
	done
}

# Verify that both the working tree and the index were created correctly
verify_checkout () {
	if test $# -ne 1
	then
		BUG "usage: verify_checkout <repository path>"
	fi &&

	git -C "$1" diff-index --ignore-submodules=none --exit-code HEAD -- &&
	git -C "$1" status --porcelain >"$1".status &&
	test_must_be_empty "$1".status
}

#!/bin/sh

test_description='test index-pack handling of delta cycles in packfiles'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-pack.sh

test_conclude_phase_times () {
	awk '
	function valid_data(key, line, prefix, value) {
		prefix = category "\"key\":\"" key "\",\"value\":"
		if (!index(line, "\"event\":\"data\"") || !index(line, prefix))
			return 0
		value = substr(line, index(line, prefix) + length(prefix))
		return value ~ /^"[0-9]+"}$/
	}
	BEGIN {
		category = "\"category\":\"index-pack\","
		clock_key = "input/read-wait-ns"
		fix_key = "conclude/fix-thin-us"
		finalize_key = "conclude/finalize-thin-us"
	}
	index($0, category "\"key\":\"" clock_key "\"") {
		if (clock || !valid_data(clock_key, $0))
			bad = 1
		clock = NR
	}
	index($0, category "\"key\":\"conclude/unresolved-deltas\"") {
		entry = NR
	}
	index($0, category "\"label\":\"conclude-pack\"") {
		if (index($0, "\"event\":\"region_enter\""))
			enter = NR
		if (index($0, "\"event\":\"region_leave\""))
			leave = NR
	}
	index($0, category "\"label\":\"conclude/fix-thin\"") ||
	index($0, category "\"label\":\"conclude/finalize-thin\"") {
		bad = 1
	}
	index($0, category "\"key\":\"" fix_key "\"") {
		if (fix || !valid_data(fix_key, $0))
			bad = 1
		fix = NR
	}
	index($0, category "\"key\":\"" finalize_key "\"") {
		if (finalize || !valid_data(finalize_key, $0))
			bad = 1
		finalize = NR
	}
	index($0, category "\"key\":\"conclude/appended-bases\"") {
		appended = NR
	}
	index($0, "\"event\":\"exit\"") && entry && !terminal {
		terminal = NR
	}
	END {
		if (!entry || !enter || entry >= enter ||
		    (clock && clock >= entry) ||
		    (fix && fix <= enter) ||
		    (finalize && finalize <= enter) ||
		    (fix && finalize && fix >= finalize) ||
		    (leave && ((fix && fix >= leave) || (finalize && finalize >= leave))) ||
		    (appended && ((fix && fix >= appended) || (finalize && finalize >= appended))) ||
		    (terminal && ((fix && fix >= terminal) || (finalize && finalize >= terminal))))
			bad = 1
		if (bad) {
			print "invalid thin-pack phase timing records"
			exit 1
		}
		if (clock && !fix) {
			print "missing conclude/fix-thin-us with working clock"
			exit 1
		}
		if (clock && !finalize) {
			print "missing conclude/finalize-thin-us with working clock"
			exit 1
		}
	}' "$1"
}

# Two similar-ish objects that we have computed deltas between.
A=$(test_oid packlib_7_0)
B=$(test_oid packlib_7_76)

# double-check our hand-constucted packs
test_expect_success 'index-pack works with a single delta (A->B)' '
	clear_packs &&
	{
		pack_header 2 &&
		pack_obj $A $B &&
		pack_obj $B
	} >ab.pack &&
	pack_trailer ab.pack &&
	git index-pack --stdin <ab.pack &&
	git cat-file -t $A &&
	git cat-file -t $B
'

test_expect_success 'index-pack works with a single delta (B->A)' '
	clear_packs &&
	{
		pack_header 2 &&
		pack_obj $A &&
		pack_obj $B $A
	} >ba.pack &&
	pack_trailer ba.pack &&
	git index-pack --stdin <ba.pack &&
	git cat-file -t $A &&
	git cat-file -t $B
'

test_expect_success 'index-pack detects missing base objects' '
	clear_packs &&
	{
		pack_header 1 &&
		pack_obj $A $B
	} >missing.pack &&
	pack_trailer missing.pack &&
	GIT_TRACE2_EVENT="$PWD/missing-base.trace" \
		test_must_fail git index-pack --fix-thin --stdin <missing.pack &&
	sed -n \
		-e "s#.*\"event\":\"\\(region_[a-z]*\\)\".*\"category\":\"index-pack\",\"label\":\"conclude-pack\".*#\\1 conclude-pack#p" \
		-e "s#.*\"event\":\"\\([^\"]*\\)\".*\"category\":\"index-pack\",\"key\":\"conclude/unresolved-deltas\",\"value\":\\([^,}]*\\).*#\\1 conclude/unresolved-deltas \\2#p" \
		-e "s#.*\"event\":\"\\([^\"]*\\)\".*\"category\":\"index-pack\",\"key\":\"conclude/appended-bases\",\"value\":\\([^,}]*\\).*#\\1 conclude/appended-bases \\2#p" \
		missing-base.trace >missing-base-conclude.actual &&
	cat >missing-base-conclude.expect <<-\EOF &&
	data conclude/unresolved-deltas "1"
	region_enter conclude-pack
	EOF
	test_cmp missing-base-conclude.expect missing-base-conclude.actual &&
	test_conclude_phase_times missing-base.trace &&
	test_grep ! "\"category\":\"index-pack\",\"key\":\"conclude/appended-base-" \
		missing-base.trace
'

test_expect_success 'index-pack detects REF_DELTA cycles' '
	clear_packs &&
	{
		pack_header 2 &&
		pack_obj $A $B &&
		pack_obj $B $A
	} >cycle.pack &&
	pack_trailer cycle.pack &&
	test_must_fail git index-pack --fix-thin --stdin <cycle.pack
'

test_expect_success 'failover to an object in another pack' '
	clear_packs &&
	git index-pack --stdin <ab.pack &&

	# This cycle does not fail since the existence of A & B in
	# the repo allows us to resolve the cycle.
	GIT_TRACE2_EVENT="$PWD/cycle-repair.trace" \
		git index-pack --stdin --fix-thin <cycle.pack &&
	sed -n \
		-e "s#.*\"event\":\"\\(region_[a-z]*\\)\".*\"category\":\"index-pack\",\"label\":\"conclude-pack\".*#\\1 conclude-pack#p" \
		-e "s#.*\"event\":\"\\([^\"]*\\)\".*\"category\":\"index-pack\",\"key\":\"conclude/unresolved-deltas\",\"value\":\\([^,}]*\\).*#\\1 conclude/unresolved-deltas \\2#p" \
		-e "s#.*\"event\":\"\\([^\"]*\\)\".*\"category\":\"index-pack\",\"key\":\"conclude/appended-bases\",\"value\":\\([^,}]*\\).*#\\1 conclude/appended-bases \\2#p" \
		cycle-repair.trace >cycle-repair-conclude.actual &&
	cat >cycle-repair-conclude.expect <<-\EOF &&
	data conclude/unresolved-deltas "2"
	region_enter conclude-pack
	region_leave conclude-pack
	data conclude/appended-bases "1"
	EOF
	test_cmp cycle-repair-conclude.expect cycle-repair-conclude.actual &&
	test_conclude_phase_times cycle-repair.trace
'

test_expect_success 'failover to a duplicate object in the same pack' '
	clear_packs &&
	{
		pack_header 3 &&
		pack_obj $A $B &&
		pack_obj $B $A &&
		pack_obj $A
	} >recoverable.pack &&
	pack_trailer recoverable.pack &&

	# This cycle does not fail since the existence of a full copy
	# of A in the pack allows us to resolve the cycle.
	git index-pack --fix-thin --stdin <recoverable.pack
'

test_expect_success 'index-pack works with thin pack A->B->C with B on disk' '
	git init server &&
	(
		cd server &&
		test_commit_bulk 4
	) &&

	A=$(git -C server rev-parse HEAD^{tree}) &&
	B=$(git -C server rev-parse HEAD~1^{tree}) &&
	C=$(git -C server rev-parse HEAD~2^{tree}) &&
	git -C server reset --hard HEAD~1 &&

	test-tool -C server pack-deltas --num-objects=2 >thin.pack <<-EOF &&
	REF_DELTA $A $B
	REF_DELTA $B $C
	EOF

	test "$(git -C server cat-file -s "$B")" -gt 1 &&
	test "$(git -C server cat-file -s "$C")" -gt 1 &&
	git clone "file://$(pwd)/server" client &&
	(
		cd client &&
		for cache_limit in 32m 1
		do
			GIT_TRACE2_EVENT="$PWD/thin-reuse-$cache_limit.trace" \
				git -c core.deltaBaseCacheLimit=$cache_limit \
				index-pack --fix-thin --stdin --threads=1 \
				--no-rev-index <../thin.pack \
				>"thin-reuse-$cache_limit.out" &&
			test_line_count = 1 "thin-reuse-$cache_limit.out" &&
			read thin_kind thin_hash <"thin-reuse-$cache_limit.out" &&
			test "$thin_kind" = pack &&
			thin_path=".git/objects/pack/pack-$thin_hash" &&
			cp "$thin_path.pack" "thin-reuse-$cache_limit.pack" &&
			cp "$thin_path.idx" "thin-reuse-$cache_limit.idx" &&
			git index-pack --no-rev-index \
				-o "thin-reuse-$cache_limit-reindexed.idx" \
				"thin-reuse-$cache_limit.pack" &&
			cmp "thin-reuse-$cache_limit.idx" \
				"thin-reuse-$cache_limit-reindexed.idx" &&
			for object in "$A" "$B" "$C"
			do
				git cat-file -p "$object" >actual-object &&
				git -C ../server cat-file -p "$object" >expect-object &&
				test_cmp expect-object actual-object || exit 1
			done &&
			test_trace2_data index-pack conclude/unresolved-deltas 2 \
				<"thin-reuse-$cache_limit.trace" &&
			test_trace2_data index-pack conclude/appended-bases 2 \
				<"thin-reuse-$cache_limit.trace" &&
			rm "$thin_path.pack" "$thin_path.idx" ||
			exit 1
		done &&
		test_cmp thin-reuse-32m.out thin-reuse-1.out &&
		cmp thin-reuse-32m.pack thin-reuse-1.pack &&
		cmp thin-reuse-32m.idx thin-reuse-1.idx
	) &&
	echo "repaired thin-pack stdout:" &&
	cat client/thin-reuse-32m.out &&
	for trace in cycle-repair.trace client/thin-reuse-32m.trace \
		client/thin-reuse-1.trace
	do
		echo "$trace" &&
		grep "\"category\":\"index-pack\",\"key\":\"conclude/appended-base-" "$trace" &&
		test "$(grep -c "\"category\":\"index-pack\",\"key\":\"conclude/appended-base-" "$trace")" = 2 ||
		return 1
	done &&
	# All output and repair checks precede the reconstruction witness.
	test_trace2_data index-pack conclude/appended-base-reconstructions 0 \
		<client/thin-reuse-32m.trace &&
	test_trace2_data index-pack conclude/appended-base-reuses 2 \
		<client/thin-reuse-32m.trace &&
	test_trace2_data index-pack conclude/appended-base-reconstructions "[1-9][0-9]*" \
		<client/thin-reuse-1.trace &&
	test_trace2_data index-pack conclude/appended-base-reuses 2 \
		<client/thin-reuse-1.trace &&
	test_trace2_data index-pack conclude/appended-base-reconstructions 0 \
		<cycle-repair.trace &&
	test_trace2_data index-pack conclude/appended-base-reuses 1 \
		<cycle-repair.trace
'

test_done

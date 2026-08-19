#!/bin/sh

test_description='test index-pack handling of delta cycles in packfiles'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-pack.sh

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
	test_cmp missing-base-conclude.expect missing-base-conclude.actual
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
	test_cmp cycle-repair-conclude.expect cycle-repair-conclude.actual
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

	git clone "file://$(pwd)/server" client &&
	(
		cd client &&
		git index-pack --fix-thin --stdin <../thin.pack
	)
'

test_done

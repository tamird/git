#!/bin/sh
#
# Copyright (c) 2005 Junio C Hamano
#

test_description='Same rename detection as t4003 but testing diff-raw.'


. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-diff.sh ;# test-lib chdir's into trash

test_expect_success 'setup reference tree' '
	COPYING_test_data >COPYING &&
	for name in bound-a bound-b bound-c
	do
		cp COPYING "$name" || return 1
	done &&
	cat COPYING COPYING >zz-bound &&
	echo frotz >rezrov &&
	git update-index --add COPYING bound-a bound-b bound-c rezrov zz-bound &&
	tree=$(git write-tree) &&
	echo $tree &&
	sed -e "s/HOWEVER/However/" <COPYING >COPYING.1 &&
	sed -e "s/GPL/G.P.L/g" <COPYING >COPYING.2 &&
	origoid=$(git hash-object COPYING) &&
	oid1=$(git hash-object COPYING.1) &&
	oid2=$(git hash-object COPYING.2)
'

################################################################
# tree has COPYING and rezrov.  work tree has COPYING.1 and COPYING.2,
# both are slightly edited, and unchanged rezrov.  We say COPYING.1
# and COPYING.2 are based on COPYING, and do not say anything about
# rezrov.

test_expect_success 'validate output from rename/copy detection (#1)' '
	rm -f COPYING &&
	git update-index --add --remove COPYING COPYING.? &&

	cat <<-EOF >expected &&
	:100644 100644 $origoid $oid1 C1234	COPYING	COPYING.1
	:100644 100644 $origoid $oid2 R1234	COPYING	COPYING.2
	EOF
	git diff-index -C $tree >current &&
	compare_diff_raw expected current
'

################################################################
# tree has COPYING and rezrov.  work tree has COPYING and COPYING.1,
# both are slightly edited, and unchanged rezrov.  We say COPYING.1
# is based on COPYING and COPYING is still there, and do not say anything
# about rezrov.

test_expect_success 'validate output from rename/copy detection (#2)' '
	mv COPYING.2 COPYING &&
	git update-index --add --remove COPYING COPYING.1 COPYING.2 &&

	cat <<-EOF >expected &&
	:100644 100644 $origoid $oid2 M	COPYING
	:100644 100644 $origoid $oid1 C1234	COPYING	COPYING.1
	EOF
	git diff-index -C $tree >current &&
	compare_diff_raw current expected
'

################################################################
# tree has COPYING and rezrov.  work tree has the same COPYING and
# copy-edited COPYING.1, and unchanged rezrov.  We should not say
# anything about rezrov or COPYING, since the revised again diff-raw
# nows how to say Copy.
# The unchanged bound-* sources fill the four best candidates together
# with COPYING.  The later zz-bound source passes the 50% size check, but
# its maximum possible score cannot beat those four candidates.

test_expect_success 'validate output from rename/copy detection (#3)' '
	COPYING_test_data >COPYING &&
	git update-index --add --remove COPYING COPYING.1 &&

	cat <<-EOF >expected &&
	:100644 100644 $origoid $oid1 C1234	COPYING	COPYING.1
	EOF
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_TRACE2=0 \
		git diff-index -l4 -C --find-copies-harder $tree \
			>untraced 2>untraced.err &&
	test_must_be_empty untraced.err &&
	GIT_TRACE2_EVENT="$PWD/rename-inexact.trace" \
		git diff-index -l4 -C --find-copies-harder $tree \
			>current 2>traced.err &&
	test_cmp untraced current &&
	test_cmp untraced.err traced.err &&
	compare_diff_raw current expected &&
	pair_bytes=$(($(wc -c <COPYING) + $(wc -c <COPYING.1))) &&
	compared_bytes=$((4 * pair_bytes)) &&
	test_trace2_data diff rename/inexact/sources 6 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/destinations 1 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/rename_limit 4 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/limit_result 0 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/similarity_calls 6 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/size_rejected 1 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/content_compared 4 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/compared_bytes "$compared_bytes" \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/score_bound_floor_ready 0 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/score_bound_rejectable 0 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/score_bound_rejectable_bytes \
		0 <rename-inexact.trace &&
	test_trace2_data diff rename/inexact/nonregular 0 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/population_failed 0 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/candidate_floor_skipped 1 \
		<rename-inexact.trace &&
	test "$(grep -c \
		"\"event\":\"data\".*\"category\":\"diff\",\"key\":\"rename/inexact/" \
		rename-inexact.trace)" = 14 &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"rename/populate\",\"intervals\":[1-9][0-9]*," rename-inexact.trace &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"spanhash/build\",\"intervals\":6," rename-inexact.trace &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"spanhash/compare\",\"intervals\":4," rename-inexact.trace
'

test_expect_success 'similarity timers aggregate while exit counts remain per invocation' '
	index_tree=$(git write-tree) &&
	printf "%s %s\n" "$tree" "$index_tree" >tree-pair &&
	cat tree-pair tree-pair >tree-pairs &&
	GIT_TRACE2_EVENT="$PWD/rename-single.trace" \
		git diff-tree -r -C --find-copies-harder "$tree" "$index_tree" \
			>single 2>single.err &&
	test_must_be_empty single.err &&
	compare_diff_raw single expected &&
	cat tree-pair single tree-pair single >expect-repeated &&
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	GIT_TRACE2_EVENT="$PWD/rename-repeated.trace" \
		git diff-tree --stdin -r -C --find-copies-harder \
			<tree-pairs >repeated 2>repeated.err &&
	test_cmp expect-repeated repeated &&
	test_must_be_empty repeated.err &&
	test_trace2_data diff rename/inexact/similarity_calls 6 \
		<rename-repeated.trace >calls &&
	test_line_count = 2 calls &&
	test_trace2_data diff rename/inexact/size_rejected 1 \
		<rename-repeated.trace >size-rejected &&
	test_line_count = 2 size-rejected &&
	test_trace2_data diff rename/inexact/content_compared 4 \
		<rename-repeated.trace >compared &&
	test_line_count = 2 compared &&
	test_trace2_data diff rename/inexact/candidate_floor_skipped 1 \
		<rename-repeated.trace >floor-skipped &&
	test_line_count = 2 floor-skipped &&
	test "$(grep -c \
		"\"event\":\"data\".*\"category\":\"diff\",\"key\":\"rename/inexact/" \
		rename-repeated.trace)" = 28 &&
	single_size=$(sed -n "s/.*\"name\":\"rename\/populate\/size-only-count\",\"count\":\([0-9][0-9]*\)}.*/\1/p" rename-single.trace) &&
	single_full=$(sed -n "s/.*\"name\":\"rename\/populate\/full-count\",\"count\":\([0-9][0-9]*\)}.*/\1/p" rename-single.trace) &&
	repeated_size=$(sed -n "s/.*\"name\":\"rename\/populate\/size-only-count\",\"count\":\([0-9][0-9]*\)}.*/\1/p" rename-repeated.trace) &&
	repeated_full=$(sed -n "s/.*\"name\":\"rename\/populate\/full-count\",\"count\":\([0-9][0-9]*\)}.*/\1/p" rename-repeated.trace) &&
	populate_intervals=$(sed -n "s/.*\"name\":\"rename\/populate\",\"intervals\":\([0-9][0-9]*\),.*/\1/p" rename-repeated.trace) &&
	test -n "$single_size" &&
	test -n "$single_full" &&
	test -n "$repeated_size" &&
	test -n "$repeated_full" &&
	test -n "$populate_intervals" &&
	test "$repeated_size" -eq "$((2 * single_size))" &&
	test "$repeated_full" -eq "$((2 * single_full))" &&
	test "$((repeated_size + repeated_full))" -eq "$populate_intervals" &&
	test_trace2_data diff rename/populate/valid 1 <rename-repeated.trace &&
	test_trace2_data diff rename/populate/size-only-count "$repeated_size" \
		<rename-repeated.trace &&
	test_trace2_data diff rename/populate/full-count "$repeated_full" \
		<rename-repeated.trace &&
	test_trace2_data diff rename/populate/size-only-us "[0-9][0-9]*" \
		<rename-repeated.trace &&
	test_trace2_data diff rename/populate/full-us "[0-9][0-9]*" \
		<rename-repeated.trace &&
	test "$(grep -c '\''"key":"rename/populate/'\'' rename-repeated.trace)" = 5 &&
	test_grep "\"event\":\"counter\".*\"category\":\"diff\",\"name\":\"rename/populate/size-only-ns\",\"count\":[1-9][0-9]*}" rename-repeated.trace &&
	test_grep "\"event\":\"counter\".*\"category\":\"diff\",\"name\":\"rename/populate/full-ns\",\"count\":[1-9][0-9]*}" rename-repeated.trace &&
	test_grep ! "\"event\":\"th_counter\".*\"name\":\"rename/populate/" rename-repeated.trace &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"spanhash/build\",\"intervals\":12," rename-repeated.trace &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"spanhash/compare\",\"intervals\":8," rename-repeated.trace
'

test_expect_success 'disabled and exact-only copies do not enter similarity phases' '
	printf "A\tCOPYING.1\n" >expect-added &&
	for mode in disabled exact-only
	do
		case "$mode" in
		disabled) set -- --no-renames ;;
		exact-only) set -- -C100% --find-copies-harder ;;
		esac &&
		GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_TRACE2=0 \
			git diff-index --name-status "$@" "$tree" \
				>untraced-control 2>untraced-control.err &&
		test_cmp expect-added untraced-control &&
		test_must_be_empty untraced-control.err &&
		GIT_TRACE2_EVENT="$PWD/$mode.trace" \
			git diff-index --name-status "$@" "$tree" \
				>traced-control 2>traced-control.err &&
		test_cmp untraced-control traced-control &&
		test_cmp untraced-control.err traced-control.err &&
		test_grep ! "rename/inexact/" "$mode.trace" &&
		test_grep ! "rename/populate" "$mode.trace" &&
		test_grep ! "spanhash/" "$mode.trace" ||
		return 1
	done
'

test_expect_success 'size rejection populates sizes without hashing or comparing spans' '
	printf "A\tCOPYING.1\n" >expect-size-rejected &&
	GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_TRACE2=0 \
		git diff-index --name-status -C --find-copies-harder "$tree" \
			-- rezrov COPYING.1 >untraced-size 2>untraced-size.err &&
	test_cmp expect-size-rejected untraced-size &&
	test_must_be_empty untraced-size.err &&
	GIT_TRACE2_EVENT="$PWD/rename-size.trace" \
		git diff-index --name-status -C --find-copies-harder "$tree" \
			-- rezrov COPYING.1 >traced-size 2>traced-size.err &&
	test_cmp untraced-size traced-size &&
	test_cmp untraced-size.err traced-size.err &&
	test_trace2_data diff rename/inexact/similarity_calls 1 \
		<rename-size.trace &&
	test_trace2_data diff rename/inexact/size_rejected 1 \
		<rename-size.trace &&
	test_trace2_data diff rename/inexact/content_compared 0 \
		<rename-size.trace &&
	test_trace2_data diff rename/inexact/nonregular 0 \
		<rename-size.trace &&
	test_trace2_data diff rename/inexact/population_failed 0 \
		<rename-size.trace &&
	test_trace2_data diff rename/inexact/candidate_floor_skipped 0 \
		<rename-size.trace &&
	test_grep "\"event\":\"timer\".*\"category\":\"diff\",\"name\":\"rename/populate\",\"intervals\":[1-9][0-9]*," rename-size.trace &&
	test_grep "\"event\":\"counter\".*\"category\":\"diff\",\"name\":\"rename/populate/size-only-count\",\"count\":[1-9][0-9]*}" rename-size.trace &&
	test_grep ! "\"name\":\"rename/populate/full-" rename-size.trace &&
	test_trace2_data diff rename/populate/valid 1 <rename-size.trace &&
	test_trace2_data diff rename/populate/full-count 0 <rename-size.trace &&
	test_trace2_data diff rename/populate/full-us 0 <rename-size.trace &&
	test_grep ! "spanhash/" rename-size.trace
'

test_expect_success 'a bounded ODB candidate needs no content population' '
	mv zz-bound zz-bound.saved &&
	test_when_finished "mv zz-bound.saved zz-bound" &&
	printf "C#\tCOPYING\tCOPYING.1\nD\tzz-bound\n" >expected-odb-bound &&
	GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_TRACE2=0 \
		git diff-index --name-status -l4 -C --find-copies-harder "$tree" \
			>untraced-odb-bound 2>untraced-odb-bound.err &&
	sed -e "s/^C[0-9][0-9]*	/C#	/" \
		<untraced-odb-bound >normalized-odb-bound &&
	test_cmp expected-odb-bound normalized-odb-bound &&
	test_must_be_empty untraced-odb-bound.err &&
	GIT_TRACE2_EVENT="$PWD/rename-odb-bound.trace" \
		git diff-index --name-status -l4 -C --find-copies-harder "$tree" \
			>traced-odb-bound 2>traced-odb-bound.err &&
	test_cmp untraced-odb-bound traced-odb-bound &&
	test_cmp untraced-odb-bound.err traced-odb-bound.err &&
	test_trace2_data diff rename/inexact/content_compared 4 \
		<rename-odb-bound.trace &&
	test_trace2_data diff rename/inexact/candidate_floor_skipped 1 \
		<rename-odb-bound.trace &&
	test_trace2_data diff rename/populate/full-count 5 \
		<rename-odb-bound.trace
'

test_expect_success 'inexact rename with a rehashed span table' '
	test_create_repo rehash &&
	(
		cd rehash &&
		test_seq 1 700 >source &&
		git add source &&
		git commit -m base &&
		git mv source destination &&
		sort -rn destination >reordered &&
		mv reordered destination &&
		git add destination &&
		printf "R100\tsource\tdestination\n" >expect &&
		git diff --cached --name-status -M >actual &&
		test_cmp expect actual &&
		sed "1s/.*/changed/" destination >edited &&
		mv edited destination &&
		git add destination &&
		printf "R099\tsource\tdestination\n" >expect &&
		git diff --cached --name-status -M >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'empty ODB destination size is populated once' '
	test_create_repo empty-destination &&
	(
		cd empty-destination &&
		for i in 1 2 3 4
		do
			printf "nonempty-%s\n" "$i" >"source-$i" || return 1
		done &&
		git add source-* &&
		old_tree=$(git write-tree) &&
		git rm -f -- source-* &&
		: >empty &&
		git add empty &&
		new_tree=$(git write-tree) &&
		printf "A\tempty\nD\tsource-1\nD\tsource-2\nD\tsource-3\nD\tsource-4\n" >expect &&
		GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0 GIT_TRACE2=0 \
			git diff-tree -r -M --name-status "$old_tree" "$new_tree" >untraced &&
		test_cmp expect untraced &&
		GIT_TRACE2_EVENT="$PWD/empty-destination.trace" \
			git diff-tree -r -M --name-status "$old_tree" "$new_tree" >traced &&
		test_cmp untraced traced &&
		test_trace2_data diff rename/inexact/size_rejected 4 \
			<empty-destination.trace &&
		test_trace2_data diff rename/populate/size-only-count 5 \
			<empty-destination.trace &&
		test_trace2_data diff rename/populate/full-count 0 \
			<empty-destination.trace
	)
'

test_expect_success 'inexact size sampling records packed nonzero attempts and loose winners' '
	test_create_repo sampled-size &&
	(
		cd sampled-size &&
		test_seq -f "source-%03g" 1 130 >sources &&
		while read name
		do
			test_seq 1 1200 >"$name" &&
			printf "%s\n" "$name" >>"$name" || return 1
		done <sources &&
		git add source-* &&
		git commit -qm base &&
		git repack -ad --window=250 --depth=50 &&
		git multi-pack-index write &&
		printf "loose source\n" >>source-064 &&
		git add source-064 &&
		git commit -qm loose &&
		old=$(git rev-parse HEAD) &&
		selected_oid=$(git rev-parse "$old:source-128") &&
		git verify-pack -v .git/objects/pack/*.idx >pack-info &&
		awk -v oid="$selected_oid" \
			"\$1 == oid { found++; delta = (\$2 == \"blob\" && NF == 7 && \$6 >= 1) }
			 END { exit !(found == 1 && delta) }" pack-info &&
		git rm -fq -- source-* &&
		test_seq 1 4000 >destination &&
		git add destination &&
		git commit -qm destination &&
		printf "A\tdestination\n" >expect &&
		while read name
		do
			printf "D\t%s\n" "$name" >>expect || return 1
		done <sources &&
		git diff-tree -r -M --name-status "$old" HEAD >plain &&
		test_cmp expect plain &&
		GIT_TRACE2_EVENT="$PWD/size-sample.trace" \
			git diff-tree -r -M --name-status "$old" HEAD >sampled &&
		GIT_TRACE2_EVENT="$PWD/size-disabled.trace" \
		GIT_TRACE2_RENAME_SIZE_SAMPLE=0 \
			git diff-tree -r -M --name-status "$old" HEAD >disabled &&
		test_cmp plain sampled &&
		test_cmp plain disabled &&
		test_trace2_data diff rename/inexact/size-odb-sample/stride 64 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/eligible 130 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/selected 2 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-valid 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-pairs 2 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-nonpacked 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-unknown-pack 0 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-same-pack 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-pack-switch 0 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/locality-exact-offset 0 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/counts-valid 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/winner-loose 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/winner-packed 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/packed-nonzero-attempts 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/location-valid 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/location-attempts 2 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/estimated-location-us \
			"[0-9][0-9]*" <size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/midx-valid 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/midx-search-attempts 2 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/estimated-midx-search-us \
			"[0-9][0-9]*" <size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/header-valid 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/header-attempts 1 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/base-attempts \
			1 <size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/decode-attempts \
			1 <size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/delta-cache-hits 0 \
			<size-sample.trace &&
		test_trace2_data diff rename/inexact/size-odb-sample/estimated-header-us \
			"[0-9][0-9]*" <size-sample.trace &&
		test_grep ! "size-odb-sample" size-disabled.trace
	)
'

test_done

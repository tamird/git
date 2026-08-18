#!/bin/sh
#
# Copyright (c) 2005 Junio C Hamano
#

test_description='Same rename detection as t4003 but testing diff-raw.'


. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-diff.sh ;# test-lib chdir's into trash

test_expect_success 'setup reference tree' '
	COPYING_test_data >COPYING &&
	echo frotz >rezrov &&
	git update-index --add COPYING rezrov &&
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

test_expect_success 'validate output from rename/copy detection (#3)' '
	COPYING_test_data >COPYING &&
	git update-index --add --remove COPYING COPYING.1 &&

	cat <<-EOF >expected &&
	:100644 100644 $origoid $oid1 C1234	COPYING	COPYING.1
	EOF
	GIT_TRACE2_EVENT="$PWD/rename-inexact.trace" \
		git diff-index -l4 -C --find-copies-harder $tree >current &&
	compare_diff_raw current expected &&
	compared_bytes=$(($(wc -c <COPYING) + $(wc -c <COPYING.1))) &&
	test "$(grep -c \
		"\"event\":\"data\".*\"category\":\"diff\",\"key\":\"rename/inexact/" \
		rename-inexact.trace)" = 8 &&
	test_trace2_data diff rename/inexact/sources 2 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/destinations 1 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/rename_limit 4 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/limit_result 0 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/similarity_calls 2 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/size_rejected 1 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/content_compared 1 \
		<rename-inexact.trace &&
	test_trace2_data diff rename/inexact/compared_bytes "$compared_bytes" \
		<rename-inexact.trace
'

test_done

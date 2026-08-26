#!/bin/sh
#
# Copyright (c) 2005 Junio C Hamano
#

test_description='More rename detection tests.

The rename detection logic should be able to detect pure rename or
copy of symbolic links, but should not produce rename/copy followed
by an edit for them.
'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-diff.sh

test_expect_success SYMLINKS 'prepare reference tree' '
	echo xyzzy | tr -d '\\\\'012 >yomin &&
	ln -s xyzzy frotz &&
	git update-index --add frotz yomin &&
	tree=$(git write-tree) &&
	echo $tree
'

test_expect_success SYMLINKS 'prepare work tree' '
	mv frotz rezrov &&
	rm -f yomin &&
	ln -s xyzzy nitfol &&
	ln -s xzzzy bozbar &&
	git update-index --add --remove frotz rezrov nitfol bozbar yomin
'

# tree has frotz pointing at xyzzy, and yomin that contains xyzzy to
# confuse things.  work tree has rezrov (xyzzy) nitfol (xyzzy) and
# bozbar (xzzzy).
# rezrov and nitfol are rename/copy of frotz and bozbar should be
# a new creation.

test_expect_success SYMLINKS 'setup diff output' '
	GIT_DIFF_OPTS=--unified=0 git diff-index -C -p $tree >current &&
	cat >expected <<\EOF
diff --git a/bozbar b/bozbar
new file mode 120000
--- /dev/null
+++ b/bozbar
@@ -0,0 +1 @@
+xzzzy
\ No newline at end of file
diff --git a/frotz b/nitfol
similarity index 100%
copy from frotz
copy to nitfol
diff --git a/frotz b/rezrov
similarity index 100%
rename from frotz
rename to rezrov
diff --git a/yomin b/yomin
deleted file mode 100644
--- a/yomin
+++ /dev/null
@@ -1 +0,0 @@
-xyzzy
\ No newline at end of file
EOF
'

test_expect_success SYMLINKS 'validate diff output' '
	compare_diff_patch current expected &&
	sane_unset GIT_TRACE2_EVENT_NESTING &&
	GIT_DIFF_OPTS=--unified=0 GIT_TRACE2_EVENT="$PWD/symlink.trace" \
		git diff-index -C -p $tree >traced 2>traced.err &&
	test_cmp current traced &&
	test_must_be_empty traced.err &&
	test_trace2_data diff rename/inexact/sources 2 <symlink.trace &&
	test_trace2_data diff rename/inexact/destinations 1 <symlink.trace &&
	test_trace2_data diff rename/inexact/similarity_calls 2 <symlink.trace &&
	test_trace2_data diff rename/inexact/size_rejected 0 <symlink.trace &&
	test_trace2_data diff rename/inexact/content_compared 0 <symlink.trace &&
	test_trace2_data diff rename/inexact/nonregular 2 <symlink.trace &&
	test_trace2_data diff rename/inexact/population_failed 0 <symlink.trace &&
	test_trace2_data diff rename/inexact/candidate_floor_skipped 0 <symlink.trace &&
	test_grep ! "rename/populate" symlink.trace &&
	test_grep ! "spanhash/" symlink.trace
'

test_done

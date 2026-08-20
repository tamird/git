#!/bin/sh

test_description='ls-tree --format'

. ./test-lib.sh
. "$TEST_DIRECTORY"/lib-t3100.sh

test_expect_success 'ls-tree --format usage' '
	test_expect_code 129 git ls-tree --format=fmt -l HEAD &&
	test_expect_code 129 git ls-tree --format=fmt --name-only HEAD &&
	test_expect_code 129 git ls-tree --format=fmt --name-status HEAD
'

test_expect_success 'setup' '
	setup_basic_ls_tree_data
'

test_ls_tree_long_trace () {
	ls_tree_timers=$(sed -n \
		's/.*"event":"timer".*"category":"ls-tree","name":"\([^"]*\)","intervals":\([0-9]*\),.*/\1:\2/p' "$1" |
		grep -E '^(read-tree|format-output(/(object-info|abbrev))?):' |
		sort) &&
	# The recursive fixture emits three blobs and one gitlink.
	test "$ls_tree_timers" = "format-output/abbrev:4
format-output/object-info:3
format-output:4
read-tree:1" &&
	test_grep ! '"event":"th_timer".*"category":"ls-tree"' "$1" &&
	test_grep ! '"event":"region_[^"]*".*"category":"ls-tree"' "$1"
}

test_ls_tree_format () {
	format=$1 &&
	opts=$2 &&
	fmtopts=$3 &&

	test_expect_success "ls-tree '--format=<$format>' is like options '$opts $fmtopts'" '
		if test "$opts" = "--long"
		then
			: >ls-tree-long.trace &&
			GIT_TRACE2_EVENT="$PWD/ls-tree-long.trace" \
				git ls-tree $opts -r HEAD >expect
		else
			git ls-tree $opts -r HEAD >expect
		fi &&
		git ls-tree --format="$format" -r $fmtopts HEAD >actual &&
		test_cmp expect actual &&
		if test "$opts" = "--long"
		then
			test_ls_tree_long_trace ls-tree-long.trace
		fi
	'

	test_expect_success "ls-tree '--format=<$format>' on optimized v.s. non-optimized path" '
		git ls-tree --format="$format" -r $fmtopts HEAD >expect &&
		if test "$opts" = "--long"
		then
			: >ls-tree-format-long.trace &&
			GIT_TRACE2_EVENT="$PWD/ls-tree-format-long.trace" \
				git ls-tree --format="> $format" -r $fmtopts HEAD >actual.raw
		else
			git ls-tree --format="> $format" -r $fmtopts HEAD >actual.raw
		fi &&
		sed "s/^> //" >actual <actual.raw &&
		test_cmp expect actual &&
		if test "$opts" = "--long"
		then
			test_ls_tree_long_trace ls-tree-format-long.trace
		fi
	'
}

test_expect_success "ls-tree --format='%(path) %(path) %(path)' HEAD top-file" '
	git ls-tree --format="%(path) %(path) %(path)" HEAD top-file.t >actual &&
	echo top-file.t top-file.t top-file.t >expect &&
	test_cmp expect actual
'

test_ls_tree_format \
	"%(objectmode) %(objecttype) %(objectname)%x09%(path)" \
	""

test_ls_tree_format \
	"%(objectmode) %(objecttype) %(objectname) %(objectsize:padded)%x09%(path)" \
	"--long"

test_ls_tree_format \
	"%(path)" \
	"--name-only"

test_ls_tree_format \
	"%(objectname)" \
	"--object-only"

test_ls_tree_format \
	"%(objectname)" \
	"--object-only --abbrev" \
	"--abbrev"

test_ls_tree_format \
	"%(objectmode) %(objecttype) %(objectname)%x09%(path)" \
	"-t" \
	"-t"

test_ls_tree_format \
	"%(objectmode) %(objecttype) %(objectname)%x09%(path)" \
	"--full-name" \
	"--full-name"

test_ls_tree_format \
	"%(objectmode) %(objecttype) %(objectname)%x09%(path)" \
	"--full-tree" \
	"--full-tree"

test_done

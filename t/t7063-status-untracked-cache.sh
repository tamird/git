#!/bin/sh

test_description='test untracked cache'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

# On some filesystems (e.g. FreeBSD's ext2 and ufs) directory mtime
# is updated lazily after contents in the directory changes, which
# forces the untracked cache code to take the slow path.  A test
# that wants to make sure that the fast path works correctly should
# call this helper to make mtime of the containing directory in sync
# with the reality before checking the fast path behaviour.
#
# See <20160803174522.5571-1-pclouds@gmail.com> if you want to know
# more.

GIT_FORCE_UNTRACKED_CACHE=true
export GIT_FORCE_UNTRACKED_CACHE

sync_mtime () {
	find . -type d -exec ls -ld {} + >/dev/null
}

avoid_racy() {
	sleep 1
}

status_is_clean() {
	git status --porcelain >../status.actual &&
	test_must_be_empty ../status.actual
}

# Ignore_Untracked_Cache, abbreviated to 3 letters because then people can
# compare commands side-by-side, e.g.
#    iuc status --porcelain >expect &&
#    git status --porcelain >actual &&
#    test_cmp expect actual
iuc () {
	git ls-files -s >../current-index-entries
	git ls-files -t | sed -ne s/^S.//p >../current-sparse-entries

	GIT_INDEX_FILE=.git/tmp_index
	export GIT_INDEX_FILE
	git update-index --index-info <../current-index-entries
	git update-index --skip-worktree $(cat ../current-sparse-entries)

	git -c core.untrackedCache=false "$@"
	ret=$?

	rm ../current-index-entries
	rm $GIT_INDEX_FILE
	unset GIT_INDEX_FILE

	return $ret
}

get_relevant_traces () {
	# From the GIT_TRACE2_PERF data of the form
	#    $TIME $FILE:$LINE | d0 | main | data | r1 | ? | ? | read_directo | $RELEVANT_STAT
	# extract the $RELEVANT_STAT fields.  We don't care about region_enter
	# or region_leave, or stats for things outside read_directory.
	INPUT_FILE=$1
	OUTPUT_FILE=$2
	grep data.*read_directo $INPUT_FILE |
	    cut -d "|" -f 9 |
	    grep -v -e visited -e subtrees-pruned -e subtrees-repaired \
	    >"$OUTPUT_FILE"
}


test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

if ! test_have_prereq UNTRACKED_CACHE; then
	skip_all='This system does not support untracked cache'
	test_done
fi

test_expect_success 'core.untrackedCache is unset' '
	test_must_fail git config --get core.untrackedCache
'

test_expect_success 'setup' '
	git init --template= worktree &&
	cd worktree &&
	mkdir done dtwo dthree &&
	touch one two three done/one dtwo/two dthree/three &&
	test-tool chmtime =-300 one two three done/one dtwo/two dthree/three &&
	test-tool chmtime =-300 done dtwo dthree &&
	test-tool chmtime =-300 . &&
	git add one two done/one &&
	mkdir .git/info &&
	: >.git/info/exclude &&
	git update-index --untracked-cache &&
	test_oid_cache <<-EOF
	root sha1:8510665149157c2bc901848c3e0b746954e9cbd9
	root sha256:09ef24b38105f396a61ad78d73ba6a18ee3cbd89ce4524b4e13b6c1af191e2d8

	exclude sha1:2bdf67abb163a4ffb2d7f3f0880c9fe5068ce782
	exclude sha256:b83643f4390b339c1b3ff2f5132c99bd4a77687dd321d3f386c25953aa6f1ce4

	done sha1:1946f0437f90c5005533cbe1736a6451ca301714
	done sha256:7f079501d79f665b3acc50f5e0e9e94509084d5032ac20113a37dd5029b757cc
	EOF
'

test_expect_success 'untracked cache is empty' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect-empty <<EOF &&
info/exclude $ZERO_OID
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
EOF
	test_cmp ../expect-empty ../actual
'

cat >../status.expect <<EOF &&
A  done/one
A  one
A  two
?? dthree/
?? dtwo/
?? three
EOF

cat >../dump.expect <<EOF &&
info/exclude $EMPTY_BLOB
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $ZERO_OID recurse valid
dthree/
dtwo/
three
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
three
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF

test_expect_success 'status first time (empty cache)' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:3
 ....gitignore-invalidation:1
 ....directory-invalidation:0
 ....opendir:4
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'untracked cache after first status' '
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../dump.expect ../actual
'

test_expect_success 'status second time (fully populated cache)' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:0
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'untracked cache after second status' '
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../dump.expect ../actual
'

cat >../status_uall.expect <<EOF &&
A  done/one
A  one
A  two
?? dthree/three
?? dtwo/two
?? three
EOF

# Positive results from a -unormal cache cannot serve -uall because they may
# name a collapsed directory. Without fsmonitor, negative summaries cannot be
# validated either, so this falls back to a full scan.
test_expect_success 'untracked cache falls back with -uall without fsmonitor' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status -uall --porcelain >../actual &&
	iuc status -uall --porcelain >../status.iuc &&
	test_cmp ../status_uall.expect ../status.iuc &&
	test_cmp ../status_uall.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'untracked cache remains after fallback' '
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../dump.expect ../actual
'

test_expect_success 'if -uall is configured, untracked cache gets populated by default' '
	test_config status.showuntrackedfiles all &&
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	test_cmp ../status_uall.expect ../status.iuc &&
	test_cmp ../status_uall.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:3
 ....gitignore-invalidation:1
 ....directory-invalidation:0
 ....opendir:4
EOF
	test_cmp ../trace.expect ../trace.relevant
'

cat >../dump_uall.expect <<EOF &&
info/exclude $EMPTY_BLOB
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000000
/ $ZERO_OID recurse valid
three
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse valid
three
/dtwo/ $ZERO_OID recurse valid
two
EOF

test_expect_success 'if -uall was configured, untracked cache is populated' '
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../dump_uall.expect ../actual
'

test_expect_success 'if -uall is configured, untracked cache is used by default' '
	test_config status.showuntrackedfiles all &&
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	test_cmp ../status_uall.expect ../status.iuc &&
	test_cmp ../status_uall.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:0
EOF
	test_cmp ../trace.expect ../trace.relevant
'

# Bypassing the untracked cache here is not desirable from an
# end-user perspective, but is expected in the current design.
# The untracked cache data stored for a -all run cannot be
# correctly used in a -unormal run - it would yield incorrect
# output.
test_expect_success 'if -uall is configured, untracked cache is bypassed with -unormal' '
	test_config status.showuntrackedfiles all &&
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status -unormal --porcelain >../actual &&
	iuc status -unormal --porcelain >../status.iuc &&
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'repopulate untracked cache for -unormal' '
	git status --porcelain
'

test_expect_success 'modify in root directory, one dir invalidation' '
	: >four &&
	test-tool chmtime =-240 four &&
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
A  done/one
A  one
A  two
?? dthree/
?? dtwo/
?? four
?? three
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:1
 ....opendir:1
EOF
	test_cmp ../trace.expect ../trace.relevant

'

test_expect_success 'verify untracked cache dump' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $EMPTY_BLOB
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $ZERO_OID recurse valid
dthree/
dtwo/
four
three
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
three
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'new .gitignore invalidates recursively' '
	echo four >.gitignore &&
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
A  done/one
A  one
A  two
?? .gitignore
?? dthree/
?? dtwo/
?? three
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:1
 ....directory-invalidation:1
 ....opendir:4
EOF
	test_cmp ../trace.expect ../trace.relevant

'

test_expect_success 'verify untracked cache dump' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $EMPTY_BLOB
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dthree/
dtwo/
three
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
three
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'new info/exclude invalidates everything' '
	echo three >>.git/info/exclude &&
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
A  done/one
A  one
A  two
?? .gitignore
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:1
 ....directory-invalidation:0
 ....opendir:4
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'verify untracked cache dump' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dtwo/
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'move two from tracked to untracked' '
	git rm --cached two &&
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'status after the move' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
A  done/one
A  one
?? .gitignore
?? dtwo/
?? two
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:1
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'verify untracked cache dump' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dtwo/
two
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'move two from untracked to tracked' '
	git add two &&
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'status after the move' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
A  done/one
A  one
A  two
?? .gitignore
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:1
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'verify untracked cache dump' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dtwo/
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'set up for sparse checkout testing' '
	echo two >done/.gitignore &&
	echo three >>done/.gitignore &&
	echo two >done/two &&
	git add -f done/two done/.gitignore &&
	git commit -m "first commit"
'

test_expect_success 'status after commit' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
?? .gitignore
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:2
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'untracked cache correct after commit' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dtwo/
/done/ $ZERO_OID recurse valid
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'set up sparse checkout' '
	echo "done/[a-z]*" >.git/info/sparse-checkout &&
	test_config core.sparsecheckout true &&
	git checkout main &&
	git update-index --force-untracked-cache &&
	git status --porcelain >/dev/null && # prime the cache
	test_path_is_missing done/.gitignore &&
	test_path_is_file done/one
'

test_expect_success 'create/modify files, some of which are gitignored' '
	echo two bis >done/two &&
	echo three >done/three && # three is gitignored
	echo four >done/four && # four is gitignored at a higher level
	echo five >done/five && # five is not gitignored
	test-tool chmtime =-180 done/two done/three done/four done/five done &&
	# we need to ensure that the root dir is touched (in the past);
	test-tool chmtime =-180 . &&
	sync_mtime
'

test_expect_success 'test sparse status with untracked cache' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../status.actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
 M done/two
?? .gitignore
?? done/five
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../status.actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:1
 ....directory-invalidation:2
 ....opendir:2
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'untracked cache correct after status' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dtwo/
/done/ $(test_oid done) recurse valid
five
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect ../actual
'

test_expect_success 'test sparse status again with untracked cache' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../status.actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
 M done/two
?? .gitignore
?? done/five
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../status.actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:0
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'set up for test of subdir and sparse checkouts' '
	mkdir done/sub &&
	mkdir done/sub/sub &&
	echo "sub" > done/sub/sub/file &&
	test-tool chmtime =-120 done/sub/sub/file done/sub/sub done/sub done
'

test_expect_success 'test sparse status with untracked cache and subdir' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../status.actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
 M done/two
?? .gitignore
?? done/five
?? done/sub/
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../status.actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:2
 ....gitignore-invalidation:0
 ....directory-invalidation:1
 ....opendir:3
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'verify untracked cache dump (sparse/subdirs)' '
	test-tool dump-untracked-cache >../actual &&
	cat >../expect-from-test-dump <<EOF &&
info/exclude $(test_oid exclude)
core.excludesfile $ZERO_OID
exclude_per_dir .gitignore
flags 00000006
/ $(test_oid root) recurse valid
.gitignore
dtwo/
/done/ $(test_oid done) recurse valid
five
sub/
/done/sub/ $ZERO_OID recurse check_only valid
sub/
/done/sub/sub/ $ZERO_OID recurse check_only valid
file
/dthree/ $ZERO_OID recurse check_only valid
/dtwo/ $ZERO_OID recurse check_only valid
two
EOF
	test_cmp ../expect-from-test-dump ../actual
'

test_expect_success 'test sparse status again with untracked cache and subdir' '
	: >../trace.output &&
	GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace.output" \
	git status --porcelain >../status.actual &&
	iuc status --porcelain >../status.iuc &&
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../status.actual &&
	get_relevant_traces ../trace.output ../trace.relevant &&
	cat >../trace.expect <<EOF &&
 ....path:
 ....node-creation:0
 ....gitignore-invalidation:0
 ....directory-invalidation:0
 ....opendir:0
EOF
	test_cmp ../trace.expect ../trace.relevant
'

test_expect_success 'move entry in subdir from untracked to cached' '
	git add dtwo/two &&
	git status --porcelain >../status.actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
 M done/two
A  dtwo/two
?? .gitignore
?? done/five
?? done/sub/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../status.actual
'

test_expect_success 'move entry in subdir from cached to untracked' '
	git rm --cached dtwo/two &&
	git status --porcelain >../status.actual &&
	iuc status --porcelain >../status.iuc &&
	cat >../status.expect <<EOF &&
 M done/two
?? .gitignore
?? done/five
?? done/sub/
?? dtwo/
EOF
	test_cmp ../status.expect ../status.iuc &&
	test_cmp ../status.expect ../status.actual
'

test_expect_success '--no-untracked-cache removes the cache' '
	git update-index --no-untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	echo "no untracked cache" >../expect-no-uc &&
	test_cmp ../expect-no-uc ../actual
'

test_expect_success 'git status does not change anything' '
	git status &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-no-uc ../actual
'

test_expect_success 'setting core.untrackedCache to true and using git status creates the cache' '
	git config core.untrackedCache true &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-no-uc ../actual &&
	git status &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-from-test-dump ../actual
'

test_expect_success 'using --no-untracked-cache does not fail when core.untrackedCache is true' '
	git update-index --no-untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-no-uc ../actual &&
	git update-index --untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-empty ../actual
'

test_expect_success 'setting core.untrackedCache to false and using git status removes the cache' '
	git config core.untrackedCache false &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-empty ../actual &&
	git status &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-no-uc ../actual
'

test_expect_success 'using --untracked-cache does not fail when core.untrackedCache is false' '
	git update-index --untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-empty ../actual
'

test_expect_success 'setting core.untrackedCache to keep' '
	git config core.untrackedCache keep &&
	git update-index --untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-empty ../actual &&
	git status &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-from-test-dump ../actual &&
	git update-index --no-untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-no-uc ../actual &&
	git update-index --force-untracked-cache &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-empty ../actual &&
	git status &&
	test-tool dump-untracked-cache >../actual &&
	test_cmp ../expect-from-test-dump ../actual
'

test_expect_success 'test ident field is working' '
	mkdir ../other_worktree &&
	cp -R done dthree dtwo four three ../other_worktree &&
	GIT_WORK_TREE=../other_worktree git status 2>../err &&
	echo "warning: untracked cache is disabled on this system or location" >../expect &&
	test_cmp ../expect ../err
'

test_expect_success 'untracked cache survives a checkout' '
	git commit --allow-empty -m empty &&
	test-tool dump-untracked-cache >../before &&
	test_when_finished  "git checkout main" &&
	git checkout -b other_branch &&
	test-tool dump-untracked-cache >../after &&
	test_cmp ../before ../after &&
	test_commit test &&
	test-tool dump-untracked-cache >../before &&
	git checkout main &&
	test-tool dump-untracked-cache >../after &&
	test_cmp ../before ../after
'

test_expect_success 'untracked cache survives a commit' '
	test-tool dump-untracked-cache >../before &&
	git add done/two &&
	git commit -m commit &&
	test-tool dump-untracked-cache >../after &&
	test_cmp ../before ../after
'

test_expect_success 'teardown worktree' '
	cd ..
'

test_expect_success SYMLINKS 'setup worktree for symlink test' '
	git init worktree-symlink &&
	cd worktree-symlink &&
	git config core.untrackedCache true &&
	mkdir one two &&
	touch one/file two/file &&
	git add one/file two/file &&
	git commit -m"first commit" &&
	git rm -rf one &&
	ln -s two one &&
	git add one &&
	git commit -m"second commit"
'

test_expect_success SYMLINKS '"status" after symlink replacement should be clean with UC=true' '
	git checkout HEAD~ &&
	status_is_clean &&
	status_is_clean &&
	git checkout main &&
	avoid_racy &&
	status_is_clean &&
	status_is_clean
'

test_expect_success SYMLINKS '"status" after symlink replacement should be clean with UC=false' '
	git config core.untrackedCache false &&
	git checkout HEAD~ &&
	status_is_clean &&
	status_is_clean &&
	git checkout main &&
	avoid_racy &&
	status_is_clean &&
	status_is_clean
'

test_expect_success 'setup worktree for non-symlink test' '
	git init worktree-non-symlink &&
	cd worktree-non-symlink &&
	git config core.untrackedCache true &&
	mkdir one two &&
	touch one/file two/file &&
	git add one/file two/file &&
	git commit -m"first commit" &&
	git rm -rf one &&
	cp two/file one &&
	git add one &&
	git commit -m"second commit"
'

test_expect_success '"status" after file replacement should be clean with UC=true' '
	git checkout HEAD~ &&
	status_is_clean &&
	status_is_clean &&
	git checkout main &&
	avoid_racy &&
	status_is_clean &&
	test-tool dump-untracked-cache >../actual &&
	grep -F "recurse valid" ../actual >../actual.grep &&
	cat >../expect.grep <<EOF &&
/ $ZERO_OID recurse valid
/two/ $ZERO_OID recurse valid
EOF
	status_is_clean &&
	test_cmp ../expect.grep ../actual.grep
'

test_expect_success '"status" after file replacement should be clean with UC=false' '
	git config core.untrackedCache false &&
	git checkout HEAD~ &&
	status_is_clean &&
	status_is_clean &&
	git checkout main &&
	avoid_racy &&
	status_is_clean &&
	status_is_clean
'

test_expect_success PTHREADS 'parallel cached directory validation' '
	test_create_repo parallel-validation &&
	(
		cd parallel-validation &&
		git config core.untrackedCache true &&
		mkdir one two &&
		echo ignored >.gitignore &&
		>one/ignored &&
		>two/ignored &&
		git add .gitignore &&
		git commit -m base &&
		git status --porcelain >../actual &&
		test_must_be_empty ../actual &&

		echo visible >.gitignore &&
		>two/new &&
		cat >../expect <<-\EOF &&
		 M .gitignore
		?? one/
		?? two/
		EOF
		GIT_TEST_UNTRACKED_CACHE_THREADS=1 \
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/parallel-validation.trace" \
			git status --porcelain >../actual &&
		test_cmp ../expect ../actual &&
		test_grep "parallel-lstat:[1-9]" \
			"$TRASH_DIRECTORY/parallel-validation.trace"
	)
'

test_expect_success 'empty repo (no index) and core.untrackedCache' '
	git init emptyrepo &&
	git -C emptyrepo -c core.untrackedCache=true write-tree
'

test_expect_success 'directory snapshots ignore weak file-stat configuration' '
	test_create_repo weak-dir &&
	(
		cd weak-dir &&
		mkdir nested &&
		echo tracked >tracked &&
		echo one >nested/one &&
		git add tracked &&
		git commit -m base &&
		git config core.untrackedCache true &&
		git config core.fsmonitor false &&
		git config core.trustCtime false &&
		git config core.checkStat minimal &&
		avoid_racy &&
		git status --porcelain -uall >/dev/null &&
		git status --porcelain -uall >/dev/null &&
		dir_mtime=$(test-tool chmtime --get nested) &&
		mv nested/one nested/two &&
		test-tool chmtime =$dir_mtime nested &&
		GIT_OPTIONAL_LOCKS=0 git -c core.untrackedCache=false \
			status --porcelain -uall >.git/expect &&
		git status --porcelain -uall >.git/actual &&
		test_cmp .git/expect .git/actual
	)
'

test_expect_success PTHREADS 'parallel directory snapshots ignore weak file-stat configuration' '
	(
		cd weak-dir &&
		git config status.showUntrackedFiles all &&
		git status --porcelain -uall >/dev/null &&
		git status --porcelain -uall >/dev/null &&
		dir_mtime=$(test-tool chmtime --get nested) &&
		mv nested/two nested/three &&
		test-tool chmtime =$dir_mtime nested &&
		GIT_OPTIONAL_LOCKS=0 git -c core.untrackedCache=false \
			status --porcelain -uall >.git/expect &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=1 \
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/weak-dir-parallel.trace" \
			git status --porcelain -uall >.git/actual &&
		test_cmp .git/expect .git/actual &&
		test_grep "parallel-lstat:[1-9]" \
			"$TRASH_DIRECTORY/weak-dir-parallel.trace"
	)
'

test_expect_success 'prepare production pending-cache index' '
	test_create_repo pending-cache &&
	(
		cd pending-cache &&
		git config index.version 2 &&
		git config index.skipHash false &&
		git config core.splitIndex false &&
		git config index.recordEndOfIndexEntries false &&
		git config index.recordOffsetTable false &&
		git config index.threads 1 &&
		git config core.fsmonitor false &&
		git config core.untrackedCache true &&
		mkdir -p a/deep a/loose b &&
		echo tracked >a/tracked &&
		echo tracked >a/deep/tracked &&
		echo tracked >b/tracked &&
		: >a/.gitignore &&
		git add a/tracked a/deep/tracked a/.gitignore b/tracked &&
		git commit -m base &&
		echo untracked >a/loose/one &&
		avoid_racy &&
		git status --porcelain >.git/expect &&
		git status --porcelain >.git/actual &&
		test_cmp .git/expect .git/actual &&
		cp .git/index .git/trusted &&
		test-tool dump-untracked-cache rewrite-index \
			.git/trusted .git/pending --mark-pending &&
		GIT_INDEX_FILE=.git/pending \
			test-tool dump-untracked-cache state >.git/pending-state &&
		test_grep "^pending [1-9][0-9]*\\.[0-9][0-9]*$" \
			.git/pending-state &&
		test-tool dump-untracked-cache inspect-index .git/pending \
			>.git/inventory &&
		test_grep "^UNRV [1-9]" .git/inventory &&
		test_grep ! "^UNTR " .git/inventory &&
		test_grep ! -E "^(EOIE|IEOT|link) " .git/inventory &&
		GIT_INDEX_FILE=.git/pending \
			test-tool dump-untracked-cache >.git/pending-dump &&
		test_grep "^loose/$" .git/pending-dump &&
		test_grep "^/a/deep/ .* valid$" .git/pending-dump &&
		git ls-files --stage >.git/tracked-expect
	)
'

test_expect_success 'pending stat results do not outlive one directory read' '
	test_when_finished "rm -f pending-cache/b/new" &&
	(
		cd pending-cache &&
		test_path_is_missing b/new &&
		cp .git/pending .git/twice &&
		GIT_INDEX_FILE=.git/twice \
			test-tool dump-untracked-cache state >.git/twice-state &&
		test_cmp .git/pending-state .git/twice-state &&
		GIT_INDEX_FILE=.git/twice &&
		GIT_EDITOR=: &&
		GIT_TEST_UNTRACKED_CACHE_THREADS=0 &&
		GIT_TRACE2_EVENT="$PWD/.git/twice-event" &&
		GIT_TRACE2_PERF="$PWD/.git/twice-perf" &&
		export GIT_INDEX_FILE GIT_EDITOR GIT_TEST_UNTRACKED_CACHE_THREADS \
			GIT_TRACE2_EVENT GIT_TRACE2_PERF &&
		test_must_fail git -c core.fsmonitor=false \
			-c commit.status=true \
			-c trailer.probe.cmd="echo created >b/new && test-tool chmtime +1 b && echo probe" \
			commit --edit --trailer probe=value \
			>.git/twice-out 2>.git/twice-err &&
		test_path_is_file b/new &&
		test_grep ! "b/new" .git/COMMIT_EDITMSG &&
		test_trace2_data status untracked/cache-resync 1 \
			<.git/twice-event &&
		test_trace2_data status untracked/cache-resync 0 \
			<.git/twice-event &&
		test_trace2_data status untracked/cache-use-fsmonitor 0 \
			<.git/twice-event &&
		test_grep ! "parallel-lstat:[1-9]" .git/twice-perf &&
		test_grep "b/new" .git/twice-out
	)
'

test_expect_success 'pending cache survives mandatory writes and validates' '
	(
		cd pending-cache &&
		cp .git/pending .git/roundtrip &&
		GIT_INDEX_FILE=.git/roundtrip \
			git update-index --force-write-index &&
		GIT_INDEX_FILE=.git/roundtrip \
			test-tool dump-untracked-cache state >.git/roundtrip-state &&
		test_cmp .git/pending-state .git/roundtrip-state &&
		GIT_INDEX_FILE=.git/roundtrip \
			git status --porcelain >.git/actual &&
		test_cmp .git/expect .git/actual &&
		GIT_INDEX_FILE=.git/roundtrip \
			test-tool dump-untracked-cache state >.git/roundtrip-state &&
		echo trusted >.git/trusted-state &&
		test_cmp .git/trusted-state .git/roundtrip-state
	)
'

test_expect_success 'split index keeps pending cache in the main index' '
	test_when_finished "git -C pending-cache config core.splitIndex false" &&
	(
		cd pending-cache &&
		git config core.splitIndex true &&
		cp .git/pending .git/split-pending &&
		GIT_INDEX_FILE=.git/split-pending \
			git update-index --split-index &&
		GIT_INDEX_FILE=.git/split-pending \
			test-tool dump-untracked-cache state >.git/split-state &&
		test_cmp .git/pending-state .git/split-state &&
		shared=$(GIT_INDEX_FILE=.git/split-pending \
			git rev-parse --shared-index-path) &&
		test -n "$shared" &&
		test-tool dump-untracked-cache inspect-index "$shared" \
			>.git/shared-inventory &&
		test_grep ! -E "^(UNTR|UNRV) " .git/shared-inventory &&
		GIT_INDEX_FILE=.git/split-pending \
			git update-index --force-write-index &&
		GIT_INDEX_FILE=.git/split-pending \
			test-tool dump-untracked-cache state >.git/split-state &&
		test_cmp .git/pending-state .git/split-state
	)
'

test_expect_success 'unknown optional pending signature preserves tracked index' '
	(
		cd pending-cache &&
		test-tool dump-untracked-cache rewrite-index \
			.git/pending .git/mutated --rename-pending=UXRV &&
		GIT_INDEX_FILE=.git/mutated \
			git ls-files --stage >.git/tracked-actual &&
		test_cmp .git/tracked-expect .git/tracked-actual &&
		GIT_INDEX_FILE=.git/mutated \
			test-tool dump-untracked-cache state >.git/state &&
		echo absent >.git/absent &&
		test_cmp .git/absent .git/state
	)
'

test_expect_success 'malformed or conflicting pending extensions fail closed' '
	(
		cd pending-cache &&
		for mutation in \
			--set-pending=magic:1 \
			--set-pending=version:2 \
			--set-pending=sec:0 \
			--set-pending=nsec:1000000000 \
			--set-pending=body-length:0 \
			--set-pending=body-length:4294967295 \
			--set-pending=sentinel:0 \
			--truncate-pending=0 \
			--truncate-pending=21 \
			--empty-body \
			--duplicate-pending \
			--legacy=before \
			--legacy=after
		do
			test-tool dump-untracked-cache rewrite-index \
				.git/pending .git/mutated "$mutation" &&
			GIT_INDEX_FILE=.git/mutated \
				git ls-files --stage >.git/tracked-actual &&
			test_cmp .git/tracked-expect .git/tracked-actual &&
			GIT_INDEX_FILE=.git/mutated \
				test-tool dump-untracked-cache state >.git/state &&
			test_cmp .git/absent .git/state || return 1
		done &&
		for order in before after
		do
			test-tool dump-untracked-cache rewrite-index \
				.git/pending .git/mutated \
				--set-pending=version:2 --legacy=$order &&
			GIT_INDEX_FILE=.git/mutated \
				test-tool dump-untracked-cache state >.git/state &&
			test_cmp .git/absent .git/state || return 1
		done
	)
'

test_expect_success 'pending directory topology is validated before use' '
	(
		cd pending-cache &&
		for mutation in \
			--node-name=0:nonempty \
			--node-name=1: \
			--node-name=1:. \
			--node-name=1:.. \
			--node-name=1:../outside \
			--node-name=1:.git \
			--node-name=1:a/b \
			--siblings=0:duplicate \
			--siblings=0:reverse
		do
			test-tool dump-untracked-cache rewrite-index \
				.git/pending .git/mutated "$mutation" &&
			GIT_INDEX_FILE=.git/mutated \
				test-tool dump-untracked-cache state >.git/state &&
			test_cmp .git/pending-state .git/state &&
			GIT_INDEX_FILE=.git/mutated \
				git status --porcelain >.git/actual &&
			test_cmp .git/expect .git/actual &&
			GIT_INDEX_FILE=.git/mutated \
				test-tool dump-untracked-cache state >.git/state &&
			test_cmp .git/absent .git/state || return 1
		done
	)
'

test_expect_success MINGW 'pending topology rejects Windows path aliases' '
	(
		cd pending-cache &&
		for mutation in \
			"--node-name=1:C:escape" \
			"--node-name=1:a\\b" \
			"--node-name=1:git~1"
		do
			test-tool dump-untracked-cache rewrite-index \
				.git/pending .git/mutated "$mutation" &&
			GIT_INDEX_FILE=.git/mutated \
				git -c core.protectNTFS=true status --porcelain \
				>.git/actual &&
			test_cmp .git/expect .git/actual &&
			GIT_INDEX_FILE=.git/mutated \
				test-tool dump-untracked-cache state >.git/state &&
			test_cmp .git/absent .git/state || return 1
		done
	)
'

test_expect_success 'pending validation accepts an empty indexed ignore blob' '
	test_when_finished "git -C pending-cache checkout-index -f a/.gitignore" &&
	(
		cd pending-cache &&
		cp .git/pending .git/empty-ignore &&
		GIT_INDEX_FILE=.git/empty-ignore \
			git update-index --skip-worktree a/.gitignore &&
		rm a/.gitignore &&
		GIT_INDEX_FILE=.git/empty-ignore \
			git status --porcelain >.git/actual &&
		test_cmp .git/expect .git/actual &&
		GIT_INDEX_FILE=.git/empty-ignore \
			test-tool dump-untracked-cache state >.git/state &&
		test_cmp .git/trusted-state .git/state &&
		git checkout-index -f a/.gitignore
	)
'

test_expect_success 'indeterminate indexed ignores retain pending state' '
	test_when_finished "git -C pending-cache checkout-index -f a/.gitignore" &&
	(
		cd pending-cache &&
		missing=$(echo missing-ignore | git hash-object --stdin) &&
		wrong_type=$(git write-tree) &&
		for oid in "$missing" "$wrong_type"
		do
			cp .git/pending .git/unknown-ignore &&
			GIT_INDEX_FILE=.git/unknown-ignore \
				git update-index --info-only \
				--cacheinfo 100644,$oid,a/.gitignore &&
			GIT_INDEX_FILE=.git/unknown-ignore \
				git update-index --skip-worktree a/.gitignore &&
			rm -f a/.gitignore &&
			GIT_INDEX_FILE=.git/unknown-ignore GIT_OPTIONAL_LOCKS=0 \
				git -c core.untrackedCache=false status --porcelain \
				>.git/unknown-expect &&
			GIT_INDEX_FILE=.git/unknown-ignore \
				git status --porcelain >.git/actual &&
			test_cmp .git/unknown-expect .git/actual &&
			GIT_INDEX_FILE=.git/unknown-ignore \
				test-tool dump-untracked-cache state >.git/state &&
			test_cmp .git/pending-state .git/state || return 1
		done &&
		git checkout-index -f a/.gitignore
	)
'

test_expect_success SANITY 'unreadable ignore retains pending state' '
	test_when_finished "chmod 600 pending-cache/a/.gitignore" &&
	(
		cd pending-cache &&
		cp .git/pending .git/unreadable-ignore &&
		chmod 000 a/.gitignore &&
		GIT_INDEX_FILE=.git/unreadable-ignore GIT_OPTIONAL_LOCKS=0 \
			git -c core.untrackedCache=false status --porcelain \
			>.git/unknown-expect &&
		GIT_INDEX_FILE=.git/unreadable-ignore \
			git status --porcelain >.git/actual &&
		test_cmp .git/unknown-expect .git/actual &&
		GIT_INDEX_FILE=.git/unreadable-ignore \
			test-tool dump-untracked-cache state >.git/state &&
		test_cmp .git/pending-state .git/state
	)
'

test_expect_success 'pending validation stops at unsafe ancestors' '
	test_when_finished "test ! -f pending-cache/.git/outside/deep/.gitignore ||
		chmod 600 pending-cache/.git/outside/deep/.gitignore" &&
	test_when_finished "if test -d pending-cache/.git/saved-a; then
		rm -f pending-cache/a &&
		mv pending-cache/.git/saved-a pending-cache/a
	fi" &&
	(
		cd pending-cache &&
		mkdir -p .git/outside/deep &&
		echo "*" >.git/outside/deep/.gitignore &&
		echo outside >.git/outside/deep/never-visit &&
		if test_have_prereq SANITY
		then
			chmod 000 .git/outside/deep/.gitignore &&
			GIT_OPTIONAL_LOCKS=0 git -c core.untrackedCache=false \
				-c core.excludesFile="$PWD/.git/outside/deep/.gitignore" \
				status --porcelain >.git/access-control-out \
				2>.git/access-control-err &&
			test_grep "unable to access" .git/access-control-err
		fi &&
		mv a .git/saved-a &&
		for kind in file symlink
		do
			if test "$kind" = symlink && ! test_have_prereq SYMLINKS
			then
				continue
			fi &&
			if test "$kind" = symlink
			then
				ln -s "$PWD/.git/outside" a
			else
				echo replacement >a
			fi &&
			GIT_INDEX_FILE=.git/pending GIT_OPTIONAL_LOCKS=0 \
				git -c core.untrackedCache=false status --porcelain \
				>.git/unsafe-expect &&
			cp .git/pending .git/unsafe-serial &&
			GIT_INDEX_FILE=.git/unsafe-serial \
				git status --porcelain >.git/actual \
				2>.git/unsafe-err &&
			test_cmp .git/unsafe-expect .git/actual &&
			test_grep ! "unable to access" .git/unsafe-err &&
			if test_have_prereq PTHREADS
			then
				cp .git/pending .git/unsafe-parallel &&
				GIT_INDEX_FILE=.git/unsafe-parallel \
				GIT_TEST_UNTRACKED_CACHE_THREADS=1 \
				GIT_TRACE2_PERF="$PWD/.git/unsafe-perf" \
					git status --porcelain >.git/actual \
					2>.git/unsafe-err &&
				test_cmp .git/unsafe-expect .git/actual &&
				test_grep ! "unable to access" .git/unsafe-err &&
				test_grep "parallel-lstat:[1-9]" .git/unsafe-perf
			fi &&
			rm a || return 1
		done &&
		mv .git/saved-a a
	)
'

test_expect_success 'pending validation uses the original index cutoff' '
	(
		cd pending-cache &&
		git config core.trustCtime false &&
		git config core.checkStat minimal &&
		git config core.excludesFile "$PWD/.git/cutoff-excludes" &&
		echo one >.git/cutoff-excludes &&
		echo one >one &&
		echo two >two &&
		now=$(test-tool chmtime --get .git/index) &&
		cutoff=$((now - 20)) &&
		racy=$((cutoff + 1)) &&
		test-tool chmtime =$racy a .git/cutoff-excludes &&
		git status --porcelain >.git/cutoff-before &&
		git status --porcelain >.git/cutoff-before &&
		cp .git/index .git/cutoff-trusted &&
		test-tool chmtime =$cutoff .git/cutoff-trusted &&
		test-tool dump-untracked-cache rewrite-index \
			.git/cutoff-trusted .git/cutoff-pending --mark-pending &&
		GIT_INDEX_FILE=.git/cutoff-pending \
			test-tool dump-untracked-cache >.git/cutoff-dump &&
		test_grep "^/a/ .* valid$" .git/cutoff-dump &&
		GIT_INDEX_FILE=.git/cutoff-pending \
			test-tool dump-untracked-cache state >.git/cutoff-state &&
		echo "pending $cutoff.000000000" >.git/cutoff-expect &&
		test_cmp .git/cutoff-expect .git/cutoff-state &&
		cp .git/cutoff-pending .git/cutoff-global &&
		GIT_INDEX_FILE=.git/cutoff-pending \
			git update-index --force-write-index &&
		GIT_INDEX_FILE=.git/cutoff-pending \
			test-tool dump-untracked-cache state >.git/cutoff-state &&
		test_cmp .git/cutoff-expect .git/cutoff-state &&
		GIT_INDEX_FILE=.git/cutoff-pending \
			git status --porcelain -- b >.git/actual &&
		test_must_be_empty .git/actual &&
		GIT_INDEX_FILE=.git/cutoff-pending \
			test-tool dump-untracked-cache >.git/cutoff-dump &&
		test_grep "^/a/ " .git/cutoff-dump &&
		test_grep ! "^/a/ .* valid$" .git/cutoff-dump &&
		echo two >.git/cutoff-excludes &&
		test-tool chmtime =$racy .git/cutoff-excludes &&
		GIT_INDEX_FILE=.git/cutoff-global GIT_OPTIONAL_LOCKS=0 \
			git -c core.untrackedCache=false status --porcelain \
			>.git/cutoff-expect &&
		GIT_INDEX_FILE=.git/cutoff-global \
			git status --porcelain >.git/actual &&
		test_cmp .git/cutoff-expect .git/actual &&
		test_grep "^?? one$" .git/actual &&
		test_grep ! "^?? two$" .git/actual
	)
'

test_expect_success 'successful commits respect disabled optional cache publication' '
	test_when_finished "git -C pending-cache config index.skipHash false" &&
	(
		cd pending-cache &&
		git config index.skipHash true &&
		cp .git/pending .git/commit-no-optional &&
		echo optional-disabled >b/tracked &&
		GIT_INDEX_FILE=.git/commit-no-optional \
			git add b/tracked &&
		GIT_INDEX_FILE=.git/commit-no-optional \
			test-tool scrap-cache-tree &&
		echo "$ZERO_OID" >.git/commit-zero-hash &&
		test_trailing_hash .git/commit-no-optional \
			>.git/commit-before-hash &&
		test_cmp .git/commit-zero-hash .git/commit-before-hash &&
		GIT_INDEX_FILE=.git/commit-no-optional \
			test-tool dump-untracked-cache state \
			>.git/commit-before-state &&
		test_cmp .git/pending-state .git/commit-before-state &&
		GIT_INDEX_FILE=.git/commit-no-optional \
		GIT_TRACE2_EVENT="$PWD/.git/commit-no-optional.trace" \
			git --no-optional-locks -c core.editor=true \
			-c commit.status=true commit --edit \
			-m "pending cache without optional publication" &&
		test_trace2_data status untracked/cache-resync 1 \
			<.git/commit-no-optional.trace &&
		sed -n "/\"category\":\"status\",\"key\":\"untracked\\/cache-resync\",\"value\":\"1\"/q;p" \
			.git/commit-no-optional.trace \
			>.git/commit-no-optional-before-status &&
		root_sid=$(sed -n "1s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" \
			.git/commit-no-optional.trace) &&
		test -n "$root_sid" &&
		grep -F "\"sid\":\"$root_sid\"" \
			.git/commit-no-optional-before-status \
			>.git/commit-no-optional-root-before-status &&
		changed_mask=$(
			test_trace2_data index write/changed_mask "[0-9][0-9]*" \
				<.git/commit-no-optional-root-before-status |
			sed -n "s/.*\"value\":\"\\([0-9][0-9]*\\)\".*/\\1/p"
		) &&
		case "$changed_mask" in
		""|*[!0-9]*) return 1 ;;
		esac &&
		test "$((changed_mask & 32))" -ne 0 &&
		echo optional-disabled >.git/commit-content-expect &&
		git show HEAD:b/tracked >.git/commit-content-actual &&
		test_cmp .git/commit-content-expect \
			.git/commit-content-actual &&
		test_trailing_hash .git/commit-no-optional \
			>.git/commit-after-hash &&
		test_cmp .git/commit-zero-hash .git/commit-after-hash &&
		GIT_INDEX_FILE=.git/commit-no-optional \
			test-tool dump-untracked-cache state \
			>.git/commit-after-state &&
		test_cmp .git/pending-state .git/commit-after-state
	)
'

test_expect_success 'successful commits publish recovered hashless index caches' '
	test_when_finished "git -C pending-cache config index.skipHash false" &&
	(
		cd pending-cache &&
		git config index.skipHash true &&
		cp .git/pending .git/commit-publish &&
		echo optional-published >b/tracked &&
		GIT_INDEX_FILE=.git/commit-publish \
			git add b/tracked &&
		GIT_INDEX_FILE=.git/commit-publish \
			test-tool scrap-cache-tree &&
		echo "$ZERO_OID" >.git/commit-zero-hash &&
		test_trailing_hash .git/commit-publish \
			>.git/commit-before-hash &&
		test_cmp .git/commit-zero-hash .git/commit-before-hash &&
		GIT_INDEX_FILE=.git/commit-publish \
			test-tool dump-untracked-cache state \
			>.git/commit-before-state &&
		test_cmp .git/pending-state .git/commit-before-state &&
		GIT_INDEX_FILE=.git/commit-publish \
		GIT_TRACE2_EVENT="$PWD/.git/commit-publish.trace" \
			git -c core.editor=true -c commit.status=true \
			commit --edit -m "publish recovered pending cache" &&
		test_trace2_data status untracked/cache-resync 1 \
			<.git/commit-publish.trace &&
		sed -n "/\"category\":\"status\",\"key\":\"untracked\\/cache-resync\",\"value\":\"1\"/q;p" \
			.git/commit-publish.trace \
			>.git/commit-publish-before-status &&
		root_sid=$(sed -n "1s/.*\"sid\":\"\\([^\"]*\\)\".*/\\1/p" \
			.git/commit-publish.trace) &&
		test -n "$root_sid" &&
		grep -F "\"sid\":\"$root_sid\"" \
			.git/commit-publish-before-status \
			>.git/commit-publish-root-before-status &&
		changed_mask=$(
			test_trace2_data index write/changed_mask "[0-9][0-9]*" \
				<.git/commit-publish-root-before-status |
			sed -n "s/.*\"value\":\"\\([0-9][0-9]*\\)\".*/\\1/p"
		) &&
		case "$changed_mask" in
		""|*[!0-9]*) return 1 ;;
		esac &&
		test "$((changed_mask & 32))" -ne 0 &&
		echo optional-published >.git/commit-content-expect &&
		git show HEAD:b/tracked >.git/commit-content-actual &&
		test_cmp .git/commit-content-expect \
			.git/commit-content-actual &&
		test_trailing_hash .git/commit-publish \
			>.git/commit-after-hash &&
		test_cmp .git/commit-zero-hash .git/commit-after-hash &&
		GIT_INDEX_FILE=.git/commit-publish \
			test-tool dump-untracked-cache state \
			>.git/commit-after-state &&
		test_cmp .git/trusted-state .git/commit-after-state &&
		GIT_INDEX_FILE=.git/commit-publish \
			test-tool dump-untracked-cache >.git/commit-published-cache &&
		test_grep "^/a/deep/ .* valid$" .git/commit-published-cache &&
		GIT_INDEX_FILE=.git/commit-publish \
		GIT_TRACE2_EVENT="$PWD/.git/commit-warm.trace" \
			git status --porcelain >.git/commit-warm-out &&
		test_trace2_data status untracked/cache-resync 0 \
			<.git/commit-warm.trace &&
		test_trace2_data status untracked/cache-root-valid 1 \
			<.git/commit-warm.trace
	)
'

test_done

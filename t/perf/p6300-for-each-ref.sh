#!/bin/sh

test_description='performance of ref iteration users'
. ./perf-lib.sh

test_perf_fresh_repo

ref_count_per_type=10000
test_iteration_count=10

test_expect_success "setup" '
	test_commit_bulk $(( 1 + $ref_count_per_type )) &&

	# Create refs
	test_seq $ref_count_per_type |
		sed "s,.*,update refs/heads/branch_& HEAD~&\nupdate refs/custom/special_& HEAD~&," |
		git update-ref --stdin &&

	# Create annotated tags
	for i in $(test_seq $ref_count_per_type)
	do
		# Base tags
		echo "tag tag_$i" &&
		echo "mark :$i" &&
		echo "from HEAD~$i" &&
		printf "tagger %s <%s> %s\n" \
			"$GIT_COMMITTER_NAME" \
			"$GIT_COMMITTER_EMAIL" \
			"$GIT_COMMITTER_DATE" &&
		echo "data <<EOF" &&
		echo "tag $i" &&
		echo "EOF" &&

		# Nested tags
		echo "tag nested_$i" &&
		echo "from :$i" &&
		printf "tagger %s <%s> %s\n" \
			"$GIT_COMMITTER_NAME" \
			"$GIT_COMMITTER_EMAIL" \
			"$GIT_COMMITTER_DATE" &&
		echo "data <<EOF" &&
		echo "nested tag $i" &&
		echo "EOF" || return 1
	done | git fast-import
'

test_for_each_ref () {
	title="for-each-ref"
	if test $# -gt 0; then
		title="$title ($1)"
		shift
	fi
	args="$@"

	test_perf "$title" "
		for i in \$(test_seq $test_iteration_count); do
			git for-each-ref $args >/dev/null
		done
	"
}

run_tests () {
	test_for_each_ref "$1"
	test_for_each_ref "$1, no sort" --no-sort
	test_for_each_ref "$1, --count=1" --count=1
	test_for_each_ref "$1, --count=1, no sort" --no-sort --count=1
	test_for_each_ref "$1, tags" refs/tags/
	test_for_each_ref "$1, tags, no sort" --no-sort refs/tags/
	test_for_each_ref "$1, tags, dereferenced" '--format="%(refname) %(objectname) %(*objectname)"' refs/tags/
	test_for_each_ref "$1, tags, dereferenced, no sort" --no-sort '--format="%(refname) %(objectname) %(*objectname)"' refs/tags/

	test_perf "for-each-ref ($1, tags) + cat-file --batch-check (dereferenced)" "
		for i in \$(test_seq $test_iteration_count); do
			git for-each-ref --format='%(objectname)^{} %(refname) %(objectname)' refs/tags/ | \
				git cat-file --batch-check='%(objectname) %(rest)' >/dev/null
		done
	"
}

run_tests "loose"
test_for_each_ref "loose, direct refs" refs/heads/ refs/custom/

test_perf "log --decorate with one ref (loose, no graph)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/branch_1 --max-count=1 >/dev/null
	done
"

test_perf "log --decorate with many commit refs (loose, no graph)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/ --max-count=1 >/dev/null
	done
"

test_expect_success 'write split commit graph' '
	git commit-graph write --split=no-merge --reachable &&
	tip=$(git commit-tree HEAD^{tree} -p HEAD) &&
	echo "$tip" | git commit-graph write --split=no-merge --stdin-commits &&
	tip=$(git commit-tree HEAD^{tree} -p "$tip") &&
	echo "$tip" | git commit-graph write --split=no-merge --stdin-commits &&
	test_line_count = 3 \
		.git/objects/info/commit-graphs/commit-graph-chain
'

test_perf "log --decorate with one graph commit ref (loose)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/branch_1 --max-count=1 >/dev/null
	done
"

test_perf "log --decorate with many graph commit refs (loose)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/ --max-count=1 >/dev/null
	done
"

test_perf "log --decorate with many annotated tags (loose)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/tags/ --max-count=1 >/dev/null
	done
"

test_expect_success 'pack refs' '
	git pack-refs --all
'
run_tests "packed"

test_perf "log --decorate with one graph commit ref (packed)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/branch_1 --max-count=1 >/dev/null
	done
"

test_perf "log --decorate with many graph commit refs (packed)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/ --max-count=1 >/dev/null
	done
"

test_perf "log --decorate with many annotated tags (packed)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/tags/ --max-count=1 >/dev/null
	done
"

test_perf "log --decorate with many graph commit refs (packed, full history)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/ --format=%H%x20%D >/dev/null
	done
"

test_perf "log --decorate with one ref (packed, full history)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=HEAD --format=%H%x20%D >/dev/null
	done
"

test_expect_success 'setup post-graph branch refs' '
	post_graph=$(echo post-graph | git commit-tree HEAD^{tree} -p HEAD) &&
	test_seq $ref_count_per_type |
	sed "s,.*,update refs/heads/post-graph/branch_& $post_graph," |
	git update-ref --stdin &&
	git pack-refs --all
'

test_perf "log --decorate with many post-graph refs (packed)" "
	for i in \$(test_seq $test_iteration_count); do
		git log --decorate --decorate-refs=refs/heads/post-graph/ \
			--max-count=1 >/dev/null
	done
"

test_expect_success 'setup many unrelated refs' '
	git init scoped &&
	test_commit -C scoped --no-tag base &&
	test_seq $ref_count_per_type |
		sed "s,.*,update refs/custom/unrelated_& HEAD," |
		git -C scoped update-ref --stdin &&
	git -C scoped update-ref refs/remotes/origin/main HEAD &&
	git -C scoped update-ref refs/tags/only HEAD
'

test_perf "branch (many unrelated refs)" "
	(
		cd scoped &&
		for i in \$(test_seq $test_iteration_count); do
			git branch --format='%(refname)' >/dev/null
		done
	)
"

test_perf "branch --remotes (many unrelated refs)" "
	(
		cd scoped &&
		for i in \$(test_seq $test_iteration_count); do
			git branch --remotes --format='%(refname)' >/dev/null
		done
	)
"

test_perf "tag (many unrelated refs)" "
	(
		cd scoped &&
		for i in \$(test_seq $test_iteration_count); do
			git tag --format='%(refname)' >/dev/null
		done
	)
"

test_done

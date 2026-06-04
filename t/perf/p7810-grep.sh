#!/bin/sh

test_description="git-grep performance in various modes"

. ./perf-lib.sh

test_perf_large_repo
test_checkout_worktree

test_expect_success 'select a tracked file' '
	tracked_file=$(git ls-files | sed -n 1p) &&
	test -n "$tracked_file" &&
	test_export tracked_file
'

test_perf 'grep --cached, fixed string in one file' '
	git grep --cached --quiet -F some_nonexistent_string \
		-- "$tracked_file" || :
'

grep_pattern="__git_perf_absent_$$"
test_export grep_pattern

test_lazy_prereq UTF8_LOCALE '
	case "$(LC_ALL=en_US.UTF-8 locale charmap 2>/dev/null)" in
	UTF-8|UTF8)
		true
		;;
	*)
		false
		;;
	esac
'

test_expect_success 'setup literal alternatives files' '
	test-tool genrandom literal-alternatives 4m \
		>literal-alternatives-binary &&
	test_seq 1 262144 >literal-alternatives-numbers &&
	sed "s/.*/static return/" <literal-alternatives-numbers \
		>literal-alternatives-text
'

test_perf 'grep --no-index, literal alternatives, binary file' \
	--prereq UTF8_LOCALE '
	test_expect_code 1 env LC_ALL=en_US.UTF-8 \
		git grep --threads=1 --no-index -E \
		"definitely_missing_one|definitely_missing_two" \
		-- literal-alternatives-binary >/dev/null
'

test_perf 'grep --no-index, literal alternatives, UTF-8 text' \
	--prereq UTF8_LOCALE '
	LC_ALL=en_US.UTF-8 git grep --threads=1 --no-index -E \
		"return|static" -- literal-alternatives-text >/dev/null
'

test_perf 'grep worktree, cheap regex' '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep "$grep_pattern"
'
test_perf 'grep worktree, cheap regex, 1 thread' '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep --threads=1 "$grep_pattern"
'
test_perf 'grep worktree, cheap regex, 8 threads' --prereq PTHREADS '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep --threads=8 "$grep_pattern"
'
test_perf 'grep worktree, expensive regex' '
	test_expect_code 1 git -c grep.worktreeBlobCache=false \
		grep "^.* *$grep_pattern$"
'
test_perf 'grep --cached, cheap regex' '
	test_expect_code 1 git grep --cached "$grep_pattern"
'
test_perf 'grep --cached, expensive regex' '
	test_expect_code 1 git grep --cached "^.* *$grep_pattern$"
'

test_expect_success 'setup fsmonitor' '
	hooks=$(git rev-parse --git-path hooks) &&
	mkdir -p "$hooks" &&
	write_script "$hooks/fsmonitor-empty" <<-\EOF &&
	printf "last_update_token\0"
	EOF
	git config core.fsmonitor "$hooks/fsmonitor-empty" &&
	git config grep.worktreeBlobCache true &&
	git update-index --fsmonitor &&
	git status --porcelain >/dev/null &&
	worktree_cache=$(git rev-parse --git-path index).grep-worktree &&
	rm -f "$worktree_cache" worktree-cache-trace &&
	test_expect_code 1 "$MODERN_GIT" grep --threads=1 \
		"$grep_pattern" >/dev/null &&
	test_path_is_file "$worktree_cache" &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/worktree-cache-trace" \
		"$MODERN_GIT" grep --threads=1 "$grep_pattern" >/dev/null &&
	test_grep \
		"\"key\":\"worktree_blob/hits\",\"value\":\"[1-9][0-9]*\"" \
		worktree-cache-trace &&
	rm -f "$worktree_cache" worktree-cache-trace &&
	test_export worktree_cache
'

test_perf 'grep worktree cache, first scan' \
	--setup 'rm -f "$worktree_cache"' '
	test_expect_code 1 git grep --threads=1 "$grep_pattern"
'

test_perf 'grep worktree cache, first scan, 8 threads' \
	--prereq PTHREADS --setup 'rm -f "$worktree_cache"' '
	test_expect_code 1 git grep --threads=8 "$grep_pattern"
'

test_perf 'grep worktree cache, second scan, 1 thread' \
	--setup '
		rm -f "$worktree_cache" &&
		test_expect_code 1 git grep --threads=1 \
			"$grep_pattern" >/dev/null
	' '
	test_expect_code 1 git grep --threads=1 "$grep_pattern"
'

test_perf 'grep worktree cache, second scan, 8 threads' \
	--prereq PTHREADS --setup '
		rm -f "$worktree_cache" &&
		test_expect_code 1 git grep --threads=1 \
			"$grep_pattern" >/dev/null
	' '
	test_expect_code 1 git grep --threads=8 "$grep_pattern"
'

test_expect_success 'setup threaded --quiet fixture' '
	"$MODERN_GIT" init -q quiet &&
	hit=$(printf "threaded-quiet-hit\n" |
		"$MODERN_GIT" -C quiet hash-object -w --stdin) &&
	miss=$(printf "threaded-quiet-miss\n" |
		"$MODERN_GIT" -C quiet hash-object -w --stdin) &&
	{
		printf "100644 %s\t!00000-hit.txt\n" "$hit" &&
		test_seq -f "100644 $miss\tfile%05g.txt" 1 50000
	} | "$MODERN_GIT" -C quiet update-index --index-info
'

test_perf 'grep --cached, threaded early --quiet hit' \
	--prereq PTHREADS '
	git -C quiet grep --cached --threads=8 --fixed-strings --quiet \
		threaded-quiet-hit
'

test_perf 'grep --cached, threaded --quiet miss' --prereq PTHREADS '
	test_must_fail git -C quiet grep --cached --threads=8 \
		--fixed-strings --quiet threaded-quiet-absent
'

test_perf_fresh_repo repeated

test_expect_success 'setup repeated revision grep' '
	test_seq 1 131072 >repeated/shared &&
	git -C repeated add shared &&
	git -C repeated commit -m base &&
	test_commit_bulk -C repeated --filename=other \
		--contents=unchanged --notick 256 &&
	git -C repeated rev-list --max-count=256 HEAD >repeated-revisions
'

test_perf 'grep repeated revisions, no match, 1 thread' '
	git -C repeated grep --threads=1 not-in-shared \
		$(cat repeated-revisions) -- shared >/dev/null || :
'

test_perf 'grep repeated revisions, no match, 8 threads' \
	--prereq PTHREADS '
	git -C repeated grep --threads=8 not-in-shared \
		$(cat repeated-revisions) -- shared >/dev/null || :
'

test_perf 'grep repeated revisions, matching, 1 thread' '
	git -C repeated grep --threads=1 131072 \
		$(cat repeated-revisions) -- shared >/dev/null
'

test_done

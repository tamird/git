#!/bin/sh

test_description='Diff-index performance with fsmonitor-valid entries'

. ./perf-lib.sh

test_perf_fresh_repo

test_expect_success 'setup 100,000-file worktree' '
	write_script generate-index <<-\EOF &&
		awk -v oid="$1" '\''
			BEGIN {
				for (directory = 0; directory < 100; directory++)
					for (file = 0; file < 1000; file++)
						printf "100644 %s\td%03d/file%04d\n",
							oid, directory, file
			}
		'\'' </dev/null
	EOF
	empty_blob=$(git hash-object -w --stdin </dev/null) &&
	./generate-index "$empty_blob" |
	git update-index --index-info &&
	mkdir a-early copy-source &&
	echo base >a-early/file &&
	echo unique-copy-source >copy-source/file &&
	git add a-early/file copy-source/file &&
	tree=$(git write-tree) &&
	commit=$(echo base | git commit-tree "$tree") &&
	git update-ref HEAD "$commit" &&
	git checkout-index --all &&
	write_script .git/hooks/fsmonitor-empty <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-dirty
		then
			while read path
			do
				printf "%s\0" "$path"
			done <.git/fsmonitor-dirty
		fi
	EOF
	git config core.fsmonitor .git/hooks/fsmonitor-empty &&
	git update-index --fsmonitor &&
	# The first refresh establishes the hook token.
	git status --short &&
	git status --short &&
	git ls-files -f >flags &&
	test_line_count = 100002 flags &&
	test $(grep -c "^h " flags) = 100002
'

test_perf 'diff-index: pathspec' '
	git diff --name-only HEAD -- d050 >/dev/null
'

test_perf 'diff-index: --quiet clean worktree' '
	git diff --quiet HEAD
'

test_expect_success 'setup early staged file' '
	echo staged >a-early/file &&
	git -c core.fsmonitor= add a-early/file &&
	: >.git/fsmonitor-dirty &&
	git status --short &&
	test_must_fail git diff --cached --quiet HEAD &&
	git ls-files -f >flags &&
	test $(grep -c "^h " flags) = 100002
'

test_perf 'diff-index: --quiet early staged file' '
	test_must_fail git diff --quiet HEAD
'

test_expect_success 'setup staged copy' '
	git reset --hard HEAD &&
	mkdir copy-target &&
	cp copy-source/file copy-target/file &&
	git add copy-target/file &&
	: >.git/fsmonitor-dirty &&
	git status --short &&
	git ls-files -f copy-source/file >flags &&
	test_grep "^h copy-source/file$" flags
'

test_perf 'diff-index: --find-copies-harder' '
	git diff -C --find-copies-harder --name-status HEAD >/dev/null
'

test_done

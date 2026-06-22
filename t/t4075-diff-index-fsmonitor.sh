#!/bin/sh

test_description='diff-index with fsmonitor-valid entries'

. ./test-lib.sh

test_expect_success SYMLINKS 'trust valid path behind leading symlink' '
	test_create_repo repo &&
	mkdir repo/tracked repo/target &&
	echo content >repo/tracked/file &&
	cp repo/tracked/file repo/target/file &&
	git -C repo add . &&
	git -C repo commit -m base &&
	test_hook -C repo --setup fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
	EOF
	git -C repo config core.fsmonitor .git/hooks/fsmonitor-test &&
	git -C repo update-index --fsmonitor &&
	git -C repo status --short &&
	git -C repo ls-files -f tracked/file >actual.fsmonitor &&
	test_grep "^h tracked/file$" actual.fsmonitor &&
	rm -rf repo/tracked &&
	ln -s target repo/tracked &&
	git -C repo diff --name-status HEAD >actual &&
	test_must_be_empty actual
'

test_done

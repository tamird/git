#!/bin/sh

test_description='git status with file system watcher'

. ./test-lib.sh

# Note, after "git reset --hard HEAD" no extensions exist other than 'TREE'
# "git update-index --fsmonitor" can be used to get the extension written
# before testing the results.

clean_repo () {
	git reset --hard HEAD &&
	git clean -fd
}

dirty_repo () {
	: >untracked &&
	: >dir1/untracked &&
	: >dir2/untracked &&
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	echo 4 >new &&
	echo 5 >dir1/new &&
	echo 6 >dir2/new
}

write_integration_script () {
	test_hook --setup --clobber fsmonitor-test<<-\EOF
	if test "$#" -ne 2
	then
		echo "$0: exactly 2 arguments expected"
		exit 2
	fi
	if test "$1" != 2
	then
		echo "Unsupported core.fsmonitor hook version." >&2
		exit 1
	fi
	printf "last_update_token\0"
	printf "untracked\0"
	printf "dir1/untracked\0"
	printf "dir2/untracked\0"
	printf "modified\0"
	printf "dir1/modified\0"
	printf "dir2/modified\0"
	printf "new\0"
	printf "dir1/new\0"
	printf "dir2/new\0"
	EOF
}

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

# Test that we detect and disallow repos that are incompatible with FSMonitor.
test_expect_success 'incompatible bare repo' '
	test_when_finished "rm -rf ./bare-clone actual expect" &&
	git init --bare bare-clone &&

	test_must_fail \
		git -C ./bare-clone -c core.fsmonitor=foo \
			update-index --fsmonitor 2>actual &&
	grep "bare repository .* is incompatible with fsmonitor" actual &&

	test_must_fail \
		git -C ./bare-clone -c core.fsmonitor=true \
			update-index --fsmonitor 2>actual &&
	grep "bare repository .* is incompatible with fsmonitor" actual
'

test_expect_success FSMONITOR_DAEMON 'run fsmonitor-daemon in bare repo' '
	test_when_finished "rm -rf ./bare-clone actual" &&
	git init --bare bare-clone &&
	test_must_fail git -C ./bare-clone fsmonitor--daemon run 2>actual &&
	grep "bare repository .* is incompatible with fsmonitor" actual
'

test_expect_success MINGW,FSMONITOR_DAEMON 'run fsmonitor-daemon in virtual repo' '
	test_when_finished "rm -rf ./fake-virtual-clone actual" &&
	git init fake-virtual-clone &&
	test_must_fail git -C ./fake-virtual-clone \
			   -c core.virtualfilesystem=true \
			   fsmonitor--daemon run 2>actual &&
	grep "virtual repository .* is incompatible with fsmonitor" actual
'

test_expect_success 'setup' '
	: >tracked &&
	: >modified &&
	mkdir dir1 &&
	: >dir1/tracked &&
	: >dir1/modified &&
	mkdir dir2 &&
	: >dir2/tracked &&
	: >dir2/modified &&
	git -c core.fsmonitor= add . &&
	git -c core.fsmonitor= commit -m initial &&
	git config core.fsmonitor .git/hooks/fsmonitor-test &&
	cat >.gitignore <<-\EOF
	.gitignore
	expect*
	actual*
	marker*
	trace2*
	EOF
'

test_expect_success 'diff-index honors fsmonitor validity' '
	test_when_finished "rm -rf diff-index" &&
	test_create_repo diff-index &&
	mkdir diff-index/clean diff-index/dirty &&
	echo clean >diff-index/clean/file &&
	echo base >diff-index/dirty/file &&
	git -C diff-index add . &&
	git -C diff-index commit -m base &&
	printf "tip \n" >diff-index/dirty/file &&
	git -C diff-index commit -am tip &&
	test_hook -C diff-index --setup fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-dirty
		then
			while read path
			do
				printf "%s\0" "$path"
			done <.git/fsmonitor-dirty
		fi
	EOF
	git -C diff-index config core.fsmonitor .git/hooks/fsmonitor-test &&
	git -C diff-index update-index --fsmonitor &&
	git -C diff-index status --short &&
	git -C diff-index ls-files -f >actual.fsmonitor &&
	grep "^h clean/file$" actual.fsmonitor &&
	grep "^h dirty/file$" actual.fsmonitor &&

	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff --name-status HEAD^ >expect &&
	git -C diff-index diff --name-status HEAD^ >actual &&
	test_cmp expect actual &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff --stat --numstat HEAD^ >expect &&
	git -C diff-index diff --stat --numstat HEAD^ >actual &&
	test_cmp expect actual &&
	test_must_fail git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff --check HEAD^ >expect &&
	test_must_fail git -C diff-index diff --check HEAD^ >actual &&
	test_cmp expect actual &&

	echo staged >diff-index/clean/file &&
	git -c core.fsmonitor= -C diff-index add clean/file &&
	git -C diff-index status --short &&
	git -C diff-index ls-files -f >actual.fsmonitor &&
	grep "^h clean/file$" actual.fsmonitor &&
	grep "^h dirty/file$" actual.fsmonitor &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff-index -c HEAD^ >expect &&
	git -C diff-index diff-index -c HEAD^ >actual &&
	test_cmp expect actual &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff-index --cc HEAD^ >expect &&
	git -C diff-index diff-index --cc HEAD^ >actual &&
	test_cmp expect actual &&

	echo worktree-after-staged >diff-index/clean/file &&
	echo clean/file >diff-index/.git/fsmonitor-dirty &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&

	git -C diff-index reset --hard HEAD &&
	echo worktree >diff-index/dirty/file &&
	echo dirty/file >diff-index/.git/fsmonitor-dirty &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&

	git -C diff-index reset --hard HEAD &&
	rm diff-index/clean/file &&
	echo clean/file >diff-index/.git/fsmonitor-dirty &&
	git -c core.fsmonitor= -c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual
'

test_expect_success SYMLINKS 'diff-index handles reported leading symlink' '
	test_when_finished "rm -rf diff-index-symlink" &&
	test_create_repo diff-index-symlink &&
	mkdir diff-index-symlink/clean &&
	echo clean >diff-index-symlink/clean/file &&
	git -C diff-index-symlink add . &&
	git -C diff-index-symlink commit -m base &&
	test_hook -C diff-index-symlink --setup fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-dirty
		then
			while read path
			do
				printf "%s\0" "$path"
			done <.git/fsmonitor-dirty
		fi
	EOF
	git -C diff-index-symlink config core.fsmonitor \
		.git/hooks/fsmonitor-test &&
	git -C diff-index-symlink update-index --fsmonitor &&
	git -C diff-index-symlink status --short &&
	git -C diff-index-symlink ls-files -f clean/file >actual.fsmonitor &&
	grep "^h clean/file$" actual.fsmonitor &&
	mkdir diff-index-symlink/link-target &&
	cp diff-index-symlink/clean/file diff-index-symlink/link-target/file &&
	rm -rf diff-index-symlink/clean &&
	ln -s link-target diff-index-symlink/clean &&
	echo clean/ >diff-index-symlink/.git/fsmonitor-dirty &&
	test_must_fail git -C diff-index-symlink diff --exit-code HEAD >actual &&
	grep "^deleted file mode" actual
'

# test that the fsmonitor extension is off by default
test_expect_success 'fsmonitor extension is off by default' '
	test-tool dump-fsmonitor >actual &&
	grep "^no fsmonitor" actual
'

# test that "update-index --fsmonitor" adds the fsmonitor extension
test_expect_success 'update-index --fsmonitor" adds the fsmonitor extension' '
	git update-index --fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	grep "^fsmonitor last update" actual
'

# test that "update-index --no-fsmonitor" removes the fsmonitor extension
test_expect_success 'update-index --no-fsmonitor" removes the fsmonitor extension' '
	git update-index --no-fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	grep "^no fsmonitor" actual
'

cat >expect <<EOF &&
h dir1/modified
H dir1/tracked
h dir2/modified
H dir2/tracked
h modified
H tracked
EOF

# test that "update-index --fsmonitor-valid" sets the fsmonitor valid bit
test_expect_success 'update-index --fsmonitor-valid" sets the fsmonitor valid bit' '
	test_hook fsmonitor-test<<-\EOF &&
		printf "last_update_token\0"
	EOF
	git update-index --fsmonitor &&
	git update-index --fsmonitor-valid dir1/modified &&
	git update-index --fsmonitor-valid dir2/modified &&
	git update-index --fsmonitor-valid modified &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
H dir1/tracked
H dir2/modified
H dir2/tracked
H modified
H tracked
EOF

# test that "update-index --no-fsmonitor-valid" clears the fsmonitor valid bit
test_expect_success 'update-index --no-fsmonitor-valid" clears the fsmonitor valid bit' '
	git update-index --no-fsmonitor-valid dir1/modified &&
	git update-index --no-fsmonitor-valid dir2/modified &&
	git update-index --no-fsmonitor-valid modified &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
H dir1/tracked
H dir2/modified
H dir2/tracked
H modified
H tracked
EOF

# test that all files returned by the script get flagged as invalid
test_expect_success 'all files returned by integration script get flagged as invalid' '
	write_integration_script &&
	dirty_repo &&
	git update-index --fsmonitor &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/new
H dir1/tracked
H dir2/modified
h dir2/new
H dir2/tracked
H modified
h new
H tracked
EOF

# test that newly added files are marked valid
test_expect_success 'newly added files are marked valid' '
	test_hook --setup --clobber fsmonitor-test<<-\EOF &&
		printf "last_update_token\0"
	EOF
	git add new &&
	git add dir1/new &&
	git add dir2/new &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/new
h dir1/tracked
H dir2/modified
h dir2/new
h dir2/tracked
H modified
h new
h tracked
EOF

# test that all unmodified files get marked valid
test_expect_success 'all unmodified files get marked valid' '
	# modified files result in update-index returning 1
	test_must_fail git update-index --refresh --force-write-index &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/tracked
h dir2/modified
h dir2/tracked
h modified
h tracked
EOF

# test that *only* files returned by the integration script get flagged as invalid
test_expect_success '*only* files returned by the integration script get flagged as invalid' '
	test_hook --clobber fsmonitor-test<<-\EOF &&
	printf "last_update_token\0"
	printf "dir1/modified\0"
	EOF
	clean_repo &&
	git update-index --refresh --force-write-index &&
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	test_must_fail git update-index --refresh --force-write-index &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

# Ensure commands that call refresh_index() to move the index back in time
# properly invalidate the fsmonitor cache
test_expect_success 'refresh_index() invalidates fsmonitor cache' '
	clean_repo &&
	dirty_repo &&
	write_integration_script &&
	git add . &&
	test_hook --clobber fsmonitor-test<<-\EOF &&
	EOF
	git commit -m "to reset" &&
	git reset HEAD~1 &&
	git status >actual &&
	git -c core.fsmonitor= status >expect &&
	test_cmp expect actual
'

# test fsmonitor with and without preloadIndex
preload_values="false true"
for preload_val in $preload_values
do
	test_expect_success "setup preloadIndex to $preload_val" '
		git config core.preloadIndex $preload_val &&
		if test $preload_val = true
		then
			GIT_TEST_PRELOAD_INDEX=$preload_val && export GIT_TEST_PRELOAD_INDEX
		else
			sane_unset GIT_TEST_PRELOAD_INDEX
		fi
	'

	# test fsmonitor with and without the untracked cache (if available)
	uc_values="false"
	test_have_prereq UNTRACKED_CACHE && uc_values="false true"
	for uc_val in $uc_values
	do
		test_expect_success "setup untracked cache to $uc_val" '
			git config core.untrackedcache $uc_val
		'

		# Status is well tested elsewhere so we'll just ensure that the results are
		# the same when using core.fsmonitor.
		test_expect_success 'compare status with and without fsmonitor' '
			write_integration_script &&
			clean_repo &&
			dirty_repo &&
			git add new &&
			git add dir1/new &&
			git add dir2/new &&
			git status >actual &&
			git -c core.fsmonitor= status >expect &&
			test_cmp expect actual
		'

		# Make sure it's actually skipping the check for modified and untracked
		# (if enabled) files unless it is told about them.
		test_expect_success "status doesn't detect unreported modifications" '
			test_hook --clobber fsmonitor-test<<-\EOF &&
			printf "last_update_token\0"
			:>marker
			EOF
			clean_repo &&
			git status &&
			test_path_is_file marker &&
			dirty_repo &&
			rm -f marker &&
			git status >actual &&
			test_path_is_file marker &&
			test_grep ! "Changes not staged for commit:" actual &&
			if test $uc_val = true
			then
				test_grep ! "Untracked files:" actual
			fi &&
			if test $uc_val = false
			then
				test_grep "Untracked files:" actual
			fi &&
			rm -f marker
		'
	done
done

# test that splitting the index doesn't interfere
test_expect_success 'splitting the index results in the same state' '
	write_integration_script &&
	dirty_repo &&
	git update-index --fsmonitor  &&
	git ls-files -f >expect &&
	test-tool dump-fsmonitor >&2 && echo &&
	git -c index.skipHash=true update-index --fsmonitor --split-index &&
	test-tool dump-fsmonitor >&2 && echo &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE 'ignore .git changes when invalidating UNTR' '
	test_create_repo dot-git &&
	(
		cd dot-git &&
		: >tracked &&
		test-tool chmtime =-60 tracked &&
		: >modified &&
		test-tool chmtime =-60 modified &&
		mkdir dir1 &&
		: >dir1/tracked &&
		test-tool chmtime =-60 dir1/tracked &&
		: >dir1/modified &&
		test-tool chmtime =-60 dir1/modified &&
		mkdir dir2 &&
		: >dir2/tracked &&
		test-tool chmtime =-60 dir2/tracked &&
		: >dir2/modified &&
		test-tool chmtime =-60 dir2/modified &&
		write_integration_script &&
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git update-index --untracked-cache &&
		git update-index --fsmonitor &&
		git status &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-before" \
		git status &&
		test-tool dump-untracked-cache >../before
	) &&
	cat >>dot-git/.git/hooks/fsmonitor-test <<-\EOF &&
	printf ".git\0"
	printf ".git/index\0"
	printf "dir1/.git\0"
	printf "dir1/.git/index\0"
	EOF
	(
		cd dot-git &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-after" \
		git status &&
		test-tool dump-untracked-cache >../after
	) &&
	grep "directory-invalidation" trace-before | cut -d"|" -f 9 >>before &&
	grep "directory-invalidation" trace-after  | cut -d"|" -f 9 >>after &&
	# UNTR extension unchanged, dir invalidation count unchanged
	test_cmp before after
'

test_expect_success UNTRACKED_CACHE 'skip traversal of empty untracked cache' '
	test_create_repo empty-untracked &&
	(
		cd empty-untracked &&
		mkdir -p dir1/dir2 dir3/dir4 &&
		: >dir1/dir2/tracked &&
		: >dir3/dir4/tracked &&
		echo ignored >.gitignore &&
		: >ignored &&
		git add . &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-empty" \
			git status --porcelain >../actual &&
		test_must_be_empty ../actual
	) &&
	test_grep "directories-visited:0" trace-empty &&
	test_grep "subtrees-pruned:1" trace-empty
'

test_expect_success UNTRACKED_CACHE 'reload partially invalid empty cache' '
	test_create_repo empty-untracked-all &&
	(
		cd empty-untracked-all &&
		mkdir -p dir1/dir2 &&
		: >dir1/dir2/tracked &&
		git add . &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git config status.showUntrackedFiles all &&
		git status --porcelain &&
		git rm --cached dir1/dir2/tracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-partial" \
			git status --porcelain >../actual
	) &&
	cat >expect <<-\EOF &&
	D  dir1/dir2/tracked
	?? dir1/dir2/tracked
	EOF
	test_cmp expect actual &&
	test_grep ! "directories-visited:0" trace-partial
'

test_expect_success UNTRACKED_CACHE 'fsmonitor invalidates empty untracked cache' '
	(
		cd empty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "untracked\0"
		EOF
		: >untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-untracked" \
			git status --porcelain >../actual
	) &&
	echo "?? untracked" >expect &&
	test_cmp expect actual &&
	test_grep ! "directories-visited:0" trace-untracked
'

test_expect_success UNTRACKED_CACHE 'replay non-empty untracked cache' '
	(
		cd empty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-replay" \
			git status --porcelain >../actual
	) &&
	echo "?? untracked" >expect &&
	test_cmp expect actual &&
	test_grep ! "directories-visited:0" trace-replay &&
	test_grep "opendir:0" trace-replay
'

test_expect_success UNTRACKED_CACHE 'prune empty subtrees around cached result' '
	test_create_repo nonempty-untracked &&
	(
		cd nonempty-untracked &&
		mkdir -p ignored-only/sub left/a results/c right/b &&
		echo ignored-only/ >.gitignore &&
		: >ignored-only/sub/ignored &&
		: >left/a/tracked &&
		: >results/c/tracked &&
		: >right/b/tracked &&
		git add . &&
		git commit -m initial &&
		: >results/c/untracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-prune-live" \
			git -c core.ignorecase=true status --porcelain &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-prune" \
			git -c core.ignorecase=true status --porcelain >../actual
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "name-hash-init" trace-prune-live &&
	test_grep "subtrees-pruned:[1-9]" trace-prune &&
	test_grep "opendir:0" trace-prune &&
	test_grep ! "name-hash-init" trace-prune
'

test_expect_success UNTRACKED_CACHE 'invalidate one prunable subtree' '
	(
		cd nonempty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "left/a/tracked\0"
		EOF
		touch left/a/tracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-subtree" \
			git status --porcelain >../actual
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-subtree
'

test_expect_success UNTRACKED_CACHE 're-prune rescanned empty subtree' '
	(
		cd nonempty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-reprune" \
			git status --porcelain >../actual
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-reprune &&
	test_grep "opendir:0" trace-reprune
'

test_expect_success UNTRACKED_CACHE 'retain pruned subtree across index write' '
	(
		cd nonempty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "right/b/tracked\0"
		EOF
		touch right/b/tracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-retained" \
			git status --porcelain >../actual
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-retained
'

test_expect_success UNTRACKED_CACHE 'reload retained prunable subtree' '
	(
		cd nonempty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-reloaded" \
			git status --porcelain >../actual
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-reloaded &&
	test_grep "opendir:0" trace-reloaded
'

test_expect_success UNTRACKED_CACHE 'set up subtree pruning with -uall' '
	test_create_repo prune-uall &&
	(
		cd prune-uall &&
		mkdir -p left/a results/c right/b &&
		: >left/a/tracked &&
		: >results/c/tracked &&
		: >right/b/tracked &&
		git add . &&
		git commit -m initial &&
		: >results/c/one &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git config status.showUntrackedFiles all &&
		git status --porcelain >../actual
	) &&
	echo "?? results/c/one" >expect &&
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE '-uall invalidates summary ancestors' '
	(
		cd prune-uall &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "left/a/two\0"
		EOF
		: >left/a/two &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-uall-left" \
			git status --porcelain >../actual
	) &&
	cat >expect <<-\EOF &&
	?? left/a/two
	?? results/c/one
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-uall-left
'

test_expect_success UNTRACKED_CACHE '-uall reloads summary invalidation' '
	(
		cd prune-uall &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "right/b/three\0"
		EOF
		: >right/b/three &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-uall-right" \
			git status --porcelain >../actual
	) &&
	cat >expect <<-\EOF &&
	?? left/a/two
	?? results/c/one
	?? right/b/three
	EOF
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE 'failed fsmonitor scans empty cache' '
	(
		cd empty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "untracked\0"
		EOF
		rm untracked &&
		git status --porcelain >../actual &&
		test_must_be_empty ../actual &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			exit 1
		EOF
		: >fallback &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-fallback" \
			git status --porcelain >../actual
	) &&
	echo "?? fallback" >expect &&
	test_cmp expect actual &&
	test_grep ! "directories-visited:0" trace-fallback
'

test_expect_success UNTRACKED_CACHE 'index-backed ignore disables shortcut' '
	test_create_repo index-ignore &&
	(
		cd index-ignore &&
		mkdir dir &&
		echo ignored >dir/.gitignore &&
		: >dir/tracked &&
		: >dir/ignored &&
		git add dir/.gitignore dir/tracked &&
		git commit -m initial &&
		git update-index --skip-worktree dir/.gitignore &&
		rm dir/.gitignore &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../actual &&
		test_must_be_empty ../actual &&
		empty=$(git hash-object -w --stdin </dev/null) &&
		git update-index --cacheinfo 100644,$empty,dir/.gitignore &&
		git update-index --skip-worktree dir/.gitignore &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-index-ignore-ls-files" \
			git ls-files --others --exclude-standard >../actual-ls-files &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-index-ignore" \
			git status --porcelain >../actual
	) &&
	cat >expect <<-\EOF &&
	M  dir/.gitignore
	?? dir/ignored
	EOF
	test_cmp expect actual &&
	echo dir/ignored >expect-ls-files &&
	test_cmp expect-ls-files actual-ls-files &&
	test_grep ! "directories-visited:0" trace-index-ignore &&
	test_grep "subtrees-pruned:0" trace-index-ignore-ls-files &&
	test_grep "directories-visited:[1-9]" trace-index-ignore-ls-files
'

test_expect_success UNTRACKED_CACHE 'prune pathspec status with fsmonitor' '
	test_create_repo pathspec-untracked &&
	(
		cd pathspec-untracked &&
		mkdir -p left/a results/c right/b &&
		: >left/a/tracked &&
		: >results/c/tracked &&
		: >right/b/tracked &&
		git add . &&
		git commit -m initial &&
		: >results/c/untracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			if test -f .git/fsmonitor-fail
			then
				exit 1
			fi
			printf "last_update_token\0"
			if test -f .git/fsmonitor-dirty
			then
				while read path
				do
					printf "%s\0" "$path"
				done <.git/fsmonitor-dirty
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec" \
			git status --porcelain -- "*untracked" >../actual
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-pathspec
'

test_expect_success UNTRACKED_CACHE 'pathspec invalidation preserves cache' '
	(
		cd pathspec-untracked &&
		: >left/a/matching &&
		echo left/a/matching >.git/fsmonitor-dirty &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec-dirty" \
			git status --porcelain -- "*matching" >../actual &&
		git status --porcelain >../actual-full
	) &&
	echo "?? left/a/matching" >expect &&
	test_cmp expect actual &&
	cat >expect-full <<-\EOF &&
	?? left/a/matching
	?? results/c/untracked
	EOF
	test_cmp expect-full actual-full &&
	test_grep "subtrees-pruned:[1-9]" trace-pathspec-dirty
'

test_expect_success UNTRACKED_CACHE 'pathspec falls back without fsmonitor' '
	(
		cd pathspec-untracked &&
		: >.git/fsmonitor-fail &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec-fallback" \
			git status --porcelain -- "*missing" >../actual
	) &&
	test_must_be_empty actual &&
	test_grep "directories-visited:[1-9]" trace-pathspec-fallback &&
	test_grep "subtrees-pruned:0" trace-pathspec-fallback
'

test_expect_success UNTRACKED_CACHE 'pathspec falls back with skip-worktree' '
	(
		cd pathspec-untracked &&
		rm .git/fsmonitor-fail &&
		git update-index --skip-worktree left/a/tracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec-skip" \
			git status --porcelain -- "*missing" >../actual
	) &&
	test_must_be_empty actual &&
	test_grep "directories-visited:[1-9]" trace-pathspec-skip &&
	test_grep "subtrees-pruned:0" trace-pathspec-skip
'

test_expect_success UNTRACKED_CACHE 'set up full untracked pruning' '
	test_create_repo full-untracked &&
	(
		cd full-untracked &&
		mkdir -p clean/a ignored-only/sub quiet/b results &&
		echo ignored-only/ >.gitignore &&
		: >clean/a/tracked &&
		: >ignored-only/sub/ignored &&
		: >quiet/b/tracked &&
		git add . &&
		git commit -m initial &&
		: >results/one &&
		: >results/two &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			if test -f .git/fsmonitor-fail
			then
				exit 1
			fi
			printf "last_update_token\0"
			if test -f .git/fsmonitor-dirty
			then
				while read path
				do
					printf "%s\0" "$path"
				done <.git/fsmonitor-dirty
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../actual
	) &&
	echo "?? results/" >expect &&
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE 'prune full status from normal cache' '
	(
		cd full-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-status-full" \
			git status --porcelain -uall >../actual
	) &&
	cat >expect <<-\EOF &&
	?? results/one
	?? results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-status-full &&
	test_grep "directories-visited:[1-9]" trace-status-full
'

test_expect_success UNTRACKED_CACHE 'prune ls-files from normal cache' '
	(
		cd full-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-full" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-full &&
	test_grep "directories-visited:[1-9]" trace-ls-files-full
'

test_expect_success UNTRACKED_CACHE 'ls-files without excludes scans all' '
	(
		cd full-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-no-exclude" \
			git ls-files --others >../actual
	) &&
	cat >expect <<-\EOF &&
	ignored-only/sub/ignored
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-ls-files-no-exclude &&
	test_grep "directories-visited:[1-9]" trace-ls-files-no-exclude
'

test_expect_success UNTRACKED_CACHE 'ls-files with excludes scans all' '
	(
		cd full-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-exclude" \
			git ls-files --others --exclude-standard \
				--exclude="results/*" \
				--exclude="!results/two" >../actual
	) &&
	echo results/two >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-ls-files-exclude &&
	test_grep "directories-visited:[1-9]" trace-ls-files-exclude
'

test_expect_success UNTRACKED_CACHE 'ls-files honors fsmonitor invalidation' '
	(
		cd full-untracked &&
		: >clean/a/new &&
		echo clean/a/new >.git/fsmonitor-dirty &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-dirty" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	clean/a/new
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-dirty &&
	test_grep "directories-visited:[1-9]" trace-ls-files-dirty
'

test_expect_success UNTRACKED_CACHE 'ls-files falls back after fsmonitor failure' '
	(
		cd full-untracked &&
		: >fallback &&
		: >.git/fsmonitor-fail &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-fallback" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	clean/a/new
	fallback
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-ls-files-fallback &&
	test_grep "directories-visited:[1-9]" trace-ls-files-fallback
'

test_expect_success UNTRACKED_CACHE 'ls-files validates standard excludes' '
	test_create_repo info-exclude-prune &&
	(
		cd info-exclude-prune &&
		mkdir -p clean hidden-core hidden-info &&
		: >clean/tracked &&
		git add clean/tracked &&
		git commit -m initial &&
		echo hidden-info/ >.git/info/exclude &&
		echo hidden-core/ >.git/core-exclude &&
		git config core.excludesFile "$PWD/.git/core-exclude" &&
		: >hidden-core/untracked &&
		: >hidden-info/untracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../actual &&
		test_must_be_empty ../actual &&
		: >.git/info/exclude &&
		: >.git/core-exclude &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-info-exclude" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	hidden-core/untracked
	hidden-info/untracked
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-info-exclude &&
	test_grep "directories-visited:[1-9]" trace-info-exclude
'

test_expect_success UNTRACKED_CACHE 'ls-files prunes all-mode cache' '
	test_create_repo ls-files-uall-cache &&
	(
		cd ls-files-uall-cache &&
		mkdir -p clean/a quiet/b results &&
		: >clean/a/tracked &&
		: >quiet/b/tracked &&
		git add . &&
		git commit -m initial &&
		: >results/one &&
		: >results/two &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git config status.showUntrackedFiles all &&
		git status --porcelain >../actual &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-uall-cache" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-uall-cache &&
	test_grep "directories-visited:[1-9]" trace-ls-files-uall-cache &&
	# Prune-only detaches the cache, so replay statistics are absent.
	test_grep ! "opendir:" trace-ls-files-uall-cache
'

test_expect_success 'discard_index() also discards fsmonitor info' '
	test_config core.fsmonitor "$TEST_DIRECTORY/t7519/fsmonitor-all" &&
	test_might_fail git update-index --refresh &&
	test-tool read-cache --print-and-refresh=tracked 2 >actual &&
	printf "tracked is%s up to date\n" "" " not" >expect &&
	test_cmp expect actual
'

# Test unstaging entries that:
#  - Are not flagged with CE_FSMONITOR_VALID
#  - Have a position in the index >= the number of entries present in the index
#    after unstaging.
test_expect_success 'status succeeds after staging/unstaging' '
	test_create_repo fsmonitor-stage-unstage &&
	(
		cd fsmonitor-stage-unstage &&
		test_commit initial &&
		git update-index --fsmonitor &&
		removed=$(test_seq 1 100 | sed "s/^/z/") &&
		touch $removed &&
		git add $removed &&
		git config core.fsmonitor "$TEST_DIRECTORY/t7519/fsmonitor-env" &&
		FSMONITOR_LIST="$removed" git restore -S $removed &&
		FSMONITOR_LIST="$removed" git status
	)
'

# Usage:
# check_sparse_index_behavior [!]
# If "!" is supplied, then we verify that we do not call ensure_full_index
# during a call to 'git status'. Otherwise, we verify that we _do_ call it.
check_sparse_index_behavior () {
	git -C full status --porcelain=v2 >expect &&
	GIT_TRACE2_EVENT="$(pwd)/trace2.txt" \
		git -C sparse status --porcelain=v2 >actual &&
	test_region $1 index ensure_full_index trace2.txt &&
	test_region fsm_hook query trace2.txt &&
	test_cmp expect actual &&
	rm trace2.txt
}

test_expect_success 'status succeeds with sparse index' '
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&

		git clone . full &&
		git clone --sparse . sparse &&
		git -C sparse sparse-checkout init --cone --sparse-index &&
		git -C sparse sparse-checkout set dir1 dir2 &&

		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git -C full config core.fsmonitor ../.git/hooks/fsmonitor-test &&
		git -C sparse config core.fsmonitor ../.git/hooks/fsmonitor-test &&
		check_sparse_index_behavior ! &&

		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "dir1/modified\0"
		EOF
		check_sparse_index_behavior ! &&

		git -C sparse sparse-checkout add dir1a &&

		for repo in full sparse
		do
			cp -r $repo/dir1 $repo/dir1a &&
			git -C $repo add dir1a &&
			git -C $repo commit -m "add dir1a" || return 1
		done &&
		git -C sparse sparse-checkout set dir1 dir2 &&

		# This one modifies outside the sparse-checkout definition
		# and hence we expect to expand the sparse-index.
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "dir1a/modified\0"
		EOF
		check_sparse_index_behavior
	)
'

test_done

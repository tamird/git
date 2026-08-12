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

test_expect_success 'index reader rejects an out-of-bounds extension size' '
	test_when_finished "rm -rf oversized-index-extension" &&
	test_create_repo oversized-index-extension &&
	(
		cd oversized-index-extension &&
		test_commit base tracked &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git update-index --fsmonitor &&
		test_grep FSMN .git/index >/dev/null &&
		perl -0777 -pe "
			\$pos = index(\$_, q(FSMN));
			die q(FSMN-not-found) if \$pos < 0;
			substr(\$_, \$pos + 4, 4) = pack(q(N), 0xffffffff);
		" .git/index >.git/index.bad &&
		mv .git/index.bad .git/index &&
		test_must_fail git status --porcelain=v2 2>err &&
		test_grep "index file corrupt" err
	)
'

# Test that we detect and disallow repos that are incompatible with FSMonitor.
test_expect_success 'incompatible bare repo' '
	test_when_finished "rm -rf ./bare-clone actual expect" &&
	git init --bare bare-clone &&

	test_must_fail \
		git -C ./bare-clone -c core.fsmonitor=foo \
			update-index --fsmonitor 2>actual &&
	test_grep "bare repository .* is incompatible with fsmonitor" actual &&

	test_must_fail \
		git -C ./bare-clone -c core.fsmonitor=true \
			update-index --fsmonitor 2>actual &&
	test_grep "bare repository .* is incompatible with fsmonitor" actual
'

test_expect_success FSMONITOR_DAEMON 'run fsmonitor-daemon in bare repo' '
	test_when_finished "rm -rf ./bare-clone actual" &&
	git init --bare bare-clone &&
	test_must_fail git -C ./bare-clone fsmonitor--daemon run 2>actual &&
	test_grep "bare repository .* is incompatible with fsmonitor" actual
'

test_expect_success MINGW,FSMONITOR_DAEMON 'run fsmonitor-daemon in virtual repo' '
	test_when_finished "rm -rf ./fake-virtual-clone actual" &&
	git init fake-virtual-clone &&
	test_must_fail git -C ./fake-virtual-clone \
			   -c core.virtualfilesystem=true \
			   fsmonitor--daemon run 2>actual &&
	test_grep "virtual repository .* is incompatible with fsmonitor" actual
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

test_expect_success 'fsmonitor refresh preserves a concurrent index update' '
	test_when_finished "
		rm -rf concurrent-index-false concurrent-index-true
	" &&
	for split_index in false true
	do
		repo=concurrent-index-$split_index &&
		test_create_repo "$repo" &&
		(
			cd "$repo" &&
			echo base >file &&
			git add file &&
			git commit -m base &&
			test_hook --setup fsmonitor-test <<-\EOF &&
				printf "token-1\0"
			EOF
			git config core.fsmonitor .git/hooks/fsmonitor-test &&
			git config index.skipHash true &&
			git config core.splitIndex "$split_index" &&
			git config splitIndex.maxPercentChange 100 &&
			git update-index --fsmonitor &&
			echo staged >file &&
			test_hook --clobber fsmonitor-test <<-\EOF &&
				git -c core.fsmonitor=false \
					-c index.skipHash=true add file &&
				printf "token-2\0"
			EOF
			git status --porcelain &&
			echo staged >expect &&
			git show :file >actual &&
			test_cmp expect actual
		) || return 1
	done
'

test_expect_success PTHREADS 'nonliteral add persists a full fsmonitor refresh' '
	test_when_finished "rm -rf add-fsmonitor-refresh" &&
	test_create_repo add-fsmonitor-refresh &&
	(
		cd add-fsmonitor-refresh &&
		echo clean >clean &&
		echo dirty >dirty &&
		echo target >target &&
		test-tool chmtime =-60 clean dirty target &&
		git add clean dirty target &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0" &&
			if test -f .git/fsmonitor-trivial
			then
				rm .git/fsmonitor-trivial &&
				printf "/\0"
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		GIT_TEST_PRELOAD_INDEX=true git status --porcelain &&
		echo modified >dirty &&
		echo staged >target &&
		: >.git/fsmonitor-trivial &&
		GIT_TEST_PRELOAD_INDEX=true git add -- ":(glob)target" &&
		git ls-files -f -- clean dirty >actual &&
		printf "h clean\nH dirty\n" >expect &&
		test_cmp expect actual &&
		git diff --cached --name-only >actual &&
		echo target >expect &&
		test_cmp expect actual &&
		git diff --name-only >actual &&
		echo dirty >expect &&
		test_cmp expect actual
	)
'

test_expect_success PTHREADS 'git diff persists a full fsmonitor refresh' '
	test_when_finished "rm -rf diff-fsmonitor-refresh" &&
	test_create_repo diff-fsmonitor-refresh &&
	(
		cd diff-fsmonitor-refresh &&
		echo clean >clean &&
		echo dirty >dirty &&
		test-tool chmtime =-60 clean dirty &&
		git add -- clean dirty &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0" &&
			if test -f .git/fsmonitor-trivial
			then
				rm .git/fsmonitor-trivial &&
				printf "/\0"
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		GIT_TEST_PRELOAD_INDEX=true git status --porcelain &&
		echo modified >dirty &&
		: >.git/fsmonitor-trivial &&
		GIT_TEST_PRELOAD_INDEX=true git diff --name-only >.git/actual &&
		echo dirty >.git/expect &&
		test_cmp .git/expect .git/actual &&
		test_path_is_missing .git/fsmonitor-trivial &&
		git ls-files -f -- clean dirty >.git/actual &&
		printf "h clean\nH dirty\n" >.git/expect &&
		test_cmp .git/expect .git/actual
	)
'

test_expect_success UNTRACKED_CACHE \
	'fsmonitor fallback invalidates persisted untracked directories' '
	test_when_finished "rm -rf fsmonitor-untracked-fallback" &&
	test_create_repo fsmonitor-untracked-fallback &&
	(
		cd fsmonitor-untracked-fallback &&
		mkdir -p parent/child &&
		: >parent/child/tracked &&
		git add -- parent/child/tracked &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0" &&
			if test -f .git/fsmonitor-trivial
			then
				rm .git/fsmonitor-trivial &&
				printf "/\0"
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.fsmonitorHookVersion 2 &&
		git config core.untrackedCache true &&
		git status --porcelain >.git/status-before &&
		test_must_be_empty .git/status-before &&
		: >parent/child/untracked &&
		: >.git/fsmonitor-trivial &&
		git update-index --refresh --force-write-index &&
		test_path_is_missing .git/fsmonitor-trivial &&
		git status --porcelain >.git/status-actual &&
		git -c core.fsmonitor=false status --porcelain \
			>.git/status-expect &&
		printf "?? parent/child/untracked\n" >.git/status-untracked &&
		test_cmp .git/status-untracked .git/status-expect &&
		test_cmp .git/status-expect .git/status-actual
	)
'

test_expect_success PTHREADS 'git diff respects fsmonitor refresh write settings' '
	test_when_finished "rm -rf diff-fsmonitor-optional-locks \
		diff-fsmonitor-auto-refresh" &&
	for mode in optional-locks auto-refresh
	do
		repo=diff-fsmonitor-$mode &&
		test_create_repo "$repo" &&
		(
			cd "$repo" &&
			echo clean >clean &&
			echo dirty >dirty &&
			test-tool chmtime =-60 clean dirty &&
			git add -- clean dirty &&
			git commit -m initial &&
			test_hook --setup fsmonitor-test <<-\EOF &&
				printf "last_update_token\0" &&
				if test -f .git/fsmonitor-trivial
				then
					rm .git/fsmonitor-trivial &&
					printf "/\0"
				fi
			EOF
			git config core.fsmonitor .git/hooks/fsmonitor-test &&
			GIT_TEST_PRELOAD_INDEX=true git status --porcelain &&
			echo modified >dirty &&
			: >.git/fsmonitor-trivial &&
			cp .git/index .git/index.before &&
			case "$mode" in
			optional-locks)
				GIT_TEST_PRELOAD_INDEX=true \
					git --no-optional-locks diff --name-only >.git/actual
				;;
			auto-refresh)
				GIT_TEST_PRELOAD_INDEX=true \
					git -c diff.autoRefreshIndex=false \
					diff --name-only >.git/actual
				;;
			esac &&
			echo dirty >.git/expect &&
			test_cmp .git/expect .git/actual &&
			test_path_is_missing .git/fsmonitor-trivial &&
			test_cmp_bin .git/index.before .git/index
		) || return 1
	done
'

test_expect_success PTHREADS 'literal add skips redundant index preload' '
	test_when_finished "rm -rf add-literal-preload trace2-add-literal" &&
	test_create_repo add-literal-preload &&
	(
		cd add-literal-preload &&
		echo clean >clean &&
		echo dirty >dirty &&
		echo one >one &&
		echo two >two &&
		test-tool chmtime =-60 clean dirty one two &&
		git add clean dirty one two &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0" &&
			if test -f .git/fsmonitor-trivial
			then
				rm .git/fsmonitor-trivial &&
				printf "/\0"
			elif test -f .git/fsmonitor-dirty
			then
				while read path
				do
					printf "%s\0" "$path"
				done <.git/fsmonitor-dirty
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		GIT_TEST_PRELOAD_INDEX=true git status --porcelain &&
		echo modified >dirty &&
		echo staged-one >one &&
		echo staged-two >two &&
		printf "dirty\none\ntwo\n" >.git/fsmonitor-dirty &&
		: >.git/fsmonitor-trivial &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/trace2-add-literal" \
			git add -- one two &&
		test_path_is_missing .git/fsmonitor-trivial &&
		test_region ! index preload "$TRASH_DIRECTORY/trace2-add-literal" &&
		git ls-files -f -- clean >actual &&
		echo "H clean" >expect &&
		test_cmp expect actual &&
		git diff --cached --name-only >actual &&
		printf "one\ntwo\n" >expect &&
		test_cmp expect actual &&
		git show :one >actual &&
		echo staged-one >expect &&
		test_cmp expect actual &&
		git show :two >actual &&
		echo staged-two >expect &&
		test_cmp expect actual &&
		git diff --name-only >actual &&
		echo dirty >expect &&
		test_cmp expect actual
	)
'

test_expect_success PTHREADS 'fsmonitor preloads only dirty index entries' '
	test_when_finished "rm -rf refresh-fsmonitor-preload \
		trace2-refresh-fsmonitor-clean trace2-refresh-fsmonitor-dirty \
		trace2-refresh-fsmonitor-assumed \
		trace2-refresh-fsmonitor-multiple" &&
	test_create_repo refresh-fsmonitor-preload &&
	(
		cd refresh-fsmonitor-preload &&
		echo clean >clean &&
		echo dirty >dirty &&
		git add -- clean dirty &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0" &&
			if test -f .git/fsmonitor-dirty
			then
				while read path
				do
					printf "%s\0" "$path"
				done <.git/fsmonitor-dirty
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		GIT_TEST_PRELOAD_INDEX=true \
			git status --porcelain >.git/actual &&
		test_must_be_empty .git/actual &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/trace2-refresh-fsmonitor-clean" \
			git status --porcelain >.git/actual &&
		test_must_be_empty .git/actual &&
		test_region ! index preload \
			"$TRASH_DIRECTORY/trace2-refresh-fsmonitor-clean" &&
		echo modified >dirty &&
		echo dirty >.git/fsmonitor-dirty &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/trace2-refresh-fsmonitor-dirty" \
			git status --porcelain >.git/actual &&
		printf " M dirty\n" >.git/expect &&
		test_cmp .git/expect .git/actual &&
		test_region ! index preload \
			"$TRASH_DIRECTORY/trace2-refresh-fsmonitor-dirty" &&
		git update-index --assume-unchanged -- clean &&
		echo modified >clean &&
		printf "%s\n" clean dirty >.git/fsmonitor-dirty &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/trace2-refresh-fsmonitor-assumed" \
			git status --porcelain >.git/actual &&
		printf " M dirty\n" >.git/expect &&
		test_cmp .git/expect .git/actual &&
		test_region ! index preload \
			"$TRASH_DIRECTORY/trace2-refresh-fsmonitor-assumed" &&
		git update-index --no-assume-unchanged -- clean &&
		printf "%s\n" clean dirty >.git/fsmonitor-dirty &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/trace2-refresh-fsmonitor-multiple" \
			git status --porcelain >.git/actual &&
		printf " M clean\n M dirty\n" >.git/expect &&
		test_cmp .git/expect .git/actual &&
		test_region index preload \
			"$TRASH_DIRECTORY/trace2-refresh-fsmonitor-multiple"
	)
'

test_expect_success PTHREADS 'bare diff avoids preload for one fsmonitor-dirty path' '
	test_when_finished "rm -rf bare-diff-fsmonitor-preload" &&
	test_create_repo bare-diff-fsmonitor-preload &&
	(
		cd bare-diff-fsmonitor-preload &&
		for n in $(test_seq 1 128)
		do
			printf "clean-%s\n" "$n" >"clean-$n" || exit 1
		done &&
		echo one >dirty-one &&
		echo two >dirty-two &&
		echo base >staged &&
		git add . &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
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
		GIT_TEST_PRELOAD_INDEX=true \
			git status --porcelain >.git/status &&
		test_must_be_empty .git/status &&
		echo modified-one >dirty-one &&
		echo dirty-one >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff >.git/diff.expect &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$PWD/.git/diff-one.trace" \
			git diff >.git/diff.actual &&
		test_cmp .git/diff.expect .git/diff.actual &&
		test_grep "^diff --git a/dirty-one b/dirty-one$" \
			.git/diff.actual &&
		test_region ! index preload "$PWD/.git/diff-one.trace" &&
		test_grep "\"key\":\"setup-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-one.trace &&
		test_grep "\"key\":\"dispatch-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-one.trace &&
		test_grep "\"key\":\"finalize-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-one.trace &&
		test_grep "\"key\":\"execution-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-one.trace &&
		for option in --stat -w
		do
			git --no-optional-locks \
				-c core.fsmonitor=false -c core.preloadIndex=false \
				diff "$option" >.git/diff.expect &&
			GIT_TEST_PRELOAD_INDEX=true \
				git diff "$option" >.git/diff.actual &&
			test_cmp .git/diff.expect .git/diff.actual || exit 1
		done &&
		echo modified-two >dirty-two &&
		printf "%s\n" dirty-one dirty-two >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff >.git/diff.expect &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$PWD/.git/diff-multiple.trace" \
			git diff >.git/diff.actual &&
		test_cmp .git/diff.expect .git/diff.actual &&
		test_region index preload "$PWD/.git/diff-multiple.trace" &&
		rm dirty-one &&
		printf "%s\n" dirty-one dirty-two >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff >.git/diff.expect &&
		GIT_TEST_PRELOAD_INDEX=true git diff >.git/diff.actual &&
		test_cmp .git/diff.expect .git/diff.actual &&
		test_grep "^deleted file mode" .git/diff.actual &&
		echo staged-change >staged &&
		git -c core.fsmonitor= add staged &&
		git diff --cached --name-only >.git/staged.actual &&
		echo staged >.git/staged.expect &&
		test_cmp .git/staged.expect .git/staged.actual &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff >.git/diff.expect &&
		GIT_TEST_PRELOAD_INDEX=true git diff >.git/diff.actual &&
		test_cmp .git/diff.expect .git/diff.actual
	)
'

test_expect_success 'diff-index honors fsmonitor validity' '
	test_when_finished "rm -rf diff-index" &&
	test_create_repo diff-index &&
	mkdir diff-index/clean diff-index/dirty &&
	echo clean >diff-index/clean/file &&
	echo base >diff-index/dirty/file &&
	test-tool chmtime =-60 diff-index/clean/file diff-index/dirty/file &&
	git -C diff-index add . &&
	git -C diff-index commit -m base &&
	printf "tip \n" >diff-index/dirty/file &&
	test-tool chmtime =-120 diff-index/dirty/file &&
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

	if test_have_prereq PTHREADS
	then
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.preloadIndex=false \
			-C diff-index diff --name-only HEAD^ \
			>diff-index/.git/fsmonitor-diff-expect &&
		git -C diff-index update-index --no-fsmonitor-valid -- \
			clean/file dirty/file &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/diff-index/.git/fsmonitor-diff-first.trace" \
			git -C diff-index diff --name-only HEAD^ \
			>diff-index/.git/fsmonitor-diff-actual &&
		test_cmp diff-index/.git/fsmonitor-diff-expect \
			diff-index/.git/fsmonitor-diff-actual &&
		test_trace2_data index preload/sum_lstat 2 \
			<diff-index/.git/fsmonitor-diff-first.trace &&
		git -C diff-index ls-files -f >actual.fsmonitor &&
		grep "^h clean/file$" actual.fsmonitor &&
		grep "^h dirty/file$" actual.fsmonitor &&
		GIT_TEST_PRELOAD_INDEX=true \
		GIT_TRACE2_EVENT="$TRASH_DIRECTORY/diff-index/.git/fsmonitor-diff-second.trace" \
			git -C diff-index diff --name-only HEAD^ \
			>diff-index/.git/fsmonitor-diff-actual &&
		test_cmp diff-index/.git/fsmonitor-diff-expect \
			diff-index/.git/fsmonitor-diff-actual &&
		test_trace2_data index preload/sum_lstat 0 \
			<diff-index/.git/fsmonitor-diff-second.trace &&
		for mode in cached optional-locks auto-refresh
		do
			git -C diff-index update-index --no-fsmonitor-valid -- \
				clean/file dirty/file &&
			cp diff-index/.git/index \
				diff-index/.git/fsmonitor-diff-index.before &&
			case "$mode" in
			cached)
				GIT_TEST_PRELOAD_INDEX=true \
					git -C diff-index diff --cached \
					--name-only HEAD^
				;;
			optional-locks)
				GIT_TEST_PRELOAD_INDEX=true \
					git -C diff-index --no-optional-locks \
					diff --name-only HEAD^
				;;
			auto-refresh)
				GIT_TEST_PRELOAD_INDEX=true \
					git -C diff-index \
					-c diff.autoRefreshIndex=false \
					diff --name-only HEAD^
				;;
			esac >diff-index/.git/fsmonitor-diff-actual &&
			test_cmp diff-index/.git/fsmonitor-diff-expect \
				diff-index/.git/fsmonitor-diff-actual &&
			test_cmp_bin diff-index/.git/fsmonitor-diff-index.before \
				diff-index/.git/index || return 1
		done
	fi &&

	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff --name-status HEAD^ >expect &&
	git -C diff-index diff --name-status HEAD^ >actual &&
	test_cmp expect actual &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff --stat --numstat HEAD^ >expect &&
	git -C diff-index diff --stat --numstat HEAD^ >actual &&
	test_cmp expect actual &&
	test_must_fail git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff --check HEAD^ >expect &&
	test_must_fail git -C diff-index diff --check HEAD^ >actual &&
	test_cmp expect actual &&

	echo staged >diff-index/clean/file &&
	git -c core.fsmonitor= -C diff-index add clean/file &&
	git -C diff-index status --short &&
	git -C diff-index ls-files -f >actual.fsmonitor &&
	grep "^h clean/file$" actual.fsmonitor &&
	grep "^h dirty/file$" actual.fsmonitor &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff-index -c HEAD^ >expect &&
	git -C diff-index diff-index -c HEAD^ >actual &&
	test_cmp expect actual &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff-index --cc HEAD^ >expect &&
	git -C diff-index diff-index --cc HEAD^ >actual &&
	test_cmp expect actual &&

	echo worktree-after-staged >diff-index/clean/file &&
	echo clean/file >diff-index/.git/fsmonitor-dirty &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&

	git -C diff-index reset --hard HEAD &&
	echo worktree >diff-index/dirty/file &&
	echo dirty/file >diff-index/.git/fsmonitor-dirty &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual &&

	git -C diff-index reset --hard HEAD &&
	rm diff-index/clean/file &&
	echo clean/file >diff-index/.git/fsmonitor-dirty &&
	git --no-optional-locks -c core.fsmonitor=false \
		-c core.preloadIndex=false \
		-C diff-index diff HEAD^ >expect &&
	git -C diff-index diff HEAD^ >actual &&
	test_cmp expect actual
'

test_expect_success 'diff-index reuses valid cache trees with excluded globs' '
	test_when_finished "rm -rf diff-index-excludes" &&
	test_create_repo diff-index-excludes &&
	(
		cd diff-index-excludes &&
		mkdir -p included ignored generated &&
		echo base >included/file &&
		echo base >ignored/skip.tmp &&
		echo base >generated/file.generated &&
		git add . &&
		git commit -m base &&
		echo tip >included/file &&
		echo hidden-tip >ignored/skip.tmp &&
		echo generated-tip >generated/file.generated &&
		git add . &&
		git commit -m tip &&
		test_hook --setup fsmonitor-test <<-\EOF &&
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
		git update-index --fsmonitor &&
		git status --porcelain >.git/status &&
		test_must_be_empty .git/status &&
		git ls-files -f >.git/fsmonitor-valid &&
		test_grep "^h included/file$" .git/fsmonitor-valid &&
		test_grep "^h ignored/skip.tmp$" .git/fsmonitor-valid &&
		test_grep "^h generated/file.generated$" .git/fsmonitor-valid &&
		exclude_tmp=":(exclude,glob)**/*.tmp" &&
		exclude_generated=":(exclude,glob)generated/**" &&
		exclude_cache=":(exclude,glob)**/*.cache" &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.expect &&
		GIT_TRACE2_EVENT="$PWD/.git/diff-exclude.trace" \
			git diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.actual &&
		test_cmp .git/diff-exclude.expect .git/diff-exclude.actual &&
		test_grep "^diff --git a/included/file b/included/file$" \
			.git/diff-exclude.actual &&
		! grep "ignored/skip.tmp" .git/diff-exclude.actual &&
		! grep "generated/file.generated" .git/diff-exclude.actual &&
		cached_traversal=$(sed -n \
			"s#.*index/cached-traversal[^0-9]*\\([0-9][0-9]*\\).*#\\1#p" \
			.git/diff-exclude.trace) &&
		echo "diff index cached traversal: $cached_traversal" &&
		test_trace2_data diff index/cached-traversal 1 \
			<.git/diff-exclude.trace &&
		test_grep "\"key\":\"setup-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-exclude.trace &&
		test_grep "\"key\":\"dispatch-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-exclude.trace &&
		test_grep "\"key\":\"finalize-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-exclude.trace &&
		test_grep "\"key\":\"execution-us\",\"value\":\"[0-9][0-9]*\"" \
			.git/diff-exclude.trace &&
		for mode in --stat -w
		do
			git --no-optional-locks \
				-c core.fsmonitor=false -c core.preloadIndex=false \
				diff "$mode" HEAD^ -- "$exclude_tmp" \
				"$exclude_generated" "$exclude_cache" \
				>.git/diff-exclude.expect &&
			git diff "$mode" HEAD^ -- "$exclude_tmp" \
				"$exclude_generated" "$exclude_cache" \
				>.git/diff-exclude.actual &&
			test_cmp .git/diff-exclude.expect \
				.git/diff-exclude.actual || exit 1
		done &&
		echo staged >included/file &&
		git -c core.fsmonitor= add included/file &&
		git status --porcelain >.git/staged-status &&
		test_grep "^M  included/file$" .git/staged-status &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.expect &&
		GIT_TRACE2_EVENT="$PWD/.git/diff-exclude-staged.trace" \
			git diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.actual &&
		test_cmp .git/diff-exclude.expect .git/diff-exclude.actual &&
		test_trace2_data diff index/cached-traversal 1 \
			<.git/diff-exclude-staged.trace &&
		echo worktree >included/file &&
		echo included/file >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.expect &&
		GIT_TRACE2_EVENT="$PWD/.git/diff-exclude-dirty.trace" \
			git diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.actual &&
		test_cmp .git/diff-exclude.expect .git/diff-exclude.actual &&
		test_trace2_data diff index/cached-traversal 0 \
			<.git/diff-exclude-dirty.trace &&
		echo excluded-worktree >ignored/skip.tmp &&
		printf "included/file\nignored/skip.tmp\n" \
			>.git/fsmonitor-dirty &&
		git diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.actual &&
		! grep "ignored/skip.tmp" .git/diff-exclude.actual &&
		rm included/file &&
		echo included/file >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.expect &&
		git diff HEAD^ -- "$exclude_tmp" "$exclude_generated" \
			"$exclude_cache" >.git/diff-exclude.actual &&
		test_cmp .git/diff-exclude.expect .git/diff-exclude.actual &&
		test_grep "^deleted file mode" .git/diff-exclude.actual
	)
'

test_expect_success 'diff-index skips clean cache-tree entries beside dirty worktrees' '
	test_when_finished "rm -rf diff-index-clean-entries" &&
	test_create_repo diff-index-clean-entries &&
	(
		cd diff-index-clean-entries &&
		mkdir bulk changes &&
		for n in $(test_seq 1 128)
		do
			printf "base-%s\n" "$n" >"bulk/clean-$n" ||
				exit 1
		done &&
		echo clean >bulk/dirty &&
		echo base >changes/file &&
		git add . &&
		git commit -m base &&
		echo tip >changes/file &&
		git add changes/file &&
		git commit -m tip &&
		test_hook --setup fsmonitor-test <<-\EOF &&
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
		git update-index --fsmonitor &&
		git status --porcelain >.git/status &&
		test_must_be_empty .git/status &&
		git ls-files -f bulk/clean-1 bulk/dirty >.git/fsmonitor-valid &&
		test_grep "^h bulk/clean-1$" .git/fsmonitor-valid &&
		test_grep "^h bulk/dirty$" .git/fsmonitor-valid &&
		echo worktree >bulk/dirty &&
		echo bulk/dirty >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ >.git/diff-clean.expect &&
		GIT_TRACE2_EVENT="$PWD/.git/diff-clean.trace" \
			git diff HEAD^ >.git/diff-clean.actual &&
		test_cmp .git/diff-clean.expect .git/diff-clean.actual &&
		test_grep "^diff --git a/bulk/dirty b/bulk/dirty$" \
			.git/diff-clean.actual &&
		test_grep "^diff --git a/changes/file b/changes/file$" \
			.git/diff-clean.actual &&
		test_trace2_data diff index/cached-traversal 0 \
			<.git/diff-clean.trace &&
		callbacks=$(sed -n \
			"s#.*cache-tree/diff-callbacks[^0-9]*\\([0-9][0-9]*\\).*#\\1#p" \
			.git/diff-clean.trace) &&
		test -n "$callbacks" &&
		echo "cache-tree diff callbacks: $callbacks" &&
		test "$callbacks" -le 2 &&
		for option in --stat -w
		do
			git --no-optional-locks \
				-c core.fsmonitor=false -c core.preloadIndex=false \
				diff "$option" HEAD^ >.git/diff-clean.expect &&
			git diff "$option" HEAD^ >.git/diff-clean.actual &&
			test_cmp .git/diff-clean.expect .git/diff-clean.actual ||
				exit 1
		done &&
		echo staged >changes/file &&
		git -c core.fsmonitor= add changes/file &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ >.git/diff-clean.expect &&
		git diff HEAD^ >.git/diff-clean.actual &&
		test_cmp .git/diff-clean.expect .git/diff-clean.actual &&
		rm bulk/dirty &&
		echo bulk/dirty >.git/fsmonitor-dirty &&
		git --no-optional-locks \
			-c core.fsmonitor=false -c core.preloadIndex=false \
			diff HEAD^ >.git/diff-clean.expect &&
		git diff HEAD^ >.git/diff-clean.actual &&
		test_cmp .git/diff-clean.expect .git/diff-clean.actual &&
		test_grep "^deleted file mode" .git/diff-clean.actual
	)
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
	test_grep "^no fsmonitor" actual
'

# test that "update-index --fsmonitor" adds the fsmonitor extension
test_expect_success 'update-index --fsmonitor" adds the fsmonitor extension' '
	git update-index --fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	test_grep "^fsmonitor last update" actual
'

# test that "update-index --no-fsmonitor" removes the fsmonitor extension
test_expect_success 'update-index --no-fsmonitor" removes the fsmonitor extension' '
	git update-index --no-fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	test_grep "^no fsmonitor" actual
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

test_expect_success UNTRACKED_CACHE 'fsmonitor invalidates directory cones' '
	test_create_repo fsmonitor-cone &&
	(
		cd fsmonitor-cone &&
		mkdir -p parent/child sibling/leaf &&
		: >parent/child/tracked &&
		: >sibling/leaf/tracked &&
		git add . &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "parent/\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain &&
		: >parent/child/untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-cone" \
			git status --porcelain >../actual &&
		rm parent/child/untracked &&
		git status --porcelain >../actual-clean &&
		test_must_be_empty ../actual-clean
	) &&
	echo "?? parent/child/untracked" >expect &&
	test_cmp expect actual &&
	test_grep "opendir:3" trace-cone
'

test_expect_success UNTRACKED_CACHE 'missing fsmonitor cones do not create cache nodes' '
	test_create_repo fsmonitor-missing-cones &&
	(
		cd fsmonitor-missing-cones &&
		mkdir -p parent/existing &&
		: >parent/existing/tracked &&
		git add -- parent &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0" &&
			if test -f .git/fsmonitor-missing-cones
			then
				for repeat in 1 2
				do
					n=256 &&
					while test "$n" -gt 0
					do
						printf "parent/missing-%04d/descendant/\0" "$n" &&
						n=$((n - 1)) ||
						exit 1
					done
				done
			fi
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../missing-before &&
		test_must_be_empty ../missing-before &&
		: >.git/fsmonitor-missing-cones &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-missing-cones" \
			git status --porcelain >../missing-after &&
		test_must_be_empty ../missing-after &&
		test_grep "node-creation:0" \
			"$TRASH_DIRECTORY/trace-missing-cones" &&
		test-tool dump-untracked-cache >../missing-cache &&
		test_grep ! "^/parent/missing-" ../missing-cache
	)
'

test_expect_success UNTRACKED_CACHE 'do not prune a flat tracked index' '
	test_create_repo flat-tracked &&
	(
		cd flat-tracked &&
		test_seq 1 64 |
		sed "s/^/tracked-/" |
		xargs touch &&
		git config feature.manyFiles true &&
		git add -- . &&
		test "$(git update-index --show-index-version)" = 4 &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../flat-before &&
		test_must_be_empty ../flat-before &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-flat-tracked" \
			git status --porcelain >../flat-after &&
		test_must_be_empty ../flat-after
	) &&
	test_grep "subtrees-pruned:0" trace-flat-tracked &&
	test_grep "directories-visited:1" trace-flat-tracked
'

test_expect_success UNTRACKED_CACHE 'do not scan index for a result-bearing subtree' '
	test_create_repo mixed-tracked &&
	(
		cd mixed-tracked &&
		test_seq 1 64 |
		sed "s/^/tracked-/" |
		xargs touch &&
		mkdir results &&
		: >results/tracked &&
		git config feature.manyFiles true &&
		git add -- . &&
		test "$(git update-index --show-index-version)" = 4 &&
		git commit -m initial &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		: >results/untracked &&
		echo "?? results/untracked" >../mixed-expect &&
		git status --porcelain >../mixed-before &&
		test_cmp ../mixed-expect ../mixed-before &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-mixed-tracked" \
			git status --porcelain >../mixed-after &&
		test_cmp ../mixed-expect ../mixed-after
	) &&
	test_grep "subtrees-pruned:0" trace-mixed-tracked &&
	test_grep "directories-visited:2" trace-mixed-tracked &&
	test_grep ! "skip-worktree-scan" trace-mixed-tracked
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
		test_must_be_empty ../actual &&
		git update-index --skip-worktree dir1/dir2/tracked &&
		git status --porcelain >../actual &&
		test_must_be_empty ../actual &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-empty-skip-worktree" \
			git --no-optional-locks status -z -uall >../actual &&
		test_must_be_empty ../actual
	) &&
	test_grep "directories-visited:0" trace-empty &&
	test_grep "subtrees-pruned:1" trace-empty &&
	test_grep "directories-visited:0" trace-empty-skip-worktree &&
	test_grep "subtrees-pruned:1" trace-empty-skip-worktree
'

test_expect_success UNTRACKED_CACHE 'keep tracked ignore identity with fsmonitor' '
	test_create_repo ignore-identity &&
	(
		cd ignore-identity &&
		echo old >.gitignore &&
		git add .gitignore &&
		git commit -m initial &&
		mkdir ignored &&
		echo ignored/ >.gitignore &&
		: >ignored/file &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >/dev/null &&
		test-tool dump-untracked-cache >../cache-before &&
		git add .gitignore &&
		git update-index --fsmonitor-valid .gitignore &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ignore-identity" \
			git status --porcelain >/dev/null &&
		test-tool dump-untracked-cache >../cache-after
	) &&
	test_cmp cache-before cache-after &&
	test_grep "gitignore-invalidation:0" trace-ignore-identity
'

test_expect_success UNTRACKED_CACHE 'reuse legacy ignore identity with fsmonitor' '
	(
		cd ignore-identity &&
		printf "ignored/\n\n" >.gitignore &&
		git status --porcelain >/dev/null &&
		printf "ignored/\n" >.gitignore &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ignore-legacy" \
			git --no-optional-locks status --porcelain \
			>../ignore-legacy-actual &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../ignore-legacy-expect &&
		test_cmp ../ignore-legacy-expect ../ignore-legacy-actual &&
		printf "elsewhere/\n" >.gitignore &&
		test_hook --setup --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf ".gitignore\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ignore-legacy-change" \
			git --no-optional-locks status --porcelain \
			>../ignore-legacy-change-actual &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../ignore-legacy-change-expect &&
		test_cmp ../ignore-legacy-change-expect \
			../ignore-legacy-change-actual
	) &&
	test_grep "gitignore-invalidation:0" trace-ignore-legacy &&
	test_grep "gitignore-invalidation:[1-9]" trace-ignore-legacy-change &&
	test_grep "?? ignored/" ignore-legacy-change-actual
'

test_expect_success UNTRACKED_CACHE 'fsmonitor invalidates empty root summary' '
	(
		cd empty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "untracked\0"
		EOF
		: >untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-root-invalidate" \
			git status --porcelain >../actual &&
		rm untracked &&
		git status --porcelain >../actual-clean &&
		test_must_be_empty ../actual-clean
	) &&
	echo "?? untracked" >expect &&
	test_cmp expect actual &&
	test_grep "directories-visited:[1-9]" trace-root-invalidate
'

test_expect_success UNTRACKED_CACHE 'reload partially invalid subtree summaries' '
	test_create_repo partial-untracked &&
	(
		cd partial-untracked &&
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
	test_grep "directories-visited:[1-9]" trace-partial
'

test_expect_success UNTRACKED_CACHE 'invalidate and recompute subtree summaries' '
	test_create_repo prune-subtrees &&
	(
		cd prune-subtrees &&
		mkdir empty results &&
		: >empty/tracked &&
		: >results/tracked &&
		git add . &&
		git commit -m initial &&
		: >results/one &&
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
	echo "?? results/one" >expect &&
	test_cmp expect actual &&
	test_grep "name-hash-init" trace-prune-live &&
	test_grep "directories-visited:2" trace-prune &&
	test_grep "subtrees-pruned:1" trace-prune &&
	test_grep "opendir:0" trace-prune &&
	test_grep ! "name-hash-init" trace-prune
'

test_expect_success UNTRACKED_CACHE 'invalidate one prunable subtree' '
	(
		cd prune-subtrees &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "empty/two\0"
		EOF
		: >empty/two &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-invalidate" \
			git status --porcelain >../actual-invalidate &&
		rm empty/two &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-rescan" \
			git status --porcelain >../actual-rescan &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-recomputed" \
			git status --porcelain >../actual-recomputed
	) &&
	echo "?? results/one" >expect &&
	test_cmp expect actual &&
	cat >expect <<-\EOF &&
	?? empty/two
	?? results/one
	EOF
	test_cmp expect actual-invalidate &&
	echo "?? results/one" >expect &&
	test_cmp expect actual-rescan &&
	test_cmp expect actual-recomputed &&
	test_grep "directories-visited:2" trace-prune &&
	test_grep "subtrees-pruned:1" trace-prune &&
	test_grep "opendir:0" trace-prune &&
	test_grep "directories-visited:3" trace-invalidate &&
	test_grep "directories-visited:3" trace-rescan &&
	test_grep "directories-visited:2" trace-recomputed &&
	test_grep "subtrees-pruned:1" trace-recomputed
'

test_expect_success UNTRACKED_CACHE '-uall invalidates summary ancestors' '
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
		git status --porcelain &&
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
	test_grep "directories-visited:[1-9]" trace-uall-left &&
	test_grep "subtrees-pruned:1" trace-uall-left &&
	test_grep "opendir:1" trace-uall-left
'

test_expect_success UNTRACKED_CACHE 'failed fsmonitor scans empty cache' '
	(
		cd empty-untracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			exit 1
		EOF
		: >fallback &&
		test-tool chmtime =-60 . &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-fallback" \
			git status --porcelain >../actual
	) &&
	echo "?? fallback" >expect &&
	test_cmp expect actual &&
	test_grep "directories-visited:[1-9]" trace-fallback
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
	test_grep "directories-visited:[1-9]" trace-index-ignore &&
	test_grep "subtrees-pruned:0" trace-index-ignore-ls-files &&
	test_grep "directories-visited:[1-9]" trace-index-ignore-ls-files
'

test_expect_success UNTRACKED_CACHE 'clearing skip-worktree invalidates cached ignores' '
	test_create_repo skip-ignore-transition &&
	(
		cd skip-ignore-transition &&
		mkdir dir &&
		echo ignored >dir/.gitignore &&
		: >dir/tracked &&
		: >dir/ignored &&
		git add -- dir/.gitignore dir/tracked &&
		git commit -m initial &&
		git update-index --skip-worktree dir/.gitignore &&
		rm dir/.gitignore &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../skip-transition-before &&
		test_must_be_empty ../skip-transition-before &&
		git -c core.fsmonitor=false update-index \
			--no-skip-worktree dir/.gitignore &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-skip-transition" \
			git status --porcelain >../skip-transition-actual &&
		git -c core.untrackedCache=false status --porcelain \
			>../skip-transition-expect
	) &&
	test_cmp skip-transition-expect skip-transition-actual &&
	test_grep "^?? dir/ignored$" skip-transition-actual &&
	test_grep "gitignore-invalidation-source:dir/.gitignore" \
		trace-skip-transition &&
	test_grep "directories-visited:[1-9]" trace-skip-transition
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

test_expect_success UNTRACKED_CACHE 'pathspec honors directory-cone invalidation' '
	(
		cd fsmonitor-cone &&
		: >parent/child/pathspec-new &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec-cone" \
			git status --porcelain -- "*pathspec-new" >../actual
	) &&
	echo "?? parent/child/pathspec-new" >expect &&
	test_cmp expect actual &&
	test_grep "directories-visited:[1-9]" trace-pathspec-cone &&
	test_grep "subtrees-pruned:1" trace-pathspec-cone
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

test_expect_success UNTRACKED_CACHE 'pathspec prunes across output modes' '
	(
		cd pathspec-untracked &&
		test-tool dump-untracked-cache >../cache-before &&
		git config status.showUntrackedFiles all &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec-mode" \
			git status --porcelain -- "*untracked" >../actual &&
		git config --unset status.showUntrackedFiles &&
		test-tool dump-untracked-cache >../cache-after
	) &&
	echo "?? results/c/untracked" >expect &&
	test_cmp expect actual &&
	test_cmp cache-before cache-after &&
	test_grep "subtrees-pruned:[1-9]" trace-pathspec-mode
'

test_expect_success UNTRACKED_CACHE 'pathspec validates standard excludes' '
	(
		cd pathspec-untracked &&
		echo left/ >.git/info/exclude &&
		git status --porcelain >/dev/null &&
		: >.git/info/exclude &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-pathspec-exclude" \
			git status --porcelain -- "*matching" >../actual
	) &&
	echo "?? left/a/matching" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-pathspec-exclude &&
	test_grep "directories-visited:[1-9]" trace-pathspec-exclude
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

test_expect_success UNTRACKED_CACHE 'set up cross-mode untracked pruning' '
	test_create_repo cross-mode-untracked &&
	(
		cd cross-mode-untracked &&
		mkdir -p clean/a ignored-only/sub quiet/b results &&
		echo ignored-only/ >.gitignore &&
		echo old-hidden >quiet/b/.gitignore &&
		echo needle >clean/a/tracked &&
		: >ignored-only/sub/ignored &&
		: >ignored-only/sub/one &&
		: >quiet/b/tracked &&
		git add . &&
		git commit -m initial &&
		echo needle >results/one &&
		echo needle >results/two &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git config core.untrackedCache true &&
		git status --porcelain >../actual &&
		test-tool dump-untracked-cache >../normal-cache
	) &&
	echo "?? results/" >expect &&
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE 'normal cache prunes all status' '
	(
		cd cross-mode-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-normal-to-all" \
			git status --porcelain -uall >../actual &&
		test-tool dump-untracked-cache >../actual-cache
	) &&
	cat >expect <<-\EOF &&
	?? results/one
	?? results/two
	EOF
	test_cmp expect actual &&
	test_cmp normal-cache actual-cache &&
	test_grep "requested-flags:0" trace-normal-to-all &&
	test_grep "stored-flags:6" trace-normal-to-all &&
	test_grep "cache-present:1" trace-normal-to-all &&
	test_grep "negative-only:1" trace-normal-to-all &&
	test_grep "subtrees-pruned:[1-9]" trace-normal-to-all &&
	test_grep "directories-visited:[1-9]" trace-normal-to-all &&
	test_grep "untracked/all:1" trace-normal-to-all &&
	test_grep "untracked/fill-us:[0-9][0-9]*" trace-normal-to-all &&
	test_grep "untracked/materialize-us:[0-9][0-9]*" trace-normal-to-all &&
	test_grep "untracked/duration-us:[0-9][0-9]*" trace-normal-to-all
'

test_expect_success UNTRACKED_CACHE 'prune git add with wildcard pathspec' '
	(
		cd cross-mode-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-add-wildcard" \
			git add -N -- "*/one" &&
		git ls-files --error-unmatch results/one &&
		test_must_fail git ls-files --error-unmatch \
			ignored-only/sub/one &&
		git reset -q -- results/one &&
		git status --porcelain >../actual
	) &&
	echo "?? results/" >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-add-wildcard &&
	test_grep "directories-visited:[1-9]" trace-add-wildcard
'

test_expect_success UNTRACKED_CACHE 'git add reports explicit ignored path' '
	(
		cd cross-mode-untracked &&
		test_must_fail env \
			GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-add-ignored" \
			git add --dry-run -N -- ignored-only/sub/ignored \
			2>../err
	) &&
	test_grep "Use -f if" err &&
	test_grep "subtrees-pruned:0" trace-add-ignored
'

test_expect_success UNTRACKED_CACHE 'all cache prunes normal status' '
	(
		cd cross-mode-untracked &&
		git config status.showUntrackedFiles all &&
		git status --porcelain >/dev/null &&
		test-tool dump-untracked-cache >../all-cache &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-all-to-normal" \
			git status --porcelain -unormal >../actual &&
		test-tool dump-untracked-cache >../actual-cache
	) &&
	echo "?? results/" >expect &&
	test_cmp expect actual &&
	test_cmp all-cache actual-cache &&
	test_grep "requested-flags:6" trace-all-to-normal &&
	test_grep "stored-flags:0" trace-all-to-normal &&
	test_grep "cache-present:1" trace-all-to-normal &&
	test_grep "negative-only:1" trace-all-to-normal &&
	test_grep "subtrees-pruned:[1-9]" trace-all-to-normal &&
	test_grep "directories-visited:[1-9]" trace-all-to-normal &&
	test_grep "untracked/all:0" trace-all-to-normal &&
	test_grep "untracked/fill-us:[0-9][0-9]*" trace-all-to-normal &&
	test_grep "untracked/materialize-us:[0-9][0-9]*" trace-all-to-normal &&
	test_grep "untracked/duration-us:[0-9][0-9]*" trace-all-to-normal
'

test_expect_success UNTRACKED_CACHE 'ls-files replays all-mode cache' '
	(
		cd cross-mode-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-all" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-all &&
	test_grep "opendir:0" trace-ls-files-all
'

test_expect_success UNTRACKED_CACHE 'prune grep --untracked from normal cache' '
	(
		cd cross-mode-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-grep-untracked" \
			git grep --untracked -l needle >../actual
	) &&
	cat >expect <<-\EOF &&
	clean/a/tracked
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-grep-untracked &&
	test_grep "directories-visited:[1-9]" trace-grep-untracked
'

test_expect_success UNTRACKED_CACHE 'ls-files prunes normal cache' '
	(
		cd cross-mode-untracked &&
		git config --unset status.showUntrackedFiles &&
		git status --porcelain >/dev/null &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-normal" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-normal &&
	test_grep "directories-visited:[1-9]" trace-ls-files-normal
'

test_expect_success UNTRACKED_CACHE 'ls-files scans positive normal-mode cache' '
	(
		cd cross-mode-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-directory" \
			git ls-files --others --exclude-standard \
				--directory --no-empty-directory >../actual
	) &&
	echo results/ >expect &&
	test_cmp expect actual &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-directory &&
	test_grep "directories-visited:[1-9]" trace-ls-files-directory
'

test_expect_success UNTRACKED_CACHE 'ls-files without standard excludes scans all' '
	(
		cd cross-mode-untracked &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-no-exclude" \
			git ls-files --others >../actual
	) &&
	cat >expect <<-\EOF &&
	ignored-only/sub/ignored
	ignored-only/sub/one
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-ls-files-no-exclude &&
	test_grep "directories-visited:[1-9]" trace-ls-files-no-exclude
'

test_expect_success UNTRACKED_CACHE 'ls-files with command excludes scans all' '
	(
		cd cross-mode-untracked &&
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
		cd cross-mode-untracked &&
		: >clean/a/new &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "clean/a/new\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-dirty" \
			git ls-files --others --exclude-standard >../actual &&
		git status --porcelain >/dev/null &&
		test_hook --clobber fsmonitor-test <<-\EOF
			printf "last_update_token\0"
		EOF
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

test_expect_success UNTRACKED_CACHE 'ls-files persists repaired empty subtree' '
	test_when_finished "
		git -C cross-mode-untracked checkout -- quiet/b/.gitignore &&
		rm -f cross-mode-untracked/quiet/b/hidden
	" &&
	(
		cd cross-mode-untracked &&
		echo hidden >quiet/b/.gitignore &&
		: >quiet/b/hidden &&
		touch quiet/b/tracked &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "clean/a/new\0"
			printf "quiet/b/.gitignore\0"
			printf "quiet/b/hidden\0"
			printf "quiet/b/tracked\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-repair" \
			git ls-files --others --exclude-standard >../actual &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-repaired" \
			git ls-files --others --exclude-standard >../actual-repaired
	) &&
	cat >expect <<-\EOF &&
	clean/a/new
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_cmp expect actual-repaired &&
	test_grep "subtrees-repaired:[1-9]" trace-ls-files-repair &&
	test_grep "subtrees-pruned:[1-9]" trace-ls-files-repaired &&
	test_grep ! quiet/b/hidden actual-repaired
'

test_expect_success UNTRACKED_CACHE 'ls-files falls back after fsmonitor failure' '
	(
		cd cross-mode-untracked &&
		: >ls-fallback &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			exit 1
		EOF
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-fallback" \
			git ls-files --others --exclude-standard >../actual &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			printf "ls-fallback\0"
		EOF
		git status --porcelain >/dev/null &&
		test_hook --clobber fsmonitor-test <<-\EOF
			printf "last_update_token\0"
		EOF
	) &&
	cat >expect <<-\EOF &&
	clean/a/new
	ls-fallback
	results/one
	results/two
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-ls-files-fallback &&
	test_grep "directories-visited:[1-9]" trace-ls-files-fallback
'

test_expect_success UNTRACKED_CACHE 'set up pathless git add --all' '
	(
		cd cross-mode-untracked &&
		rm -f clean/a/new ls-fallback &&
		: >add-input &&
		test_hook --clobber fsmonitor-test <<-\EOF
			printf "last_update_token\0"
			printf "clean/a/new\0"
			printf "ls-fallback\0"
			printf "add-input\0"
		EOF
	)
'

test_expect_success UNTRACKED_CACHE 'pathless git add --all prunes normal cache' '
	test_when_finished "git -C cross-mode-untracked reset --quiet" &&
	(
		cd cross-mode-untracked &&
		git config status.showUntrackedFiles normal &&
		git status --porcelain >/dev/null &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		test-tool dump-untracked-cache >../add-normal-cache &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-add-normal" \
			git add --all &&
		git diff --cached --name-only >../actual-staged
	) &&
	cat >expect-staged <<-\EOF &&
	add-input
	results/one
	results/two
	EOF
	test_grep "flags 00000006" add-normal-cache &&
	test_cmp expect-staged actual-staged &&
	test_grep "subtrees-pruned:[1-9]" trace-add-normal &&
	test_grep "directories-visited:[1-9]" trace-add-normal
'

test_expect_success UNTRACKED_CACHE 'pathless git add --all replays all-mode cache' '
	test_when_finished "git -C cross-mode-untracked reset --quiet" &&
	(
		cd cross-mode-untracked &&
		git config status.showUntrackedFiles all &&
		git status --porcelain >/dev/null &&
		test-tool dump-untracked-cache >../add-all-cache &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-add-all" \
			git add --all &&
		git diff --cached --name-only >../actual-staged
	) &&
	cat >expect-staged <<-\EOF &&
	add-input
	results/one
	results/two
	EOF
	test_grep "flags 00000000" add-all-cache &&
	test_cmp expect-staged actual-staged &&
	test_grep "opendir:0" trace-add-all
'

test_expect_success UNTRACKED_CACHE 'git add --all reports explicit ignored path' '
	(
		cd cross-mode-untracked &&
		test_must_fail git add --all -- ignored-only/sub/ignored \
			2>../err
	) &&
	test_grep "^ignored-only$" err &&
	test_grep "Use -f if" err
'

test_expect_success UNTRACKED_CACHE 'git add --all falls back after fsmonitor failure' '
	(
		cd cross-mode-untracked &&
		git config status.showUntrackedFiles normal &&
		git status --porcelain >/dev/null &&
		test-tool dump-untracked-cache >../add-normal-cache &&
		: >add-fallback &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			exit 1
		EOF
		git add --all &&
		git diff --cached --name-only >../actual-staged &&
		test_hook --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		git status --porcelain >../actual-status &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-add-status" \
			git status --porcelain >../actual-status-cached
	) &&
	cat >expect-staged <<-\EOF &&
	add-fallback
	add-input
	results/one
	results/two
	EOF
	cat >expect-status <<-\EOF &&
	A  add-fallback
	A  add-input
	A  results/one
	A  results/two
	EOF
	test_grep "flags 00000006" add-normal-cache &&
	test_cmp expect-staged actual-staged &&
	test_cmp expect-status actual-status &&
	test_cmp expect-status actual-status-cached &&
	test_grep "subtrees-pruned:[1-9]" trace-add-status &&
	test_grep "opendir:0" trace-add-status
'

test_expect_success UNTRACKED_CACHE 'ls-files validates standard excludes' '
	test_create_repo ls-files-excludes &&
	(
		cd ls-files-excludes &&
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
		git status --porcelain >/dev/null &&
		: >.git/info/exclude &&
		: >.git/core-exclude &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-ls-files-ident" \
			git ls-files --others --exclude-standard >../actual
	) &&
	cat >expect <<-\EOF &&
	hidden-core/untracked
	hidden-info/untracked
	EOF
	test_cmp expect actual &&
	test_grep "subtrees-pruned:0" trace-ls-files-ident &&
	test_grep "directories-visited:[1-9]" trace-ls-files-ident
'

test_expect_success UNTRACKED_CACHE 'reuse legacy standard exclude identities' '
	(
		cd ls-files-excludes &&
		printf "hidden-info/\n\n" >.git/info/exclude &&
		printf "hidden-core/\n\n" >.git/core-exclude &&
		git status --porcelain >/dev/null &&
		printf "hidden-info/\n" >.git/info/exclude &&
		printf "hidden-core/\n" >.git/core-exclude &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-standard-excludes-legacy" \
			git --no-optional-locks status --porcelain \
			>../standard-excludes-legacy-actual &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../standard-excludes-legacy-expect &&
		test_cmp ../standard-excludes-legacy-expect \
			../standard-excludes-legacy-actual &&
		printf "elsewhere-info/\n" >.git/info/exclude &&
		printf "elsewhere-core/\n" >.git/core-exclude &&
		GIT_TRACE2_PERF="$TRASH_DIRECTORY/trace-standard-excludes-change" \
			git --no-optional-locks status --porcelain \
			>../standard-excludes-change-actual &&
		git --no-optional-locks -c core.fsmonitor=false \
			-c core.untrackedCache=false status --porcelain \
			>../standard-excludes-change-expect &&
		test_cmp ../standard-excludes-change-expect \
			../standard-excludes-change-actual
	) &&
	test_grep "gitignore-invalidation:0" trace-standard-excludes-legacy &&
	test_grep ! "gitignore-invalidation-source:" \
		trace-standard-excludes-legacy &&
	test_grep "gitignore-invalidation:[1-9]" trace-standard-excludes-change &&
	test_grep "gitignore-invalidation-source:info/exclude" \
		trace-standard-excludes-change &&
	test_grep "gitignore-invalidation-source:core.excludesFile" \
		trace-standard-excludes-change &&
	test_grep "?? hidden-core/" standard-excludes-change-actual &&
	test_grep "?? hidden-info/" standard-excludes-change-actual
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

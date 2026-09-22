#!/bin/sh

test_description='index file specific tests'

. ./test-lib.sh

sane_unset GIT_TEST_SPLIT_INDEX

test_expect_success 'setup' '
	echo 1 >a
'

test_expect_success 'bogus GIT_INDEX_VERSION issues warning' '
	(
		rm -f .git/index &&
		GIT_INDEX_VERSION=2bogus &&
		export GIT_INDEX_VERSION &&
		git add a 2>err &&
		sed "s/[0-9]//" err >actual.err &&
		sed -e "s/ Z$/ /" <<-\EOF >expect.err &&
			warning: GIT_INDEX_VERSION set, but the value is invalid.
			Using version Z
		EOF
		test_cmp expect.err actual.err
	)
'

test_expect_success 'out of bounds GIT_INDEX_VERSION issues warning' '
	(
		rm -f .git/index &&
		GIT_INDEX_VERSION=1 &&
		export GIT_INDEX_VERSION &&
		git add a 2>err &&
		sed "s/[0-9]//" err >actual.err &&
		sed -e "s/ Z$/ /" <<-\EOF >expect.err &&
			warning: GIT_INDEX_VERSION set, but the value is invalid.
			Using version Z
		EOF
		test_cmp expect.err actual.err
	)
'

test_expect_success 'no warning with bogus GIT_INDEX_VERSION and existing index' '
	(
		GIT_INDEX_VERSION=1 &&
		export GIT_INDEX_VERSION &&
		git add a 2>actual.err &&
		test_must_be_empty actual.err
	)
'

test_expect_success 'out of bounds index.version issues warning' '
	(
		sane_unset GIT_INDEX_VERSION &&
		rm -f .git/index &&
		git config --add index.version 1 &&
		git add a 2>err &&
		sed "s/[0-9]//" err >actual.err &&
		sed -e "s/ Z$/ /" <<-\EOF >expect.err &&
			warning: index.version set, but the value is invalid.
			Using version Z
		EOF
		test_cmp expect.err actual.err
	)
'

test_expect_success 'index.skipHash config option' '
	rm -f .git/index &&
	git -c index.skipHash=true add a &&
	test_trailing_hash .git/index >hash &&
	echo $(test_oid zero) >expect &&
	test_cmp expect hash &&
	git fsck &&

	rm -f .git/index &&
	git -c feature.manyFiles=true add a &&
	test_trailing_hash .git/index >hash &&
	cmp expect hash &&

	rm -f .git/index &&
	git -c feature.manyFiles=true \
	    -c index.skipHash=false add a &&
	test_trailing_hash .git/index >hash &&
	! cmp expect hash &&

	test_commit start &&
	git -c protocol.file.allow=always submodule add ./ sub &&
	git config index.skipHash false &&
	git -C sub config index.skipHash true &&
	rm -f .git/modules/sub/index &&
	>sub/file &&
	git -C sub add a &&
	test_trailing_hash .git/modules/sub/index >hash &&
	test_cmp expect hash &&
	git -C sub fsck
'

test_index_version () {
	INDEX_VERSION_CONFIG=$1 &&
	FEATURE_MANY_FILES=$2 &&
	ENV_VAR_VERSION=$3
	EXPECTED_OUTPUT_VERSION=$4 &&
	(
		rm -f .git/index &&
		rm -f .git/config &&
		if test "$INDEX_VERSION_CONFIG" -ne 0
		then
			git config --add index.version $INDEX_VERSION_CONFIG
		fi &&
		git config --add feature.manyFiles $FEATURE_MANY_FILES
		if test "$ENV_VAR_VERSION" -ne 0
		then
			GIT_INDEX_VERSION=$ENV_VAR_VERSION &&
			export GIT_INDEX_VERSION
		else
			unset GIT_INDEX_VERSION
		fi &&
		git add a &&
		echo $EXPECTED_OUTPUT_VERSION >expect &&
		git update-index --show-index-version >actual &&
		test_cmp expect actual
	)
}

test_expect_success 'index version config precedence' '
	test_index_version 0 false 0 2 &&
	test_index_version 2 false 0 2 &&
	test_index_version 3 false 0 2 &&
	test_index_version 4 false 0 4 &&
	test_index_version 2 false 4 4 &&
	test_index_version 2 true 0 2 &&
	test_index_version 0 true 0 4 &&
	test_index_version 0 true 2 2
'

test_expect_success 'setup opportunistic index writes' '
	test_create_repo write-index &&
	(
		cd write-index &&
		echo content >file &&
		test-tool chmtime -60 file &&
		git add file &&
		git ls-files --stage >expect &&
		sed s/100644/100755/ expect >expect-executable &&
		cat expect-executable expect >expect-published &&
		cat >expect-writes <<-\EOF &&
		1 0
		0 0
		1 0
		0 0
		EOF
		write_script .git/hooks/post-index-change <<-\EOF
		git ls-files --stage >>actual
		EOF
	)
'

for split in false true
do
	for skip_hash in false true
	do
		test_expect_success "opportunistic writes acknowledge changes (split=$split, skipHash=$skip_hash)" '
			(
				cd write-index &&
				git config core.splitIndex $split &&
				git config index.skipHash $skip_hash &&
				git update-index --refresh &&
				>actual &&
				test-tool read-cache --write-index file >writes &&
				test_cmp expect-writes writes &&
				test_cmp expect-published actual
			)
		'
	done
done

test_expect_success 'opportunistic writes preserve dirty state after alternate output' '
	(
		cd write-index &&
		>actual &&
		echo "1 1" >expect-writes &&
		test-tool read-cache --write-index file .git/alternate-index >writes &&
		test_cmp expect-writes writes &&
		test_cmp expect actual &&
		GIT_INDEX_FILE=.git/alternate-index git ls-files --stage >alternate &&
		test_cmp expect-executable alternate
	)
'

# This fault removes a lockfile while its descriptor is still open.
test_expect_success !MINGW 'failed opportunistic write preserves dirty state' '
	(
		cd write-index &&
		echo "0 1" >expect-writes &&
		test-tool read-cache --write-index file --fail-write >writes &&
		test_cmp expect-writes writes &&
		git ls-files --stage >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'fsmonitor changes after an opportunistic write are persisted' '
	test_config -C write-index core.fsmonitor .git/hooks/fsmonitor &&
	test_config -C write-index core.fsmonitorHookVersion 2 &&
	test_when_finished "git -C write-index -c core.fsmonitor=false update-index --no-fsmonitor" &&
	(
		cd write-index &&
		write_script .git/hooks/fsmonitor <<-\EOF &&
		printf "token\\0"
		EOF
		write_script .git/hooks/post-index-change <<-\EOF &&
		git ls-files --stage >>actual &&
		git ls-files -f file >>actual-flags
		EOF
		>actual &&
		>actual-flags &&
		cat expect-published expect >expect-fsmonitor &&
		cat >expect-writes <<-\EOF &&
		1 0
		0 0
		1 0
		0 0
		1 0
		0 0
		EOF
		cat >expect-flags <<-\EOF &&
		H file
		H file
		h file
		EOF
		test-tool read-cache --write-index file >writes &&
		test_cmp expect-writes writes &&
		test_cmp expect-fsmonitor actual &&
		test_cmp expect-flags actual-flags
	)
'

test_expect_success 'opportunistic write does not overwrite a replaced index' '
	(
		cd write-index &&
		cp .git/index .git/replacement-index &&
		echo replacement >other &&
		GIT_INDEX_FILE=.git/replacement-index git add other &&
		GIT_INDEX_FILE=.git/replacement-index git ls-files --stage >expect-replacement &&
		write_script .git/hooks/post-index-change <<-\EOF &&
		if test -f .git/replacement-index
		then
			mv .git/replacement-index .git/index
		fi
		EOF
		cat >expect-writes <<-\EOF &&
		1 0
		0 0
		0 1
		0 1
		EOF
		test-tool read-cache --write-index file >writes &&
		test_cmp expect-writes writes &&
		git ls-files --stage >actual &&
		test_cmp expect-replacement actual
	)
'

test_expect_success 'gentle detached reader rejects an index changed during admission' '
	test_create_repo tree-snapshot &&
	(
		cd tree-snapshot &&
		git config index.recordendofindexentries true &&
		test_commit base &&
		for skip_hash in false true
		do
			git -c index.skipHash=$skip_hash update-index --force-write-index &&
			test-tool read-cache --tree-snapshot &&
			test_expect_code 1 test-tool read-cache --tree-snapshot --touch-index \
				>out 2>err &&
			test_must_be_empty out &&
			test_must_be_empty err || return 1
		done
	)
'

test_done

#!/bin/sh

test_description='test quickfetch from local'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

copy_sparse_object () {
	git -C sparse-source cat-file "$1" "$2" |
	git -C sparse-target hash-object -w -t "$1" --stdin >copied &&
	echo "$2" >expected &&
	test_cmp expected copied
}

test_expect_success setup '

	test_tick &&
	echo ichi >file &&
	git add file &&
	git commit -m initial &&

	cnt=$( (
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	test $cnt -eq 3
'

test_expect_success 'clone without alternate' '

	(
		mkdir cloned &&
		cd cloned &&
		git init-db &&
		git remote add -f origin ..
	) &&
	cnt=$( (
		cd cloned &&
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	test $cnt -eq 3
'

test_expect_success 'further commits in the original' '

	test_tick &&
	echo ni >file &&
	git commit -a -m second &&

	cnt=$( (
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	test $cnt -eq 6
'

test_expect_success 'copy commit and tree but not blob by hand' '

	git rev-list --objects HEAD |
	git pack-objects --stdout |
	(
		cd cloned &&
		git unpack-objects
	) &&

	cnt=$( (
		cd cloned &&
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	test $cnt -eq 6 &&

	blob=$(git rev-parse HEAD:file | sed -e "s|..|&/|") &&
	test -f "cloned/.git/objects/$blob" &&
	rm -f "cloned/.git/objects/$blob" &&

	cnt=$( (
		cd cloned &&
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	test $cnt -eq 5

'

test_expect_success 'quickfetch should not leave a corrupted repository' '

	(
		cd cloned &&
		git fetch
	) &&

	cnt=$( (
		cd cloned &&
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	test $cnt -eq 6

'

test_expect_success 'existing fetch tip skips excluded tree expansion' '
	file_oid=$(git -C cloned rev-parse origin/main:file) &&
	old_tree=$(printf "100644 blob %s\\tunrelated\\n" "$file_oid" |
		git -C cloned mktree) &&
	git -C cloned update-ref refs/tags/unrelated-tree "$old_tree" &&
	git -C cloned rev-parse origin/main >existing-tip &&
	GIT_TRACE2_EVENT="$PWD/unoptimized.trace" git -C cloned rev-list \
		--objects --stdin --not --all --quiet --alternate-refs \
		<existing-tip &&
	test_trace2_data revision pending-negative-tree/trees-expanded \
		"[1-9][0-9]*" <unoptimized.trace &&
	GIT_TRACE2_EVENT="$PWD/already-connected.trace" git -C cloned fetch &&
	test_trace2_data rev-list connectivity/skip-excluded-trees 1 \
		<already-connected.trace &&
	! test_trace2_data revision pending-negative-tree/roots \
		"[1-9][0-9]*" \
		<already-connected.trace &&
	git -C cloned update-ref -d refs/tags/unrelated-tree
'

test_expect_success 'sparse connectivity falls back for moved old objects' '
	test_create_repo sparse-source &&
	test_create_repo sparse-target &&
	mkdir -p sparse-source/old sparse-source/new &&
	echo old >sparse-source/old/file &&
	git -C sparse-source add old/file &&
	git -C sparse-source commit -m base &&
	base=$(git -C sparse-source rev-parse HEAD) &&
	base_tree=$(git -C sparse-source rev-parse "HEAD^{tree}") &&
	old_tree=$(git -C sparse-source rev-parse HEAD:old) &&
	git -C sparse-source mv old/file new/renamed &&
	git -C sparse-source commit -m moved &&
	moved=$(git -C sparse-source rev-parse HEAD) &&
	moved_tree=$(git -C sparse-source rev-parse "HEAD^{tree}") &&
	new_tree=$(git -C sparse-source rev-parse HEAD:new) &&
	copy_sparse_object commit "$base" &&
	copy_sparse_object tree "$base_tree" &&
	copy_sparse_object tree "$old_tree" &&
	copy_sparse_object commit "$moved" &&
	copy_sparse_object tree "$moved_tree" &&
	copy_sparse_object tree "$new_tree" &&
	git -C sparse-target update-ref refs/heads/main "$base" &&
	printf "%s\n" "$moved" >moved-tip &&
	git -C sparse-target rev-list --objects --stdin --not --all \
		--quiet <moved-tip &&
	GIT_TRACE2_EVENT="$PWD/sparse-moved.trace" \
		git -C sparse-target rev-list --objects --stdin --not --all \
		--quiet --connectivity-check <moved-tip &&
	test_trace2_data rev-list connectivity/sparse-excluded-trees 1 \
		<sparse-moved.trace &&
	! test_trace2_data rev-list edge-mark/roots "[0-9]*" \
		<sparse-moved.trace &&
	test_region revision connectivity_dense_fallback sparse-moved.trace >/dev/null
'

test_expect_success 'sparse connectivity rejects a new missing blob' '
	echo fresh >sparse-source/new/fresh &&
	git -C sparse-source add new/fresh &&
	git -C sparse-source commit -m fresh &&
	fresh=$(git -C sparse-source rev-parse HEAD) &&
	fresh_tree=$(git -C sparse-source rev-parse "HEAD^{tree}") &&
	fresh_dir=$(git -C sparse-source rev-parse HEAD:new) &&
	fresh_blob=$(git -C sparse-source rev-parse HEAD:new/fresh) &&
	copy_sparse_object commit "$fresh" &&
	copy_sparse_object tree "$fresh_tree" &&
	copy_sparse_object tree "$fresh_dir" &&
	printf "%s\n" "$fresh" >fresh-tip &&
	GIT_TRACE2_EVENT="$PWD/sparse-fresh.trace" \
		test_must_fail git -C sparse-target rev-list --objects --stdin \
		--not --all --quiet --connectivity-check <fresh-tip 2>fresh.err &&
	test_grep "missing blob object .$fresh_blob." fresh.err &&
	test_region revision connectivity_dense_fallback sparse-fresh.trace >/dev/null
'

test_expect_success 'sparse connectivity still checks a tag pointing to a tree' '
	git -C sparse-source tag -a -m tree-tip tree-tip "$fresh_tree" &&
	tree_tag=$(git -C sparse-source rev-parse refs/tags/tree-tip) &&
	copy_sparse_object tag "$tree_tag" &&
	printf "%s\n" "$tree_tag" >tree-tag-tip &&
	GIT_TRACE2_EVENT="$PWD/sparse-tree-tag.trace" \
		test_must_fail git -C sparse-target rev-list --objects --stdin \
		--not --all --quiet --connectivity-check \
		<tree-tag-tip 2>tree-tag.err &&
	test_grep "missing blob object .$fresh_blob." tree-tag.err &&
	test_region revision connectivity_dense_fallback sparse-tree-tag.trace >/dev/null
'

test_expect_success 'sparse connectivity rejects a new missing tree' '
	mkdir sparse-source/0missing &&
	echo fresh >sparse-source/0missing/file &&
	git -C sparse-source add 0missing/file &&
	git -C sparse-source commit -m missing-tree &&
	missing_tree_tip=$(git -C sparse-source rev-parse HEAD) &&
	missing_tree_root=$(git -C sparse-source rev-parse "HEAD^{tree}") &&
	missing_tree=$(git -C sparse-source rev-parse HEAD:0missing) &&
	copy_sparse_object commit "$missing_tree_tip" &&
	copy_sparse_object tree "$missing_tree_root" &&
	printf "%s\n" "$missing_tree_tip" >missing-tree-tip &&
	GIT_TRACE2_EVENT="$PWD/sparse-missing-tree.trace" \
		test_must_fail git -C sparse-target rev-list --objects --stdin \
		--not --all --quiet --connectivity-check \
		<missing-tree-tip 2>missing-tree.err &&
	test_grep "bad tree object $missing_tree" missing-tree.err &&
	test_region revision connectivity_dense_fallback sparse-missing-tree.trace >/dev/null
'

test_expect_success 'shallow connectivity keeps the dense tree walk' '
	test_when_finished "rm -f sparse-target/.git/shallow" &&
	git -C sparse-target rev-parse refs/heads/main >sparse-target/.git/shallow &&
	GIT_TRACE2_EVENT="$PWD/sparse-shallow.trace" \
		git -C sparse-target rev-list --objects --stdin --not --all \
		--quiet --connectivity-check <moved-tip &&
	test_trace2_data rev-list connectivity/sparse-excluded-trees 0 \
		<sparse-shallow.trace &&
	test_region ! revision connectivity_dense_fallback sparse-shallow.trace >/dev/null
'

test_expect_success 'quickfetch should not copy from alternate' '

	(
		mkdir quickclone &&
		cd quickclone &&
		git init-db &&
		(cd ../.git/objects && pwd) >.git/objects/info/alternates &&
		git remote add origin .. &&
		git fetch -k -k
	) &&
	obj_cnt=$( (
		cd quickclone &&
		git count-objects | sed -e "s/ *objects,.*//"
	) ) &&
	pck_cnt=$( (
		cd quickclone &&
		git count-objects -v | sed -n -e "/packs:/{
				s/packs://
				p
				q
			}"
	) ) &&
	origin_main=$( (
		cd quickclone &&
		git rev-parse origin/main
	) ) &&
	echo "loose objects: $obj_cnt, packfiles: $pck_cnt" &&
	test $obj_cnt -eq 0 &&
	test $pck_cnt -eq 0 &&
	test z$origin_main = z$(git rev-parse main)

'

test_expect_success 'quickfetch should handle ~1000 refs (on Windows)' '

	git gc &&
	head=$(git rev-parse HEAD) &&
	branchprefix="$head refs/heads/branch" &&
	for i in 0 1 2 3 4 5 6 7 8 9; do
		for j in 0 1 2 3 4 5 6 7 8 9; do
			for k in 0 1 2 3 4 5 6 7 8 9; do
				echo "$branchprefix$i$j$k" >> .git/packed-refs || return 1
			done
		done
	done &&
	(
		cd cloned &&
		git fetch &&
		git fetch
	)

'

test_done

#!/bin/sh

test_description='git archive in partial clones'

TEST_NO_CREATE_REPO=1
. ./test-lib.sh

test_expect_success 'setup archive source' '
	git init source &&
	git -C source config uploadpack.allowfilter true &&
	git -C source config uploadpack.allowanysha1inwant true &&
	mkdir -p source/selected/ignored source/unrelated &&
	cat >source/.gitattributes <<-\EOF &&
	.gitattributes export-ignore
	selected/ignored export-ignore
	EOF
	cat >source/selected/.gitattributes <<-\EOF &&
	* chosen
	*.txt text eol=crlf
	skip.txt export-ignore
	subst export-subst
	EOF
	echo first >source/selected/one.txt &&
	echo second >source/selected/two.txt &&
	cp source/selected/one.txt source/selected/duplicate.txt &&
	echo "\$Format:%s\$" >source/selected/subst &&
	echo ignored-file >source/selected/skip.txt &&
	echo ignored-directory >source/selected/ignored/file &&
	echo "* nested-chosen" >source/selected/ignored/.gitattributes &&
	echo unrelated >source/unrelated/file &&
	echo "* unrelated" >source/unrelated/.gitattributes &&
	git -C source add . &&
	git -C source commit -m archive-source
'

for format in tar zip
do
	test_expect_success "$format archive fetches only selected blobs in batches" '
		git -C source archive --format="$format" --prefix=output/ \
			HEAD selected >expect &&
		git clone --bare --filter=blob:none \
			"file://$PWD/source" "$format.git" &&
		GIT_TRACE_PACKET="$PWD/$format.trace" \
			git -C "$format.git" archive --format="$format" \
			--prefix=output/ HEAD selected >actual &&
		test_cmp_bin expect actual &&

		git -C "$format.git" rev-list --objects --missing=print HEAD >objects &&
		sed -n "s/^?//p" objects | sort >actual-missing &&
		git -C source rev-parse HEAD:selected/skip.txt \
			HEAD:selected/ignored/file HEAD:unrelated/file \
			HEAD:unrelated/.gitattributes >expect-unsorted &&
		sort expect-unsorted >expect-missing &&
		test_cmp expect-missing actual-missing &&

		# One fetch for attributes, followed by one for archive contents.
		grep "fetch> done" "$format.trace" >fetches &&
		test_line_count = 2 fetches &&

		>"$format-warm.trace" &&
		GIT_TRACE_PACKET="$PWD/$format-warm.trace" \
			git -C "$format.git" archive --format="$format" \
			--prefix=output/ HEAD selected >warm &&
		test_cmp_bin expect warm &&
		test_grep ! "fetch> done" "$format-warm.trace"
	'
done

test_expect_success 'previously read payloads leave unrelated blobs missing' '
	git clone --no-checkout --filter=blob:none \
		"file://$PWD/source" preloaded &&
	git -C preloaded cat-file blob HEAD:selected/one.txt >actual &&
	test_cmp source/selected/one.txt actual &&
	git -C source rev-parse HEAD:.gitattributes \
		HEAD:selected/.gitattributes HEAD:unrelated/file >candidates &&
	sed "s/^/?/" candidates >expect-missing &&
	git -C preloaded rev-list --objects --missing=print HEAD >objects &&
	grep -F -f expect-missing objects >actual-missing &&
	test_line_count = 3 actual-missing &&

	git -C source archive HEAD selected/one.txt >expect &&
	GIT_TRACE_PACKET="$PWD/preloaded.trace" \
		git -C preloaded archive HEAD selected/one.txt >actual &&
	test_cmp_bin expect actual &&
	grep "fetch> done" preloaded.trace >fetches &&
	test_line_count = 1 fetches &&
	git -C preloaded rev-list --objects --missing=print HEAD >objects &&
	grep -F -f expect-missing objects >actual-missing &&
	tail -n 1 expect-missing >expect-unrelated &&
	test_cmp expect-unrelated actual-missing
'

test_expect_success 'attribute pathspecs are evaluated after attribute prefetch' '
	git clone --bare --filter=blob:none "file://$PWD/source" attr.git &&
	git -C source archive HEAD ":(attr:chosen)selected" \
		":(exclude,attr:chosen)selected/two.txt" >expect &&
	GIT_TRACE_PACKET="$PWD/attr.trace" git -C attr.git archive HEAD \
		":(attr:chosen)selected" ":(exclude,attr:chosen)selected/two.txt" >actual &&
	test_cmp_bin expect actual &&
	grep "fetch> done" attr.trace >fetches &&
	test_line_count = 2 fetches &&
	git -C attr.git rev-list --objects --missing=print HEAD >objects &&
	missing=$(git -C source rev-parse HEAD:selected/two.txt) &&
	test_grep "^?$missing$" objects
'

test_expect_success 'builtin_objectmode pathspec reads the archived tree in a bare clone' '
	git clone --bare --filter=blob:none "file://$PWD/source" mode.git &&
	git -C source archive HEAD ":(attr:builtin_objectmode=100644)selected" >expect &&
	git -C mode.git archive HEAD ":(attr:builtin_objectmode=100644)selected" >actual &&
	test_cmp_bin expect actual &&
	test_must_fail git -C mode.git archive HEAD ":(attr:builtin_objectmode=040000)selected"
'

test_expect_success 'an export-ignored path still passes pathspec validation' '
	git clone --bare --filter=blob:none "file://$PWD/source" ignored.git &&
	git -C source archive HEAD selected/ignored/file >expect &&
	git -C ignored.git archive HEAD selected/ignored/file >actual &&
	test_cmp_bin expect actual &&
	git -C ignored.git rev-list --objects --missing=print HEAD >objects &&
	missing=$(git -C source rev-parse HEAD:selected/ignored/file) &&
	test_grep "^?$missing$" objects
'

test_expect_success 'attribute validation includes paths excluded by another argument' '
	git clone --bare --filter=blob:none "file://$PWD/source" excluded.git &&
	git -C source archive HEAD ":(attr:nested-chosen)selected/ignored/file" \
		":!selected/ignored" >expect &&
	GIT_TRACE_PACKET="$PWD/excluded.trace" git -C excluded.git archive HEAD \
		":(attr:nested-chosen)selected/ignored/file" ":!selected/ignored" >actual &&
	test_cmp_bin expect actual &&
	grep "fetch> done" excluded.trace >fetches &&
	test_line_count = 1 fetches
'

test_expect_success 'subtree and invocation subdirectory retain their attribute roots' '
	git clone --no-checkout --filter=blob:none "file://$PWD/source" subdir &&
	mkdir subdir/selected &&
	git -C source/selected archive HEAD >expect &&
	git -C subdir/selected archive HEAD >actual &&
	test_cmp_bin expect actual &&
	git -C source archive --mtime="2001-01-01 00:00:00 +0000" HEAD:selected >expect &&
	git -C subdir archive --mtime="2001-01-01 00:00:00 +0000" HEAD:selected >actual &&
	test_cmp_bin expect actual
'

test_expect_success 'explicit attribute source overrides only worktree-attributes mode' '
	echo "selected export-ignore" >attributes &&
	blob=$(git -C source hash-object -w --stdin <attributes) &&
	tree=$(printf "100644 blob %s\t.gitattributes\n" "$blob" |
		git -C source mktree) &&
	commit=$(echo alternate-attributes | git -C source commit-tree "$tree") &&
	git -C source update-ref refs/heads/attributes "$commit" &&
	git clone --bare --filter=blob:none "file://$PWD/source" override.git &&
	git -C source archive HEAD selected >expect &&
	git -C override.git --attr-source=attributes archive HEAD selected >actual &&
	test_cmp_bin expect actual &&
	git -C source --attr-source=attributes archive --worktree-attributes HEAD selected >expect &&
	git -C override.git --attr-source=attributes archive --worktree-attributes HEAD selected >actual &&
	test_cmp_bin expect actual &&
	test_must_fail git -C override.git --attr-source=does-not-exist \
		archive HEAD selected >actual 2>err &&
	test_grep "bad --attr-source or GIT_ATTR_SOURCE" err
'

test_expect_success 'the second archive walk revisits differently attributed siblings' '
	git init siblings &&
	git -C siblings config uploadpack.allowfilter true &&
	git -C siblings config uploadpack.allowanysha1inwant true &&
	mkdir siblings/a siblings/b &&
	echo ".gitattributes export-ignore" >siblings/.gitattributes &&
	echo "one export-ignore" >siblings/a/.gitattributes &&
	echo "two export-ignore" >siblings/b/.gitattributes &&
	echo hidden-a >siblings/a/one &&
	echo visible-a >siblings/a/two &&
	echo visible-b >siblings/b/one &&
	echo hidden-b >siblings/b/two &&
	git -C siblings add . &&
	git -C siblings commit -m siblings &&
	git -C siblings archive HEAD >expect.tar &&
	git clone --bare --filter=blob:none "file://$PWD/siblings" siblings.git &&
	git -C siblings.git archive HEAD >actual.tar &&
	test_cmp_bin expect.tar actual.tar &&
	printf "a/\na/two\nb/\nb/one\n" >expect-list &&
	"$TAR" tf actual.tar >actual-list &&
	test_cmp expect-list actual-list
'

test_expect_success 'symlinks are fetched but submodule commits are not' '
	git init modes &&
	git -C modes config uploadpack.allowfilter true &&
	git -C modes config uploadpack.allowanysha1inwant true &&
	echo target >modes/file &&
	git -C modes add file &&
	link=$(printf file | git -C modes hash-object -w --stdin) &&
	foreign=$(echo foreign-commit | git -C modes hash-object --stdin) &&
	git -C modes update-index --add --cacheinfo 120000,$link,link &&
	git -C modes update-index --add --cacheinfo 160000,$foreign,module &&
	git -C modes commit -m modes &&
	git -C modes archive HEAD >expect &&
	git clone --bare --filter=blob:none "file://$PWD/modes" modes.git &&
	GIT_TRACE_PACKET="$PWD/modes.trace" git -C modes.git archive HEAD >actual &&
	test_cmp_bin expect actual &&
	grep "fetch> done" modes.trace >fetches &&
	test_line_count = 1 fetches
'

test_expect_success 'symlink attributes read their blob without following the target' '
	attributes=$(echo "file export-ignore" | git -C modes hash-object -w --stdin) &&
	git -C modes update-index --add --cacheinfo 120000,$attributes,.gitattributes &&
	git -C modes commit -m symlink-attributes &&
	git -C modes archive HEAD file >expect &&
	git clone --bare --filter=blob:none "file://$PWD/modes" symlink-attr.git &&
	git -C symlink-attr.git archive HEAD file >actual &&
	test_cmp_bin expect actual &&
	git -C symlink-attr.git rev-list --objects --missing=print HEAD >objects &&
	missing=$(git -C modes rev-parse HEAD:file) &&
	test_grep "^?$missing$" objects
'

test_expect_success 'missing trees retain lazy fetching without unrelated blobs' '
	git clone --bare --filter=tree:0 "file://$PWD/source" treeless.git &&
	git -C source archive HEAD selected >expect &&
	git -C treeless.git archive HEAD selected >actual &&
	test_cmp_bin expect actual &&
	git -C treeless.git rev-list --objects --missing=print HEAD >objects &&
	missing=$(git -C source rev-parse HEAD:unrelated/file) &&
	test_grep "^?$missing$" objects
'

test_done

#!/bin/sh

test_description='git-status with core.ignorecase=true'

. ./test-lib.sh

test_expect_success 'status with hash collisions' '
	# note: "V/", "V/XQANY/" and "WURZAUP/" produce the same hash code
	# in name-hash.c::hash_name
	mkdir V &&
	mkdir V/XQANY &&
	mkdir WURZAUP &&
	touch V/XQANY/test &&
	git config core.ignorecase true &&
	git add . &&
	# test is successful if git status completes (no endless loop)
	git status
'

test_expect_success 'bounded index probe' '
	test_create_repo probe &&
	(
		cd probe &&
		blob=$(echo blob | git hash-object -w --stdin) &&
		tree=$(git mktree </dev/null) &&
		commit=$(echo commit | git commit-tree "$tree") &&
		{
			printf "100644 %s\\texact/tracked\\n" "$blob" &&
			printf "100644 %s\\tALIAS/two\\n" "$blob" &&
			printf "100644 %s\\talias/one\\n" "$blob" &&
			printf "100644 %s\\tfinal/Foo\\n" "$blob" &&
			printf "100644 %s\\tfinal/foo\\n" "$blob" &&
			printf "100644 %s 1\\tstaged\\n" "$blob" &&
			printf "100644 %s 2\\tstaged\\n" "$blob" &&
			printf "100644 %s 1\\tdf\\n" "$blob" &&
			printf "100644 %s 2\\tdf/child\\n" "$blob" &&
			printf "160000 %s\\tgitlink\\n" "$commit"
		} | git update-index --index-info &&
		{
			test-tool read-cache --icase-probe=exact/missing &&
			test-tool read-cache --icase-probe=exact/TRACKED &&
			test-tool read-cache --icase-probe=EXACT/missing &&
			test-tool read-cache --icase-probe=alias/missing &&
			test-tool read-cache --icase-probe=final/fOo &&
			test-tool read-cache --icase-probe=staged &&
			test-tool read-cache --icase-probe=exact &&
			test-tool read-cache --icase-probe=df &&
			test-tool read-cache --icase-probe=gitlink &&
			test-tool read-cache --icase-dir-probe=exact &&
			test-tool read-cache --icase-dir-probe=EXACT &&
			test-tool read-cache --icase-dir-probe=exact/tracked &&
			test-tool read-cache --icase-dir-probe=alias &&
			test-tool read-cache --icase-dir-probe=df &&
			test-tool read-cache --icase-dir-probe=gitlink &&
			test-tool read-cache --icase-dir-probe=missing
		} | cut -d" " -f1 >actual &&
		cat >expect <<-\EOF &&
		absent
		present
		unknown
		unknown
		unknown
		present
		absent
		unknown
		present
		present
		present
		absent
		unknown
		present
		absent
		absent
		EOF
		test_cmp expect actual
	)
'

test_expect_success 'bounded index probe exhausts budget' '
	test_create_repo budget &&
	(
		cd budget &&
		blob=$(echo blob | git hash-object -w --stdin) &&
		{
			for i in $(test_seq 1 1024)
			do
				printf "100644 %s\\tz%s/file\\n" "$blob" "$i" ||
				return 1
			done &&
			printf "100644 %s\\tz/file\\n" "$blob"
		} | git update-index --index-info &&
		echo "unknown 4" >expect &&
		test-tool read-cache --icase-probe=z/missing 4 >actual &&
		test_cmp expect actual &&
		test-tool read-cache --icase-dir-probe=z 4 >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'bounded index probe skips unrelated prefixes' '
	(
		cd budget &&
		cat >expect <<-\EOF &&
		absent
		absent
		absent
		EOF
		{
			test-tool read-cache --icase-probe=missing 16 &&
			test-tool read-cache --icase-probe=zmissing 16 &&
			test-tool read-cache --icase-probe=z/missing 16
		} >probe-actual &&
		cut -d" " -f1 probe-actual >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'directory traversal preserves case aliases and unmerged files' '
	test_create_repo traversal &&
	(
		cd traversal &&
		git config core.ignoreCase true &&
		blob=$(echo blob | git hash-object -w --stdin) &&
		tree=$(git mktree </dev/null) &&
		commit=$(echo commit | git commit-tree "$tree") &&
		{
			printf "100644 %s\\texact/tracked\\n" "$blob" &&
			printf "100644 %s 2\\tstaged\\n" "$blob" &&
			printf "100644 %s\\tFold/tracked\\n" "$blob" &&
			printf "100644 %s\\tLINK/tracked\\n" "$blob" &&
			printf "160000 %s\\tlink\\n" "$commit"
		} | git update-index --index-info &&
		mkdir exact fold link newdir &&
		touch exact/tracked exact/new fold/tracked fold/new &&
		touch staged link/tracked link/new newdir/new &&
		echo link/new >../expect &&
		git ls-files --others --exclude-standard --directory -- link >../actual &&
		test_cmp ../expect ../actual &&
		git ls-files --others --exclude-standard --directory >../actual &&
		cat >../expect <<-\EOF &&
		exact/new
		fold/new
		link/new
		newdir/
		EOF
		test_cmp ../expect ../actual
	)
'

test_done

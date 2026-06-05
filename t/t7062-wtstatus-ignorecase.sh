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
			test-tool read-cache --icase-probe=gitlink
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
				printf "100644 %s\\ta%s/file\\n" "$blob" "$i" ||
				return 1
			done &&
			printf "100644 %s\\tz/file\\n" "$blob"
		} | git update-index --index-info &&
		echo "unknown 1024" >expect &&
		test-tool read-cache --icase-probe=z/missing >actual &&
		test_cmp expect actual
	)
'

test_done

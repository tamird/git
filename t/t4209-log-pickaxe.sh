#!/bin/sh

test_description='log --grep/--author/--regexp-ignore-case/-S/-G'

. ./test-lib.sh

test_lazy_prereq ENHANCED_BRE '
	test-tool regex --silent "a\|b" a
'

test_lazy_prereq EMPTY_ERE '
	test-tool regex --silent "missing|" "" EXTENDED &&
	test-tool regex --silent "missing||absent" "" EXTENDED
'

test_lazy_prereq EMPTY_ENHANCED_BRE '
	test-tool regex --silent "missing\|" "" &&
	test-tool regex --silent "missing\|\|absent" ""
'

test_lazy_prereq SJIS_REGEX_NOMATCH '
	invalid=$(printf "\\202foo") &&
	LC_ALL=C test-tool regex --silent \
		"foo|absent" "$invalid" EXTENDED &&
	sjis_status=$(
		LC_ALL=ja_JP.SJIS test-tool regex --silent \
			"foo|absent" "$invalid" EXTENDED
		echo $?
	) &&
	nomatch_status=$(
		LC_ALL=ja_JP.SJIS test-tool regex --silent \
			absent present EXTENDED
		echo $?
	) &&
	test "$sjis_status" -ne 0 &&
	test "$sjis_status" = "$nomatch_status"
'

test_lazy_prereq TURKISH_ICASE '
	dotless_i=$(printf "\\375") &&
	c_status=$(
		LC_ALL=C test-tool regex --silent \
			"Ix|absent" "${dotless_i}x" ICASE EXTENDED
		echo $?
	) &&
	test "$c_status" -ne 0 &&
	LC_ALL=tr_TR.ISO8859-9 test-tool regex --silent \
		"Ix|absent" "${dotless_i}x" ICASE EXTENDED
'

test_log () {
	expect=$1
	kind=$2
	needle=$3
	shift 3
	rest=$@

	case $kind in
	--*)
		opt=$kind=$needle
		;;
	*)
		opt=$kind$needle
		;;
	esac
	case $expect in
	expect_nomatch)
		match=nomatch
		;;
	*)
		match=match
		;;
	esac

	test_expect_success "log $kind${rest:+ $rest} ($match)" "
		git log $rest $opt --format=%H >actual &&
		test_cmp $expect actual
	"
}

# test -i and --regexp-ignore-case and expect both to behave the same way
test_log_icase () {
	test_log $@ --regexp-ignore-case
	test_log $@ -i
}

test_expect_success setup '
	>expect_nomatch &&

	>file &&
	git add file &&
	test_tick &&
	git commit -m initial &&
	git rev-parse --verify HEAD >expect_initial &&

	echo Picked >file &&
	git add file &&
	test_tick &&
	git commit --author="Another Person <another@example.com>" -m second &&
	git rev-parse --verify HEAD >expect_second &&

	cat expect_second expect_initial >expect_both &&
	printf "\\202foo\\n" >sjis-body &&
	git -c i18n.commitEncoding=SJIS commit-tree \
		HEAD^{tree} -p HEAD <sjis-body >log-grep-sjis &&
	git cat-file commit "$(cat log-grep-sjis)" >log-grep-sjis.commit &&
	test_grep "^encoding SJIS\$" log-grep-sjis.commit &&
	sed '1,/^$/d' log-grep-sjis.commit >log-grep-sjis.body &&
	test_cmp_bin sjis-body log-grep-sjis.body &&
	printf "\\375x\\n" >turkish-body &&
	git -c i18n.commitEncoding=ISO-8859-9 commit-tree \
		HEAD^{tree} -p HEAD <turkish-body >log-grep-turkish &&
	git cat-file commit "$(cat log-grep-turkish)" >log-grep-turkish.commit &&
	test_grep "^encoding ISO-8859-9\$" log-grep-turkish.commit &&
	sed '1,/^$/d' log-grep-turkish.commit >log-grep-turkish.body &&
	test_cmp_bin turkish-body log-grep-turkish.body
'

test_expect_success ENHANCED_BRE 'log grep with enhanced BRE alternatives' '
	git log --grep="initial\\|second" --format=%H >actual &&
	test_cmp expect_both actual
'

test_expect_success 'log grep with literal ERE alternatives' '
	git log -E --grep="initial|second" --format=%H >actual &&
	test_cmp expect_both actual
'

test_expect_success ENHANCED_BRE 'log grep with ignore-case enhanced BRE' '
	git log -i --grep="INITIAL\\|SECOND" --format=%H >actual &&
	test_cmp expect_both actual
'

test_expect_success 'log grep with case-insensitive EREs' '
	git log -i -E --grep="INITIAL|SECOND" --format=%H >actual &&
	test_cmp expect_both actual
'

test_expect_success TURKISH_ICASE 'log grep preserves locale folding' '
	LC_ALL=tr_TR.ISO8859-9 git log --encoding=none -1 -i -E \
		--grep="Ix|absent" --format=%H \
		$(cat log-grep-turkish) >actual &&
	test_cmp log-grep-turkish actual
'

test_expect_success 'log grep falls back for one-byte alternatives' '
	git log -E --grep="missing|i" --format=%H >actual &&
	test_cmp expect_initial actual
'

test_expect_success 'log grep prefilter requires complete pattern' '
	git log -E --grep="missing|s.cond" --format=%H >actual &&
	test_cmp expect_second actual
'

test_expect_success EMPTY_ERE 'log grep with trailing empty ERE branch' '
	git log -E --grep="missing|" --format=%H >actual &&
	test_cmp expect_both actual
'

test_expect_success EMPTY_ERE 'log grep with adjacent empty ERE branches' '
	git log -E --grep="missing||absent" --format=%H >actual &&
	test_cmp expect_both actual
'

test_expect_success EMPTY_ENHANCED_BRE 'log grep with empty enhanced BREs' '
	git log --grep="missing\\|" --format=%H >actual.trailing &&
	test_cmp expect_both actual.trailing &&
	git log --grep="missing\\|\\|absent" --format=%H >actual.adjacent &&
	test_cmp expect_both actual.adjacent
'

test_expect_success SJIS_REGEX_NOMATCH 'SJIS keyword hits use POSIX' '
	LC_ALL=ja_JP.SJIS git log --encoding=none -1 -E \
		--grep="foo|absent" --format=%H \
		$(cat log-grep-sjis) >actual &&
	test_must_be_empty actual
'

test_expect_success 'log --author with literal ERE alternatives' '
	git log -E --author="Another|Missing" --format=%H >actual &&
	test_cmp expect_second actual
'

test_expect_success 'usage' '
	test_expect_code 129 git log -S 2>err &&
	test_grep "switch.*requires a value" err &&

	test_expect_code 129 git log -G 2>err &&
	test_grep "switch.*requires a value" err &&

	test_expect_code 128 git log -Gregex -Sstring 2>err &&
	test_grep "cannot be used together" err &&

	test_expect_code 128 git log -Gregex --find-object=HEAD 2>err &&
	test_grep "cannot be used together" err &&

	test_expect_code 128 git log -Sstring --find-object=HEAD 2>err &&
	test_grep "cannot be used together" err &&

	test_expect_code 128 git log --pickaxe-all --find-object=HEAD 2>err &&
	test_grep "cannot be used together" err
'

test_expect_success 'usage: --pickaxe-regex' '
	test_expect_code 128 git log -Gregex --pickaxe-regex 2>err &&
	test_grep "cannot be used together" err
'

test_expect_success 'usage: --no-pickaxe-regex' '
	cat >expect <<-\EOF &&
	fatal: unrecognized argument: --no-pickaxe-regex
	EOF

	test_expect_code 128 git log -Sstring --no-pickaxe-regex 2>actual &&
	test_cmp expect actual &&

	test_expect_code 128 git log -Gstring --no-pickaxe-regex 2>err &&
	test_cmp expect actual
'

test_expect_success 'usage: -G and -S with empty argument' '
	cat >expect <<-\EOF &&
	error: -S requires a non-empty argument
	EOF

	test_expect_code 129 git log -S "" 2>actual &&
	test_cmp expect actual &&

	cat >expect <<-\EOF &&
	error: -G requires a non-empty argument
	EOF

	test_expect_code 129 git log -G "" 2>actual &&
	test_cmp expect actual
'

test_log	expect_initial	--grep initial
test_log	expect_nomatch	--grep InItial
test_log_icase	expect_initial	--grep InItial
test_log_icase	expect_nomatch	--grep initail

test_log	expect_second	--author Person
test_log	expect_nomatch	--author person
test_log_icase	expect_second	--author person
test_log_icase	expect_nomatch	--author spreon

test_log	expect_nomatch	-G picked
test_log	expect_second	-G Picked
test_log_icase	expect_nomatch	-G pickle
test_log_icase	expect_second	-G picked

test_expect_success 'log -G --textconv (missing textconv tool)' '
	echo "* diff=test" >.gitattributes &&
	test_must_fail git -c diff.test.textconv=missing log -Gfoo &&
	rm .gitattributes
'

test_expect_success 'log -G --no-textconv (missing textconv tool)' '
	echo "* diff=test" >.gitattributes &&
	git -c diff.test.textconv=missing log -Gfoo --no-textconv >actual &&
	test_cmp expect_nomatch actual &&
	rm .gitattributes
'

test_log	expect_nomatch	-S picked
test_log	expect_second	-S Picked
test_log_icase	expect_second	-S picked
test_log_icase	expect_nomatch	-S pickle

test_log	expect_nomatch	-S p.cked --pickaxe-regex
test_log	expect_second	-S P.cked --pickaxe-regex
test_log_icase	expect_second	-S p.cked --pickaxe-regex
test_log_icase	expect_nomatch	-S p.ckle --pickaxe-regex

test_expect_success 'log -S --textconv (missing textconv tool)' '
	echo "* diff=test" >.gitattributes &&
	test_must_fail git -c diff.test.textconv=missing log -Sfoo &&
	rm .gitattributes
'

test_expect_success 'log -S --no-textconv (missing textconv tool)' '
	echo "* diff=test" >.gitattributes &&
	git -c diff.test.textconv=missing log -Sfoo --no-textconv >actual &&
	test_cmp expect_nomatch actual &&
	rm .gitattributes
'

test_expect_success 'setup log -[GS] plain & regex' '
	test_create_repo GS-plain &&
	test_commit -C GS-plain --append A data.txt "a" &&
	test_commit -C GS-plain --append B data.txt "a a" &&
	test_commit -C GS-plain --append C data.txt "b" &&
	test_commit -C GS-plain --append D data.txt "[b]" &&
	test_commit -C GS-plain E data.txt "" &&

	# We also include E, the deletion commit
	git -C GS-plain log --grep="[ABE]" >A-to-B-then-E-log &&
	git -C GS-plain log --grep="[CDE]" >C-to-D-then-E-log &&
	git -C GS-plain log --grep="[DE]" >D-then-E-log &&
	git -C GS-plain log >full-log
'

test_expect_success 'log -G trims diff new/old [-+]' '
	git -C GS-plain log -G"[+-]a" >log &&
	test_must_be_empty log &&
	git -C GS-plain log -G"^a" >log &&
	test_cmp log A-to-B-then-E-log
'

test_expect_success 'log -S<pat> is not a regex, but -S<pat> --pickaxe-regex is' '
	git -C GS-plain log -S"a" >log &&
	test_cmp log A-to-B-then-E-log &&

	git -C GS-plain log -S"[a]" >log &&
	test_must_be_empty log &&

	git -C GS-plain log -S"[a]" --pickaxe-regex >log &&
	test_cmp log A-to-B-then-E-log &&

	git -C GS-plain log -S"[b]" >log &&
	test_cmp log D-then-E-log &&

	git -C GS-plain log -S"[b]" --pickaxe-regex >log &&
	test_cmp log C-to-D-then-E-log
'

test_expect_success 'setup log -[GS] binary & --text' '
	test_create_repo GS-bin-txt &&
	test_commit -C GS-bin-txt --printf A data.bin "a\na\0a\n" &&
	test_commit -C GS-bin-txt --append --printf B data.bin "a\na\0a\n" &&
	test_commit -C GS-bin-txt C data.bin "" &&
	git -C GS-bin-txt log >full-log
'

test_expect_success 'log -G ignores binary files' '
	git -C GS-bin-txt log -Ga >log &&
	test_must_be_empty log
'

test_expect_success 'log -G looks into binary files with -a' '
	git -C GS-bin-txt log -a -Ga >log &&
	test_cmp log full-log
'

test_expect_success 'log -G looks into binary files with textconv filter' '
	test_when_finished "rm GS-bin-txt/.gitattributes" &&
	(
		cd GS-bin-txt &&
		echo "* diff=bin" >.gitattributes &&
		git -c diff.bin.textconv=cat log -Ga >../log
	) &&
	test_cmp log full-log
'

test_expect_success 'log -S looks into binary files' '
	git -C GS-bin-txt log -Sa >log &&
	test_cmp log full-log
'

test_expect_success 'log -S --pickaxe-regex looks into binary files' '
	git -C GS-bin-txt log --pickaxe-regex -Sa >log &&
	test_cmp log full-log &&

	git -C GS-bin-txt log --pickaxe-regex -S"[a]" >log &&
	test_cmp log full-log
'

test_done

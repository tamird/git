#!/bin/sh
#
# Copyright (c) 2006 Junio C Hamano
#

test_description='git grep various.
'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

test_invalid_grep_expression() {
	params="$@" &&
	test_expect_success "invalid expression: grep $params" '
		test_must_fail git grep $params -- nonexisting
	'
}

LC_ALL=en_US.UTF-8 test-tool regex '^.$' '¿' &&
  test_set_prereq MB_REGEX

test_lazy_prereq REGEX_MATCH_ERROR '
	invalid=$(printf "\\377foo") &&
	LC_ALL=C test-tool regex --silent "foo|bar" "$invalid" EXTENDED &&
	invalid_status=$(
		LC_ALL=en_US.UTF-8 test-tool regex --silent \
			"foo|bar" "$invalid" EXTENDED
		echo $?
	) &&
	nomatch_status=$(
		LC_ALL=en_US.UTF-8 test-tool regex --silent \
			"foo|bar" absent EXTENDED
		echo $?
	) &&
	test "$invalid_status" -ne 0 &&
	test "$invalid_status" != "$nomatch_status"
'

test_lazy_prereq ENHANCED_BRE '
	test-tool regex --silent "a\|b" a
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

cat >hello.c <<EOF
#include <assert.h>
#include <stdio.h>

int main(int argc, const char **argv)
{
	printf("Hello world.\n");
	return 0;
	/* char ?? */
}

EOF

test_expect_success setup '
	cat >file <<-\EOF &&
	foo mmap bar
	foo_mmap bar
	foo_mmap bar mmap
	foo mmap bar_mmap
	foo_mmap bar mmap baz
	EOF
	cat >hello_world <<-\EOF &&
	Hello world
	HeLLo world
	Hello_world
	HeLLo_world
	EOF
	cat >ab <<-\EOF &&
	a+b*c
	a+bc
	abc
	EOF
	cat >d0 <<-\EOF &&
	d
	0
	EOF
	echo vvv >v &&
	echo ww w >w &&
	echo x x xx x >x &&
	echo y yy >y &&
	echo zzz > z &&
	mkdir t &&
	echo test >t/t &&
	echo vvv >t/v &&
	mkdir t/a &&
	echo vvv >t/a/v &&
	qz_to_tab_space >space <<-\EOF &&
	line without leading space1
	Zline with leading space1
	Zline with leading space2
	Zline with leading space3
	line without leading space2
	EOF
	cat >hello.ps1 <<-\EOF &&
	# No-op.
	function dummy() {}

	# Say hello.
	function hello() {
	  echo "Hello world."
	  echo "Hello again."
	} # hello

	# Still a no-op.
	function dummy() {}
	EOF
	printf "\200\nASCII\n" >invalid-utf8 &&
	if test_have_prereq FUNNYNAMES
	then
		echo unusual >"\"unusual\" pathname" &&
		echo unusual >"t/nested \"unusual\" pathname"
	fi &&
	if test_have_prereq MB_REGEX
	then
		echo "¿" >reverse-question-mark
	fi &&
	git add . &&
	test_tick &&
	git commit -m initial
'

test_expect_success ENHANCED_BRE,LIBPCRE2 \
	'BRE wildcard alternatives preserve matches' '
	test_when_finished "rm -f bre-lookahead" &&
	cat >bre-lookahead <<-\EOF &&
	sync_hash_applied_global
	.applied_manage/generated-requirements
	service_requirements
	test_requirements
	build_requirements
	EOF
	cat >expect <<-\EOF &&
	bre-lookahead:1:sync_hash_applied_global
	bre-lookahead:2:.applied_manage/generated-requirements
	bre-lookahead:3:service_requirements
	bre-lookahead:4:test_requirements
	bre-lookahead:5:build_requirements
	EOF
	git grep --no-index -n \
		"sync_hash_applied_global\\|\\.applied_manage/.*requirements\\|service_requirements\\|test_requirements\\|build_requirements" \
		-- bre-lookahead >actual &&
	test_cmp expect actual
'

test_expect_success LIBPCRE2 \
	'POSIX wildcard preserves matches' '
	test_when_finished "rm -f bre-lookahead" &&
	cat >bre-lookahead <<-\EOF &&
	copy UvIndex
	copy the UvIndex
	unrelated
	EOF
	cat >expect <<-\EOF &&
	bre-lookahead:1:copy UvIndex
	bre-lookahead:2:copy the UvIndex
	EOF
	git grep --no-index -n "copy.*UvIndex" -- bre-lookahead >actual &&
	test_cmp expect actual &&
	git grep --no-index -n -E "copy.*UvIndex" -- bre-lookahead >actual &&
	test_cmp expect actual &&
	printf "copy\rUvIndex\n" >bre-lookahead &&
	git grep --no-index -q "copy.*UvIndex" -- bre-lookahead
'

test_expect_success ENHANCED_BRE,LIBPCRE2 \
	'BRE candidate finder requires complete pattern' '
	test_when_finished "rm -f bre-lookahead" &&
	echo baz >bre-lookahead &&
	echo bre-lookahead:1:baz >expect &&
	git grep --no-index -n \
		"missing\\|b.z\\|absent.*needle" \
		-- bre-lookahead >actual &&
	test_cmp expect actual
'

test_expect_success ENHANCED_BRE,LIBPCRE2 \
	'BRE literal alternatives preserve matches' '
	test_when_finished "rm -f bre-lookahead" &&
	printf "foo\nbar\nbaz\n" >bre-lookahead &&
	printf "bre-lookahead:1:foo\nbre-lookahead:2:bar\n" >expect &&
	git grep --no-index -n "foo\\|bar" -- bre-lookahead >actual &&
	test_cmp expect actual
'

test_expect_success LIBPCRE2 'ERE literal alternatives preserve matches' '
	test_when_finished "rm -f ere-lookahead" &&
	cat >ere-lookahead <<-\EOF &&
	load_graph(
	direct_dependencies
	unrelated
	EOF
	cat >expect <<-\EOF &&
	ere-lookahead:1:load_graph(
	ere-lookahead:2:direct_dependencies
	EOF
	git grep --no-index -n -E \
		"load_graph\\(|direct_dependencies" \
		-- ere-lookahead >actual &&
	test_cmp expect actual
'

test_expect_success 'grep should not segfault with a bad input' '
	test_must_fail git grep "("
'

test_invalid_grep_expression --and -e A

test_pattern_type () {
	H=$1 &&
	HC=$2 &&
	L=$3 &&
	type=$4 &&
	shift 4 &&

	expected_str= &&
	case "$type" in
	BRE)
		expected_str="${HC}ab:a+bc"
		;;
	ERE)
		expected_str="${HC}ab:abc"
		;;
	FIX)
		expected_str="${HC}ab:a+b*c"
		;;
	*)
		BUG "unknown pattern type '$type'"
		;;
	esac &&
	config_str="$@" &&

	test_expect_success "grep $L with '$config_str' interpreted as $type" '
		echo $expected_str >expected &&
		git $config_str grep "a+b*c" $H ab >actual &&
		test_cmp expected actual
	'
}

for H in HEAD ''
do
	case "$H" in
	HEAD)	HC='HEAD:' L='HEAD' ;;
	'')	HC= L='in working tree' ;;
	esac

	test_expect_success "grep -w $L" '
		cat >expected <<-EOF &&
		${HC}file:1:foo mmap bar
		${HC}file:3:foo_mmap bar mmap
		${HC}file:4:foo mmap bar_mmap
		${HC}file:5:foo_mmap bar mmap baz
		EOF
		git -c grep.linenumber=false grep -n -w -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (with --column)" '
		cat >expected <<-EOF &&
		${HC}file:5:foo mmap bar
		${HC}file:14:foo_mmap bar mmap
		${HC}file:5:foo mmap bar_mmap
		${HC}file:14:foo_mmap bar mmap baz
		EOF
		git grep --column -w -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (with --column, extended OR)" '
		cat >expected <<-EOF &&
		${HC}file:14:foo_mmap bar mmap
		${HC}file:19:foo_mmap bar mmap baz
		EOF
		git grep --column -w -e mmap$ --or -e baz $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (with --column, --invert-match)" '
		cat >expected <<-EOF &&
		${HC}file:1:foo mmap bar
		${HC}file:1:foo_mmap bar
		${HC}file:1:foo_mmap bar mmap
		${HC}file:1:foo mmap bar_mmap
		EOF
		git grep --column --invert-match -w -e baz $H -- file >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L (with --column, --invert-match, extended OR)" '
		cat >expected <<-EOF &&
		${HC}hello_world:6:HeLLo_world
		EOF
		git grep --column --invert-match -e ll --or --not -e _ $H -- hello_world \
			>actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L (with --column, --invert-match, extended AND)" '
		cat >expected <<-EOF &&
		${HC}hello_world:3:Hello world
		${HC}hello_world:3:Hello_world
		${HC}hello_world:6:HeLLo_world
		EOF
		git grep --column --invert-match --not -e _ --and --not -e ll $H -- hello_world \
			>actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L (with --column, double-negation)" '
		cat >expected <<-EOF &&
		${HC}file:1:foo_mmap bar mmap baz
		EOF
		git grep --column --not \( --not -e foo --or --not -e baz \) $H -- file \
			>actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (with --column, -C)" '
		cat >expected <<-EOF &&
		${HC}file:5:foo mmap bar
		${HC}file-foo_mmap bar
		${HC}file:14:foo_mmap bar mmap
		${HC}file:5:foo mmap bar_mmap
		${HC}file:14:foo_mmap bar mmap baz
		EOF
		git grep --column -w -C1 -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (with --line-number, --column)" '
		cat >expected <<-EOF &&
		${HC}file:1:5:foo mmap bar
		${HC}file:3:14:foo_mmap bar mmap
		${HC}file:4:5:foo mmap bar_mmap
		${HC}file:5:14:foo_mmap bar mmap baz
		EOF
		git grep -n --column -w -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (with non-extended patterns, --column)" '
		cat >expected <<-EOF &&
		${HC}file:5:foo mmap bar
		${HC}file:10:foo_mmap bar
		${HC}file:10:foo_mmap bar mmap
		${HC}file:5:foo mmap bar_mmap
		${HC}file:10:foo_mmap bar mmap baz
		EOF
		git grep --column -w -e bar -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L" '
		cat >expected <<-EOF &&
		${HC}file:1:foo mmap bar
		${HC}file:3:foo_mmap bar mmap
		${HC}file:4:foo mmap bar_mmap
		${HC}file:5:foo_mmap bar mmap baz
		EOF
		git -c grep.linenumber=true grep -w -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L" '
		cat >expected <<-EOF &&
		${HC}file:foo mmap bar
		${HC}file:foo_mmap bar mmap
		${HC}file:foo mmap bar_mmap
		${HC}file:foo_mmap bar mmap baz
		EOF
		git -c grep.linenumber=true grep --no-line-number -w -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (w)" '
		test_must_fail git grep -n -w -e "^w" $H >actual &&
		test_must_be_empty actual
	'

	test_expect_success "grep -w $L (x)" '
		cat >expected <<-EOF &&
		${HC}x:1:x x xx x
		EOF
		git grep -n -w -e "x xx* x" $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (y-1)" '
		cat >expected <<-EOF &&
		${HC}y:1:y yy
		EOF
		git grep -n -w -e "^y" $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -w $L (y-2)" '
		if git grep -n -w -e "^y y" $H >actual
		then
			echo should not have matched
			cat actual
			false
		else
			test_must_be_empty actual
		fi
	'

	test_expect_success "grep -w $L (z)" '
		if git grep -n -w -e "^z" $H >actual
		then
			echo should not have matched
			cat actual
			false
		else
			test_must_be_empty actual
		fi
	'

	test_expect_success "grep $L (with --column, --only-matching)" '
		cat >expected <<-EOF &&
		${HC}file:1:5:mmap
		${HC}file:2:5:mmap
		${HC}file:3:5:mmap
		${HC}file:3:14:mmap
		${HC}file:4:5:mmap
		${HC}file:4:14:mmap
		${HC}file:5:5:mmap
		${HC}file:5:14:mmap
		EOF
		git grep --column -n -o -e mmap $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L (t-1)" '
		echo "${HC}t/t:1:test" >expected &&
		git grep -n -e test $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L (t-2)" '
		echo "${HC}t:1:test" >expected &&
		(
			cd t &&
			git grep -n -e test $H
		) >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L (t-3)" '
		echo "${HC}t/t:1:test" >expected &&
		(
			cd t &&
			git grep --full-name -n -e test $H
		) >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep -c $L (no /dev/null)" '
		! git grep -c test $H | grep /dev/null
	'

	test_expect_success "grep --max-depth -1 $L" '
		cat >expected <<-EOF &&
		${HC}t/a/v:1:vvv
		${HC}t/v:1:vvv
		${HC}v:1:vvv
		EOF
		git grep --max-depth -1 -n -e vvv $H >actual &&
		test_cmp expected actual &&
		git grep --recursive -n -e vvv $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --max-depth 0 $L" '
		cat >expected <<-EOF &&
		${HC}v:1:vvv
		EOF
		git grep --max-depth 0 -n -e vvv $H >actual &&
		test_cmp expected actual &&
		git grep --no-recursive -n -e vvv $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --max-depth 0 -- '*' $L" '
		cat >expected <<-EOF &&
		${HC}t/a/v:1:vvv
		${HC}t/v:1:vvv
		${HC}v:1:vvv
		EOF
		git grep --max-depth 0 -n -e vvv $H -- "*" >actual &&
		test_cmp expected actual &&
		git grep --no-recursive -n -e vvv $H -- "*" >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --max-depth 1 $L" '
		cat >expected <<-EOF &&
		${HC}t/v:1:vvv
		${HC}v:1:vvv
		EOF
		git grep --max-depth 1 -n -e vvv $H >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --max-depth 0 -- t $L" '
		cat >expected <<-EOF &&
		${HC}t/v:1:vvv
		EOF
		git grep --max-depth 0 -n -e vvv $H -- t >actual &&
		test_cmp expected actual &&
		git grep --no-recursive -n -e vvv $H -- t >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --max-depth 0 -- . t $L" '
		cat >expected <<-EOF &&
		${HC}t/v:1:vvv
		${HC}v:1:vvv
		EOF
		git grep --max-depth 0 -n -e vvv $H -- . t >actual &&
		test_cmp expected actual &&
		git grep --no-recursive -n -e vvv $H -- . t >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --max-depth 0 -- t . $L" '
		cat >expected <<-EOF &&
		${HC}t/v:1:vvv
		${HC}v:1:vvv
		EOF
		git grep --max-depth 0 -n -e vvv $H -- t . >actual &&
		test_cmp expected actual &&
		git grep --no-recursive -n -e vvv $H -- t . >actual &&
		test_cmp expected actual
	'


	test_pattern_type "$H" "$HC" "$L" BRE -c grep.extendedRegexp=false
	test_pattern_type "$H" "$HC" "$L" ERE -c grep.extendedRegexp=true
	test_pattern_type "$H" "$HC" "$L" BRE -c grep.patternType=basic
	test_pattern_type "$H" "$HC" "$L" ERE -c grep.patternType=extended
	test_pattern_type "$H" "$HC" "$L" FIX -c grep.patternType=fixed

	test_expect_success PCRE "grep $L with grep.patterntype=perl" '
		echo "${HC}ab:a+b*c" >expected &&
		git -c grep.patterntype=perl grep "a\x{2b}b\x{2a}c" $H ab >actual &&
		test_cmp expected actual
	'

	test_expect_success !FAIL_PREREQS,!PCRE "grep $L with grep.patterntype=perl errors without PCRE" '
		test_must_fail git -c grep.patterntype=perl grep "foo.*bar"
	'

	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.patternType=default \
		-c grep.extendedRegexp=true
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.extendedRegexp=true \
		-c grep.patternType=default
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.patternType=extended \
		-c grep.extendedRegexp=false
	test_pattern_type "$H" "$HC" "$L" BRE \
		-c grep.patternType=basic \
		-c grep.extendedRegexp=true
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.extendedRegexp=false \
		-c grep.patternType=extended
	test_pattern_type "$H" "$HC" "$L" BRE \
		-c grep.extendedRegexp=true \
		-c grep.patternType=basic

	# grep.extendedRegexp is last-one-wins
	test_pattern_type "$H" "$HC" "$L" BRE \
		-c grep.extendedRegexp=true \
		-c grep.extendedRegexp=false

	# grep.patternType=basic pays no attention to grep.extendedRegexp
	test_pattern_type "$H" "$HC" "$L" BRE \
		-c grep.extendedRegexp=true \
		-c grep.patternType=basic \
		-c grep.extendedRegexp=false

	# grep.patternType=extended pays no attention to grep.extendedRegexp
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.extendedRegexp=true \
		-c grep.patternType=extended \
		-c grep.extendedRegexp=false

	# grep.extendedRegexp is used with a last-one-wins grep.patternType=default
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.patternType=fixed \
		-c grep.extendedRegexp=true \
		-c grep.patternType=default

	# grep.extendedRegexp is used with earlier grep.patternType=default
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.extendedRegexp=false \
		-c grep.patternType=default \
		-c grep.extendedRegexp=true

	# grep.extendedRegexp is used with a last-one-loses grep.patternType=default
	test_pattern_type "$H" "$HC" "$L" ERE \
		-c grep.extendedRegexp=false \
		-c grep.extendedRegexp=true \
		-c grep.patternType=default

	# grep.extendedRegexp and grep.patternType are both last-one-wins independently
	test_pattern_type "$H" "$HC" "$L" BRE \
		-c grep.patternType=default \
		-c grep.extendedRegexp=true \
		-c grep.patternType=basic

	# grep.patternType=extended and grep.patternType=default
	test_pattern_type "$H" "$HC" "$L" BRE \
		-c grep.patternType=extended \
		-c grep.patternType=default

	# grep.patternType=[extended -> default -> fixed] (BRE)" '
	test_pattern_type "$H" "$HC" "$L" FIX \
		-c grep.patternType=extended \
		-c grep.patternType=default \
		-c grep.patternType=fixed

	test_expect_success "grep --count $L" '
		echo ${HC}ab:3 >expected &&
		git grep --count -e b $H -- ab >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep --count -h $L" '
		echo 3 >expected &&
		git grep --count -h -e b $H -- ab >actual &&
		test_cmp expected actual
	'

	test_expect_success "grep $L searches past invalid lines on UTF-8 locale" '
		LC_ALL=en_US.UTF-8 git grep A. invalid-utf8 >actual &&
		cat >expected <<-EOF &&
		invalid-utf8:ASCII
		EOF
		test_cmp expected actual
	'

	test_expect_success FUNNYNAMES "grep $L should quote unusual pathnames" '
		cat >expected <<-EOF &&
		${HC}"\"unusual\" pathname":unusual
		${HC}"t/nested \"unusual\" pathname":unusual
		EOF
		git grep unusual $H >actual &&
		test_cmp expected actual
	'

	test_expect_success FUNNYNAMES "grep $L in subdir should quote unusual relative pathnames" '
		cat >expected <<-EOF &&
		${HC}"nested \"unusual\" pathname":unusual
		EOF
		(
			cd t &&
			git grep unusual $H
		) >actual &&
		test_cmp expected actual
	'

	test_expect_success FUNNYNAMES "grep -z $L with unusual pathnames" '
		cat >expected <<-EOF &&
		${HC}"unusual" pathname:unusual
		${HC}t/nested "unusual" pathname:unusual
		EOF
		git grep -z unusual $H >actual &&
		tr "\0" ":" <actual >actual-replace-null &&
		test_cmp expected actual-replace-null
	'

	test_expect_success FUNNYNAMES "grep -z $L in subdir with unusual relative pathnames" '
		cat >expected <<-EOF &&
		${HC}nested "unusual" pathname:unusual
		EOF
		(
			cd t &&
			git grep -z unusual $H
		) >actual &&
		tr "\0" ":" <actual >actual-replace-null &&
		test_cmp expected actual-replace-null
	'
done

test_expect_success MB_REGEX 'grep exactly one char in single-char multibyte file' '
	LC_ALL=en_US.UTF-8 git grep "^.$" reverse-question-mark
'

test_expect_success MB_REGEX 'grep two chars in single-char multibyte file' '
	LC_ALL=en_US.UTF-8 test_expect_code 1 git grep ".." reverse-question-mark
'

cat >expected <<EOF
file
EOF
test_expect_success 'grep -l -C' '
	git grep -l -C1 foo >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
file:5
EOF
test_expect_success 'grep -c -C' '
	git grep -c -C1 foo >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -L -C' '
	git ls-files >expected &&
	git grep -L -C1 nonexistent_string >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --files-without-match --quiet' '
	git grep --files-without-match --quiet nonexistent_string >actual &&
	test_must_be_empty actual
'

test_expect_success 'grep --max-count 0 (must exit with non-zero)' '
	test_must_fail git grep --max-count 0 foo >actual &&
	test_must_be_empty actual
'

test_expect_success 'grep --max-count 3' '
	cat >expected <<-EOF &&
	file:foo mmap bar
	file:foo_mmap bar
	file:foo_mmap bar mmap
	EOF
	git grep --max-count 3 foo >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count -1 (no limit)' '
	cat >expected <<-EOF &&
	file:foo mmap bar
	file:foo_mmap bar
	file:foo_mmap bar mmap
	file:foo mmap bar_mmap
	file:foo_mmap bar mmap baz
	EOF
	git grep --max-count -1 foo >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count 1 --context 2' '
	cat >expected <<-EOF &&
	file-foo mmap bar
	file:foo_mmap bar
	file-foo_mmap bar mmap
	EOF
	git grep --max-count 1 --context 1 foo_mmap >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count 1 --show-function' '
	cat >expected <<-EOF &&
	hello.ps1=function hello() {
	hello.ps1:  echo "Hello world."
	EOF
	git grep --max-count 1 --show-function Hello hello.ps1 >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count 2 --show-function' '
	cat >expected <<-EOF &&
	hello.ps1=function hello() {
	hello.ps1:  echo "Hello world."
	hello.ps1:  echo "Hello again."
	EOF
	git grep --max-count 2 --show-function Hello hello.ps1 >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count 1 --count' '
	cat >expected <<-EOF &&
	hello.ps1:1
	EOF
	git grep --max-count 1 --count Hello hello.ps1 >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count 1 (multiple files)' '
	cat >expected <<-EOF &&
	hello.c:#include <stdio.h>
	hello.ps1:# No-op.
	EOF
	git grep --max-count 1 -e o -- hello.\* >actual &&
	test_cmp expected actual
'

test_expect_success 'grep --max-count 1 --context 1 (multiple files)' '
	cat >expected <<-EOF &&
	hello.c-#include <assert.h>
	hello.c:#include <stdio.h>
	hello.c-
	--
	hello.ps1:# No-op.
	hello.ps1-function dummy() {}
	EOF
	git grep --max-count 1 --context 1 -e o -- hello.\* >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
file:foo mmap bar_mmap
EOF

test_expect_success 'grep -e A --and -e B' '
	git grep -e "foo mmap" --and -e bar_mmap >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
file:foo_mmap bar mmap
file:foo_mmap bar mmap baz
EOF


test_expect_success 'grep ( -e A --or -e B ) --and -e B' '
	git grep \( -e foo_ --or -e baz \) \
		--and -e " mmap" >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
file:foo mmap bar
EOF

test_expect_success 'grep -e A --and --not -e B' '
	git grep -e "foo mmap" --and --not -e bar_mmap >actual &&
	test_cmp expected actual
'

test_expect_success 'grep should ignore GREP_OPTIONS' '
	GREP_OPTIONS=-v git grep " mmap bar\$" >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -f, non-existent file' '
	test_must_fail git grep -f patterns
'

cat >expected <<EOF
file:foo mmap bar
file:foo_mmap bar
file:foo_mmap bar mmap
file:foo mmap bar_mmap
file:foo_mmap bar mmap baz
EOF

cat >pattern <<EOF
mmap
EOF

test_expect_success 'grep -f, one pattern' '
	git grep -f pattern >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
file:foo mmap bar
file:foo_mmap bar
file:foo_mmap bar mmap
file:foo mmap bar_mmap
file:foo_mmap bar mmap baz
t/a/v:vvv
t/v:vvv
v:vvv
EOF

cat >patterns <<EOF
mmap
vvv
EOF

test_expect_success 'grep -f, multiple patterns' '
	git grep -f patterns >actual &&
	test_cmp expected actual
'

test_expect_success 'grep, multiple patterns' '
	git grep "$(cat patterns)" >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
file:foo mmap bar
file:foo_mmap bar
file:foo_mmap bar mmap
file:foo mmap bar_mmap
file:foo_mmap bar mmap baz
t/a/v:vvv
t/v:vvv
v:vvv
EOF

cat >patterns <<EOF

mmap

vvv

EOF

test_expect_success 'grep -f, ignore empty lines' '
	git grep -f patterns >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -f, ignore empty lines, read patterns from stdin' '
	git grep -f - <patterns >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -f, use cwd relative file' '
	test_when_finished "git rm -f sub/dir/file" &&
	mkdir -p sub/dir &&
	echo hit >sub/dir/file &&
	git add sub/dir/file &&
	echo hit >sub/dir/pattern &&
	echo miss >pattern &&
	(
		cd sub/dir && git grep -f pattern file
	) &&
	git -C sub/dir grep -f pattern file
'

cat >expected <<EOF
y:y yy
--
z:zzz
EOF

test_expect_success 'grep -q, silently report matches' '
	git grep -q mmap >actual &&
	test_must_be_empty actual &&
	test_must_fail git grep -q qfwfq >actual &&
	test_must_be_empty actual
'

test_expect_success 'grep -C1 hunk mark between files' '
	git grep -C1 "^[yz]" >actual &&
	test_cmp expected actual
'

test_expect_success 'log grep setup' '
	test_commit --append --author "With * Asterisk <xyzzy@frotz.com>" second file a &&
	test_commit --append third file a &&
	test_commit --append --author "Night Fall <nitfol@frobozz.com>" fourth file a &&
	printf "\\202foo\n" |
	git commit-tree HEAD^{tree} -p HEAD >log-grep-sjis
'

test_expect_success ENHANCED_BRE 'log grep with literal BRE alternatives' '
	cat >expect <<-\EOF &&
	fourth
	second
	EOF
	git log --grep="second\\|fourth" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success ENHANCED_BRE \
	'log grep with case-insensitive literal BRE alternatives' '
	cat >expect <<-\EOF &&
	fourth
	second
	EOF
	git log -i --grep="SECOND\\|FOURTH" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success 'log grep with literal ERE alternatives' '
	cat >expect <<-\EOF &&
	fourth
	second
	EOF
	git log -E --grep="second|fourth" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success \
	'log grep with case-insensitive literal ERE alternatives' '
	cat >expect <<-\EOF &&
	fourth
	second
	EOF
	git log -i -E --grep="SECOND|FOURTH" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success ENHANCED_BRE \
	'log grep BRE fast path requires complete pattern' '
	echo fourth >expect &&
	git log --grep="missing\\|f.urth" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success 'log grep ERE fast path requires complete pattern' '
	echo fourth >expect &&
	git log -E --grep="missing|f.urth" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success SJIS_REGEX_NOMATCH \
	'log grep leaves multibyte candidates to POSIX' '
	LC_ALL=ja_JP.SJIS git log --encoding=none -1 -E \
		--grep="foo|absent" --format=%s \
		$(cat log-grep-sjis) >actual &&
	test_must_be_empty actual
'

test_expect_success 'log grep with literal author alternatives' '
	cat >expect <<-\EOF &&
	fourth
	second
	EOF
	git log -E --author="With|Night" --format=%s >actual &&
	test_cmp expect actual
'

test_expect_success 'log grep (1)' '
	git log --author=author --pretty=tformat:%s >actual &&
	{
		echo third && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (2)' '
	git log --author=" * " -F --pretty=tformat:%s >actual &&
	{
		echo second
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (3)' '
	git log --author="^A U" --pretty=tformat:%s >actual &&
	{
		echo third && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (4)' '
	git log --author="frotz\.com>$" --pretty=tformat:%s >actual &&
	{
		echo second
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (5)' '
	git log --author=Thor -F --pretty=tformat:%s >actual &&
	{
		echo third && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (6)' '
	git log --author=-0700  --pretty=tformat:%s >actual &&
	test_must_be_empty actual
'

test_expect_success 'log grep (7)' '
	git log -g --grep-reflog="commit: third" --pretty=tformat:%s >actual &&
	echo third >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (8)' '
	git log -g --grep-reflog="commit: third" --grep-reflog="commit: second" --pretty=tformat:%s >actual &&
	{
		echo third && echo second
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (9)' '
	git log -g --grep-reflog="commit: third" --author="Thor" --pretty=tformat:%s >actual &&
	echo third >expect &&
	test_cmp expect actual
'

test_expect_success 'log grep (9)' '
	git log -g --grep-reflog="commit: third" --author="non-existent" --pretty=tformat:%s >actual &&
	test_must_be_empty actual
'

test_expect_success 'log --grep-reflog can only be used under -g' '
	test_must_fail git log --grep-reflog="commit: third"
'

test_expect_success 'log with multiple --grep uses union' '
	git log --grep=i --grep=r --format=%s >actual &&
	{
		echo fourth && echo third && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --all-match with multiple --grep uses intersection' '
	git log --all-match --grep=i --grep=r --format=%s >actual &&
	{
		echo third
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log with multiple --author uses union' '
	git log --author="Thor" --author="Aster" --format=%s >actual &&
	{
	    echo third && echo second && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --all-match with multiple --author still uses union' '
	git log --all-match --author="Thor" --author="Aster" --format=%s >actual &&
	{
	    echo third && echo second && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --grep --author uses intersection' '
	# grep matches only third and fourth
	# author matches only initial and third
	git log --author="A U Thor" --grep=r --format=%s >actual &&
	{
		echo third
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --grep --grep --author takes union of greps and intersects with author' '
	# grep matches initial and second but not third
	# author matches only initial and third
	git log --author="A U Thor" --grep=s --grep=l --format=%s >actual &&
	{
		echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log ---all-match -grep --author --author still takes union of authors and intersects with grep' '
	# grep matches only initial and third
	# author matches all but second
	git log --all-match --author="Thor" --author="Night" --grep=i --format=%s >actual &&
	{
	    echo third && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --grep --author --author takes union of authors and intersects with grep' '
	# grep matches only initial and third
	# author matches all but second
	git log --author="Thor" --author="Night" --grep=i --format=%s >actual &&
	{
	    echo third && echo initial
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --all-match --grep --grep --author takes intersection' '
	# grep matches only third
	# author matches only initial and third
	git log --all-match --author="A U Thor" --grep=i --grep=r --format=%s >actual &&
	{
		echo third
	} >expect &&
	test_cmp expect actual
'

test_expect_success 'log --author does not search in timestamp' '
	git log --author="$GIT_AUTHOR_DATE" >actual &&
	test_must_be_empty actual
'

test_expect_success 'log --committer does not search in timestamp' '
	git log --committer="$GIT_COMMITTER_DATE" >actual &&
	test_must_be_empty actual
'

test_expect_success 'grep with CE_VALID file' '
	test_when_finished "rm -f grep-literal-trace-valid" &&
	git update-index --assume-unchanged t/t &&
	rm t/t &&
	echo "t/t:test" >expect &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-valid" \
		git grep test -- t/t >actual &&
	test_cmp expect actual &&
	test_grep ! "literal_path_candidates" grep-literal-trace-valid &&
	git update-index --no-assume-unchanged t/t &&
	git checkout t/t
'

test_expect_success 'literal path selection falls back for unmerged paths' '
	test_when_finished "rm -f grep-literal-trace-unmerged index-info &&
		git rm -f grep-literal-unmerged" &&
	stage1=$(git rev-parse :t/t) &&
	stage2=$(echo ours | git hash-object -w --stdin) &&
	stage3=$(echo theirs | git hash-object -w --stdin) &&
	printf "100644 %s 1\tgrep-literal-unmerged\n" "$stage1" >index-info &&
	printf "100644 %s 2\tgrep-literal-unmerged\n" "$stage2" >>index-info &&
	printf "100644 %s 3\tgrep-literal-unmerged\n" "$stage3" >>index-info &&
	git update-index --index-info <index-info &&
	echo "unmerged worktree needle" >grep-literal-unmerged &&
	echo "grep-literal-unmerged:unmerged worktree needle" >expect &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-unmerged" \
		git grep "unmerged worktree" -- grep-literal-unmerged >actual &&
	test_cmp expect actual &&
	test_grep ! "literal_path_candidates" grep-literal-trace-unmerged
'

cat >expected <<EOF
hello.c=#include <stdio.h>
hello.c:	return 0;
EOF

test_expect_success 'grep -p with userdiff' '
	git config diff.custom.funcname "^#" &&
	echo "hello.c diff=custom" >.gitattributes &&
	git grep -p return >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c=int main(int argc, const char **argv)
hello.c:	return 0;
EOF

test_expect_success 'grep -p' '
	rm -f .gitattributes &&
	git grep -p return >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c-#include <stdio.h>
hello.c-
hello.c=int main(int argc, const char **argv)
hello.c-{
hello.c-	printf("Hello world.\n");
hello.c:	return 0;
EOF

test_expect_success 'grep -p -B5' '
	git grep -p -B5 return >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c=int main(int argc, const char **argv)
hello.c-{
hello.c-	printf("Hello world.\n");
hello.c:	return 0;
hello.c-	/* char ?? */
hello.c-}
EOF

test_expect_success 'grep -W' '
	git grep -W return >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c-#include <assert.h>
hello.c:#include <stdio.h>
EOF

test_expect_success 'grep -W shows no trailing empty lines' '
	git grep -W stdio >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -W with userdiff' '
	test_when_finished "rm -f .gitattributes" &&
	git config diff.custom.xfuncname "^function .*$" &&
	echo "hello.ps1 diff=custom" >.gitattributes &&
	git grep -W echo >function-context-userdiff-actual
'

test_expect_success ' includes preceding comment' '
	grep "# Say hello" function-context-userdiff-actual
'

test_expect_success ' includes function line' '
	grep "=function hello" function-context-userdiff-actual
'

test_expect_success ' includes matching line' '
	grep ":  echo" function-context-userdiff-actual
'

test_expect_success ' includes last line of the function' '
	grep "} # hello" function-context-userdiff-actual
'

for threads in $(test_seq 0 10)
do
	test_expect_success "grep --threads=$threads & -c grep.threads=$threads" "
		git grep --threads=$threads . >actual.$threads &&
		if test $threads -ge 1
		then
			test_cmp actual.\$(($threads - 1)) actual.$threads
		fi &&
		git -c grep.threads=$threads grep . >actual.$threads &&
		if test $threads -ge 1
		then
			test_cmp actual.\$(($threads - 1)) actual.$threads
		fi
	"
done

test_expect_success 'setup repeated revision grep' '
	git init result-cache &&
	(
		cd result-cache &&
		echo haystack >shared &&
		printf "\\377foo\\n" >regex-error &&
		git add shared regex-error &&
		git commit -m base &&
		git tag cache-base &&

		echo unrelated >other &&
		git add other &&
		git commit -m tip &&
		git tag cache-tip &&

		write_script textconv <<-\EOF &&
		if test -n "$RESULT_CACHE_TEXTCONV_LOG"
		then
			echo textconv >>"$RESULT_CACHE_TEXTCONV_LOG"
		fi
		cat "$1"
		EOF
		git config diff.cache.textconv "\"$(pwd)/textconv\"" &&

		printf "needle\n\0" >binary &&
		cp binary text &&
		printf "text diff\nshared diff=cache\n" >.gitattributes &&
		git add binary text .gitattributes &&
		git commit -m drivers &&
		git tag cache-drivers &&

		printf "before\nneedle one\nafter\n" >match &&
		git add match &&
		git commit -m format-one &&
		git tag cache-format-one &&
		sed "s/one/two/" match >match.new &&
		mv match.new match &&
		git commit -am format-two &&
		git tag cache-format-two &&
		sed "s/two/three/" match >match.new &&
		mv match.new match &&
		git commit -am format-three &&
		git tag cache-format-three
	)
'

test_expect_success 'grep caches repeated no-output blobs' '
	test_must_fail env \
		GIT_TRACE2_EVENT="$(pwd)/result-cache-no-output.trace" \
		git -C result-cache grep --threads=1 \
		needle cache-base cache-tip -- shared >actual &&
	test_must_be_empty actual &&
	test_trace2_data grep result_cache/entries 1 \
		<result-cache-no-output.trace &&
	test_trace2_data grep result_cache/hits 1 \
		<result-cache-no-output.trace
'

test_expect_success REGEX_MATCH_ERROR \
	'grep does not cache regex errors' '
	test_must_fail env LC_ALL=en_US.UTF-8 \
		GIT_TRACE2_EVENT="$(pwd)/result-cache-regex-error.trace" \
		git -C result-cache grep --threads=1 -E "foo.*bar" \
		cache-base cache-tip -- regex-error >actual &&
	test_must_be_empty actual &&
	test_trace2_data grep result_cache/entries 0 \
		<result-cache-regex-error.trace &&
	test_trace2_data grep result_cache/hits 0 \
		<result-cache-regex-error.trace
'

test_expect_success PTHREADS,REGEX_MATCH_ERROR \
	'threaded grep does not cache regex errors' '
	test_must_fail env LC_ALL=en_US.UTF-8 \
		GIT_TRACE2_EVENT="$(pwd)/result-cache-regex-error-threaded.trace" \
		git -C result-cache grep --threads=8 -E "foo|absent" \
		cache-base cache-tip -- regex-error >actual &&
	test_must_be_empty actual &&
	test_trace2_data grep result_cache/entries 0 \
		<result-cache-regex-error-threaded.trace &&
	test_trace2_data grep result_cache/hits 0 \
		<result-cache-regex-error-threaded.trace
'

test_expect_success 'grep caches repeated -L suppression' '
	test_must_fail env \
		GIT_TRACE2_EVENT="$(pwd)/result-cache-L.trace" \
		git -C result-cache grep --threads=1 -L \
		haystack cache-base cache-tip -- shared >actual &&
	test_must_be_empty actual &&
	test_trace2_data grep result_cache/entries 1 \
		<result-cache-L.trace &&
	test_trace2_data grep result_cache/hits 1 \
		<result-cache-L.trace
'

test_expect_success 'grep caches repeated --all-match rejection' '
	test_must_fail env \
		GIT_TRACE2_EVENT="$(pwd)/result-cache-all-match.trace" \
		git -C result-cache grep --threads=1 --all-match \
		-e haystack -e absent cache-base cache-tip -- shared >actual &&
	test_must_be_empty actual &&
	test_trace2_data grep result_cache/entries 1 \
		<result-cache-all-match.trace &&
	test_trace2_data grep result_cache/hits 1 \
		<result-cache-all-match.trace
'

test_expect_success PTHREADS \
	'threaded grep reuses completed no-output scans' '
	revisions= &&
	for i in $(test_seq 1 256)
	do
		revisions="$revisions cache-base" || return 1
	done &&
	revisions="$revisions cache-format-one cache-format-two \
		cache-format-three" &&
	git -C result-cache grep --threads=1 \
		--heading --break -C1 needle $revisions \
		-- match shared >expect &&
	GIT_TRACE2_EVENT="$(pwd)/result-cache-threaded.trace" \
		git -C result-cache grep --threads=8 \
		--heading --break -C1 needle $revisions \
		-- match shared >actual &&
	test_cmp expect actual &&
	test_trace2_data grep result_cache/entries 1 \
		<result-cache-threaded.trace &&
	# Of 259 shared occurrences, 1-8 may be scanned before caching,
	# leaving 251-258 cache hits.
	test_grep -E \
		"\"key\":\"result_cache/hits\",\"value\":\"25[1-8]\"" \
		result-cache-threaded.trace
'

test_expect_success 'grep rescans repeated matching blobs' '
	cat >expect <<-\EOF &&
	cache-base:shared:haystack
	cache-tip:shared:haystack
	EOF
	GIT_TRACE2_EVENT="$(pwd)/result-cache-match.trace" \
		git -C result-cache grep --threads=1 \
		haystack cache-base cache-tip -- shared >actual &&
	test_cmp expect actual &&
	test_trace2_data grep result_cache/entries 0 \
		<result-cache-match.trace &&
	test_trace2_data grep result_cache/hits 0 \
		<result-cache-match.trace
'

test_expect_success 'grep result cache distinguishes binary handling' '
	cat >expect <<-\EOF &&
	cache-drivers:text:needle
	cache-drivers:text:needle
	EOF
	GIT_TRACE2_EVENT="$(pwd)/result-cache-binary.trace" \
		git -C result-cache grep --threads=1 -I \
		needle cache-drivers cache-drivers -- binary text >actual &&
	test_cmp expect actual &&
	test_trace2_data grep result_cache/entries 1 \
		<result-cache-binary.trace &&
	test_trace2_data grep result_cache/hits 1 \
		<result-cache-binary.trace
'

test_expect_success 'grep cache preserves output formatting state' '
	git -C result-cache grep --threads=1 --textconv \
		--heading --break -C1 needle \
		cache-format-one cache-format-two cache-format-three \
		-- match shared >expect &&
	git -C result-cache grep --threads=1 \
		--heading --break -C1 needle \
		cache-format-one cache-format-two cache-format-three \
		-- match shared >actual &&
	test_cmp expect actual
'

test_expect_success 'grep does not cache textconv results' '
	RESULT_CACHE_TEXTCONV_LOG="$(pwd)/result-cache-textconv.log" &&
	rm -f "$RESULT_CACHE_TEXTCONV_LOG" &&
	test_must_fail env \
		RESULT_CACHE_TEXTCONV_LOG="$RESULT_CACHE_TEXTCONV_LOG" \
		git -C result-cache grep --threads=1 --textconv \
		absent cache-drivers cache-format-one -- shared >actual &&
	test_must_be_empty actual &&
	test_line_count = 2 result-cache-textconv.log
'

test_expect_success 'grep does not cache object read failures' '
	oid=$(git -C result-cache rev-parse cache-base:shared) &&
	object_path="result-cache/.git/objects/$(test_oid_to_path "$oid")" &&
	mv "$object_path" "$object_path.missing" &&
	test_when_finished "mv \"$object_path.missing\" \"$object_path\"" &&
	test_must_fail env \
		GIT_TRACE2_EVENT="$(pwd)/result-cache-missing.trace" \
		git -C result-cache grep --threads=1 \
		needle cache-base cache-tip -- shared >actual 2>err &&
	test_must_be_empty actual &&
	test_grep "cache-base:shared.*unable to read $oid" err &&
	test_grep "cache-tip:shared.*unable to read $oid" err &&
	test_trace2_data grep result_cache/entries 0 \
		<result-cache-missing.trace &&
	test_trace2_data grep result_cache/hits 0 \
		<result-cache-missing.trace
'

test_expect_success !PTHREADS,!FAIL_PREREQS \
	'grep --threads=N or pack.threads=N warns when no pthreads' '
	git grep --threads=2 Hello hello_world 2>err &&
	grep ^warning: err >warnings &&
	test_line_count = 1 warnings &&
	grep -F "no threads support, ignoring --threads" err &&
	git -c grep.threads=2 grep Hello hello_world 2>err &&
	grep ^warning: err >warnings &&
	test_line_count = 1 warnings &&
	grep -F "no threads support, ignoring grep.threads" err &&
	git -c grep.threads=2 grep --threads=4 Hello hello_world 2>err &&
	grep ^warning: err >warnings &&
	test_line_count = 2 warnings &&
	grep -F "no threads support, ignoring --threads" err &&
	grep -F "no threads support, ignoring grep.threads" err &&
	git -c grep.threads=0 grep --threads=0 Hello hello_world 2>err &&
	test_line_count = 0 err
'

test_expect_success 'grep from a subdirectory to search wider area (1)' '
	mkdir -p s &&
	(
		cd s && git grep "x x x" ..
	)
'

test_expect_success 'grep from a subdirectory to search wider area (2)' '
	mkdir -p s &&
	(
		cd s &&
		test_expect_code 1 git grep xxyyzz .. >out &&
		test_must_be_empty out
	)
'

cat >expected <<EOF
hello.c:int main(int argc, const char **argv)
EOF

test_expect_success 'grep -Fi' '
	git grep -Fi "CHAR *" >actual &&
	test_cmp expected actual
'

test_expect_success 'outside of git repository' '
	rm -fr non &&
	mkdir -p non/git/sub &&
	echo hello >non/git/file1 &&
	echo world >non/git/sub/file2 &&
	{
		echo file1:hello &&
		echo sub/file2:world
	} >non/expect.full &&
	echo file2:world >non/expect.sub &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_must_fail git grep o &&
		git grep --no-index o >../actual.full &&
		test_cmp ../expect.full ../actual.full &&
		cd sub &&
		test_must_fail git grep o &&
		git grep --no-index o >../../actual.sub &&
		test_cmp ../../expect.sub ../../actual.sub
	) &&

	echo ".*o*" >non/git/.gitignore &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_must_fail git grep o &&
		git grep --no-index --exclude-standard o >../actual.full &&
		test_cmp ../expect.full ../actual.full &&

		{
			echo ".gitignore:.*o*" &&
			cat ../expect.full
		} >../expect.with.ignored &&
		git grep --no-index --no-exclude-standard o >../actual.full &&
		test_cmp ../expect.with.ignored ../actual.full
	)
'

test_expect_success 'outside of git repository with fallbackToNoIndex' '
	rm -fr non &&
	mkdir -p non/git/sub &&
	echo hello >non/git/file1 &&
	echo world >non/git/sub/file2 &&
	cat <<-\EOF >non/expect.full &&
	file1:hello
	sub/file2:world
	EOF
	echo file2:world >non/expect.sub &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_must_fail git -c grep.fallbackToNoIndex=false grep o &&
		git -c grep.fallbackToNoIndex=true grep o >../actual.full &&
		test_cmp ../expect.full ../actual.full &&
		cd sub &&
		test_must_fail git -c grep.fallbackToNoIndex=false grep o &&
		git -c grep.fallbackToNoIndex=true grep o >../../actual.sub &&
		test_cmp ../../expect.sub ../../actual.sub
	) &&

	echo ".*o*" >non/git/.gitignore &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_must_fail git -c grep.fallbackToNoIndex=false grep o &&
		git -c grep.fallbackToNoIndex=true grep --exclude-standard o >../actual.full &&
		test_cmp ../expect.full ../actual.full &&

		{
			echo ".gitignore:.*o*" &&
			cat ../expect.full
		} >../expect.with.ignored &&
		git -c grep.fallbackToNoIndex grep --no-exclude-standard o >../actual.full &&
		test_cmp ../expect.with.ignored ../actual.full
	)
'

test_expect_success 'no repository with path outside $cwd' '
	test_when_finished rm -fr non &&
	rm -fr non &&
	mkdir -p non/git/sub non/tig &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_expect_code 128 git grep --no-index search .. 2>error &&
		grep "is outside the directory tree" error
	) &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_expect_code 128 git grep --no-index search ../tig 2>error &&
		grep "is outside the directory tree" error
	) &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		test_expect_code 128 git grep --no-index search ../non 2>error &&
		grep "no such path in the working tree" error
	)
'

test_expect_success 'inside git repository but with --no-index' '
	rm -fr is &&
	mkdir -p is/git/sub &&
	echo hello >is/git/file1 &&
	echo world >is/git/sub/file2 &&
	echo ".*o*" >is/git/.gitignore &&
	{
		echo file1:hello &&
		echo sub/file2:world
	} >is/expect.unignored &&
	{
		echo ".gitignore:.*o*" &&
		cat is/expect.unignored
	} >is/expect.full &&
	echo file2:world >is/expect.sub &&
	(
		cd is/git &&
		git init &&
		test_must_fail git grep o >../actual.full &&
		test_must_be_empty ../actual.full &&

		git grep --untracked o >../actual.unignored &&
		test_cmp ../expect.unignored ../actual.unignored &&

		git grep --no-index o >../actual.full &&
		test_cmp ../expect.full ../actual.full &&

		git grep --no-index --exclude-standard o >../actual.unignored &&
		test_cmp ../expect.unignored ../actual.unignored &&

		cd sub &&
		test_must_fail git grep o >../../actual.sub &&
		test_must_be_empty ../../actual.sub &&

		git grep --no-index o >../../actual.sub &&
		test_cmp ../../expect.sub ../../actual.sub &&

		git grep --untracked o >../../actual.sub &&
		test_cmp ../../expect.sub ../../actual.sub
	)
'

test_expect_success 'grep --untracked merges worktree paths in order' '
	test_create_repo grep-untracked-merge &&
	(
		cd grep-untracked-merge &&
		echo b-tracked >.gitignore &&
		echo j-ignored >>.gitignore &&
		echo needle >b-tracked &&
		echo needle >d-tracked &&
		test_ln_s_add missing g-type &&
		echo needle >h-sparse &&
		echo needle >i-absent &&
		git add -f .gitignore b-tracked d-tracked h-sparse i-absent &&
		git commit -m initial &&
		git update-index --add --cacheinfo 160000,$(git rev-parse HEAD),k-gitlink &&
		echo needle >a-untracked &&
		echo needle >c-untracked &&
		echo needle >e-intent &&
		echo needle >j-ignored &&
		echo needle >k-gitlink &&
		git add -N e-intent &&
		stage1=$(echo one | git hash-object -w --stdin) &&
		stage2=$(echo two | git hash-object -w --stdin) &&
		stage3=$(echo three | git hash-object -w --stdin) &&
		{
			printf "100644 %s 1\tf-unmerged\n" "$stage1" &&
			printf "100644 %s 2\tf-unmerged\n" "$stage2" &&
			printf "100644 %s 3\tf-unmerged\n" "$stage3"
		} | git update-index --index-info &&
		echo needle >f-unmerged &&
		rm g-type &&
		echo needle >g-type &&
		git config core.sparseCheckout true &&
		echo "/*" >.git/info/sparse-checkout &&
		git update-index --skip-worktree h-sparse &&
		rm i-absent &&
		git update-index --skip-worktree i-absent &&
		cat >expect <<-\EOF &&
		a-untracked
		b-tracked
		c-untracked
		d-tracked
		e-intent
		f-unmerged
		g-type
		h-sparse
		k-gitlink
		EOF
		git -c grep.threads=1 grep --untracked -l needle >actual &&
		test_cmp expect actual &&
		git -c grep.threads=4 grep --untracked -l needle >actual &&
		test_cmp expect actual &&
		cat >expect <<-\EOF &&
		a-untracked
		b-tracked
		c-untracked
		d-tracked
		e-intent
		f-unmerged
		g-type
		h-sparse
		j-ignored
		k-gitlink
		EOF
		git grep --untracked --no-exclude-standard -l needle >actual &&
		test_cmp expect actual &&
		test_must_fail git grep --untracked -l needle -- "k-gitlink/*" \
			>actual &&
		test_must_be_empty actual &&
		git config sparse.expectFilesOutsideOfPatterns true &&
		git update-index --skip-worktree h-sparse &&
		echo h-sparse >expect &&
		git grep --untracked -l needle -- h-sparse >actual &&
		test_cmp expect actual &&
		git config core.sparseCheckout false &&
		manual=$(echo needle | git hash-object -w --stdin) &&
		git update-index --add --cacheinfo 100644,$manual,l-manual &&
		git update-index --skip-worktree l-manual &&
		echo needle >l-manual &&
		echo l-manual >expect &&
		git grep --untracked -l needle -- l-manual >actual &&
		test_cmp expect actual &&
		git update-index --add --cacheinfo \
			160000,$(git rev-parse HEAD),m-gitlink-dir &&
		mkdir m-gitlink-dir &&
		echo needle >m-gitlink-dir/child &&
		echo m-gitlink-dir/child >expect &&
		git grep --untracked -l needle -- m-gitlink-dir >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'grep --no-index descends into repos, but not .git' '
	rm -fr non &&
	mkdir -p non/git &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&

		echo magic >file &&
		git init repo &&
		(
			cd repo &&
			echo magic >file &&
			git add file &&
			git commit -m foo &&
			echo magic >.git/file
		) &&

		cat >expect <<-\EOF &&
		file
		repo/file
		EOF
		git grep -l --no-index magic >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'setup double-dash tests' '
cat >double-dash <<EOF &&
--
->
other
EOF
git add double-dash
'

cat >expected <<EOF
double-dash:->
EOF
test_expect_success 'grep -- pattern' '
	git grep -- "->" >actual &&
	test_cmp expected actual
'
test_expect_success 'grep -- pattern -- pathspec' '
	git grep -- "->" -- double-dash >actual &&
	test_cmp expected actual
'
test_expect_success 'grep -e pattern -- path' '
	git grep -e "->" -- double-dash >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
double-dash:--
EOF
test_expect_success 'grep -e -- -- path' '
	git grep -e -- -- double-dash >actual &&
	test_cmp expected actual
'

test_expect_success 'dashdash disambiguates rev as rev' '
	test_when_finished "rm -f main" &&
	echo content >main &&
	echo main:hello.c >expect &&
	git grep -l o main -- hello.c >actual &&
	test_cmp expect actual
'

test_expect_success 'dashdash disambiguates pathspec as pathspec' '
	test_when_finished "git rm -f main" &&
	echo content >main &&
	git add main &&
	echo main:content >expect &&
	git grep o -- main >actual &&
	test_cmp expect actual
'

test_expect_success 'report bogus arg without dashdash' '
	test_must_fail git grep o does-not-exist
'

test_expect_success 'report bogus rev with dashdash' '
	test_must_fail git grep o hello.c --
'

test_expect_success 'allow non-existent path with dashdash' '
	# We need a real match so grep exits with success.
	tree=$(git ls-tree HEAD |
	       sed s/hello.c/not-in-working-tree/ |
	       git mktree) &&
	git grep o "$tree" -- not-in-working-tree
'

test_expect_success 'grep --no-index pattern -- path' '
	rm -fr non &&
	mkdir -p non/git &&
	(
		GIT_CEILING_DIRECTORIES="$(pwd)/non" &&
		export GIT_CEILING_DIRECTORIES &&
		cd non/git &&
		echo hello >hello &&
		echo goodbye >goodbye &&
		echo hello:hello >expect &&
		git grep --no-index o -- hello >actual &&
		test_cmp expect actual
	)
'

test_expect_success 'grep --no-index complains of revs' '
	test_must_fail git grep --no-index o main -- 2>err &&
	test_grep "cannot be used with revs" err
'

test_expect_success 'grep --no-index prefers paths to revs' '
	test_when_finished "rm -f main" &&
	echo content >main &&
	echo main:content >expect &&
	git grep --no-index o main >actual &&
	test_cmp expect actual
'

test_expect_success 'grep --no-index does not "diagnose" revs' '
	test_must_fail git grep --no-index o :1:hello.c 2>err &&
	test_grep ! -i "did you mean" err
'

cat >expected <<EOF
hello.c:int main(int argc, const char **argv)
hello.c:	printf("Hello world.\n");
EOF

test_expect_success PCRE 'grep --perl-regexp pattern' '
	git grep --perl-regexp "\p{Ps}.*?\p{Pe}" hello.c >actual &&
	test_cmp expected actual
'

test_expect_success !FAIL_PREREQS,!PCRE 'grep --perl-regexp pattern errors without PCRE' '
	test_must_fail git grep --perl-regexp "foo.*bar"
'

test_expect_success PCRE 'grep -P pattern' '
	git grep -P "\p{Ps}.*?\p{Pe}" hello.c >actual &&
	test_cmp expected actual
'

test_expect_success LIBPCRE2 "grep -P with (*NO_JIT) doesn't error out" '
	git grep -P "(*NO_JIT)\p{Ps}.*?\p{Pe}" hello.c >actual &&
	test_cmp expected actual

'

test_expect_success !FAIL_PREREQS,!PCRE 'grep -P pattern errors without PCRE' '
	test_must_fail git grep -P "foo.*bar"
'

test_expect_success 'grep pattern with grep.extendedRegexp=true' '
	test_must_fail git -c grep.extendedregexp=true \
		grep "\p{Ps}.*?\p{Pe}" hello.c >actual &&
	test_must_be_empty actual
'

test_expect_success PCRE 'grep -P pattern with grep.extendedRegexp=true' '
	git -c grep.extendedregexp=true \
		grep -P "\p{Ps}.*?\p{Pe}" hello.c >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -P -v pattern' '
	cat >expected <<-\EOF &&
	ab:a+b*c
	ab:a+bc
	EOF
	git grep -P -v "abc" ab >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -P -i pattern' '
	cat >expected <<-EOF &&
	hello.c:	printf("Hello world.\n");
	EOF
	git grep -P -i "PRINTF\([^\d]+\)" hello.c >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -P -w pattern' '
	cat >expected <<-\EOF &&
	hello_world:Hello world
	hello_world:HeLLo world
	EOF
	git grep -P -w "He((?i)ll)o" hello_world >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -P backreferences work (the PCRE NO_AUTO_CAPTURE flag is not set)' '
	git grep -P -h "(?P<one>.)(?P=one)" hello_world >actual &&
	test_cmp hello_world actual &&
	git grep -P -h "(.)\1" hello_world >actual &&
	test_cmp hello_world actual
'

test_expect_success 'grep -G invalidpattern properly dies ' '
	test_must_fail git grep -G "a["
'

test_expect_success 'grep invalidpattern properly dies with grep.patternType=basic' '
	test_must_fail git -c grep.patterntype=basic grep "a["
'

test_expect_success 'grep -E invalidpattern properly dies ' '
	test_must_fail git grep -E "a["
'

test_expect_success 'grep invalidpattern properly dies with grep.patternType=extended' '
	test_must_fail git -c grep.patterntype=extended grep "a["
'

test_expect_success PCRE 'grep -P invalidpattern properly dies ' '
	test_must_fail git grep -P "a["
'

test_expect_success PCRE 'grep invalidpattern properly dies with grep.patternType=perl' '
	test_must_fail git -c grep.patterntype=perl grep "a["
'

test_expect_success 'grep -G -E -F pattern' '
	echo "ab:a+b*c" >expected &&
	git grep -G -E -F "a+b*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep pattern with grep.patternType=basic, =extended, =fixed' '
	echo "ab:a+b*c" >expected &&
	git \
		-c grep.patterntype=basic \
		-c grep.patterntype=extended \
		-c grep.patterntype=fixed \
		grep "a+b*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -E -F -G pattern' '
	echo "ab:a+bc" >expected &&
	git grep -E -F -G "a+b*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep pattern with grep.patternType=extended, =fixed, =basic' '
	echo "ab:a+bc" >expected &&
	git \
		-c grep.patterntype=extended \
		-c grep.patterntype=fixed \
		-c grep.patterntype=basic \
		grep "a+b*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -F -G -E pattern' '
	echo "ab:abc" >expected &&
	git grep -F -G -E "a+b*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep pattern with grep.patternType=fixed, =basic, =extended' '
	echo "ab:abc" >expected &&
	git \
		-c grep.patterntype=fixed \
		-c grep.patterntype=basic \
		-c grep.patterntype=extended \
		grep "a+b*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -G -F -P -E pattern' '
	echo "d0:d" >expected &&
	git grep -G -F -P -E "[\d]" d0 >actual &&
	test_cmp expected actual
'

test_expect_success 'grep pattern with grep.patternType=fixed, =basic, =perl, =extended' '
	echo "d0:d" >expected &&
	git \
		-c grep.patterntype=fixed \
		-c grep.patterntype=basic \
		-c grep.patterntype=perl \
		-c grep.patterntype=extended \
		grep "[\d]" d0 >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -G -F -E -P pattern' '
	echo "d0:0" >expected &&
	git grep -G -F -E -P "[\d]" d0 >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep pattern with grep.patternType=fixed, =basic, =extended, =perl' '
	echo "d0:0" >expected &&
	git \
		-c grep.patterntype=fixed \
		-c grep.patterntype=basic \
		-c grep.patterntype=extended \
		-c grep.patterntype=perl \
		grep "[\d]" d0 >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -P pattern with grep.patternType=fixed' '
	echo "ab:a+b*c" >expected &&
	git \
		-c grep.patterntype=fixed \
		grep -P "a\x{2b}b\x{2a}c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -F pattern with grep.patternType=basic' '
	echo "ab:a+b*c" >expected &&
	git \
		-c grep.patterntype=basic \
		grep -F "*c" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -G pattern with grep.patternType=fixed' '
	cat >expected <<-\EOF &&
	ab:a+b*c
	ab:a+bc
	EOF
	git \
		-c grep.patterntype=fixed \
		grep -G "a+b" ab >actual &&
	test_cmp expected actual
'

test_expect_success 'grep -E pattern with grep.patternType=fixed' '
	cat >expected <<-\EOF &&
	ab:a+b*c
	ab:a+bc
	ab:abc
	EOF
	git \
		-c grep.patterntype=fixed \
		grep -E "a+" ab >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c<RED>:<RESET>int main(int argc, const char **argv)
hello.c<RED>-<RESET>{
<RED>--<RESET>
hello.c<RED>:<RESET>	/* char ?? */
hello.c<RED>-<RESET>}
<RED>--<RESET>
hello_world<RED>:<RESET>Hello_world
hello_world<RED>-<RESET>HeLLo_world
EOF

test_expect_success 'grep --color, separator' '
	test_config color.grep.context		normal &&
	test_config color.grep.filename		normal &&
	test_config color.grep.function		normal &&
	test_config color.grep.linenumber	normal &&
	test_config color.grep.match		normal &&
	test_config color.grep.selected		normal &&
	test_config color.grep.separator	red &&

	git grep --color=always -A1 -e char -e lo_w hello.c hello_world |
	test_decode_color >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c:int main(int argc, const char **argv)
hello.c:	/* char ?? */

hello_world:Hello_world
EOF

test_expect_success 'grep --break' '
	git grep --break -e char -e lo_w hello.c hello_world >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c:int main(int argc, const char **argv)
hello.c-{
--
hello.c:	/* char ?? */
hello.c-}

hello_world:Hello_world
hello_world-HeLLo_world
EOF

test_expect_success 'grep --break with context' '
	git grep --break -A1 -e char -e lo_w hello.c hello_world >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c
int main(int argc, const char **argv)
	/* char ?? */
hello_world
Hello_world
EOF

test_expect_success 'grep --heading' '
	git grep --heading -e char -e lo_w hello.c hello_world >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
<BOLD;GREEN>hello.c<RESET>
4:int main(int argc, const <BLACK;BYELLOW>char<RESET> **argv)
8:	/* <BLACK;BYELLOW>char<RESET> ?? */

<BOLD;GREEN>hello_world<RESET>
3:Hel<BLACK;BYELLOW>lo_w<RESET>orld
EOF

test_expect_success 'mimic ack-grep --group' '
	test_config color.grep.context		normal &&
	test_config color.grep.filename		"bold green" &&
	test_config color.grep.function		normal &&
	test_config color.grep.linenumber	normal &&
	test_config color.grep.match		"black yellow" &&
	test_config color.grep.selected		normal &&
	test_config color.grep.separator	normal &&

	git grep --break --heading -n --color \
		-e char -e lo_w hello.c hello_world |
	test_decode_color >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
space: line with leading space1
space: line with leading space2
space: line with leading space3
EOF

test_expect_success PCRE 'grep -E "^ "' '
	git grep -E "^ " space >actual &&
	test_cmp expected actual
'

test_expect_success PCRE 'grep -P "^ "' '
	git grep -P "^ " space >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
space-line without leading space1
space: line <RED>with <RESET>leading space1
space: line <RED>with <RESET>leading <RED>space2<RESET>
space: line <RED>with <RESET>leading space3
space:line without leading <RED>space2<RESET>
EOF

test_expect_success 'grep --color -e A -e B with context' '
	test_config color.grep.context		normal &&
	test_config color.grep.filename		normal &&
	test_config color.grep.function		normal &&
	test_config color.grep.linenumber	normal &&
	test_config color.grep.matchContext	normal &&
	test_config color.grep.matchSelected	red &&
	test_config color.grep.selected		normal &&
	test_config color.grep.separator	normal &&

	git grep --color=always -C2 -e "with " -e space2  space |
	test_decode_color >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
space-line without leading space1
space- line with leading space1
space: line <RED>with <RESET>leading <RED>space2<RESET>
space- line with leading space3
space-line without leading space2
EOF

test_expect_success 'grep --color -e A --and -e B with context' '
	test_config color.grep.context		normal &&
	test_config color.grep.filename		normal &&
	test_config color.grep.function		normal &&
	test_config color.grep.linenumber	normal &&
	test_config color.grep.matchContext	normal &&
	test_config color.grep.matchSelected	red &&
	test_config color.grep.selected		normal &&
	test_config color.grep.separator	normal &&

	git grep --color=always -C2 -e "with " --and -e space2  space |
	test_decode_color >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
space-line without leading space1
space: line <RED>with <RESET>leading space1
space- line with leading space2
space: line <RED>with <RESET>leading space3
space-line without leading space2
EOF

test_expect_success 'grep --color -e A --and --not -e B with context' '
	test_config color.grep.context		normal &&
	test_config color.grep.filename		normal &&
	test_config color.grep.function		normal &&
	test_config color.grep.linenumber	normal &&
	test_config color.grep.matchContext	normal &&
	test_config color.grep.matchSelected	red &&
	test_config color.grep.selected		normal &&
	test_config color.grep.separator	normal &&

	git grep --color=always -C2 -e "with " --and --not -e space2  space |
	test_decode_color >actual &&
	test_cmp expected actual
'

cat >expected <<EOF
hello.c-
hello.c=int main(int argc, const char **argv)
hello.c-{
hello.c:	pr<RED>int<RESET>f("<RED>Hello<RESET> world.\n");
hello.c-	return 0;
hello.c-	/* char ?? */
hello.c-}
EOF

test_expect_success 'grep --color -e A --and -e B -p with context' '
	test_config color.grep.context		normal &&
	test_config color.grep.filename		normal &&
	test_config color.grep.function		normal &&
	test_config color.grep.linenumber	normal &&
	test_config color.grep.matchContext	normal &&
	test_config color.grep.matchSelected	red &&
	test_config color.grep.selected		normal &&
	test_config color.grep.separator	normal &&

	git grep --color=always -p -C3 -e int --and -e Hello --no-index hello.c |
	test_decode_color >actual &&
	test_cmp expected actual
'

test_expect_success 'grep can find things only in the work tree' '
	: >work-tree-only &&
	git add work-tree-only &&
	test_when_finished "git rm -f work-tree-only" &&
	echo "find in work tree" >work-tree-only &&
	git grep --quiet "find in work tree" &&
	test_must_fail git grep --quiet --cached "find in work tree" &&
	test_must_fail git grep --quiet "find in work tree" HEAD
'

test_expect_success 'grep selects literal pathsets directly' '
	test_when_finished "rm -f grep-literal-trace-* &&
		git rm -rf grep-literal-a grep-literal-z \
			grep-literal-dir grep-literal-dir.sibling \
			grep-literal-component grep-literal-recursive \
			grep-literal-many-*" &&
	echo "literal needle a" >grep-literal-a &&
	echo "literal needle z" >grep-literal-z &&
	mkdir -p grep-literal-dir/nested &&
	echo "literal needle directory" >grep-literal-dir/file &&
	echo "literal needle nested" >grep-literal-dir/nested/file &&
	echo "prefix sibling" >grep-literal-dir.sibling &&
	git add grep-literal-a grep-literal-z grep-literal-dir \
		grep-literal-dir.sibling &&
	cat >expected <<-\EOF &&
	grep-literal-a:1:literal needle a
	grep-literal-z:1:literal needle z
	EOF
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-paths" \
		git grep -n "literal needle" -- \
			grep-literal-z grep-literal-a >actual &&
	test_cmp expected actual &&
	test_trace2_data grep literal_path_candidates 2 \
		<grep-literal-trace-paths &&
	echo "modified literal needle z" >grep-literal-z &&
	echo "grep-literal-z:modified literal needle z" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-modified" \
		git grep "modified literal needle" -- grep-literal-z >actual &&
	test_cmp expected actual &&
	test_trace2_data grep literal_path_candidates 1 \
		<grep-literal-trace-modified &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-literal-trace-missing" \
		git grep "literal needle" -- grep-literal-missing &&
	test_trace2_data grep literal_path_candidates 0 \
		<grep-literal-trace-missing &&
	cat >expected <<-\EOF &&
	grep-literal-dir/file:literal needle directory
	grep-literal-dir/nested/file:literal needle nested
	EOF
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-directory" \
		git grep "literal needle" -- grep-literal-dir >actual &&
	test_cmp expected actual &&
	test_trace2_data grep literal_path_candidates 2 \
		<grep-literal-trace-directory &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-overlap" \
		git grep "literal needle" -- \
			grep-literal-dir grep-literal-dir/file >actual &&
	test_cmp expected actual &&
	test_trace2_data grep literal_path_candidates 2 \
		<grep-literal-trace-overlap &&
	mkdir -p grep-literal-recursive/a \
		grep-literal-recursive/b/grep-literal-component &&
	echo "recursive needle root" >grep-literal-component &&
	echo "recursive needle file" \
		>grep-literal-recursive/a/grep-literal-component &&
	echo "recursive needle child" \
		>grep-literal-recursive/b/grep-literal-component/child &&
	echo "recursive needle suffix" \
		>grep-literal-recursive/b/grep-literal-component-suffix &&
	git add grep-literal-component grep-literal-recursive &&
	cat >recursive-expected <<-\EOF &&
	grep-literal-recursive/a/grep-literal-component:recursive needle file
	EOF
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-recursive-basename" \
		git grep "recursive needle" -- \
			"**/grep-literal-component" >actual &&
	test_cmp recursive-expected actual &&
	test_trace2_data grep recursive_basename_path_candidates 1 \
		<grep-literal-trace-recursive-basename &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-escaped-basename" \
		git grep "recursive needle" -- \
			"**/grep-literal\\-component" >actual &&
	test_cmp recursive-expected actual &&
	test_grep ! "recursive_basename_path_candidates" \
		grep-literal-trace-escaped-basename &&
	cat >glob-expected <<-\EOF &&
	grep-literal-component:recursive needle root
	grep-literal-recursive/a/grep-literal-component:recursive needle file
	EOF
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-glob-basename" \
		git grep "recursive needle" -- \
			":(glob)**/grep-literal-component" >actual &&
	test_cmp glob-expected actual &&
	test_grep ! "recursive_basename_path_candidates" \
		grep-literal-trace-glob-basename &&
	for i in $(test_seq 1 40)
	do
		echo "many literal paths" >grep-literal-many-$i || return 1
	done &&
	git add grep-literal-many-* &&
	git ls-files "grep-literal-many-*" >many-paths &&
	sed "s/$/:many literal paths/" many-paths >many-expected &&
	set -- &&
	while read path
	do
		set -- "$path" "$@" || return 1
	done <many-paths &&
	set -- "$@" grep-literal-many-1 &&
	env \
		GIT_TRACE2_EVENT="$PWD/grep-literal-trace-many" \
		git grep "many literal paths" -- "$@" >actual &&
	test_cmp many-expected actual &&
	test_trace2_data grep literal_path_candidates 40 \
		<grep-literal-trace-many &&
	git update-index --assume-unchanged \
		grep-literal-dir/nested/file &&
	rm grep-literal-dir/nested/file &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-valid-directory" \
		git grep "literal needle" -- grep-literal-dir >actual &&
	test_cmp expected actual &&
	test_grep ! "literal_path_candidates" \
		grep-literal-trace-valid-directory &&
	git update-index --no-assume-unchanged \
		grep-literal-dir/nested/file &&
	git checkout -- grep-literal-dir/nested/file &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-max-depth" \
		git grep --max-depth 1 "literal needle" -- \
			grep-literal-dir >actual &&
	test_cmp expected actual &&
	test_grep ! "literal_path_candidates" \
		grep-literal-trace-max-depth &&
	GIT_TRACE2_EVENT="$PWD/grep-literal-trace-directory-slash" \
		git grep "literal needle" -- grep-literal-dir/ >actual &&
	test_cmp expected actual &&
	test_grep ! "literal_path_candidates" \
		grep-literal-trace-directory-slash
'

test_expect_success 'grep reuses observed worktree blob bytes' '
	GIT_TEST_GREP_LITERAL_PATHS=0 &&
	GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 &&
	export GIT_TEST_GREP_LITERAL_PATHS &&
	export GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES &&
	test_when_finished "unset GIT_TEST_GREP_LITERAL_PATHS \
		GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES" &&
	test_when_finished "rm -f .git/fsmonitor-attributes \
		.git/fsmonitor-equal .git/index.grep-worktree \
		.git/index.grep-worktree-generation \
		.git/index.grep-worktree-recovery \
		.git/index.grep-worktree-recovery-next \
		.git/index.grep-worktree.lock \
		.git/index.grep-worktree.save \
		grep-worktree-trace-* &&
		rm -rf grep-worktree-other &&
		git update-index --no-fsmonitor &&
		git rm -f --ignore-unmatch .gitattributes grep-worktree-equal \
			grep-worktree-converted grep-worktree-index-change \
			grep-worktree-refresh-a grep-worktree-refresh-b \
			grep-worktree-refresh-c grep-worktree-refresh-d \
			grep-worktree-refresh-negative \
			grep-worktree-rewrite" &&
	{
		echo "grep-worktree-converted text" &&
		echo "grep-worktree-equal diff=worktree"
	} >.gitattributes &&
	echo "equal worktree blob" >grep-worktree-equal &&
	printf "converted worktree blob\r\n" >grep-worktree-converted &&
	test-tool chmtime =-5 .gitattributes grep-worktree-equal \
		grep-worktree-converted &&
	git add .gitattributes grep-worktree-equal grep-worktree-converted &&
	test_config diff.worktree.textconv cat &&
	if test -z "$GIT_TEST_SPLIT_INDEX"
	then
		test_config index.skipHash true &&
		git update-index --force-write-index &&
		test_trailing_hash .git/index >actual &&
		echo $(test_oid zero) >expected &&
		test_cmp expected actual
	fi &&
	test "$(git hash-object --no-filters grep-worktree-converted)" != \
		"$(git rev-parse :grep-worktree-converted)" &&
	test_expect_code 1 git -c core.fsmonitor=false grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree &&
	test_hook --setup --clobber fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-attributes
		then
			printf ".gitattributes\0"
		fi
		if test -f .git/fsmonitor-equal
		then
			printf "grep-worktree-equal\0"
		fi
	EOF
	fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
	test_config core.fsmonitor "$fsmonitor_hook" &&
	git update-index --fsmonitor &&
	git status --porcelain >/dev/null &&
	test_expect_code 1 git -c grep.worktreeBlobCache=auto grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1 \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-auto-create" \
		git -c grep.worktreeBlobCache=auto grep \
			"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_file .git/index.grep-worktree &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-auto-create &&
	rm .git/index.grep-worktree &&
	test_must_fail git -c grep.worktreeBlobCache=invalid grep \
		"absent worktree blob" -- grep-worktree-equal 2>err &&
	test_grep "invalid value for '\''grep.worktreeblobcache'\'': '\''invalid'\''" \
		err &&
	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1073741824 \
		git -c grep.worktreeBlobCache=auto grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-default-create" \
		git grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_file .git/index.grep-worktree &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-default-create &&
	rm .git/index.grep-worktree &&
	test_expect_code 1 git -c grep.worktreeBlobCache=false grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree &&
	test_expect_code 1 git --no-optional-locks grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree &&
	>.git/index.grep-worktree.lock &&
	test_expect_code 1 git grep "absent worktree blob" -- \
		grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree &&
	rm .git/index.grep-worktree.lock &&

	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-1" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-1b" \
		git grep "absent worktree blob" -- grep-worktree-converted &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-1 &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-1 &&
	test_trace2_data grep worktree_blob/recorded_different 0 \
		<grep-worktree-trace-1 &&
	cp .git/index.grep-worktree .git/index.grep-worktree.save &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-textconv" \
		git grep --textconv "absent worktree blob" -- \
		grep-worktree-equal &&
	test_cmp .git/index.grep-worktree.save \
		.git/index.grep-worktree &&
	test_grep ! "worktree_blob/" grep-worktree-trace-textconv &&
	rm .git/index.grep-worktree.save &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-1b &&
	test_trace2_data grep worktree_blob/recorded_equal 0 \
		<grep-worktree-trace-1b &&
	test_trace2_data grep worktree_blob/recorded_different 1 \
		<grep-worktree-trace-1b &&

	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-2" \
		git grep --threads=1 "absent worktree blob" -- \
			grep-worktree-equal grep-worktree-converted &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-2 &&
	test_trace2_data grep worktree_blob/recorded_equal 0 \
		<grep-worktree-trace-2 &&
	test_trace2_data grep worktree_blob/recorded_different 1 \
		<grep-worktree-trace-2 &&
	cp .git/index.grep-worktree \
		.git/index.grep-worktree.no-optional-locks-save &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-no-optional-locks" \
		git --no-optional-locks grep \
			"absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-no-optional-locks &&
	test_cmp .git/index.grep-worktree.no-optional-locks-save \
		.git/index.grep-worktree &&
	rm .git/index.grep-worktree.no-optional-locks-save &&
	cp .git/index.grep-worktree \
		.git/index.grep-worktree.generation-save &&
	cp .git/index.grep-worktree-generation \
		.git/index.grep-worktree-generation.save &&
	rm .git/index.grep-worktree-generation &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-generation-missing" \
		git --no-optional-locks grep \
			"absent worktree blob" -- grep-worktree-equal &&
	test_path_is_missing .git/index.grep-worktree-generation &&
	test_cmp .git/index.grep-worktree.generation-save \
		.git/index.grep-worktree &&
	test_grep ! "worktree_blob/" \
		grep-worktree-trace-generation-missing &&
	printf "malformed generation" \
		>.git/index.grep-worktree-generation &&
	cp .git/index.grep-worktree-generation \
		.git/index.grep-worktree-generation.malformed &&
	test_expect_code 1 git --no-optional-locks grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_cmp .git/index.grep-worktree-generation.malformed \
		.git/index.grep-worktree-generation &&
	test_cmp .git/index.grep-worktree.generation-save \
		.git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-generation-repair" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	! test_cmp .git/index.grep-worktree-generation.malformed \
		.git/index.grep-worktree-generation &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-generation-repair &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-generation-repair &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-generation-reused" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-generation-reused &&
	cp .git/index.grep-worktree-generation \
		.git/index.grep-worktree-generation.current &&
	cp .git/index.grep-worktree-generation.save \
		.git/index.grep-worktree-generation.replace &&
	mv .git/index.grep-worktree-generation.replace \
		.git/index.grep-worktree-generation &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-generation-mismatch" \
		git --no-optional-locks grep \
			"absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-generation-mismatch &&
	mv .git/index.grep-worktree-generation.current \
		.git/index.grep-worktree-generation &&
	rm .git/index.grep-worktree.generation-save \
		.git/index.grep-worktree-generation.save \
		.git/index.grep-worktree-generation.malformed &&
	if test -z "$(git rev-parse --shared-index-path)"
	then
		rm .git/index.grep-worktree-recovery &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-no-recovery" \
			git grep "absent worktree blob" -- \
				grep-worktree-equal &&
		test_trace2_data grep worktree_blob/hits 1 \
			<grep-worktree-trace-no-recovery &&
		test_path_is_missing .git/index.grep-worktree-recovery
	fi &&
	env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1 \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-quiet" \
		git -c grep.worktreeBlobCache=auto grep --quiet \
		"equal worktree blob" -- grep-worktree-equal &&
	test_grep ! "worktree_blob/" grep-worktree-trace-quiet &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-quiet-true" \
		git -c grep.worktreeBlobCache=true grep --quiet \
		"equal worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-quiet-true &&
	echo "disabled worktree blob" >grep-worktree-equal &&
	echo "grep-worktree-equal:disabled worktree blob" >expected &&
	git -c grep.worktreeBlobCache=false grep \
		"disabled worktree blob" -- grep-worktree-equal >actual &&
	test_cmp expected actual &&
	echo "no fsmonitor worktree blob" >grep-worktree-equal &&
	echo "grep-worktree-equal:no fsmonitor worktree blob" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-no-fsmonitor" \
		git -c core.fsmonitor=false grep \
		"no fsmonitor worktree blob" -- grep-worktree-equal \
		>actual 2>err &&
	test_cmp expected actual &&
	test_must_be_empty err &&
	test_grep ! "worktree_blob/" grep-worktree-trace-no-fsmonitor &&
	echo "equal worktree blob" >grep-worktree-equal &&
	test_expect_code 1 env \
		GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES=1073741824 \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-auto" \
		git -c grep.worktreeBlobCache=auto grep \
		"absent worktree blob" -- grep-worktree-equal &&
	test_grep ! "worktree_blob/" grep-worktree-trace-auto &&
	cp .git/index.grep-worktree .git/index.grep-worktree.save &&
	rm .git/index.grep-worktree &&
	printf "truncated sidecar" >.git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-malformed" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-malformed &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-recovered" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-recovered &&
	rawsz=$(test_oid rawsz) &&
	git ls-files >grep-worktree-index-files &&
	index_nr=$(wc -l <grep-worktree-index-files) &&
	rm grep-worktree-index-files &&
	bitmap_size=$(((index_nr + 7) / 8)) &&
	# Keep the exact section valid, but pair zero base entries with a
	# non-null base identity.
	{
		test_copy_bytes 16 <.git/index.grep-worktree &&
		test-tool genzeros 4 &&
		dd if=.git/index.grep-worktree bs=1 skip=20 \
			count="$rawsz" 2>/dev/null &&
		printf "\001" &&
		test-tool genzeros $((rawsz - 1)) &&
		dd if=.git/index.grep-worktree bs=1 \
			skip=$((20 + 2 * rawsz)) \
			count=$((2 * rawsz + 2 * bitmap_size)) 2>/dev/null
	} >.git/index.grep-worktree.malformed &&
	test-tool $(test_oid algo) -b \
		<.git/index.grep-worktree.malformed \
		>.git/index.grep-worktree.checksum &&
	cat .git/index.grep-worktree.checksum \
		>>.git/index.grep-worktree.malformed &&
	mv .git/index.grep-worktree.malformed \
		.git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-malformed-base" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-malformed-base &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-malformed-base &&
	sidecar_size=$(wc -c <.git/index.grep-worktree) &&
	equal_offset=$((20 + 4 * rawsz)) &&
	different_offset=$((equal_offset + bitmap_size)) &&
	{
		test_copy_bytes "$different_offset" \
			<.git/index.grep-worktree &&
		dd if=.git/index.grep-worktree bs=1 \
			skip="$equal_offset" count="$bitmap_size" \
			2>/dev/null &&
		dd if=.git/index.grep-worktree bs=1 \
			skip=$((different_offset + bitmap_size)) \
			count=$((sidecar_size - rawsz -
				 different_offset - bitmap_size)) \
			2>/dev/null
	} >.git/index.grep-worktree.malformed &&
	test-tool $(test_oid algo) -b \
		<.git/index.grep-worktree.malformed \
		>.git/index.grep-worktree.checksum &&
	cat .git/index.grep-worktree.checksum \
		>>.git/index.grep-worktree.malformed &&
	mv .git/index.grep-worktree.malformed \
		.git/index.grep-worktree &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-malformed-overlap" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-malformed-overlap &&
	test_trace2_data grep worktree_blob/recorded_equal 1 \
		<grep-worktree-trace-malformed-overlap &&
	rm .git/index.grep-worktree.checksum &&
	rm .git/index.grep-worktree &&
	mv .git/index.grep-worktree.save .git/index.grep-worktree &&
	if test -z "$(git rev-parse --shared-index-path)"
	then
		rm .git/index.grep-worktree-recovery
	fi &&

	echo "rewrite index" >grep-worktree-rewrite &&
	test-tool chmtime =-5 grep-worktree-rewrite &&
	git add grep-worktree-rewrite &&
	git status --porcelain >/dev/null &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-rewrite" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	if test -n "$(git rev-parse --shared-index-path)"
	then
		test_trace2_data grep worktree_blob/hits 1 \
			<grep-worktree-trace-rewrite &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<grep-worktree-trace-rewrite
	else
		test_trace2_data grep worktree_blob/hits 0 \
			<grep-worktree-trace-rewrite &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<grep-worktree-trace-rewrite &&
		test_trace2_data grep worktree_blob/recovery_invalid 1 \
			<grep-worktree-trace-rewrite &&
		test_trace2_data grep worktree_blob/recovery_revoked 1 \
			<grep-worktree-trace-rewrite &&
		test_path_is_missing .git/index.grep-worktree-recovery &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-bootstrap" \
			git grep "absent worktree blob" -- \
				grep-worktree-equal &&
		test_trace2_data grep worktree_blob/hits 1 \
			<grep-worktree-trace-bootstrap &&
		test_path_is_file .git/index.grep-worktree-recovery
	fi &&

	echo "changed worktree blob" >grep-worktree-equal &&
	>.git/fsmonitor-equal &&
	echo "grep-worktree-equal:changed worktree blob" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-changed" \
		git grep "changed worktree blob" -- grep-worktree-equal >actual &&
	test_cmp expected actual &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-changed &&
	echo "equal worktree blob" >grep-worktree-equal &&
	rm .git/fsmonitor-equal &&

	echo "grep-worktree-converted -text" >.gitattributes &&
	>.git/fsmonitor-attributes &&
	pattern=$(printf "worktree blob\r") &&
	printf "grep-worktree-converted:converted worktree blob\r\n" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-3" \
		git grep "$pattern" -- grep-worktree-converted >actual &&
	test_cmp expected actual &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-3 &&
	test_trace2_data grep worktree_blob/recorded_equal 0 \
		<grep-worktree-trace-3 &&
	test_trace2_data grep worktree_blob/recorded_different 1 \
		<grep-worktree-trace-3 &&

	echo "index change" >grep-worktree-index-change &&
	git add grep-worktree-index-change &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-4" \
		git grep "absent worktree blob" -- grep-worktree-equal &&
	if test -n "$(git rev-parse --shared-index-path)"
	then
		test_trace2_data grep worktree_blob/hits 0 \
			<grep-worktree-trace-4 &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<grep-worktree-trace-4
	else
		test_trace2_data grep worktree_blob/hits 1 \
			<grep-worktree-trace-4 &&
		test_trace2_data grep worktree_blob/recovered_identity 1 \
			<grep-worktree-trace-4 &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<grep-worktree-trace-4
	fi &&

	oid=$(git rev-parse :grep-worktree-equal) &&
	echo "replacement blob" >replacement &&
	replacement=$(git hash-object -w replacement) &&
	rm replacement &&
	git replace "$oid" "$replacement" &&
	test_when_finished "test_might_fail git replace -d $oid" &&
	echo "grep-worktree-equal:equal worktree blob" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-5" \
		git grep "equal worktree blob" -- grep-worktree-equal >actual &&
	test_cmp expected actual &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-5 &&
	git replace -d "$oid" &&

	repository_format=$(
		git config --get core.repositoryFormatVersion || echo 0
	) &&
	test_when_finished "git config core.repositoryFormatVersion \
		$repository_format" &&
	git config core.repositoryFormatVersion 1 &&
	test_config extensions.partialClone origin &&
	test_config remote.origin.promisor true &&
	test_config remote.origin.url "$PWD/grep-worktree-missing-remote" &&
	object=.git/objects/$(test_oid_to_path "$oid") &&
	mv "$object" "$object.save" &&
	test_when_finished "test ! -e \"$object.save\" ||
		mv \"$object.save\" \"$object\"" &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-6" \
		git grep "equal worktree blob" -- grep-worktree-equal >actual 2>err &&
	test_cmp expected actual &&
	test_must_be_empty err &&
	test_grep ! "\"key\":\"fetch_count\"" grep-worktree-trace-6 &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-6 &&
	mv "$object.save" "$object" &&
	mv "$object" "$object.save" &&
	>"$object" &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-corrupt" \
		git grep "equal worktree blob" -- grep-worktree-equal \
		>actual 2>err &&
	test_cmp expected actual &&
	test_grep "object file .* is empty" err &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-corrupt &&
	rm "$object" &&
	mv "$object.save" "$object" &&

	{
		echo "grep-worktree-converted -text" &&
		echo "grep-worktree-equal text"
	} >.gitattributes &&
	git add .gitattributes &&
	test_expect_code 1 git grep "absent worktree blob" -- \
		grep-worktree-equal &&
	>.git/fsmonitor-equal &&
	printf "equal worktree blob\r\n" >grep-worktree-equal &&
	git add grep-worktree-equal &&
	rm .git/fsmonitor-equal &&
	git status --porcelain >/dev/null &&
	test "$oid" = "$(git rev-parse :grep-worktree-equal)" &&
	pattern=$(printf "worktree blob\r") &&
	printf "grep-worktree-equal:equal worktree blob\r\n" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-same-oid" \
		git grep "$pattern" -- grep-worktree-equal >actual &&
	test_cmp expected actual &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-same-oid &&
	test_trace2_data grep worktree_blob/recorded_equal 0 \
		<grep-worktree-trace-same-oid &&
	test_trace2_data grep worktree_blob/recorded_different 1 \
		<grep-worktree-trace-same-oid &&
	test_trace2_data grep worktree_blob/recovered_split_base 0 \
		<grep-worktree-trace-same-oid &&

	mkdir grep-worktree-other &&
	echo "other worktree blob" >grep-worktree-other/grep-worktree-equal &&
	echo "grep-worktree-equal:other worktree blob" >expected &&
	GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-other" \
		git --no-optional-locks \
			--work-tree="$PWD/grep-worktree-other" \
			grep "other worktree blob" -- grep-worktree-equal \
			>actual 2>err &&
	test_cmp expected actual &&
	test_must_be_empty err &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-other &&

	if test -z "$(git rev-parse --shared-index-path)"
	then
		rm -f .git/index.grep-worktree \
			.git/index.grep-worktree-recovery \
			.git/index.grep-worktree-recovery-next &&
		echo "recovery entry a" >grep-worktree-refresh-a &&
		echo "recovery entry b" >grep-worktree-refresh-b &&
		git add grep-worktree-refresh-a grep-worktree-refresh-b &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep "absent worktree blob" -- \
			grep-worktree-refresh-a &&
		test_path_is_file .git/index.grep-worktree-recovery &&
		echo "recovery entry c" >grep-worktree-refresh-c &&
		echo "recovery negative index" \
			>grep-worktree-refresh-negative &&
		git add grep-worktree-refresh-c \
			grep-worktree-refresh-negative &&
		git status --porcelain >/dev/null &&
		echo "recovery negative worktree" \
			>grep-worktree-refresh-negative &&
		git update-index --fsmonitor-valid \
			grep-worktree-refresh-negative &&
		test_expect_code 1 env \
			GIT_TEST_GREP_WORKTREE_RECOVERY_REFRESH_MIN_ENTRIES=1 \
			GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-refresh" \
			git grep "absent worktree blob" -- \
				grep-worktree-refresh-b \
				grep-worktree-refresh-negative &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<grep-worktree-trace-refresh &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<grep-worktree-trace-refresh &&
		test_path_is_file .git/index.grep-worktree-recovery-next &&
		echo "recovery entry d" >grep-worktree-refresh-d &&
		git add grep-worktree-refresh-d &&
		git status --porcelain >/dev/null &&
		git update-index --fsmonitor-valid \
			grep-worktree-refresh-negative &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-refreshed" \
			git grep "absent worktree blob" -- \
				grep-worktree-refresh-a \
				grep-worktree-refresh-b \
				grep-worktree-refresh-negative &&
		test_trace2_data grep worktree_blob/recovered_identity 2 \
			<grep-worktree-trace-refreshed &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<grep-worktree-trace-refreshed
	fi
'

test_expect_success 'grep handles cache after index replacement' '
	GIT_TEST_GREP_LITERAL_PATHS=0 &&
	export GIT_TEST_GREP_LITERAL_PATHS &&
	test_when_finished "unset GIT_TEST_GREP_LITERAL_PATHS" &&
	test_config grep.worktreeBlobCache true &&
	test_when_finished "rm -f .git/fsmonitor-replace-index \
		.git/index.original .git/index.replace \
		.git/index.replace.stale \
		.git/index.grep-worktree \
		.git/index.grep-worktree-generation \
		.git/index.grep-worktree-recovery \
		grep-worktree-trace-race \
		grep-worktree-trace-race-newer &&
		git update-index --no-fsmonitor &&
		git rm -f --ignore-unmatch grep-worktree-race-before \
			grep-worktree-race-equal grep-worktree-race-zafter" &&
	echo "equal before index replacement" >grep-worktree-race-equal &&
	echo "after cached entry" >grep-worktree-race-zafter &&
	test-tool chmtime =-5 grep-worktree-race-equal \
		grep-worktree-race-zafter &&
	git add grep-worktree-race-equal grep-worktree-race-zafter &&
	test_hook --setup --clobber fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-replace-index
		then
			mv .git/index.replace .git/index
			rm .git/fsmonitor-replace-index
			GIT_TRACE2_EVENT= git grep "absent newer sidecar" -- \
				grep-worktree-race-equal >/dev/null 2>&1
			test $? = 1 || exit 1
		fi
	EOF
	test_config core.fsmonitor .git/hooks/fsmonitor-test &&
	git update-index --fsmonitor &&
	git status --porcelain >/dev/null &&
	test_expect_code 1 git grep "absent before replacement" -- \
		grep-worktree-race-equal &&
	test_path_is_file .git/index.grep-worktree &&
	cp .git/index .git/index.original &&

	echo "indexed before replacement" >grep-worktree-race-before &&
	git add grep-worktree-race-before &&
	git rm --cached grep-worktree-race-zafter &&
	git status --porcelain >/dev/null &&
	cp .git/index .git/index.replace &&
	rawsz=$(test_oid rawsz) &&
	replace_size=$(wc -c <.git/index.replace) &&
	test_copy_bytes $((replace_size - rawsz)) \
		<.git/index.replace >.git/index.replace.stale &&
	tail -c "$rawsz" .git/index.original \
		>>.git/index.replace.stale &&
	mv .git/index.replace.stale .git/index.replace &&
	mv .git/index.original .git/index &&
	echo "worktree after replacement" >grep-worktree-race-before &&
	>.git/fsmonitor-replace-index &&

	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-race" \
		git grep "absent after replacement" -- \
		grep-worktree-race-equal grep-worktree-race-zafter &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-race &&
	test_trace2_data grep worktree_blob/recovered_identity 0 \
		<grep-worktree-trace-race &&
	test_trace2_data grep worktree_blob/recorded_equal 2 \
		<grep-worktree-trace-race &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-race-newer" \
		git grep "absent newer sidecar" -- \
			grep-worktree-race-equal &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-race-newer &&
	test_trace2_data grep worktree_blob/recovered_identity 0 \
		<grep-worktree-trace-race-newer &&
	echo "grep-worktree-race-before:worktree after replacement" >expected &&
	git grep "worktree after replacement" -- \
		grep-worktree-race-before >actual &&
	test_cmp expected actual
'

test_lazy_prereq NO_FORCED_SPLIT_INDEX '
	! test_bool_env GIT_TEST_SPLIT_INDEX false
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree cache recovers non-split index entries' '
	test_when_finished "rm -rf grep-worktree-recovery" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-recovery &&
		cd grep-worktree-recovery &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		export GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES &&
		echo "recovery target" >target &&
		echo "recovery other" >other &&
		echo "recovery sentinel" >sentinel &&
		test-tool chmtime =-5 target other sentinel &&
		git add target other sentinel &&
		test_hook --setup --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			if test -f .git/fsmonitor-target
			then
				printf "target\0"
			fi
			if test -f .git/fsmonitor-other
			then
				printf "other\0"
			fi
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep "absent recovery" -- \
			target other sentinel &&
		test_path_is_file .git/index.grep-worktree &&
		test_path_is_file .git/index.grep-worktree-recovery &&
		cp .git/index.grep-worktree .git/index.grep-worktree.save &&

		test-tool chmtime =-10 other &&
		>.git/fsmonitor-other &&
		git status --porcelain >/dev/null &&
		rm .git/fsmonitor-other &&
		git update-index --fsmonitor-valid other &&
		test_expect_code 1 env \
			GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=2 \
			GIT_TRACE2_EVENT="$PWD/trace-stat" \
			git grep "absent recovery" -- target &&
		test_trace2_data grep worktree_blob/recovered_identity 1 \
			<trace-stat &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<trace-stat &&
		test_cmp .git/index.grep-worktree.save \
			.git/index.grep-worktree &&
		test_expect_code 1 env \
			GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=2 \
			GIT_TRACE2_EVENT="$PWD/trace-stat-repeat" \
			git grep "absent recovery" -- target &&
		test_trace2_data grep worktree_blob/recovered_identity 1 \
			<trace-stat-repeat &&
		test_cmp .git/index.grep-worktree.save \
			.git/index.grep-worktree &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-stat-promote" \
			git grep "absent recovery" -- target &&
		test_trace2_data grep worktree_blob/recovered_identity 1 \
			<trace-stat-promote &&
		! test_cmp .git/index.grep-worktree.save \
			.git/index.grep-worktree &&
		rm .git/index.grep-worktree.save &&
		cp .git/index.grep-worktree .git/index.grep-worktree.save &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-stat-exact" \
			git grep "absent recovery" -- target &&
		test_trace2_data grep worktree_blob/hits 1 \
			<trace-stat-exact &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<trace-stat-exact &&
		test_cmp .git/index.grep-worktree.save \
			.git/index.grep-worktree &&
		rm .git/index.grep-worktree.save &&

		echo "recovery added" >aaa &&
		test-tool chmtime =-5 aaa &&
		git add aaa &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-shift" \
			git grep "absent recovery" -- target aaa &&
		test_trace2_data grep worktree_blob/recovered_identity 1 \
			<trace-shift &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<trace-shift &&

		cp .git/index.grep-worktree-recovery \
			.git/index.grep-worktree-recovery.save &&
		cp .git/index.grep-worktree-recovery \
			.git/index.grep-worktree-recovery-next &&
		echo "recovery generation" >bbb &&
		test-tool chmtime =-5 bbb &&
		git add bbb &&
		git status --porcelain >/dev/null &&
		rawsz=$(test_oid rawsz) &&
		recovery_size=$(wc -c \
			<.git/index.grep-worktree-recovery) &&
		{
			test_copy_bytes $((recovery_size - 2 * rawsz)) \
				<.git/index.grep-worktree-recovery &&
			dd if=.git/index.grep-worktree-recovery bs=1 \
				skip=$((recovery_size - 3 * rawsz)) \
				count="$rawsz" 2>/dev/null &&
			dd if=.git/index.grep-worktree-recovery bs=1 \
				skip=$((recovery_size - rawsz)) \
				count="$rawsz" 2>/dev/null
		} >.git/index.grep-worktree-recovery.corrupt &&
		mv .git/index.grep-worktree-recovery.corrupt \
			.git/index.grep-worktree-recovery &&
		test_expect_code 1 env \
			GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=3 \
			GIT_TRACE2_EVENT="$PWD/trace-recovery-fallback" \
			git grep --no-content-index \
				"absent recovery" -- target sentinel &&
		test_trace2_data grep worktree_blob/recovered_identity 2 \
			<trace-recovery-fallback &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<trace-recovery-fallback &&
		test_trace2_data grep worktree_blob/recovery_invalid 0 \
			<trace-recovery-fallback &&
		rm .git/index.grep-worktree-recovery-next &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-corrupt-recovery" \
			git grep --no-content-index \
				"absent recovery" -- target sentinel &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<trace-corrupt-recovery &&
		test_trace2_data grep worktree_blob/recorded_equal 2 \
			<trace-corrupt-recovery &&
		test_trace2_data grep worktree_blob/recovery_invalid 1 \
			<trace-corrupt-recovery &&
		test_trace2_data grep worktree_blob/recovery_revoked 1 \
			<trace-corrupt-recovery &&
		mv .git/index.grep-worktree-recovery.save \
			.git/index.grep-worktree-recovery &&
		echo "recovery after corruption" >ccc &&
		test-tool chmtime =-5 ccc &&
		git add ccc &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-after-corruption" \
			git grep --no-content-index \
				"absent recovery" -- target &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<trace-after-corruption &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<trace-after-corruption &&

		echo "worktree-only recovery" >target &&
		test-tool chmtime =-15 other target &&
		>.git/fsmonitor-other &&
		>.git/fsmonitor-target &&
		git status --porcelain >/dev/null &&
		rm .git/fsmonitor-other .git/fsmonitor-target &&
		echo "target:worktree-only recovery" >expected &&
		GIT_TRACE2_EVENT="$PWD/trace-dirty" \
		git grep "worktree-only recovery" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 <trace-dirty &&

		git checkout -- target &&
		test-tool chmtime =-20 target &&
		>.git/fsmonitor-target &&
		git status --porcelain >/dev/null &&
		rm .git/fsmonitor-target &&
		test_expect_code 1 git grep "absent recovery" -- target &&
		test-tool chmtime =-20 other &&
		>.git/fsmonitor-other &&
		git status --porcelain >/dev/null &&
		rm .git/fsmonitor-other &&
		rm .git/index.grep-worktree-recovery &&
		printf "malformed recovery" \
			>.git/index.grep-worktree-recovery &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-malformed" \
			git grep --no-content-index \
				"absent recovery" -- target &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<trace-malformed &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<trace-malformed
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree recovery compares full SHA-256 identities' '
	test_when_finished "rm -rf grep-worktree-recovery-identity" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-recovery-identity &&
		cd grep-worktree-recovery-identity &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		export GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES &&
		echo "recovery identity target" >target &&
		test-tool chmtime =-5 target &&
		git add target &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep \
			"absent recovery identity" -- target &&

		rawsz=$(test_oid rawsz) &&
		recovery=.git/index.grep-worktree-recovery &&
		recovery_size=$(wc -c <"$recovery") &&
		recovery_body_size=$((recovery_size - rawsz)) &&
		identity_byte=$((16 + rawsz + 65536 * 4 + 31)) &&
		byte=$(dd if="$recovery" bs=1 skip="$identity_byte" \
			count=1 2>/dev/null | test-tool hexdump) &&
		if test "$byte" = "00 "
		then
			printf "\001" >replacement
		else
			test-tool genzeros 1 >replacement
		fi &&
		{
			test_copy_bytes "$identity_byte" <"$recovery" &&
			cat replacement &&
			dd if="$recovery" bs=1 \
				skip=$((identity_byte + 1)) \
				count=$((recovery_body_size -
					 identity_byte - 1)) 2>/dev/null
		} >recovery.body &&
		test-tool $(test_oid algo) -b \
			<recovery.body >recovery.checksum &&
		cat recovery.body recovery.checksum >recovery.new &&
		mv recovery.new "$recovery" &&

		compact=.git/index.grep-worktree &&
		compact_size=$(wc -c <"$compact") &&
		compact_body_size=$((compact_size - rawsz)) &&
		recovery_checksum_offset=$((20 + 2 * rawsz)) &&
		{
			test_copy_bytes "$recovery_checksum_offset" \
				<"$compact" &&
			cat recovery.checksum &&
			dd if="$compact" bs=1 \
				skip=$((recovery_checksum_offset + rawsz)) \
				count=$((compact_body_size -
					 recovery_checksum_offset -
					 rawsz)) 2>/dev/null
		} >compact.body &&
		test-tool $(test_oid algo) -b \
			<compact.body >compact.checksum &&
		cat compact.body compact.checksum >compact.new &&
		mv compact.new "$compact" &&

		echo "recovery identity shift" >shift &&
		test-tool chmtime =-5 shift &&
		git add shift &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/identity.trace" \
			git grep "absent recovery identity" -- target &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<identity.trace &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<identity.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree cache handles concurrent recovery updates' '
	test_when_finished "rm -rf grep-worktree-recovery-race" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-recovery-race &&
		cd grep-worktree-recovery-race &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "recovery race" >target &&
		test-tool chmtime =-5 target &&
		git add target &&
		test_hook --setup --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			if test -f .git/fsmonitor-mutate-target
			then
				echo "changed during cache write" >target
				rm .git/fsmonitor-mutate-target
			fi
			if test -f .git/fsmonitor-target
			then
				printf "target\0"
			fi
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		cp .git/index .git/index.old &&
		echo "recovery race other" >other &&
		test-tool chmtime =-5 other &&
		git add other &&
		git status --porcelain >/dev/null &&
		cp .git/index .git/index.new &&
		test_expect_code 1 git grep "absent recovery race" -- target &&
		test_path_is_file .git/index.grep-worktree &&
		test_path_is_missing .git/index.grep-worktree-recovery &&
		publisher_hold="$PWD/.git/grep-worktree-publisher-hold" &&
		publisher_ready="$PWD/.git/grep-worktree-publisher-ready" &&
		>"$publisher_hold" &&

		{
			env \
				GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$publisher_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=locked \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$publisher_ready" \
				git grep "absent recovery race" -- target \
				>publisher.out 2>publisher.err &
		} &&
		publisher_pid=$! &&
		trap "kill $publisher_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$publisher_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$publisher_ready" &&
		test_path_is_file .git/index.grep-worktree-recovery.lock &&
		test_path_is_file .git/index.grep-worktree.lock &&
		cp .git/index.grep-worktree-generation \
			.git/index.grep-worktree-generation.before &&

		cp .git/index.old .git/index &&
		negative_hold="$PWD/.git/grep-worktree-negative-hold" &&
		negative_ready="$PWD/.git/grep-worktree-negative-ready" &&
		>"$negative_hold" &&
		>.git/fsmonitor-mutate-target &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$negative_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$negative_ready" \
				GIT_TRACE2_EVENT="$PWD/pending-negative.trace" \
				git grep "absent recovery race" -- target \
				>negative.out 2>negative.err &
		} &&
		negative_pid=$! &&
		trap "kill $publisher_pid $negative_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$negative_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$negative_ready" &&
		test_path_is_missing .git/fsmonitor-mutate-target &&
		cp .git/index.new .git/index &&
		rm "$negative_hold" &&
		test_expect_code 1 wait "$negative_pid" &&
		trap "kill $publisher_pid 2>/dev/null || :" 0 &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<pending-negative.trace &&
		test_path_is_file .git/index.grep-worktree-generation &&
		! test_cmp .git/index.grep-worktree-generation.before \
			.git/index.grep-worktree-generation &&
		rm "$publisher_hold" &&
		test_expect_code 1 wait "$publisher_pid" &&
		trap - 0 &&
		test_path_is_file .git/index.grep-worktree-recovery &&
		test_path_is_missing .git/index.grep-worktree-recovery.lock &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/post-negative.trace" \
			git grep "absent recovery race" -- target &&
		test_trace2_data grep worktree_blob/hits 0 \
			<post-negative.trace &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<post-negative.trace &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<post-negative.trace &&

		>.git/fsmonitor-target &&
		git checkout -- target &&
		rm .git/fsmonitor-target &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 env \
			GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 \
			GIT_TRACE2_EVENT="$PWD/rebootstrap.trace" \
			git grep "absent recovery race" -- target &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<rebootstrap.trace &&
		test_path_is_file .git/index.grep-worktree-recovery &&
		echo "recovery race shift" >shift &&
		test-tool chmtime =-5 shift &&
		git add shift &&
		git status --porcelain >/dev/null &&
		rawsz=$(test_oid rawsz) &&

		hold="$PWD/.git/grep-worktree-promotion-hold" &&
		ready="$PWD/.git/grep-worktree-promotion-ready" &&
		>"$hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES=1 \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=recovery \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$ready" \
				GIT_TRACE2_EVENT="$PWD/promotion.trace" \
				git grep "absent recovery race" -- target \
				>promotion.out 2>promotion.err &
		} &&
		grep_pid=$! &&
		trap "kill $grep_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$ready" &&

		sidecar_size=$(wc -c <.git/index.grep-worktree) &&
		recovery_offset=$((20 + 2 * rawsz)) &&
		{
			test_copy_bytes "$recovery_offset" \
				<.git/index.grep-worktree &&
			test-tool genzeros "$rawsz" &&
			dd if=.git/index.grep-worktree bs=1 \
				skip=$((recovery_offset + rawsz)) \
				count=$((sidecar_size - 2 * rawsz -
					 recovery_offset)) 2>/dev/null
		} >.git/index.grep-worktree.revoked &&
		test-tool $(test_oid algo) -b \
			<.git/index.grep-worktree.revoked \
			>.git/index.grep-worktree.checksum &&
		cat .git/index.grep-worktree.checksum \
			>>.git/index.grep-worktree.revoked &&
		mv .git/index.grep-worktree.revoked \
			.git/index.grep-worktree &&
		cp .git/index.grep-worktree .git/index.grep-worktree.revoked &&
		rm "$hold" &&
		test_expect_code 1 wait "$grep_pid" &&
		trap - 0 &&
		test_trace2_data grep worktree_blob/recovered_identity 1 \
			<promotion.trace &&
		test_cmp .git/index.grep-worktree.revoked \
			.git/index.grep-worktree &&

		rm -f .git/index.grep-worktree \
			.git/index.grep-worktree-recovery &&
		git update-index --fsmonitor-valid target &&
		positive_hold="$PWD/.git/grep-worktree-positive-hold" &&
		positive_ready="$PWD/.git/grep-worktree-positive-ready" &&
		>"$positive_hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$positive_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$positive_ready" \
				git grep "absent stale positive" -- target \
				>positive.out 2>positive.err &
		} &&
		positive_pid=$! &&
		trap "kill $positive_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$positive_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$positive_ready" &&

		echo "changed after stale positive" >target &&
		git update-index --fsmonitor-valid target &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/newer-negative.trace" \
			git grep "absent stale positive" -- target &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<newer-negative.trace &&
		rm "$positive_hold" &&
		test_expect_code 1 wait "$positive_pid" &&
		trap - 0 &&
		echo "target:changed after stale positive" >expected &&
		GIT_TRACE2_EVENT="$PWD/stale-positive.trace" \
			git grep "changed after stale positive" -- \
				target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<stale-positive.trace &&
		test_trace2_data grep worktree_blob/recovered_identity 0 \
			<stale-positive.trace &&

		echo "recovery race" >target &&
		git update-index --fsmonitor-valid target &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/sticky-negative.trace" \
			git grep "absent sticky negative" -- target &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/sticky-negative-repeat.trace" \
			git grep "absent sticky negative" -- target &&
		test_trace2_data grep worktree_blob/hits 0 \
			<sticky-negative.trace &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<sticky-negative.trace &&
		test_trace2_data grep worktree_blob/hits 0 \
			<sticky-negative-repeat.trace &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<sticky-negative-repeat.trace &&

		rm -f .git/index.grep-worktree \
			.git/index.grep-worktree-recovery &&
		git update-index --fsmonitor-valid target &&
		test_expect_code 1 git grep \
			"absent source checksum" -- target &&
		echo "source checksum other" >checksum-other &&
		test-tool chmtime =-5 checksum-other &&
		git add checksum-other &&
		git status --porcelain >/dev/null &&
		echo "changed before delayed negative" >target &&
		git update-index --fsmonitor-valid target &&
		negative_hold="$PWD/.git/grep-worktree-checksum-hold" &&
		negative_ready="$PWD/.git/grep-worktree-checksum-ready" &&
		>"$negative_hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$negative_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$negative_ready" \
				GIT_TRACE2_EVENT="$PWD/checksum-negative.trace" \
				git grep "absent source checksum" -- target \
				>checksum-negative.out \
				2>checksum-negative.err &
		} &&
		negative_pid=$! &&
		trap "kill $negative_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$negative_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$negative_ready" &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/checksum-positive.trace" \
			git grep "absent source checksum" -- checksum-other &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<checksum-positive.trace &&
		rm "$negative_hold" &&
		test_expect_code 1 wait "$negative_pid" &&
		trap - 0 &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<checksum-negative.trace &&
		test_trace2_data grep worktree_blob/direct_write 1 \
			<checksum-negative.trace &&
		echo "target:changed before delayed negative" >expected &&
		GIT_TRACE2_EVENT="$PWD/checksum-result.trace" \
			git grep "changed before delayed negative" -- \
				target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<checksum-result.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree repeated negative remaps after index change' '
	test_when_finished "rm -rf grep-worktree-repeated-negative" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-repeated-negative &&
		cd grep-worktree-repeated-negative &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "repeated negative target" >target &&
		echo "direct negative target" >direct &&
		test-tool chmtime =-5 target direct &&
		git add target direct &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&

		rm -f .git/index.grep-worktree \
			.git/index.grep-worktree-recovery &&
		echo "dirty repeated negative" >target &&
		git update-index --fsmonitor-valid target &&
		git grep "dirty repeated negative" -- target >actual &&
		echo "target:dirty repeated negative" >expected &&
		test_cmp expected actual &&
		echo "dirty direct negative" >direct &&
		git update-index --fsmonitor-valid direct &&
		GIT_TRACE2_EVENT="$PWD/direct-negative.trace" \
			git grep "dirty direct negative" -- direct >actual &&
		echo "direct:dirty direct negative" >expected-direct &&
		test_cmp expected-direct actual &&
		test_trace2_data grep worktree_blob/direct_write 1 \
			<direct-negative.trace &&
		echo "direct negative target" >direct &&
		git update-index --fsmonitor-valid direct &&
		cp .git/index .git/index.repeated-old &&
		cp .git/index.grep-worktree \
			.git/index.grep-worktree.repeated-old &&

		echo "repeated negative shift" >shift &&
		test-tool chmtime =-5 shift &&
		git add shift &&
		echo "repeated negative target" >target &&
		git update-index --fsmonitor-valid target &&
		test_expect_code 1 git grep \
			"absent repeated negative" -- target &&
		cp .git/index .git/index.repeated-new &&
		cp .git/index.grep-worktree \
			.git/index.grep-worktree.repeated-new &&

		cp .git/index.repeated-old .git/index &&
		rm .git/index.grep-worktree &&
		cp .git/index.grep-worktree.repeated-old \
			.git/index.grep-worktree &&
		echo "dirty repeated negative" >target &&
		negative_hold="$PWD/.git/grep-worktree-repeated-hold" &&
		negative_ready="$PWD/.git/grep-worktree-repeated-ready" &&
		>"$negative_hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$negative_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$negative_ready" \
				GIT_TRACE2_EVENT="$PWD/repeated-negative.trace" \
				git grep "dirty repeated negative" -- target \
				>negative.out 2>negative.err &
		} &&
		negative_pid=$! &&
		trap "kill $negative_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$negative_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$negative_ready" &&
		cp .git/index.repeated-new .git/index &&
		rm .git/index.grep-worktree &&
		cp .git/index.grep-worktree.repeated-new \
			.git/index.grep-worktree &&
		cp .git/index.grep-worktree-generation \
			.git/index.grep-worktree-generation.before-repeated &&
		rm "$negative_hold" &&
		wait "$negative_pid" &&
		trap - 0 &&
		test_cmp .git/index.grep-worktree-generation.before-repeated \
			.git/index.grep-worktree-generation &&
		test_trace2_data grep worktree_blob/negative_noop 0 \
			<repeated-negative.trace &&

		GIT_TRACE2_EVENT="$PWD/repeated-result.trace" \
			git grep "dirty repeated negative" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<repeated-result.trace &&
		test_trace2_data grep worktree_blob/negative_noop 1 \
			<repeated-result.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree negatives invalidate unsafe generations' '
	test_when_finished "rm -rf grep-worktree-generation-race" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-generation-race &&
		cd grep-worktree-generation-race &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "generation target" >target &&
		test-tool chmtime =-5 target &&
		git add target &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep \
			"absent generation race" -- target &&

		echo "generation shift" >shift &&
		test-tool chmtime =-5 shift &&
		git add shift &&
		git status --porcelain >/dev/null &&
		echo "negative before generation change" >target &&
		git update-index --fsmonitor-valid target &&
		negative_hold="$PWD/.git/grep-worktree-generation-negative-hold" &&
		negative_ready="$PWD/.git/grep-worktree-generation-negative-ready" &&
		>"$negative_hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$negative_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$negative_ready" \
				git grep "absent generation race" -- target \
				>negative.out 2>negative.err &
		} &&
		negative_pid=$! &&
		trap "kill $negative_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$negative_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$negative_ready" &&

		generation=.git/index.grep-worktree-generation &&
		{
			test_copy_bytes 12 <"$generation" &&
			printf "replacement generation" |
				test-tool $(test_oid algo) -b
		} >"$generation.new-body" &&
		test-tool $(test_oid algo) -b \
			<"$generation.new-body" \
			>"$generation.new-checksum" &&
		cat "$generation.new-body" \
			"$generation.new-checksum" \
			>"$generation.new" &&
		rm "$generation.new-body" \
			"$generation.new-checksum" &&
		mv "$generation.new" "$generation" &&
		cp "$generation" "$generation.before-negative" &&

		echo "generation target" >target &&
		git update-index --fsmonitor-valid target &&
		positive_hold="$PWD/.git/grep-worktree-generation-positive-hold" &&
		positive_ready="$PWD/.git/grep-worktree-generation-positive-ready" &&
		>"$positive_hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$positive_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$positive_ready" \
				git grep "absent generation race" -- target \
				>positive.out 2>positive.err &
		} &&
		positive_pid=$! &&
		trap "kill $negative_pid $positive_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$positive_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$positive_ready" &&

		echo "changed after newer positive" >target &&
		git update-index --fsmonitor-valid target &&
		rm "$negative_hold" &&
		test_expect_code 1 wait "$negative_pid" &&
		trap "kill $positive_pid 2>/dev/null || :" 0 &&
		! test_cmp "$generation.before-negative" "$generation" &&
		rm "$positive_hold" &&
		test_expect_code 1 wait "$positive_pid" &&
		trap - 0 &&
		echo "target:changed after newer positive" >expected &&
		GIT_TRACE2_EVENT="$PWD/generation-result.trace" \
			git grep "changed after newer positive" -- \
				target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<generation-result.trace &&

		echo "generation target" >target &&
		git add target &&
		git status --porcelain >/dev/null &&
		rm -f .git/index.grep-worktree \
			.git/index.grep-worktree-recovery &&
		test_expect_code 1 git grep \
			"absent unmatched negative" -- target &&
		cp .git/index .git/index.with-target &&
		echo "unmatched shift" >unmatched-shift &&
		test-tool chmtime =-5 unmatched-shift &&
		git add unmatched-shift &&
		git status --porcelain >/dev/null &&
		echo "unmatched negative" >target &&
		git update-index --fsmonitor-valid target &&
		negative_hold="$PWD/.git/grep-worktree-unmatched-hold" &&
		negative_ready="$PWD/.git/grep-worktree-unmatched-ready" &&
		>"$negative_hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$negative_hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$negative_ready" \
				git grep "absent unmatched negative" -- target \
				>unmatched.out 2>unmatched.err &
		} &&
		negative_pid=$! &&
		trap "kill $negative_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$negative_ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$negative_ready" &&
		git rm --cached -f target &&
		cp "$generation" "$generation.before-unmatched" &&
		rm "$negative_hold" &&
		test_expect_code 1 wait "$negative_pid" &&
		trap - 0 &&
		! test_cmp "$generation.before-unmatched" "$generation" &&
		cp .git/index.with-target .git/index &&
		echo "target:unmatched negative" >expected &&
		GIT_TRACE2_EVENT="$PWD/unmatched-result.trace" \
			git grep "unmatched negative" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<unmatched-result.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree negative marks failed invalidation' '
	test_when_finished "rm -rf grep-worktree-invalidation-failure" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-invalidation-failure &&
		cd grep-worktree-invalidation-failure &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "invalidation target" >target &&
		echo "invalidation other" >other &&
		test-tool chmtime =-5 target other &&
		git add target other &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep \
			"absent invalidation failure" -- target &&

		echo "invalidation shift" >shift &&
		test-tool chmtime =-5 shift &&
		git add shift &&
		git status --porcelain >/dev/null &&
		echo "changed under invalidation failure" >target &&
		git update-index --fsmonitor-valid target &&
		lock=.git/index.grep-worktree.lock &&
		invalid_lock=.git/index.grep-worktree-invalid.lock &&
		>"$lock" &&
		>"$invalid_lock" &&
		env \
			GIT_TEST_GREP_WORKTREE_INVALIDATION_FAILURE=1 \
			GIT_TRACE2_EVENT="$PWD/negative.trace" \
			git grep "changed under invalidation failure" \
				-- target >actual 2>negative.err &&
		echo "target:changed under invalidation failure" >expected &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<negative.trace &&
		test_path_is_file .git/index.grep-worktree-invalid &&

		cp .git/index.grep-worktree \
			.git/index.grep-worktree.before-no-optional &&
		cp .git/index.grep-worktree-generation \
			.git/index.grep-worktree-generation.before-no-optional &&
		GIT_TRACE2_EVENT="$PWD/no-optional.trace" \
			git --no-optional-locks grep \
				"changed under invalidation failure" \
				-- target >actual &&
		test_cmp expected actual &&
		test_cmp .git/index.grep-worktree.before-no-optional \
			.git/index.grep-worktree &&
		test_cmp .git/index.grep-worktree-generation.before-no-optional \
			.git/index.grep-worktree-generation &&
		test_path_is_file .git/index.grep-worktree-invalid &&
		! test_grep "worktree_blob/hits" no-optional.trace &&

		rm "$lock" &&
		cp .git/index.grep-worktree-generation \
			.git/index.grep-worktree-generation.before-repair &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/repair.trace" \
			git grep "absent invalidation repair" -- other &&
		! test_cmp .git/index.grep-worktree-generation.before-repair \
			.git/index.grep-worktree-generation &&
		test_trace2_data grep worktree_blob/hits 0 <repair.trace &&
		test_path_is_missing .git/index.grep-worktree-invalid &&

		GIT_TRACE2_EVENT="$PWD/result.trace" \
			git grep "changed under invalidation failure" \
				-- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 <result.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX,SYMLINKS \
	'worktree invalidation recognizes dangling symlink' '
	test_when_finished "rm -rf grep-worktree-invalidation-symlink" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-invalidation-symlink &&
		cd grep-worktree-invalidation-symlink &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "symlink invalidation target" >target &&
		test-tool chmtime =-5 target &&
		git add target &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep \
			"absent symlink invalidation" -- target &&

		echo "symlink invalidation shift" >shift &&
		test-tool chmtime =-5 shift &&
		git add shift &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep \
			"absent symlink invalidation" -- target &&

		echo "dirty under symlink invalidation" >target &&
		git update-index --fsmonitor-valid target &&
		ln -s missing .git/index.grep-worktree-invalid &&
		echo "target:dirty under symlink invalidation" >expected &&
		GIT_TRACE2_EVENT="$PWD/symlink.trace" \
			git --no-optional-locks grep \
				"dirty under symlink invalidation" \
				-- target >actual &&
		test_cmp expected actual &&
		test -L .git/index.grep-worktree-invalid &&
		! test_grep "worktree_blob/hits" symlink.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree negative clears new split base' '
	test_when_finished "rm -rf grep-worktree-split-negative" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-split-negative &&
		cd grep-worktree-split-negative &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "split transition target" >target &&
		test-tool chmtime =-5 target &&
		git add target &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git config splitIndex.maxPercentChange 100 &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep \
			"absent split transition" -- target &&
		cp .git/index.grep-worktree \
			.git/index.grep-worktree.nonsplit &&
		rm .git/index.grep-worktree &&

		echo "changed across split transition" >target &&
		git update-index --fsmonitor-valid target &&
		hold="$PWD/.git/grep-worktree-split-negative-hold" &&
		ready="$PWD/.git/grep-worktree-split-negative-ready" &&
		>"$hold" &&
		{
			env \
				GIT_TEST_GREP_WORKTREE_WRITE_HOLD="$hold" \
				GIT_TEST_GREP_WORKTREE_WRITE_PHASE=prelock \
				GIT_TEST_GREP_WORKTREE_WRITE_READY="$ready" \
				GIT_TRACE2_EVENT="$PWD/negative.trace" \
				git grep "absent split transition" -- target \
				>negative.out 2>negative.err &
		} &&
		negative_pid=$! &&
		trap "kill $negative_pid 2>/dev/null || :" 0 &&
		attempts=0 &&
		while test ! -f "$ready" &&
		      test "$attempts" -lt 30
		do
			sleep 1 &&
			attempts=$(($attempts + 1)) ||
			exit 1
		done &&
		test_path_is_file "$ready" &&

		mv .git/index.grep-worktree.nonsplit \
			.git/index.grep-worktree &&
		echo "split transition target" >target &&
		git update-index --split-index &&
		git update-index --fsmonitor-valid target &&
		test_path_is_file "$(git rev-parse --shared-index-path)" &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/populate-split.trace" \
			git grep "absent split transition" -- target &&
		test_trace2_data grep worktree_blob/hits 1 \
			<populate-split.trace &&

		echo "changed across split transition" >target &&
		git update-index --fsmonitor-valid target &&
		rm "$hold" &&
		test_expect_code 1 wait "$negative_pid" &&
		trap - 0 &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<negative.trace &&
		echo "target:changed across split transition" >expected &&
		GIT_TRACE2_EVENT="$PWD/post-negative.trace" \
			git grep "changed across split transition" -- \
				target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<post-negative.trace &&
		test_trace2_data grep worktree_blob/recovered_split_base 0 \
			<post-negative.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree direct negative clears split base' '
	test_when_finished "rm -rf grep-worktree-split-direct-negative" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-split-direct-negative &&
		cd grep-worktree-split-direct-negative &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "direct split target" >target &&
		echo "direct split other" >other &&
		test-tool chmtime =-5 target other &&
		git add target other &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git config splitIndex.maxPercentChange 100 &&
		git update-index --fsmonitor &&
		git update-index --split-index &&
		git status --porcelain >/dev/null &&
		test_path_is_file "$(git rev-parse --shared-index-path)" &&
		test_expect_code 1 git grep \
			"absent direct split" -- target &&
		cp .git/index .git/index.inherited &&

		oid=$(git rev-parse :target) &&
		git update-index --cacheinfo 100644 "$oid" target &&
		git update-index --fsmonitor-valid target other &&
		test_expect_code 1 git grep \
			"absent direct split" -- other &&

		echo "dirty direct split" >target &&
		git update-index --fsmonitor-valid target &&
		echo "target:dirty direct split" >expected &&
		GIT_TRACE2_EVENT="$PWD/direct.trace" \
			git grep "dirty direct split" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/direct_write 1 \
			<direct.trace &&

		cp .git/index.inherited .git/index &&
		GIT_TRACE2_EVENT="$PWD/result.trace" \
			git grep "dirty direct split" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<result.trace &&
		test_trace2_data grep worktree_blob/recovered_split_base 0 \
			<result.trace
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree cache accepts empty split-index base' '
	test_when_finished "rm -rf grep-worktree-empty-split" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-empty-split &&
		cd grep-worktree-empty-split &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		git config splitIndex.maxPercentChange 100 &&
		git update-index --split-index &&
		test_path_is_file "$(git rev-parse --shared-index-path)" &&
		echo "empty split overlay" >overlay &&
		test-tool chmtime =-5 overlay &&
		git add overlay &&
		test_hook --setup fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep "absent empty split" -- overlay &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-empty-split" \
			git grep "absent empty split" -- overlay &&
		test_trace2_data grep worktree_blob/hits 1 \
			<trace-empty-split
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree cache follows split-index base' '
	test_when_finished "rm -rf grep-worktree-split" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-split &&
		cd grep-worktree-split &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "split base target" >target &&
		echo "split base other" >other &&
		echo "split base cycle" >cycle &&
		{
			echo "cycle text" &&
			echo "target text"
		} >.gitattributes &&
		test-tool chmtime =-5 .gitattributes cycle target other &&
		git add .gitattributes cycle target other &&
		cycle_oid=$(git rev-parse :cycle) &&
		target_oid=$(git rev-parse :target) &&
		git config splitIndex.maxPercentChange 100 &&
		git update-index --split-index &&
		base=$(git rev-parse --shared-index-path) &&
		test_path_is_file "$base" &&
		test_hook --setup --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			if test -f .git/fsmonitor-target
			then
				printf "target\0"
			fi
			if test -f .git/fsmonitor-cycle
			then
				printf "cycle\0"
			fi
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-initial" \
			git grep "absent split base" -- cycle target other &&
		test_trace2_data grep worktree_blob/recorded_equal 3 \
			<trace-initial &&

		mkdir other-worktree &&
		echo "split scope worktree" >other-worktree/target &&
		echo "target:split scope worktree" >expected &&
		GIT_TRACE2_EVENT="$PWD/trace-other-worktree" \
			git --no-optional-locks \
				--work-tree="$PWD/other-worktree" \
				grep "split scope worktree" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<trace-other-worktree &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 0 \
			<trace-other-worktree &&

		echo "split overlay addition" >added &&
		test-tool chmtime =-5 added &&
		git add added &&
		git status --porcelain >/dev/null &&
		current_base=$(git rev-parse --shared-index-path) &&
		test "$base" = "$current_base" &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-recovered" \
			git grep "absent split base" -- target &&
		test_trace2_data grep worktree_blob/hits 1 \
			<trace-recovered &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 1 \
			<trace-recovered &&
		test_trace2_data grep worktree_blob/recorded_equal 0 \
			<trace-recovered &&

		git rm --cached cycle &&
		>.git/fsmonitor-cycle &&
		printf "split base cycle\r\n" >cycle &&
		test-tool chmtime =-5 cycle &&
		git add cycle &&
		rm .git/fsmonitor-cycle &&
		git status --porcelain >/dev/null &&
		current_cycle_oid=$(git rev-parse :cycle) &&
		test "$cycle_oid" = "$current_cycle_oid" &&
		pattern=$(printf "cycle\r") &&
		printf "cycle:split base cycle\r\n" >expected &&
		GIT_TRACE2_EVENT="$PWD/trace-readded" \
			git grep "$pattern" -- cycle >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<trace-readded &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 0 \
			<trace-readded &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<trace-readded &&

		>.git/fsmonitor-target &&
		printf "split base target\r\n" >target &&
		test-tool chmtime =-5 target &&
		git add target &&
		rm .git/fsmonitor-target &&
		git status --porcelain >/dev/null &&
		current_target_oid=$(git rev-parse :target) &&
		test "$target_oid" = "$current_target_oid" &&
		current_base=$(git rev-parse --shared-index-path) &&
		test "$base" = "$current_base" &&
		pattern=$(printf "target\r") &&
		printf "target:split base target\r\n" >expected &&
		GIT_TRACE2_EVENT="$PWD/trace-replacement" \
			git grep "$pattern" -- target >actual &&
		test_cmp expected actual &&
		test_trace2_data grep worktree_blob/hits 0 \
			<trace-replacement &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 0 \
			<trace-replacement &&
		test_trace2_data grep worktree_blob/recorded_different 1 \
			<trace-replacement &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-added" \
			git grep "absent split base" -- added &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<trace-added &&

		git config splitIndex.maxPercentChange 0 &&
		git update-index --force-write-index &&
		current_base=$(git rev-parse --shared-index-path) &&
		test "$base" != "$current_base" &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-new-base-exact" \
			git grep "absent split base" -- added &&
		test_trace2_data grep worktree_blob/hits 1 \
			<trace-new-base-exact &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 0 \
			<trace-new-base-exact &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-new-base" \
			git grep "absent split base" -- other &&
		test_trace2_data grep worktree_blob/hits 0 \
			<trace-new-base &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 0 \
			<trace-new-base &&
		test_trace2_data grep worktree_blob/recorded_equal 1 \
			<trace-new-base
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree cache merges across split overlay race' '
	test_when_finished "rm -rf grep-worktree-split-race" &&
	(
		sane_unset GIT_TEST_SPLIT_INDEX &&
		git init grep-worktree-split-race &&
		cd grep-worktree-split-race &&
		GIT_TEST_GREP_LITERAL_PATHS=0 &&
		export GIT_TEST_GREP_LITERAL_PATHS &&
		echo "split race cached" >cached &&
		echo "split race pending" >pending &&
		test-tool chmtime =-5 cached pending &&
		git add cached pending &&
		git config splitIndex.maxPercentChange 100 &&
		git update-index --split-index &&
		base=$(git rev-parse --shared-index-path) &&
		test_hook --setup --clobber fsmonitor-test <<-\EOF &&
			printf "last_update_token\0"
			if test -f .git/fsmonitor-replace-index
			then
				mv .git/index.replace .git/index
				rm .git/fsmonitor-replace-index
				git grep "absent split race" -- added \
					>/dev/null 2>&1
				test $? = 1 || exit 1
			fi
		EOF
		fsmonitor_hook="\"$PWD/.git/hooks/fsmonitor-test\"" &&
		git config core.fsmonitor "$fsmonitor_hook" &&
		git config grep.worktreeBlobCache true &&
		git update-index --fsmonitor &&
		git status --porcelain >/dev/null &&
		test_expect_code 1 git grep "absent split race" -- cached &&
		cp .git/index .git/index.original &&

		echo "split race added" >added &&
		test-tool chmtime =-5 added &&
		git add added &&
		git status --porcelain >/dev/null &&
		current_base=$(git rev-parse --shared-index-path) &&
		test "$base" = "$current_base" &&
		cp .git/index .git/index.replace &&
		mv .git/index.original .git/index &&
		>.git/fsmonitor-replace-index &&

		test_expect_code 1 git grep "absent split race" -- pending &&
		test_path_is_missing .git/fsmonitor-replace-index &&
		added_oid=$(git rev-parse :added) &&
		worktree_oid=$(git hash-object added) &&
		test "$added_oid" = "$worktree_oid" &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-race-base" \
			git grep "absent split race" -- pending &&
		test_trace2_data grep worktree_blob/hits 1 \
			<trace-race-base &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 1 \
			<trace-race-base &&
		test_expect_code 1 env \
			GIT_TRACE2_EVENT="$PWD/trace-race-exact" \
			git grep "absent split race" -- added &&
		test_trace2_data grep worktree_blob/hits 1 \
			<trace-race-exact &&
		test_trace2_data grep \
			worktree_blob/recovered_split_base 0 \
			<trace-race-exact
	)
'

test_expect_success NO_FORCED_SPLIT_INDEX \
	'worktree cache follows sparse-index identity' '
	GIT_TEST_GREP_LITERAL_PATHS=0 &&
	export GIT_TEST_GREP_LITERAL_PATHS &&
	test_when_finished "unset GIT_TEST_GREP_LITERAL_PATHS" &&
	test_when_finished "rm -rf grep-worktree-sparse \
		grep-worktree-trace-sparse-*" &&
	git init grep-worktree-sparse &&
	mkdir -p grep-worktree-sparse/inside \
		grep-worktree-sparse/outside \
		grep-worktree-sparse/.git/hooks &&
	echo "inside sparse index" >grep-worktree-sparse/inside/file &&
	echo "outside sparse index" >grep-worktree-sparse/outside/file &&
	test-tool chmtime =-5 grep-worktree-sparse/inside/file \
		grep-worktree-sparse/outside/file &&
	git -C grep-worktree-sparse add . &&
	git -C grep-worktree-sparse commit -m initial &&
	test_hook -C grep-worktree-sparse --setup --clobber \
		fsmonitor-test <<-\EOF &&
		printf "last_update_token\0"
		if test -f .git/fsmonitor-inside
		then
			printf "inside/file\0"
		fi
	EOF
	git -C grep-worktree-sparse config \
		core.fsmonitor .git/hooks/fsmonitor-test &&
	git -C grep-worktree-sparse config grep.worktreeBlobCache true &&
	git -C grep-worktree-sparse sparse-checkout init \
		--cone --sparse-index &&
	git -C grep-worktree-sparse sparse-checkout set inside &&
	test-tool chmtime =-5 grep-worktree-sparse/inside/file &&
	>grep-worktree-sparse/.git/fsmonitor-inside &&
	git -C grep-worktree-sparse status --porcelain >/dev/null &&
	rm grep-worktree-sparse/.git/fsmonitor-inside &&
	git -C grep-worktree-sparse update-index \
		--fsmonitor-valid inside/file &&
	test_expect_code 1 git -C grep-worktree-sparse grep \
		"absent sparse index" -- inside/file &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-sparse-hit" \
		git -C grep-worktree-sparse grep \
		"absent sparse index" -- inside/file &&
	test_trace2_data grep worktree_blob/hits 1 \
		<grep-worktree-trace-sparse-hit &&
	git -C grep-worktree-sparse sparse-checkout reapply \
		--no-sparse-index &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-sparse-full" \
		git -C grep-worktree-sparse grep \
		"absent sparse index" -- inside/file &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-sparse-full &&
	git -C grep-worktree-sparse sparse-checkout reapply \
		--sparse-index &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-sparse-collapsed" \
		git -C grep-worktree-sparse grep \
		"absent sparse index" -- inside/file &&
	test_trace2_data grep worktree_blob/hits 0 \
		<grep-worktree-trace-sparse-collapsed &&
	unset GIT_TEST_GREP_LITERAL_PATHS &&
	test_expect_code 1 env \
		GIT_TRACE2_EVENT="$PWD/grep-worktree-trace-sparse-outside" \
		git -C grep-worktree-sparse grep \
		"outside sparse index" -- outside/file &&
	test_grep ! "literal_path_candidates" \
		grep-worktree-trace-sparse-outside
'

test_expect_success 'grep can find things only in the work tree (i-t-a)' '
	echo "intend to add this" >intend-to-add &&
	git add -N intend-to-add &&
	test_when_finished "git rm -f intend-to-add" &&
	git grep --quiet "intend to add this" &&
	test_must_fail git grep --quiet --cached "intend to add this" &&
	test_must_fail git grep --quiet "intend to add this" HEAD
'

test_expect_success 'grep does not search work tree with assume unchanged' '
	echo "intend to add this" >intend-to-add &&
	git add -N intend-to-add &&
	git update-index --assume-unchanged intend-to-add &&
	test_when_finished "git rm -f intend-to-add" &&
	test_must_fail git grep --quiet "intend to add this" &&
	test_must_fail git grep --quiet --cached "intend to add this" &&
	test_must_fail git grep --quiet "intend to add this" HEAD
'

test_expect_success 'grep can find things only in the index' '
	echo "only in the index" >cache-this &&
	git add cache-this &&
	rm cache-this &&
	test_when_finished "git rm --cached cache-this" &&
	test_must_fail git grep --quiet "only in the index" &&
	git grep --quiet --cached "only in the index" &&
	test_must_fail git grep --quiet "only in the index" HEAD
'

test_expect_success 'grep does not report i-t-a with -L --cached' '
	echo "intend to add this" >intend-to-add &&
	git add -N intend-to-add &&
	test_when_finished "git rm -f intend-to-add" &&
	git ls-files | grep -v "^intend-to-add\$" >expected &&
	git grep -L --cached "nonexistent_string" >actual &&
	test_cmp expected actual
'

test_expect_success 'grep does not report i-t-a and assume unchanged with -L' '
	echo "intend to add this" >intend-to-add-assume-unchanged &&
	git add -N intend-to-add-assume-unchanged &&
	test_when_finished "git rm -f intend-to-add-assume-unchanged" &&
	git update-index --assume-unchanged intend-to-add-assume-unchanged &&
	git ls-files | grep -v "^intend-to-add-assume-unchanged\$" >expected &&
	git grep -L "nonexistent_string" >actual &&
	test_cmp expected actual
'

test_expect_success 'grep of revision in partial clone batches prefetch and honors pathspec' '
	test_when_finished "rm -rf grep-partial-src grep-partial" &&

	git init grep-partial-src &&
	(
		cd grep-partial-src &&
		git config uploadpack.allowfilter 1 &&
		git config uploadpack.allowanysha1inwant 1 &&
		mkdir a b &&
		echo "needle in haystack" >a/matches.txt &&
		echo "nothing to see here" >a/nomatch.txt &&
		echo "needle again" >b/matches.md &&
		git add . &&
		git commit -m "initial"
	) &&

	git clone --no-checkout --filter=blob:none \
		"file://$(pwd)/grep-partial-src" grep-partial &&

	# All three blobs are missing immediately after a blobless clone.
	git -C grep-partial rev-list --quiet --objects \
		--missing=print HEAD >missing &&
	test_line_count = 3 missing &&

	# A pathspec-limited grep should prefetch only the two blobs
	# in a/.  It should fetch both blobs in one batched request.
	GIT_TRACE2_EVENT="$(pwd)/grep-trace-pathspec" \
		git -C grep-partial grep -c "needle" HEAD -- "a/*.txt" >result &&

	# Only a/matches.txt contains "needle" among the matched paths.
	test_line_count = 1 result &&

	# Exactly the two a/*.txt blobs should have been requested, and
	# the server packed those two objects in the response.
	test_trace2_data promisor fetch_count 2 <grep-trace-pathspec &&
	test_trace2_data pack-objects written 2 <grep-trace-pathspec &&

	# b/matches.md should still be missing locally.
	git -C grep-partial rev-list --quiet --objects \
		--missing=print HEAD >missing &&
	test_line_count = 1 missing &&

	# A second grep without a pathspec must recurse into both
	# subdirectories, but should request only the still-missing blob
	# from the promisor.
	GIT_TRACE2_EVENT="$(pwd)/grep-trace-all" \
		git -C grep-partial grep -c "needle" HEAD >result &&

	test_line_count = 2 result &&
	test_trace2_data promisor fetch_count 1 <grep-trace-all &&
	test_trace2_data pack-objects written 1 <grep-trace-all &&

	# Everything is local now.
	git -C grep-partial rev-list --quiet --objects \
		--missing=print HEAD >missing &&
	test_line_count = 0 missing
'

test_done

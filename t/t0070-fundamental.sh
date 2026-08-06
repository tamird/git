#!/bin/sh

test_description='check that the most basic functions work


Verify wrappers and compatibility functions.
'

. ./test-lib.sh

test_expect_success 'cgroup CPU quotas cap and round available workers' '
	test 29 = "$(test-tool online-cpus --quota 64 "2900000 100000")" &&
	test 2 = "$(test-tool online-cpus --quota 64 "150000 100000")" &&
	test 1 = "$(test-tool online-cpus --quota 64 "1 100000")" &&
	test 64 = "$(test-tool online-cpus --quota 64 "12800000 100000")"
'

test_expect_success 'unlimited and whitespace-delimited CPU quotas' '
	whitespace=$(printf "\t 2900000\t100000 \t") &&
	test 29 = "$(test-tool online-cpus --quota 64 "$whitespace")" &&
	test 64 = "$(test-tool online-cpus --quota 64 "max 100000")"
'

test_expect_success 'malformed CPU quotas leave available workers unchanged' '
	for quota in \
		"" \
		"2900000" \
		"0 100000" \
		"2900000 0" \
		"-1 100000" \
		"2900000 -1" \
		"2900000 100000 extra" \
		"18446744073709551616 100000" \
		"2900000 18446744073709551616"
	do
		test 64 = "$(test-tool online-cpus --quota 64 "$quota")" ||
			return 1
	done
'

test_expect_success 'mktemp to nonexistent directory prints filename' '
	test_must_fail test-tool mktemp doesnotexist/testXXXXXX 2>err &&
	test_grep "doesnotexist/test" err
'

test_expect_success POSIXPERM,SANITY 'mktemp to unwritable directory prints filename' '
	mkdir cannotwrite &&
	test_when_finished "chmod +w cannotwrite" &&
	chmod -w cannotwrite &&
	test_must_fail test-tool mktemp cannotwrite/testXXXXXX 2>err &&
	test_grep "cannotwrite/test" err
'

test_expect_success 'git_mkstemps_mode does not fail if fd 0 is not open' '
	git commit --allow-empty -m message <&-
'

test_expect_success 'check for a bug in the regex routines' '
	# if this test fails, re-build git with NO_REGEX=1
	test-tool regex --bug
'

test_expect_success 'incomplete sideband messages are reassembled' '
	test-tool pkt-line send-split-sideband >split-sideband &&
	test-tool pkt-line receive-sideband <split-sideband 2>err &&
	test_grep "Hello, world" err
'

test_expect_success 'eof on sideband message is reported' '
	printf 1234 >input &&
	test-tool pkt-line receive-sideband <input 2>err &&
	test_grep "unexpected disconnect" err
'

test_expect_success 'missing sideband designator is reported' '
	printf 0004 >input &&
	test-tool pkt-line receive-sideband <input 2>err &&
	test_grep "missing sideband" err
'

test_expect_success 'unpack-sideband: --no-chomp-newline' '
	test_when_finished "rm -f expect-out expect-err" &&
	test-tool pkt-line send-split-sideband >split-sideband &&
	test-tool pkt-line unpack-sideband \
		--no-chomp-newline <split-sideband >out 2>err &&
	cat >expect-out <<-EOF &&
		primary: regular output
	EOF
	cat >expect-err <<-EOF &&
		Foo.
		Bar.
		Hello, world!
	EOF
	test_cmp expect-out out &&
	test_cmp expect-err err
'

test_expect_success 'unpack-sideband: --chomp-newline (default)' '
	test_when_finished "rm -f expect-out expect-err" &&
	test-tool pkt-line send-split-sideband >split-sideband &&
	test-tool pkt-line unpack-sideband \
		--chomp-newline <split-sideband >out 2>err &&
	printf "primary: regular output" >expect-out &&
	printf "Foo.Bar.Hello, world!" >expect-err &&
	test_cmp expect-out out &&
	test_cmp expect-err err
'

test_expect_success 'unpack-sideband: packet_reader_read() consumes sideband, no chomp payload' '
	test_when_finished "rm -f expect-out expect-err" &&
	test-tool pkt-line send-split-sideband >split-sideband &&
	test-tool pkt-line unpack-sideband \
		--reader-use-sideband \
		--no-chomp-newline <split-sideband >out 2>err &&
	cat >expect-out <<-EOF &&
		primary: regular output
	EOF
	printf "remote: Foo.        \n"           >expect-err &&
	printf "remote: Bar.        \n"          >>expect-err &&
	printf "remote: Hello, world!        \n" >>expect-err &&
	test_cmp expect-out out &&
	test_cmp expect-err err
'

test_expect_success 'unpack-sideband: packet_reader_read() consumes sideband, chomp payload' '
	test_when_finished "rm -f expect-out expect-err" &&
	test-tool pkt-line send-split-sideband >split-sideband &&
	test-tool pkt-line unpack-sideband \
		--reader-use-sideband \
		--chomp-newline <split-sideband >out 2>err &&
	printf "primary: regular output" >expect-out &&
	printf "remote: Foo.        \n"           >expect-err &&
	printf "remote: Bar.        \n"          >>expect-err &&
	printf "remote: Hello, world!        \n" >>expect-err &&
	test_cmp expect-out out &&
	test_cmp expect-err err
'

test_done

#!/bin/sh

test_description='shared grep content index performance'

. ./perf-lib.sh

test_perf_default_repo

test_expect_success 'setup content index workloads' '
	printf "narrow grep index content\n" >perf-narrow &&
	"$MODERN_GIT" add perf-narrow &&
	"$MODERN_GIT" grep-index --no-progress &&
	index_dir=$("$MODERN_GIT" rev-parse \
		--git-path objects/info/grep-index) &&
	test_export index_dir &&

	"$MODERN_GIT" init --quiet all-matching &&
	test_seq 1 1024 |
	awk "
		BEGIN {
			print \"commit refs/heads/main\"
			print \"committer Performance Test <test@example.com> 1234567890 +0000\"
			print \"data 4\"
			print \"base\"
		}
		{
			content = \"common grep index content \" \$1
			print \"M 100644 inline files/\" \$1
			print \"data \" length(content)
			print content
		}
	" | "$MODERN_GIT" -C all-matching fast-import --quiet &&
	"$MODERN_GIT" -C all-matching read-tree refs/heads/main &&
	"$MODERN_GIT" -C all-matching grep-index --no-progress
'

test_perf 'rebuild content index' \
	--setup 'rm -rf "$index_dir"' '
	git grep-index --no-progress
'

test_size 'content index size in bytes' '
	wc -c "$index_dir"/* |
	awk "END { print \$1 }"
'

test_perf 'missing fixed string without content index' '
	git grep --cached --fixed-strings \
		--no-content-index \
		"definitely absent grep index performance pattern" >/dev/null || :
'

test_perf 'missing fixed string with content index' '
	git grep --cached --fixed-strings \
		--content-index \
		"definitely absent grep index performance pattern" >/dev/null || :
'

test_perf 'narrow fixed string without content index' '
	git grep --cached --fixed-strings --no-content-index \
		"narrow grep index content" -- perf-narrow >/dev/null
'

test_perf 'narrow fixed string with content index' '
	git grep --cached --fixed-strings --content-index \
		"narrow grep index content" -- perf-narrow >/dev/null
'

test_perf 'all-matching fixed string without content index' '
	git -C all-matching grep --cached --fixed-strings \
		--no-content-index "common grep index content" >/dev/null
'

test_perf 'all-matching fixed string with content index' '
	git -C all-matching grep --cached --fixed-strings \
		--content-index "common grep index content" >/dev/null
'

test_done

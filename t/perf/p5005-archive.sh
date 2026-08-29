#!/bin/sh

test_description='archive selection and attribute lookup scaling'

. ./perf-lib.sh

test_perf_default_repo "$TRASH_DIRECTORY/real"
test_perf_fresh_repo source

test_perf 'full archive of the test repository' '
	git -C real archive HEAD >/dev/null
'

# Shared blobs and subtrees isolate traversal cost from object volume.
test_expect_success 'create wide and flat archive trees' '
	blob=$(echo content | git -C source hash-object -w --stdin) &&
	subtree=$(printf "100644 blob %s\tfile\n" "$blob" | git -C source mktree) &&
	for count in 1000 4000
	do
		test_seq -f "040000 tree $subtree\tdir%04g" 1 "$count" >entries &&
		tree=$(git -C source mktree <entries) &&
		commit=$(echo wide | git -C source commit-tree "$tree") &&
		git -C source update-ref "refs/heads/wide$count" "$commit" &&
		printf "160000 commit %s\tzmodule\n" "$commit" >>entries &&
		tree=$(git -C source mktree <entries) &&
		commit=$(echo late-gitlink | git -C source commit-tree "$tree") &&
		git -C source update-ref "refs/heads/mode$count" "$commit" || return 1
	done &&
	test_seq -f "100644 blob $blob\tfile%04g" 1 4000 >entries &&
	tree=$(git -C source mktree <entries) &&
	commit=$(echo flat | git -C source commit-tree "$tree") &&
	git -C source update-ref refs/heads/flat4000 "$commit" &&
	git -C source symbolic-ref HEAD refs/heads/wide4000 &&
	git -C source config uploadpack.allowfilter true &&
	git -C source config uploadpack.allowanysha1inwant true
'

# Unrelated sibling directories each contain one deterministic binary blob.
create_archive_tree () {
	"$PERL_PATH" -e '
		binmode STDOUT or die "binmode: $!";
		my ($branch, $count, $size, $selected) = @ARGV;
		print "commit refs/heads/$branch\n",
		      "committer A U Thor <author\@example.com> 1234567890 +0000\n",
		      "data 9\npayloads\n\n";
		my $attributes = ".gitattributes export-ignore\n";
		print "M 100644 inline .gitattributes\ndata ",
		      length($attributes), "\n", $attributes, "\n";
		my $seed = 1;
		for my $i (1..($selected + $count)) {
			my ($path, $length) = $i <= $selected
				? (sprintf("selected/file%04d", $i), 1024)
				: (sprintf("dir%04d/file", $i - $selected), $size);
			my $data = pack("N*", map {
				$seed = (1664525 * $seed + 1013904223) & 0xffffffff;
			} 1..($length / 4));
			printf "M 100644 inline %s\ndata %d\n%s\n",
			       $path, length($data), $data;
		}
		print "\n";
	' "$@" >import &&
	git -C source fast-import --quiet <import
}

test_expect_success 'create distinct partial-clone payloads' '
	create_archive_tree blobs 4000 1024 0
'

prepare_partial_clone () {
	rm -rf client &&
	git clone --bare --single-branch --branch "${1:-blobs}" \
		--filter=blob:none "file://$PWD/source" client
}

test_perf 'full archive, 1000 directories' '
	git -C source archive wide1000 >/dev/null
'

test_perf 'full archive, 4000 directories' '
	git -C source archive wide4000 >/dev/null
'

test_perf 'narrow archive, 4000 directories' '
	git -C source archive wide4000 dir0001 >/dev/null
'

test_perf 'builtin mode pathspec, 4000 files' '
	git -C source archive flat4000 ":(attr:builtin_objectmode=100644)" >/dev/null
'

test_perf 'late builtin mode match, 1000 directories' '
	git -C source archive mode1000 ":(attr:builtin_objectmode=160000)" >/dev/null
'

test_perf 'late builtin mode match, 4000 directories' '
	git -C source archive mode4000 ":(attr:builtin_objectmode=160000)" >/dev/null
'

test_perf 'partial narrow archive, 4000 distinct blobs' --setup '
	prepare_partial_clone
' '
	git -C client archive blobs dir0001 >/dev/null
'

test_perf 'partial full archive, 4000 distinct blobs' --setup '
	prepare_partial_clone
' '
	git -C client archive blobs >/dev/null
'

# Logical bytes of fetched blobs, excluding pack compression and protocol data.
for selection in narrow full
do
	test_size "partial $selection archive fetched blob bytes" '
		prepare_partial_clone &&
		case $selection in
		narrow) git -C client archive blobs dir0001 >/dev/null ;;
		full) git -C client archive blobs >/dev/null ;;
		esac &&
		git -C client cat-file --batch-all-objects \
			--batch-check="%(objecttype) %(objectsize)" >objects &&
		awk '\''$1 == "blob" { size += $2 } END { print size }'\'' objects
	'
done

# Model a partial clone whose selected payloads were read or prefetched earlier.
# Each bare clone starts with all trees but no blobs; prefetch the same 22
# payloads before timing archive, leaving unrelated blobs missing. The only
# attribute blob is the root .gitattributes. OS and server caches are not reset.
prepare_prefetched_clone () {
	prepare_partial_clone "$archive_ref" &&
	cp selected.oids prefetch.oids &&
	if test "$archive_attributes" = present
	then
		cat attribute.oid >>prefetch.oids
	fi &&
	git -C client fetch --no-tags --no-write-fetch-head \
		--no-auto-maintenance --stdin origin <prefetch.oids
}

# Count only blobs added by archive, not those fetched during preparation.
# Sizes are logical blob bytes, not compressed pack or protocol bytes.
measure_prefetched_blobs () {
	prepare_prefetched_clone &&
	git -C client cat-file --batch-all-objects \
		--batch-check="%(objecttype) %(objectsize)" >objects.before &&
	git -C client archive "$archive_commit" selected >/dev/null &&
	git -C client cat-file --batch-all-objects \
		--batch-check="%(objecttype) %(objectsize)" >objects.after &&
	awk -v metric="$1" '
		$1 == "blob" {
			sign = FNR == NR ? -1 : 1;
			count += sign;
			bytes += sign * $2;
		}
		END { print (metric == "count" ? count : bytes) + 0 }
	' objects.before objects.after
}

# Keep the selected subtree fixed while varying unrelated entries and bytes.
# GIT_PERF_EXTRA enables the two larger fixtures.
for archive_scale in 4000x1024 40000x1024 4000x16384
do
	case $archive_scale in
	4000x1024) archive_prereq= ;;
	*) archive_prereq=PERF_EXTRA ;;
	esac

	test_expect_success "$archive_prereq" \
		"create prefetch fixture, $archive_scale unrelated bytes" '
		archive_count=${archive_scale%x*} &&
		archive_blob_size=${archive_scale#*x} &&
		archive_ref=prefetch-$archive_scale &&
		create_archive_tree "$archive_ref" "$archive_count" \
			"$archive_blob_size" 22 &&
		archive_commit=$(git -C source rev-parse "$archive_ref") &&
		git -C source ls-tree -r --format="%(objectname)" \
			"$archive_commit" selected >selected.oids &&
		git -C source rev-parse "$archive_commit:.gitattributes" \
			>attribute.oid &&
		test_export archive_commit
	'

	for archive_attributes in missing present
	do
		test_perf "prefetched 22, $archive_scale B unrelated, attrs $archive_attributes" \
			--prereq "$archive_prereq" --setup '
			prepare_prefetched_clone
		' '
			git -C client archive "$archive_commit" selected >/dev/null
		'

		for archive_metric in count bytes
		do
			test_size "prefetched 22, $archive_scale B unrelated, attrs $archive_attributes, new blob $archive_metric" \
				--prereq "$archive_prereq" '
				measure_prefetched_blobs "$archive_metric"
			'
		done
	done
done

test_done

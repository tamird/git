#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "config.h"
#include "environment.h"
#include "grep-index-identity.h"
#include "name-hash.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"

int cmd__read_cache(int argc, const char **argv)
{
	int i, cnt = 1;
	const char *name = NULL;
	const char *probe_name = NULL;
	const char *replace_old = NULL;
	const char *replace_new = NULL;

	if (argc > 1 &&
	    skip_prefix(argv[1], "--identity-replace=", &replace_old)) {
		if (argc != 3)
			die("expected replacement file after --identity-replace");
		replace_new = argv[2];
	} else if (argc > 1 &&
		   skip_prefix(argv[1], "--icase-probe=", &probe_name)) {
		argc--;
		argv++;
	} else if (argc > 1 &&
		   skip_prefix(argv[1], "--print-and-refresh=", &name)) {
		argc--;
		argv++;
	}

	if (argc == 2)
		cnt = strtol(argv[1], NULL, 0);
	setup_git_directory(the_repository);
	repo_config(the_repository, git_default_config, NULL);

	if (replace_old) {
		struct grep_index_identity before, after;
		struct index_state *istate = the_repository->index;
		size_t old_nr;
		int pos;

		setup_work_tree(the_repository);
		repo_read_index(the_repository);
		old_nr = istate->cache_nr;
		if (grep_index_identity_get(the_repository, istate, &before))
			die("unable to identify loaded index");
		pos = index_name_pos(istate, replace_old, strlen(replace_old));
		if (pos < 0)
			die("index entry to replace does not exist");
		remove_index_entry_at(istate, pos);
		if (add_file_to_index(istate, replace_new, 0) ||
		    istate->cache_nr != old_nr)
			die("unable to replace entry in loaded index");
		if (grep_index_identity_get(the_repository, istate, &after) ||
		    oideq(&before.oid_sequence, &after.oid_sequence) ||
		    oideq(&before.worktree, &after.worktree))
			die("in-memory index mutation reused stale identity");
		return 0;
	}

	if (probe_name) {
		enum index_file_icase_probe_result result;
		size_t scans = 0;

		repo_read_index(the_repository);
		result = index_file_exists_icase_probe(
			the_repository->index, probe_name, strlen(probe_name),
			&scans, 1024);
		switch (result) {
		case INDEX_FILE_ICASE_PROBE_UNKNOWN:
			printf("unknown");
			break;
		case INDEX_FILE_ICASE_PROBE_ABSENT:
			printf("absent");
			break;
		case INDEX_FILE_ICASE_PROBE_PRESENT:
			printf("present");
			break;
		}
		printf(" %"PRIuMAX"\n", (uintmax_t)scans);
		return 0;
	}

	for (i = 0; i < cnt; i++) {
		repo_read_index(the_repository);
		if (name) {
			int pos;

			refresh_index(the_repository->index, REFRESH_QUIET,
				      NULL, NULL, NULL);
			pos = index_name_pos(the_repository->index, name, strlen(name));
			if (pos < 0)
				die("%s not in index", name);
			printf("%s is%s up to date\n", name,
			       ce_uptodate(the_repository->index->cache[pos]) ? "" : " not");
			write_file(name, "%d\n", i);
		}
		discard_index(the_repository->index);
	}
	return 0;
}

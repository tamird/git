#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "config.h"
#include "environment.h"
#include "fsmonitor.h"
#include "grep-index-identity.h"
#include "lockfile.h"
#include "name-hash.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"

static void update_index(int fail_write)
{
	struct lock_file lock = LOCK_INIT;
	int written;

	repo_hold_locked_index(the_repository, &lock, LOCK_DIE_ON_ERROR);
	/* The open fd is writable, but the writer cannot finish the tempfile. */
	if (fail_write && unlink(get_lock_file_path(&lock)))
		die_errno("unable to remove index lock file");
	written = repo_update_index_if_able(the_repository, &lock);
	printf("%d %d\n", written, !!the_repository->index->cache_changed);
}

static int write_index_updates(const char *name, const char *alternate,
			       int fail_write)
{
	struct index_state *istate = the_repository->index;
	int pos;

	setup_work_tree(the_repository);
	if (repo_read_index(the_repository) < 0)
		die("unable to read index");
	refresh_index(istate, REFRESH_QUIET, NULL, NULL, NULL);
	pos = index_name_pos(istate, name, strlen(name));
	if (pos < 0)
		die("index entry to update does not exist");
	if (chmod_index_entry(istate, istate->cache[pos], '+'))
		die("unable to make index entry executable");
	set_alternate_index_output(alternate);
	update_index(fail_write);
	set_alternate_index_output(NULL);
	if (alternate || fail_write)
		return 0;
	update_index(0);
	if (chmod_index_entry(istate, istate->cache[pos], '-'))
		die("unable to make index entry non-executable");
	update_index(0);
	update_index(0);
	if (istate->fsmonitor_last_update) {
		mark_fsmonitor_valid(istate, istate->cache[pos]);
		update_index(0);
		update_index(0);
	}
	return 0;
}

int cmd__read_cache(int argc, const char **argv)
{
	int i, cnt = 1;
	const char *name = NULL;
	const char *probe_name = NULL;
	int probe_dir = 0;
	const char *replace_old = NULL;
	const char *replace_new = NULL;
	int write_updates = argc > 1 && !strcmp(argv[1], "--write-index");

	if (write_updates && argc != 3 && argc != 4)
		die("expected path and optional alternate index after --write-index");

	if (argc > 1 &&
	    skip_prefix(argv[1], "--identity-replace=", &replace_old)) {
		if (argc != 3)
			die("expected replacement file after --identity-replace");
		replace_new = argv[2];
	} else if (argc > 1 &&
		   skip_prefix(argv[1], "--icase-dir-probe=", &probe_name)) {
		probe_dir = 1;
		argc--;
		argv++;
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
	if (write_updates) {
		int fail_write = argc == 4 && !strcmp(argv[3], "--fail-write");
		const char *alternate = argc == 4 && !fail_write ? argv[3] : NULL;

		return write_index_updates(argv[2], alternate, fail_write);
	}

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
		enum index_icase_probe_result result;
		size_t scans = 0;
		unsigned int scan_limit = 1024;

		if (argc > 2 ||
		    (argc == 2 && strtoul_ui(argv[1], 10, &scan_limit)))
			die("expected an unsigned scan limit after the probe option");
		repo_read_index(the_repository);
		result = (probe_dir ? index_dir_exists_icase_probe :
			  index_file_exists_icase_probe)(
			the_repository->index, probe_name, strlen(probe_name),
			&scans, scan_limit);
		switch (result) {
		case INDEX_ICASE_PROBE_UNKNOWN:
			printf("unknown");
			break;
		case INDEX_ICASE_PROBE_ABSENT:
			printf("absent");
			break;
		case INDEX_ICASE_PROBE_PRESENT:
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

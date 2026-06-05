#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "config.h"
#include "environment.h"
#include "name-hash.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"

int cmd__read_cache(int argc, const char **argv)
{
	int i, cnt = 1;
	const char *name = NULL;
	const char *probe_name = NULL;

	if (argc > 1 &&
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

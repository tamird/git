#include "builtin.h"
#include "grep-index.h"
#include "parse-options.h"
#include "replace-object.h"

static const char * const builtin_grep_index_usage[] = {
	N_("git grep-index [--[no-]progress]"),
	NULL
};

int cmd_grep_index(int argc, const char **argv, const char *prefix,
		   struct repository *repo)
{
	int progress = isatty(2);
	int transpose_existing = 0;
	struct option options[] = {
		OPT_BOOL(0, "progress", &progress,
			 N_("force progress reporting")),
		OPT_BOOL(0, "transpose-existing", &transpose_existing,
			 N_("transpose existing content indexes")),
		OPT_END(),
	};

	disable_replace_refs();
	argc = parse_options(argc, argv, prefix, options,
			     builtin_grep_index_usage, 0);
	if (argc)
		usage_with_options(builtin_grep_index_usage, options);
	if (transpose_existing)
		return write_transposed_grep_index(repo);
	return write_grep_index(repo, progress);
}

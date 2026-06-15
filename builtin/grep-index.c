#define USE_THE_REPOSITORY_VARIABLE

#include "builtin.h"
#include "environment.h"
#include "grep-commit-index.h"
#include "grep-index.h"
#include "parse-options.h"
#include "progress.h"
#include "replace-object.h"
#include "revision.h"

static const char * const builtin_grep_index_usage[] = {
	N_("git grep-index [--[no-]progress]"),
	N_("git grep-index [--[no-]progress] --reachable "
	   "[<revision>...] [-- [<path>...]]"),
	N_("git grep-index [--[no-]progress] --commit-edges "
	   "[<revision>...] [-- [<path>...]]"),
	N_("git grep-index --transpose-existing"),
	NULL
};

int cmd_grep_index(int argc, const char **argv, const char *prefix,
		   struct repository *repo)
{
	int show_progress = isatty(2);
	int commit_edges = 0;
	int reachable = 0;
	int transpose_existing = 0;
	int result;
	struct progress *progress = NULL;
	struct rev_info revs = REV_INFO_INIT;
	struct option options[] = {
		OPT_BOOL(0, "commit-edges", &commit_edges,
			 N_("index changed blobs by commit edge")),
		OPT_BOOL(0, "progress", &show_progress,
			 N_("force progress reporting")),
		OPT_BOOL(0, "transpose-existing", &transpose_existing,
			 N_("transpose existing content indexes")),
		OPT_BOOL(0, "reachable", &reachable,
			 N_("index blobs reachable from revisions")),
		OPT_END(),
	};

	disable_replace_refs();
	argc = parse_options(argc, argv, prefix, options,
			     builtin_grep_index_usage,
			     PARSE_OPT_KEEP_UNKNOWN_OPT |
				     PARSE_OPT_KEEP_ARGV0 |
				     PARSE_OPT_KEEP_DASHDASH);
	if (transpose_existing && reachable)
		die(_("options '%s' and '%s' cannot be used together"),
		    "--transpose-existing", "--reachable");
	if (transpose_existing && commit_edges)
		die(_("options '%s' and '%s' cannot be used together"),
		    "--transpose-existing", "--commit-edges");
	if (reachable && commit_edges)
		die(_("options '%s' and '%s' cannot be used together"),
		    "--reachable", "--commit-edges");
	if (!reachable && !commit_edges && argc > 1)
		usage_with_options(builtin_grep_index_usage, options);
	if (transpose_existing)
		return write_transposed_grep_index(repo);
	if (reachable || commit_edges) {
		const char *all_argv[] = { "grep-index", "--all", NULL };

		repo_init_revisions(repo, &revs, prefix);
		if (argc == 1)
			argc = setup_revisions(2, all_argv, &revs, NULL);
		else
			argc = setup_revisions(argc, argv, &revs, NULL);
		if (argc > 1)
			die(_("unrecognized argument: %s"), argv[1]);
	}
	if (commit_edges) {
		if (show_progress)
			progress = start_delayed_progress(
				repo, _("Indexing commit edges"), 0);
		result = write_grep_commit_index(repo, &revs, progress);
		stop_progress(&progress);
	} else
		result = write_grep_index(repo, show_progress,
					  reachable ? &revs : NULL);
	if (reachable || commit_edges)
		release_revisions(&revs);
	return result;
}

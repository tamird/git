#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "grep-index-ipc.h"
#include "repository.h"
#include "setup.h"
#include "thread-utils.h"
#include "wrapper.h"

int cmd__grep_index_ipc(int argc, const char **argv)
{
	uint64_t lease_id;
	int target;
	int requested;

	if (argc != 5 || strtol_i(argv[1], 10, &requested) ||
	    requested < 1)
		die("usage: test-tool grep-index-ipc <workers> "
		    "<start> <acquired> <release>");

	setup_git_directory(the_repository);
	while (access(argv[2], F_OK))
		sleep_millisec(10);
	if (grep_index_ipc_acquire_workers(
		    the_repository, requested, 0, &lease_id, &target))
		die("could not acquire grep workers");
	while (access(argv[4], F_OK)) {
		write_file(argv[3], "%d\n", target);
		sleep_millisec(10);
		if (grep_index_ipc_update_workers(
			    the_repository, lease_id, requested,
			    target, &target))
			die("could not update grep workers");
	}
	grep_index_ipc_release_workers(the_repository, lease_id);
	return 0;
}

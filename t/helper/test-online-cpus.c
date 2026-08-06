#include "test-tool.h"
#include "git-compat-util.h"
#include "thread-utils.h"

int cmd__online_cpus(int argc, const char **argv)
{
	if (argc == 4 && !strcmp(argv[1], "--quota")) {
		char *end;
		long available;

		errno = 0;
		available = strtol(argv[2], &end, 10);
		if (errno == ERANGE || *end || available < 1 ||
		    available > INT_MAX)
			usage("test-tool online-cpus --quota <cpus> <cpu.max>");

		printf("%d\n", online_cpus_with_cgroup_quota((int)available,
							   argv[3]));
		return 0;
	}

	if (argc != 1)
		usage("test-tool online-cpus [--quota <cpus> <cpu.max>]");

	printf("%d\n", online_cpus());
	return 0;
}

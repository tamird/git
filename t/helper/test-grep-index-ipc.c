#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "grep-index.h"
#include "grep-index-ipc.h"
#include "repository.h"
#include "setup.h"
#include "strbuf.h"
#include "thread-utils.h"
#include "wrapper.h"

static int test_query_wire(void)
{
	static const unsigned char exact[] = {
		0x47, 0x49, 0x51, 0x58,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x12, 0x34, 0x56, 0x78,
		0x00, 0x00, 0x00, 0x00,
	};
	static const unsigned char folded[] = {
		0x47, 0x49, 0x51, 0x58,
		0x00, 0x00, 0x00, 0x02,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x12, 0x34, 0x56, 0x78,
		0x00, 0x00, 0x00, 0x00,
	};
	unsigned char invalid[sizeof(folded)];
	struct grep_index_query *query;
	struct strbuf serialized = STRBUF_INIT;

	query = grep_index_query_deserialize((const char *)exact,
					     sizeof(exact));
	if (!query || grep_index_query_serialize(query, &serialized) ||
	    serialized.len != sizeof(exact) ||
	    memcmp(serialized.buf, exact, sizeof(exact)))
		return error("exact grep query wire format changed");
	grep_index_query_free(query);
	strbuf_reset(&serialized);

	query = grep_index_query_deserialize((const char *)folded,
					     sizeof(folded));
	if (!query || grep_index_query_serialize(query, &serialized) ||
	    serialized.len != sizeof(folded) ||
	    memcmp(serialized.buf, folded, sizeof(folded)))
		return error("folded grep query wire format changed");
	grep_index_query_free(query);
	strbuf_release(&serialized);

	memcpy(invalid, folded, sizeof(invalid));
	invalid[11] = 2;
	query = grep_index_query_deserialize((const char *)invalid,
					     sizeof(invalid));
	if (query) {
		grep_index_query_free(query);
		return error("invalid grep query flags accepted");
	}
	return 0;
}

int cmd__grep_index_ipc(int argc, const char **argv)
{
	uint64_t lease_id;
	int target;
	int requested;

	if (argc == 2 && !strcmp(argv[1], "query-wire"))
		return test_query_wire();
	if (argc != 5 || strtol_i(argv[1], 10, &requested) ||
	    requested < 1)
		die("usage: test-tool grep-index-ipc query-wire\n"
		    "   or: test-tool grep-index-ipc <workers> "
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

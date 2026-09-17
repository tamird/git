/*
 * test-fsmonitor-client.c: client code to send commands/requests to
 * a `git fsmonitor--daemon` daemon.
 */

#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "dir.h"
#include "parse-options.h"
#include "fsmonitor-ipc.h"
#include "fsmonitor-ll.h"
#include "hex.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"
#include "strbuf.h"
#include "thread-utils.h"
#include "trace2.h"

#ifndef HAVE_FSMONITOR_DAEMON_BACKEND
int cmd__fsmonitor_client(int argc UNUSED, const char **argv UNUSED)
{
	die("fsmonitor--daemon not available on this platform");
}
#else

/*
 * Read the `.git/index` to get the last token written to the
 * FSMonitor Index Extension.
 */
static const char *get_token_from_index(void)
{
	struct index_state *istate = the_repository->index;

	if (do_read_index(istate, the_repository->index_file, 0) < 0)
		die("unable to read index file");
	if (!istate->fsmonitor_last_update)
		die("index file does not have fsmonitor extension");

	return istate->fsmonitor_last_update;
}

/*
 * Send an IPC query to a `git-fsmonitor--daemon` daemon and
 * ask for the changes since the given token or from the last
 * token in the index extension.
 *
 * This will implicitly start a daemon process if necessary.  The
 * daemon process will persist after we exit.
 */
static int do_send_query(const char *token)
{
	struct strbuf answer = STRBUF_INIT;
	int ret;

	if (!token || !*token)
		token = get_token_from_index();

	ret = fsmonitor_ipc__send_query(token, &answer);
	if (ret < 0)
		die("could not query fsmonitor--daemon");

	write_in_full(1, answer.buf, answer.len);
	strbuf_release(&answer);

	return 0;
}

/*
 * Send a "flush" command to the `git-fsmonitor--daemon` (if running)
 * and tell it to flush its cache.
 *
 * This feature is primarily used by the test suite to simulate a loss of
 * sync with the filesystem where we miss kernel events.
 */
static int do_send_flush(void)
{
	struct strbuf answer = STRBUF_INIT;
	int ret;

	ret = fsmonitor_ipc__send_command("flush", &answer);
	if (ret)
		return ret;

	write_in_full(1, answer.buf, answer.len);
	strbuf_release(&answer);

	return 0;
}

static int do_save_untracked_cache(const char *token, int current_token,
				   int if_absent)
{
	struct index_state *istate = the_repository->index;

	/* Read the non-split fixture without querying or starting fsmonitor. */
	if (do_read_index(istate, the_repository->index_file, 1) < 0)
		die("unable to read index file");
	if (token) {
		free(istate->fsmonitor_last_update);
		istate->fsmonitor_last_update = xstrdup(token);
	} else if (current_token)
		refresh_fsmonitor(istate);
	fsmonitor_ipc__save_untracked_cache(
		istate, if_absent ? FSMONITOR_UNTRACKED_CACHE_SAVE_IF_ABSENT :
				    FSMONITOR_UNTRACKED_CACHE_SAVE_NORMAL);
	return 0;
}

/* Exercise the snapshot writer's depth limit without creating worktree dirs. */
static int do_save_overdeep_untracked_cache(void)
{
	struct index_state *istate = the_repository->index;
	struct untracked_cache *original;
	struct untracked_cache synthetic;
	struct untracked_cache_dir *root = NULL, *parent = NULL, *node, *next;
	int i;

	if (do_read_index(istate, the_repository->index_file, 1) < 0 ||
	    !istate->untracked)
		die("test requires an index with an untracked cache");
	refresh_fsmonitor(istate);
	original = istate->untracked;
	synthetic = *original;
	for (i = 0; i < 2048; i++) {
		FLEX_ALLOC_STR(node, name, i ? "child" : "");
		node->recurse = node->valid = 1;
		if (parent) {
			ALLOC_ARRAY(parent->dirs, 1);
			parent->dirs[0] = node;
			parent->dirs_nr = parent->dirs_alloc = 1;
		} else {
			root = node;
		}
		parent = node;
	}
	synthetic.root = root;
	istate->untracked = &synthetic;
	fsmonitor_ipc__save_untracked_cache(
		istate, FSMONITOR_UNTRACKED_CACHE_SAVE_NORMAL);
	istate->untracked = original;
	for (node = root; node; node = next) {
		next = node->dirs_nr ? node->dirs[0] : NULL;
		free(node->dirs);
		free(node);
	}
	return 0;
}

/* Test the first directory count that exceeded the former snapshot limit. */
static int test_untracked_snapshot_dir_bound(void)
{
	enum { nr_children = 512 * 1024 };
	struct untracked_cache synthetic = { 0 };
	struct untracked_cache *restored = NULL;
	struct untracked_cache_dir *root, *child;
	struct strbuf snapshot = STRBUF_INIT;
	enum untracked_snapshot_bound bound;
	char child_name[16];
	int ret = 1;

	synthetic.exclude_per_dir = ".gitignore";
	strbuf_init(&synthetic.ident, 0);
	FLEX_ALLOC_STR(root, name, "");
	root->valid = root->recurse = 1;
	CALLOC_ARRAY(root->dirs, nr_children);
	root->dirs_nr = root->dirs_alloc = nr_children;
	for (int i = 0; i < nr_children; i++) {
		xsnprintf(child_name, sizeof(child_name), "d%06d", i);
		FLEX_ALLOC_STR(child, name, child_name);
		child->valid = child->recurse = 1;
		root->dirs[i] = child;
	}
	synthetic.root = root;

	if (write_untracked_snapshot(&snapshot, &synthetic, &bound) !=
		    UNTRACKED_CACHE_ENCODING_LEGACY ||
	    bound != UNTRACKED_SNAPSHOT_BOUND_NONE) {
		error("snapshot rejected %d directory nodes", nr_children + 1);
		goto done;
	}
	restored = read_untracked_snapshot(snapshot.buf, snapshot.len);
	if (!restored || !restored->root ||
	    restored->root->dirs_nr != nr_children ||
	    strcmp(restored->root->dirs[0]->name, "d000000") ||
	    strcmp(restored->root->dirs[nr_children - 1]->name, child_name)) {
		error("snapshot failed to round-trip %d directory nodes",
		      nr_children + 1);
		goto done;
	}
	ret = 0;

done:
	free_untracked_cache(restored);
	for (int i = 0; i < nr_children; i++)
		free(root->dirs[i]);
	free(root->dirs);
	free(root);
	strbuf_release(&synthetic.ident);
	strbuf_release(&snapshot);
	return ret;
}

static int do_send_untracked_cache_raw(const char *token, const char *verb,
				       const char *expected_reply)
{
	struct index_state *istate = the_repository->index;
	struct strbuf identity = STRBUF_INIT;
	struct strbuf command = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	int ret = 1;

	if (do_read_index(istate, the_repository->index_file, 1) < 0 ||
	    is_null_oid(&istate->oid))
		die("test requires an index with a valid object ID");
	refresh_fsmonitor(istate);
	if (!token)
		token = istate->fsmonitor_last_update;
	if (!token || fsmonitor_ipc__get_worktree_identity(
				 repo_get_work_tree(the_repository), &identity))
		goto done;

	strbuf_addstr(&command, FSMONITOR_IPC_QUERY_PREFIX);
	strbuf_addbuf(&command, &identity);
	strbuf_addch(&command, '\n');
	strbuf_addf(&command, FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX "%s %s %s%s", verb, oid_to_hex(&istate->oid), token,
		    !strcmp(verb, "get") ? "" : " 00");
	if (fsmonitor_ipc__send_command(command.buf, &answer))
		goto done;
	if (!strcmp(expected_reply, "hit"))
		ret = answer.len <= 4 || memcmp(answer.buf, "hit", 4);
	else
		ret = answer.len != strlen(expected_reply) ||
		      memcmp(answer.buf, expected_reply, answer.len);

done:
	strbuf_release(&answer);
	strbuf_release(&command);
	strbuf_release(&identity);
	return ret;
}

struct hammer_thread_data
{
	pthread_t pthread_id;
	int thread_nr;

	int nr_requests;
	const char *token;

	int sum_successful;
	int sum_errors;
};

static void *hammer_thread_proc(void *_hammer_thread_data)
{
	struct hammer_thread_data *data = _hammer_thread_data;
	struct strbuf answer = STRBUF_INIT;
	int k;
	int ret;

	trace2_thread_start("hammer");

	for (k = 0; k < data->nr_requests; k++) {
		strbuf_reset(&answer);

		ret = fsmonitor_ipc__send_query(data->token, &answer);
		if (ret < 0)
			data->sum_errors++;
		else
			data->sum_successful++;
	}

	strbuf_release(&answer);
	trace2_thread_exit();
	return NULL;
}

/*
 * Start a pool of client threads that will each send a series of
 * commands to the daemon.
 *
 * The goal is to overload the daemon with a sustained series of
 * concurrent requests.
 */
static int do_hammer(const char *token, int nr_threads, int nr_requests)
{
	struct hammer_thread_data *data = NULL;
	int k;
	int sum_join_errors = 0;
	int sum_commands = 0;
	int sum_errors = 0;

	if (!token || !*token)
		token = get_token_from_index();
	if (nr_threads < 1)
		nr_threads = 1;
	if (nr_requests < 1)
		nr_requests = 1;

	CALLOC_ARRAY(data, nr_threads);

	for (k = 0; k < nr_threads; k++) {
		struct hammer_thread_data *p = &data[k];
		p->thread_nr = k;
		p->nr_requests = nr_requests;
		p->token = token;

		if (pthread_create(&p->pthread_id, NULL, hammer_thread_proc, p)) {
			warning("failed to create thread[%d] skipping remainder", k);
			nr_threads = k;
			break;
		}
	}

	for (k = 0; k < nr_threads; k++) {
		struct hammer_thread_data *p = &data[k];

		if (pthread_join(p->pthread_id, NULL))
			sum_join_errors++;
		sum_commands += p->sum_successful;
		sum_errors += p->sum_errors;
	}

	fprintf(stderr, "HAMMER: [threads %d][requests %d] [ok %d][err %d][join %d]\n",
		nr_threads, nr_requests, sum_commands, sum_errors, sum_join_errors);

	free(data);

	/*
	 * Return an error if any of the _send_query requests failed.
	 * We don't care about thread create/join errors.
	 */
	return sum_errors > 0;
}

static int test_trivial_response(void)
{
	struct strbuf reply = STRBUF_INIT;
	static const struct {
		const char *suffix;
		size_t len;
		int expected;
	} cause_cases[] = {
		{ "/\0", sizeof("/\0") - 1, 0 },
		{ "/\0002\0", sizeof("/\0002\0") - 1, 2 },
		{ "/\0x\0", sizeof("/\0x\0") - 1, 0 },
		{ "/\0009\0", sizeof("/\0009\0") - 1, 0 },
		{ "/\0002\0extra", sizeof("/\0002\0extra") - 1, 0 },
	};
	static const struct {
		const char *requested;
		const char *response;
		const char *reason;
		unsigned int invalid_token_mask;
	} cases[] = {
		{ NULL, "",
		  "initial-token", 0 },
		{ "builtin:fake", "",
		  "initial-token", 0 },
		{ NULL, "builtin:g:1",
		  "initial-token", 0 },
		{ "builtin:fake", "builtin:g:1",
		  "initial-token", 0 },
		{ "", "builtin:g:1",
		  "invalid-token", 1 },
		{ "builtin:g:1", "",
		  "invalid-token", 2 },
		{ "", "",
		  "invalid-token", 3 },
		{ "bad", "builtin:g:1",
		  "invalid-token", 1 },
		{ "builtin:g:1", "bad",
		  "invalid-token", 2 },
		{ "builtin:", "builtin:g:1",
		  "invalid-token", 1 },
		{ "builtin:g:1", "builtin:",
		  "invalid-token", 2 },
		{ "builtin:g", "builtin:g:1",
		  "invalid-token", 1 },
		{ "builtin:g:1", "builtin:g",
		  "invalid-token", 2 },
		{ "builtin::1", "builtin:g:1",
		  "invalid-token", 1 },
		{ "builtin:g:1", "builtin::1",
		  "invalid-token", 2 },
		{ "builtin:g:", "builtin:g:1",
		  "invalid-token", 1 },
		{ "builtin:g:1", "builtin:g:",
		  "invalid-token", 2 },
		{ "bad", "builtin:g:",
		  "invalid-token", 3 },
		{ "builtin:g:1", "builtin:fake",
		  "invalid-token", 2 },
		{ "builtin:g:1", "builtin:g:2",
		  "same-token-generation", 0 },
		{ "builtin:g:x", "builtin:g:y",
		  "same-token-generation", 0 },
		{ "builtin:g:x:y", "builtin:g:z:w",
		  "same-token-generation", 0 },
		{ "builtin:g:1", "builtin:h:1",
		  "token-generation-changed", 0 },
		{ "builtin:g:1", "builtin:gg:1",
		  "token-generation-changed", 0 },
		{ "builtin:gg:1", "builtin:g:1",
		  "token-generation-changed", 0 },
		{ "builtin:fake:1", "builtin:fake:2",
		  "same-token-generation", 0 },
	};

	for (size_t i = 0; i < ARRAY_SIZE(cases); i++) {
		struct fsmonitor_trivial_result result =
			fsmonitor_classify_trivial_response(
				cases[i].requested, cases[i].response);

		if (!result.reason || strcmp(result.reason, cases[i].reason) ||
		    result.invalid_token_mask != cases[i].invalid_token_mask)
			die("trivial response classification failed at case %"PRIuMAX,
			    (uintmax_t)i);
	}
	for (size_t i = 0; i < ARRAY_SIZE(cause_cases); i++) {
		int actual;

		strbuf_reset(&reply);
		strbuf_addstr(&reply, "builtin:g:2");
		strbuf_addch(&reply, '\0');
		strbuf_add(&reply, cause_cases[i].suffix, cause_cases[i].len);
		actual = fsmonitor_trivial_generation_cause(&reply,
							    strlen(reply.buf) + 1);
		if (actual != cause_cases[i].expected)
			die("trivial response cause failed at case %" PRIuMAX
			    ": expected %d, got %d",
			    (uintmax_t)i,
			    cause_cases[i].expected, actual);
	}
	strbuf_release(&reply);

	return 0;
}

int cmd__fsmonitor_client(int argc, const char **argv)
{
	const char *subcmd;
	const char *token = NULL;
	int current_token = 0, if_absent = 0;
	int nr_threads = 1;
	int nr_requests = 1;

	const char *const fsmonitor_client_usage[] = {
		"test-tool fsmonitor-client test-trivial-response",
		"test-tool fsmonitor-client query [<token>]",
		"test-tool fsmonitor-client flush",
		"test-tool fsmonitor-client ipc-path",
		"test-tool fsmonitor-client save-untracked-cache [--token=<token> | --current-token] [--if-absent]",
		"test-tool fsmonitor-client save-overdeep-untracked-cache",
		"test-tool fsmonitor-client test-untracked-snapshot-dir-bound",
		"test-tool fsmonitor-client poison-untracked-cache [--token=<token>]",
		"test-tool fsmonitor-client legacy-untracked-cache-save-miss --token=<token>",
		"test-tool fsmonitor-client legacy-untracked-cache-get-miss --token=<token>",
		"test-tool fsmonitor-client legacy-untracked-cache-get-hit",
		"test-tool fsmonitor-client hammer [<token>] [<threads>] [<requests>]",
		NULL,
	};

	struct option options[] = {
		OPT_STRING(0, "token", &token, "token",
			   "command token to send to the server"),
		OPT_BOOL(0, "current-token", &current_token,
			 "refresh the token from the daemon"),
		OPT_BOOL(0, "if-absent", &if_absent,
			 "preserve a snapshot already saved at the current token"),

		OPT_INTEGER(0, "threads", &nr_threads, "number of client threads"),
		OPT_INTEGER(0, "requests", &nr_requests, "number of requests per thread"),

		OPT_END()
	};

	argc = parse_options(argc, argv, NULL, options, fsmonitor_client_usage, 0);

	if (argc != 1)
		usage_with_options(fsmonitor_client_usage, options);

	subcmd = argv[0];

	if (!strcmp(subcmd, "test-trivial-response"))
		return test_trivial_response();

	setup_git_directory(the_repository);

	if (!strcmp(subcmd, "query"))
		return !!do_send_query(token);

	if (!strcmp(subcmd, "flush"))
		return !!do_send_flush();

	if (!strcmp(subcmd, "ipc-path")) {
		puts(fsmonitor_ipc__get_path(the_repository));
		return 0;
	}

	if (!strcmp(subcmd, "save-untracked-cache"))
		return do_save_untracked_cache(token, current_token, if_absent);
	if (!strcmp(subcmd, "save-overdeep-untracked-cache"))
		return do_save_overdeep_untracked_cache();
	if (!strcmp(subcmd, "test-untracked-snapshot-dir-bound"))
		return test_untracked_snapshot_dir_bound();

	if (!strcmp(subcmd, "poison-untracked-cache"))
		return do_send_untracked_cache_raw(token, "put", "ok");
	if (!strcmp(subcmd, "legacy-untracked-cache-save-miss"))
		return do_send_untracked_cache_raw(token, "put", "miss");
	if (!strcmp(subcmd, "legacy-untracked-cache-get-miss"))
		return do_send_untracked_cache_raw(token, "get", "miss");
	if (!strcmp(subcmd, "legacy-untracked-cache-get-hit"))
		return do_send_untracked_cache_raw(token, "get", "hit");

	if (!strcmp(subcmd, "hammer"))
		return !!do_hammer(token, nr_threads, nr_requests);

	die("Unhandled subcommand: '%s'", subcmd);
}
#endif

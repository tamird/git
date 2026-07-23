#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "dir.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-settings.h"
#include "gettext.h"
#include "hash.h"
#include "hex.h"
#include "read-cache-ll.h"
#include "simple-ipc.h"
#include "fsmonitor-ipc.h"
#include "repository.h"
#include "run-command.h"
#include "strbuf.h"
#include "trace2.h"

#ifndef HAVE_FSMONITOR_DAEMON_BACKEND

/*
 * A trivial implementation of the fsmonitor_ipc__ API for unsupported
 * platforms.
 */

int fsmonitor_ipc__is_supported(void)
{
	return 0;
}

const char *fsmonitor_ipc__get_path(struct repository *r UNUSED)
{
	return NULL;
}

enum ipc_active_state fsmonitor_ipc__get_state(void)
{
	return IPC_STATE__OTHER_ERROR;
}

int fsmonitor_ipc__send_query(const char *since_token UNUSED,
			      struct strbuf *answer UNUSED)
{
	return -1;
}

int fsmonitor_ipc__send_command(const char *command UNUSED,
				struct strbuf *answer UNUSED)
{
	return -1;
}

enum fsmonitor_untracked_cache_result
fsmonitor_ipc__restore_untracked_cache(struct index_state *istate UNUSED)
{
	return FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED;
}

void fsmonitor_ipc__save_untracked_cache(struct index_state *istate UNUSED)
{
}

#else

int fsmonitor_ipc__get_worktree_identity(const char *worktree,
					 struct strbuf *identity)
{
	static const char hex[] = "0123456789abcdef";
	struct strbuf canonical = STRBUF_INIT;
	struct strbuf stable = STRBUF_INIT;
	git_SHA256_CTX ctx;
	unsigned char hash[GIT_SHA256_RAWSZ];
	struct stat st;
	int ret = -1;

	if (!worktree ||
	    !strbuf_realpath(&canonical, worktree, 0) ||
	    stat(canonical.buf, &st))
		goto done;

	strbuf_addf(&stable, "v1\n%zu:", canonical.len);
	strbuf_addbuf(&stable, &canonical);
	strbuf_addf(&stable, "\n%"PRIuMAX"\n%"PRIuMAX,
		    (uintmax_t)st.st_dev, (uintmax_t)st.st_ino);
#ifdef __APPLE__
	strbuf_addf(&stable, "\n%"PRIdMAX"\n%ld\n%"PRIu32,
		    (intmax_t)st.st_birthtimespec.tv_sec,
		    st.st_birthtimespec.tv_nsec, st.st_gen);
#endif

	git_SHA256_Init(&ctx);
	git_SHA256_Update(&ctx, stable.buf, stable.len);
	git_SHA256_Final(hash, &ctx);
	strbuf_reset(identity);
	for (size_t i = 0; i < ARRAY_SIZE(hash); i++) {
		strbuf_addch(identity, hex[hash[i] >> 4]);
		strbuf_addch(identity, hex[hash[i] & 0xf]);
	}
	ret = 0;

done:
	strbuf_release(&stable);
	strbuf_release(&canonical);
	return ret;
}

int fsmonitor_ipc__is_supported(void)
{
	return 1;
}

#ifdef __APPLE__
static void fsmonitor_ipc__format_request(struct strbuf *request,
					  const char *command,
					  size_t command_len)
{
	char *gitdir = real_pathdup(repo_get_git_dir(the_repository), 1);

	strbuf_addstr(request, "v1");
	strbuf_addch(request, '\0');
	strbuf_addstr(request, gitdir);
	strbuf_addch(request, '\0');
	strbuf_add(request, command, command_len);
	free(gitdir);
}
#endif

enum ipc_active_state fsmonitor_ipc__get_state(void)
{
	return ipc_get_active_state(fsmonitor_ipc__get_path(the_repository));
}

static int spawn_daemon(void)
{
	struct child_process cmd = CHILD_PROCESS_INIT;

	cmd.git_cmd = 1;
	cmd.no_stdin = 1;
	cmd.no_stdout = 1;
	cmd.no_stderr = 1;
	cmd.close_fd_above_stderr = 1;
	cmd.trace2_child_class = "fsmonitor";
	strvec_pushl(&cmd.args, "fsmonitor--daemon", "start", NULL);

	return run_command(&cmd);
}

int fsmonitor_ipc__send_query(const char *since_token,
			      struct strbuf *answer)
{
	struct strbuf command = STRBUF_INIT;
	struct strbuf identity = STRBUF_INIT;
	int ret = -1;
	int tried_to_spawn = 0;
	enum ipc_active_state state = IPC_STATE__OTHER_ERROR;
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	const char *tok = since_token ? since_token : "";
#ifdef __APPLE__
	struct strbuf request = STRBUF_INIT;
#endif

	trace2_region_enter("fsm_client", "query", NULL);
	if (fsmonitor_ipc__get_worktree_identity(
		    repo_get_work_tree(the_repository), &identity)) {
		trace2_data_intmax("fsm_client", NULL,
				   "query/worktree-identity-error", 1);
		goto done;
	}
	strbuf_addstr(&command, FSMONITOR_IPC_QUERY_PREFIX);
	strbuf_addbuf(&command, &identity);
	strbuf_addch(&command, '\n');
	strbuf_addstr(&command, tok);
#ifdef __APPLE__
	fsmonitor_ipc__format_request(&request, command.buf, command.len);
#endif

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	trace2_data_string("fsm_client", NULL, "query/command", tok);

try_again:
	state = ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
						&options, &connection);

	switch (state) {
	case IPC_STATE__LISTENING:
		ret = ipc_client_send_command_to_connection(
			connection,
#ifdef __APPLE__
			request.buf, request.len,
#else
			command.buf, command.len,
#endif
			answer);
		ipc_client_close_connection(connection);
#ifdef __APPLE__
		if (!ret && !memchr(answer->buf, '\0', answer->len))
			ret = -1;
#endif

		trace2_data_intmax("fsm_client", NULL,
				   "query/response-length", answer->len);
		goto done;

	case IPC_STATE__NOT_LISTENING:
	case IPC_STATE__PATH_NOT_FOUND:
		if (tried_to_spawn)
			goto done;

		tried_to_spawn++;
		if (spawn_daemon()) {
#ifdef __APPLE__
			/*
			 * Another worktree may have won the race to start the
			 * repository-wide daemon.
			 */
			if (fsmonitor_ipc__get_state() != IPC_STATE__LISTENING)
				goto done;
#else
			goto done;
#endif
		}

		/*
		 * Try again, but this time give the daemon a chance to
		 * actually create the pipe/socket.
		 *
		 * Granted, the daemon just started so it can't possibly have
		 * any FS cached yet, so we'll always get a trivial answer.
		 * BUT the answer should include a new token that can serve
		 * as the basis for subsequent requests.
		 */
		options.wait_if_not_found = 1;
		goto try_again;

	case IPC_STATE__INVALID_PATH:
		ret = error(_("fsmonitor_ipc__send_query: invalid path '%s'"),
			    fsmonitor_ipc__get_path(the_repository));
		goto done;

	case IPC_STATE__OTHER_ERROR:
	default:
		ret = error(_("fsmonitor_ipc__send_query: unspecified error on '%s'"),
			    fsmonitor_ipc__get_path(the_repository));
		goto done;
	}

done:
	trace2_region_leave("fsm_client", "query", NULL);
#ifdef __APPLE__
	strbuf_release(&request);
#endif
	strbuf_release(&identity);
	strbuf_release(&command);

	return ret;
}

static int fsmonitor_ipc__send_untracked_cache_command(
	const char *command, size_t command_len, struct strbuf *answer)
{
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct strbuf bound = STRBUF_INIT;
	struct strbuf identity = STRBUF_INIT;
	int ret = -1;
#ifdef __APPLE__
	struct strbuf request = STRBUF_INIT;
#endif

	if (fsmonitor_ipc__get_worktree_identity(
		    repo_get_work_tree(the_repository), &identity))
		goto done;

	strbuf_addstr(&bound, FSMONITOR_IPC_QUERY_PREFIX);
	strbuf_addbuf(&bound, &identity);
	strbuf_addch(&bound, '\n');
	strbuf_add(&bound, command, command_len);
#ifdef __APPLE__
	fsmonitor_ipc__format_request(&request, bound.buf, bound.len);
#endif

	options.wait_if_busy = 1;
	if (ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
				   &options, &connection) !=
	    IPC_STATE__LISTENING)
		goto done;

	strbuf_reset(answer);
	ret = ipc_client_send_command_to_connection_gently(
		connection,
#ifdef __APPLE__
		request.buf, request.len,
#else
		bound.buf, bound.len,
#endif
		answer);
	ipc_client_close_connection(connection);

done:
#ifdef __APPLE__
	strbuf_release(&request);
#endif
	strbuf_release(&identity);
	strbuf_release(&bound);
	return ret;
}

enum fsmonitor_untracked_cache_result
fsmonitor_ipc__restore_untracked_cache(struct index_state *istate)
{
	struct strbuf command = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	struct untracked_cache *candidate;
	enum fsmonitor_untracked_cache_result result =
		FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED;

	if (!istate->untracked || is_null_oid(&istate->oid) ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		return FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED;

	refresh_fsmonitor(istate);
	if (!istate->fsmonitor_last_update ||
	    !istate->untracked->use_fsmonitor)
		return FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED;

	strbuf_addf(&command, FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX
		    "get %s %s", oid_to_hex(&istate->oid),
		    istate->fsmonitor_last_update);
	if (fsmonitor_ipc__send_untracked_cache_command(
		    command.buf, command.len, &answer))
		goto done;
	if (answer.len == 4 && !memcmp(answer.buf, "miss", 4)) {
		result = FSMONITOR_UNTRACKED_CACHE_MISS;
		goto done;
	}
	if (answer.len <= 4 ||
	    answer.len - 4 > FSMONITOR_IPC_UNTRACKED_CACHE_MAX ||
	    memcmp(answer.buf, "hit", 4))
		goto done;

	candidate = read_untracked_extension_bounded(answer.buf + 4,
						     answer.len - 4);
	if (!candidate)
		goto done;
	result = FSMONITOR_UNTRACKED_CACHE_HIT;
	candidate->use_fsmonitor = 1;
	free_untracked_cache(istate->untracked);
	istate->untracked = candidate;
	trace2_data_intmax("fsmonitor", istate->repo,
			   "untracked-cache/hit", 1);

done:
	strbuf_release(&answer);
	strbuf_release(&command);
	return result;
}

void fsmonitor_ipc__save_untracked_cache(struct index_state *istate)
{
	static const char hex[] = "0123456789abcdef";
	struct strbuf command = STRBUF_INIT;
	struct strbuf snapshot = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	size_t start;

	if (!istate->untracked || !istate->untracked->root ||
	    !istate->untracked->use_fsmonitor ||
	    !istate->fsmonitor_last_update || is_null_oid(&istate->oid) ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		return;

	write_untracked_extension(&snapshot, istate->untracked);
	if (!snapshot.len || snapshot.len >
		FSMONITOR_IPC_UNTRACKED_CACHE_MAX)
		goto done;

	strbuf_addf(&command, FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX
		    "put %s %s ", oid_to_hex(&istate->oid),
		    istate->fsmonitor_last_update);
	start = command.len;
	strbuf_grow(&command, snapshot.len * 2);
	for (size_t i = 0; i < snapshot.len; i++) {
		unsigned char value = snapshot.buf[i];

		command.buf[start + i * 2] = hex[value >> 4];
		command.buf[start + i * 2 + 1] = hex[value & 0xf];
	}
	strbuf_setlen(&command, start + snapshot.len * 2);
	if (!fsmonitor_ipc__send_untracked_cache_command(
		    command.buf, command.len, &answer) &&
	    answer.len == 2 && !memcmp(answer.buf, "ok", 2))
		trace2_data_intmax("fsmonitor", istate->repo,
				   "untracked-cache/saved", snapshot.len);

done:
	strbuf_release(&answer);
	strbuf_release(&snapshot);
	strbuf_release(&command);
}

int fsmonitor_ipc__send_command(const char *command,
				struct strbuf *answer)
{
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	int ret;
	enum ipc_active_state state;
	const char *c = command ? command : "";
	size_t c_len = command ? strlen(command) : 0;
#ifdef __APPLE__
	struct strbuf request = STRBUF_INIT;

	fsmonitor_ipc__format_request(&request, c, c_len);
#endif

	strbuf_reset(answer);

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	state = ipc_client_try_connect(fsmonitor_ipc__get_path(the_repository),
						&options, &connection);
	if (state != IPC_STATE__LISTENING) {
#ifdef __APPLE__
		strbuf_release(&request);
#endif
		die(_("fsmonitor--daemon is not running"));
		return -1;
	}

	ret = ipc_client_send_command_to_connection(
		connection,
#ifdef __APPLE__
		request.buf, request.len,
#else
		c, c_len,
#endif
		answer);
	ipc_client_close_connection(connection);
#ifdef __APPLE__
	strbuf_release(&request);
#endif

	if (ret == -1) {
		die(_("could not send '%s' command to fsmonitor--daemon"), c);
		return -1;
	}

	return 0;
}

#endif

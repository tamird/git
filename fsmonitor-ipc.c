#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "gettext.h"
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

#else

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
	int ret = -1;
	int tried_to_spawn = 0;
	enum ipc_active_state state = IPC_STATE__OTHER_ERROR;
	struct ipc_client_connection *connection = NULL;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	const char *tok = since_token ? since_token : "";
	size_t tok_len = since_token ? strlen(since_token) : 0;
#ifdef __APPLE__
	struct strbuf request = STRBUF_INIT;

	fsmonitor_ipc__format_request(&request, tok, tok_len);
#endif

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	trace2_region_enter("fsm_client", "query", NULL);
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
			tok, tok_len,
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

	return ret;
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

#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "config.h"
#include "gettext.h"
#include "hex.h"
#include "path.h"
#include "repository.h"
#include "strbuf.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-ipc.h"
#include "fsmonitor-path-utils.h"

#ifndef __APPLE__
static GIT_PATH_FUNC(fsmonitor_ipc__get_default_path, "fsmonitor--daemon.ipc")
#else
static int fsmonitor_socket_dir_cb(const char *var, const char *value,
				   const struct config_context *ctx UNUSED,
				   void *data)
{
	if (!strcmp(var, "fsmonitor.socketdir"))
		return git_config_string(data, var, value);
	return 0;
}

static char *fsmonitor_common_socket_dir(struct repository *r)
{
	struct config_options opts = {
		.respect_includes = 1,
		.ignore_worktree = 1,
		.ignore_cmdline = 1,
		.commondir = repo_get_common_dir(r),
		.git_dir = repo_get_common_dir(r),
	};
	char *socket_dir = NULL;

	config_with_options(fsmonitor_socket_dir_cb, &socket_dir, NULL, NULL,
			    &opts);
	return socket_dir;
}
#endif

const char *fsmonitor_ipc__get_path(struct repository *r)
{
	static const char *ipc_path = NULL;
	git_SHA_CTX sha1ctx;
	char *sock_dir = NULL;
	struct strbuf ipc_file = STRBUF_INIT;
	unsigned char hash[GIT_SHA1_RAWSZ];

	if (!r)
		BUG("No repository passed into fsmonitor_ipc__get_path");

	if (ipc_path)
		return ipc_path;

#ifdef __APPLE__
	{
		char *common_dir = real_pathdup(repo_get_common_dir(r), 1);
		char *default_path = xstrfmt(
			"%s/fsmonitor--daemon-common-v1.ipc", common_dir);

		sock_dir = fsmonitor_common_socket_dir(r);
		if (sock_dir && *sock_dir &&
		    !is_absolute_path(sock_dir) &&
		    sock_dir[0] != '~' &&
		    !starts_with(sock_dir, "%(prefix)/")) {
			char *absolute = xstrfmt("%s/%s", common_dir, sock_dir);

			free(sock_dir);
			sock_dir = absolute;
		}
		if ((!sock_dir || !*sock_dir) &&
		    fsmonitor__is_fs_remote(common_dir) < 1 &&
		    strlen(default_path) + 1 <=
			    sizeof(((struct sockaddr_un *)NULL)->sun_path)) {
			free(common_dir);
			free(sock_dir);
			ipc_path = default_path;
			return ipc_path;
		}
		free(default_path);

		git_SHA1_Init(&sha1ctx);
		git_SHA1_Update(&sha1ctx, common_dir, strlen(common_dir));
		git_SHA1_Final(hash, &sha1ctx);
		free(common_dir);
	}
	if (sock_dir && *sock_dir)
		strbuf_addf(&ipc_file, "%s/.git-fsmonitor-v1-%s",
			    sock_dir, hash_to_hex_algop(
					      hash, &hash_algos[GIT_HASH_SHA1]));
	else
		strbuf_addf(&ipc_file, "~/.git-fsmonitor-v1-%s",
			    hash_to_hex_algop(
				    hash, &hash_algos[GIT_HASH_SHA1]));
	free(sock_dir);
#else
	repo_config_get_string(r, "fsmonitor.socketdir", &sock_dir);

	/*
	 * Use the hashed fallback when the default path would require a
	 * process-wide chdir(), which is unsafe for multithreaded clients.
	 */
	if ((!sock_dir || !*sock_dir) &&
	    fsmonitor__is_fs_remote(r->gitdir) < 1) {
		const char *default_path = fsmonitor_ipc__get_default_path();

		if (strlen(default_path) + 1 <=
		    sizeof(((struct sockaddr_un *)NULL)->sun_path)) {
			free(sock_dir);
			ipc_path = default_path;
			return ipc_path;
		}
	}

	git_SHA1_Init(&sha1ctx);
	git_SHA1_Update(&sha1ctx, r->worktree, strlen(r->worktree));
	git_SHA1_Final(hash, &sha1ctx);

	/* Create the socket file in either socketDir or $HOME */
	if (sock_dir && *sock_dir) {
		strbuf_addf(&ipc_file, "%s/.git-fsmonitor-%s",
			    sock_dir, hash_to_hex_algop(hash, &hash_algos[GIT_HASH_SHA1]));
	} else {
		strbuf_addf(&ipc_file, "~/.git-fsmonitor-%s",
			    hash_to_hex_algop(hash, &hash_algos[GIT_HASH_SHA1]));
	}
	free(sock_dir);
#endif

	ipc_path = interpolate_path(ipc_file.buf, 1);
	if (!ipc_path)
		die(_("Invalid path: %s"), ipc_file.buf);

	strbuf_release(&ipc_file);
	return ipc_path;
}

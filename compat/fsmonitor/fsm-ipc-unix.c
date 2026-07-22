#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "config.h"
#include "gettext.h"
#include "hex.h"
#include "path.h"
#include "repository.h"
#include "strbuf.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-ipc.h"
#include "fsmonitor-path-utils.h"

static GIT_PATH_FUNC(fsmonitor_ipc__get_default_path, "fsmonitor--daemon.ipc")

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

	ipc_path = interpolate_path(ipc_file.buf, 1);
	if (!ipc_path)
		die(_("Invalid path: %s"), ipc_file.buf);

	strbuf_release(&ipc_file);
	return ipc_path;
}

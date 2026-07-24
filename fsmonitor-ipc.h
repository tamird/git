#ifndef FSMONITOR_IPC_H
#define FSMONITOR_IPC_H

#include "simple-ipc.h"

struct repository;
struct index_state;

#define FSMONITOR_IPC_QUERY_PREFIX "query-v1 "
#define FSMONITOR_IPC_WORKTREE_ID_HEX 64
#define FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX "untracked-cache-v1 "
#define FSMONITOR_IPC_UNTRACKED_CACHE_MAX (8 * 1024 * 1024)

enum fsmonitor_untracked_cache_result {
	FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED,
	FSMONITOR_UNTRACKED_CACHE_MISS,
	FSMONITOR_UNTRACKED_CACHE_HIT,
};

/* Hash the canonical worktree root and its stable filesystem identity. */
int fsmonitor_ipc__get_worktree_identity(const char *worktree,
					 struct strbuf *identity);

/*
 * Returns true if built-in file system monitor daemon is defined
 * for this platform.
 */
int fsmonitor_ipc__is_supported(void);

/*
 * Returns the pathname to the IPC named pipe or Unix domain socket
 * where a `git-fsmonitor--daemon` process will listen. On macOS this is
 * shared by all worktrees in a repository; elsewhere it is per-worktree.
 *
 * Returns NULL if the daemon is not supported on this platform.
 */
const char *fsmonitor_ipc__get_path(struct repository *r);

/*
 * Try to determine whether there is a `git-fsmonitor--daemon` process
 * listening on the IPC pipe/socket.
 */
enum ipc_active_state fsmonitor_ipc__get_state(void);

/*
 * Connect to a `git-fsmonitor--daemon` process via simple-ipc
 * and ask for the set of changed files since the given token.
 *
 * Spawn a daemon process in the background if necessary.
 *
 * Returns -1 on error; 0 on success.
 */
int fsmonitor_ipc__send_query(const char *since_token,
			      struct strbuf *answer);

/*
 * Connect to a `git-fsmonitor--daemon` process via simple-ipc and
 * send a command verb.  If no daemon is available, we DO NOT try to
 * start one.
 *
 * Returns -1 on error; 0 on success.
 */
int fsmonitor_ipc__send_command(const char *command,
				struct strbuf *answer);

/*
 * Reuse a complete, current-token untracked snapshot without an index lock.
 * The required restore_reason receives a static unsupported reason or NULL.
 */
enum fsmonitor_untracked_cache_result
fsmonitor_ipc__restore_untracked_cache(struct index_state *istate,
				       const char **restore_reason);
void fsmonitor_ipc__save_untracked_cache(struct index_state *istate);

#endif /* FSMONITOR_IPC_H */

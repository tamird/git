#ifndef FSMONITOR_IPC_H
#define FSMONITOR_IPC_H

#include "simple-ipc.h"

struct repository;
struct index_state;

#define FSMONITOR_IPC_QUERY_PREFIX "query-v1 "
#define FSMONITOR_IPC_KEEP_HISTORY_PREFIX    "keep-history "
#define FSMONITOR_IPC_WORKTREE_ID_HEX 64
#define FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX "untracked-cache-v1 "
#define FSMONITOR_IPC_UNTRACKED_CACHE_MAX (8 * 1024 * 1024)

/* Stable Trace2 codes for the cause of the daemon's current token generation. */
enum fsmonitor_generation_cause {
	FSMONITOR_GENERATION_UNKNOWN = 0,
	FSMONITOR_GENERATION_WATCH_START = 1,
	FSMONITOR_GENERATION_EXPLICIT_FLUSH = 2,
	FSMONITOR_GENERATION_DARWIN_KERNEL_DROPPED = 3,
	FSMONITOR_GENERATION_DARWIN_USER_DROPPED = 4,
	FSMONITOR_GENERATION_DARWIN_OUTSIDE_CONE = 5,
	FSMONITOR_GENERATION_DARWIN_WORKTREE_ROOT = 6,
	FSMONITOR_GENERATION_DARWIN_COOKIE_PREFIX = 7,
	FSMONITOR_GENERATION_WINDOWS_OVERFLOW = 8,
	FSMONITOR_GENERATION_CAUSE_NR,
};

enum fsmonitor_untracked_cache_result {
	FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED,
	FSMONITOR_UNTRACKED_CACHE_MISS,
	FSMONITOR_UNTRACKED_CACHE_HIT,
	FSMONITOR_UNTRACKED_CACHE_INVALID_SNAPSHOT,
};

enum fsmonitor_untracked_cache_save_mode {
	FSMONITOR_UNTRACKED_CACHE_SAVE_NORMAL,
	FSMONITOR_UNTRACKED_CACHE_SAVE_REPAIR,
	/* Preserve a snapshot that another command saved while this one ran. */
	FSMONITOR_UNTRACKED_CACHE_SAVE_IF_ABSENT,
};

enum fsmonitor_query_kind {
	/* The token came from the index and may advance history retention. */
	FSMONITOR_QUERY_INDEX,
	/* The token may be newer than the index; preserve its older history. */
	FSMONITOR_QUERY_AUXILIARY,
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
			      struct strbuf *answer,
			      enum fsmonitor_query_kind kind);

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
void fsmonitor_ipc__save_untracked_cache(
	struct index_state *istate, enum fsmonitor_untracked_cache_save_mode mode);

#endif /* FSMONITOR_IPC_H */

#ifndef GREP_INDEX_IPC_H
#define GREP_INDEX_IPC_H

struct grep_index_ipc_server;
struct grep_index_query;
struct object_id;
struct repository;

enum grep_index_ipc_result {
	GREP_INDEX_IPC_UNKNOWN,
	GREP_INDEX_IPC_IMPOSSIBLE,
	GREP_INDEX_IPC_MAYBE,
};

enum grep_index_ipc_worker_update_result {
	GREP_INDEX_IPC_WORKER_UPDATE_UNKNOWN = 1,
	GREP_INDEX_IPC_WORKER_UPDATE_NOT_SENT,
};

int grep_index_ipc_is_available(struct repository *repo);
int grep_index_ipc_workers_are_available(struct repository *repo);
int grep_index_ipc_query(struct repository *repo,
			 const struct grep_index_query *query,
			 const struct object_id *oids, size_t nr,
			 unsigned char *maybe);
int grep_index_ipc_query_index(struct repository *repo,
			       const struct grep_index_query *query,
			       unsigned char *maybe, size_t nr);
int grep_index_ipc_acquire_workers(struct repository *repo, int requested,
				   int held,
				   uint64_t *lease_id, int *granted);
/*
 * Returns 0 for an updated lease, GREP_INDEX_IPC_WORKER_UPDATE_UNKNOWN when
 * the daemon no longer knows the lease,
 * GREP_INDEX_IPC_WORKER_UPDATE_NOT_SENT when no request reached the daemon,
 * and -1 when the request outcome is ambiguous or invalid.
 */
int grep_index_ipc_update_workers(struct repository *repo, uint64_t lease_id,
				  int requested, int held, int *target);
void grep_index_ipc_release_workers(struct repository *repo,
				    uint64_t lease_id);

int grep_index_ipc_server_init(struct grep_index_ipc_server **server,
			       const char *gitdir, const char *path,
			       const char *worker_path,
			       int nr_threads);
void grep_index_ipc_server_start(struct grep_index_ipc_server *server);
void grep_index_ipc_server_stop(struct grep_index_ipc_server *server);
void grep_index_ipc_server_await(struct grep_index_ipc_server *server);
void grep_index_ipc_server_free(struct grep_index_ipc_server *server);

#endif

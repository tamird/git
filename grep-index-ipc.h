#ifndef GREP_INDEX_IPC_H
#define GREP_INDEX_IPC_H

#include "grep-index.h"

struct grep_index_ipc_server;
struct grep_index_query;
struct object_id;
struct repository;

#define GREP_INDEX_IPC_PREPARED_MIN_OIDS 4096
#define GREP_INDEX_IPC_MAX_CLIENT_THREADS 8

char *grep_index_ipc_path(struct repository *repo);
char *grep_index_ipc_worker_path(struct repository *repo);

enum grep_index_ipc_result {
	GREP_INDEX_IPC_UNKNOWN,
	GREP_INDEX_IPC_IMPOSSIBLE,
	GREP_INDEX_IPC_MAYBE,
};

enum grep_index_ipc_worker_update_result {
	GREP_INDEX_IPC_WORKER_UPDATE_UNKNOWN = 1,
	GREP_INDEX_IPC_WORKER_UPDATE_NOT_SENT,
};

/* Values are exposed by pickaxe Trace2 data. */
enum grep_index_ipc_availability_outcome {
	GREP_INDEX_IPC_AVAILABILITY_NOT_ATTEMPTED = 0,
	GREP_INDEX_IPC_AVAILABILITY_AVAILABLE = 1,
	GREP_INDEX_IPC_AVAILABILITY_UNSUPPORTED = 2,
	GREP_INDEX_IPC_AVAILABILITY_INVALID_PATH = 3,
	GREP_INDEX_IPC_AVAILABILITY_ENDPOINT_ERROR = 4,
	GREP_INDEX_IPC_AVAILABILITY_FSMONITOR_UNAVAILABLE = 5,
	GREP_INDEX_IPC_AVAILABILITY_START_SEND_FAILED = 6,
	GREP_INDEX_IPC_AVAILABILITY_START_READ_FAILED = 7,
	GREP_INDEX_IPC_AVAILABILITY_NO_LISTENER_AFTER_REQUEST = 8,
};

int grep_index_ipc_is_available(struct repository *repo);
int grep_index_ipc_is_available_with_outcome(
	struct repository *repo,
	enum grep_index_ipc_availability_outcome *outcome);
int grep_index_ipc_workers_are_available(struct repository *repo);
int grep_index_ipc_query(struct repository *repo,
			 const struct grep_index_query *query,
			 const struct object_id *oids, size_t nr,
			 unsigned char *maybe);
/*
 * Optional caller-owned diagnostics. Client endpoints use getnanotime();
 * server stage durations use the server's independent clock and are never
 * offsets in the client's clock domain.
 */
struct grep_index_ipc_server_trace {
	uint64_t pre_reply_ns, reply_write_ns, cleanup_ns;
	int available, timing_invalid;
};
struct grep_index_ipc_request_trace {
	uint64_t begin_ns, end_ns;
	size_t objects;
	int outcome;
	struct grep_index_ipc_server_trace server;
};

struct grep_index_ipc_query_trace {
	uint64_t probe_begin_ns, probe_end_ns;
	int probe_outcome;
	unsigned int probe_attempts, diagnostic_version;
	size_t requests_planned, requests_started;
	struct grep_index_ipc_request_trace requests[GREP_INDEX_IPC_MAX_CLIENT_THREADS];
	int query_available, backend_available;
	size_t unique_objects, requests_validated;
	size_t unknown, impossible, maybe;
	uint64_t persistent, ready_reused, cold_attempt;
	uint64_t unavailable_prebuild, waited;
};

int grep_index_ipc_query_with_max_parallel_requests(
	struct repository *repo, const struct grep_index_query *query,
	const struct object_id *oids, size_t nr, unsigned char *maybe,
	size_t max_parallel_requests, struct grep_index_ipc_query_trace *trace);
int grep_index_ipc_query_index(struct repository *repo,
			       const struct grep_index_query *query,
			       const struct object_id *index_identity,
			       unsigned char *maybe,
			       unsigned char *unresolved, size_t nr,
			       struct object_id *identity,
			       int *negative_cache_supported);
int grep_index_ipc_report_negatives(
	struct repository *repo,
	const struct grep_index_query *query,
	const struct object_id *identity,
	const unsigned char *negative, size_t nr);
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
/* Install only before start or after all server users have joined. */
void grep_index_ipc_server_set_build_observer_for_test(
	struct grep_index_ipc_server *server,
	grep_index_memory_build_observer_fn observer, void *data);
void grep_index_ipc_server_start(struct grep_index_ipc_server *server);
void grep_index_ipc_server_stop(struct grep_index_ipc_server *server);
void grep_index_ipc_server_await(struct grep_index_ipc_server *server);
void grep_index_ipc_server_free(struct grep_index_ipc_server *server);

#endif

#include "git-compat-util.h"
#include "grep-index-identity.h"
#include "grep-index-ipc.h"
#include "grep-index.h"
#include "fsmonitor-ipc.h"
#include "hash.h"
#include "parse.h"
#include "path.h"
#include "read-cache-ll.h"
#include "replace-object.h"
#include "repository.h"
#include "simple-ipc.h"
#include "strbuf.h"
#include "thread-utils.h"
#include "trace.h"
#include "trace2.h"
#include "wrapper.h"

#ifndef SUPPORTS_SIMPLE_IPC

int grep_index_ipc_is_available(struct repository *repo UNUSED)
{
	return 0;
}

int grep_index_ipc_workers_are_available(struct repository *repo UNUSED)
{
	return 0;
}

int grep_index_ipc_query(struct repository *repo UNUSED,
			 const struct grep_index_query *query UNUSED,
			 const struct object_id *oids UNUSED, size_t nr UNUSED,
			 unsigned char *maybe UNUSED)
{
	return -1;
}

int grep_index_ipc_query_index(struct repository *repo UNUSED,
			       const struct grep_index_query *query UNUSED,
			       unsigned char *maybe UNUSED,
			       unsigned char *unresolved UNUSED,
			       size_t nr UNUSED,
			       struct object_id *identity UNUSED,
			       int *negative_cache_supported UNUSED)
{
	return -1;
}

int grep_index_ipc_report_negatives(
	struct repository *repo UNUSED,
	const struct grep_index_query *query UNUSED,
	const struct object_id *identity UNUSED,
	const unsigned char *negative UNUSED, size_t nr UNUSED)
{
	return -1;
}

int grep_index_ipc_acquire_workers(struct repository *repo UNUSED,
				   int requested UNUSED,
				   int held UNUSED,
				   uint64_t *lease_id UNUSED,
				   int *granted UNUSED)
{
	return -1;
}

int grep_index_ipc_update_workers(struct repository *repo UNUSED,
				  uint64_t lease_id UNUSED,
				  int requested UNUSED,
				  int held UNUSED, int *target UNUSED)
{
	return -1;
}

void grep_index_ipc_release_workers(struct repository *repo UNUSED,
				    uint64_t lease_id UNUSED)
{
}

int grep_index_ipc_server_init(struct grep_index_ipc_server **server,
			       const char *gitdir UNUSED,
			       const char *path UNUSED,
			       const char *worker_path UNUSED,
			       int nr_threads UNUSED)
{
	*server = NULL;
	return -1;
}

void grep_index_ipc_server_start(struct grep_index_ipc_server *server UNUSED)
{
}

void grep_index_ipc_server_stop(struct grep_index_ipc_server *server UNUSED)
{
}

void grep_index_ipc_server_await(struct grep_index_ipc_server *server UNUSED)
{
}

void grep_index_ipc_server_free(struct grep_index_ipc_server *server UNUSED)
{
}

#else

# define GREP_INDEX_IPC_REQUEST_SIGNATURE    0x47495251
# define GREP_INDEX_IPC_RESPONSE_SIGNATURE   0x47495250
# define GREP_INDEX_IPC_INDEX_REQUEST_SIGNATURE  0x47494951
# define GREP_INDEX_IPC_INDEX_RESPONSE_SIGNATURE 0x47494950
# define GREP_INDEX_IPC_INDEX_CACHED_RESPONSE_SIGNATURE 0x47494943
# define GREP_INDEX_IPC_INDEX_OVERLAY_REQUEST_SIGNATURE 0x47494f51
# define GREP_INDEX_IPC_INDEX_MISSING_SIGNATURE  0x4749494d
# define GREP_INDEX_IPC_REGISTER_REQUEST_SIGNATURE  0x47495247
# define GREP_INDEX_IPC_REGISTER_RESPONSE_SIGNATURE 0x47495253
# define GREP_INDEX_IPC_NEGATIVE_REPORT_SIGNATURE 0x47494e52
# define GREP_INDEX_IPC_NEGATIVE_ACK_SIGNATURE    0x47494e41
# define GREP_INDEX_IPC_WORKER_ACQUIRE_SIGNATURE 0x47495741
# define GREP_INDEX_IPC_WORKER_UPDATE_SIGNATURE  0x47495752
# define GREP_INDEX_IPC_WORKER_RELEASE_SIGNATURE 0x4749574c
# define GREP_INDEX_IPC_WORKER_RESPONSE_SIGNATURE 0x47495750
# define GREP_INDEX_IPC_WORKER_UNKNOWN_RESPONSE_SIGNATURE 0x47495755
# define GREP_INDEX_IPC_WORKER_RELEASE_RESPONSE_SIGNATURE 0x47495758
# define GREP_INDEX_IPC_VERSION		     1
# define GREP_INDEX_IPC_REQUEST_HEADER_SIZE  (5 * sizeof(uint32_t))
# define GREP_INDEX_IPC_RESPONSE_HEADER_SIZE (3 * sizeof(uint32_t))
# define GREP_INDEX_IPC_CACHED_RESPONSE_HEADER_SIZE \
	(4 * sizeof(uint32_t))
# define GREP_INDEX_IPC_INDEX_REQUEST_HEADER_SIZE \
	(5 * sizeof(uint32_t))
# define GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE \
	(4 * sizeof(uint32_t))
# define GREP_INDEX_IPC_NEGATIVE_HEADER_SIZE \
	(4 * sizeof(uint32_t))
# define GREP_INDEX_IPC_MAX_CLIENT_THREADS   8
# define GREP_INDEX_IPC_MAX_SERVER_THREADS   8
# define GREP_INDEX_IPC_MIN_OIDS_PER_THREAD  4096
# define GREP_INDEX_IPC_PREPARED_MIN_OIDS    4096
# define GREP_INDEX_IPC_MAX_REQUEST_SIZE     (64 * 1024 * 1024)
# define GREP_INDEX_IPC_MAX_CACHED_INDEX_BYTES (256 * 1024 * 1024)
# define GREP_INDEX_IPC_WORKER_ACQUIRE_SIZE \
	(5 * sizeof(uint32_t) + sizeof(uint64_t))
# define GREP_INDEX_IPC_WORKER_UPDATE_SIZE \
	(5 * sizeof(uint32_t) + sizeof(uint64_t))
# define GREP_INDEX_IPC_WORKER_RELEASE_SIZE \
	(3 * sizeof(uint32_t) + sizeof(uint64_t))
# define GREP_INDEX_IPC_WORKER_RESPONSE_SIZE \
	(4 * sizeof(uint32_t) + sizeof(uint64_t))
# define GREP_INDEX_IPC_WORKER_RELEASE_RESPONSE_SIZE \
	(2 * sizeof(uint32_t) + sizeof(uint64_t))
# define GREP_INDEX_IPC_WORKER_LEASE_NS (1000ULL * 1000 * 1000)
# define GREP_INDEX_IPC_MAX_WORKER_LEASES    1024

enum grep_index_ipc_worker_request_result {
	GREP_INDEX_IPC_WORKER_REQUEST_AMBIGUOUS = -1,
	GREP_INDEX_IPC_WORKER_REQUEST_NOT_SENT = -2,
	GREP_INDEX_IPC_WORKER_REQUEST_PROTOCOL = -3,
};

struct grep_index_ipc_cached_negative {
	struct grep_index_ipc_cached_negative *next;
	struct object_id key;
	unsigned char *bitmap;
	size_t bytes;
};

struct grep_index_ipc_cached_index {
	struct grep_index_ipc_cached_index *next;
	struct grep_index_ipc_cached_negative *negatives;
	struct object_id identity;
	struct grep_index_location *locations;
	size_t nr;
	size_t bytes;
	size_t users;
};

struct grep_index_ipc_worker_lease {
	struct grep_index_ipc_worker_lease *next;
	uint64_t id;
	uint64_t last_seen;
	pid_t pid;
	uint32_t requested;
	uint32_t held;
	uint32_t target;
	uint32_t desired;
};

struct grep_index_ipc_server {
	struct repository repo;
	struct grep_index_memory *index;
	struct grep_index *persistent;
	struct grep_index_ipc_cached_index *indexes;
	struct grep_index_ipc_worker_lease *worker_leases;
	struct ipc_server_data *ipc;
	struct ipc_server_data *worker_ipc;
	pthread_mutex_t request_mutex;
	pthread_mutex_t index_mutex;
	pthread_mutex_t worker_mutex;
	pthread_rwlock_t generation_lock;
	size_t active_requests;
	size_t cached_index_bytes;
	uint32_t worker_capacity;
	int repo_initialized;
	int legacy_manifest_stat_valid;
	int transposed_manifest_stat_valid;
	char *path;
	char *worker_path;
	char *legacy_manifest_path;
	char *transposed_manifest_path;
	struct stat legacy_manifest_stat;
	struct stat transposed_manifest_stat;
};

struct grep_index_ipc_query_task {
	const char *path;
	const char *query;
	size_t query_len;
	const struct git_hash_algo *hash_algo;
	const struct object_id *oids;
	size_t nr;
	unsigned char *maybe;
	int result;
};

static void grep_index_ipc_put_u32(struct strbuf *buf, uint32_t value)
{
	char data[sizeof(uint32_t)];

	put_be32(data, value);
	strbuf_add(buf, data, sizeof(data));
}

static void grep_index_ipc_put_u64(struct strbuf *buf, uint64_t value)
{
	char data[sizeof(uint64_t)];

	put_be64(data, value);
	strbuf_add(buf, data, sizeof(data));
}

static char *grep_index_ipc_path(struct repository *repo)
{
	return repo_common_path(repo, "grep-index.ipc");
}

static char *grep_index_ipc_worker_path(struct repository *repo)
{
	return repo_common_path(repo, "grep-workers.ipc");
}

static int grep_index_ipc_path_is_available(const char *path)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	enum ipc_active_state state;

	options.uds_disallow_chdir = 1;
	state = ipc_client_try_connect(path, &options, &connection);
	ipc_client_close_connection(connection);
	return state == IPC_STATE__LISTENING;
}

static int grep_index_ipc_ensure_path(
	struct repository *repo, const char *path)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	struct strbuf response = STRBUF_INIT;
	int available = grep_index_ipc_path_is_available(path);

	if (!available) {
		options.wait_if_busy = 1;
		options.uds_disallow_chdir = 1;
		if (ipc_client_try_connect(
			    fsmonitor_ipc__get_path(repo), &options,
			    &connection) == IPC_STATE__LISTENING)
			ipc_client_send_command_to_connection_gently(
				connection, "start-grep-index", 16,
				&response);
		ipc_client_close_connection(connection);
		available = grep_index_ipc_path_is_available(path);
	}
	strbuf_release(&response);
	return available;
}

int grep_index_ipc_is_available(struct repository *repo)
{
	char *path = grep_index_ipc_path(repo);
	int available = grep_index_ipc_ensure_path(repo, path);

	free(path);
	return available;
}

int grep_index_ipc_workers_are_available(struct repository *repo)
{
	char *path = grep_index_ipc_worker_path(repo);
	int available = grep_index_ipc_ensure_path(repo, path);

	free(path);
	return available;
}

static void grep_index_ipc_cached_index_free(
	struct grep_index_ipc_cached_index *index)
{
	struct grep_index_ipc_cached_negative *negative;

	if (!index)
		return;
	while ((negative = index->negatives)) {
		index->negatives = negative->next;
		free(negative->bitmap);
		free(negative);
	}
	free(index->locations);
	free(index);
}

static struct grep_index_ipc_cached_negative *
grep_index_ipc_get_cached_negative(
	struct grep_index_ipc_cached_index *index,
	const struct object_id *key)
{
	struct grep_index_ipc_cached_negative **p = &index->negatives;

	while (*p) {
		struct grep_index_ipc_cached_negative *negative = *p;

		if (oideq(&negative->key, key)) {
			*p = negative->next;
			negative->next = index->negatives;
			index->negatives = negative;
			return negative;
		}
		p = &negative->next;
	}
	return NULL;
}

static struct grep_index_ipc_cached_index *
grep_index_ipc_get_cached_index(
	struct grep_index_ipc_server *server,
	const struct object_id *identity, size_t nr, int acquire)
{
	struct grep_index_ipc_cached_index **p = &server->indexes;
	struct grep_index_ipc_cached_index *cached = NULL;

	while (*p) {
		cached = *p;
		if (oideq(&cached->identity, identity) && cached->nr == nr) {
			*p = cached->next;
			cached->next = server->indexes;
			server->indexes = cached;
			if (acquire)
				cached->users++;
			return cached;
		}
		p = &cached->next;
	}
	return NULL;
}

static int grep_index_ipc_evict_one(struct grep_index_ipc_server *server)
{
	struct grep_index_ipc_cached_index **candidate = NULL;
	struct grep_index_ipc_cached_index **p = &server->indexes;
	struct grep_index_ipc_cached_index *negative_index = NULL;
	struct grep_index_ipc_cached_index *evicted;

	while (*p) {
		if ((*p)->negatives)
			negative_index = *p;
		if (!(*p)->users)
			candidate = p;
		p = &(*p)->next;
	}
	if (negative_index) {
		/*
		 * Location tables serve every query and are expensive to rebuild.
		 * Treat query-specific, recreatable results as a lower cache tier.
		 */
		struct grep_index_ipc_cached_negative **negative =
			&negative_index->negatives;
		struct grep_index_ipc_cached_negative *evicted_negative;

		while ((*negative)->next)
			negative = &(*negative)->next;
		evicted_negative = *negative;
		*negative = NULL;
		negative_index->bytes -= evicted_negative->bytes;
		server->cached_index_bytes -= evicted_negative->bytes;
		free(evicted_negative->bitmap);
		free(evicted_negative);
		return 1;
	}
	if (!candidate)
		return 0;
	evicted = *candidate;
	*candidate = evicted->next;
	server->cached_index_bytes -= evicted->bytes;
	grep_index_ipc_cached_index_free(evicted);
	return 1;
}

static void grep_index_ipc_trim_cached_indexes(
	struct grep_index_ipc_server *server)
{
	while (server->cached_index_bytes >
	       GREP_INDEX_IPC_MAX_CACHED_INDEX_BYTES)
		if (!grep_index_ipc_evict_one(server))
			break;
}

static void grep_index_ipc_clear_cached_indexes(
	struct grep_index_ipc_server *server)
{
	struct grep_index_ipc_cached_index *cached = NULL;

	while ((cached = server->indexes)) {
		server->indexes = cached->next;
		grep_index_ipc_cached_index_free(cached);
	}
	server->cached_index_bytes = 0;
}

static void grep_index_ipc_expire_worker_leases(
	struct grep_index_ipc_server *server, uint64_t now)
{
	struct grep_index_ipc_worker_lease **p = &server->worker_leases;

	while (*p) {
		struct grep_index_ipc_worker_lease *lease = *p;

		if (now < lease->last_seen ||
		    now - lease->last_seen <= GREP_INDEX_IPC_WORKER_LEASE_NS) {
			p = &lease->next;
			continue;
		}
		*p = lease->next;
		free(lease);
	}
}

static int grep_index_ipc_handle_worker_request(
	void *data,
	const char *request, size_t request_len,
	ipc_server_reply_cb *reply,
	struct ipc_server_reply_data *reply_data)
{
	struct grep_index_ipc_server *server = data;
	const unsigned char *raw = (const unsigned char *)request;
	struct grep_index_ipc_worker_lease **p;
	struct grep_index_ipc_worker_lease *lease = NULL;
	struct strbuf response = STRBUF_INIT;
	uint32_t signature;
	uint32_t active = 0;
	uint32_t target = 0;
	uint64_t now = getnanotime();
	uint64_t acquired_id = 0;
	uint64_t response_id = 0;
	int release_response = 0;
	int unknown_response = 0;
	int result = 0;

	if (request_len < sizeof(uint32_t))
		return 0;
	signature = get_be32(raw);
	pthread_mutex_lock(&server->worker_mutex);
	grep_index_ipc_expire_worker_leases(server, now);
	if (signature == GREP_INDEX_IPC_WORKER_ACQUIRE_SIGNATURE) {
		uint32_t active_leases = 0;
		uint32_t held;
		uint32_t pid;
		uint32_t requested;
		uint64_t id;

		if (request_len != GREP_INDEX_IPC_WORKER_ACQUIRE_SIZE ||
		    get_be32(raw + 4) != GREP_INDEX_IPC_VERSION)
			goto unlock;
		id = get_be64(raw + 8);
		requested = get_be32(raw + 16);
		held = get_be32(raw + 20);
		pid = get_be32(raw + 24);
		if (!id || !requested || requested > INT_MAX ||
		    held > requested || !pid || pid > INT_MAX)
			goto unlock;
		for (lease = server->worker_leases; lease;
		     lease = lease->next) {
			active_leases++;
			if (lease->id != id)
				continue;
			if (lease->requested != requested ||
			    lease->pid != (pid_t)pid)
				goto unlock;
			lease->held = held;
			lease->last_seen = now;
			response_id = lease->id;
			break;
		}
		if (response_id)
			goto allocate;
		if (active_leases >= GREP_INDEX_IPC_MAX_WORKER_LEASES)
			goto unlock;
		CALLOC_ARRAY(lease, 1);
		lease->id = id;
		lease->pid = pid;
		lease->requested = requested;
		lease->held = held;
		lease->last_seen = now;
		for (p = &server->worker_leases; *p; p = &(*p)->next)
			;
		*p = lease;
		acquired_id = lease->id;
		response_id = lease->id;
	} else if (signature == GREP_INDEX_IPC_WORKER_UPDATE_SIGNATURE) {
		uint64_t id;
		uint32_t held;
		uint32_t pid;
		uint32_t requested;

		if (request_len != GREP_INDEX_IPC_WORKER_UPDATE_SIZE ||
		    get_be32(raw + 4) != GREP_INDEX_IPC_VERSION)
			goto unlock;
		id = get_be64(raw + 8);
		requested = get_be32(raw + 16);
		held = get_be32(raw + 20);
		pid = get_be32(raw + 24);
		if (!requested || requested > INT_MAX ||
		    held > requested || !pid || pid > INT_MAX)
			goto unlock;
		for (p = &server->worker_leases; *p; p = &(*p)->next) {
			if ((*p)->id != id)
				continue;
			lease = *p;
			if (lease->pid != (pid_t)pid)
				goto unlock;
			lease->requested = requested;
			lease->held = held;
			lease->last_seen = now;
			response_id = lease->id;
			break;
		}
		if (!lease)
			unknown_response = 1;
	} else if (signature == GREP_INDEX_IPC_WORKER_RELEASE_SIGNATURE) {
		uint64_t id;
		uint32_t pid;

		if (request_len != GREP_INDEX_IPC_WORKER_RELEASE_SIZE ||
		    get_be32(raw + 4) != GREP_INDEX_IPC_VERSION)
			goto unlock;
		id = get_be64(raw + 8);
		pid = get_be32(raw + 16);
		if (!pid || pid > INT_MAX)
			goto unlock;
		for (p = &server->worker_leases; *p; p = &(*p)->next) {
			if ((*p)->id != id)
				continue;
			lease = *p;
			if (lease->pid != (pid_t)pid)
				goto unlock;
			*p = lease->next;
			response_id = lease->id;
			free(lease);
			lease = NULL;
			release_response = 1;
			break;
		}
	} else {
		goto unlock;
	}

allocate:
	{
		struct grep_index_ipc_worker_lease *candidate;
		uint64_t reserved = 0;
		uint32_t remaining = server->worker_capacity;
		int progress;

		for (candidate = server->worker_leases; candidate;
		     candidate = candidate->next) {
			candidate->desired = 0;
			active++;
		}
		do {
			progress = 0;
			for (candidate = server->worker_leases;
			     candidate && remaining;
			     candidate = candidate->next) {
				if (candidate->desired >= candidate->requested)
					continue;
				candidate->desired++;
				remaining--;
				progress = 1;
			}
		} while (remaining && progress);
		for (candidate = server->worker_leases; candidate;
		     candidate = candidate->next) {
			if (candidate->target > candidate->desired)
				candidate->target = candidate->desired;
			reserved += candidate->held > candidate->target ?
					    candidate->held :
					    candidate->target;
		}
		do {
			progress = 0;
			for (candidate = server->worker_leases;
			     candidate && reserved < server->worker_capacity;
			     candidate = candidate->next) {
				if (candidate->target >= candidate->desired)
					continue;
				candidate->target++;
				reserved++;
				progress = 1;
			}
		} while (reserved < server->worker_capacity && progress);
	}

	if (response_id && !release_response) {
		for (lease = server->worker_leases; lease;
		     lease = lease->next)
			if (lease->id == response_id)
				break;
		if (!lease)
			goto unlock;
		target = lease->target;
		if (lease->held < target)
			lease->held = target;
	}

unlock:
	pthread_mutex_unlock(&server->worker_mutex);
	if (release_response) {
		grep_index_ipc_put_u32(
			&response,
			GREP_INDEX_IPC_WORKER_RELEASE_RESPONSE_SIGNATURE);
		grep_index_ipc_put_u32(
			&response, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u64(&response, response_id);
		result = reply(reply_data, response.buf, response.len);
	} else if (unknown_response) {
		grep_index_ipc_put_u32(
			&response,
			GREP_INDEX_IPC_WORKER_UNKNOWN_RESPONSE_SIGNATURE);
		grep_index_ipc_put_u32(
			&response, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u64(
			&response, get_be64(raw + 8));
		result = reply(reply_data, response.buf, response.len);
	} else if (response_id) {
		grep_index_ipc_put_u32(
			&response, GREP_INDEX_IPC_WORKER_RESPONSE_SIGNATURE);
		grep_index_ipc_put_u32(
			&response, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u64(&response, response_id);
		grep_index_ipc_put_u32(&response, target);
		grep_index_ipc_put_u32(&response, active);
		result = reply(reply_data, response.buf, response.len);
	}
	if (result && acquired_id) {
		pthread_mutex_lock(&server->worker_mutex);
		for (p = &server->worker_leases; *p; p = &(*p)->next)
			if ((*p)->id == acquired_id) {
				lease = *p;
				*p = lease->next;
				free(lease);
				break;
			}
		pthread_mutex_unlock(&server->worker_mutex);
	}
	strbuf_release(&response);
	return result;
}

static int grep_index_ipc_stat_manifest(const char *path, struct stat *st)
{
	if (!stat(path, st))
		return 1;
	if (errno != ENOENT)
		trace2_data_string("grep-index", NULL,
				   "ipc_index/manifest_stat", path);
	memset(st, 0, sizeof(*st));
	return 0;
}

static int grep_index_ipc_manifest_stat_equal(
	int a_valid, const struct stat *a,
	int b_valid, const struct stat *b)
{
	return a_valid == b_valid &&
	       (!a_valid ||
		(a->st_dev == b->st_dev &&
		 a->st_ino == b->st_ino &&
		 a->st_size == b->st_size &&
		 a->st_mtime == b->st_mtime &&
		 ST_MTIME_NSEC(*a) == ST_MTIME_NSEC(*b) &&
		 a->st_ctime == b->st_ctime &&
		 ST_CTIME_NSEC(*a) == ST_CTIME_NSEC(*b)));
}

static int grep_index_ipc_generation_changed(
	struct grep_index_ipc_server *server,
	struct stat *legacy_stat, int *legacy_valid,
	struct stat *transposed_stat, int *transposed_valid)
{
	*legacy_valid = grep_index_ipc_stat_manifest(
		server->legacy_manifest_path, legacy_stat);
	*transposed_valid = grep_index_ipc_stat_manifest(
		server->transposed_manifest_path, transposed_stat);
	return !grep_index_ipc_manifest_stat_equal(
		       server->legacy_manifest_stat_valid,
		       &server->legacy_manifest_stat,
		       *legacy_valid, legacy_stat) ||
	       !grep_index_ipc_manifest_stat_equal(
		       server->transposed_manifest_stat_valid,
		       &server->transposed_manifest_stat,
		       *transposed_valid, transposed_stat);
}

static void grep_index_ipc_refresh_generation(
	struct grep_index_ipc_server *server)
{
	struct grep_index_memory *old_index;
	struct grep_index *old_persistent;
	struct grep_index *persistent;
	struct stat legacy_stat, transposed_stat;
	int legacy_valid, transposed_valid;
	int changed;

	pthread_rwlock_rdlock(&server->generation_lock);
	changed = grep_index_ipc_generation_changed(
		server, &legacy_stat, &legacy_valid,
		&transposed_stat, &transposed_valid);
	pthread_rwlock_unlock(&server->generation_lock);
	if (!changed)
		return;

	pthread_rwlock_wrlock(&server->generation_lock);
	if (!grep_index_ipc_generation_changed(
		    server, &legacy_stat, &legacy_valid,
		    &transposed_stat, &transposed_valid))
		goto unlock;

	persistent = grep_index_load(&server->repo);
	old_persistent = server->persistent;
	old_index = server->index;
	server->persistent = persistent;
	server->index = grep_index_memory_new(
		&server->repo, server->persistent);
	server->legacy_manifest_stat = legacy_stat;
	server->legacy_manifest_stat_valid = legacy_valid;
	server->transposed_manifest_stat = transposed_stat;
	server->transposed_manifest_stat_valid = transposed_valid;

	pthread_mutex_lock(&server->index_mutex);
	grep_index_ipc_clear_cached_indexes(server);
	pthread_mutex_unlock(&server->index_mutex);
	grep_index_memory_free(old_index);
	grep_index_free(old_persistent);
	trace2_data_string("grep-index", &server->repo,
			   "ipc_index/reload", "manifest-changed");

unlock:
	pthread_rwlock_unlock(&server->generation_lock);
}

static int grep_index_ipc_handle_register_request(
	struct grep_index_ipc_server *server,
	const char *request, size_t request_len,
	ipc_server_reply_cb *reply,
	struct ipc_server_reply_data *reply_data)
{
	struct grep_index_ipc_cached_index *cached = NULL;
	struct strbuf response = STRBUF_INIT;
	const unsigned char *raw = (const unsigned char *)request;
	const unsigned char *oid_data;
	struct git_hash_ctx ctx;
	struct object_id actual_identity;
	struct object_id identity;
	uint32_t version, format_id, nr;
	size_t rawsz = server->repo.hash_algo->rawsz;
	size_t locations_bytes;
	int result = 0;

	grep_index_ipc_refresh_generation(server);
	pthread_rwlock_rdlock(&server->generation_lock);
	if (!server->persistent ||
	    !grep_index_is_transposed(server->persistent) ||
	    request_len < GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE +
				  rawsz)
		goto cleanup;
	version = get_be32(raw + 4);
	format_id = get_be32(raw + 8);
	nr = get_be32(raw + 12);
	if (version != GREP_INDEX_IPC_VERSION ||
	    format_id != server->repo.hash_algo->format_id ||
	    !nr ||
	    nr > (request_len -
		  GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE - rawsz) /
			 rawsz ||
	    GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE + rawsz +
			    (size_t)nr * rawsz !=
		    request_len ||
	    nr > GREP_INDEX_IPC_MAX_CACHED_INDEX_BYTES /
			 sizeof(struct grep_index_location))
		goto cleanup;
	oidread(&identity,
		raw + GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE,
		server->repo.hash_algo);
	oid_data = raw + GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE +
		   rawsz;
	grep_index_identity_oid_sequence_init(
		&server->repo, &ctx, nr);
	git_hash_update(&ctx, oid_data, (size_t)nr * rawsz);
	git_hash_final_oid(&actual_identity, &ctx);
	if (!oideq(&actual_identity, &identity)) {
		trace2_data_string("grep-index", &server->repo,
				   "ipc_index/reject", "identity-mismatch");
		goto cleanup;
	}

	CALLOC_ARRAY(cached, 1);
	oidcpy(&cached->identity, &identity);
	cached->nr = nr;
	locations_bytes = st_mult(
		(size_t)nr, sizeof(struct grep_index_location));
	cached->bytes = st_add(sizeof(*cached), locations_bytes);
	CALLOC_ARRAY(cached->locations, nr);
	for (size_t i = 0; i < nr; i++) {
		struct object_id oid;

		oidread(&oid, oid_data + i * rawsz,
			server->repo.hash_algo);
		grep_index_resolve_location(
			server->persistent, &oid, &cached->locations[i]);
	}

	pthread_mutex_lock(&server->index_mutex);
	if (!grep_index_ipc_get_cached_index(
		    server, &identity, nr, 0)) {
		cached->next = server->indexes;
		server->indexes = cached;
		server->cached_index_bytes += cached->bytes;
		cached = NULL;
		grep_index_ipc_trim_cached_indexes(server);
	}
	pthread_mutex_unlock(&server->index_mutex);

	grep_index_ipc_put_u32(
		&response, GREP_INDEX_IPC_REGISTER_RESPONSE_SIGNATURE);
	grep_index_ipc_put_u32(&response, GREP_INDEX_IPC_VERSION);
	grep_index_ipc_put_u32(&response, nr);
	result = reply(reply_data, response.buf, response.len);

cleanup:
	pthread_rwlock_unlock(&server->generation_lock);
	grep_index_ipc_cached_index_free(cached);
	strbuf_release(&response);
	return result;
}

static int grep_index_ipc_handle_negative_request(
	struct grep_index_ipc_server *server,
	const char *request, size_t request_len,
	ipc_server_reply_cb *reply,
	struct ipc_server_reply_data *reply_data)
{
	struct grep_index_ipc_cached_index *cached;
	struct grep_index_ipc_cached_negative *negative;
	struct strbuf response = STRBUF_INIT;
	const unsigned char *raw = (const unsigned char *)request;
	struct object_id identity;
	struct object_id key;
	uint32_t signature, version, format_id, nr;
	size_t rawsz = server->repo.hash_algo->rawsz;
	size_t bitmap_size;
	size_t header_size = GREP_INDEX_IPC_NEGATIVE_HEADER_SIZE +
			     2 * rawsz;
	int result = 0;

	if (request_len < header_size)
		return 0;
	signature = get_be32(raw);
	version = get_be32(raw + 4);
	format_id = get_be32(raw + 8);
	nr = get_be32(raw + 12);
	if (signature != GREP_INDEX_IPC_NEGATIVE_REPORT_SIGNATURE ||
	    version != GREP_INDEX_IPC_VERSION ||
	    format_id != server->repo.hash_algo->format_id || !nr ||
	    nr > GREP_INDEX_IPC_MAX_CACHED_INDEX_BYTES /
			    sizeof(struct grep_index_location))
		return 0;
	bitmap_size = DIV_ROUND_UP((size_t)nr, 8);
	if (request_len != header_size + bitmap_size)
		return 0;
	oidread(&identity, raw + GREP_INDEX_IPC_NEGATIVE_HEADER_SIZE,
		server->repo.hash_algo);
	oidread(&key,
		raw + GREP_INDEX_IPC_NEGATIVE_HEADER_SIZE + rawsz,
		server->repo.hash_algo);

	pthread_mutex_lock(&server->index_mutex);
	cached = grep_index_ipc_get_cached_index(
		server, &identity, nr, 0);
	negative = cached ? grep_index_ipc_get_cached_negative(cached, &key) :
			    NULL;
	if (!cached) {
		grep_index_ipc_put_u32(
			&response, GREP_INDEX_IPC_INDEX_MISSING_SIGNATURE);
		grep_index_ipc_put_u32(&response, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u32(&response, nr);
		goto unlock;
	}
	{
		const unsigned char *bitmap = raw + header_size;
		int any = 0;

		for (size_t i = 0; i < bitmap_size; i++)
			if (bitmap[i]) {
				any = 1;
				break;
			}

		if (!negative && any) {
			CALLOC_ARRAY(negative, 1);
			oidcpy(&negative->key, &key);
			CALLOC_ARRAY(negative->bitmap, bitmap_size);
			negative->bytes = st_add(sizeof(*negative), bitmap_size);
			negative->next = cached->negatives;
			cached->negatives = negative;
			cached->bytes = st_add(cached->bytes, negative->bytes);
			server->cached_index_bytes = st_add(
				server->cached_index_bytes, negative->bytes);
		}
		if (negative)
			for (size_t i = 0; i < bitmap_size; i++)
				negative->bitmap[i] |= bitmap[i];
		grep_index_ipc_trim_cached_indexes(server);
	}
	grep_index_ipc_put_u32(
		&response, GREP_INDEX_IPC_NEGATIVE_ACK_SIGNATURE);
	grep_index_ipc_put_u32(&response, GREP_INDEX_IPC_VERSION);
	grep_index_ipc_put_u32(&response, nr);

unlock:
	pthread_mutex_unlock(&server->index_mutex);
	if (response.len)
		result = reply(reply_data, response.buf, response.len);
	strbuf_release(&response);
	return result;
}

static int grep_index_ipc_handle_index_request(
	struct grep_index_ipc_server *server,
	const char *request, size_t request_len,
	ipc_server_reply_cb *reply,
	struct ipc_server_reply_data *reply_data,
	int include_unresolved)
{
	struct grep_index_query *query = NULL;
	struct grep_index_prepared *prepared = NULL;
	struct grep_index_ipc_cached_index *cached = NULL;
	struct strbuf response = STRBUF_INIT;
	const unsigned char *raw = (const unsigned char *)request;
	const unsigned char *data;
	struct object_id identity;
	struct object_id key;
	uint32_t version, format_id, query_len, nr;
	size_t rawsz = server->repo.hash_algo->rawsz;
	size_t bitmap_size;
	size_t response_header_size;
	int cache_negatives;
	int result = 0;

	grep_index_ipc_refresh_generation(server);
	pthread_rwlock_rdlock(&server->generation_lock);
	if (!server->persistent ||
	    !grep_index_is_transposed(server->persistent) ||
	    request_len < GREP_INDEX_IPC_INDEX_REQUEST_HEADER_SIZE +
				  rawsz)
		goto cleanup;
	version = get_be32(raw + 4);
	format_id = get_be32(raw + 8);
	query_len = get_be32(raw + 12);
	nr = get_be32(raw + 16);
	cache_negatives =
		request_len == GREP_INDEX_IPC_INDEX_REQUEST_HEADER_SIZE +
				       2 * rawsz + query_len;
	if (version != GREP_INDEX_IPC_VERSION ||
	    format_id != server->repo.hash_algo->format_id ||
	    !nr ||
	    (!cache_negatives &&
	     request_len != GREP_INDEX_IPC_INDEX_REQUEST_HEADER_SIZE +
				    rawsz + query_len))
		goto cleanup;
	data = raw + GREP_INDEX_IPC_INDEX_REQUEST_HEADER_SIZE;
	oidread(&identity, data, server->repo.hash_algo);
	data += rawsz;
	if (cache_negatives) {
		oidread(&key, data, server->repo.hash_algo);
		data += rawsz;
	}
	query = grep_index_query_deserialize((const char *)data, query_len);
	if (!query)
		goto cleanup;

	pthread_mutex_lock(&server->index_mutex);
	cached = grep_index_ipc_get_cached_index(
		server, &identity, nr, 1);
	pthread_mutex_unlock(&server->index_mutex);
	if (!cached) {
		grep_index_ipc_put_u32(
			&response,
			GREP_INDEX_IPC_INDEX_MISSING_SIGNATURE);
		grep_index_ipc_put_u32(
			&response, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u32(&response, nr);
		result = reply(
			reply_data, response.buf, response.len);
		goto cleanup;
	}
	prepared = grep_index_prepare(server->persistent, query);
	if (!prepared)
		goto cleanup;
	bitmap_size = nr / 8 + !!(nr % 8);
	grep_index_ipc_put_u32(
		&response, cache_negatives ?
				   GREP_INDEX_IPC_INDEX_CACHED_RESPONSE_SIGNATURE :
				   GREP_INDEX_IPC_INDEX_RESPONSE_SIGNATURE);
	grep_index_ipc_put_u32(&response, GREP_INDEX_IPC_VERSION);
	grep_index_ipc_put_u32(&response, nr);
	if (cache_negatives)
		grep_index_ipc_put_u32(&response, 0);
	response_header_size = cache_negatives ?
				       GREP_INDEX_IPC_CACHED_RESPONSE_HEADER_SIZE :
				       GREP_INDEX_IPC_RESPONSE_HEADER_SIZE;
	strbuf_grow(&response, bitmap_size * (1 + include_unresolved));
	for (size_t i = 0; i < bitmap_size * (1 + include_unresolved); i++)
		strbuf_addch(&response, 0);
	for (size_t i = 0; i < nr; i++) {
		if (grep_index_prepared_location_maybe_contains(
			    prepared, &cached->locations[i]))
			response.buf[response_header_size +
				     i / 8] |=
				1u << (i & 7);
		if (include_unresolved && !cached->locations[i].valid)
			response.buf[response_header_size + bitmap_size +
				     i / 8] |=
				1u << (i & 7);
	}
	if (cache_negatives) {
		struct grep_index_ipc_cached_negative *negative;
		uint32_t hits = 0;

		pthread_mutex_lock(&server->index_mutex);
		negative = grep_index_ipc_get_cached_negative(cached, &key);
		if (negative) {
			unsigned char *bitmap =
				(unsigned char *)response.buf + response_header_size;
			unsigned char *unresolved = NULL;

			if (include_unresolved)
				unresolved = bitmap + bitmap_size;

			for (size_t i = 0; i < bitmap_size; i++) {
				unsigned char cleared = bitmap[i] &
							negative->bitmap[i];

				bitmap[i] &= ~negative->bitmap[i];
				if (unresolved)
					unresolved[i] &= ~negative->bitmap[i];
				while (cleared) {
					cleared &= cleared - 1;
					hits++;
				}
			}
		}
		pthread_mutex_unlock(&server->index_mutex);
		put_be32(response.buf + 3 * sizeof(uint32_t), hits);
	}
	result = reply(reply_data, response.buf, response.len);

cleanup:
	if (cached) {
		pthread_mutex_lock(&server->index_mutex);
		cached->users--;
		grep_index_ipc_trim_cached_indexes(server);
		pthread_mutex_unlock(&server->index_mutex);
	}
	pthread_rwlock_unlock(&server->generation_lock);
	grep_index_prepared_free(prepared);
	grep_index_query_free(query);
	strbuf_release(&response);
	return result;
}

static int grep_index_ipc_handle_request(
	void *data, const char *request, size_t request_len,
	ipc_server_reply_cb *reply, struct ipc_server_reply_data *reply_data)
{
	struct grep_index_ipc_server *server = data;
	struct grep_index_query *query = NULL;
	struct grep_index_prepared *prepared = NULL;
	struct strbuf response = STRBUF_INIT;
	const unsigned char *raw = (const unsigned char *)request;
	const unsigned char *oid_data;
	uint32_t signature, version, format_id, query_len, nr;
	size_t rawsz = server->repo.hash_algo->rawsz;
	size_t prepared_min_oids = git_env_ulong(
		"GIT_TEST_GREP_INDEX_IPC_PREPARED_MIN_OIDS",
		GREP_INDEX_IPC_PREPARED_MIN_OIDS);
	int use_prepared;
	int result = 0;

	if (request_len >= sizeof(uint32_t) &&
	    get_be32(request) ==
		    GREP_INDEX_IPC_INDEX_REQUEST_SIGNATURE)
		return grep_index_ipc_handle_index_request(
			server, request, request_len, reply, reply_data, 0);
	if (request_len >= sizeof(uint32_t) &&
	    get_be32(request) ==
		    GREP_INDEX_IPC_INDEX_OVERLAY_REQUEST_SIGNATURE)
		return grep_index_ipc_handle_index_request(
			server, request, request_len, reply, reply_data, 1);
	if (request_len >= sizeof(uint32_t) &&
	    get_be32(request) ==
		    GREP_INDEX_IPC_REGISTER_REQUEST_SIGNATURE)
		return grep_index_ipc_handle_register_request(
			server, request, request_len, reply, reply_data);
	if (request_len >= sizeof(uint32_t) &&
	    get_be32(request) == GREP_INDEX_IPC_NEGATIVE_REPORT_SIGNATURE)
		return grep_index_ipc_handle_negative_request(
			server, request, request_len, reply, reply_data);
	if (request_len < GREP_INDEX_IPC_REQUEST_HEADER_SIZE)
		return 0;
	signature = get_be32(raw);
	version = get_be32(raw + 4);
	format_id = get_be32(raw + 8);
	query_len = get_be32(raw + 12);
	nr = get_be32(raw + 16);
	if (signature != GREP_INDEX_IPC_REQUEST_SIGNATURE ||
	    version != GREP_INDEX_IPC_VERSION ||
	    format_id != server->repo.hash_algo->format_id ||
	    query_len > request_len - GREP_INDEX_IPC_REQUEST_HEADER_SIZE ||
	    nr > (request_len - GREP_INDEX_IPC_REQUEST_HEADER_SIZE -
		  query_len) /
			    rawsz ||
	    GREP_INDEX_IPC_REQUEST_HEADER_SIZE + query_len +
			    (size_t)nr * rawsz !=
		    request_len)
		return 0;

	query = grep_index_query_deserialize(
		request + GREP_INDEX_IPC_REQUEST_HEADER_SIZE, query_len);
	if (!query)
		return 0;
	oid_data = raw + GREP_INDEX_IPC_REQUEST_HEADER_SIZE + query_len;

	grep_index_ipc_refresh_generation(server);
	pthread_rwlock_rdlock(&server->generation_lock);
	pthread_mutex_lock(&server->request_mutex);
	server->active_requests++;
	pthread_mutex_unlock(&server->request_mutex);
	use_prepared =
		nr >= prepared_min_oids &&
		grep_index_is_transposed(server->persistent);

	grep_index_ipc_put_u32(&response,
			       GREP_INDEX_IPC_RESPONSE_SIGNATURE);
	grep_index_ipc_put_u32(&response, GREP_INDEX_IPC_VERSION);
	grep_index_ipc_put_u32(&response, nr);
	strbuf_grow(&response, nr);
	for (size_t i = 0; i < nr; i++) {
		struct grep_index_location location;
		struct object_id oid;
		int maybe;

		oidread(&oid, oid_data + i * rawsz, server->repo.hash_algo);
		if (use_prepared &&
		    !grep_index_resolve_location(
			    server->persistent, &oid, &location)) {
			if (!prepared)
				prepared = grep_index_prepare(
					server->persistent, query);
			maybe = grep_index_prepared_location_maybe_contains(
				prepared, &location);
		} else {
			maybe = grep_index_memory_maybe_contains(
				server->index, &oid, query);
		}
		strbuf_addch(&response,
			     maybe < 0 ? GREP_INDEX_IPC_UNKNOWN :
			     maybe     ? GREP_INDEX_IPC_MAYBE :
					 GREP_INDEX_IPC_IMPOSSIBLE);
	}
	trace2_data_intmax("grep-index", &server->repo,
			   "ipc_query/prepared", !!prepared);
	result = reply(reply_data, response.buf, response.len);
	pthread_mutex_lock(&server->request_mutex);
	if (!--server->active_requests)
		grep_index_memory_release_object_store(server->index);
	pthread_mutex_unlock(&server->request_mutex);
	grep_index_prepared_free(prepared);
	pthread_rwlock_unlock(&server->generation_lock);
	grep_index_query_free(query);
	strbuf_release(&response);
	return result;
}

int grep_index_ipc_server_init(struct grep_index_ipc_server **server_out,
			       const char *gitdir, const char *path,
			       const char *worker_path,
			       int nr_threads)
{
	struct grep_index_ipc_server *server;
	const char *test_capacity;
	struct ipc_server_opts opts = {
		.nr_threads = nr_threads > GREP_INDEX_IPC_MAX_SERVER_THREADS ?
				      GREP_INDEX_IPC_MAX_SERVER_THREADS :
				      nr_threads,
		.max_request_size = GREP_INDEX_IPC_MAX_REQUEST_SIZE,
		.uds_disallow_chdir = 1,
	};
	struct ipc_server_opts worker_opts = {
		.nr_threads = 2,
		.max_request_size = GREP_INDEX_IPC_WORKER_ACQUIRE_SIZE,
		.uds_disallow_chdir = 1,
	};
	int result;

	CALLOC_ARRAY(server, 1);
	if (repo_init(&server->repo, gitdir, NULL)) {
		free(server);
		*server_out = NULL;
		return -1;
	}
	server->repo_initialized = 1;
	server->path = xstrdup(path);
	server->worker_path = xstrdup(worker_path);
	server->legacy_manifest_path = repo_common_path(
		&server->repo, "objects/info/grep-index/chain");
	server->transposed_manifest_path = repo_common_path(
		&server->repo, "objects/info/grep-index/chain-transposed");
	pthread_mutex_init(&server->request_mutex, NULL);
	pthread_mutex_init(&server->index_mutex, NULL);
	pthread_mutex_init(&server->worker_mutex, NULL);
	pthread_rwlock_init(&server->generation_lock, NULL);
	server->worker_capacity = online_cpus();
	if (server->worker_capacity > UINT32_MAX / 2)
		server->worker_capacity = UINT32_MAX;
	else
		server->worker_capacity *= 2;
	if (!server->worker_capacity)
		server->worker_capacity = 1;
	test_capacity = getenv("GIT_TEST_GREP_WORKER_CAPACITY");
	if (test_capacity) {
		uintmax_t capacity;

		if (!git_parse_unsigned(
			    test_capacity, &capacity, UINT32_MAX) ||
		    !capacity)
			BUG("invalid GIT_TEST_GREP_WORKER_CAPACITY");
		server->worker_capacity = (uint32_t)capacity;
	}

	result = ipc_server_init_async(
		&server->ipc, server->path, &opts,
		grep_index_ipc_handle_request, server);
	if (result) {
		grep_index_ipc_server_free(server);
		*server_out = NULL;
		return result;
	}
	result = ipc_server_init_async(
		&server->worker_ipc, server->worker_path, &worker_opts,
		grep_index_ipc_handle_worker_request, server);
	if (result) {
		ipc_server_start_async(server->ipc);
		ipc_server_stop_async(server->ipc);
		ipc_server_await(server->ipc);
		grep_index_ipc_server_free(server);
		*server_out = NULL;
		return result;
	}
	server->legacy_manifest_stat_valid =
		grep_index_ipc_stat_manifest(
			server->legacy_manifest_path,
			&server->legacy_manifest_stat);
	server->transposed_manifest_stat_valid =
		grep_index_ipc_stat_manifest(
			server->transposed_manifest_path,
			&server->transposed_manifest_stat);
	server->persistent = grep_index_load(&server->repo);
	server->index = grep_index_memory_new(
		&server->repo, server->persistent);
	*server_out = server;
	return 0;
}

void grep_index_ipc_server_start(struct grep_index_ipc_server *server)
{
	if (server)
		ipc_server_start_async(server->worker_ipc);
	if (server)
		ipc_server_start_async(server->ipc);
}

void grep_index_ipc_server_stop(struct grep_index_ipc_server *server)
{
	if (server)
		ipc_server_stop_async(server->ipc);
	if (server)
		ipc_server_stop_async(server->worker_ipc);
}

void grep_index_ipc_server_await(struct grep_index_ipc_server *server)
{
	if (server)
		ipc_server_await(server->ipc);
	if (server)
		ipc_server_await(server->worker_ipc);
}

void grep_index_ipc_server_free(struct grep_index_ipc_server *server)
{
	if (!server)
		return;
	if (server->worker_ipc)
		ipc_server_free(server->worker_ipc);
	if (server->ipc)
		ipc_server_free(server->ipc);
	grep_index_ipc_clear_cached_indexes(server);
	grep_index_memory_free(server->index);
	grep_index_free(server->persistent);
	while (server->worker_leases) {
		struct grep_index_ipc_worker_lease *lease =
			server->worker_leases;

		server->worker_leases = lease->next;
		free(lease);
	}
	pthread_rwlock_destroy(&server->generation_lock);
	pthread_mutex_destroy(&server->worker_mutex);
	pthread_mutex_destroy(&server->index_mutex);
	pthread_mutex_destroy(&server->request_mutex);
	if (server->repo_initialized)
		repo_clear(&server->repo);
	free(server->transposed_manifest_path);
	free(server->legacy_manifest_path);
	free(server->worker_path);
	free(server->path);
	free(server);
}

static int grep_index_ipc_worker_request(
	struct repository *repo, uint32_t signature, uint64_t lease_id,
	uint32_t requested, uint32_t held,
	uint64_t *response_lease_id, int *granted,
	int *active)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	struct strbuf request = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;
	char *path = NULL;
	enum ipc_active_state state;
	int command_result;
	int result = GREP_INDEX_IPC_WORKER_REQUEST_NOT_SENT;

	if (signature == GREP_INDEX_IPC_WORKER_ACQUIRE_SIGNATURE) {
		if (!requested)
			return -1;
	} else if (!lease_id) {
		return -1;
	}

	grep_index_ipc_put_u32(&request, signature);
	grep_index_ipc_put_u32(&request, GREP_INDEX_IPC_VERSION);
	if (signature == GREP_INDEX_IPC_WORKER_ACQUIRE_SIGNATURE) {
		grep_index_ipc_put_u64(&request, lease_id);
		grep_index_ipc_put_u32(&request, requested);
		grep_index_ipc_put_u32(&request, held);
		grep_index_ipc_put_u32(&request, getpid());
	} else {
		grep_index_ipc_put_u64(&request, lease_id);
		if (signature == GREP_INDEX_IPC_WORKER_UPDATE_SIGNATURE) {
			grep_index_ipc_put_u32(&request, requested);
			grep_index_ipc_put_u32(&request, held);
		}
		grep_index_ipc_put_u32(&request, getpid());
	}

	path = grep_index_ipc_worker_path(repo);
	options.wait_if_busy =
		signature == GREP_INDEX_IPC_WORKER_ACQUIRE_SIGNATURE;
	options.uds_disallow_chdir = 1;
	state = ipc_client_try_connect(path, &options, &connection);
	if (state != IPC_STATE__LISTENING)
		goto cleanup;
	result = GREP_INDEX_IPC_WORKER_REQUEST_AMBIGUOUS;
	command_result = ipc_client_send_command_to_connection_gently(
		connection, request.buf, request.len, &response);
	if (command_result == IPC_CLIENT_COMMAND_ERROR_SEND) {
		result = GREP_INDEX_IPC_WORKER_REQUEST_NOT_SENT;
		goto cleanup;
	}
	if (command_result)
		goto cleanup;
	result = GREP_INDEX_IPC_WORKER_REQUEST_PROTOCOL;
	if (signature == GREP_INDEX_IPC_WORKER_RELEASE_SIGNATURE) {
		if (response.len !=
			    GREP_INDEX_IPC_WORKER_RELEASE_RESPONSE_SIZE ||
		    get_be32(response.buf) !=
			    GREP_INDEX_IPC_WORKER_RELEASE_RESPONSE_SIGNATURE ||
		    get_be32(response.buf + 4) != GREP_INDEX_IPC_VERSION ||
		    get_be64(response.buf + 8) != lease_id)
			goto cleanup;
		result = 0;
		goto cleanup;
	}
	if (signature == GREP_INDEX_IPC_WORKER_UPDATE_SIGNATURE &&
	    response.len == GREP_INDEX_IPC_WORKER_RELEASE_RESPONSE_SIZE &&
	    get_be32(response.buf) ==
		    GREP_INDEX_IPC_WORKER_UNKNOWN_RESPONSE_SIGNATURE &&
	    get_be32(response.buf + 4) == GREP_INDEX_IPC_VERSION &&
	    get_be64(response.buf + 8) == lease_id) {
		result = 1;
		goto cleanup;
	}
	if (response.len != GREP_INDEX_IPC_WORKER_RESPONSE_SIZE ||
	    get_be32(response.buf) !=
		    GREP_INDEX_IPC_WORKER_RESPONSE_SIGNATURE ||
	    get_be32(response.buf + 4) != GREP_INDEX_IPC_VERSION ||
	    !get_be64(response.buf + 8) ||
	    get_be64(response.buf + 8) != lease_id ||
	    get_be32(response.buf + 16) > INT_MAX ||
	    get_be32(response.buf + 20) > INT_MAX)
		goto cleanup;
	*response_lease_id = get_be64(response.buf + 8);
	*granted = get_be32(response.buf + 16);
	if (active)
		*active = get_be32(response.buf + 20);
	result = 0;

cleanup:
	ipc_client_close_connection(connection);
	free(path);
	strbuf_release(&response);
	strbuf_release(&request);
	return result;
}

int grep_index_ipc_acquire_workers(struct repository *repo, int requested,
				   int held,
				   uint64_t *lease_id, int *granted)
{
	uint64_t response_lease_id;
	uint64_t request_lease_id;
	int active;
	int result = GREP_INDEX_IPC_WORKER_REQUEST_NOT_SENT;

	if (requested < 1 || held < 0 || held > requested ||
	    !grep_index_ipc_workers_are_available(repo))
		return -1;
	do {
		if (csprng_bytes(
			    &request_lease_id, sizeof(request_lease_id), 0))
			return -1;
	} while (!request_lease_id);
	for (int attempt = 0; attempt < 2; attempt++) {
		result = grep_index_ipc_worker_request(
			repo, GREP_INDEX_IPC_WORKER_ACQUIRE_SIGNATURE,
			request_lease_id, requested, held,
			&response_lease_id, granted, &active);
		if (!result)
			goto acquired;
		if (result != GREP_INDEX_IPC_WORKER_REQUEST_NOT_SENT)
			break;
	}
	if (result != GREP_INDEX_IPC_WORKER_REQUEST_AMBIGUOUS)
		return -1;
	*lease_id = request_lease_id;
	*granted = 0;
	trace2_data_intmax(
		"grep", repo, "worker_lease/pending", 1);
	return 0;

acquired:
	*lease_id = response_lease_id;
	trace2_data_intmax("grep", repo, "worker_lease/requested",
			   requested);
	trace2_data_intmax("grep", repo, "worker_lease/granted",
			   *granted);
	trace2_data_intmax("grep", repo, "worker_lease/active",
			   active);
	return 0;
}

int grep_index_ipc_update_workers(struct repository *repo, uint64_t lease_id,
				  int requested, int held, int *target)
{
	uint64_t response_lease_id;
	int result;

	if (requested < 1 || held < 0 || held > requested)
		return -1;
	result = grep_index_ipc_worker_request(
		repo, GREP_INDEX_IPC_WORKER_UPDATE_SIGNATURE,
		lease_id, requested, held,
		&response_lease_id, target, NULL);
	if (result == GREP_INDEX_IPC_WORKER_REQUEST_NOT_SENT)
		return GREP_INDEX_IPC_WORKER_UPDATE_NOT_SENT;
	return result > 0 ? GREP_INDEX_IPC_WORKER_UPDATE_UNKNOWN :
	       result < 0 ? -1 : 0;
}

void grep_index_ipc_release_workers(struct repository *repo,
				    uint64_t lease_id)
{
	uint64_t response_lease_id;
	int granted;

	if (!grep_index_ipc_worker_request(
		    repo, GREP_INDEX_IPC_WORKER_RELEASE_SIGNATURE,
		    lease_id, 0, 0, &response_lease_id, &granted, NULL))
		trace2_data_intmax(
			"grep", repo, "worker_lease/released", 1);
}

static void *grep_index_ipc_query_thread(void *data)
{
	struct grep_index_ipc_query_task *task = data;
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	struct strbuf request = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;
	enum ipc_active_state state;
	size_t rawsz = task->hash_algo->rawsz;

	task->result = -1;
	if (task->query_len > GREP_INDEX_IPC_MAX_REQUEST_SIZE -
				      GREP_INDEX_IPC_REQUEST_HEADER_SIZE ||
	    task->nr >
		    (GREP_INDEX_IPC_MAX_REQUEST_SIZE -
		     GREP_INDEX_IPC_REQUEST_HEADER_SIZE - task->query_len) /
			    rawsz)
		return NULL;
	grep_index_ipc_put_u32(&request,
			       GREP_INDEX_IPC_REQUEST_SIGNATURE);
	grep_index_ipc_put_u32(&request, GREP_INDEX_IPC_VERSION);
	grep_index_ipc_put_u32(&request, task->hash_algo->format_id);
	grep_index_ipc_put_u32(&request, task->query_len);
	grep_index_ipc_put_u32(&request, task->nr);
	strbuf_add(&request, task->query, task->query_len);
	for (size_t i = 0; i < task->nr; i++)
		strbuf_add(&request, task->oids[i].hash, rawsz);

	options.wait_if_busy = 1;
	options.uds_disallow_chdir = 1;
	state = ipc_client_try_connect(task->path, &options, &connection);
	if (state != IPC_STATE__LISTENING)
		goto cleanup;
	if (ipc_client_send_command_to_connection_gently(
		    connection, request.buf, request.len, &response))
		goto cleanup;
	if (response.len != GREP_INDEX_IPC_RESPONSE_HEADER_SIZE + task->nr ||
	    get_be32(response.buf) != GREP_INDEX_IPC_RESPONSE_SIGNATURE ||
	    get_be32(response.buf + 4) != GREP_INDEX_IPC_VERSION ||
	    get_be32(response.buf + 8) != task->nr)
		goto cleanup;
	for (size_t i = 0; i < task->nr; i++) {
		unsigned char value =
			response.buf[GREP_INDEX_IPC_RESPONSE_HEADER_SIZE + i];

		if (value > GREP_INDEX_IPC_MAYBE)
			goto cleanup;
		task->maybe[i] = value;
	}
	task->result = 0;

cleanup:
	ipc_client_close_connection(connection);
	strbuf_release(&response);
	strbuf_release(&request);
	return NULL;
}

int grep_index_ipc_query(struct repository *repo,
			 const struct grep_index_query *query,
			 const struct object_id *oids, size_t nr,
			 unsigned char *maybe)
{
	struct strbuf serialized = STRBUF_INIT;
	char *path = NULL;
	struct grep_index_ipc_query_task *tasks = NULL;
	pthread_t *threads = NULL;
	size_t threads_nr = 1;
	size_t started = 0;
	int cpus;
	int result = -1;

	if (!nr)
		return 0;
	path = grep_index_ipc_path(repo);
	if (!query || nr > UINT32_MAX ||
	    grep_index_query_serialize(query, &serialized) ||
	    serialized.len > UINT32_MAX)
		goto cleanup;
	if (replace_refs_enabled(repo)) {
		prepare_replace_object(repo);
		if (oidmap_get_size(&repo->objects->replace_map))
			goto cleanup;
	}

	if (nr >= 2 * GREP_INDEX_IPC_MIN_OIDS_PER_THREAD) {
		threads_nr = DIV_ROUND_UP(
			nr, GREP_INDEX_IPC_MIN_OIDS_PER_THREAD);
		if (threads_nr > GREP_INDEX_IPC_MAX_CLIENT_THREADS)
			threads_nr = GREP_INDEX_IPC_MAX_CLIENT_THREADS;
		cpus = online_cpus();
		if (cpus > 0 && threads_nr > (size_t)cpus)
			threads_nr = cpus;
	}
	CALLOC_ARRAY(tasks, threads_nr);
	for (size_t i = 0, pos = 0; i < threads_nr; i++) {
		size_t remaining = nr - pos;
		size_t task_nr = DIV_ROUND_UP(remaining, threads_nr - i);

		tasks[i].path = path;
		tasks[i].query = serialized.buf;
		tasks[i].query_len = serialized.len;
		tasks[i].hash_algo = repo->hash_algo;
		tasks[i].oids = oids + pos;
		tasks[i].nr = task_nr;
		tasks[i].maybe = maybe + pos;
		pos += task_nr;
	}
	if (threads_nr == 1) {
		grep_index_ipc_query_thread(&tasks[0]);
		if (!tasks[0].result)
			result = 0;
		goto cleanup;
	}
	ALLOC_ARRAY(threads, threads_nr);
	for (size_t i = 0; i < threads_nr; i++) {
		if (pthread_create(&threads[i], NULL,
				   grep_index_ipc_query_thread, &tasks[i]))
			goto join;
		started++;
	}

join:
	for (size_t i = 0; i < started; i++)
		pthread_join(threads[i], NULL);
	if (started != threads_nr)
		goto cleanup;
	for (size_t i = 0; i < threads_nr; i++)
		if (tasks[i].result)
			goto cleanup;
	result = 0;

cleanup:
	free(threads);
	free(tasks);
	free(path);
	strbuf_release(&serialized);
	return result;
}

static int grep_index_ipc_negative_report(
	struct repository *repo, const char *path,
	const struct object_id *index_identity,
	const struct object_id *key, const unsigned char *bitmap,
	size_t nr)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	struct strbuf request = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;
	enum ipc_active_state state;
	size_t rawsz = repo->hash_algo->rawsz;
	size_t bitmap_size = DIV_ROUND_UP(nr, 8);
	size_t request_size = GREP_INDEX_IPC_NEGATIVE_HEADER_SIZE +
			      2 * rawsz + bitmap_size;
	int result = -1;

	if (!key || !nr || nr > UINT32_MAX ||
	    request_size > GREP_INDEX_IPC_MAX_REQUEST_SIZE)
		goto cleanup;
	grep_index_ipc_put_u32(
		&request, GREP_INDEX_IPC_NEGATIVE_REPORT_SIGNATURE);
	grep_index_ipc_put_u32(&request, GREP_INDEX_IPC_VERSION);
	grep_index_ipc_put_u32(&request, repo->hash_algo->format_id);
	grep_index_ipc_put_u32(&request, nr);
	strbuf_add(&request, index_identity->hash, rawsz);
	strbuf_add(&request, key->hash, rawsz);
	strbuf_add(&request, bitmap, bitmap_size);

	options.wait_if_busy = 1;
	options.uds_disallow_chdir = 1;
	state = ipc_client_try_connect(path, &options, &connection);
	if (state != IPC_STATE__LISTENING ||
	    ipc_client_send_command_to_connection_gently(
		    connection, request.buf, request.len, &response))
		goto cleanup;
	if (response.len != GREP_INDEX_IPC_RESPONSE_HEADER_SIZE ||
	    get_be32(response.buf) != GREP_INDEX_IPC_NEGATIVE_ACK_SIGNATURE ||
	    get_be32(response.buf + 4) != GREP_INDEX_IPC_VERSION ||
	    get_be32(response.buf + 8) != nr)
		goto cleanup;
	result = 0;

cleanup:
	ipc_client_close_connection(connection);
	strbuf_release(&response);
	strbuf_release(&request);
	return result;
}

int grep_index_ipc_query_index(struct repository *repo,
			       const struct grep_index_query *query,
			       unsigned char *maybe,
			       unsigned char *unresolved, size_t nr,
			       struct object_id *result_identity,
			       int *negative_cache_supported)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	struct strbuf serialized = STRBUF_INIT;
	struct strbuf request = STRBUF_INIT;
	struct strbuf registration = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;
	char *path = NULL;
	enum ipc_active_state state;
	size_t bitmap_size = nr / 8 + !!(nr % 8);
	size_t rawsz = repo->hash_algo->rawsz;
	size_t request_len = GREP_INDEX_IPC_INDEX_REQUEST_HEADER_SIZE;
	struct grep_index_identity index_identity;
	struct object_id identity;
	const struct object_id *cache_key =
		grep_index_query_cache_key(query);
	int cache_request = !!cache_key;
	int overlay_request = !!unresolved;
	int registered = 0;
	int result = -1;

	if (negative_cache_supported)
		*negative_cache_supported = 0;
	if (unresolved)
		memset(unresolved, 0, bitmap_size);

	if (!query || !repo->index || nr != repo->index->cache_nr ||
	    !nr || nr > UINT32_MAX ||
	    grep_index_query_serialize(query, &serialized) ||
	    serialized.len > UINT32_MAX)
		goto cleanup;
	if (replace_refs_enabled(repo)) {
		prepare_replace_object(repo);
		if (oidmap_get_size(&repo->objects->replace_map))
		goto cleanup;
	}
	if (grep_index_identity_get(repo, repo->index, &index_identity))
		goto cleanup;
	oidcpy(&identity, &index_identity.oid_sequence);
	path = grep_index_ipc_path(repo);
	if (rawsz * (1 + !!cache_key) >
	    GREP_INDEX_IPC_MAX_REQUEST_SIZE - request_len)
		goto cleanup;
	request_len += rawsz * (1 + !!cache_key);
	if (serialized.len > GREP_INDEX_IPC_MAX_REQUEST_SIZE - request_len)
		goto cleanup;

	options.wait_if_busy = 1;
	options.uds_disallow_chdir = 1;
	/* Overlay request, legacy fallback, and post-registration retry. */
	for (int attempt = 0; attempt < 4; attempt++) {
		size_t response_header_size = cache_request ?
						      GREP_INDEX_IPC_CACHED_RESPONSE_HEADER_SIZE :
						      GREP_INDEX_IPC_RESPONSE_HEADER_SIZE;
		uint32_t response_signature = cache_request ?
						      GREP_INDEX_IPC_INDEX_CACHED_RESPONSE_SIGNATURE :
						      GREP_INDEX_IPC_INDEX_RESPONSE_SIGNATURE;
		size_t response_size = response_header_size +
				       bitmap_size * (1 + overlay_request);

		strbuf_reset(&request);
		strbuf_reset(&response);
		grep_index_ipc_put_u32(
			&request, overlay_request ?
					  GREP_INDEX_IPC_INDEX_OVERLAY_REQUEST_SIGNATURE :
					  GREP_INDEX_IPC_INDEX_REQUEST_SIGNATURE);
		grep_index_ipc_put_u32(&request, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u32(
			&request, repo->hash_algo->format_id);
		grep_index_ipc_put_u32(&request, serialized.len);
		grep_index_ipc_put_u32(&request, nr);
		strbuf_add(&request, identity.hash, rawsz);
		if (cache_request)
			strbuf_add(&request, cache_key->hash, rawsz);
		strbuf_addbuf(&request, &serialized);

		state = ipc_client_try_connect(
			path, &options, &connection);
		if (state != IPC_STATE__LISTENING)
			goto cleanup;
		if (ipc_client_send_command_to_connection_gently(
			    connection, request.buf, request.len,
			    &response))
			goto cleanup;
		ipc_client_close_connection(connection);
		connection = NULL;
		if (response.len == response_size &&
		    get_be32(response.buf) == response_signature &&
		    get_be32(response.buf + 4) ==
			    GREP_INDEX_IPC_VERSION &&
		    get_be32(response.buf + 8) == nr) {
			memcpy(maybe,
			       response.buf + response_header_size,
			       bitmap_size);
			if (overlay_request) {
				const unsigned char *unresolved_response =
					(const unsigned char *)response.buf +
					response_header_size + bitmap_size;

				for (size_t i = 0; i < bitmap_size; i++) {
					unresolved[i] = unresolved_response[i];
					/* Preserve candidates if the bitmaps disagree. */
					maybe[i] |= unresolved[i];
				}
			}
			if (cache_request) {
				trace2_data_intmax(
					"grep", repo,
					"content_index_negative_cache_hits",
					get_be32(response.buf + 12));
				if (negative_cache_supported)
					*negative_cache_supported = 1;
			}
			if (result_identity)
				oidcpy(result_identity, &identity);
			result = 0;
			break;
		}
		if (response.len != GREP_INDEX_IPC_RESPONSE_HEADER_SIZE ||
		    get_be32(response.buf) !=
			    GREP_INDEX_IPC_INDEX_MISSING_SIGNATURE ||
		    get_be32(response.buf + 4) !=
			    GREP_INDEX_IPC_VERSION ||
		    get_be32(response.buf + 8) != nr) {
			if (overlay_request) {
				overlay_request = 0;
				continue;
			}
			if (cache_request) {
				/* A running older daemon expects the original layout. */
				cache_request = 0;
				continue;
			}
			goto cleanup;
		}
		if (registered ||
		    nr > (GREP_INDEX_IPC_MAX_REQUEST_SIZE -
			  GREP_INDEX_IPC_REGISTER_REQUEST_HEADER_SIZE -
			  rawsz) /
				    rawsz)
			goto cleanup;

		grep_index_ipc_put_u32(
			&registration,
			GREP_INDEX_IPC_REGISTER_REQUEST_SIGNATURE);
		grep_index_ipc_put_u32(
			&registration, GREP_INDEX_IPC_VERSION);
		grep_index_ipc_put_u32(
			&registration, repo->hash_algo->format_id);
		grep_index_ipc_put_u32(&registration, nr);
		strbuf_add(&registration, identity.hash, rawsz);
		for (size_t i = 0; i < nr; i++)
			strbuf_add(&registration,
				   repo->index->cache[i]->oid.hash,
				   rawsz);
		strbuf_reset(&response);
		state = ipc_client_try_connect(
			path, &options, &connection);
		if (state != IPC_STATE__LISTENING)
			goto cleanup;
		if (ipc_client_send_command_to_connection_gently(
			    connection, registration.buf,
			    registration.len, &response))
			goto cleanup;
		ipc_client_close_connection(connection);
		connection = NULL;
		if (response.len != GREP_INDEX_IPC_RESPONSE_HEADER_SIZE ||
		    get_be32(response.buf) !=
			    GREP_INDEX_IPC_REGISTER_RESPONSE_SIGNATURE ||
		    get_be32(response.buf + 4) !=
			    GREP_INDEX_IPC_VERSION ||
		    get_be32(response.buf + 8) != nr)
			goto cleanup;
		registered = 1;
	}

cleanup:
	ipc_client_close_connection(connection);
	free(path);
	strbuf_release(&response);
	strbuf_release(&registration);
	strbuf_release(&request);
	strbuf_release(&serialized);
	return result;
}

int grep_index_ipc_report_negatives(
	struct repository *repo,
	const struct grep_index_query *query,
	const struct object_id *identity,
	const unsigned char *negative, size_t nr)
{
	const struct object_id *key = grep_index_query_cache_key(query);
	char *path;
	int result;

	if (!key || !identity || !nr)
		return -1;
	path = grep_index_ipc_path(repo);
	result = grep_index_ipc_negative_report(
		repo, path, identity, key, negative, nr);
	free(path);
	return result;
}

#endif

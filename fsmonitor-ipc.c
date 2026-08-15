#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "abspath.h"
#include "dir.h"
#include "fsmonitor-ll.h"
#include "fsmonitor-settings.h"
#include "gettext.h"
#include "git-zlib.h"
#include "hash.h"
#include "hex.h"
#include "object.h"
#include "parse.h"
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
fsmonitor_ipc__restore_untracked_cache(struct index_state *istate UNUSED,
				       const char **restore_reason)
{
	*restore_reason = "backend-unavailable";
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

static const struct object_id *untracked_cache_index_oid(
	struct index_state *istate, struct object_id *identity)
{
	if (!is_null_oid(&istate->oid))
		return &istate->oid;
	if (istate->index_file_identity_valid)
		return is_null_oid(&istate->index_file_identity) ?
			NULL : &istate->index_file_identity;

#ifdef NO_NSEC
	(void)identity;
	return NULL;
#else
	{
		static const char domain[] = "fsmonitor-untracked-index-v1";
		const struct stat *saved = &istate->index_file_stat;
		struct stat current;
		struct git_hash_ctx ctx;
		unsigned char stable[7 * sizeof(uint64_t)];

		if (!fstat_is_reliable() ||
		    !istate->index_file_fd_valid ||
		    !istate->index_file_stat_valid ||
		    !saved->st_dev || !saved->st_ino || saved->st_size <= 0 ||
		    fstat(istate->index_file_fd, &current) ||
		    current.st_dev != saved->st_dev ||
		    current.st_ino != saved->st_ino ||
		    current.st_size != saved->st_size ||
		    current.st_ctime != saved->st_ctime ||
		    ST_CTIME_NSEC(current) != ST_CTIME_NSEC(*saved) ||
		    current.st_mtime != saved->st_mtime ||
		    ST_MTIME_NSEC(current) != ST_MTIME_NSEC(*saved))
			return NULL;

		put_be64(stable, (uint64_t)saved->st_dev);
		put_be64(stable + sizeof(uint64_t), (uint64_t)saved->st_ino);
		put_be64(stable + 2 * sizeof(uint64_t),
			 (uint64_t)saved->st_size);
		put_be64(stable + 3 * sizeof(uint64_t),
			 (uint64_t)saved->st_ctime);
		put_be64(stable + 4 * sizeof(uint64_t),
			 (uint64_t)ST_CTIME_NSEC(*saved));
		put_be64(stable + 5 * sizeof(uint64_t),
			 (uint64_t)saved->st_mtime);
		put_be64(stable + 6 * sizeof(uint64_t),
			 (uint64_t)ST_MTIME_NSEC(*saved));
		git_hash_init(&ctx, istate->repo->hash_algo);
		git_hash_update(&ctx, domain, sizeof(domain) - 1);
		git_hash_update(&ctx, stable, sizeof(stable));
		git_hash_final_oid(identity, &ctx);
		return is_null_oid(identity) ? NULL : identity;
	}
#endif
}

/* Existing daemons keep snapshot bytes opaque and enforce the wire limit. */
#define FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC "\0UCZ1"
#define FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN \
	(sizeof(FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC) - 1)
#define FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN \
	(FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN + sizeof(uint32_t))
#define FSMONITOR_IPC_UNCOMPRESSED_CACHE_MAX \
	(8 * FSMONITOR_IPC_UNTRACKED_CACHE_MAX)
#define FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC "\0UCF1"
#define FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN \
	(sizeof(FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC) - 1)
#define FSMONITOR_IPC_TRACKED_SNAPSHOT_HEADER_LEN \
	(FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN + 2 * sizeof(uint32_t))

static int tracked_snapshot_entry_is_eligible(const struct cache_entry *ce)
{
	return !(ce->ce_flags & CE_REMOVE) && !ce_stage(ce) &&
		!S_ISGITLINK(ce->ce_mode) && !S_ISSPARSEDIR(ce->ce_mode);
}

static int add_tracked_snapshot(struct index_state *istate,
				struct strbuf *snapshot)
{
	struct strbuf wrapped = STRBUF_INIT;
	size_t bitmap_len, header_len;

	if (istate->split_index || !istate->cache_nr)
		return 0;
	if (snapshot->len > UINT32_MAX)
		return -1;

	bitmap_len = ((size_t)istate->cache_nr + 7) / 8;
	header_len = FSMONITOR_IPC_TRACKED_SNAPSHOT_HEADER_LEN;
	if (snapshot->len > FSMONITOR_IPC_UNCOMPRESSED_CACHE_MAX - header_len ||
	    bitmap_len > FSMONITOR_IPC_UNCOMPRESSED_CACHE_MAX - header_len -
			 snapshot->len)
		return -1;

	strbuf_add(&wrapped, FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC,
		   FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN);
	strbuf_addchars(&wrapped, '\0', 2 * sizeof(uint32_t));
	put_be32(wrapped.buf + FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN,
		 istate->cache_nr);
	put_be32(wrapped.buf + FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN +
		 sizeof(uint32_t), snapshot->len);
	strbuf_addbuf(&wrapped, snapshot);
	strbuf_addchars(&wrapped, '\0', bitmap_len);

	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];

		if ((ce->ce_flags & CE_FSMONITOR_VALID) &&
		    tracked_snapshot_entry_is_eligible(ce))
			wrapped.buf[header_len + snapshot->len + i / 8] |=
				1u << (i % 8);
	}

	strbuf_swap(snapshot, &wrapped);
	strbuf_release(&wrapped);
	return 0;
}

static int parse_tracked_snapshot(struct index_state *istate,
				  const char **data, size_t *len,
				  const unsigned char **bitmap)
{
	uint32_t cache_nr, untracked_len;
	size_t bitmap_len, header_len;

	*bitmap = NULL;
	if (*len < FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN ||
	    memcmp(*data, FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC,
		   FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN))
		return 0;
	if (*len < FSMONITOR_IPC_TRACKED_SNAPSHOT_HEADER_LEN ||
	    istate->split_index)
		return -1;

	cache_nr = get_be32(*data + FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN);
	untracked_len = get_be32(*data +
				 FSMONITOR_IPC_TRACKED_SNAPSHOT_MAGIC_LEN +
				 sizeof(uint32_t));
	if (!cache_nr || cache_nr != istate->cache_nr || !untracked_len)
		return -1;

	bitmap_len = ((size_t)cache_nr + 7) / 8;
	header_len = FSMONITOR_IPC_TRACKED_SNAPSHOT_HEADER_LEN;
	if ((size_t)untracked_len > *len - header_len ||
	    bitmap_len != *len - header_len - untracked_len)
		return -1;
	if (cache_nr % 8 &&
	    ((unsigned char)(*data)[*len - 1] >> (cache_nr % 8)))
		return -1;

	*bitmap = (const unsigned char *)*data + header_len + untracked_len;
	*data += header_len;
	*len = untracked_len;
	return 0;
}

static int compress_untracked_cache(struct strbuf *snapshot)
{
	struct strbuf compressed = STRBUF_INIT;
	git_zstream stream;
	unsigned long bound;
	int status;

	if (snapshot->len > FSMONITOR_IPC_UNCOMPRESSED_CACHE_MAX)
		return -1;

	git_deflate_init(&stream, Z_BEST_SPEED);
	bound = git_deflate_bound(&stream, snapshot->len);
	if (bound > FSMONITOR_IPC_UNTRACKED_CACHE_MAX -
		    FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN)
		bound = FSMONITOR_IPC_UNTRACKED_CACHE_MAX -
			FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN;

	strbuf_add(&compressed, FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC,
		   FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN);
	strbuf_addchars(&compressed, '\0', sizeof(uint32_t));
	put_be32(compressed.buf + FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN,
		 snapshot->len);
	strbuf_grow(&compressed, bound);
	stream.next_in = (unsigned char *)snapshot->buf;
	stream.avail_in = snapshot->len;
	stream.next_out = (unsigned char *)compressed.buf + compressed.len;
	stream.avail_out = bound;
	status = git_deflate(&stream, Z_FINISH);
	if (git_deflate_end_gently(&stream) != Z_OK ||
	    status != Z_STREAM_END || stream.avail_in) {
		strbuf_release(&compressed);
		return -1;
	}
	strbuf_setlen(&compressed,
		      FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN +
		      stream.total_out);
	strbuf_swap(snapshot, &compressed);
	strbuf_release(&compressed);
	return 0;
}

static int decompress_untracked_cache(const char *data, size_t len,
				     struct strbuf *snapshot)
{
	git_zstream stream = { 0 };
	uint32_t expected;
	int status;

	if (len <= FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN)
		return -1;
	expected = get_be32(data +
			    FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN);
	if (!expected || expected > FSMONITOR_IPC_UNCOMPRESSED_CACHE_MAX)
		return -1;

	git_inflate_init(&stream);
	strbuf_grow(snapshot, expected);
	stream.next_in = (unsigned char *)data +
		FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN;
	stream.avail_in = len - FSMONITOR_IPC_COMPRESSED_SNAPSHOT_HEADER_LEN;
	stream.next_out = (unsigned char *)snapshot->buf;
	stream.avail_out = expected;
	status = git_inflate(&stream, Z_FINISH);
	git_inflate_end(&stream);
	if (status != Z_STREAM_END || stream.avail_in ||
	    stream.total_out != expected)
		return -1;
	strbuf_setlen(snapshot, expected);
	return 0;
}

enum fsmonitor_untracked_cache_result
fsmonitor_ipc__restore_untracked_cache(struct index_state *istate,
				       const char **restore_reason)
{
	struct strbuf command = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	struct strbuf snapshot = STRBUF_INIT;
	struct untracked_cache *candidate;
	struct object_id generated_index_oid;
	const struct object_id *index_oid;
	const char *snapshot_data;
	const unsigned char *tracked_bitmap;
	size_t snapshot_len;
	const char *reason = "ineligible";
	enum fsmonitor_untracked_cache_result result =
		FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED;

	*restore_reason = NULL;
	if (!istate->untracked ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		goto done;
	index_oid = untracked_cache_index_oid(istate, &generated_index_oid);
	if (!index_oid)
		goto done;

	refresh_fsmonitor(istate);
	if (!istate->fsmonitor_last_update) {
		reason = "no-current-token";
		goto done;
	}
	/* A restarted daemon can validate snapshots with its new token. */
	if (!starts_with(istate->fsmonitor_last_update, "builtin:") ||
	    !strcmp(istate->fsmonitor_last_update, "builtin:fake")) {
		reason = "fsmonitor-fallback";
		goto done;
	}

	strbuf_addf(&command, FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX
		    "get %s %s", oid_to_hex(index_oid),
		    istate->fsmonitor_last_update);
	if (fsmonitor_ipc__send_untracked_cache_command(
		    command.buf, command.len, &answer)) {
		reason = "ipc-error";
		goto done;
	}
	if (answer.len == 4 && !memcmp(answer.buf, "miss", 4)) {
		result = FSMONITOR_UNTRACKED_CACHE_MISS;
		goto done;
	}
	if (answer.len <= 4) {
		reason = "short-response";
		goto done;
	}
	if (answer.len - 4 > FSMONITOR_IPC_UNTRACKED_CACHE_MAX) {
		reason = "oversize-response";
		goto done;
	}
	if (memcmp(answer.buf, "hit", 4)) {
		reason = "invalid-response";
		goto done;
	}

	snapshot_data = answer.buf + 4;
	snapshot_len = answer.len - 4;
	if (snapshot_len >= FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN &&
	    !memcmp(snapshot_data, FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC,
		    FSMONITOR_IPC_COMPRESSED_SNAPSHOT_MAGIC_LEN)) {
		if (decompress_untracked_cache(snapshot_data, snapshot_len,
					       &snapshot)) {
			reason = "invalid-compressed-snapshot";
			goto done;
		}
		snapshot_data = snapshot.buf;
		snapshot_len = snapshot.len;
		trace2_data_intmax("fsmonitor", istate->repo,
				   "untracked-cache/decompressed", 1);
	}
	if (parse_tracked_snapshot(istate, &snapshot_data, &snapshot_len,
				   &tracked_bitmap)) {
		reason = "invalid-tracked-snapshot";
		goto done;
	}

	candidate = read_untracked_extension_bounded(snapshot_data,
						     snapshot_len);
	if (!candidate) {
		reason = "invalid-snapshot";
		goto done;
	}
	result = FSMONITOR_UNTRACKED_CACHE_HIT;
	candidate->use_fsmonitor = 1;
	if (candidate->root && !candidate->root->valid)
		candidate->dir_invalidated = 1;
	free_untracked_cache(istate->untracked);
	istate->untracked = candidate;
	if (tracked_bitmap) {
		unsigned int restored = 0;

		for (size_t i = 0; i < istate->cache_nr; i++) {
			struct cache_entry *ce = istate->cache[i];

			if ((tracked_bitmap[i / 8] & (1u << (i % 8))) &&
			    tracked_snapshot_entry_is_eligible(ce)) {
				ce->ce_flags |= CE_FSMONITOR_VALID;
				restored++;
			}
		}
		trace2_data_intmax("fsmonitor", istate->repo,
				   "tracked-cache/restored", restored);
	}
	trace2_data_intmax("fsmonitor", istate->repo,
			   "untracked-cache/hit", 1);

done:
	trace2_data_string("fsmonitor", istate->repo,
			   "untracked-cache/restore",
			   result == FSMONITOR_UNTRACKED_CACHE_HIT ? "hit" :
			   result == FSMONITOR_UNTRACKED_CACHE_MISS ? "miss" :
			   "unsupported");
	if (result == FSMONITOR_UNTRACKED_CACHE_UNSUPPORTED) {
		*restore_reason = reason;
		trace2_data_string("fsmonitor", istate->repo,
				   "untracked-cache/restore-reason", reason);
	}
	strbuf_release(&answer);
	strbuf_release(&snapshot);
	strbuf_release(&command);
	return result;
}

void fsmonitor_ipc__save_untracked_cache(struct index_state *istate)
{
	static const char hex[] = "0123456789abcdef";
	struct strbuf command = STRBUF_INIT;
	struct strbuf snapshot = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	struct object_id generated_index_oid;
	const struct object_id *index_oid;
	size_t start;

	if (!istate->untracked || !istate->untracked->root ||
	    !istate->fsmonitor_last_update ||
	    !starts_with(istate->fsmonitor_last_update, "builtin:") ||
	    !strcmp(istate->fsmonitor_last_update, "builtin:fake") ||
	    fsm_settings__get_mode(istate->repo) != FSMONITOR_MODE_IPC)
		return;
	index_oid = untracked_cache_index_oid(istate, &generated_index_oid);
	if (!index_oid)
		return;

	write_untracked_extension(&snapshot, istate->untracked);
	if (!snapshot.len)
		goto done;
	if (add_tracked_snapshot(istate, &snapshot)) {
		trace2_data_string("fsmonitor", istate->repo,
				   "untracked-cache/save-reason",
				   "oversize-snapshot");
		goto done;
	}
	if (snapshot.len > FSMONITOR_IPC_UNTRACKED_CACHE_MAX ||
	    git_env_bool("GIT_TEST_FSMONITOR_COMPRESS_UNTRACKED_CACHE", 0)) {
		if (compress_untracked_cache(&snapshot)) {
			trace2_data_string("fsmonitor", istate->repo,
					   "untracked-cache/save-reason",
					   "oversize-snapshot");
			goto done;
		}
		trace2_data_intmax("fsmonitor", istate->repo,
				   "untracked-cache/compressed", 1);
	}

	strbuf_addf(&command, FSMONITOR_IPC_UNTRACKED_CACHE_PREFIX
		    "put %s %s ", oid_to_hex(index_oid),
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

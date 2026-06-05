#include "git-compat-util.h"
#include "grep-index-identity.h"
#include "csum-file.h"
#include "environment.h"
#include "lockfile.h"
#include "path.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "wrapper.h"

#define GREP_INDEX_TOKEN_SIGNATURE 0x47574944
#define GREP_INDEX_TOKEN_VERSION 4
#define GREP_INDEX_TOKEN_HEADER_SIZE 76

static void hash_uint32(struct git_hash_ctx *ctx, uint32_t value)
{
	value = htonl(value);
	git_hash_update(ctx, &value, sizeof(value));
}

static void hash_string(struct git_hash_ctx *ctx, const char *value)
{
	if (value)
		git_hash_update(ctx, value, strlen(value));
	git_hash_update(ctx, "", 1);
}

void grep_index_identity_oid_sequence_init(
	struct repository *repo, struct git_hash_ctx *ctx, size_t nr)
{
	repo->hash_algo->init_fn(ctx);
	git_hash_update(ctx, "grep-index-ipc-index-v1", 24);
	hash_uint32(ctx, repo->hash_algo->format_id);
	hash_uint32(ctx, nr);
}

static void hash_scope(struct repository *repo, struct object_id *oid)
{
	struct git_hash_ctx ctx;

	repo->hash_algo->init_fn(&ctx);
	git_hash_update(&ctx, "grep-worktree-scope-v1", 22);
	hash_uint32(&ctx, repo->hash_algo->format_id);
	hash_string(&ctx, repo_get_work_tree(repo));
	hash_string(&ctx, repo_get_git_dir(repo));
	git_hash_final_oid(oid, &ctx);
}

static int compute_identity(struct repository *repo,
			    struct index_state *istate,
			    struct grep_index_identity *identity)
{
	struct strbuf entries = STRBUF_INIT;
	struct strbuf oids = STRBUF_INIT;
	struct git_hash_ctx entries_ctx;
	struct git_hash_ctx oids_ctx;
	char data[sizeof(uint32_t)];
	int result = -1;

	grep_index_identity_oid_sequence_init(
		repo, &oids_ctx, istate->cache_nr);
	repo->hash_algo->init_fn(&entries_ctx);
	git_hash_update(&entries_ctx, "grep-worktree-index-v1", 22);
	hash_uint32(&entries_ctx, repo->hash_algo->format_id);
	hash_string(&entries_ctx, repo_get_work_tree(repo));
	hash_string(&entries_ctx, repo_get_git_dir(repo));
	hash_uint32(&entries_ctx, istate->cache_nr);
	strbuf_grow(&oids, 1024 * 1024);
	strbuf_grow(&entries, 1024 * 1024);
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		size_t name_len = ce_namelen(ce);

		if (ce_stage(ce) || ce_intent_to_add(ce) ||
		    ce->ce_flags & CE_REMOVE || name_len > UINT32_MAX)
			goto cleanup;
		strbuf_add(&oids, ce->oid.hash, repo->hash_algo->rawsz);
		if (oids.len >= 1024 * 1024) {
			git_hash_update(&oids_ctx, oids.buf, oids.len);
			strbuf_reset(&oids);
		}
		put_be32(data, ce->ce_mode);
		strbuf_add(&entries, data, sizeof(data));
		put_be32(data, name_len);
		strbuf_add(&entries, data, sizeof(data));
		strbuf_add(&entries, ce->name, name_len);
		strbuf_add(&entries, ce->oid.hash, repo->hash_algo->rawsz);
		if (entries.len >= 1024 * 1024) {
			git_hash_update(&entries_ctx, entries.buf, entries.len);
			strbuf_reset(&entries);
		}
	}
	git_hash_update(&oids_ctx, oids.buf, oids.len);
	git_hash_final_oid(&identity->oid_sequence, &oids_ctx);
	git_hash_update(&entries_ctx, entries.buf, entries.len);
	git_hash_final_oid(&identity->worktree, &entries_ctx);
	result = 0;

cleanup:
	strbuf_release(&entries);
	strbuf_release(&oids);
	return result;
}

static void token_path(struct repository *repo, struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-token", repo_get_index_file(repo));
}

static void *map_file(const char *path, size_t *map_size)
{
	void *map;
	struct stat st;
	int fd = git_open(path);

	if (fd < 0)
		return NULL;
	if (fstat(fd, &st) || st.st_size < 0) {
		close(fd);
		return NULL;
	}
	*map_size = xsize_t(st.st_size);
	map = xmmap_gently(NULL, *map_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	return map == MAP_FAILED ? NULL : map;
}

static int load_token(struct repository *repo,
		      struct index_state *istate,
		      const struct object_id *scope_oid,
		      struct grep_index_identity *identity)
{
	const unsigned char *map;
	const struct stat *st = &istate->index_file_stat;
	struct strbuf path = STRBUF_INIT;
	size_t expected;
	size_t map_size;
	size_t rawsz = repo->hash_algo->rawsz;
	int result = -1;

	if (!istate->index_file_stat_valid)
		return -1;
	token_path(repo, &path);
	map = map_file(path.buf, &map_size);
	if (!map)
		goto cleanup;
	expected = GREP_INDEX_TOKEN_HEADER_SIZE + 5 * rawsz;
	if (map_size != expected ||
	    !hashfile_checksum_valid(repo->hash_algo, map, map_size) ||
	    get_be32(map) != GREP_INDEX_TOKEN_SIGNATURE ||
	    get_be32(map + 4) != GREP_INDEX_TOKEN_VERSION ||
	    get_be32(map + 8) != repo->hash_algo->format_id ||
	    get_be32(map + 12) != istate->cache_nr ||
	    get_be64(map + 16) != (uint64_t)st->st_dev ||
	    get_be64(map + 24) != (uint64_t)st->st_ino ||
	    get_be64(map + 32) != (uint64_t)st->st_size ||
	    get_be64(map + 40) != (uint64_t)st->st_mtime ||
	    get_be64(map + 48) != ST_MTIME_NSEC(*st) ||
	    get_be64(map + 56) != (uint64_t)st->st_ctime ||
	    get_be64(map + 64) != ST_CTIME_NSEC(*st) ||
	    get_be32(map + 72) != istate->sparse_index ||
	    !hasheq(map + GREP_INDEX_TOKEN_HEADER_SIZE,
		    istate->oid.hash, repo->hash_algo) ||
	    !hasheq(map + GREP_INDEX_TOKEN_HEADER_SIZE + rawsz,
		    scope_oid->hash, repo->hash_algo))
		goto unmap;
	oidread(&identity->oid_sequence,
		map + GREP_INDEX_TOKEN_HEADER_SIZE + 2 * rawsz,
		repo->hash_algo);
	oidread(&identity->worktree,
		map + GREP_INDEX_TOKEN_HEADER_SIZE + 3 * rawsz,
		repo->hash_algo);
	result = 0;

unmap:
	munmap((void *)map, map_size);
cleanup:
	strbuf_release(&path);
	return result;
}

static void write_token(struct repository *repo,
			struct index_state *istate,
			const struct object_id *scope_oid,
			const struct grep_index_identity *identity)
{
	const struct stat *st = &istate->index_file_stat;
	struct hashfile *f = NULL;
	struct lock_file lock = LOCK_INIT;
	struct strbuf path = STRBUF_INIT;
	int fd;

	if (!istate->index_file_stat_valid || !use_optional_locks())
		return;
	token_path(repo, &path);
	fd = hold_lock_file_for_update_mode(&lock, path.buf, 0, 0444);
	if (fd < 0)
		goto cleanup;
	f = hashfd(repo->hash_algo, fd, get_lock_file_path(&lock));
	hashwrite_be32(f, GREP_INDEX_TOKEN_SIGNATURE);
	hashwrite_be32(f, GREP_INDEX_TOKEN_VERSION);
	hashwrite_be32(f, repo->hash_algo->format_id);
	hashwrite_be32(f, istate->cache_nr);
	hashwrite_be64(f, st->st_dev);
	hashwrite_be64(f, st->st_ino);
	hashwrite_be64(f, st->st_size);
	hashwrite_be64(f, st->st_mtime);
	hashwrite_be64(f, ST_MTIME_NSEC(*st));
	hashwrite_be64(f, st->st_ctime);
	hashwrite_be64(f, ST_CTIME_NSEC(*st));
	hashwrite_be32(f, istate->sparse_index);
	hashwrite(f, istate->oid.hash, repo->hash_algo->rawsz);
	hashwrite(f, scope_oid->hash, repo->hash_algo->rawsz);
	hashwrite(f, identity->oid_sequence.hash, repo->hash_algo->rawsz);
	hashwrite(f, identity->worktree.hash, repo->hash_algo->rawsz);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	f = NULL;
	commit_lock_file(&lock);

cleanup:
	if (f)
		discard_hashfile(f);
	rollback_lock_file(&lock);
	strbuf_release(&path);
}

int grep_index_identity_get(struct repository *repo,
			    struct index_state *istate,
			    struct grep_index_identity *identity)
{
	struct object_id scope_oid;

	hash_scope(repo, &scope_oid);
	if (!load_token(repo, istate, &scope_oid, identity))
		return 0;
	if (compute_identity(repo, istate, identity))
		return -1;
	write_token(repo, istate, &scope_oid, identity);
	return 0;
}

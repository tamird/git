#include "git-compat-util.h"
#include "grep-index-identity.h"
#include "csum-file.h"
#include "environment.h"
#include "lockfile.h"
#include "path.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "split-index.h"
#include "strbuf.h"
#include "trace2.h"
#include "wrapper.h"

#define GREP_INDEX_TOKEN_SIGNATURE 0x47574944
#define GREP_INDEX_TOKEN_VERSION	7
#define GREP_INDEX_TOKEN_HEADER_SIZE	92
#define GREP_INDEX_TOKEN_V5_HEADER_SIZE 76
#define GREP_INDEX_EOIE_SIZE		32
#define GREP_INDEX_IEOT_SIGNATURE	0x49454f54 /* IEOT */

/* Numeric Trace2 outcomes; token reads and writes are best effort. */
enum grep_index_token_read_outcome {
	GREP_INDEX_TOKEN_READ_HIT = 0,
	GREP_INDEX_TOKEN_READ_NO_INDEX_STAT,
	GREP_INDEX_TOKEN_READ_MISSING,
	GREP_INDEX_TOKEN_READ_FAILED,
	GREP_INDEX_TOKEN_READ_INVALID,
	GREP_INDEX_TOKEN_READ_ENTRY_MATCH,
};

enum grep_index_token_write_outcome {
	GREP_INDEX_TOKEN_WRITE_COMMITTED = 0,
	GREP_INDEX_TOKEN_WRITE_NO_INDEX_STAT,
	GREP_INDEX_TOKEN_WRITE_OPTIONAL_LOCKS_DISABLED,
	GREP_INDEX_TOKEN_WRITE_LOCK_FAILED,
	GREP_INDEX_TOKEN_WRITE_COMMIT_FAILED,
	GREP_INDEX_TOKEN_WRITE_ENTRIES_CHANGED,
};

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
	git_hash_init(ctx, repo->hash_algo);
	git_hash_update(ctx, "grep-index-ipc-index-v1", 24);
	hash_uint32(ctx, repo->hash_algo->format_id);
	hash_uint32(ctx, nr);
}

static void hash_scope(struct repository *repo, struct object_id *oid)
{
	struct git_hash_ctx ctx;

	git_hash_init(&ctx, repo->hash_algo);
	git_hash_update(&ctx, "grep-worktree-scope-v1", 22);
	hash_uint32(&ctx, repo->hash_algo->format_id);
	hash_string(&ctx, repo_get_work_tree(repo));
	hash_string(&ctx, repo_get_git_dir(repo));
	git_hash_final_oid(oid, &ctx);
}

struct worktree_entry_data {
	unsigned char header[2 * sizeof(uint32_t)];
	unsigned char stat[9 * sizeof(uint32_t)];
	size_t name_len;
};

static int serialize_worktree_entry(struct worktree_entry_data *data,
				    const struct cache_entry *ce)
{
	size_t name_len = ce_namelen(ce);
	unsigned char *stat = data->stat;

	if (ce_stage(ce) || ce_intent_to_add(ce) ||
	    ce->ce_flags & CE_REMOVE || name_len > UINT32_MAX)
		return -1;
	put_be32(data->header, ce->ce_mode);
	put_be32(data->header + sizeof(uint32_t), name_len);
	data->name_len = name_len;
	/*
	 * Stat data does not prove byte equality, but distinguishes index
	 * entry generations which retain a blob ID while their converted
	 * worktree bytes change.
	 */
	put_be32(stat, ce->ce_stat_data.sd_ctime.sec);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_ctime.nsec);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_mtime.sec);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_mtime.nsec);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_dev);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_ino);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_uid);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_gid);
	put_be32(stat += sizeof(uint32_t), ce->ce_stat_data.sd_size);
	return 0;
}

void grep_worktree_entry_identity_init(
	struct repository *repo,
	struct grep_worktree_entry_identity *identity)
{
	identity->object_format_id = repo->hash_algo->format_id;
	identity->object_rawsz = repo->hash_algo->rawsz;
}

int grep_worktree_entry_identity_hash(
	const struct grep_worktree_entry_identity *identity,
	const struct cache_entry *ce,
	struct object_id *oid)
{
	struct worktree_entry_data data;
	struct git_hash_ctx ctx;
	const struct git_hash_algo *algo = &hash_algos[GIT_HASH_SHA256];

	if (serialize_worktree_entry(&data, ce))
		return -1;
	git_hash_init(&ctx, algo);
	git_hash_update(&ctx, "grep-worktree-entry-v1", 22);
	hash_uint32(&ctx, identity->object_format_id);
	git_hash_update(&ctx, data.header, sizeof(data.header));
	git_hash_update(&ctx, ce->name, data.name_len);
	git_hash_update(&ctx, ce->oid.hash, identity->object_rawsz);
	git_hash_update(&ctx, data.stat, sizeof(data.stat));
	git_hash_final_oid(oid, &ctx);
	return 0;
}

static int compute_identity(struct repository *repo,
			    struct index_state *istate,
			    struct grep_index_identity *identity)
{
	struct strbuf entries = STRBUF_INIT;
	struct strbuf oids = STRBUF_INIT;
	unsigned char entries_hash[GIT_SHA256_RAWSZ];
	struct git_hash_ctx entries_ctx;
	struct git_hash_ctx oids_ctx;
	int result = -1;

	grep_index_identity_oid_sequence_init(
		repo, &oids_ctx, istate->cache_nr);
	/*
	 * Hash the large stream with SHA-256, then use the repository hash to
	 * retain its key width and, for SHA-1, collision detection.
	 */
	git_hash_init(&entries_ctx, &hash_algos[GIT_HASH_SHA256]);
	git_hash_update(&entries_ctx, "grep-worktree-index-v2", 22);
	hash_uint32(&entries_ctx, repo->hash_algo->format_id);
	hash_string(&entries_ctx, repo_get_work_tree(repo));
	hash_string(&entries_ctx, repo_get_git_dir(repo));
	hash_uint32(&entries_ctx, istate->cache_nr);
	strbuf_grow(&oids, 1024 * 1024);
	strbuf_grow(&entries, 1024 * 1024);
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		struct worktree_entry_data data;

		if (serialize_worktree_entry(&data, ce))
			goto cleanup;
		strbuf_add(&entries, data.header, sizeof(data.header));
		strbuf_add(&entries, ce->name, data.name_len);
		strbuf_add(&entries, ce->oid.hash,
			   repo->hash_algo->rawsz);
		strbuf_add(&entries, data.stat, sizeof(data.stat));
		strbuf_add(&oids, ce->oid.hash, repo->hash_algo->rawsz);
		if (oids.len >= 1024 * 1024) {
			git_hash_update(&oids_ctx, oids.buf, oids.len);
			strbuf_reset(&oids);
		}
		if (entries.len >= 1024 * 1024) {
			git_hash_update(&entries_ctx, entries.buf, entries.len);
			strbuf_reset(&entries);
		}
	}
	git_hash_update(&oids_ctx, oids.buf, oids.len);
	git_hash_final_oid(&identity->oid_sequence, &oids_ctx);
	git_hash_update(&entries_ctx, entries.buf, entries.len);
	git_hash_final(entries_hash, &entries_ctx);
	git_hash_init(&entries_ctx, repo->hash_algo);
	git_hash_update(&entries_ctx, "grep-worktree-index-sha256-v1",
			sizeof("grep-worktree-index-sha256-v1") - 1);
	git_hash_update(&entries_ctx, entries_hash, sizeof(entries_hash));
	git_hash_final_oid(&identity->worktree, &entries_ctx);
	result = 0;

cleanup:
	git_hash_discard(&entries_ctx);
	git_hash_discard(&oids_ctx);
	strbuf_release(&entries);
	strbuf_release(&oids);
	return result;
}

static void token_path(struct repository *repo, struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-token", repo_get_index_file(repo));
}

static void *map_file(const char *path, size_t *map_size, int *read_errno)
{
	void *map;
	struct stat st;
	int fd = git_open(path);

	*read_errno = 0;
	if (fd < 0) {
		*read_errno = errno;
		return NULL;
	}
	if (fstat(fd, &st)) {
		*read_errno = errno;
		close(fd);
		return NULL;
	}
	if (st.st_size < 0) {
		close(fd);
		return NULL;
	}
	if (!st.st_size) {
		close(fd);
		return NULL;
	}
	*map_size = xsize_t(st.st_size);
	map = xmmap_gently(NULL, *map_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map == MAP_FAILED)
		*read_errno = errno;
	close(fd);
	return map == MAP_FAILED ? NULL : map;
}

static int same_index_stat(const struct stat *a, const struct stat *b)
{
	return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
	       a->st_size == b->st_size &&
	       a->st_mtime == b->st_mtime &&
	       ST_MTIME_NSEC(*a) == ST_MTIME_NSEC(*b) &&
	       a->st_ctime == b->st_ctime &&
	       ST_CTIME_NSEC(*a) == ST_CTIME_NSEC(*b);
}

static int parsed_entries_unchanged(const struct index_state *istate)
{
	return istate->index_file_parsed_generation_valid &&
	       !(istate->cache_changed & (SOMETHING_CHANGED | CE_ENTRY_ADDED |
					  CE_ENTRY_REMOVED | CE_ENTRY_CHANGED));
}

/* Hash the bytes parsed into this index, never a later pathname generation. */
static int index_entry_checksum(struct repository *repo,
				struct index_state *istate,
				struct object_id *oid)
{
	const unsigned char *map;
	const unsigned char *eoie;
	struct stat st, after;
	struct git_hash_ctx ctx = { 0 };
	size_t size, offset, end = istate->index_file_entries_end;
	int ieot_seen = 0;
	int result = -1;

	if (!istate->index_file_fd_valid ||
	    !istate->index_file_stat_valid ||
	    !istate->index_file_entries_end_valid ||
	    istate->index_file_has_link || istate->index_file_has_sdir ||
	    istate->split_index || istate->sparse_index ||
	    !parsed_entries_unchanged(istate) ||
	    fstat(istate->index_file_fd, &st) ||
	    !same_index_stat(&st, &istate->index_file_stat) ||
	    st.st_size < 0)
		return -1;
	size = xsize_t(st.st_size);
	if (size < sizeof(struct cache_header) + GREP_INDEX_EOIE_SIZE +
			    repo->hash_algo->rawsz ||
	    end <= sizeof(struct cache_header) ||
	    end >= size - GREP_INDEX_EOIE_SIZE - repo->hash_algo->rawsz)
		return -1;
	trace2_region_enter("grep", "index-identity/entry-checksum", repo);
	map = xmmap_gently(NULL, size, PROT_READ, MAP_PRIVATE,
			   istate->index_file_fd, 0);
	if (map == MAP_FAILED)
		goto done;
	eoie = map + size - GREP_INDEX_EOIE_SIZE - repo->hash_algo->rawsz;
	if (get_be32(map) != CACHE_SIGNATURE ||
	    get_be32(map + 4) != istate->version ||
	    get_be32(map + 8) != istate->cache_nr ||
	    get_be32(eoie) != 0x454f4945 || /* EOIE */
	    get_be32(eoie + 4) != 24 ||
	    get_be32(eoie + 8) != end ||
	    !hasheq(map + size - repo->hash_algo->rawsz,
		    istate->oid.hash, repo->hash_algo))
		goto unmap;
	git_hash_init(&ctx, &hash_algos[GIT_HASH_SHA256]);
	git_hash_update(&ctx, "grep-index-entry-bytes-v7",
			sizeof("grep-index-entry-bytes-v7") - 1);
	hash_uint32(&ctx, istate->index_file_used_ieot);
	git_hash_update(&ctx, map + sizeof(struct cache_header),
			end - sizeof(struct cache_header));
	for (offset = end; offset < (size_t)(eoie - map);) {
		uint32_t extsize;

		if ((size_t)(eoie - map) - offset < 8)
			goto unmap;
		extsize = get_be32(map + offset + 4);
		if (extsize > (size_t)(eoie - map) - offset - 8)
			goto unmap;
		if (get_be32(map + offset) == GREP_INDEX_IEOT_SIGNATURE) {
			git_hash_update(&ctx, map + offset, 8 + extsize);
			ieot_seen = 1;
		}
		offset += 8 + extsize;
	}
	if (offset != (size_t)(eoie - map) ||
	    (istate->index_file_used_ieot && !ieot_seen))
		goto unmap;
	git_hash_final_oid(oid, &ctx);
	if (!fstat(istate->index_file_fd, &after) &&
	    same_index_stat(&st, &after))
		result = 0;
unmap:
	munmap((void *)map, size);
done:
	git_hash_discard(&ctx);
	trace2_region_leave("grep", "index-identity/entry-checksum", repo);
	return result;
}

static enum grep_index_token_read_outcome load_token(
	struct repository *repo, struct index_state *istate,
	const struct index_file_snapshot *snapshot,
	const struct object_id *scope_oid,
	struct grep_index_identity *identity,
	struct object_id *entry_checksum_out, int *read_errno)
{
	const unsigned char *map;
	const struct stat *st = &snapshot->stat;
	struct strbuf path = STRBUF_INIT;
	struct object_id entry_checksum;
	size_t expected;
	size_t map_size;
	size_t rawsz = repo->hash_algo->rawsz;
	size_t header_size;
	uint32_t version;
	enum grep_index_token_read_outcome result = GREP_INDEX_TOKEN_READ_INVALID;

	*read_errno = 0;
	if (istate && !istate->index_file_stat_valid)
		return GREP_INDEX_TOKEN_READ_NO_INDEX_STAT;
	if (istate && !parsed_entries_unchanged(istate))
		return GREP_INDEX_TOKEN_READ_INVALID;
	token_path(repo, &path);
	map = map_file(path.buf, &map_size, read_errno);
	if (!map) {
		if (*read_errno == ENOENT)
			result = GREP_INDEX_TOKEN_READ_MISSING;
		else if (*read_errno)
			result = GREP_INDEX_TOKEN_READ_FAILED;
		goto cleanup;
	}
	if (map_size < 8)
		goto unmap;
	version = get_be32(map + 4);
	if (version != 5 && version != 6 &&
	    version != GREP_INDEX_TOKEN_VERSION)
		goto unmap;
	if (!istate && version != GREP_INDEX_TOKEN_VERSION)
		goto unmap;
	header_size = version == 5 ? GREP_INDEX_TOKEN_V5_HEADER_SIZE :
				     GREP_INDEX_TOKEN_HEADER_SIZE;
	expected = header_size + 5 * rawsz;
	if (version != 5)
		expected += version == 6 ? rawsz : GIT_SHA256_RAWSZ;
	if (map_size != expected ||
	    !hashfile_checksum_valid(repo->hash_algo, map, map_size) ||
	    get_be32(map) != GREP_INDEX_TOKEN_SIGNATURE ||
	    get_be32(map + 8) != repo->hash_algo->format_id ||
	    get_be32(map + 12) != snapshot->nr ||
	    get_be32(map + 72) != (istate ? istate->sparse_index : 0) ||
	    (version >= 6 &&
	     get_be32(map + 88) != snapshot->used_ieot) ||
	    !hasheq(map + header_size + rawsz,
		    scope_oid->hash, repo->hash_algo))
		goto unmap;
	if (!istate) {
		oidread(&entry_checksum, map + header_size + 4 * rawsz,
			&hash_algos[GIT_HASH_SHA256]);
		/* A token without the optional entry checksum stores a zero tuple. */
		if (is_null_oid(&entry_checksum) ?
			    get_be32(map + 76) || get_be64(map + 80) :
			    get_be32(map + 76) != snapshot->version ||
				    get_be64(map + 80) != snapshot->entries_end)
			goto unmap;
	}
	if (get_be64(map + 16) == (uint64_t)st->st_dev &&
	    get_be64(map + 24) == (uint64_t)st->st_ino &&
	    get_be64(map + 32) == (uint64_t)st->st_size &&
	    get_be64(map + 40) == (uint64_t)st->st_mtime &&
	    get_be64(map + 48) == ST_MTIME_NSEC(*st) &&
	    get_be64(map + 56) == (uint64_t)st->st_ctime &&
	    get_be64(map + 64) == ST_CTIME_NSEC(*st) &&
	    hasheq(map + header_size, snapshot->oid.hash, repo->hash_algo))
		result = GREP_INDEX_TOKEN_READ_HIT;
	else if (istate && version == GREP_INDEX_TOKEN_VERSION &&
		 get_be32(map + 76) == istate->version &&
		 get_be64(map + 80) == istate->index_file_entries_end &&
		 istate->index_file_entries_end_valid &&
		 index_entry_checksum(repo, istate, &entry_checksum) == 0) {
		oidcpy(entry_checksum_out, &entry_checksum);
		if (hasheq(map + header_size + 4 * rawsz,
			   entry_checksum.hash, &hash_algos[GIT_HASH_SHA256]))
			result = GREP_INDEX_TOKEN_READ_ENTRY_MATCH;
	}
	if (result == GREP_INDEX_TOKEN_READ_INVALID)
		goto unmap;
	oidread(&identity->oid_sequence,
		map + header_size + 2 * rawsz,
		repo->hash_algo);
	oidread(&identity->worktree,
		map + header_size + 3 * rawsz,
		repo->hash_algo);

unmap:
	munmap((void *)map, map_size);
cleanup:
	strbuf_release(&path);
	return result;
}

static enum grep_index_token_write_outcome write_token(
	struct repository *repo, struct index_state *istate,
	const struct object_id *scope_oid,
	const struct grep_index_identity *identity,
	const struct object_id *verified_entry_checksum, int *error_errno)
{
	const struct stat *st = &istate->index_file_stat;
	struct object_id entry_checksum;
	struct hashfile *f = NULL;
	struct lock_file lock = LOCK_INIT;
	struct strbuf path = STRBUF_INIT;
	int fd;
	enum grep_index_token_write_outcome result =
		GREP_INDEX_TOKEN_WRITE_COMMITTED;

	*error_errno = 0;
	if (!istate->index_file_stat_valid)
		return GREP_INDEX_TOKEN_WRITE_NO_INDEX_STAT;
	if (!parsed_entries_unchanged(istate))
		return GREP_INDEX_TOKEN_WRITE_ENTRIES_CHANGED;
	if (!use_optional_locks())
		return GREP_INDEX_TOKEN_WRITE_OPTIONAL_LOCKS_DISABLED;
	trace2_region_enter("grep", "index-identity/token-write", repo);
	token_path(repo, &path);
	fd = hold_lock_file_for_update_mode(&lock, path.buf, 0, 0444);
	if (fd < 0) {
		*error_errno = errno;
		result = GREP_INDEX_TOKEN_WRITE_LOCK_FAILED;
		goto cleanup;
	}
	if (verified_entry_checksum)
		oidcpy(&entry_checksum, verified_entry_checksum);
	else if (index_entry_checksum(repo, istate, &entry_checksum))
		oidclr(&entry_checksum, &hash_algos[GIT_HASH_SHA256]);
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
	hashwrite_be32(f, is_null_oid(&entry_checksum) ? 0 : istate->version);
	hashwrite_be64(f, is_null_oid(&entry_checksum) ? 0 :
							 istate->index_file_entries_end);
	hashwrite_be32(f, istate->index_file_used_ieot);
	hashwrite(f, istate->oid.hash, repo->hash_algo->rawsz);
	hashwrite(f, scope_oid->hash, repo->hash_algo->rawsz);
	hashwrite(f, identity->oid_sequence.hash, repo->hash_algo->rawsz);
	hashwrite(f, identity->worktree.hash, repo->hash_algo->rawsz);
	hashwrite(f, entry_checksum.hash, GIT_SHA256_RAWSZ);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	f = NULL;
	if (commit_lock_file(&lock)) {
		*error_errno = errno;
		result = GREP_INDEX_TOKEN_WRITE_COMMIT_FAILED;
	}

cleanup:
	if (f)
		free_hashfile(f);
	rollback_lock_file(&lock);
	strbuf_release(&path);
	trace2_region_leave("grep", "index-identity/token-write", repo);
	return result;
}

int grep_index_identity_get(struct repository *repo,
			    struct index_state *istate,
			    struct grep_index_identity *identity)
{
	struct git_hash_ctx ctx;
	struct object_id scope_oid;
	struct object_id entry_checksum;
	struct index_file_snapshot snapshot = {
		.stat = istate->index_file_stat,
		.oid = istate->oid,
		.entries_end = istate->index_file_entries_end,
		.nr = istate->cache_nr,
		.version = istate->version,
		.used_ieot = istate->index_file_used_ieot,
	};
	enum grep_index_token_read_outcome read_outcome;
	enum grep_index_token_write_outcome write_outcome;
	int compute_result, read_errno, write_errno;

	hash_scope(repo, &scope_oid);
	oidclr(&entry_checksum, &hash_algos[GIT_HASH_SHA256]);
	oidcpy(&identity->worktree_scope, &scope_oid);
	oidclr(&identity->worktree_split_base_identity, repo->hash_algo);
	if (istate->split_index && istate->split_index->base &&
	    istate->split_index->base->cache_nr) {
		/*
		 * Scope the immutable base to this checkout so its positions
		 * cannot be reused by another worktree sharing the object store.
		 */
		git_hash_init(&ctx, repo->hash_algo);
		git_hash_update(&ctx, "grep-worktree-split-base-v1", 27);
		hash_uint32(&ctx, repo->hash_algo->format_id);
		git_hash_update(&ctx, scope_oid.hash, repo->hash_algo->rawsz);
		git_hash_update(&ctx, istate->split_index->base_oid.hash,
				repo->hash_algo->rawsz);
		hash_uint32(&ctx, istate->split_index->base->cache_nr);
		git_hash_final_oid(&identity->worktree_split_base_identity,
				   &ctx);
	}
	trace2_region_enter("grep", "index-identity/token-read", repo);
	read_outcome = load_token(repo, istate, &snapshot, &scope_oid, identity,
				  &entry_checksum, &read_errno);
	trace2_region_leave("grep", "index-identity/token-read", repo);
	trace2_data_intmax("grep", repo, "index_identity/token_read_outcome",
			   read_outcome);
	if (read_outcome == GREP_INDEX_TOKEN_READ_FAILED && read_errno)
		trace2_data_intmax("grep", repo,
				   "index_identity/token_read_errno",
				   read_errno);
	if (read_outcome == GREP_INDEX_TOKEN_READ_HIT)
		return 0;
	if (read_outcome == GREP_INDEX_TOKEN_READ_ENTRY_MATCH)
		goto write;
	trace2_region_enter("grep", "index-identity/compute", repo);
	compute_result = compute_identity(repo, istate, identity);
	trace2_region_leave("grep", "index-identity/compute", repo);
	trace2_data_intmax("grep", repo, "index_identity/compute_failed",
			   !!compute_result);
	if (compute_result)
		return -1;

write:
	write_outcome = write_token(repo, istate, &scope_oid, identity,
				    is_null_oid(&entry_checksum) ? NULL :
								   &entry_checksum,
				    &write_errno);
	trace2_data_intmax("grep", repo, "index_identity/token_write_outcome",
			   write_outcome);
	if (write_errno)
		trace2_data_intmax("grep", repo,
				   "index_identity/token_write_errno",
				   write_errno);
	return 0;
}

int grep_index_identity_from_snapshot(struct repository *repo,
				      const struct index_file_snapshot *snapshot, struct grep_index_identity *identity)
{
	struct object_id checksum;
	int read_errno;
	enum grep_index_token_read_outcome outcome;

	hash_scope(repo, &identity->worktree_scope);
	oidclr(&identity->worktree_split_base_identity, repo->hash_algo);
	outcome = load_token(repo, NULL, snapshot, &identity->worktree_scope,
			     identity, &checksum, &read_errno);
	return outcome == GREP_INDEX_TOKEN_READ_HIT ? 0 : -1;
}

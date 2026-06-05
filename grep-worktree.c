#include "git-compat-util.h"
#include "grep-worktree.h"
#include "csum-file.h"
#include "environment.h"
#include "lockfile.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "trace2.h"
#include "wrapper.h"

#define GREP_WORKTREE_CACHE_SIGNATURE	0x47574243
#define GREP_WORKTREE_CACHE_VERSION	1
#define GREP_WORKTREE_CACHE_HEADER_SIZE 16
#define GREP_WORKTREE_HASH_BUFFER_SIZE	(64 * 1024)

/*
 * The sidecar contains:
 *
 *   0                    signature
 *   4                    version
 *   8                    hash algorithm format ID
 *   12                   number of physical index entries
 *   16                   semantic index state hash
 *   16 + rawsz           known bitmap
 *   16 + rawsz + mapsz   equal bitmap
 *   16 + rawsz + 2*mapsz file checksum
 *
 * Bit i describes physical index position i. An equal bit must also be known,
 * and unused bits in the final byte must be zero.
 */
struct grep_worktree_cache {
	struct repository *repo;
	struct index_state *istate;
	struct object_id state_oid;
	unsigned char *known;
	unsigned char *equal;
	unsigned char *updated;
	size_t bitmap_size;
	uint64_t hits;
	uint64_t recorded_equal;
	uint64_t recorded_different;
	struct object_id sidecar_oid;
	int sidecar_present;
	int changed;
};

static void grep_worktree_cache_path(struct repository *repo,
				     struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-worktree", repo_get_index_file(repo));
}

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

static int hash_cache_identity(struct repository *repo,
			       struct index_state *istate,
			       struct object_id *oid)
{
	static const char domain[] = "grep-worktree-index-v1";
	struct strbuf entries = STRBUF_INIT;
	struct git_hash_ctx ctx;
	char data[sizeof(uint32_t)];
	int result = -1;

	/*
	 * Positions are valid while the ordered entry semantics remain the
	 * same. Ignore stat data and extensions so metadata-only index
	 * rewrites do not discard observations that fsmonitor still guards.
	 * CE_FSMONITOR_VALID is also excluded because current validity gates
	 * each lookup rather than describing the position-to-blob mapping.
	 *
	 * Include the worktree identity because GIT_INDEX_FILE can be shared
	 * by worktrees whose files have different contents.
	 */
	repo->hash_algo->init_fn(&ctx);
	git_hash_update(&ctx, domain, sizeof(domain) - 1);
	hash_uint32(&ctx, repo->hash_algo->format_id);
	hash_string(&ctx, repo_get_work_tree(repo));
	hash_string(&ctx, repo_get_git_dir(repo));
	hash_uint32(&ctx, istate->cache_nr);
	strbuf_grow(&entries, GREP_WORKTREE_HASH_BUFFER_SIZE);
	for (size_t i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		size_t name_len = ce_namelen(ce);
		uint32_t flags = ce->ce_flags &
				 (CE_STAGEMASK | CE_VALID | CE_EXTENDED_FLAGS);

		if (name_len > UINT32_MAX)
			goto cleanup;
		put_be32(data, ce->ce_mode);
		strbuf_add(&entries, data, sizeof(data));
		put_be32(data, flags);
		strbuf_add(&entries, data, sizeof(data));
		put_be32(data, (uint32_t)name_len);
		strbuf_add(&entries, data, sizeof(data));
		strbuf_add(&entries, ce->name, name_len);
		strbuf_add(&entries, ce->oid.hash, repo->hash_algo->rawsz);
		if (entries.len >= GREP_WORKTREE_HASH_BUFFER_SIZE) {
			git_hash_update(&ctx, entries.buf, entries.len);
			strbuf_reset(&entries);
		}
	}
	git_hash_update(&ctx, entries.buf, entries.len);
	git_hash_final_oid(oid, &ctx);
	result = 0;

cleanup:
	strbuf_release(&entries);
	return result;
}

static void *map_file(const char *path, size_t expected_size, int *present)
{
	void *map;
	struct stat st;
	int fd = git_open(path);

	if (fd < 0)
		return NULL;
	if (present)
		*present = 1;
	if (fstat(fd, &st) || st.st_size < 0 ||
	    (uintmax_t)st.st_size != expected_size) {
		close(fd);
		return NULL;
	}
	map = xmmap_gently(NULL, expected_size, PROT_READ, MAP_PRIVATE, fd, 0);
	close(fd);
	return map == MAP_FAILED ? NULL : map;
}

static int load_cache(struct grep_worktree_cache *cache,
		      unsigned char *known, unsigned char *equal,
		      struct object_id *file_oid, int *file_present)
{
	struct strbuf path = STRBUF_INIT;
	struct git_hash_ctx ctx;
	const unsigned char *map;
	const unsigned char *map_known;
	const unsigned char *map_equal;
	size_t expected;
	size_t map_size;
	size_t rawsz = cache->repo->hash_algo->rawsz;
	int checksum_valid;
	int result = 0;

	grep_worktree_cache_path(cache->repo, &path);
	expected = GREP_WORKTREE_CACHE_HEADER_SIZE + 2 * rawsz +
		   2 * cache->bitmap_size;
	map_size = expected;
	map = map_file(path.buf, expected, file_present);
	if (!map)
		goto done;
	checksum_valid =
		hashfile_checksum_valid(cache->repo->hash_algo, map, map_size);
	if (file_oid) {
		if (checksum_valid) {
			oidread(file_oid, map + map_size - rawsz,
				cache->repo->hash_algo);
		} else {
			cache->repo->hash_algo->init_fn(&ctx);
			git_hash_update(&ctx, map, map_size);
			git_hash_final_oid(file_oid, &ctx);
		}
	}
	if (!checksum_valid ||
	    get_be32(map) != GREP_WORKTREE_CACHE_SIGNATURE ||
	    get_be32(map + 4) != GREP_WORKTREE_CACHE_VERSION ||
	    get_be32(map + 8) != cache->repo->hash_algo->format_id ||
	    get_be32(map + 12) != cache->istate->cache_nr ||
	    !hasheq(map + GREP_WORKTREE_CACHE_HEADER_SIZE,
		    cache->state_oid.hash, cache->repo->hash_algo))
		goto unmap;

	map_known = map + GREP_WORKTREE_CACHE_HEADER_SIZE + rawsz;
	map_equal = map_known + cache->bitmap_size;
	for (size_t i = 0; i < cache->bitmap_size; i++)
		if (map_equal[i] & ~map_known[i])
			goto unmap;
	if (cache->istate->cache_nr & 7) {
		unsigned char valid =
			(1u << (cache->istate->cache_nr & 7)) - 1;

		if ((map_known[cache->bitmap_size - 1] |
		     map_equal[cache->bitmap_size - 1]) &
		    ~valid)
			goto unmap;
	}
	memcpy(known, map_known, cache->bitmap_size);
	memcpy(equal, map_equal, cache->bitmap_size);
	result = 1;

unmap:
	munmap((void *)map, map_size);
done:
	strbuf_release(&path);
	return result;
}

struct grep_worktree_cache *grep_worktree_cache_load(
	struct repository *repo, struct index_state *istate)
{
	struct grep_worktree_cache *cache;

	if (!istate->fsmonitor_last_update || !istate->cache_nr)
		return NULL;

	CALLOC_ARRAY(cache, 1);
	cache->repo = repo;
	cache->istate = istate;
	cache->bitmap_size = DIV_ROUND_UP(istate->cache_nr, 8);
	if (hash_cache_identity(repo, istate, &cache->state_oid)) {
		grep_worktree_cache_free(cache);
		return NULL;
	}
	CALLOC_ARRAY(cache->known, cache->bitmap_size);
	CALLOC_ARRAY(cache->equal, cache->bitmap_size);
	CALLOC_ARRAY(cache->updated, cache->bitmap_size);
	load_cache(cache, cache->known, cache->equal,
		   &cache->sidecar_oid, &cache->sidecar_present);
	return cache;
}

enum grep_worktree_cache_result grep_worktree_cache_lookup(
	struct grep_worktree_cache *cache, size_t pos)
{
	unsigned char mask;

	if (!cache || !cache->known || pos >= cache->istate->cache_nr)
		return GREP_WORKTREE_CACHE_UNKNOWN;
	mask = 1u << (pos & 7);
	if (!(cache->known[pos >> 3] & mask))
		return GREP_WORKTREE_CACHE_UNKNOWN;
	return cache->equal[pos >> 3] & mask ?
		       GREP_WORKTREE_CACHE_EQUAL :
		       GREP_WORKTREE_CACHE_DIFFERENT;
}

void grep_worktree_cache_record(struct grep_worktree_cache *cache, size_t pos,
				int equal)
{
	unsigned char mask;
	unsigned char *known;
	unsigned char *cached_equal;

	if (!cache || !cache->known || pos >= cache->istate->cache_nr)
		return;
	mask = 1u << (pos & 7);
	known = &cache->known[pos >> 3];
	cached_equal = &cache->equal[pos >> 3];
	if (*known & mask) {
		if (!(*cached_equal & mask) || equal)
			return;
		*cached_equal &= ~mask;
		cache->recorded_different++;
	} else {
		*known |= mask;
		if (equal) {
			*cached_equal |= mask;
			cache->recorded_equal++;
		} else {
			cache->recorded_different++;
		}
	}
	cache->updated[pos >> 3] |= mask;
	cache->changed = 1;
}

void grep_worktree_cache_hit(struct grep_worktree_cache *cache)
{
	if (cache)
		cache->hits++;
}

static int merge_updates(struct grep_worktree_cache *cache,
			 unsigned char *known, unsigned char *equal)
{
	int changed = 0;

	for (size_t i = 0; i < cache->bitmap_size; i++) {
		unsigned char updated = cache->updated[i];
		unsigned char old_known;
		unsigned char old_equal;
		unsigned char merged_equal;

		if (!updated)
			continue;
		old_known = known[i];
		old_equal = equal[i];
		merged_equal = cache->equal[i] & (~old_known | old_equal);
		known[i] |= updated;
		equal[i] = (old_equal & ~updated) |
			   (merged_equal & updated);
		if (known[i] != old_known || equal[i] != old_equal)
			changed = 1;
	}
	return changed;
}

void grep_worktree_cache_write(struct grep_worktree_cache *cache)
{
	unsigned char *known = NULL;
	unsigned char *equal = NULL;
	struct hashfile *f;
	struct lock_file lock = LOCK_INIT;
	struct object_id sidecar_oid;
	struct strbuf path = STRBUF_INIT;
	int sidecar_present = 0;
	int fd;

	if (!cache || !cache->changed || !use_optional_locks())
		return;

	grep_worktree_cache_path(cache->repo, &path);
	fd = hold_lock_file_for_update_mode(&lock, path.buf, 0, 0444);
	if (fd < 0)
		goto done;

	oidclr(&sidecar_oid, cache->repo->hash_algo);
	CALLOC_ARRAY(known, cache->bitmap_size);
	CALLOC_ARRAY(equal, cache->bitmap_size);
	if (load_cache(cache, known, equal, &sidecar_oid,
		       &sidecar_present)) {
		if (!merge_updates(cache, known, equal))
			goto done;
	} else {
		/*
		 * The semantic state in the file makes an index replacement
		 * harmless. Only avoid overwriting a sidecar that changed
		 * after this process loaded it.
		 */
		if (sidecar_present != cache->sidecar_present ||
		    (sidecar_present &&
		     !oideq(&sidecar_oid, &cache->sidecar_oid)))
			goto done;
		COPY_ARRAY(known, cache->known, cache->bitmap_size);
		COPY_ARRAY(equal, cache->equal, cache->bitmap_size);
	}

	f = hashfd(cache->repo->hash_algo, fd, get_lock_file_path(&lock));
	hashwrite_be32(f, GREP_WORKTREE_CACHE_SIGNATURE);
	hashwrite_be32(f, GREP_WORKTREE_CACHE_VERSION);
	hashwrite_be32(f, cache->repo->hash_algo->format_id);
	hashwrite_be32(f, cache->istate->cache_nr);
	hashwrite(f, cache->state_oid.hash, cache->repo->hash_algo->rawsz);
	hashwrite(f, known, cache->bitmap_size);
	hashwrite(f, equal, cache->bitmap_size);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	if (commit_lock_file(&lock))
		goto done;

done:
	rollback_lock_file(&lock);
	free(known);
	free(equal);
	strbuf_release(&path);
}

void grep_worktree_cache_free(struct grep_worktree_cache *cache)
{
	if (!cache)
		return;
	trace2_data_intmax("grep", cache->repo, "worktree_blob/hits",
			   cache->hits);
	trace2_data_intmax("grep", cache->repo, "worktree_blob/recorded_equal",
			   cache->recorded_equal);
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/recorded_different",
			   cache->recorded_different);
	free(cache->known);
	free(cache->equal);
	free(cache->updated);
	free(cache);
}

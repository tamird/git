#include "git-compat-util.h"
#include "grep-worktree.h"
#include "csum-file.h"
#include "dir.h"
#include "environment.h"
#include "lockfile.h"
#include "parse.h"
#include "path.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "strbuf.h"
#include "trace2.h"
#include "wrapper.h"

#define GREP_WORKTREE_CACHE_SIGNATURE 0x47574243
#define GREP_WORKTREE_CACHE_VERSION 1
#define GREP_WORKTREE_CACHE_HEADER_SIZE 16

/*
 * The sidecar contains:
 *
 *   0                    signature
 *   4                    version
 *   8                    hash algorithm format ID
 *   12                   number of physical index entries
 *   16                   index generation hash
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
	struct git_hash_ctx ctx;

	/*
	 * Positions are valid only for the index contents that were scanned.
	 * index_file_identity is computed from the exact mapped bytes that
	 * supplied those positions.
	 * Include the worktree identity because GIT_INDEX_FILE can be shared
	 * by worktrees whose files have different contents.
	 */
	if (!istate->index_file_identity_valid)
		return -1;
	oidclr(oid, repo->hash_algo);
	repo->hash_algo->init_fn(&ctx);
	hash_uint32(&ctx, repo->hash_algo->format_id);
	hash_string(&ctx, repo_get_work_tree(repo));
	hash_string(&ctx, repo_get_git_dir(repo));
	hash_uint32(&ctx, istate->version);
	git_hash_update(&ctx, istate->index_file_identity.hash,
			repo->hash_algo->rawsz);
	git_hash_final_oid(oid, &ctx);
	return 0;
}

static void *map_file(const char *path, size_t *map_size, int *present)
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
	if (present)
		*present = 1;
	*map_size = xsize_t(st.st_size);
	map = xmmap_gently(NULL, *map_size, PROT_READ, MAP_PRIVATE, fd, 0);
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
	int result = 0;

	grep_worktree_cache_path(cache->repo, &path);
	map = map_file(path.buf, &map_size, file_present);
	if (!map)
		goto done;
	if (file_oid) {
		cache->repo->hash_algo->init_fn(&ctx);
		git_hash_update(&ctx, map, map_size);
		git_hash_final_oid(file_oid, &ctx);
	}
	expected = GREP_WORKTREE_CACHE_HEADER_SIZE + 2 * rawsz +
		   2 * cache->bitmap_size;
	if (map_size != expected ||
	    !hashfile_checksum_valid(cache->repo->hash_algo, map, map_size) ||
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
		     map_equal[cache->bitmap_size - 1]) & ~valid)
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

static void allocate_cache_bitmaps(struct grep_worktree_cache *cache)
{
	if (cache->known)
		return;
	CALLOC_ARRAY(cache->known, cache->bitmap_size);
	CALLOC_ARRAY(cache->equal, cache->bitmap_size);
	CALLOC_ARRAY(cache->updated, cache->bitmap_size);
}

static int current_index_matches(struct grep_worktree_cache *cache)
{
	struct git_hash_ctx ctx;
	struct object_id oid;
	const unsigned char *map;
	size_t map_size;
	size_t rawsz = cache->repo->hash_algo->rawsz;
	int result = 0;

	map = map_file(repo_get_index_file(cache->repo), &map_size, NULL);
	if (!map)
		return 0;
	if (map_size < rawsz) {
		munmap((void *)map, map_size);
		return 0;
	}

	cache->repo->hash_algo->init_fn(&ctx);
	git_hash_update(&ctx, map, map_size - rawsz);
	git_hash_final_oid(&oid, &ctx);
	result = oideq(&oid, &cache->istate->index_file_identity);
	munmap((void *)map, map_size);
	return result;
}

struct grep_worktree_cache *grep_worktree_cache_load(
	struct repository *repo, struct index_state *istate)
{
	struct grep_worktree_cache *cache;

	if (!istate->fsmonitor_last_update || !istate->cache_nr ||
	    ensure_index_file_identity(istate))
		return NULL;

	CALLOC_ARRAY(cache, 1);
	cache->repo = repo;
	cache->istate = istate;
	cache->bitmap_size = DIV_ROUND_UP(istate->cache_nr, 8);
	if (hash_cache_identity(repo, istate, &cache->state_oid)) {
		grep_worktree_cache_free(cache);
		return NULL;
	}
	allocate_cache_bitmaps(cache);
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
	struct hashfile *f = NULL;
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
	if (!current_index_matches(cache))
		goto done;

	oidclr(&sidecar_oid, cache->repo->hash_algo);
	CALLOC_ARRAY(known, cache->bitmap_size);
	CALLOC_ARRAY(equal, cache->bitmap_size);
	if (load_cache(cache, known, equal, &sidecar_oid,
		       &sidecar_present)) {
		if (!merge_updates(cache, known, equal))
			goto done;
	} else {
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
	f = NULL;
	if (commit_lock_file(&lock))
		goto done;

done:
	if (f)
		discard_hashfile(f);
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

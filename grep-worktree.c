#include "git-compat-util.h"
#include "grep-worktree.h"
#include "grep-index-identity.h"
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
#define GREP_WORKTREE_CACHE_VERSION 5
#define GREP_WORKTREE_CACHE_HEADER_SIZE 16

/*
 * The sidecar contains:
 *
 *   0                    signature
 *   4                    version
 *   8                    hash algorithm format ID
 *   12                   number of physical index entries
 *   16                   index generation hash
 *   16 + rawsz           equal bitmap
 *   16 + rawsz + mapsz   file checksum
 *
 * Bit i describes physical index position i. Unused bits in the final byte
 * must be zero.
 */
struct grep_worktree_cache {
	struct repository *repo;
	struct index_state *istate;
	struct object_id state_oid;
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
static int hash_cache_identity(struct repository *repo,
			       struct index_state *istate,
			       struct object_id *oid)
{
	struct grep_index_identity identity;

	if (grep_index_identity_get(repo, istate, &identity))
		return -1;
	oidcpy(oid, &identity.worktree);
	return 0;
}

static int load_cache(struct grep_worktree_cache *cache,
		      unsigned char *equal,
		      struct object_id *file_oid, int *file_present)
{
	struct strbuf path = STRBUF_INIT;
	struct git_hash_ctx ctx;
	const unsigned char *map;
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
		   cache->bitmap_size;
	if (map_size != expected ||
	    !hashfile_checksum_valid(cache->repo->hash_algo, map, map_size) ||
	    get_be32(map) != GREP_WORKTREE_CACHE_SIGNATURE ||
	    get_be32(map + 4) != GREP_WORKTREE_CACHE_VERSION ||
	    get_be32(map + 8) != cache->repo->hash_algo->format_id ||
	    get_be32(map + 12) != cache->istate->cache_nr ||
	    !hasheq(map + GREP_WORKTREE_CACHE_HEADER_SIZE,
		    cache->state_oid.hash, cache->repo->hash_algo))
		goto unmap;

	map_equal = map + GREP_WORKTREE_CACHE_HEADER_SIZE + rawsz;
	if (cache->istate->cache_nr & 7) {
		unsigned char valid =
			(1u << (cache->istate->cache_nr & 7)) - 1;

		if (map_equal[cache->bitmap_size - 1] & ~valid)
			goto unmap;
	}
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
	if (cache->equal)
		return;
	CALLOC_ARRAY(cache->equal, cache->bitmap_size);
	CALLOC_ARRAY(cache->updated, cache->bitmap_size);
}

static int current_index_matches(struct grep_worktree_cache *cache)
{
	struct index_state istate = INDEX_STATE_INIT(cache->repo);
	struct object_id oid;
	int result = 0;

	istate.lazy_cache_tree = 1;
	if (read_index_from(&istate, repo_get_index_file(cache->repo),
			    repo_get_git_dir(cache->repo)) < 0)
		return 0;
	if (!hash_cache_identity(cache->repo, &istate, &oid))
		result = oideq(&oid, &cache->state_oid);
	discard_index(&istate);
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
	allocate_cache_bitmaps(cache);
	load_cache(cache, cache->equal,
		   &cache->sidecar_oid, &cache->sidecar_present);
	return cache;
}

enum grep_worktree_cache_result grep_worktree_cache_lookup(
	struct grep_worktree_cache *cache, size_t pos)
{
	unsigned char mask;

	if (!cache || !cache->equal || pos >= cache->istate->cache_nr)
		return GREP_WORKTREE_CACHE_UNKNOWN;
	mask = 1u << (pos & 7);
	return cache->equal[pos >> 3] & mask ?
		       GREP_WORKTREE_CACHE_EQUAL :
		       GREP_WORKTREE_CACHE_UNKNOWN;
}

void grep_worktree_cache_record(struct grep_worktree_cache *cache, size_t pos,
				int equal)
{
	unsigned char mask;
	unsigned char *cached_equal;

	if (!cache || !cache->equal || pos >= cache->istate->cache_nr)
		return;
	mask = 1u << (pos & 7);
	cached_equal = &cache->equal[pos >> 3];
	if (equal) {
		if (*cached_equal & mask)
			return;
		*cached_equal |= mask;
		cache->recorded_equal++;
	} else {
		cache->recorded_different++;
		if (!(*cached_equal & mask))
			return;
		*cached_equal &= ~mask;
	}
	cache->updated[pos >> 3] |= mask;
	cache->changed = 1;
}

void grep_worktree_cache_hit(struct grep_worktree_cache *cache)
{
	if (cache)
		cache->hits++;
}

void grep_worktree_cache_write(struct grep_worktree_cache *cache)
{
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
	CALLOC_ARRAY(equal, cache->bitmap_size);
	if (load_cache(cache, equal, &sidecar_oid,
		       &sidecar_present)) {
		if (sidecar_present != cache->sidecar_present ||
		    !oideq(&sidecar_oid, &cache->sidecar_oid))
			goto done;
	} else {
		if (sidecar_present != cache->sidecar_present ||
		    (sidecar_present &&
		     !oideq(&sidecar_oid, &cache->sidecar_oid)))
			goto done;
	}
	COPY_ARRAY(equal, cache->equal, cache->bitmap_size);

	f = hashfd(cache->repo->hash_algo, fd, get_lock_file_path(&lock));
	hashwrite_be32(f, GREP_WORKTREE_CACHE_SIGNATURE);
	hashwrite_be32(f, GREP_WORKTREE_CACHE_VERSION);
	hashwrite_be32(f, cache->repo->hash_algo->format_id);
	hashwrite_be32(f, cache->istate->cache_nr);
	hashwrite(f, cache->state_oid.hash, cache->repo->hash_algo->rawsz);
	hashwrite(f, equal, cache->bitmap_size);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	f = NULL;
	if (commit_lock_file(&lock))
		goto done;

done:
	if (f)
		discard_hashfile(f);
	rollback_lock_file(&lock);
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
	free(cache->equal);
	free(cache->updated);
	free(cache);
}

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
#include "split-index.h"
#include "strbuf.h"
#include "trace2.h"
#include "wrapper.h"

#define GREP_WORKTREE_CACHE_SIGNATURE 0x47574243
#define GREP_WORKTREE_CACHE_VERSION	6
#define GREP_WORKTREE_CACHE_HEADER_SIZE 20

enum grep_worktree_cache_section {
	GREP_WORKTREE_CACHE_EXACT = 1,
	GREP_WORKTREE_CACHE_SPLIT_BASE = 2,
};

/*
 * The sidecar contains:
 *
 *   0                    signature
 *   4                    version
 *   8                    hash algorithm format ID
 *   12                   number of physical index entries
 *   16                   number of shared-index entries
 *   20                   index generation hash
 *   20 + rawsz           scoped shared-index identity
 *   20 + 2*rawsz         equal bitmap
 *   20 + 2*rawsz + mapsz shared-index equal bitmap
 *   20 + 2*rawsz +
 *      mapsz + basemapsz file checksum
 *
 * The first bitmap describes physical merged-index positions. The second
 * describes positions in the immutable split-index base. Unused bits in the
 * final byte of either bitmap must be zero.
 */
struct grep_worktree_cache {
	struct repository *repo;
	struct index_state *istate;
	struct object_id state_oid;
	struct object_id split_base_identity;
	unsigned char *equal;
	unsigned char *updated;
	unsigned char *split_base_equal;
	unsigned char *split_base_updated;
	size_t bitmap_size;
	size_t split_base_nr;
	size_t split_base_bitmap_size;
	uint64_t hits;
	uint64_t recorded_equal;
	uint64_t recorded_different;
	uint64_t recovered_split_base;
	int exact_changed;
	int split_base_changed;
};

static void grep_worktree_cache_path(struct repository *repo,
				     struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-worktree", repo_get_index_file(repo));
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

static size_t bitmap_size(size_t nr)
{
	return nr / 8 + !!(nr & 7);
}

static int load_cache(struct grep_worktree_cache *cache,
		      unsigned char *equal,
		      unsigned char *split_base_equal)
{
	struct strbuf path = STRBUF_INIT;
	const unsigned char *map;
	const unsigned char *map_equal;
	const unsigned char *map_split_base_equal;
	struct object_id map_split_base_identity;
	uint32_t map_nr;
	uint32_t map_split_base_nr;
	size_t expected;
	size_t map_size;
	size_t map_bitmap_size;
	size_t map_split_base_bitmap_size;
	size_t rawsz = cache->repo->hash_algo->rawsz;
	int result = 0;

	grep_worktree_cache_path(cache->repo, &path);
	map = map_file(path.buf, &map_size);
	if (!map)
		goto done;
	if (map_size < GREP_WORKTREE_CACHE_HEADER_SIZE + 3 * rawsz ||
	    get_be32(map) != GREP_WORKTREE_CACHE_SIGNATURE ||
	    get_be32(map + 4) != GREP_WORKTREE_CACHE_VERSION ||
	    get_be32(map + 8) != cache->repo->hash_algo->format_id)
		goto unmap;

	map_nr = get_be32(map + 12);
	map_split_base_nr = get_be32(map + 16);
	map_bitmap_size = bitmap_size(map_nr);
	map_split_base_bitmap_size = bitmap_size(map_split_base_nr);
	expected = st_add4(GREP_WORKTREE_CACHE_HEADER_SIZE,
			   st_mult(3, rawsz), map_bitmap_size,
			   map_split_base_bitmap_size);
	if (map_size != expected ||
	    !hashfile_checksum_valid(cache->repo->hash_algo, map, map_size))
		goto unmap;
	map_equal = map + GREP_WORKTREE_CACHE_HEADER_SIZE + 2 * rawsz;
	map_split_base_equal = map_equal + map_bitmap_size;
	oidread(&map_split_base_identity,
		map + GREP_WORKTREE_CACHE_HEADER_SIZE + rawsz,
		cache->repo->hash_algo);
	if ((!map_split_base_nr &&
	     !is_null_oid(&map_split_base_identity)) ||
	    (map_split_base_nr &&
	     is_null_oid(&map_split_base_identity)))
		goto unmap;
	if (map_nr & 7) {
		unsigned char valid =
			(1u << (map_nr & 7)) - 1;

		if (map_equal[map_bitmap_size - 1] & ~valid)
			goto unmap;
	}
	if (map_split_base_nr & 7) {
		unsigned char valid =
			(1u << (map_split_base_nr & 7)) - 1;

		if (map_split_base_equal[map_split_base_bitmap_size - 1] &
		    ~valid)
			goto unmap;
	}
	if (map_nr == cache->istate->cache_nr &&
	    hasheq(map + GREP_WORKTREE_CACHE_HEADER_SIZE,
		   cache->state_oid.hash, cache->repo->hash_algo)) {
		memcpy(equal, map_equal, cache->bitmap_size);
		result |= GREP_WORKTREE_CACHE_EXACT;
	}
	if (cache->split_base_nr &&
	    map_split_base_nr == cache->split_base_nr &&
	    oideq(&map_split_base_identity,
		  &cache->split_base_identity)) {
		memcpy(split_base_equal, map_split_base_equal,
		       cache->split_base_bitmap_size);
		result |= GREP_WORKTREE_CACHE_SPLIT_BASE;
	}

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
	CALLOC_ARRAY(cache->split_base_equal,
		     cache->split_base_bitmap_size);
	CALLOC_ARRAY(cache->split_base_updated,
		     cache->split_base_bitmap_size);
}

static int update_cache_bit(unsigned char *equal, unsigned char *updated,
			    size_t pos, int value)
{
	unsigned char mask = 1u << (pos & 7);

	if (value) {
		if (equal[pos >> 3] & mask)
			return 0;
		equal[pos >> 3] |= mask;
	} else {
		equal[pos >> 3] &= ~mask;
	}
	updated[pos >> 3] |= mask;
	return 1;
}

static int split_base_position(struct grep_worktree_cache *cache,
			       size_t pos, size_t *split_base_pos)
{
	const struct cache_entry *ce;
	struct split_index *si = cache->istate->split_index;

	if (!si || !si->base || pos >= cache->istate->cache_nr)
		return 0;
	ce = cache->istate->cache[pos];
	/*
	 * merge_base_index() leaves unchanged base entries shared with the
	 * merged index. Replacements retain their base position but set
	 * CE_UPDATE_IN_BASE.
	 */
	if (!(ce->ce_flags & CE_FSMONITOR_VALID) || !ce->index ||
	    ce->index > si->base->cache_nr ||
	    ce->ce_flags & CE_UPDATE_IN_BASE ||
	    ce != si->base->cache[ce->index - 1])
		return 0;
	*split_base_pos = ce->index - 1;
	return 1;
}

struct grep_worktree_cache *grep_worktree_cache_load(
	struct repository *repo, struct index_state *istate,
	int *sidecar_loaded)
{
	struct grep_worktree_cache *cache;
	struct grep_index_identity identity;
	int loaded;

	*sidecar_loaded = 0;
	if (!istate->fsmonitor_last_update || !istate->cache_nr)
		return NULL;

	CALLOC_ARRAY(cache, 1);
	cache->repo = repo;
	cache->istate = istate;
	cache->bitmap_size = bitmap_size(istate->cache_nr);
	if (istate->split_index && istate->split_index->base) {
		cache->split_base_nr =
			istate->split_index->base->cache_nr;
		cache->split_base_bitmap_size =
			bitmap_size(cache->split_base_nr);
	}
	if (grep_index_identity_get(repo, istate, &identity)) {
		grep_worktree_cache_free(cache);
		return NULL;
	}
	oidcpy(&cache->state_oid, &identity.worktree);
	oidcpy(&cache->split_base_identity,
	       &identity.worktree_split_base_identity);
	allocate_cache_bitmaps(cache);
	loaded = load_cache(cache, cache->equal,
			    cache->split_base_equal);
	*sidecar_loaded = !!loaded;
	return cache;
}

enum grep_worktree_cache_result grep_worktree_cache_lookup(
	struct grep_worktree_cache *cache, size_t pos)
{
	unsigned char mask;
	size_t split_base_pos;

	if (!cache || !cache->equal || pos >= cache->istate->cache_nr)
		return GREP_WORKTREE_CACHE_UNKNOWN;
	if (!(cache->istate->cache[pos]->ce_flags & CE_FSMONITOR_VALID))
		return GREP_WORKTREE_CACHE_UNKNOWN;
	mask = 1u << (pos & 7);
	if (cache->equal[pos >> 3] & mask) {
		if (split_base_position(cache, pos, &split_base_pos) &&
		    update_cache_bit(cache->split_base_equal,
				     cache->split_base_updated,
				     split_base_pos, 1))
			cache->split_base_changed = 1;
		return GREP_WORKTREE_CACHE_EQUAL;
	}
	if (split_base_position(cache, pos, &split_base_pos) &&
	    cache->split_base_equal[split_base_pos >> 3] &
		    (1u << (split_base_pos & 7))) {
		cache->recovered_split_base++;
		return GREP_WORKTREE_CACHE_EQUAL;
	}
	return GREP_WORKTREE_CACHE_UNKNOWN;
}

void grep_worktree_cache_record(struct grep_worktree_cache *cache, size_t pos,
				int equal)
{
	size_t split_base_pos;

	if (!cache || !cache->equal || pos >= cache->istate->cache_nr)
		return;
	if (equal) {
		if (update_cache_bit(cache->equal, cache->updated,
				     pos, 1)) {
			cache->recorded_equal++;
			cache->exact_changed = 1;
		}
	} else {
		cache->recorded_different++;
		update_cache_bit(cache->equal, cache->updated, pos, 0);
		cache->exact_changed = 1;
	}
	if (split_base_position(cache, pos, &split_base_pos)) {
		if (update_cache_bit(cache->split_base_equal,
				     cache->split_base_updated,
				     split_base_pos, equal))
			cache->split_base_changed = 1;
	}
}

void grep_worktree_cache_hit(struct grep_worktree_cache *cache)
{
	if (cache)
		cache->hits++;
}

void grep_worktree_cache_write(struct grep_worktree_cache *cache)
{
	unsigned char *equal = NULL;
	unsigned char *split_base_equal = NULL;
	struct grep_worktree_cache current = { 0 };
	struct grep_index_identity identity;
	struct index_state istate = INDEX_STATE_INIT(NULL);
	struct hashfile *f = NULL;
	struct lock_file lock = LOCK_INIT;
	struct strbuf path = STRBUF_INIT;
	int exact_matches;
	int fd;
	int output_changed = 0;
	int split_base_matches;

	if (!cache ||
	    (!cache->exact_changed && !cache->split_base_changed) ||
	    !use_optional_locks())
		return;

	istate.repo = cache->repo;
	grep_worktree_cache_path(cache->repo, &path);
	fd = hold_lock_file_for_update_mode(&lock, path.buf, 0, 0444);
	if (fd < 0)
		goto done;
	istate.lazy_cache_tree = 1;
	if (read_index_from(&istate, repo_get_index_file(cache->repo),
			    repo_get_git_dir(cache->repo)) < 0 ||
	    grep_index_identity_get(cache->repo, &istate, &identity))
		goto done;

	current.repo = cache->repo;
	current.istate = &istate;
	current.bitmap_size = bitmap_size(istate.cache_nr);
	oidcpy(&current.state_oid, &identity.worktree);
	oidcpy(&current.split_base_identity,
	       &identity.worktree_split_base_identity);
	if (istate.split_index && istate.split_index->base) {
		current.split_base_nr = istate.split_index->base->cache_nr;
		current.split_base_bitmap_size =
			bitmap_size(current.split_base_nr);
	}
	exact_matches = cache->exact_changed &&
			current.bitmap_size == cache->bitmap_size &&
			oideq(&current.state_oid, &cache->state_oid);
	split_base_matches =
		cache->split_base_changed &&
		current.split_base_nr == cache->split_base_nr &&
		current.split_base_nr &&
		oideq(&current.split_base_identity,
		      &cache->split_base_identity);
	if (!exact_matches && !split_base_matches)
		goto done;

	CALLOC_ARRAY(equal, current.bitmap_size);
	CALLOC_ARRAY(split_base_equal, current.split_base_bitmap_size);
	load_cache(&current, equal, split_base_equal);
	if (exact_matches) {
		for (size_t i = 0; i < current.bitmap_size; i++) {
			unsigned char merged =
				(equal[i] & ~cache->updated[i]) |
				(cache->equal[i] & cache->updated[i]);

			if (merged != equal[i])
				output_changed = 1;
			equal[i] = merged;
		}
	}
	if (split_base_matches) {
		for (size_t i = 0;
		     i < current.split_base_bitmap_size; i++) {
			unsigned char merged =
				(split_base_equal[i] &
				 ~cache->split_base_updated[i]) |
				(cache->split_base_equal[i] &
				 cache->split_base_updated[i]);

			if (merged != split_base_equal[i])
				output_changed = 1;
			split_base_equal[i] = merged;
		}
	}
	if (!output_changed)
		goto done;

	f = hashfd(cache->repo->hash_algo, fd, get_lock_file_path(&lock));
	hashwrite_be32(f, GREP_WORKTREE_CACHE_SIGNATURE);
	hashwrite_be32(f, GREP_WORKTREE_CACHE_VERSION);
	hashwrite_be32(f, cache->repo->hash_algo->format_id);
	hashwrite_be32(f, istate.cache_nr);
	hashwrite_be32(f, current.split_base_nr);
	hashwrite(f, current.state_oid.hash,
		  cache->repo->hash_algo->rawsz);
	hashwrite(f, current.split_base_identity.hash,
		  cache->repo->hash_algo->rawsz);
	hashwrite(f, equal, current.bitmap_size);
	hashwrite(f, split_base_equal, current.split_base_bitmap_size);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	f = NULL;
	if (commit_lock_file(&lock))
		goto done;

done:
	if (f)
		discard_hashfile(f);
	rollback_lock_file(&lock);
	free(equal);
	free(split_base_equal);
	strbuf_release(&path);
	discard_index(&istate);
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
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/recovered_split_base",
			   cache->recovered_split_base);
	free(cache->equal);
	free(cache->updated);
	free(cache->split_base_equal);
	free(cache->split_base_updated);
	free(cache);
}

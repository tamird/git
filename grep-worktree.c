#include "git-compat-util.h"
#include "grep-worktree.h"
#include "grep-index-identity.h"
#include "csum-file.h"
#include "environment.h"
#include "gettext.h"
#include "lockfile.h"
#include "oid-array.h"
#include "parse.h"
#include "path.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "split-index.h"
#include "strbuf.h"
#include "tempfile.h"
#include "trace2.h"
#include "wrapper.h"

#define GREP_WORKTREE_CACHE_SIGNATURE 0x47574243
#define GREP_WORKTREE_CACHE_VERSION	8
#define GREP_WORKTREE_CACHE_HEADER_SIZE 20

#define GREP_WORKTREE_GENERATION_SIGNATURE   0x47574247
#define GREP_WORKTREE_GENERATION_VERSION     1
#define GREP_WORKTREE_GENERATION_HEADER_SIZE 12
#define GREP_WORKTREE_LOCK_TIMEOUT_MS	     100

#define GREP_WORKTREE_RECOVERY_SIGNATURE      0x47574252
#define GREP_WORKTREE_RECOVERY_VERSION	      1
#define GREP_WORKTREE_RECOVERY_HEADER_SIZE    16
#define GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES (1U << 16)
#define GREP_WORKTREE_RECOVERY_FANOUT_SIZE \
	(GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES * sizeof(uint32_t))
#define GREP_WORKTREE_RECOVERY_MIN_ENTRIES 1024

enum grep_worktree_cache_section {
	GREP_WORKTREE_CACHE_EXACT = 1,
	GREP_WORKTREE_CACHE_SPLIT_BASE = 2,
};

/*
 * The sidecar contains:
 *
 *   0                    signature
 *   4                    version
 *   8                    repository hash algorithm format ID
 *   12                   number of physical index entries
 *   16                   number of shared-index entries
 *   20                   index generation hash
 *   20 + rawsz           scoped shared-index identity
 *   20 + 2*rawsz         recovery sidecar checksum
 *   20 + 3*rawsz         observation generation
 *   20 + 4*rawsz         equal bitmap
 *   20 + 4*rawsz + mapsz different bitmap
 *   20 + 4*rawsz +
 *      2*mapsz            shared-index equal bitmap
 *   20 + 4*rawsz +
 *      2*mapsz + basemapsz
 *                         file checksum
 *
 * The first two bitmaps describe physical merged-index positions. A
 * different bit records that equality was disproved for that exact index
 * identity and prevents an older positive observer from restoring it. The
 * third bitmap describes positions in the immutable split-index base. Unused
 * bits in the final byte of each bitmap must be zero.
 *
 * The observation generation is stored separately as:
 *
 *   0                    signature
 *   4                    version
 *   8                    repository hash algorithm format ID
 *   12                   non-null generation
 *   12 + rawsz           file checksum
 *
 * Readers require the same generation before and after loading the compact
 * sidecar. A negative observer which cannot lock the compact sidecar replaces
 * the generation through an atomic rename or removes it. If neither operation
 * succeeds, it publishes an invalidation marker. The marker is level-triggered:
 * readers fail closed while it exists, and a writer which finds it knows that
 * its negative observations are covered. A reader repairs the cache while
 * holding the compact-sidecar lock. Rotating the generation before removing
 * the marker fences every writer which could have loaded cache state before
 * the marker was published; readers starting during repair either see the
 * marker or the new generation. Missing or malformed generations are repaired
 * only when optional locks are enabled.
 */

/*
 * The recovery sidecar contains:
 *
 *   0                    signature
 *   4                    version
 *   8                    repository hash algorithm format ID
 *   12                   number of equal entry identities
 *   16                   worktree scope identity
 *   16 + rawsz           16-bit fanout table
 *   16 + rawsz + 262144  sorted SHA-256 entry identities
 *   16 + rawsz + 262144 +
 *      32*count          file checksum
 *
 * The scope and entry identity together describe an equality observation
 * which remains useful across unrelated index changes while fsmonitor reports
 * no later worktree change.
 *
 * The compact sidecar authorizes exactly one immutable recovery file by its
 * checksum. The recovery file is published first, so an interrupted update
 * leaves an unauthorized file that readers ignore. A validated recovery hit
 * may be promoted into the ordinary equal bitmap, which binds it to the exact
 * index state. Malformed or missing recovery data causes misses; clearing its
 * authorization is only a best-effort optimization.
 */
struct grep_worktree_cache {
	struct repository *repo;
	struct index_state *istate;
	struct grep_worktree_entry_identity entry_identity;
	struct object_id state_oid;
	struct object_id worktree_scope;
	struct object_id split_base_identity;
	struct object_id recovery_checksum;
	struct object_id observation_generation;
	struct object_id compact_checksum;
	const unsigned char *recovery_map;
	const uint32_t *recovery_fanout;
	const unsigned char *recovery_entries;
	struct oid_array negative_entries;
	unsigned char *equal;
	unsigned char *different;
	unsigned char *negative_observed;
	unsigned char *updated;
	unsigned char *recovered;
	unsigned char *split_base_equal;
	unsigned char *split_base_updated;
	size_t bitmap_size;
	size_t split_base_nr;
	size_t split_base_bitmap_size;
	size_t recovery_map_size;
	uint64_t hits;
	uint64_t recorded_equal;
	uint64_t recorded_different;
	uint64_t recovered_identity;
	uint64_t recovered_split_base;
	uint64_t direct_write;
	uint64_t negative_noop;
	int split_index;
	int recovery_checksum_checked;
	int recovery_checksum_valid;
	int recovery_load_attempted;
	int recovery_invalid;
	int recovery_revoked;
	int compact_loaded;
	int exact_changed;
	int split_base_changed;
};

static void grep_worktree_cache_path(struct repository *repo,
				     struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-worktree", repo_get_index_file(repo));
}

static void grep_worktree_recovery_path(struct repository *repo,
					struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-worktree-recovery",
		    repo_get_index_file(repo));
}

static void grep_worktree_observation_generation_path(
	struct repository *repo, struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-worktree-generation",
		    repo_get_index_file(repo));
}

static void grep_worktree_invalidation_path(struct repository *repo,
					    struct strbuf *path)
{
	strbuf_addf(path, "%s.grep-worktree-invalid",
		    repo_get_index_file(repo));
}

static int invalidation_marker_exists(struct repository *repo)
{
	struct strbuf path = STRBUF_INIT;
	struct stat st;
	int result;

	grep_worktree_invalidation_path(repo, &path);
	result = lstat(path.buf, &st);
	strbuf_release(&path);
	if (!result)
		return 1;
	return errno == ENOENT ? 0 : -1;
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

static int load_observation_generation(struct repository *repo,
				       struct object_id *oid)
{
	struct strbuf path = STRBUF_INIT;
	const unsigned char *map = NULL;
	size_t expected = GREP_WORKTREE_GENERATION_HEADER_SIZE +
			  2 * repo->hash_algo->rawsz;
	size_t map_size = 0;
	int result = -1;

	oidclr(oid, repo->hash_algo);
	grep_worktree_observation_generation_path(repo, &path);
	map = map_file(path.buf, &map_size);
	if (!map ||
	    map_size != expected ||
	    get_be32(map) != GREP_WORKTREE_GENERATION_SIGNATURE ||
	    get_be32(map + 4) != GREP_WORKTREE_GENERATION_VERSION ||
	    get_be32(map + 8) != repo->hash_algo->format_id ||
	    !hashfile_checksum_valid(repo->hash_algo, map, map_size))
		goto done;
	oidread(oid, map + GREP_WORKTREE_GENERATION_HEADER_SIZE,
		repo->hash_algo);
	if (is_null_oid(oid))
		goto done;
	result = 0;

done:
	if (map)
		munmap((void *)map, map_size);
	strbuf_release(&path);
	return result;
}

static int rotate_observation_generation(
	struct grep_worktree_cache *cache)
{
	struct object_id observation_generation;
	struct hashfile *f = NULL;
	struct strbuf path = STRBUF_INIT;
	struct strbuf temp_path = STRBUF_INIT;
	struct tempfile *temp = NULL;
	int saved_errno = 0;
	int result = -1;

	oidclr(&observation_generation, cache->repo->hash_algo);
	do {
		if (csprng_bytes(observation_generation.hash,
				 cache->repo->hash_algo->rawsz, 0) < 0)
			goto done;
	} while (is_null_oid(&observation_generation));
	grep_worktree_observation_generation_path(cache->repo, &path);
	strbuf_addf(&temp_path, "%s.tmp_XXXXXX", path.buf);
	temp = mks_tempfile_m(temp_path.buf, 0444);
	if (!temp)
		goto done;
	f = hashfd(cache->repo->hash_algo, get_tempfile_fd(temp),
		   get_tempfile_path(temp));
	hashwrite_be32(f, GREP_WORKTREE_GENERATION_SIGNATURE);
	hashwrite_be32(f, GREP_WORKTREE_GENERATION_VERSION);
	hashwrite_be32(f, cache->repo->hash_algo->format_id);
	hashwrite(f, observation_generation.hash,
		  cache->repo->hash_algo->rawsz);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	f = NULL;
	if (rename_tempfile(&temp, path.buf))
		goto done;
	oidcpy(&cache->observation_generation,
	       &observation_generation);
	result = 0;

done:
	saved_errno = errno;
	if (f)
		discard_hashfile(f);
	delete_tempfile(&temp);
	strbuf_release(&path);
	strbuf_release(&temp_path);
	if (result)
		errno = saved_errno;
	return result;
}

static int invalidate_observation_generation(
	struct grep_worktree_cache *cache)
{
	struct strbuf path = STRBUF_INIT;
	int result = -1;

	if (git_env_bool("GIT_TEST_GREP_WORKTREE_INVALIDATION_FAILURE", 0)) {
		errno = EACCES;
		return -1;
	}
	if (!rotate_observation_generation(cache))
		return 0;
	grep_worktree_observation_generation_path(cache->repo, &path);
	if (!unlink(path.buf) || errno == ENOENT)
		result = 0;
	strbuf_release(&path);
	return result;
}

static int write_invalidation_marker(struct grep_worktree_cache *cache)
{
	struct strbuf path = STRBUF_INIT;
	int fd;
	int result = -1;
	int saved_errno;

	grep_worktree_invalidation_path(cache->repo, &path);
	/*
	 * Creating the file publishes invalidation immediately. A lockfile
	 * would leave an ignored artifact if the process died before rename.
	 */
	fd = open(path.buf, O_WRONLY | O_CREAT | O_EXCL, 0444);
	if (fd >= 0) {
		close(fd);
		result = 0;
	} else if (errno == EEXIST) {
		result = 0;
	}
	saved_errno = errno;
	strbuf_release(&path);
	if (result)
		errno = saved_errno;
	return result;
}

static size_t bitmap_size(size_t nr)
{
	return nr / 8 + !!(nr & 7);
}

static int load_cache(struct grep_worktree_cache *cache,
		      unsigned char *equal,
		      unsigned char *different,
		      unsigned char *split_base_equal)
{
	struct strbuf path = STRBUF_INIT;
	const unsigned char *map;
	const unsigned char *map_different;
	const unsigned char *map_equal;
	const unsigned char *map_split_base_equal;
	struct object_id map_observation_generation;
	struct object_id map_recovery_checksum;
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
	if (map_size < GREP_WORKTREE_CACHE_HEADER_SIZE + 5 * rawsz ||
	    get_be32(map) != GREP_WORKTREE_CACHE_SIGNATURE ||
	    get_be32(map + 4) != GREP_WORKTREE_CACHE_VERSION ||
	    get_be32(map + 8) != cache->repo->hash_algo->format_id)
		goto unmap;

	map_nr = get_be32(map + 12);
	map_split_base_nr = get_be32(map + 16);
	map_bitmap_size = bitmap_size(map_nr);
	map_split_base_bitmap_size = bitmap_size(map_split_base_nr);
	expected = st_add4(GREP_WORKTREE_CACHE_HEADER_SIZE,
			   st_mult(5, rawsz),
			   st_mult(2, map_bitmap_size),
			   map_split_base_bitmap_size);
	if (map_size != expected ||
	    !hashfile_checksum_valid(cache->repo->hash_algo, map, map_size))
		goto unmap;
	map_equal = map + GREP_WORKTREE_CACHE_HEADER_SIZE + 4 * rawsz;
	map_different = map_equal + map_bitmap_size;
	map_split_base_equal = map_different + map_bitmap_size;
	oidread(&map_split_base_identity,
		map + GREP_WORKTREE_CACHE_HEADER_SIZE + rawsz,
		cache->repo->hash_algo);
	oidread(&map_recovery_checksum,
		map + GREP_WORKTREE_CACHE_HEADER_SIZE + 2 * rawsz,
		cache->repo->hash_algo);
	oidread(&map_observation_generation,
		map + GREP_WORKTREE_CACHE_HEADER_SIZE + 3 * rawsz,
		cache->repo->hash_algo);
	if (!oideq(&map_observation_generation,
		   &cache->observation_generation))
		goto unmap;
	if ((!map_split_base_nr &&
	     !is_null_oid(&map_split_base_identity)) ||
	    (map_split_base_nr &&
	     is_null_oid(&map_split_base_identity)) ||
	    (map_split_base_nr &&
	     !is_null_oid(&map_recovery_checksum)))
		goto unmap;
	if (map_nr & 7) {
		unsigned char valid =
			(1u << (map_nr & 7)) - 1;

		if ((map_equal[map_bitmap_size - 1] |
		     map_different[map_bitmap_size - 1]) &
		    ~valid)
			goto unmap;
	}
	for (size_t i = 0; i < map_bitmap_size; i++)
		if (map_equal[i] & map_different[i])
			goto unmap;
	if (map_split_base_nr & 7) {
		unsigned char valid =
			(1u << (map_split_base_nr & 7)) - 1;

		if (map_split_base_equal[map_split_base_bitmap_size - 1] &
		    ~valid)
			goto unmap;
	}
	oidread(&cache->compact_checksum, map + map_size - rawsz,
		cache->repo->hash_algo);
	cache->compact_loaded = 1;
	oidcpy(&cache->recovery_checksum, &map_recovery_checksum);
	if (map_nr == cache->istate->cache_nr &&
	    hasheq(map + GREP_WORKTREE_CACHE_HEADER_SIZE,
		   cache->state_oid.hash, cache->repo->hash_algo)) {
		memcpy(equal, map_equal, cache->bitmap_size);
		memcpy(different, map_different, cache->bitmap_size);
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

int grep_worktree_cache_entry_refreshable(const struct cache_entry *ce)
{
	return S_ISREG(ce->ce_mode) && !ce_skip_worktree(ce) &&
	       !ce_stage(ce) && !ce_intent_to_add(ce) &&
	       !(ce->ce_flags & (CE_VALID | CE_REMOVE));
}

int grep_worktree_cache_entry_eligible(const struct cache_entry *ce)
{
	return grep_worktree_cache_entry_refreshable(ce) &&
	       (ce->ce_flags & CE_FSMONITOR_VALID);
}

static int load_recovery(struct grep_worktree_cache *cache)
{
	struct object_id scope;
	struct strbuf path = STRBUF_INIT;
	const unsigned char *entries;
	const uint32_t *fanout;
	const unsigned char *map;
	uint32_t count;
	size_t overhead;
	size_t expected;
	size_t map_size;
	size_t entry_rawsz = GREP_WORKTREE_ENTRY_IDENTITY_RAWSZ;
	size_t rawsz = cache->repo->hash_algo->rawsz;
	int result = 0;

	if (cache->recovery_load_attempted)
		return !!cache->recovery_map;
	cache->recovery_load_attempted = 1;
	if (cache->split_index ||
	    is_null_oid(&cache->recovery_checksum))
		return 0;
	grep_worktree_recovery_path(cache->repo, &path);
	map = map_file(path.buf, &map_size);
	if (!map) {
		cache->recovery_invalid = 1;
		goto done;
	}
	if (map_size < GREP_WORKTREE_RECOVERY_HEADER_SIZE +
			       GREP_WORKTREE_RECOVERY_FANOUT_SIZE +
			       2 * rawsz ||
	    get_be32(map) != GREP_WORKTREE_RECOVERY_SIGNATURE ||
	    get_be32(map + 4) != GREP_WORKTREE_RECOVERY_VERSION ||
	    get_be32(map + 8) != cache->repo->hash_algo->format_id)
		goto unmap;
	count = get_be32(map + 12);
	overhead = GREP_WORKTREE_RECOVERY_HEADER_SIZE +
		   GREP_WORKTREE_RECOVERY_FANOUT_SIZE + 2 * rawsz;
	if (count > (map_size - overhead) / entry_rawsz)
		goto unmap;
	expected = overhead + count * entry_rawsz;
	if (map_size != expected ||
	    !hasheq(map + map_size - rawsz,
		    cache->recovery_checksum.hash,
		    cache->repo->hash_algo))
		goto unmap;
	oidread(&scope, map + GREP_WORKTREE_RECOVERY_HEADER_SIZE,
		cache->repo->hash_algo);
	if (!oideq(&scope, &cache->worktree_scope))
		goto unmap;

	fanout = (const uint32_t *)(map +
				    GREP_WORKTREE_RECOVERY_HEADER_SIZE + rawsz);
	entries = (const unsigned char *)fanout +
		  GREP_WORKTREE_RECOVERY_FANOUT_SIZE;
	for (size_t i = 0, previous = 0;
	     i < GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES; i++) {
		uint32_t value = get_be32((const unsigned char *)fanout +
					  i * sizeof(uint32_t));

		if (value < previous || value > count)
			goto unmap;
		previous = value;
		if (i == GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES - 1 &&
		    value != count)
			goto unmap;
	}
	cache->recovery_map = map;
	cache->recovery_map_size = map_size;
	cache->recovery_fanout = fanout;
	cache->recovery_entries = entries;
	result = 1;
	goto done;

unmap:
	munmap((void *)map, map_size);
	cache->recovery_invalid = 1;
done:
	strbuf_release(&path);
	return result;
}

static int recovery_checksum_valid(struct grep_worktree_cache *cache)
{
	if (!cache->recovery_checksum_checked) {
		cache->recovery_checksum_valid =
			hashfile_checksum_valid(cache->repo->hash_algo,
						cache->recovery_map,
						cache->recovery_map_size);
		cache->recovery_checksum_checked = 1;
		if (!cache->recovery_checksum_valid)
			cache->recovery_invalid = 1;
	}
	return cache->recovery_checksum_valid;
}

static int recovery_contains_oid(struct grep_worktree_cache *cache,
				 const struct object_id *entry_oid)
{
	const unsigned char *entries;
	const unsigned char *hash = entry_oid->hash;
	size_t rawsz = GREP_WORKTREE_ENTRY_IDENTITY_RAWSZ;
	uint32_t bucket;
	uint32_t hi;
	uint32_t lo;

	if (cache->recovery_invalid ||
	    is_null_oid(&cache->recovery_checksum))
		return 0;
	if (!cache->recovery_map && !load_recovery(cache))
		return 0;
	entries = cache->recovery_entries;
	bucket = get_be16(hash);
	hi = get_be32((const unsigned char *)cache->recovery_fanout +
		      bucket * sizeof(uint32_t));
	lo = bucket ?
		     get_be32((const unsigned char *)cache->recovery_fanout +
			      (bucket - 1) * sizeof(uint32_t)) :
		     0;
	for (uint32_t i = lo; i < hi; i++) {
		int cmp = memcmp(entries + i * rawsz, hash, rawsz);

		if (!cmp)
			return recovery_checksum_valid(cache);
		if (cmp > 0)
			break;
	}
	return 0;
}

static int recovery_contains(struct grep_worktree_cache *cache,
			     const struct cache_entry *ce)
{
	struct object_id entry_oid;

	if (grep_worktree_entry_identity_hash(&cache->entry_identity, ce,
					      &entry_oid))
		return 0;
	return recovery_contains_oid(cache, &entry_oid);
}

static void allocate_cache_bitmaps(struct grep_worktree_cache *cache)
{
	if (cache->equal)
		return;
	CALLOC_ARRAY(cache->equal, cache->bitmap_size);
	CALLOC_ARRAY(cache->different, cache->bitmap_size);
	CALLOC_ARRAY(cache->negative_observed, cache->bitmap_size);
	CALLOC_ARRAY(cache->updated, cache->bitmap_size);
	CALLOC_ARRAY(cache->recovered, cache->bitmap_size);
	CALLOC_ARRAY(cache->split_base_equal,
		     cache->split_base_bitmap_size);
	CALLOC_ARRAY(cache->split_base_updated,
		     cache->split_base_bitmap_size);
}

static int update_cache_bit(unsigned char *equal, unsigned char *updated,
			    size_t pos, int value)
{
	unsigned char mask = 1u << (pos & 7);
	int old = !!(equal[pos >> 3] & mask);

	if (old == value)
		return 0;
	if (value)
		equal[pos >> 3] |= mask;
	else
		equal[pos >> 3] &= ~mask;
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
	struct lock_file lock = LOCK_INIT;
	struct object_id observation_generation;
	struct strbuf invalid_path = STRBUF_INIT;
	struct strbuf path = STRBUF_INIT;
	int invalid;
	int loaded;

	*sidecar_loaded = 0;
	if (!istate->fsmonitor_last_update || !istate->cache_nr)
		return NULL;

	CALLOC_ARRAY(cache, 1);
	cache->repo = repo;
	cache->istate = istate;
	invalid = invalidation_marker_exists(repo);
	if (invalid < 0)
		goto disable;
	if (invalid) {
		if (!use_optional_locks())
			goto disable;
		grep_worktree_cache_path(repo, &path);
		if (hold_lock_file_for_update_timeout_mode(
			    &lock, path.buf, 0,
			    GREP_WORKTREE_LOCK_TIMEOUT_MS, 0444) < 0)
			goto disable;
		invalid = invalidation_marker_exists(repo);
		if (invalid < 0)
			goto disable;
		if (invalid) {
			/*
			 * The compact lock keeps old writers from publishing
			 * across repair. Rotate first, so removing the marker
			 * cannot expose cache state from the old generation.
			 */
			if (rotate_observation_generation(cache))
				goto disable;
			grep_worktree_invalidation_path(repo, &invalid_path);
			if (unlink(invalid_path.buf) && errno != ENOENT)
				goto disable;
		}
		rollback_lock_file(&lock);
	}
	if (load_observation_generation(
		    repo, &cache->observation_generation) &&
	    (!use_optional_locks() ||
	     rotate_observation_generation(cache)))
		goto disable;
	cache->bitmap_size = bitmap_size(istate->cache_nr);
	if (istate->split_index && istate->split_index->base) {
		cache->split_index = 1;
		cache->split_base_nr =
			istate->split_index->base->cache_nr;
		cache->split_base_bitmap_size =
			bitmap_size(cache->split_base_nr);
	}
	if (grep_index_identity_get(repo, istate, &identity)) {
		goto disable;
	}
	oidcpy(&cache->state_oid, &identity.worktree);
	oidcpy(&cache->worktree_scope, &identity.worktree_scope);
	grep_worktree_entry_identity_init(repo, &cache->entry_identity);
	oidcpy(&cache->split_base_identity,
	       &identity.worktree_split_base_identity);
	allocate_cache_bitmaps(cache);
	loaded = load_cache(cache, cache->equal, cache->different,
			    cache->split_base_equal);
	if (load_observation_generation(repo, &observation_generation) ||
	    !oideq(&observation_generation,
		   &cache->observation_generation) ||
	    invalidation_marker_exists(repo)) {
		memset(cache->equal, 0, cache->bitmap_size);
		memset(cache->different, 0, cache->bitmap_size);
		memset(cache->split_base_equal, 0,
		       cache->split_base_bitmap_size);
		oidclr(&cache->compact_checksum, repo->hash_algo);
		oidclr(&cache->recovery_checksum, repo->hash_algo);
		cache->compact_loaded = 0;
		loaded = 0;
	}
	*sidecar_loaded =
		!!loaded ||
		(!cache->split_index &&
		 !is_null_oid(&cache->recovery_checksum));
	strbuf_release(&invalid_path);
	strbuf_release(&path);
	return cache;

disable:
	rollback_lock_file(&lock);
	strbuf_release(&invalid_path);
	strbuf_release(&path);
	free(cache);
	return NULL;
}

enum grep_worktree_cache_result grep_worktree_cache_lookup(
	struct grep_worktree_cache *cache, size_t pos)
{
	unsigned char mask;
	size_t split_base_pos;

	if (!cache || !cache->equal || pos >= cache->istate->cache_nr)
		return GREP_WORKTREE_CACHE_UNKNOWN;
	if (!grep_worktree_cache_entry_eligible(
		    cache->istate->cache[pos]))
		return GREP_WORKTREE_CACHE_UNKNOWN;
	mask = 1u << (pos & 7);
	if (cache->different[pos >> 3] & mask)
		return GREP_WORKTREE_CACHE_UNKNOWN;
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
	if (recovery_contains(cache, cache->istate->cache[pos])) {
		if (!(cache->recovered[pos >> 3] & mask)) {
			cache->recovered[pos >> 3] |= mask;
			cache->recovered_identity++;
		}
		return GREP_WORKTREE_CACHE_EQUAL;
	}
	return GREP_WORKTREE_CACHE_UNKNOWN;
}

void grep_worktree_cache_record(struct grep_worktree_cache *cache, size_t pos,
				int equal)
{
	int record_negative = 0;
	size_t split_base_pos;

	if (!cache || !cache->equal || pos >= cache->istate->cache_nr)
		return;
	if (equal) {
		if (!grep_worktree_cache_entry_eligible(
			    cache->istate->cache[pos]))
			return;
		if (cache->different[pos >> 3] &
		    (1u << (pos & 7)))
			return;
		if (update_cache_bit(cache->equal, cache->updated,
				     pos, 1)) {
			cache->recorded_equal++;
			cache->exact_changed = 1;
		}
	} else {
		int changed;

		cache->recorded_different++;
		changed = update_cache_bit(
			cache->equal, cache->updated, pos, 0);
		changed |= update_cache_bit(
			cache->different, cache->updated, pos, 1);
		if (changed)
			cache->exact_changed = 1;
		record_negative = 1;
	}
	if (split_base_position(cache, pos, &split_base_pos)) {
		if (update_cache_bit(cache->split_base_equal,
				     cache->split_base_updated,
				     split_base_pos, equal))
			cache->split_base_changed = 1;
	}
	if (record_negative)
		cache->negative_observed[pos >> 3] |= 1u << (pos & 7);
}

void grep_worktree_cache_hit(struct grep_worktree_cache *cache)
{
	if (cache)
		cache->hits++;
}

static int recovery_bootstrap_threshold_met(
	const struct grep_worktree_cache *cache)
{
	uint64_t observed = cache->recorded_equal;

	if (UINT64_MAX - observed < cache->hits)
		observed = UINT64_MAX;
	else
		observed += cache->hits;
	return observed >=
	       git_env_ulong("GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES",
			     GREP_WORKTREE_RECOVERY_MIN_ENTRIES);
}

static int recovery_promotion_threshold_met(
	const struct grep_worktree_cache *cache)
{
	return cache->recovered_identity >=
	       git_env_ulong("GIT_TEST_GREP_WORKTREE_RECOVERY_MIN_ENTRIES",
			     GREP_WORKTREE_RECOVERY_MIN_ENTRIES);
}

static void wait_for_test_write_phase(const char *phase)
{
	const char *hold = getenv("GIT_TEST_GREP_WORKTREE_WRITE_HOLD");
	const char *ready = getenv("GIT_TEST_GREP_WORKTREE_WRITE_READY");
	const char *requested =
		getenv("GIT_TEST_GREP_WORKTREE_WRITE_PHASE");

	if (!hold || !requested || strcmp(requested, phase))
		return;
	if (ready)
		write_file(ready, "%s", "");
	while (!access(hold, F_OK))
		sleep_millisec(10);
}

static int prepare_recovery(struct grep_worktree_cache *cache,
			    struct lock_file *lock,
			    struct object_id *recovery_checksum,
			    unsigned char **prepared_equal)
{
	unsigned char *included = NULL;
	struct object_id entry_oid;
	struct oid_array entries = OID_ARRAY_INIT;
	uint32_t *fanout = NULL;
	struct hashfile *f = NULL;
	struct strbuf path = STRBUF_INIT;
	int fd;
	int result = -1;

	oidclr(recovery_checksum, cache->repo->hash_algo);
	*prepared_equal = NULL;
	grep_worktree_recovery_path(cache->repo, &path);
	fd = hold_lock_file_for_update_mode(lock, path.buf, 0, 0444);
	if (fd < 0)
		goto done;
	CALLOC_ARRAY(included, cache->bitmap_size);
	CALLOC_ARRAY(fanout, GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES);
	for (size_t i = 0; i < cache->istate->cache_nr; i++) {
		if (!(cache->equal[i >> 3] & (1u << (i & 7))) ||
		    !grep_worktree_cache_entry_eligible(
			    cache->istate->cache[i]))
			continue;
		if (grep_worktree_entry_identity_hash(
			    &cache->entry_identity,
			    cache->istate->cache[i], &entry_oid))
			goto done;
		oid_array_append(&entries, &entry_oid);
		included[i >> 3] |= 1u << (i & 7);
	}
	if (entries.nr > UINT32_MAX)
		goto done;
	oid_array_sort(&entries);
	for (size_t i = 0; i < entries.nr; i++) {
		if (i && oideq(&entries.oid[i - 1], &entries.oid[i]))
			goto done;
		fanout[get_be16(entries.oid[i].hash)]++;
	}
	for (size_t i = 1;
	     i < GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES; i++)
		fanout[i] += fanout[i - 1];

	f = hashfd(cache->repo->hash_algo, fd, get_lock_file_path(lock));
	hashwrite_be32(f, GREP_WORKTREE_RECOVERY_SIGNATURE);
	hashwrite_be32(f, GREP_WORKTREE_RECOVERY_VERSION);
	hashwrite_be32(f, cache->repo->hash_algo->format_id);
	hashwrite_be32(f, entries.nr);
	hashwrite(f, cache->worktree_scope.hash,
		  cache->repo->hash_algo->rawsz);
	for (size_t i = 0;
	     i < GREP_WORKTREE_RECOVERY_FANOUT_ENTRIES; i++)
		hashwrite_be32(f, fanout[i]);
	for (size_t i = 0; i < entries.nr; i++)
		hashwrite(f, entries.oid[i].hash,
			  GREP_WORKTREE_ENTRY_IDENTITY_RAWSZ);
	finalize_hashfile(f, recovery_checksum->hash, FSYNC_COMPONENT_NONE,
			  CSUM_HASH_IN_STREAM);
	f = NULL;
	*prepared_equal = included;
	included = NULL;
	result = 0;

done:
	if (f)
		discard_hashfile(f);
	if (result)
		rollback_lock_file(lock);
	free(fanout);
	free(included);
	oid_array_clear(&entries);
	strbuf_release(&path);
	return result;
}

void grep_worktree_cache_write(struct grep_worktree_cache *cache)
{
	unsigned char *different = NULL;
	unsigned char *equal = NULL;
	unsigned char *negative_resolved = NULL;
	unsigned char *prepared_recovery_equal = NULL;
	unsigned char *split_base_equal = NULL;
	struct grep_worktree_cache current = { 0 };
	struct grep_worktree_cache *output = &current;
	struct grep_index_identity identity;
	struct index_state istate = INDEX_STATE_INIT(NULL);
	struct object_id prepared_recovery_checksum;
	struct hashfile *f = NULL;
	struct lock_file lock = LOCK_INIT;
	struct lock_file recovery_lock = LOCK_INIT;
	struct strbuf path = STRBUF_INIT;
	int bootstrap_recovery;
	int direct_current = 0;
	int exact_matches;
	int fd;
	int index_result;
	int loaded;
	int negative_safe;
	int output_changed = 0;
	int persist_recovered;
	int recovery_conflicts = 0;
	int repeated_negatives_only;
	int same_index = 0;
	int same_sources = 0;
	int source_matches;
	int split_base_matches;

	if (!cache || !use_optional_locks())
		return;
	bootstrap_recovery =
		!cache->split_index &&
		is_null_oid(&cache->recovery_checksum) &&
		recovery_bootstrap_threshold_met(cache);
	persist_recovered =
		recovery_promotion_threshold_met(cache);
	negative_safe = !cache->recorded_different;
	if (!cache->exact_changed && !persist_recovered &&
	    !cache->split_base_changed && !bootstrap_recovery &&
	    !cache->recovery_invalid && !cache->recorded_different)
		return;
	wait_for_test_write_phase("prelock");
	if (bootstrap_recovery &&
	    prepare_recovery(cache, &recovery_lock,
			     &prepared_recovery_checksum,
			     &prepared_recovery_equal))
		bootstrap_recovery = 0;
	if (!cache->exact_changed && !persist_recovered &&
	    !cache->split_base_changed && !bootstrap_recovery &&
	    !cache->recovery_invalid && !cache->recorded_different)
		goto done;
	repeated_negatives_only =
		cache->recorded_different &&
		!cache->exact_changed && !persist_recovered &&
		!cache->split_base_changed && !bootstrap_recovery &&
		!cache->recovery_invalid;
	wait_for_test_write_phase("recovery");

	istate.repo = cache->repo;
	grep_worktree_cache_path(cache->repo, &path);
	fd = hold_lock_file_for_update_timeout_mode(
		&lock, path.buf, 0,
		cache->recorded_different ?
			GREP_WORKTREE_LOCK_TIMEOUT_MS :
			0,
		0444);
	if (fd < 0)
		goto done;
	index_result = invalidation_marker_exists(cache->repo);
	if (index_result) {
		/*
		 * Repair cannot remove the marker without rotating the
		 * generation while holding this lock, so an existing marker
		 * already covers every negative observation from this writer.
		 */
		if (index_result > 0)
			negative_safe = 1;
		goto done;
	}
	index_result = load_observation_generation(
		cache->repo, &current.observation_generation);
	if (index_result ||
	    !oideq(&current.observation_generation,
		   &cache->observation_generation))
		goto done;
	if (cache->istate->index_file_stat_valid) {
		const unsigned char *map = NULL;
		const struct stat *old = &cache->istate->index_file_stat;
		struct stat st;
		size_t map_size = 0;
		size_t rawsz = cache->repo->hash_algo->rawsz;
		same_index =
			!stat(repo_get_index_file(cache->repo), &st) &&
			st.st_dev == old->st_dev &&
			st.st_ino == old->st_ino &&
			st.st_size == old->st_size &&
			st.st_mtime == old->st_mtime &&
			ST_MTIME_NSEC(st) == ST_MTIME_NSEC(*old) &&
			st.st_ctime == old->st_ctime &&
			ST_CTIME_NSEC(st) == ST_CTIME_NSEC(*old);

		if (same_index && cache->compact_loaded)
			map = map_file(path.buf, &map_size);
		if (map && map_size >= rawsz &&
		    hashfile_checksum_valid(cache->repo->hash_algo,
					    map, map_size) &&
		    hasheq(map + map_size - rawsz,
			   cache->compact_checksum.hash,
			   cache->repo->hash_algo))
			same_sources = 1;
		if (map)
			munmap((void *)map, map_size);
	}
	if (same_sources && repeated_negatives_only) {
		/*
		 * Every negative already found a sticky different bit, so no
		 * mutation is pending. The index stat preserves the positional
		 * interpretation, while the compact checksum preserves the full
		 * source snapshot, including prior recovery revocation and
		 * split-base clearing. An index mismatch falls through to identity
		 * remapping; a compact mismatch reloads and positionally merges the
		 * current sidecar.
		 */
		negative_safe = 1;
		cache->negative_noop++;
		goto done;
	}
	if (same_index && !bootstrap_recovery) {
		current.repo = cache->repo;
		current.istate = cache->istate;
		current.entry_identity = cache->entry_identity;
		current.bitmap_size = cache->bitmap_size;
		current.split_index = cache->split_index;
		current.split_base_nr = cache->split_base_nr;
		current.split_base_bitmap_size =
			cache->split_base_bitmap_size;
		oidcpy(&current.state_oid, &cache->state_oid);
		oidcpy(&current.worktree_scope, &cache->worktree_scope);
		oidcpy(&current.split_base_identity,
		       &cache->split_base_identity);
		CALLOC_ARRAY(equal, current.bitmap_size);
		CALLOC_ARRAY(different, current.bitmap_size);
		CALLOC_ARRAY(split_base_equal,
			     current.split_base_bitmap_size);
		current.equal = equal;
		current.different = different;
		current.split_base_equal = split_base_equal;
		loaded = load_cache(&current, equal, different,
				    split_base_equal);
		exact_matches = loaded & GREP_WORKTREE_CACHE_EXACT;
		split_base_matches =
			cache->split_base_changed &&
			loaded & GREP_WORKTREE_CACHE_SPLIT_BASE;
		source_matches =
			cache->compact_loaded == current.compact_loaded &&
			(!cache->compact_loaded ||
			 oideq(&cache->compact_checksum,
			       &current.compact_checksum));
		if (!exact_matches) {
			if (current.recovery_map)
				munmap((void *)current.recovery_map,
				       current.recovery_map_size);
			current.recovery_map = NULL;
			free(different);
			free(equal);
			free(split_base_equal);
			different = NULL;
			equal = NULL;
			split_base_equal = NULL;
			memset(&current, 0, sizeof(current));
			oidcpy(&current.observation_generation,
			       &cache->observation_generation);
			goto read_current_index;
		}
		for (size_t i = 0; i < cache->istate->cache_nr; i++) {
			struct object_id entry_oid;
			unsigned char mask = 1u << (i & 7);
			const struct cache_entry *ce =
				cache->istate->cache[i];

			if (!(cache->negative_observed[i >> 3] & mask))
				continue;
			if (!(different[i >> 3] & mask)) {
				cache->updated[i >> 3] |= mask;
				cache->exact_changed = 1;
			}
			if (!(cache->updated[i >> 3] &
			      cache->different[i >> 3] & mask))
				continue;
			if (grep_worktree_entry_identity_hash(
				    &cache->entry_identity,
				    ce, &entry_oid))
				goto done;
			oid_array_append(&cache->negative_entries, &entry_oid);
			if (current.split_base_nr && ce->index &&
			    ce->index <= current.split_base_nr) {
				struct object_id base_oid;
				size_t base_pos = ce->index - 1;

				if (grep_worktree_entry_identity_hash(
					    &cache->entry_identity,
					    cache->istate->split_index->base
						    ->cache[base_pos],
					    &base_oid))
					goto done;
				if (oideq(&entry_oid, &base_oid) &&
				    split_base_equal[base_pos >> 3] &
					    (1u << (base_pos & 7))) {
					split_base_equal[base_pos >> 3] &=
						~(1u << (base_pos & 7));
					output_changed = 1;
				}
			}
		}
		oid_array_sort(&cache->negative_entries);
		CALLOC_ARRAY(negative_resolved,
			     cache->negative_entries.nr);
		direct_current = 1;
		goto merge_current;
	}

read_current_index:
	for (size_t i = 0; i < cache->istate->cache_nr; i++) {
		struct object_id entry_oid;

		if (!(cache->negative_observed[i >> 3] &
		      (1u << (i & 7))))
			continue;
		if (grep_worktree_entry_identity_hash(
			    &cache->entry_identity,
			    cache->istate->cache[i], &entry_oid))
			goto done;
		oid_array_append(&cache->negative_entries, &entry_oid);
	}
	oid_array_sort(&cache->negative_entries);
	wait_for_test_write_phase("locked");
	istate.lazy_cache_tree = 1;
	index_result = read_index_from(
		&istate, repo_get_index_file(cache->repo),
		repo_get_git_dir(cache->repo));
	if (index_result < 0)
		goto done;
	index_result =
		grep_index_identity_get(cache->repo, &istate, &identity);
	if (index_result)
		goto done;

	current.repo = cache->repo;
	current.istate = &istate;
	current.bitmap_size = bitmap_size(istate.cache_nr);
	oidcpy(&current.state_oid, &identity.worktree);
	oidcpy(&current.worktree_scope, &identity.worktree_scope);
	grep_worktree_entry_identity_init(cache->repo,
					  &current.entry_identity);
	oidcpy(&current.split_base_identity,
	       &identity.worktree_split_base_identity);
	if (istate.split_index && istate.split_index->base) {
		current.split_index = 1;
		current.split_base_nr = istate.split_index->base->cache_nr;
		current.split_base_bitmap_size =
			bitmap_size(current.split_base_nr);
	}
	exact_matches = current.bitmap_size == cache->bitmap_size &&
			oideq(&current.state_oid, &cache->state_oid);
	split_base_matches =
		cache->split_base_changed &&
		current.split_base_nr == cache->split_base_nr &&
		current.split_base_nr &&
		oideq(&current.split_base_identity,
		      &cache->split_base_identity);
	CALLOC_ARRAY(equal, current.bitmap_size);
	CALLOC_ARRAY(different, current.bitmap_size);
	CALLOC_ARRAY(negative_resolved, cache->negative_entries.nr);
	CALLOC_ARRAY(split_base_equal, current.split_base_bitmap_size);
	current.equal = equal;
	current.different = different;
	current.split_base_equal = split_base_equal;
	load_cache(&current, equal, different, split_base_equal);
	source_matches =
		cache->compact_loaded == current.compact_loaded &&
		(!cache->compact_loaded ||
		 oideq(&cache->compact_checksum,
		       &current.compact_checksum));

merge_current:
	if (cache->exact_changed && exact_matches) {
		for (size_t i = 0; i < current.bitmap_size; i++) {
			unsigned char negative =
				cache->updated[i] & cache->different[i];
			unsigned char positive =
				cache->updated[i] & cache->equal[i];
			unsigned char merged_different =
				different[i] | negative;
			unsigned char merged_equal =
				equal[i] & ~negative;

			if (source_matches || direct_current)
				merged_equal |=
					positive & ~merged_different;
			if (merged_equal != equal[i] ||
			    merged_different != different[i])
				output_changed = 1;
			equal[i] = merged_equal;
			different[i] = merged_different;
		}
	}
	if (exact_matches)
		memset(negative_resolved, 1,
		       cache->negative_entries.nr);
	if (split_base_matches) {
		for (size_t i = 0;
		     i < current.split_base_bitmap_size; i++) {
			unsigned char negative =
				cache->split_base_updated[i] &
				~cache->split_base_equal[i];
			unsigned char positive =
				cache->split_base_updated[i] &
				cache->split_base_equal[i];
			unsigned char merged =
				split_base_equal[i] & ~negative;

			if (source_matches)
				merged |= positive;
			if (merged != split_base_equal[i])
				output_changed = 1;
			split_base_equal[i] = merged;
		}
	}
	if (cache->negative_entries.nr && !exact_matches) {
		for (size_t i = 0; i < current.istate->cache_nr; i++) {
			struct object_id entry_oid;
			unsigned char mask = 1u << (i & 7);

			ssize_t negative_pos;

			if (grep_worktree_entry_identity_hash(
				    &current.entry_identity,
				    current.istate->cache[i], &entry_oid))
				continue;
			negative_pos = oid_array_lookup(
				&cache->negative_entries, &entry_oid);
			if (negative_pos < 0)
				continue;
			negative_resolved[negative_pos] = 1;
			if (equal[i >> 3] & mask ||
			    !(different[i >> 3] & mask))
				output_changed = 1;
			equal[i >> 3] &= ~mask;
			different[i >> 3] |= mask;
		}
	}
	if (cache->negative_entries.nr && current.split_base_nr &&
	    !direct_current) {
		struct index_state *base =
			current.istate->split_index->base;

		for (size_t i = 0; i < base->cache_nr; i++) {
			struct object_id entry_oid;
			unsigned char mask = 1u << (i & 7);

			ssize_t negative_pos;

			if (grep_worktree_entry_identity_hash(
				    &current.entry_identity,
				    base->cache[i], &entry_oid))
				continue;
			negative_pos = oid_array_lookup(
				&cache->negative_entries, &entry_oid);
			if (negative_pos < 0)
				continue;
			negative_resolved[negative_pos] = 1;
			if (!(split_base_equal[i >> 3] & mask))
				continue;
			split_base_equal[i >> 3] &= ~mask;
			output_changed = 1;
		}
	}
	if (cache->negative_entries.nr && !current.split_index &&
	    !is_null_oid(&current.recovery_checksum)) {
		for (size_t i = 0; i < cache->negative_entries.nr; i++) {
			if (recovery_contains_oid(
				    &current,
				    &cache->negative_entries.oid[i])) {
				negative_resolved[i] = 1;
				recovery_conflicts = 1;
			}
		}
	}
	if (current.split_index &&
	    !is_null_oid(&current.recovery_checksum)) {
		oidclr(&current.recovery_checksum,
		       cache->repo->hash_algo);
		output_changed = 1;
	} else if (cache->recovery_invalid &&
		   oideq(&current.recovery_checksum,
			 &cache->recovery_checksum)) {
		oidclr(&current.recovery_checksum,
		       cache->repo->hash_algo);
		cache->recovery_revoked = 1;
		output_changed = 1;
	} else if (current.recovery_invalid || recovery_conflicts) {
		oidclr(&current.recovery_checksum,
		       cache->repo->hash_algo);
		cache->recovery_revoked = 1;
		output_changed = 1;
	}
	negative_safe = 1;
	for (size_t i = 0; i < cache->negative_entries.nr; i++) {
		if (!negative_resolved[i]) {
			negative_safe = 0;
			break;
		}
	}
	if (persist_recovered && exact_matches &&
	    !cache->recovery_invalid &&
	    oideq(&current.recovery_checksum,
		  &cache->recovery_checksum)) {
		for (size_t i = 0; i < current.bitmap_size; i++) {
			unsigned char merged =
				equal[i] |
				(cache->recovered[i] & ~different[i]);

			if (merged != equal[i])
				output_changed = 1;
			equal[i] = merged;
		}
	}
	if (!current.split_index && exact_matches && bootstrap_recovery &&
	    is_null_oid(&current.recovery_checksum)) {
		int recovery_still_valid = 1;

		/*
		 * Preparation happens without the compact-sidecar lock. Do not
		 * let it restore an equality observation cleared by a concurrent
		 * writer before we acquired that lock.
		 */
		for (size_t i = 0; i < current.bitmap_size; i++) {
			if (prepared_recovery_equal[i] &
			    (~equal[i] | different[i])) {
				recovery_still_valid = 0;
				break;
			}
		}
		if (recovery_still_valid &&
		    !commit_lock_file(&recovery_lock)) {
			oidcpy(&current.recovery_checksum,
			       &prepared_recovery_checksum);
			output_changed = 1;
		}
	}
	if (!output_changed)
		goto done;
	if (direct_current)
		cache->direct_write++;

	f = hashfd(cache->repo->hash_algo, fd, get_lock_file_path(&lock));
	hashwrite_be32(f, GREP_WORKTREE_CACHE_SIGNATURE);
	hashwrite_be32(f, GREP_WORKTREE_CACHE_VERSION);
	hashwrite_be32(f, cache->repo->hash_algo->format_id);
	hashwrite_be32(f, output->istate->cache_nr);
	hashwrite_be32(f, output->split_base_nr);
	hashwrite(f, output->state_oid.hash,
		  cache->repo->hash_algo->rawsz);
	hashwrite(f, output->split_base_identity.hash,
		  cache->repo->hash_algo->rawsz);
	hashwrite(f, output->recovery_checksum.hash,
		  cache->repo->hash_algo->rawsz);
	hashwrite(f, output->observation_generation.hash,
		  cache->repo->hash_algo->rawsz);
	hashwrite(f, output->equal, output->bitmap_size);
	hashwrite(f, output->different, output->bitmap_size);
	hashwrite(f, output->split_base_equal,
		  output->split_base_bitmap_size);
	finalize_hashfile(f, NULL, FSYNC_COMPONENT_NONE, CSUM_HASH_IN_STREAM);
	f = NULL;
	if (commit_lock_file(&lock)) {
		if (cache->recorded_different)
			negative_safe = 0;
		goto done;
	}

done:
	if (!negative_safe &&
	    invalidate_observation_generation(cache) &&
	    write_invalidation_marker(cache))
		die_errno(_("unable to invalidate grep worktree cache"));
	if (f)
		discard_hashfile(f);
	rollback_lock_file(&lock);
	rollback_lock_file(&recovery_lock);
	if (current.recovery_map)
		munmap((void *)current.recovery_map,
		       current.recovery_map_size);
	free(different);
	free(equal);
	free(negative_resolved);
	free(prepared_recovery_equal);
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
			   "worktree_blob/recovered_identity",
			   cache->recovered_identity);
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/recovered_split_base",
			   cache->recovered_split_base);
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/direct_write",
			   cache->direct_write);
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/negative_noop",
			   cache->negative_noop);
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/recovery_invalid",
			   cache->recovery_invalid);
	trace2_data_intmax("grep", cache->repo,
			   "worktree_blob/recovery_revoked",
			   cache->recovery_revoked);
	free(cache->equal);
	free(cache->different);
	free(cache->negative_observed);
	free(cache->updated);
	free(cache->recovered);
	oid_array_clear(&cache->negative_entries);
	free(cache->split_base_equal);
	free(cache->split_base_updated);
	if (cache->recovery_map)
		munmap((void *)cache->recovery_map,
		       cache->recovery_map_size);
	free(cache);
}

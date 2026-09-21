#define USE_THE_REPOSITORY_VARIABLE
#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "gettext.h"
#include "hex.h"
#include "lockfile.h"
#include "tree.h"
#include "tree-walk.h"
#include "cache-tree.h"
#include "object-file.h"
#include "odb.h"
#include "odb/transaction.h"
#include "parse.h"
#include "read-cache-ll.h"
#include "replace-object.h"
#include "repository.h"
#include "promisor-remote.h"
#include "trace.h"
#include "trace2.h"

#ifndef DEBUG_CACHE_TREE
#define DEBUG_CACHE_TREE 0
#endif

struct cache_tree_record {
	const char *name;
	const unsigned char *oid;
	int namelen;
	int entry_count;
	int subtree_nr;
};

struct cache_tree_flat_entry {
	/* Names and OIDs borrow storage from index_state.cache_tree_data. */
	struct cache_tree_record record;
	size_t children;
};

struct cache_tree_flat {
	struct cache_tree_flat_entry *entries;
	size_t nr, alloc;
};

static void cache_tree_flat_free(struct index_state *istate)
{
	if (istate->cache_tree_flat) {
		free(istate->cache_tree_flat->entries);
		FREE_AND_NULL(istate->cache_tree_flat);
	}
}

struct cache_tree *cache_tree(void)
{
	struct cache_tree *it = xcalloc(1, sizeof(struct cache_tree));
	it->entry_count = -1;
	return it;
}

void cache_tree_free(struct cache_tree **it_p)
{
	int i;
	struct cache_tree *it = *it_p;

	if (!it)
		return;
	for (i = 0; i < it->subtree_nr; i++)
		if (it->down[i]) {
			cache_tree_free(&it->down[i]->cache_tree);
			free(it->down[i]);
		}
	free(it->down);
	free(it);
	*it_p = NULL;
}

struct cache_tree *cache_tree_get(struct index_state *istate)
{
	if (!istate->cache_tree && istate->cache_tree_data) {
		cache_tree_flat_free(istate);
		istate->cache_tree = cache_tree_read(
			istate->cache_tree_data,
			istate->cache_tree_data_size);
		FREE_AND_NULL(istate->cache_tree_data);
		istate->cache_tree_data_size = 0;
	}
	return istate->cache_tree;
}

void cache_tree_discard(struct index_state *istate)
{
	cache_tree_flat_free(istate);
	cache_tree_free(&istate->cache_tree);
	FREE_AND_NULL(istate->cache_tree_data);
	istate->cache_tree_data_size = 0;
}

static int subtree_name_cmp(const char *one, int onelen,
			    const char *two, int twolen)
{
	if (onelen < twolen)
		return -1;
	if (twolen < onelen)
		return 1;
	return memcmp(one, two, onelen);
}

int cache_tree_subtree_pos(struct cache_tree *it, const char *path, int pathlen)
{
	struct cache_tree_sub **down = it->down;
	int lo, hi;
	lo = 0;
	hi = it->subtree_nr;
	while (lo < hi) {
		int mi = lo + (hi - lo) / 2;
		struct cache_tree_sub *mdl = down[mi];
		int cmp = subtree_name_cmp(path, pathlen,
					   mdl->name, mdl->namelen);
		if (!cmp)
			return mi;
		if (cmp < 0)
			hi = mi;
		else
			lo = mi + 1;
	}
	return -lo-1;
}

static struct cache_tree_sub *find_subtree(struct cache_tree *it,
					   const char *path,
					   int pathlen,
					   int create)
{
	struct cache_tree_sub *down;
	int pos = cache_tree_subtree_pos(it, path, pathlen);
	if (0 <= pos)
		return it->down[pos];
	if (!create)
		return NULL;

	pos = -pos-1;
	ALLOC_GROW(it->down, it->subtree_nr + 1, it->subtree_alloc);
	it->subtree_nr++;

	FLEX_ALLOC_MEM(down, name, path, pathlen);
	down->cache_tree = NULL;
	down->namelen = pathlen;

	if (pos < it->subtree_nr)
		MOVE_ARRAY(it->down + pos + 1, it->down + pos,
			   it->subtree_nr - pos - 1);
	it->down[pos] = down;
	return down;
}

struct cache_tree_sub *cache_tree_sub(struct cache_tree *it, const char *path)
{
	int pathlen = strlen(path);
	return find_subtree(it, path, pathlen, 1);
}

static int do_invalidate_path(struct cache_tree *it, const char *path)
{
	/* a/b/c
	 * ==> invalidate self
	 * ==> find "a", have it invalidate "b/c"
	 * a
	 * ==> invalidate self
	 * ==> if "a" exists as a subtree, remove it.
	 */
	const char *slash;
	int namelen;
	struct cache_tree_sub *down;

#if DEBUG_CACHE_TREE
	fprintf(stderr, "cache-tree invalidate <%s>\n", path);
#endif

	if (!it)
		return 0;
	slash = strchrnul(path, '/');
	namelen = slash - path;
	it->entry_count = -1;
	if (!*slash) {
		int pos;
		pos = cache_tree_subtree_pos(it, path, namelen);
		if (0 <= pos) {
			cache_tree_free(&it->down[pos]->cache_tree);
			free(it->down[pos]);
			/* 0 1 2 3 4 5
			 *       ^     ^subtree_nr = 6
			 *       pos
			 * move 4 and 5 up one place (2 entries)
			 * 2 = 6 - 3 - 1 = subtree_nr - pos - 1
			 */
			MOVE_ARRAY(it->down + pos, it->down + pos + 1,
				   it->subtree_nr - pos - 1);
			it->subtree_nr--;
		}
		return 1;
	}
	down = find_subtree(it, path, namelen, 0);
	if (down)
		do_invalidate_path(down->cache_tree, slash + 1);
	return 1;
}

void cache_tree_invalidate_path(struct index_state *istate, const char *path)
{
	if (do_invalidate_path(cache_tree_get(istate), path))
		istate->cache_changed |= CACHE_TREE_CHANGED;
}

/*
 * Check whether this_ce and the next entry in the index form a D/F
 * conflict ("path" vs "path/file").  Returns the conflicting "path/..."
 * name when one is found, or NULL otherwise.
 *
 * The cache is sorted, so "path/file" sorts after "path" and the
 * conflict is usually visible as adjacent entries.  But other entries
 * can sort between them -- e.g. "path-internal" sits between "path"
 * and "path/file" because '-' (0x2D) precedes '/' (0x2F) -- so when
 * the immediately following entry shares our prefix but starts with a
 * character that sorts before '/', binary search for "path/" instead.
 */
static const char *find_df_conflict(struct index_state *istate,
				    const struct cache_entry *this_ce,
				    const struct cache_entry *next_ce)
{
	const char *this_name = this_ce->name;
	const char *next_name = next_ce->name;
	int this_len = ce_namelen(this_ce);
	const struct cache_entry *other;
	struct strbuf probe = STRBUF_INIT;
	int pos;

	if (this_len >= ce_namelen(next_ce) ||
	    next_name[this_len] > '/' ||
	    strncmp(this_name, next_name, this_len))
		return NULL;

	if (next_name[this_len] == '/')
		return next_name;

	strbuf_add(&probe, this_name, this_len);
	strbuf_addch(&probe, '/');
	pos = index_name_pos_sparse(istate, probe.buf, probe.len);
	strbuf_release(&probe);

	if (pos < 0)
		pos = -pos - 1;
	if (pos >= (int)istate->cache_nr)
		return NULL;
	other = istate->cache[pos];
	if (ce_namelen(other) > this_len &&
	    other->name[this_len] == '/' &&
	    !strncmp(this_name, other->name, this_len))
		return other->name;
	return NULL;
}

static int verify_cache(struct index_state *istate, int flags)
{
	unsigned i, funny;
	int silent = flags & WRITE_TREE_SILENT;

	/* Verify that the tree is merged */
	funny = 0;
	for (i = 0; i < istate->cache_nr; i++) {
		const struct cache_entry *ce = istate->cache[i];
		if (ce_stage(ce)) {
			if (silent)
				return -1;
			if (10 < ++funny) {
				fprintf(stderr, "...\n");
				break;
			}
			fprintf(stderr, "%s: unmerged (%s)\n",
				ce->name, oid_to_hex(&ce->oid));
		}
	}
	if (funny)
		return -1;

	/* Also verify that the cache does not have path and path/file
	 * at the same time.  At this point we know the cache has only
	 * stage 0 entries.
	 */
	funny = 0;
	for (i = 0; i + 1 < istate->cache_nr; i++) {
		const struct cache_entry *this_ce = istate->cache[i];
		const struct cache_entry *next_ce = istate->cache[i + 1];
		const char *conflict_name;

		conflict_name = find_df_conflict(istate, this_ce, next_ce);
		if (conflict_name) {
			if (10 < ++funny) {
				fprintf(stderr, "...\n");
				break;
			}
			fprintf(stderr, "You have both %s and %s\n",
				this_ce->name, conflict_name);
		}
	}
	if (funny)
		return -1;
	return 0;
}

static void discard_unused_subtrees(struct cache_tree *it)
{
	struct cache_tree_sub **down = it->down;
	int nr = it->subtree_nr;
	int dst, src;
	for (dst = src = 0; src < nr; src++) {
		struct cache_tree_sub *s = down[src];
		if (s->used)
			down[dst++] = s;
		else {
			cache_tree_free(&s->cache_tree);
			free(s);
			it->subtree_nr--;
		}
	}
}

struct cache_tree_validation_stats {
	uintmax_t nodes;
	uintmax_t object_checks;
	uint64_t object_check_ns;
	int time_object_checks;
};

static int cache_tree_fully_valid_internal(struct cache_tree *it,
					 struct cache_tree_validation_stats *stats)
{
	int i, exists;
	if (!it)
		return 0;
	if (stats)
		stats->nodes++;
	if (it->entry_count < 0)
		return 0;
	if (stats)
		stats->object_checks++;
	if (stats && stats->time_object_checks) {
		int saved_errno = errno;

		trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_OBJECT_CHECK);
		errno = saved_errno;
	}
	exists = odb_has_object(the_repository->objects, &it->oid,
				ODB_HAS_OBJECT_RECHECK_PACKED |
					ODB_HAS_OBJECT_FETCH_PROMISOR);
	if (stats && stats->time_object_checks) {
		int saved_errno = errno;

		stats->object_check_ns +=
			trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_OBJECT_CHECK);
		errno = saved_errno;
	}
	if (!exists)
		return 0;
	for (i = 0; i < it->subtree_nr; i++) {
		if (!cache_tree_fully_valid_internal(it->down[i]->cache_tree, stats))
			return 0;
	}
	return 1;
}

#define CACHE_TREE_OID_ORDER_MIN_ENTRIES 1000000
#define CACHE_TREE_OID_ORDER_MAX_NODES 1000000
#define CACHE_TREE_OID_ORDER_PROBE_PREFIX   1024
#define CACHE_TREE_OID_ORDER_PROBE_INTERVAL 64

struct cache_tree_oid_order {
	struct cache_tree **nodes;
	size_t nr, alloc;
};

static int collect_valid_cache_tree_nodes(struct cache_tree *it,
					  struct cache_tree_oid_order *order)
{
	int i;
	size_t next_alloc;

	if (!it || it->entry_count < 0)
		return 0;
	if (order->nr == CACHE_TREE_OID_ORDER_MAX_NODES)
		return 0;
	if (order->nr == order->alloc) {
		next_alloc = order->alloc ? order->alloc * 2 : 256;
		if (next_alloc > CACHE_TREE_OID_ORDER_MAX_NODES)
			next_alloc = CACHE_TREE_OID_ORDER_MAX_NODES;
		REALLOC_ARRAY(order->nodes, next_alloc);
		order->alloc = next_alloc;
	}
	order->nodes[order->nr++] = it;
	for (i = 0; i < it->subtree_nr; i++)
		if (!collect_valid_cache_tree_nodes(it->down[i]->cache_tree, order))
			return 0;
	return 1;
}

static int cache_tree_oid_order_cmp(const void *a, const void *b)
{
	const struct cache_tree *const *one = a;
	const struct cache_tree *const *two = b;

	return oidcmp(&(*one)->oid, &(*two)->oid);
}

static int cache_tree_fully_valid_oid_order(struct cache_tree *it,
					    struct cache_tree_validation_stats *stats)
{
	struct cache_tree_oid_order order = { 0 };
	size_t i, checks = 0;
	uint64_t ordered_object_check_ns = 0;
	uint64_t selected_checks = 0;
	int trace_packed = trace2_is_enabled();
	int exists, saved_errno;

	if (!collect_valid_cache_tree_nodes(it, &order)) {
		saved_errno = errno;
		trace2_data_intmax("cache_tree", the_repository,
				   "validate/oid-order/structural-fallback", 1);
		errno = saved_errno;
		goto fallback;
	}
	QSORT(order.nodes, order.nr, cache_tree_oid_order_cmp);
	saved_errno = errno;
	trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PROBE_LOOP);
	errno = saved_errno;
	for (i = 0; i < order.nr; i++) {
		enum odb_has_object_flags check_flags =
			ODB_HAS_OBJECT_RECHECK_PACKED |
			ODB_HAS_OBJECT_FETCH_PROMISOR;

		if (i && oideq(&order.nodes[i - 1]->oid, &order.nodes[i]->oid))
			continue;

		/* Cover short validations, then sample every 64th ordered check. */
		if (trace_packed &&
		    (checks < CACHE_TREE_OID_ORDER_PROBE_PREFIX ||
		     !((checks - CACHE_TREE_OID_ORDER_PROBE_PREFIX) %
		       CACHE_TREE_OID_ORDER_PROBE_INTERVAL))) {
			check_flags |= ODB_HAS_OBJECT_TRACE_CACHE_TREE_VALIDATE_PACKED_LOOKUP;
			selected_checks++;
		}
		checks++;
		if (stats && stats->time_object_checks) {
			saved_errno = errno;
			trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_OBJECT_CHECK);
			errno = saved_errno;
		}
		exists = odb_has_object(the_repository->objects,
					&order.nodes[i]->oid, check_flags);
		if (stats && stats->time_object_checks) {
			saved_errno = errno;
			ordered_object_check_ns +=
				trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_OBJECT_CHECK);
			errno = saved_errno;
		}
		if (!exists)
			break;
	}
	saved_errno = errno;
	trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PROBE_LOOP);
	errno = saved_errno;
	/* The DFS fallback is excluded; selected checks can miss packed storage. */
	if (selected_checks) {
		saved_errno = errno;
		trace2_counter_add(
			TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_LOOKUP_SELECTED_CHECKS,
			selected_checks);
		errno = saved_errno;
	}
	if (i < order.nr) {
		if (stats) {
			stats->object_checks += checks;
			stats->object_check_ns += ordered_object_check_ns;
		}
		saved_errno = errno;
		trace2_data_intmax("cache_tree", the_repository,
				   "validate/oid-order/probes", checks);
		trace2_data_intmax("cache_tree", the_repository,
				   "validate/oid-order/fallback", 1);
		errno = saved_errno;
		goto fallback;
	}
	if (stats) {
		stats->nodes += order.nr;
		stats->object_checks += checks;
		stats->object_check_ns += ordered_object_check_ns;
	}
	saved_errno = errno;
	trace2_data_intmax("cache_tree", the_repository,
			   "validate/oid-order/probes", checks);
	errno = saved_errno;
	free(order.nodes);
	return 1;

fallback:
	free(order.nodes);
	return cache_tree_fully_valid_internal(it, stats);
}

static int cache_tree_fully_valid_maybe_oid_order(struct cache_tree *it,
						  struct cache_tree_validation_stats *stats,
						  int allow_oid_order)
{
	int saved_errno;

	/* Root entry count is a cheap proxy for the cost of sorting nodes. */
	if (!git_env_bool("GIT_TEST_CACHE_TREE_OID_ORDER",
			  allow_oid_order && it &&
				  it->entry_count >= CACHE_TREE_OID_ORDER_MIN_ENTRIES))
		return cache_tree_fully_valid_internal(it, stats);
	if (repo_has_promisor_remote(the_repository)) {
		saved_errno = errno;
		trace2_data_intmax("cache_tree", the_repository,
				   "validate/oid-order/promisor-bypass", 1);
		errno = saved_errno;
		return cache_tree_fully_valid_internal(it, stats);
	}
	return cache_tree_fully_valid_oid_order(it, stats);
}

int cache_tree_fully_valid(struct cache_tree *it)
{
	return cache_tree_fully_valid_maybe_oid_order(it, NULL, 0);
}

int cache_tree_fully_valid_with_order(struct cache_tree *it, int allow_oid_order,
				      uintmax_t *nodes, uintmax_t *object_checks)
{
	struct cache_tree_validation_stats stats = { 0 };
	int valid = cache_tree_fully_valid_maybe_oid_order(it,
							   nodes || object_checks ? &stats : NULL,
							   allow_oid_order);

	if (nodes)
		*nodes = stats.nodes;
	if (object_checks)
		*object_checks = stats.object_checks;
	return valid;
}

int cache_tree_fully_valid_with_counts(struct cache_tree *it,
				       uintmax_t *nodes, uintmax_t *object_checks)
{
	return cache_tree_fully_valid_with_order(it, 0, nodes, object_checks);
}

static void trace_cache_tree_validation(const struct cache_tree_validation_stats *stats,
				       int valid, int skipped)
{
	/*
	 * write_index_as_tree() runs on the command's main thread. Accumulate
	 * completed validations across index states, matching the validate
	 * region's cumulative time. Calls include explicit skips; the rest
	 * are valid or invalid. Object checks count odb_has_object() calls,
	 * not unique OIDs or backend filesystem probes. Object-check time covers
	 * the entire ODB call, including retries and promisor fetches. The rest
	 * of validate includes decoding, iteration, and diagnostic overhead;
	 * neither duration is CPU time.
	 * On ordered fallback, nodes report the canonical DFS traversal.
	 */
	static struct {
		uintmax_t calls, valid, skipped;
		struct cache_tree_validation_stats work;
	} totals;
	int saved_errno = errno;

	totals.calls++;
	totals.valid += valid;
	totals.skipped += skipped;
	totals.work.nodes += stats->nodes;
	totals.work.object_checks += stats->object_checks;
	totals.work.object_check_ns += stats->object_check_ns;
	trace2_data_intmax("cache_tree", NULL, "validate/calls-total", totals.calls);
	trace2_data_intmax("cache_tree", NULL, "validate/valid-total", totals.valid);
	trace2_data_intmax("cache_tree", NULL, "validate/skipped-total", totals.skipped);
	trace2_data_intmax("cache_tree", NULL, "validate/nodes-total", totals.work.nodes);
	trace2_data_intmax("cache_tree", NULL, "validate/object-checks-total",
			   totals.work.object_checks);
	trace2_data_intmax("cache_tree", NULL, "validate/object-check-us-total",
			   totals.work.object_check_ns / 1000);
	errno = saved_errno;
}

static int must_check_existence(const struct cache_entry *ce)
{
	return !(repo_has_promisor_remote(the_repository) && ce_skip_worktree(ce));
}

struct cache_tree_update_stats {
	uint64_t nodes, reused, sparse, hash_only;
	uint64_t entries_visited, entry_object_checks, entry_object_check_ns;
	uint64_t reused_child_parent_checks, reused_child_parent_check_ns;
	uint64_t reuse_object_checks, reuse_object_check_ns;
	uint64_t reuse_object_probed_checks;
	uint64_t repair_tree_checks, repair_tree_check_ns, hash_only_ns;
	uint64_t object_write_calls, object_write_ns;
	uint64_t owned_odb_commit_calls, owned_odb_commit_ns;
};

/* Packed stage totals describe the probed checks, not all reuse checks. */
#define CACHE_TREE_REUSE_PROBE_PREFIX	1024
#define CACHE_TREE_REUSE_PROBE_INTERVAL 64

/*
 * Accumulate returning update regions across index states and threads.
 * Writes count completed ODB API attempts, which may only freshen an
 * existing object. Hash-only nodes use repair or dry-run mode. Commit API calls
 * belong to this update, not an enclosing ODB transaction. Failed returns
 * are included; a nonreturning update has no complete summary. Times are
 * work-time sums, not process wall time.
 */
static void trace_cache_tree_update(const struct cache_tree_update_stats *stats,
				    int failed)
{
	int saved_errno = errno;

	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_CALLS, 1);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_FAILED, failed);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_NODES,
			   stats->nodes);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSED,
			   stats->reused);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_SPARSE,
			   stats->sparse);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_HASH_ONLY,
			   stats->hash_only);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_ENTRIES_VISITED,
			   stats->entries_visited);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_ENTRY_OBJECT_CHECKS,
			   stats->entry_object_checks);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_ENTRY_OBJECT_CHECK_NS,
			   stats->entry_object_check_ns);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSED_CHILD_PARENT_CHECKS,
			   stats->reused_child_parent_checks);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSED_CHILD_PARENT_CHECK_NS,
			   stats->reused_child_parent_check_ns);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_OBJECT_CHECKS,
			   stats->reuse_object_checks);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_OBJECT_CHECK_NS,
			   stats->reuse_object_check_ns);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_OBJECT_PROBED_CHECKS,
			   stats->reuse_object_probed_checks);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REPAIR_TREE_CHECKS,
			   stats->repair_tree_checks);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REPAIR_TREE_CHECK_NS,
			   stats->repair_tree_check_ns);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_HASH_ONLY_NS,
			   stats->hash_only_ns);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OBJECT_WRITE_CALLS,
			   stats->object_write_calls);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OBJECT_WRITE_NS,
			   stats->object_write_ns);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OWNED_ODB_COMMIT_CALLS,
			   stats->owned_odb_commit_calls);
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OWNED_ODB_COMMIT_NS,
			   stats->owned_odb_commit_ns);
	errno = saved_errno;
}

static int update_has_object(const struct object_id *oid,
			     enum odb_has_object_flags flags, uint64_t *elapsed_ns)
{
	uint64_t start, elapsed;
	int exists, saved_errno;

	if (!elapsed_ns)
		return odb_has_object(the_repository->objects, oid, flags);
	saved_errno = errno;
	start = getnanotime();
	errno = saved_errno;
	exists = odb_has_object(the_repository->objects, oid, flags);
	saved_errno = errno;
	elapsed = getnanotime() - start;
	*elapsed_ns += elapsed;
	errno = saved_errno;
	return exists;
}

static void update_hash_tree(const struct strbuf *buffer, struct object_id *oid,
			     uint64_t *elapsed_ns)
{
	uint64_t start, elapsed;
	int saved_errno;

	if (!elapsed_ns) {
		hash_object_file(the_hash_algo, buffer->buf, buffer->len,
				 OBJ_TREE, oid);
		return;
	}
	saved_errno = errno;
	start = getnanotime();
	errno = saved_errno;
	hash_object_file(the_hash_algo, buffer->buf, buffer->len, OBJ_TREE, oid);
	saved_errno = errno;
	elapsed = getnanotime() - start;
	*elapsed_ns += elapsed;
	errno = saved_errno;
}

static int update_one(struct cache_tree *it,
		      struct cache_entry **cache,
		      int entries,
		      const char *base,
		      int baselen,
		      int *skip_count,
		      int flags,
		      struct cache_tree_update_stats *stats,
		      int *reused_object)
{
	struct strbuf buffer;
	int missing_ok = flags & WRITE_TREE_MISSING_OK;
	int dryrun = flags & WRITE_TREE_DRY_RUN;
	int repair = flags & WRITE_TREE_REPAIR;
	int to_invalidate = 0;
	int i;

	assert(!(dryrun && repair));

	if (stats)
		stats->nodes++;
	*skip_count = 0;
	if (reused_object)
		*reused_object = 0;

	/*
	 * If the first entry of this region is a sparse directory
	 * entry corresponding exactly to 'base', then this cache_tree
	 * struct is a "leaf" in the data structure, pointing to the
	 * tree OID specified in the entry.
	 */
	if (entries > 0) {
		const struct cache_entry *ce = cache[0];

		if (S_ISSPARSEDIR(ce->ce_mode) &&
		    ce->ce_namelen == baselen &&
		    !strncmp(ce->name, base, baselen)) {
			if (stats)
				stats->sparse++;
			it->entry_count = 1;
			oidcpy(&it->oid, &ce->oid);
			return 1;
		}
	}

	if (0 <= it->entry_count) {
		enum odb_has_object_flags check_flags =
			ODB_HAS_OBJECT_RECHECK_PACKED |
			ODB_HAS_OBJECT_FETCH_PROMISOR;

		if (stats) {
			uint64_t ordinal = stats->reuse_object_checks++;

			/* Cover small updates, then sample periodically. */
			if (ordinal < CACHE_TREE_REUSE_PROBE_PREFIX ||
			    !((ordinal - CACHE_TREE_REUSE_PROBE_PREFIX) %
			      CACHE_TREE_REUSE_PROBE_INTERVAL)) {
				check_flags |= ODB_HAS_OBJECT_TRACE_PACKED_LOOKUP;
				stats->reuse_object_probed_checks++;
			}
		}
		if (update_has_object(&it->oid,
				      check_flags,
				      stats ? &stats->reuse_object_check_ns : NULL)) {
			if (stats)
				stats->reused++;
			if (reused_object)
				*reused_object = 1;
			return it->entry_count;
		}
	}

	/*
	 * We first scan for subtrees and update them; we start by
	 * marking existing subtrees -- the ones that are unmarked
	 * should not be in the result.
	 */
	for (i = 0; i < it->subtree_nr; i++)
		it->down[i]->used = CACHE_TREE_SUB_UNUSED;

	/*
	 * Find the subtrees and update them.
	 */
	i = 0;
	while (i < entries) {
		const struct cache_entry *ce = cache[i];
		struct cache_tree_sub *sub;
		const char *path, *slash;
		int pathlen, sublen, subcnt, subskip, sub_reused;

		path = ce->name;
		pathlen = ce_namelen(ce);
		if (pathlen <= baselen || memcmp(base, path, baselen))
			break; /* at the end of this level */

		slash = strchr(path + baselen, '/');
		if (!slash) {
			i++;
			continue;
		}
		/*
		 * a/bbb/c (base = a/, slash = /c)
		 * ==>
		 * path+baselen = bbb/c, sublen = 3
		 */
		sublen = slash - (path + baselen);
		sub = find_subtree(it, path + baselen, sublen, 1);
		if (!sub->cache_tree)
			sub->cache_tree = cache_tree();
		subcnt = update_one(sub->cache_tree,
				    cache + i, entries - i,
				    path,
				    baselen + sublen + 1,
				    &subskip,
				    flags, stats, &sub_reused);
		if (subcnt < 0)
			return subcnt;
		if (!subcnt)
			die("index cache-tree records empty sub-tree");
		i += subcnt;
		sub->count = subcnt; /* to be used in the next loop */
		*skip_count += subskip;
		sub->used = sub_reused ? CACHE_TREE_SUB_REUSED_OBJECT_VERIFIED :
					 CACHE_TREE_SUB_USED;
	}

	discard_unused_subtrees(it);

	/*
	 * Then write out the tree object for this level.
	 */
	strbuf_init(&buffer, 8192);

	i = 0;
	while (i < entries) {
		const struct cache_entry *ce = cache[i];
		struct cache_tree_sub *sub = NULL;
		const char *path, *slash;
		int pathlen, entlen;
		const struct object_id *oid;
		unsigned mode;
		int expected_missing = 0;
		int contains_ita = 0;
		int ce_missing_ok, oid_is_null, object_exists = 1;
		uint64_t object_check_ns = 0;

		path = ce->name;
		pathlen = ce_namelen(ce);
		if (pathlen <= baselen || memcmp(base, path, baselen))
			break; /* at the end of this level */

		slash = strchr(path + baselen, '/');
		if (slash) {
			entlen = slash - (path + baselen);
			sub = find_subtree(it, path + baselen, entlen, 0);
			if (!sub)
				die("cache-tree.c: '%.*s' in '%s' not found",
				    entlen, path + baselen, path);
			i += sub->count;
			oid = &sub->cache_tree->oid;
			mode = S_IFDIR;
			contains_ita = sub->cache_tree->entry_count < 0;
			if (contains_ita) {
				to_invalidate = 1;
				expected_missing = 1;
			}
		}
		else {
			oid = &ce->oid;
			mode = ce->ce_mode;
			entlen = pathlen - baselen;
			i++;
		}

		if (stats)
			stats->entries_visited++;
		ce_missing_ok = mode == S_IFGITLINK || missing_ok ||
			!must_check_existence(ce);
		oid_is_null = is_null_oid(oid);
		if (!oid_is_null && !ce_missing_ok) {
			if (stats)
				stats->entry_object_checks++;
			object_exists = update_has_object(oid,
							  ODB_HAS_OBJECT_RECHECK_PACKED |
								  ODB_HAS_OBJECT_FETCH_PROMISOR,
							  stats ? &object_check_ns : NULL);
			if (stats) {
				stats->entry_object_check_ns += object_check_ns;
				if (sub && sub->used ==
						   CACHE_TREE_SUB_REUSED_OBJECT_VERIFIED) {
					stats->reused_child_parent_checks++;
					stats->reused_child_parent_check_ns +=
						object_check_ns;
				}
			}
		}
		if (oid_is_null || !object_exists) {
			strbuf_release(&buffer);
			if (expected_missing)
				return -1;
			return error("invalid object %06o %s for '%.*s'",
				mode, oid_to_hex(oid), entlen+baselen, path);
		}

		/*
		 * CE_REMOVE entries are removed before the index is
		 * written to disk. Skip them to remain consistent
		 * with the future on-disk index.
		 */
		if (ce->ce_flags & CE_REMOVE) {
			*skip_count = *skip_count + 1;
			continue;
		}

		/*
		 * CE_INTENT_TO_ADD entries exist in on-disk index but
		 * they are not part of generated trees. Invalidate up
		 * to root to force cache-tree users to read elsewhere.
		 */
		if (!sub && ce_intent_to_add(ce)) {
			to_invalidate = 1;
			continue;
		}

		/*
		 * "sub" can be an empty tree if all subentries are i-t-a.
		 */
		if (contains_ita && is_empty_tree_oid(oid, the_repository->hash_algo))
			continue;

		strbuf_grow(&buffer, entlen + 100);
		strbuf_addf(&buffer, "%o %.*s%c", mode, entlen, path + baselen, '\0');
		strbuf_add(&buffer, oid->hash, the_hash_algo->rawsz);

#if DEBUG_CACHE_TREE
		fprintf(stderr, "cache-tree update-one %o %.*s\n",
			mode, entlen, path + baselen);
#endif
	}

	if (stats && (repair || dryrun))
		stats->hash_only++;
	if (repair) {
		struct object_id oid;

		update_hash_tree(&buffer, &oid, stats ? &stats->hash_only_ns : NULL);
		if (stats)
			stats->repair_tree_checks++;
		if (update_has_object(&oid, ODB_HAS_OBJECT_RECHECK_PACKED,
				      stats ? &stats->repair_tree_check_ns : NULL))
			oidcpy(&it->oid, &oid);
		else
			to_invalidate = 1;
	} else if (dryrun) {
		update_hash_tree(&buffer, &it->oid,
				 stats ? &stats->hash_only_ns : NULL);
	} else {
		int ret;

		if (stats) {
			int saved_errno = errno;

			trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_UPDATE_OBJECT_WRITE);
			errno = saved_errno;
		}
		ret = odb_write_object_ext(the_repository->objects, buffer.buf, buffer.len,
					   OBJ_TREE, &it->oid, NULL,
					   flags & WRITE_TREE_SILENT ? ODB_WRITE_OBJECT_SILENT : 0);
		if (stats) {
			int saved_errno = errno;

			stats->object_write_ns +=
				trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_UPDATE_OBJECT_WRITE);
			stats->object_write_calls++;
			errno = saved_errno;
		}
		if (ret) {
			strbuf_release(&buffer);
			return -1;
		}
	}

	strbuf_release(&buffer);
	it->entry_count = to_invalidate ? -1 : i - *skip_count;
#if DEBUG_CACHE_TREE
	fprintf(stderr, "cache-tree update-one (%d ent, %d subtree) %s\n",
		it->entry_count, it->subtree_nr,
		oid_to_hex(&it->oid));
#endif
	return i;
}

int cache_tree_update(struct index_state *istate, int flags)
{
	int inflight = !!the_repository->objects->transaction;
	struct cache_tree *root;
	struct odb_transaction *transaction;
	struct cache_tree_update_stats stats = { 0 };
	struct cache_tree_update_stats *trace = NULL;
	int skip, i;

	i = verify_cache(istate, flags);

	if (i)
		return i;

	root = cache_tree_get(istate);
	if (!root) {
		root = cache_tree();
		istate->cache_tree = root;
	}

	if (!(flags & WRITE_TREE_MISSING_OK) && repo_has_promisor_remote(the_repository))
		prefetch_cache_entries(istate, must_check_existence);

	if (trace2_is_enabled())
		trace = &stats;
	trace_performance_enter();
	trace2_region_enter("cache_tree", "update", istate->repo);
	if (!inflight)
		odb_transaction_begin_or_die(the_repository->objects, &transaction, 0);
	i = update_one(root, istate->cache, istate->cache_nr,
		       "", 0, &skip, flags, trace, NULL);
	if (!inflight) {
		if (trace) {
			int saved_errno = errno;

			trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_UPDATE_OWNED_ODB_COMMIT);
			errno = saved_errno;
		}
		odb_transaction_commit_and_finalize_or_die(transaction);
		if (trace) {
			int saved_errno = errno;

			stats.owned_odb_commit_ns +=
				trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_UPDATE_OWNED_ODB_COMMIT);
			stats.owned_odb_commit_calls++;
			errno = saved_errno;
		}
	}
	trace2_region_leave("cache_tree", "update", istate->repo);
	trace_performance_leave("cache_tree_update");
	if (trace)
		trace_cache_tree_update(trace, i < 0);
	if (i < 0)
		return i;
	istate->cache_changed |= CACHE_TREE_CHANGED;
	return 0;
}

static void write_one(struct strbuf *buffer, struct cache_tree *it,
		      const char *path, int pathlen)
{
	int i;

	/* One "cache-tree" entry consists of the following:
	 * path (NUL terminated)
	 * entry_count, subtree_nr ("%d %d\n")
	 * tree-sha1 (missing if invalid)
	 * subtree_nr "cache-tree" entries for subtrees.
	 */
	strbuf_grow(buffer, pathlen + 100);
	strbuf_add(buffer, path, pathlen);
	strbuf_addf(buffer, "%c%d %d\n", 0, it->entry_count, it->subtree_nr);

#if DEBUG_CACHE_TREE
	if (0 <= it->entry_count)
		fprintf(stderr, "cache-tree <%.*s> (%d ent, %d subtree) %s\n",
			pathlen, path, it->entry_count, it->subtree_nr,
			oid_to_hex(&it->oid));
	else
		fprintf(stderr, "cache-tree <%.*s> (%d subtree) invalid\n",
			pathlen, path, it->subtree_nr);
#endif

	if (0 <= it->entry_count) {
		strbuf_add(buffer, it->oid.hash, the_hash_algo->rawsz);
	}
	for (i = 0; i < it->subtree_nr; i++) {
		struct cache_tree_sub *down = it->down[i];
		if (i) {
			struct cache_tree_sub *prev = it->down[i-1];
			if (subtree_name_cmp(down->name, down->namelen,
					     prev->name, prev->namelen) <= 0)
				die("fatal - unsorted cache subtree");
		}
		write_one(buffer, down->cache_tree, down->name, down->namelen);
	}
}

void cache_tree_write(struct strbuf *sb, struct cache_tree *root)
{
	trace2_region_enter("cache_tree", "write", the_repository);
	write_one(sb, root, "", 0);
	trace2_region_leave("cache_tree", "write", the_repository);
}

static int parse_int(const char **ptr, unsigned long *len_p, int *out)
{
	const char *s = *ptr;
	unsigned long len = *len_p;
	uint64_t ret = 0;
	int sign = 1;
	int digits = 0;

	while (len && *s == '-') {
		sign *= -1;
		s++;
		len--;
	}

	while (len) {
		unsigned digit;
		uint64_t limit;

		if (!isdigit(*s))
			break;
		digit = *s - '0';
		limit = sign < 0 ? (uint64_t)INT_MAX + 1 : INT_MAX;
		if (ret > (limit - digit) / 10)
			return -1;
		ret = ret * 10 + digit;
		digits = 1;
		s++;
		len--;
	}

	if (!digits)
		return -1;

	*ptr = s;
	*len_p = len;
	if (ret == (uint64_t)INT_MAX + 1)
		*out = INT_MIN;
	else
		*out = sign < 0 ? -(int)ret : (int)ret;
	return 0;
}

static int read_record(const char **buffer, unsigned long *size_p,
		       struct cache_tree_record *record)
{
	const char *buf = *buffer;
	unsigned long size = *size_p;
	const unsigned rawsz = the_hash_algo->rawsz;

	record->name = buf;
	/* skip name, but make sure name exists */
	while (size && *buf) {
		size--;
		buf++;
	}
	if (!size)
		return -1;
	record->namelen = buf - record->name;
	buf++; size--;

	if (parse_int(&buf, &size, &record->entry_count) < 0)
		return -1;
	if (!size || *buf != ' ')
		return -1;
	buf++; size--;
	if (parse_int(&buf, &size, &record->subtree_nr) < 0)
		return -1;
	if (!size || *buf != '\n')
		return -1;
	buf++; size--;
	if (0 <= record->entry_count) {
		if (size < rawsz)
			return -1;
		record->oid = (const unsigned char *)buf;
		buf += rawsz;
		size -= rawsz;
	} else
		record->oid = NULL;
	*buffer = buf;
	*size_p = size;
	return 0;
}

int cache_tree_root_matches_index(struct index_state *istate,
				  const struct object_id *oid)
{
	if (istate->cache_tree_data) {
		const char *data = istate->cache_tree_data;
		unsigned long size;
		struct cache_tree_record record;
		struct object_id root_oid;

		if (istate->cache_tree_data_size > ULONG_MAX)
			return 0;
		size = istate->cache_tree_data_size;
		if (read_record(&data, &size, &record) || record.namelen ||
		    record.entry_count != istate->cache_nr || !record.oid ||
		    record.subtree_nr < 0)
			return 0;
		oidread(&root_oid, record.oid, istate->repo->hash_algo);
		return oideq(&root_oid, oid);
	}
	return istate->cache_tree &&
	       istate->cache_tree->entry_count == istate->cache_nr &&
	       oideq(&istate->cache_tree->oid, oid);
}

static struct cache_tree *read_one(const char **buffer, unsigned long *size_p)
{
	const char *buf = *buffer;
	unsigned long size = *size_p;
	struct cache_tree_record record;
	struct cache_tree *it;
	int i, subtree_nr;

	if (read_record(&buf, &size, &record))
		return NULL;
	it = cache_tree();
	it->entry_count = record.entry_count;
	if (record.oid)
		oidread(&it->oid, record.oid, the_repository->hash_algo);
	subtree_nr = record.subtree_nr;

#if DEBUG_CACHE_TREE
	if (0 <= it->entry_count)
		fprintf(stderr, "cache-tree <%s> (%d ent, %d subtree) %s\n",
			*buffer, it->entry_count, subtree_nr,
			oid_to_hex(&it->oid));
	else
		fprintf(stderr, "cache-tree <%s> (%d subtrees) invalid\n",
			*buffer, subtree_nr);
#endif

	/*
	 * Just a heuristic -- we do not add directories that often but
	 * we do not want to have to extend it immediately when we do,
	 * hence +2.  Avoid a separate allocation for the common leaf case.
	 */
	if (subtree_nr) {
		it->subtree_alloc = subtree_nr + 2;
		ALLOC_ARRAY(it->down, it->subtree_alloc);
	}
	for (i = 0; i < subtree_nr; i++) {
		/* read each subtree */
		struct cache_tree *sub;
		struct cache_tree_sub *subtree;
		const char *name = buf;
		int namelen;

		sub = read_one(&buf, &size);
		if (!sub)
			goto free_return;
		namelen = strlen(name);
		if (!it->subtree_nr ||
		    subtree_name_cmp(it->down[it->subtree_nr - 1]->name,
				     it->down[it->subtree_nr - 1]->namelen,
				     name, namelen) < 0) {
			FLEX_ALLOC_MEM(subtree, name, name, namelen);
			subtree->namelen = namelen;
			it->down[it->subtree_nr++] = subtree;
		} else {
			/* Be liberal in what we accept from older writers. */
			subtree = cache_tree_sub(it, name);
		}
		subtree->cache_tree = sub;
	}
	if (subtree_nr != it->subtree_nr)
		die("cache-tree: internal error");
	*buffer = buf;
	*size_p = size;
	return it;

 free_return:
	cache_tree_free(&it);
	return NULL;
}

struct cache_tree *cache_tree_read(const char *buffer, unsigned long size)
{
	struct cache_tree *result;

	if (buffer[0])
		return NULL; /* not the whole tree */

	trace2_region_enter("cache_tree", "read", the_repository);
	trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_READ);
	result = read_one(&buffer, &size);
	trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_READ);
	trace2_region_leave("cache_tree", "read", the_repository);

	return result;
}

/* Keep each node's children contiguous for the usual binary name lookup. */
static int read_flat_one(const char **buffer, unsigned long *size,
			 struct cache_tree_flat *flat, size_t pos)
{
	struct cache_tree_record record;
	const char *previous = NULL;
	size_t children;
	int previous_len = 0, i;

	/* Even an invalid, nameless leaf needs "\0-1 0\n". */
	if (read_record(buffer, size, &record) || record.subtree_nr < 0 ||
	    record.subtree_nr > *size / 6)
		return -1;
	flat->entries[pos].record = record;
	flat->entries[pos].children = children = flat->nr;
	flat->nr = st_add(flat->nr, record.subtree_nr);
	ALLOC_GROW(flat->entries, flat->nr, flat->alloc);
	for (i = 0; i < record.subtree_nr; i++) {
		struct cache_tree_record *child;

		if (read_flat_one(buffer, size, flat, children + i))
			return -1;
		child = &flat->entries[children + i].record;
		/* Leave legacy unordered or duplicate names to the full reader. */
		if (previous && subtree_name_cmp(previous, previous_len,
						 child->name, child->namelen) >= 0)
			return -1;
		previous = child->name;
		previous_len = child->namelen;
	}
	return 0;
}

static int prepare_cache_tree_flat(struct index_state *istate)
{
	const char *buffer = istate->cache_tree_data;
	unsigned long size = istate->cache_tree_data_size;
	struct cache_tree_flat *flat;
	int ret;

	if (istate->cache_tree_flat)
		return 0;
	CALLOC_ARRAY(istate->cache_tree_flat, 1);
	flat = istate->cache_tree_flat;
	flat->nr = 1;
	ALLOC_GROW(flat->entries, flat->nr, flat->alloc);
	trace2_region_enter("cache_tree", "flat-read", istate->repo);
	trace2_timer_start(TRACE2_TIMER_ID_CACHE_TREE_FLAT_READ);
	ret = !size || *buffer || read_flat_one(&buffer, &size, flat, 0);
	trace2_timer_stop(TRACE2_TIMER_ID_CACHE_TREE_FLAT_READ);
	trace2_region_leave("cache_tree", "flat-read", istate->repo);
	if (ret) {
		cache_tree_flat_free(istate);
		return -1;
	}
	trace2_counter_add(TRACE2_COUNTER_ID_CACHE_TREE_FLAT_NODES,
			   istate->cache_tree_flat->nr);
	return 0;
}

static struct cache_tree *cache_tree_find(struct cache_tree *it, const char *path)
{
	if (!it)
		return NULL;
	while (*path) {
		const char *slash;
		struct cache_tree_sub *sub;

		slash = strchrnul(path, '/');
		/*
		 * Between path and slash is the name of the subtree
		 * to look for.
		 */
		sub = find_subtree(it, path, slash - path, 0);
		if (!sub)
			return NULL;
		it = sub->cache_tree;

		path = slash;
		while (*path == '/')
			path++;
	}
	return it;
}

static int write_index_as_tree_internal(struct object_id *oid,
					struct index_state *index_state,
					int cache_tree_valid,
					int flags,
					const char *prefix)
{
	struct cache_tree *root;

	if (flags & WRITE_TREE_IGNORE_CACHE_TREE) {
		cache_tree_discard(index_state);
		cache_tree_valid = 0;
	}

	if (!cache_tree_valid && cache_tree_update(index_state, flags) < 0)
		return WRITE_TREE_UNMERGED_INDEX;

	root = cache_tree_get(index_state);
	if (prefix) {
		struct cache_tree *subtree;
		subtree = cache_tree_find(root, prefix);
		if (!subtree)
			return WRITE_TREE_PREFIX_ERROR;
		oidcpy(oid, &subtree->oid);
	}
	else
		oidcpy(oid, &root->oid);

	return 0;
}

struct tree *write_in_core_index_as_tree(struct repository *repo,
					 struct index_state *index_state) {
	struct object_id o;
	int was_valid, ret;

	was_valid = cache_tree_fully_valid(cache_tree_get(index_state));

	ret = write_index_as_tree_internal(&o, index_state, was_valid, 0, NULL);
	if (ret == WRITE_TREE_UNMERGED_INDEX) {
		int i;
		bug("there are unmerged index entries:");
		for (i = 0; i < index_state->cache_nr; i++) {
			const struct cache_entry *ce = index_state->cache[i];
			if (ce_stage(ce))
				bug("%d %.*s", ce_stage(ce),
				    (int)ce_namelen(ce), ce->name);
		}
		BUG("unmerged index entries when writing in-core index");
	}

	return lookup_tree(repo, &o);
}


int write_index_as_tree(struct object_id *oid, struct index_state *index_state, const char *index_path, int flags, const char *prefix)
{
	int entries, was_valid;
	struct cache_tree_validation_stats validation = {
		.time_object_checks = 1,
	};
	struct lock_file lock_file = LOCK_INIT;
	int ret;
	int validate_only = !!(flags & WRITE_TREE_VALIDATE_ONLY);
	int write_index = !(flags & (WRITE_TREE_NO_INDEX_WRITE | WRITE_TREE_VALIDATE_ONLY));
	int trace_validation = trace2_is_enabled();

	if (validate_only) {
		if (flags & ~(WRITE_TREE_VALIDATE_ONLY | WRITE_TREE_NO_INDEX_WRITE) ||
		    prefix)
			return WRITE_TREE_INVALID_VALIDATION_FLAGS;
		if (repo_has_promisor_remote(index_state->repo))
			return WRITE_TREE_PROMISOR_REPOSITORY;
	}
	flags &= ~(WRITE_TREE_NO_INDEX_WRITE | WRITE_TREE_VALIDATE_ONLY);
	if (write_index)
		hold_lock_file_for_update(&lock_file, index_path, LOCK_DIE_ON_ERROR);

	if (validate_only)
		entries = read_index_from_with_options(index_state, index_path,
						       repo_get_git_dir(the_repository),
						       READ_INDEX_NO_SIDE_EFFECTS);
	else
		entries = read_index_from(index_state, index_path,
					  repo_get_git_dir(the_repository));
	if (entries < 0) {
		ret = WRITE_TREE_UNREADABLE_INDEX;
		goto out;
	}

	trace2_region_enter("cache_tree", "validate", index_state->repo);
	was_valid = !(flags & WRITE_TREE_IGNORE_CACHE_TREE) &&
		    cache_tree_fully_valid_maybe_oid_order(cache_tree_get(index_state),
							   trace_validation ? &validation : NULL,
							   1);
	trace2_region_leave("cache_tree", "validate", index_state->repo);
	if (trace_validation)
		trace_cache_tree_validation(&validation, was_valid,
					    !!(flags & WRITE_TREE_IGNORE_CACHE_TREE));

	if (validate_only) {
		ret = was_valid ? 0 : WRITE_TREE_INVALID_CACHE_TREE;
		if (!ret)
			oidcpy(oid, &cache_tree_get(index_state)->oid);
		goto out;
	}

	ret = write_index_as_tree_internal(oid, index_state, was_valid, flags,
					   prefix);
	if (!ret && !was_valid && write_index) {
		write_locked_index(index_state, &lock_file, COMMIT_LOCK);
		/* Not being able to write is fine -- we are only interested
		 * in updating the cache-tree part, and if the next caller
		 * ends up using the old index with unupdated cache-tree part
		 * it misses the work we did here, but that is just a
		 * performance penalty and not a big deal.
		 */
	}

out:
	rollback_lock_file(&lock_file);
	return ret;
}

static void prime_cache_tree_sparse_dir(struct cache_tree *it,
					struct tree *tree)
{

	oidcpy(&it->oid, &tree->object.oid);
	it->entry_count = 1;
}

static void prime_cache_tree_rec(struct repository *r,
				 struct cache_tree *it,
				 struct tree *tree,
				 struct strbuf *tree_path)
{
	struct tree_desc desc;
	struct name_entry entry;
	int cnt;
	size_t base_path_len = tree_path->len;

	oidcpy(&it->oid, &tree->object.oid);

	init_tree_desc(&desc, &tree->object.oid, tree->buffer, tree->size);
	cnt = 0;
	while (tree_entry(&desc, &entry)) {
		if (!S_ISDIR(entry.mode))
			cnt++;
		else {
			struct cache_tree_sub *sub;
			struct tree *subtree = lookup_tree(r, &entry.oid);

			if (repo_parse_tree(the_repository, subtree) < 0)
				exit(128);
			sub = cache_tree_sub(it, entry.path);
			sub->cache_tree = cache_tree();

			/*
			 * Recursively-constructed subtree path is only needed when working
			 * in a sparse index (where it's used to determine whether the
			 * subtree is a sparse directory in the index).
			 */
			if (r->index->sparse_index) {
				strbuf_setlen(tree_path, base_path_len);
				strbuf_add(tree_path, entry.path, entry.pathlen);
				strbuf_addch(tree_path, '/');
			}

			/*
			 * If a sparse index is in use, the directory being processed may be
			 * sparse. To confirm that, we can check whether an entry with that
			 * exact name exists in the index. If it does, the created subtree
			 * should be sparse. Otherwise, cache tree expansion should continue
			 * as normal.
			 */
			if (r->index->sparse_index &&
			    index_entry_exists(r->index, tree_path->buf, tree_path->len))
				prime_cache_tree_sparse_dir(sub->cache_tree, subtree);
			else
				prime_cache_tree_rec(r, sub->cache_tree, subtree, tree_path);
			cnt += sub->cache_tree->entry_count;
		}
	}

	it->entry_count = cnt;
}

void prime_cache_tree(struct repository *r,
		      struct index_state *istate,
		      struct tree *tree)
{
	struct strbuf tree_path = STRBUF_INIT;
	struct cache_tree *root;

	/*
	 * Repair and validation still use the main repository's object
	 * database. Reuse its full, non-promisor indexes only when repair
	 * proves the cache tree is valid and matches the target tree.
	 */
	if (r == the_repository && istate->repo == r &&
	    !istate->sparse_index && !repo_has_promisor_remote(r) &&
	    cache_tree_get(istate) &&
	    !cache_tree_update(istate, WRITE_TREE_SILENT |
			       WRITE_TREE_REPAIR | WRITE_TREE_MISSING_OK) &&
	    (root = cache_tree_get(istate)) &&
	    cache_tree_fully_valid(root) &&
	    oideq(&root->oid, &tree->object.oid))
		return;

	trace2_region_enter("cache-tree", "prime_cache_tree", r);
	cache_tree_discard(istate);
	istate->cache_tree = cache_tree();

	prime_cache_tree_rec(r, istate->cache_tree, tree, &tree_path);
	strbuf_release(&tree_path);
	istate->cache_changed |= CACHE_TREE_CHANGED;
	trace2_region_leave("cache-tree", "prime_cache_tree", r);
}

/*
 * find the cache_tree that corresponds to the current level without
 * exploding the full path into textual form.  The root of the
 * cache tree is given as "root", and our current level is "info".
 * (1) When at root level, info->prev is NULL, so it is "root" itself.
 * (2) Otherwise, find the cache_tree that corresponds to one level
 *     above us, and find ourselves in there.
 */
static struct cache_tree *find_cache_tree_from_traversal(struct cache_tree *root,
							 struct traverse_info *info)
{
	struct cache_tree *our_parent;

	if (!info->prev)
		return root;
	our_parent = find_cache_tree_from_traversal(root, info->prev);
	return cache_tree_find(our_parent, info->name);
}

static size_t cache_tree_flat_find(struct cache_tree_flat *flat, size_t pos,
				   const char *path)
{
	if (pos == SIZE_MAX)
		return pos;
	while (*path) {
		const char *slash = strchrnul(path, '/');
		struct cache_tree_flat_entry *parent = &flat->entries[pos];
		size_t lo = parent->children;
		size_t hi = lo + parent->record.subtree_nr;
		int namelen = slash - path;

		pos = SIZE_MAX;
		while (lo < hi) {
			size_t mid = lo + (hi - lo) / 2;
			struct cache_tree_record *entry = &flat->entries[mid].record;
			int cmp = subtree_name_cmp(path, namelen,
						   entry->name, entry->namelen);

			if (cmp < 0)
				hi = mid;
			else if (cmp > 0)
				lo = mid + 1;
			else {
				pos = mid;
				break;
			}
		}
		if (pos == SIZE_MAX)
			return pos;
		path = slash;
		while (*path == '/')
			path++;
	}
	return pos;
}

static size_t cache_tree_flat_node_count(struct cache_tree_flat *flat, size_t pos)
{
	struct cache_tree_flat_entry *entry = &flat->entries[pos];
	size_t count = 1;

	for (int i = 0; i < entry->record.subtree_nr; i++)
		count += cache_tree_flat_node_count(flat, entry->children + i);
	return count;
}

static size_t cache_tree_node_count(struct cache_tree *tree)
{
	size_t count = 1;

	for (int i = 0; i < tree->subtree_nr; i++)
		count += cache_tree_node_count(tree->down[i]->cache_tree);
	return count;
}

int cache_tree_get_path(struct index_state *istate, const char *path,
			struct object_id *oid, size_t *tree_count)
{
	struct cache_tree *tree;

	if (istate->cache_tree_data) {
		struct cache_tree_record *record;
		size_t pos;

		if (prepare_cache_tree_flat(istate))
			return -1;
		pos = cache_tree_flat_find(istate->cache_tree_flat, 0, path);
		if (pos == SIZE_MAX)
			return -1;
		record = &istate->cache_tree_flat->entries[pos].record;
		if (record->entry_count < 0)
			return -1;
		oidread(oid, record->oid, istate->repo->hash_algo);
		if (tree_count)
			*tree_count = cache_tree_flat_node_count(istate->cache_tree_flat, pos);
		return record->entry_count;
	}
	tree = cache_tree_find(istate->cache_tree, path);
	if (!tree || tree->entry_count < 0)
		return -1;
	oidcpy(oid, &tree->oid);
	if (tree_count)
		*tree_count = cache_tree_node_count(tree);
	return tree->entry_count;
}

static size_t find_flat_from_traversal(struct cache_tree_flat *flat,
				       struct traverse_info *info)
{
	if (!info->prev)
		return 0;
	return cache_tree_flat_find(flat,
		find_flat_from_traversal(flat, info->prev), info->name);
}

int cache_tree_matches_traversal(struct index_state *istate,
				 struct name_entry *ent,
				 struct traverse_info *info)
{
	struct cache_tree *it;

	if (istate->cache_tree_data && !prepare_cache_tree_flat(istate)) {
		struct cache_tree_flat *flat = istate->cache_tree_flat;
		size_t pos = cache_tree_flat_find(flat,
			find_flat_from_traversal(flat, info), ent->path);

		if (pos != SIZE_MAX) {
			struct cache_tree_record *record = &flat->entries[pos].record;

			if (record->entry_count > 0) {
				struct object_id oid;

				oidread(&oid, record->oid, the_repository->hash_algo);
				if (oideq(&ent->oid, &oid))
					return record->entry_count;
			}
		}
		return 0;
	}
	it = find_cache_tree_from_traversal(cache_tree_get(istate), info);
	it = cache_tree_find(it, ent->path);
	if (it && it->entry_count > 0 && oideq(&ent->oid, &it->oid))
		return it->entry_count;
	return 0;
}

static int verify_one_sparse(struct index_state *istate,
			     struct strbuf *path,
			     int pos)
{
	struct cache_entry *ce = istate->cache[pos];
	if (!S_ISSPARSEDIR(ce->ce_mode))
		return error(_("directory '%s' is present in index, but not sparse"),
			     path->buf);
	return 0;
}

/*
 * Returns:
 *  0 - Verification completed.
 *  1 - Restart verification - a call to ensure_full_index() freed the cache
 *      tree that is being verified and verification needs to be restarted from
 *      the new toplevel cache tree.
 *  -1 - Verification failed.
 */
static int verify_one(struct repository *r,
		      struct index_state *istate,
		      struct cache_tree *it,
		      struct strbuf *path)
{
	int i, pos, len = path->len;
	struct strbuf tree_buf = STRBUF_INIT;
	struct object_id new_oid;
	int ret;

	for (i = 0; i < it->subtree_nr; i++) {
		strbuf_addf(path, "%s/", it->down[i]->name);
		ret = verify_one(r, istate, it->down[i]->cache_tree, path);
		if (ret)
			goto out;

		strbuf_setlen(path, len);
	}

	if (it->entry_count < 0 ||
	    /* no verification on tests (t7003) that replace trees */
	    lookup_replace_object(r, &it->oid) != &it->oid) {
		ret = 0;
		goto out;
	}

	if (path->len) {
		/*
		 * If the index is sparse and the cache tree is not
		 * index_name_pos() may trigger ensure_full_index() which will
		 * free the tree that is being verified.
		 */
		int is_sparse = istate->sparse_index;
		pos = index_name_pos(istate, path->buf, path->len);
		if (is_sparse && !istate->sparse_index) {
			ret = 1;
			goto out;
		}

		if (pos >= 0) {
			ret = verify_one_sparse(istate, path, pos);
			goto out;
		}

		pos = -pos - 1;
	} else {
		pos = 0;
	}

	if (it->entry_count + pos > istate->cache_nr) {
		ret = error(_("corrupted cache-tree has entries not present in index"));
		goto out;
	}

	i = 0;
	while (i < it->entry_count) {
		struct cache_entry *ce = istate->cache[pos + i];
		const char *slash;
		struct cache_tree_sub *sub = NULL;
		const struct object_id *oid;
		const char *name;
		unsigned mode;
		int entlen;

		if (ce->ce_flags & (CE_STAGEMASK | CE_INTENT_TO_ADD | CE_REMOVE)) {
			ret = error(_("%s with flags 0x%x should not be in cache-tree"),
				    ce->name, ce->ce_flags);
			goto out;
		}

		name = ce->name + path->len;
		slash = strchr(name, '/');
		if (slash) {
			entlen = slash - name;

			sub = find_subtree(it, ce->name + path->len, entlen, 0);
			if (!sub || sub->cache_tree->entry_count < 0) {
				ret = error(_("bad subtree '%.*s'"), entlen, name);
				goto out;
			}

			oid = &sub->cache_tree->oid;
			mode = S_IFDIR;
			i += sub->cache_tree->entry_count;
		} else {
			oid = &ce->oid;
			mode = ce->ce_mode;
			entlen = ce_namelen(ce) - path->len;
			i++;
		}
		strbuf_addf(&tree_buf, "%o %.*s%c", mode, entlen, name, '\0');
		strbuf_add(&tree_buf, oid->hash, r->hash_algo->rawsz);
	}

	hash_object_file(r->hash_algo, tree_buf.buf, tree_buf.len, OBJ_TREE,
			 &new_oid);

	if (!oideq(&new_oid, &it->oid)) {
		ret = error(_("cache-tree for path %.*s does not match. "
			      "Expected %s got %s"), len, path->buf,
			    oid_to_hex(&new_oid), oid_to_hex(&it->oid));
		goto out;
	}

	ret = 0;
out:
	strbuf_setlen(path, len);
	strbuf_release(&tree_buf);
	return ret;
}

int cache_tree_verify(struct repository *r, struct index_state *istate)
{
	struct cache_tree *root;
	struct strbuf path = STRBUF_INIT;
	int ret;

	root = cache_tree_get(istate);
	if (!root) {
		ret = 0;
		goto out;
	}

	ret = verify_one(r, istate, root, &path);
	if (ret < 0)
		goto out;
	if (ret > 0) {
		strbuf_reset(&path);
		root = cache_tree_get(istate);

		ret = verify_one(r, istate, root, &path);
		if (ret < 0)
			goto out;
		if (ret > 0)
			BUG("ensure_full_index() called twice while verifying cache tree");
	}

	ret = 0;

out:
	strbuf_release(&path);
	return ret;
}

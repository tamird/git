#ifndef GREP_WORKTREE_H
#define GREP_WORKTREE_H

#define GREP_WORKTREE_CACHE_MIN_BYTES (1ULL << 30)

struct cache_entry;
struct index_state;
struct repository;

struct grep_worktree_cache;

enum grep_worktree_cache_result {
	GREP_WORKTREE_CACHE_UNKNOWN,
	GREP_WORKTREE_CACHE_EQUAL,
};

int grep_worktree_cache_entry_refreshable(const struct cache_entry *ce);
int grep_worktree_cache_entry_eligible(const struct cache_entry *ce);
/* sidecar_loaded is set when a compact or recovery cache can be reused. */
struct grep_worktree_cache *grep_worktree_cache_load(
	struct repository *repo, struct index_state *istate,
	int *sidecar_loaded);
enum grep_worktree_cache_result grep_worktree_cache_lookup(
	struct grep_worktree_cache *cache, size_t pos);
void grep_worktree_cache_record(struct grep_worktree_cache *cache, size_t pos,
				int equal);
void grep_worktree_cache_hit(struct grep_worktree_cache *cache);
void grep_worktree_cache_write(struct grep_worktree_cache *cache);
void grep_worktree_cache_free(struct grep_worktree_cache *cache);

#endif

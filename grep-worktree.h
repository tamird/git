#ifndef GREP_WORKTREE_H
#define GREP_WORKTREE_H

#define GREP_WORKTREE_CACHE_MIN_BYTES (1ULL << 30)

struct cache_entry;
struct grep_index_identity;
struct index_state;
struct repository;

struct grep_worktree_cache;

enum grep_worktree_cache_result {
	GREP_WORKTREE_CACHE_UNKNOWN,
	GREP_WORKTREE_CACHE_EQUAL,
};

/* A terminal failed proof, not a statement about current worktree bytes. */
enum grep_worktree_cache_miss_reason {
	GREP_WORKTREE_CACHE_MISS_NONE,
	GREP_WORKTREE_CACHE_MISS_LOOKUP_UNAVAILABLE,
	GREP_WORKTREE_CACHE_MISS_DIFFERENT,
	GREP_WORKTREE_CACHE_MISS_IDENTITY_UNREPRESENTABLE,
	GREP_WORKTREE_CACHE_MISS_NO_AUTHORIZED_RECOVERY,
	GREP_WORKTREE_CACHE_MISS_RECOVERY_UNAVAILABLE,
	GREP_WORKTREE_CACHE_MISS_NO_MATCHING_IDENTITY,
	GREP_WORKTREE_CACHE_MISS_CHECKSUM_REJECTED,
	GREP_WORKTREE_CACHE_MISS_NR,
};

int grep_worktree_cache_entry_refreshable(const struct cache_entry *ce);
int grep_worktree_cache_entry_eligible(const struct cache_entry *ce);
/* sidecar_loaded is set when a compact or recovery cache can be reused. */
struct grep_worktree_cache *grep_worktree_cache_load(
	struct repository *repo, struct index_state *istate,
	struct grep_index_identity *identity,
	int *sidecar_loaded);
enum grep_worktree_cache_result grep_worktree_cache_lookup(
	struct grep_worktree_cache *cache, size_t pos);
enum grep_worktree_cache_result grep_worktree_cache_lookup_with_reason(
	struct grep_worktree_cache *cache, size_t pos,
	enum grep_worktree_cache_miss_reason *reason);
void grep_worktree_cache_record(struct grep_worktree_cache *cache, size_t pos,
				int equal);
void grep_worktree_cache_hit(struct grep_worktree_cache *cache);
void grep_worktree_cache_write(struct grep_worktree_cache *cache);
void grep_worktree_cache_free(struct grep_worktree_cache *cache);

#endif

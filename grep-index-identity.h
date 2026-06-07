#ifndef GREP_INDEX_IDENTITY_H
#define GREP_INDEX_IDENTITY_H

#include "hash.h"

#define GREP_WORKTREE_ENTRY_IDENTITY_RAWSZ GIT_SHA256_RAWSZ

struct cache_entry;
struct index_state;
struct repository;

struct grep_worktree_entry_identity {
	uint32_t object_format_id;
	size_t object_rawsz;
};

struct grep_index_identity {
	struct object_id oid_sequence;
	struct object_id worktree;
	struct object_id worktree_scope;
	struct object_id worktree_split_base_identity;
};

void grep_index_identity_oid_sequence_init(
	struct repository *repo, struct git_hash_ctx *ctx, size_t nr);
void grep_worktree_entry_identity_init(
	struct repository *repo,
	struct grep_worktree_entry_identity *identity);
int grep_worktree_entry_identity_hash(
	const struct grep_worktree_entry_identity *identity,
	const struct cache_entry *ce,
	struct object_id *oid);
int grep_index_identity_get(struct repository *repo,
			    struct index_state *istate,
			    struct grep_index_identity *identity);

#endif

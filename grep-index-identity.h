#ifndef GREP_INDEX_IDENTITY_H
#define GREP_INDEX_IDENTITY_H

#include "hash.h"

struct index_state;
struct repository;

struct grep_index_identity {
	struct object_id oid_sequence;
	struct object_id worktree;
	struct object_id worktree_split_base_identity;
};

void grep_index_identity_oid_sequence_init(
	struct repository *repo, struct git_hash_ctx *ctx, size_t nr);
int grep_index_identity_get(struct repository *repo,
			    struct index_state *istate,
			    struct grep_index_identity *identity);

#endif

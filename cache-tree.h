#ifndef CACHE_TREE_H
#define CACHE_TREE_H

#include "tree.h"
#include "tree-walk.h"

struct cache_tree;
enum cache_tree_sub_use {
	CACHE_TREE_SUB_UNUSED,
	CACHE_TREE_SUB_USED,
	CACHE_TREE_SUB_REUSED_OBJECT_VERIFIED,
};

struct cache_tree_sub {
	struct cache_tree *cache_tree;
	int count;		/* internally used by update_one() */
	int namelen;
	enum cache_tree_sub_use used; /* transient during update_one() */
	char name[FLEX_ARRAY];
};

struct cache_tree {
	int entry_count; /* negative means "invalid" */
	struct object_id oid;
	int subtree_nr;
	int subtree_alloc;
	struct cache_tree_sub **down;
};

struct cache_tree *cache_tree(void);
void cache_tree_free(struct cache_tree **);
struct cache_tree *cache_tree_get(struct index_state *);
int cache_tree_root_matches_index(struct index_state *, const struct object_id *);
/*
 * Return the valid subtree entry count and OID, or -1; "" names the root.
 * Optionally count directory nodes, including the named subtree itself.
 */
int cache_tree_get_path(struct index_state *, const char *path,
			struct object_id *, size_t *tree_count);
void cache_tree_discard(struct index_state *);
void cache_tree_invalidate_path(struct index_state *, const char *);
struct cache_tree_sub *cache_tree_sub(struct cache_tree *, const char *);

int cache_tree_subtree_pos(struct cache_tree *it, const char *path, int pathlen);

void cache_tree_write(struct strbuf *, struct cache_tree *root);
struct cache_tree *cache_tree_read(const char *buffer, unsigned long size);

int cache_tree_fully_valid(struct cache_tree *);
int cache_tree_fully_valid_with_counts(struct cache_tree *, uintmax_t *nodes,
				       uintmax_t *object_checks);
int cache_tree_fully_valid_with_order(struct cache_tree *, int allow_oid_order,
				      uintmax_t *nodes, uintmax_t *object_checks);
int cache_tree_update(struct index_state *, int);
int cache_tree_verify(struct repository *, struct index_state *);

/* bitmasks to write_index_as_tree flags */
#define WRITE_TREE_MISSING_OK 1
#define WRITE_TREE_IGNORE_CACHE_TREE 2
#define WRITE_TREE_DRY_RUN 4
#define WRITE_TREE_SILENT 8
#define WRITE_TREE_REPAIR 16
#define WRITE_TREE_NO_INDEX_WRITE    32
#define WRITE_TREE_VALIDATE_ONLY     64

/* error return codes */
#define WRITE_TREE_UNREADABLE_INDEX (-1)
#define WRITE_TREE_UNMERGED_INDEX (-2)
#define WRITE_TREE_PREFIX_ERROR (-3)
#define WRITE_TREE_INVALID_CACHE_TREE	    (-4)
#define WRITE_TREE_PROMISOR_REPOSITORY	    (-5)
#define WRITE_TREE_INVALID_VALIDATION_FLAGS (-6)

struct tree *write_in_core_index_as_tree(struct repository *repo,
					 struct index_state *index_state);
int write_index_as_tree(struct object_id *oid, struct index_state *index_state, const char *index_path, int flags, const char *prefix);
void prime_cache_tree(struct repository *, struct index_state *, struct tree *);

int cache_tree_matches_traversal(struct index_state *, struct name_entry *ent, struct traverse_info *info);
#endif

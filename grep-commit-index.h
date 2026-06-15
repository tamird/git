#ifndef GREP_COMMIT_INDEX_H
#define GREP_COMMIT_INDEX_H

#include <stddef.h>
#include <stdint.h>

struct object_id;
struct repository;
struct rev_info;

struct grep_commit_index;

/*
 * The OID bytes point into the mapped index and remain valid until the index
 * is freed. Callers can iterate them in oid_size-byte steps.
 */
struct grep_commit_index_edge {
	const unsigned char *oids;
	size_t nr;
	size_t oid_size;
	uint32_t changed_pairs;
};

struct grep_commit_index *grep_commit_index_load(struct repository *repo);

/*
 * Return zero for a complete edge matching commit_oid and parent_oid. Missing,
 * incomplete, or malformed records are unavailable and return -1. Root edges
 * use an all-zero parent OID.
 */
int grep_commit_index_lookup(struct grep_commit_index *index,
			     const struct object_id *commit_oid,
			     const struct object_id *parent_oid,
			     struct grep_commit_index_edge *edge);

void grep_commit_index_free(struct grep_commit_index *index);

/* Replacements must be disabled before revisions are initialized. */
int write_grep_commit_index(struct repository *repo, struct rev_info *revs,
			    int show_progress);

#endif

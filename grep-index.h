#ifndef GREP_INDEX_H
#define GREP_INDEX_H

struct object_id;
struct grep_opt;
struct repository;

struct grep_index;
struct grep_index_query;

struct grep_index *grep_index_load(struct repository *repo);
void grep_index_free(struct grep_index *index);
struct grep_index_query *grep_index_query_create(const struct grep_opt *opt);
void grep_index_query_free(struct grep_index_query *query);

int grep_index_maybe_contains(struct grep_index *index,
			      struct repository *repo,
			      const struct object_id *oid,
			      const struct grep_index_query *query);

int write_grep_index(struct repository *repo, int show_progress);

#endif

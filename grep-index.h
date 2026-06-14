#ifndef GREP_INDEX_H
#define GREP_INDEX_H

struct object_id;
struct grep_opt;
struct repository;
struct rev_info;
struct strbuf;

struct grep_index;
struct grep_index_memory;
struct grep_index_prepared;
struct grep_index_query;

struct grep_index_location {
	uint32_t segment;
	uint32_t position;
	uint8_t filter_class;
	uint8_t valid;
};

struct grep_index *grep_index_load(struct repository *repo);
void grep_index_free(struct grep_index *index);
struct grep_index_query *grep_index_query_create(const struct grep_opt *opt);
void grep_index_query_free(struct grep_index_query *query);
int grep_index_query_serialize(const struct grep_index_query *query,
			       struct strbuf *buf);
struct grep_index_query *grep_index_query_deserialize(const char *data,
						      size_t len);
const struct object_id *grep_index_query_cache_key(
	const struct grep_index_query *query);

int grep_index_maybe_contains(struct grep_index *index,
			      struct repository *repo,
			      const struct object_id *oid,
			      const struct grep_index_query *query);
int grep_index_is_transposed(struct grep_index *index);
struct grep_index_prepared *grep_index_prepare(
	struct grep_index *index,
	const struct grep_index_query *query);
int grep_index_prepared_maybe_contains(
	struct grep_index_prepared *prepared,
	struct repository *repo,
	const struct object_id *oid);
int grep_index_resolve_location(
	struct grep_index *index,
	const struct object_id *oid,
	struct grep_index_location *location);
int grep_index_prepared_location_maybe_contains(
	struct grep_index_prepared *prepared,
	const struct grep_index_location *location);
void grep_index_prepared_free(struct grep_index_prepared *prepared);

struct grep_index_memory *grep_index_memory_new(
	struct repository *repo, struct grep_index *persistent);
void grep_index_memory_free(struct grep_index_memory *index);
/* Return a replacement generation while no other thread can use index. */
struct grep_index_memory *grep_index_memory_rotate_if_requested(
	struct grep_index_memory *index);
void grep_index_memory_release_object_store(struct grep_index_memory *index);
int grep_index_memory_maybe_contains(struct grep_index_memory *index,
				     const struct object_id *oid,
				     const struct grep_index_query *query);

int write_grep_index(struct repository *repo, int show_progress,
		     struct rev_info *revs);
int write_transposed_grep_index(struct repository *repo);

#endif

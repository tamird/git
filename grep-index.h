#ifndef GREP_INDEX_H
#define GREP_INDEX_H

struct object_id;
struct oid_array;
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
int grep_index_query_negative_is_cacheable(
	const struct grep_index_query *query, const char *buf, size_t len);

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
int grep_index_location_maybe_contains(
	struct grep_index *index,
	const struct grep_index_location *location,
	const struct grep_index_query *query);
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
/*
 * Consume oids and reset it to OID_ARRAY_INIT on every return path. Transpose
 * only the new segment unless transpose_existing requests a full catch-up.
 */
int write_grep_index_oids(struct repository *repo, int show_progress,
			  struct oid_array *oids, int transpose_existing);
int write_transposed_grep_index(struct repository *repo);
int append_grep_index_chain_entry(struct repository *repo,
				  const char *chain_name,
				  const char *entry);

#endif

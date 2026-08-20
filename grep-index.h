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

/* Values are exposed by pickaxe Trace2 data. */
enum grep_index_load_outcome {
	GREP_INDEX_LOAD_NOT_ATTEMPTED = 0,
	GREP_INDEX_LOAD_LOADED = 1,
	GREP_INDEX_LOAD_REPLACEMENTS = 2,
	GREP_INDEX_LOAD_NO_GITDIR = 3,
	GREP_INDEX_LOAD_MANIFEST_MISSING = 4,
	GREP_INDEX_LOAD_MANIFEST_READ_ERROR = 5,
	GREP_INDEX_LOAD_MANIFEST_EMPTY = 6,
	GREP_INDEX_LOAD_MANIFEST_INVALID = 7,
	GREP_INDEX_LOAD_SEGMENT_UNUSABLE = 8,
};

struct grep_index *grep_index_load(struct repository *repo);
struct grep_index *grep_index_load_with_outcome(
	struct repository *repo, enum grep_index_load_outcome *outcome);
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

enum grep_index_memory_build_event {
	GREP_INDEX_MEMORY_BUILD_CLAIMED,
	GREP_INDEX_MEMORY_WAIT_OBSERVED,
};

typedef void (*grep_index_memory_build_observer_fn)(
	enum grep_index_memory_build_event event,
	const struct object_id *oid, int ignore_case, void *data);

struct grep_index_memory *grep_index_memory_new(
	struct repository *repo, struct grep_index *persistent);
void grep_index_memory_free(struct grep_index_memory *index);
/*
 * Install or clear a private test observer only while index has no users.
 * Keep observer and data alive and unchanged until all users have joined.
 * A replacement generation starts without an observer.  Passing NULL also
 * clears data; the caller retains ownership of data.
 *
 * BUILD_CLAIMED runs after the index mutex is released and may wait on a
 * test-owned barrier.  WAIT_OBSERVED runs once before the condition wait,
 * with the index mutex held, and must return without waiting.  Neither
 * callback may reenter the memory index.  The oid is borrowed for the call.
 */
void grep_index_memory_set_build_observer_for_test(
	struct grep_index_memory *index,
	grep_index_memory_build_observer_fn observer, void *data);
/* Return a replacement generation while no other thread can use index. */
struct grep_index_memory *grep_index_memory_rotate_if_requested(
	struct grep_index_memory *index);
void grep_index_memory_release_object_store(struct grep_index_memory *index);

enum grep_index_memory_query_origin {
	GREP_INDEX_MEMORY_QUERY_PERSISTENT,
	GREP_INDEX_MEMORY_QUERY_READY_REUSED,
	GREP_INDEX_MEMORY_QUERY_COLD_ATTEMPT,
	GREP_INDEX_MEMORY_QUERY_UNAVAILABLE_PREBUILD,
};

struct grep_index_memory_query_outcome {
	enum grep_index_memory_query_origin origin;
	unsigned int waited : 1;
};

/*
 * Report the route taken independently of the returned classification.
 * PERSISTENT delegates to the persistent index; READY_REUSED uses an
 * existing ready memory filter, possibly after waiting for its builder.
 * COLD_ATTEMPT means this call claimed a build, even if that build fails.
 * UNAVAILABLE_PREBUILD means none of those routes was taken.
 * waited records one observation of an existing BUILDING entry, including
 * a wait that ends in FAILED or SATURATED.  outcome may be NULL.
 */
int grep_index_memory_maybe_contains_with_outcome(
	struct grep_index_memory *index,
	const struct object_id *oid,
	const struct grep_index_query *query,
	struct grep_index_memory_query_outcome *outcome);
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

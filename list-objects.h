#ifndef LIST_OBJECTS_H
#define LIST_OBJECTS_H

struct commit;
struct object;
struct rev_info;
struct tree_mark_stats;

typedef void (*show_commit_fn)(struct commit *, void *);
typedef void (*show_object_fn)(struct object *, const char *, void *);

typedef void (*show_edge_fn)(struct commit *);
void mark_edges_uninteresting(struct rev_info *revs,
			      show_edge_fn show_edge,
			      int sparse);
/* Collect statistics for the nonsparse edge walk. */
void mark_edges_uninteresting_with_stats(struct rev_info *revs,
					 show_edge_fn show_edge,
					 struct tree_mark_stats *stats);

struct oidset;
struct list_objects_filter_options;

void traverse_commit_list_filtered(
	struct rev_info *revs,
	show_commit_fn show_commit,
	show_object_fn show_object,
	void *show_data,
	struct oidset *omitted);

struct list_objects_tree_read_stats {
	uint64_t attempt_count;
	uint64_t elapsed_ns;
	int invalid;
};

/*
 * Optional aggregate observations of tree parsing and non-commit traversal.
 * "Parse needed" means object.parsed was false, not an ODB or page-cache miss.
 * Such calls include failed attempts; already-parsed calls are counted without
 * clock calls. Timings cover the whole parse-needed call, not only object I/O.
 * Bookkeeping and clock-boundary overhead are not an uninstrumented baseline.
 *
 * Packed location/content observations reuse the optional ODB read results.
 * They include misses and failed attempts before a later source succeeds;
 * content includes cache copies and unpacking, not just inflation. Only a
 * successfully started parse-needed clock enables these ODB clocks. NULL or
 * failed outer clocks leave these timings unavailable, not valid zero totals.
 *
 * Non-commit timing sums sequential traverse_non_commits() calls, including
 * recursive object processing and pending-array cleanup. It includes parse
 * timing, but excludes revision iteration and queuing root trees. Its separate
 * validity flag does not affect parse counts or timings.
 *
 * The caller supplies get_time: zero means a checked monotonic nanosecond value,
 * nonzero invalidates the corresponding timings. NULL disables timings, but not
 * counts. Traversal resets all other fields, preserves errno around each clock
 * call, and retains neither the stats pointer nor the callback after the walk.
 */
struct list_objects_tree_parse_stats {
	intmax_t parse_needed_count;
	intmax_t already_parsed_count;
	uint64_t parse_needed_ns;
	int counts_valid;
	int timings_valid;
	uint64_t non_commits_ns;
	int non_commits_timings_valid;
	struct list_objects_tree_read_stats packed_entry_location;
	struct list_objects_tree_read_stats packed_content;
	int (*get_time)(uint64_t *now);
};

void traverse_commit_list_with_tree_parse_stats(
	struct rev_info *revs,
	show_commit_fn show_commit,
	show_object_fn show_object,
	void *show_data,
	struct list_objects_tree_parse_stats *stats);

static inline void traverse_commit_list(
	struct rev_info *revs,
	show_commit_fn show_commit,
	show_object_fn show_object,
	void *show_data)
{
	traverse_commit_list_filtered(revs, show_commit,
				      show_object, show_data, NULL);
}

#endif /* LIST_OBJECTS_H */

#ifndef NAME_HASH_H
#define NAME_HASH_H

struct cache_entry;
struct index_state;

enum index_icase_probe_result {
	INDEX_ICASE_PROBE_UNKNOWN,
	INDEX_ICASE_PROBE_ABSENT,
	INDEX_ICASE_PROBE_PRESENT,
};

int index_dir_find(struct index_state *istate, const char *name, int namelen,
		   struct strbuf *canonical_path);

#define index_dir_exists(i, n, l) index_dir_find((i), (n), (l), NULL)

void adjust_dirname_case(struct index_state *istate, char *name);
struct cache_entry *index_file_exists(struct index_state *istate, const char *name, int namelen, int igncase);
/*
 * Probe the sorted index without constructing the name hash. The caller must
 * fall back to index_file_exists() when the result is UNKNOWN. "scans" is a
 * cumulative input/output budget; sparse indexes, non-exact parents,
 * ambiguous aliases, and budget exhaustion return UNKNOWN.
 */
enum index_icase_probe_result
index_file_exists_icase_probe(struct index_state *istate,
			      const char *name, size_t namelen,
			      size_t *scans, size_t scan_limit);
/* UNKNOWN requires falling back to index_dir_exists() for directory aliases. */
enum index_icase_probe_result
index_dir_exists_icase_probe(struct index_state *istate,
			     const char *name, size_t namelen,
			     size_t *scans, size_t scan_limit);

int test_lazy_init_name_hash(struct index_state *istate, int try_threaded);
void add_name_hash(struct index_state *istate, struct cache_entry *ce);
void remove_name_hash(struct index_state *istate, struct cache_entry *ce);
void free_name_hash(struct index_state *istate);

#endif /* NAME_HASH_H */

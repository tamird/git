#include "git-compat-util.h"
#include "strbuf.h"
#include "trace2/tr2_tgt.h"
#include "trace2/tr2_tls.h"
#include "trace2/tr2_ctr.h"

/*
 * A global counter block to aggregate values from the partial sums
 * from each thread.
 */
static struct tr2_counter_block final_counter_block; /* access under tr2tls_mutex */

/*
 * Define metadata for each global counter.
 *
 * This array must match the "enum trace2_counter_id" and the values
 * in "struct tr2_counter_block.counter[*]".
 */
static struct tr2_counter_metadata tr2_counter_metadata[TRACE2_NUMBER_OF_COUNTERS] = {
	[TRACE2_COUNTER_ID_TEST1] = {
		.category = "test",
		.name = "test1",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_TEST2] = {
		.category = "test",
		.name = "test2",
		.want_per_thread_events = 1,
	},
	[TRACE2_COUNTER_ID_ATTR_QUERIES] = {
		.category = "attr",
		.name = "queries",
	},
	[TRACE2_COUNTER_ID_PACKED_REFS_JUMPS] = {
		.category = "packed-refs",
		.name = "jumps_made",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_REFTABLE_RESEEKS] = {
		.category = "reftable",
		.name = "reseeks_made",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_FSYNC_WRITEOUT_ONLY] = {
		.category = "fsync",
		.name = "writeout-only",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_FSYNC_HARDWARE_FLUSH] = {
		.category = "fsync",
		.name = "hardware-flush",
		.want_per_thread_events = 0,
	},

	[TRACE2_COUNTER_ID_PCHECKOUT_PARALLEL_ITEMS] = {
		.category = "pcheckout",
		.name = "parallel/items-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_SEQUENCER_EMPTY_CACHE_TREE_VALIDATE_CALLS] = {
		.category = "sequencer",
		.name = "empty-check/cache-tree-validate/calls-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_SEQUENCER_EMPTY_CACHE_TREE_VALIDATE_VALID] = {
		.category = "sequencer",
		.name = "empty-check/cache-tree-validate/valid-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_SEQUENCER_EMPTY_CACHE_TREE_VALIDATE_NODES] = {
		.category = "sequencer",
		.name = "empty-check/cache-tree-validate/nodes-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_SEQUENCER_EMPTY_CACHE_TREE_VALIDATE_OBJECT_CHECKS] = {
		.category = "sequencer",
		.name = "empty-check/cache-tree-validate/object-checks-total",
		.want_per_thread_events = 0,
	},

	[TRACE2_COUNTER_ID_DIFF_FOLLOW_FULL_TREE_COMPLETED] = {
		.category = "diff",
		.name = "follow-full-tree/completed",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_FULL_TREE_ELIGIBLE_ADDITIONS] = {
		.category = "diff",
		.name = "follow-full-tree/eligible-additions",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_LOG_FOLLOW_PARENT_SAME_ROOT] = {
		.category = "log",
		.name = "follow-parent/same-root-count",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/invalid",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_READS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/read-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INMEMORY] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/source-inmemory-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_LOOSE] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/source-loose-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_PACKED_COPY] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/source-packed-copy-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_PACKED_UNPACK] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/source-packed-unpack-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_LOCATION_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/entry-location-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_LOCATION_NS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/entry-location-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_CONTENT_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-content-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_CONTENT_NS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-content-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/cache-copy-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/cache-copy-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/invalid",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_LOCATION_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/covered-entry-location-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_SEARCH_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/midx-search-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_SEARCH_NS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/midx-search-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_RESOLVE_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/midx-resolve-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_RESOLVE_NS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/midx-resolve-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_COUNT] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/fallback-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_NS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/fallback-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_PACK_ATTEMPTS] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/odb/packed-lookup/fallback-pack-attempt-count",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_INVALID] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/invalid",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_COVERED] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/covered-reads",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_SELECTED] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/selected-reads",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_FIRST] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/first-reads",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_SAME_SCAN] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/same-search-repeats",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_CROSS_SCAN] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/cross-search-repeats",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_LE_64] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/gap-le-64",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_LE_4096] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/gap-le-4096",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_LE_65536] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/gap-le-65536",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_GT_65536] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/gap-gt-65536",
	},
	[TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_TRUNCATED] = {
		.category = "diff",
		.name = "follow-full-tree/tree-read/requested-oid-sample/truncated",
	},
	[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_COUNT] = {
		.category = "diff",
		.name = "rename/populate/size-only-count",
	},
	[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_NS] = {
		.category = "diff",
		.name = "rename/populate/size-only-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_COUNT] = {
		.category = "diff",
		.name = "rename/populate/full-count",
	},
	[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_NS] = {
		.category = "diff",
		.name = "rename/populate/full-ns",
	},
	[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SUMMARY_INVALID] = {
		.category = "diff",
		.name = "rename/populate/summary-invalid",
	},

	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_CALLS] = {
		.category = "cache_tree",
		.name = "update/calls-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_FAILED] = {
		.category = "cache_tree",
		.name = "update/failed-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_NODES] = {
		.category = "cache_tree",
		.name = "update/nodes-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSED] = {
		.category = "cache_tree",
		.name = "update/reused-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_SPARSE] = {
		.category = "cache_tree",
		.name = "update/sparse-nodes-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_HASH_ONLY] = {
		.category = "cache_tree",
		.name = "update/hash-only-nodes-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_ENTRIES_VISITED] = {
		.category = "cache_tree",
		.name = "update/entries-visited-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_ENTRY_OBJECT_CHECKS] = {
		.category = "cache_tree",
		.name = "update/entry-object-checks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_ENTRY_OBJECT_CHECK_NS] = {
		.category = "cache_tree",
		.name = "update/entry-object-check-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSED_CHILD_PARENT_CHECKS] = {
		.category = "cache_tree",
		.name = "update/reused-child-parent-checks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSED_CHILD_PARENT_CHECK_NS] = {
		.category = "cache_tree",
		.name = "update/reused-child-parent-check-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_OBJECT_CHECKS] = {
		.category = "cache_tree",
		.name = "update/reuse-object-checks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_OBJECT_CHECK_NS] = {
		.category = "cache_tree",
		.name = "update/reuse-object-check-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_OBJECT_PROBED_CHECKS] = {
		.category = "cache_tree",
		.name = "update/reuse-object-probed-checks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REPAIR_TREE_CHECKS] = {
		.category = "cache_tree",
		.name = "update/repair-tree-checks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REPAIR_TREE_CHECK_NS] = {
		.category = "cache_tree",
		.name = "update/repair-tree-check-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_HASH_ONLY_NS] = {
		.category = "cache_tree",
		.name = "update/hash-only-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OBJECT_WRITE_CALLS] = {
		.category = "cache_tree",
		.name = "update/object-write-calls-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OBJECT_WRITE_NS] = {
		.category = "cache_tree",
		.name = "update/object-write-ns-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OWNED_ODB_COMMIT_CALLS] = {
		.category = "cache_tree",
		.name = "update/owned-odb-commit-calls-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_OWNED_ODB_COMMIT_NS] = {
		.category = "cache_tree",
		.name = "update/owned-odb-commit-ns-total",
		.want_per_thread_events = 0,
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_ATTEMPTS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-attempts-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_ATTEMPT_NS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-attempt-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_PREPARES] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-prepares-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_PREPARE_NS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-prepare-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_MIDX_SEARCHES] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-midx-searches-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_MIDX_SEARCH_NS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-midx-search-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_MIDX_RESOLVES] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-midx-resolves-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_MIDX_RESOLVE_NS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-midx-resolve-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_FALLBACKS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-fallbacks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_FALLBACK_NS] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-fallback-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_INVALID] = {
		.category = "cache_tree",
		.name = "update/reuse-packed-invalid-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_LOOKUP_SELECTED_CHECKS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-lookup-selected-checks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_ATTEMPTS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-attempts-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_ATTEMPT_NS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-attempt-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_PREPARES] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-prepares-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_PREPARE_NS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-prepare-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_MIDX_SEARCHES] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-midx-searches-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_MIDX_SEARCH_NS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-midx-search-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_MIDX_RESOLVES] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-midx-resolves-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_MIDX_RESOLVE_NS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-midx-resolve-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_FALLBACKS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-fallbacks-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_FALLBACK_NS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-fallback-ns-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_FALLBACK_PACK_ATTEMPTS] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-fallback-pack-attempts-total",
	},
	[TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_INVALID] = {
		.category = "cache_tree",
		.name = "validate/oid-order/packed-invalid-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_LOOKUP_SELECTED_CHECKS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-lookup-selected-checks-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_ATTEMPTS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-attempts-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_ATTEMPT_NS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-attempt-ns-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_PREPARES] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-prepares-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_PREPARE_NS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-prepare-ns-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_MIDX_SEARCHES] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-midx-searches-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_MIDX_SEARCH_NS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-midx-search-ns-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_MIDX_RESOLVES] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-midx-resolves-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_MIDX_RESOLVE_NS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-midx-resolve-ns-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_FALLBACKS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-fallbacks-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_FALLBACK_NS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-fallback-ns-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_FALLBACK_PACK_ATTEMPTS] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-fallback-pack-attempts-total",
	},
	[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_INVALID] = {
		.category = "ref-filter",
		.name = "object_metadata/preload/packed-invalid-total",
	},

	[TRACE2_COUNTER_ID_GREP_SOURCE_PROCESSED] = {
		.category = "grep",
		.name = "source/processed",
	},
	[TRACE2_COUNTER_ID_GREP_SOURCE_SELECTED] = {
		.category = "grep",
		.name = "source/selected",
	},
	[TRACE2_COUNTER_ID_GREP_LOOKUP_INVALID] = {
		.category = "grep",
		.name = "packed/lookup/invalid",
	},
	[TRACE2_COUNTER_ID_GREP_LOOKUP_COUNT] = {
		.category = "grep",
		.name = "packed/lookup/count",
	},
	[TRACE2_COUNTER_ID_GREP_LOOKUP_MIDX_SEARCH_NS] = {
		.category = "grep",
		.name = "packed/lookup/midx-search-ns",
	},
	[TRACE2_COUNTER_ID_GREP_LOOKUP_MIDX_RESOLVE_NS] = {
		.category = "grep",
		.name = "packed/lookup/midx-resolve-ns",
	},
	[TRACE2_COUNTER_ID_GREP_LOOKUP_FALLBACK_NS] = {
		.category = "grep",
		.name = "packed/lookup/fallback-ns",
	},

	[TRACE2_COUNTER_ID_ICASE_PROBE_EMPTY_NAME] = {
		.category = "index",
		.name = "icase-probe/empty-name",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_TRAILING_SLASH] = {
		.category = "index",
		.name = "icase-probe/trailing-slash",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_SPARSE_INDEX] = {
		.category = "index",
		.name = "icase-probe/sparse-index",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_HASH_INITIALIZED] = {
		.category = "index",
		.name = "icase-probe/hash-initialized",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_EMPTY_COMPONENT] = {
		.category = "index",
		.name = "icase-probe/empty-component",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_SCAN_LIMIT] = {
		.category = "index",
		.name = "icase-probe/scan-limit",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_AMBIGUOUS_LEAF] = {
		.category = "index",
		.name = "icase-probe/ambiguous-leaf",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_NONEXACT_PARENT] = {
		.category = "index",
		.name = "icase-probe/nonexact-parent",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_AMBIGUOUS_PARENT] = {
		.category = "index",
		.name = "icase-probe/ambiguous-parent",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_MISSING_PARENT] = {
		.category = "index",
		.name = "icase-probe/missing-parent",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_LIMIT_PRIOR_SCANS] = {
		.category = "index",
		.name = "icase-probe/scan-limit/prior-scans",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_LIMIT_RANGE_ENTRIES] = {
		.category = "index",
		.name = "icase-probe/scan-limit/range-entries",
	},
	[TRACE2_COUNTER_ID_ICASE_PROBE_LIMIT_PARENT] = {
		.category = "index",
		.name = "icase-probe/scan-limit/parent",
	},
	[TRACE2_COUNTER_ID_SEND_PACK_PREPARE_HAVES] = {
		.category = "send_pack",
		.name = "prepare_objects/haves",
	},
	[TRACE2_COUNTER_ID_SEND_PACK_PREPARE_WANTS] = {
		.category = "send_pack",
		.name = "prepare_objects/wants",
	},

	/* Add additional metadata before here. */
};

/* These families promise checked sums and a sticky validity result. */
static void add_checked_counter(struct tr2_counter_block *block,
				enum trace2_counter_id first,
				enum trace2_counter_id cid, uint64_t value)
{
	uint64_t *invalid = &block->counter[first].value;
	uint64_t *sum = &block->counter[cid].value;

	if (cid == first) {
		if (value)
			*invalid = 1;
	} else if (!*invalid) {
		if (value > UINT64_MAX - *sum)
			*invalid = 1;
		else
			*sum += value;
	}
}

static inline void tr2_counter_increment_for_ctx(struct tr2tls_thread_ctx *ctx,
						 enum trace2_counter_id cid,
						 uint64_t value)
{
	struct tr2_counter *c = &ctx->counter_block.counter[cid];

	if (cid >= TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID &&
	    cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS)
		add_checked_counter(&ctx->counter_block,
			TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID, cid, value);
	else if (cid >= TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID &&
		 cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_PACK_ATTEMPTS)
		add_checked_counter(&ctx->counter_block,
			TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID, cid, value);
	else if (cid >= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_INVALID &&
		 cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_TRUNCATED)
		add_checked_counter(&ctx->counter_block,
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_INVALID, cid, value);
	else if (cid >= TRACE2_COUNTER_ID_GREP_LOOKUP_INVALID &&
		 cid <= TRACE2_COUNTER_ID_GREP_LOOKUP_FALLBACK_NS)
		add_checked_counter(&ctx->counter_block,
				    TRACE2_COUNTER_ID_GREP_LOOKUP_INVALID, cid, value);
	else if (cid >= TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_COUNT &&
		 cid <= TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_NS) {
		if (value > UINT64_MAX - c->value)
			ctx->counter_block.counter[
				TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SUMMARY_INVALID].value = 1;
		c->value += value;
	} else {
		c->value += value;
	}

	ctx->used_any_counter = 1;
	if (tr2_counter_metadata[cid].want_per_thread_events)
		ctx->used_any_per_thread_counter = 1;
}

void tr2_counter_increment(enum trace2_counter_id cid, uint64_t value)
{
	tr2_counter_increment_for_ctx(tr2tls_get_self(), cid, value);
}

void tr2_counter_increment_many(enum trace2_counter_id first,
				const uint64_t *values, size_t nr)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	size_t i;

	for (i = 0; i < nr; i++)
		tr2_counter_increment_for_ctx(ctx, first + i, values[i]);
}

void tr2_update_final_counters(void)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	enum trace2_counter_id cid;

	if (!ctx->used_any_counter)
		return;

	/*
	 * Access `final_counter_block` requires holding `tr2tls_mutex`.
	 * We assume that our caller is holding the lock.
	 */

	for (cid = 0; cid < TRACE2_NUMBER_OF_COUNTERS; cid++) {
		struct tr2_counter *c_final = &final_counter_block.counter[cid];
		const struct tr2_counter *c = &ctx->counter_block.counter[cid];

		if (cid >= TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID &&
		    cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS)
			add_checked_counter(&final_counter_block,
				TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID,
				cid, c->value);
		else if (cid >= TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID &&
			 cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_PACK_ATTEMPTS)
			add_checked_counter(&final_counter_block,
				TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID,
				cid, c->value);
		else if (cid >= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_INVALID &&
			 cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_TRUNCATED)
			add_checked_counter(&final_counter_block,
				TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_INVALID,
				cid, c->value);
		else if (cid >= TRACE2_COUNTER_ID_GREP_LOOKUP_INVALID &&
			 cid <= TRACE2_COUNTER_ID_GREP_LOOKUP_FALLBACK_NS)
			add_checked_counter(&final_counter_block,
					    TRACE2_COUNTER_ID_GREP_LOOKUP_INVALID,
					    cid, c->value);
		else if (cid >= TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_COUNT &&
			 cid <= TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_NS) {
			if (c->value > UINT64_MAX - c_final->value)
				final_counter_block.counter[
					TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SUMMARY_INVALID].value = 1;
			c_final->value += c->value;
		} else if (cid == TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SUMMARY_INVALID) {
			if (c->value)
				c_final->value = 1;
		} else {
			c_final->value += c->value;
		}
	}
}

void tr2_emit_per_thread_counters(tr2_tgt_evt_counter_t *fn_apply)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	enum trace2_counter_id cid;

	if (!ctx->used_any_per_thread_counter)
		return;

	/*
	 * For each counter, if the counter wants per-thread events
	 * and this thread used it (the value is non-zero), emit it.
	 */
	for (cid = 0; cid < TRACE2_NUMBER_OF_COUNTERS; cid++)
		if (tr2_counter_metadata[cid].want_per_thread_events &&
		    ctx->counter_block.counter[cid].value)
			fn_apply(&tr2_counter_metadata[cid],
				 &ctx->counter_block.counter[cid],
				 0);
}

static void emit_counter_snapshot(const char *category,
				  enum trace2_counter_id first,
				  enum trace2_counter_id last)
{
	struct strbuf us_name = STRBUF_INIT;
	enum trace2_counter_id cid;
	int saved_errno = errno;

	for (cid = first; cid <= last; cid++) {
		const char *name = tr2_counter_metadata[cid].name;
		uint64_t value = final_counter_block.counter[cid].value;

		if (ends_with(name, "-ns-total")) {
			strbuf_reset(&us_name);
			strbuf_add(&us_name, name,
				   strlen(name) - strlen("-ns-total"));
			strbuf_addstr(&us_name, "-us-total");
			name = us_name.buf;
			value /= 1000;
		}
		if (value <= INTMAX_MAX)
			trace2_data_intmax(category, NULL, name, value);
	}
	strbuf_release(&us_name);
	errno = saved_errno;
}

void tr2_emit_final_counters(tr2_tgt_evt_counter_t *fn_apply)
{
	uint64_t follow_completed = final_counter_block.counter[
		TRACE2_COUNTER_ID_DIFF_FOLLOW_FULL_TREE_COMPLETED].value;
	uint64_t follow_additions = final_counter_block.counter[
		TRACE2_COUNTER_ID_DIFF_FOLLOW_FULL_TREE_ELIGIBLE_ADDITIONS].value;
	enum trace2_counter_id cid;

	/*
	 * Access `final_counter_block` requires holding `tr2tls_mutex`.
	 * We assume that our caller is holding the lock.
	 */

	for (cid = 0; cid < TRACE2_NUMBER_OF_COUNTERS; cid++)
		if (final_counter_block.counter[cid].value)
			fn_apply(&tr2_counter_metadata[cid],
				 &final_counter_block.counter[cid],
				 1);

	/*
	 * Retain an explicit zero for DATA-only consumers when a full-tree
	 * traversal completed. Its existing timer DATA supplies the count.
	 */
	if (follow_completed && follow_completed <= INTMAX_MAX &&
	    follow_additions <= INTMAX_MAX) {
		int saved_errno = errno;

		trace2_data_intmax("diff", NULL,
				   "follow-full-tree/eligible-additions",
				   follow_additions);
		errno = saved_errno;
	}

	/* A completed descriptor, not a completed traversal, owns this cohort. */
	if (final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_READS].value ||
	    final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID].value) {
		int saved_errno = errno;
		int valid = !final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_INVALID].value;

		for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_READS;
		     cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS; cid++)
			if (cid != TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_LOCATION_NS &&
			    cid != TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_CONTENT_NS &&
			    cid != TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS &&
			    final_counter_block.counter[cid].value > INTMAX_MAX)
				valid = 0;

		trace2_data_intmax("diff", NULL, "follow-full-tree/tree-read/odb/valid", valid);
		for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_READS;
		     valid && cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS; cid++) {
			const char *name = tr2_counter_metadata[cid].name;
			uint64_t value = final_counter_block.counter[cid].value;

			/* Round only after checked command-cumulative ns aggregation. */
			if (cid == TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_LOCATION_NS) {
				name = "follow-full-tree/tree-read/odb/entry-location-us";
				value /= 1000;
			} else if (cid == TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_CONTENT_NS) {
				name = "follow-full-tree/tree-read/odb/packed-content-us";
				value /= 1000;
			} else if (cid == TRACE2_COUNTER_ID_DIFF_FOLLOW_ODB_COPY_NS) {
				name = "follow-full-tree/tree-read/odb/cache-copy-us";
				value /= 1000;
			}
			trace2_data_intmax("diff", NULL, name, value);
		}
		errno = saved_errno;
	}

	if (final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_LOCATION_COUNT].value ||
	    final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID].value) {
		int saved_errno = errno;
		int valid = !final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_INVALID].value;

		for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_LOCATION_COUNT;
		     cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_PACK_ATTEMPTS; cid++)
			if (cid != TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_SEARCH_NS &&
			    cid != TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_RESOLVE_NS &&
			    cid != TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_NS &&
			    final_counter_block.counter[cid].value > INTMAX_MAX)
				valid = 0;

		trace2_data_intmax("diff", NULL,
			"follow-full-tree/tree-read/odb/packed-lookup/valid", valid);
		for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_LOCATION_COUNT;
		     valid && cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_PACK_ATTEMPTS;
		     cid++) {
			const char *name = tr2_counter_metadata[cid].name;
			uint64_t value = final_counter_block.counter[cid].value;

			if (cid == TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_SEARCH_NS) {
				name = "follow-full-tree/tree-read/odb/packed-lookup/midx-search-us";
				value /= 1000;
			} else if (cid == TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_MIDX_RESOLVE_NS) {
				name = "follow-full-tree/tree-read/odb/packed-lookup/midx-resolve-us";
				value /= 1000;
			} else if (cid == TRACE2_COUNTER_ID_DIFF_FOLLOW_LOOKUP_FALLBACK_NS) {
				name = "follow-full-tree/tree-read/odb/packed-lookup/fallback-us";
				value /= 1000;
			}
			trace2_data_intmax("diff", NULL, name, value);
		}
		errno = saved_errno;
	}

	if (follow_completed) {
		uint64_t covered = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_COVERED].value;
		uint64_t selected = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_SELECTED].value;
		uint64_t first = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_FIRST].value;
		uint64_t same = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_SAME_SCAN].value;
		uint64_t cross = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_CROSS_SCAN].value;
		uint64_t repeats = 0, remaining;
		int saved_errno = errno;
		int valid = !final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_INVALID].value;

		for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_COVERED;
		     cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_GT_65536; cid++)
			if (final_counter_block.counter[cid].value > INTMAX_MAX)
				valid = 0;
		if (selected > covered || first > selected)
			valid = 0;
		else {
			repeats = selected - first;
			if (same > repeats || cross != repeats - same)
				valid = 0;
			remaining = repeats;
			for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_LE_64;
			     cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_GT_65536;
			     cid++) {
				uint64_t count = final_counter_block.counter[cid].value;

				if (count > remaining) {
					valid = 0;
					break;
				}
				remaining -= count;
			}
			if (remaining)
				valid = 0;
		}
		trace2_data_intmax("diff", NULL,
			"follow-full-tree/tree-read/requested-oid-sample/valid", valid);
		trace2_data_intmax("diff", NULL,
			"follow-full-tree/tree-read/requested-oid-sample/modulus",
			TRACE2_FOLLOW_OID_SAMPLE_MODULUS);
		trace2_data_intmax("diff", NULL,
			"follow-full-tree/tree-read/requested-oid-sample/distinct-cap",
			TRACE2_FOLLOW_OID_SAMPLE_MAX_DISTINCT);
		trace2_data_intmax("diff", NULL,
			"follow-full-tree/tree-read/requested-oid-sample/truncated",
			!!final_counter_block.counter[
				TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_TRUNCATED].value);
		for (cid = TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_COVERED;
		     valid && cid <= TRACE2_COUNTER_ID_DIFF_FOLLOW_OID_GAP_GT_65536;
		     cid++)
			trace2_data_intmax("diff", NULL,
				tr2_counter_metadata[cid].name,
				final_counter_block.counter[cid].value);
		if (valid)
			trace2_data_intmax("diff", NULL,
				"follow-full-tree/tree-read/requested-oid-sample/repeated-reads",
				repeats);
		errno = saved_errno;
	}

	/* Summarize only completed population calls; a missing kind is zero. */
	if (final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_COUNT].value ||
	    final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_COUNT].value ||
	    final_counter_block.counter[TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SUMMARY_INVALID].value) {
		uint64_t size_count = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_COUNT].value;
		uint64_t full_count = final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_COUNT].value;
		int saved_errno = errno;
		int valid = !final_counter_block.counter[
			TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SUMMARY_INVALID].value &&
			size_count <= INTMAX_MAX && full_count <= INTMAX_MAX;

		trace2_data_intmax("diff", NULL, "rename/populate/valid", valid);
		if (valid) {
			trace2_data_intmax("diff", NULL,
				"rename/populate/size-only-count", size_count);
			trace2_data_intmax("diff", NULL,
				"rename/populate/size-only-us",
				final_counter_block.counter[
					TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_SIZE_NS].value / 1000);
			trace2_data_intmax("diff", NULL,
				"rename/populate/full-count", full_count);
			trace2_data_intmax("diff", NULL,
				"rename/populate/full-us",
				final_counter_block.counter[
					TRACE2_COUNTER_ID_DIFF_RENAME_POPULATE_FULL_NS].value / 1000);
		}
		errno = saved_errno;
	}

	/* Include zero stages for completed updates and selected probes. */
	if (final_counter_block.counter[TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_CALLS].value)
		emit_counter_snapshot("cache_tree",
				      TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_CALLS,
				      TRACE2_COUNTER_ID_CACHE_TREE_UPDATE_REUSE_PACKED_INVALID);
	if (final_counter_block.counter[
		TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_LOOKUP_SELECTED_CHECKS].value)
		emit_counter_snapshot("cache_tree",
				      TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_LOOKUP_SELECTED_CHECKS,
				      TRACE2_COUNTER_ID_CACHE_TREE_VALIDATE_OID_ORDER_PACKED_INVALID);
	if (final_counter_block.counter[TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_LOOKUP_SELECTED_CHECKS].value)
		emit_counter_snapshot("ref-filter",
				      TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_LOOKUP_SELECTED_CHECKS,
				      TRACE2_COUNTER_ID_REF_FILTER_PRELOAD_PACKED_INVALID);
}

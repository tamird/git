#include "git-compat-util.h"
#include "trace2/tr2_tgt.h"
#include "trace2/tr2_tls.h"
#include "trace2/tr2_tmr.h"
#include "trace.h"

#define MY_MAX(a, b) ((a) > (b) ? (a) : (b))
#define MY_MIN(a, b) ((a) < (b) ? (a) : (b))

/*
 * A global timer block to aggregate values from the partial sums from
 * each thread.
 */
static struct tr2_timer_block final_timer_block; /* access under tr2tls_mutex */

/*
 * Define metadata for each stopwatch timer.
 *
 * This array must match "enum trace2_timer_id" and the values
 * in "struct tr2_timer_block.timer[*]".
 */
static struct tr2_timer_metadata tr2_timer_metadata[TRACE2_NUMBER_OF_TIMERS] = {
	[TRACE2_TIMER_ID_TEST1] = {
		.category = "test",
		.name = "test1",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_TEST2] = {
		.category = "test",
		.name = "test2",
		.want_per_thread_events = 1,
	},
	[TRACE2_TIMER_ID_DIFF_SETUP] = {
		.category = "diff",
		.name = "setup",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_DIFF_WRITEBACK] = {
		.category = "diff",
		.name = "write back to queue",
		.want_per_thread_events = 0,
	},
	/* Rebase and pick are inclusive; their phase timers overlap them. */
	[TRACE2_TIMER_ID_SEQUENCER_REBASE] = {
		.category = "sequencer",
		.name = "rebase",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_SEQUENCER_CHECKOUT] = {
		.category = "sequencer",
		.name = "checkout-onto",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_SEQUENCER_PICK] = {
		.category = "sequencer",
		.name = "pick",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_SEQUENCER_EMPTY_CHECK] = {
		.category = "sequencer",
		.name = "empty-check",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_SEQUENCER_COMMIT_OBJECT] = {
		.category = "sequencer",
		.name = "commit-object",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_SEQUENCER_UPDATE_HEAD] = {
		.category = "sequencer",
		.name = "update-head",
		.want_per_thread_events = 0,
	},
	/* Follow-parent and diffcore include their nested phase timers. */
	[TRACE2_TIMER_ID_DIFF_FOLLOW_PICKAXE_TREE_PATHS] = {
		.category = "diff",
		.name = "follow-pickaxe/tree-paths",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_DIFF_FOLLOW_PICKAXE_DIFFCORE] = {
		.category = "diff",
		.name = "follow-pickaxe/diffcore",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_LOG_GET_REVISION] = {
		.category = "log",
		.name = "get-revision",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_LOG_FOLLOW_PARENT] = {
		.category = "log",
		.name = "follow-parent",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_PICKAXE_FILTER] = {
		.category = "pickaxe",
		.name = "filter",
		.want_per_thread_events = 0,
	},
	/* Sorting includes sort-populate; format-output includes stdio. */
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_PREPARE] = {
		.category = "ref-filter",
		.name = "materialized/prepare",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_SORT] = {
		.category = "ref-filter",
		.name = "materialized/sort",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_SORT_POPULATE] = {
		.category = "ref-filter",
		.name = "materialized/sort-populate",
		.want_per_thread_events = 0,
	},
	/* These call timers are included in sort-populate. */
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_SORT_POPULATE_GRAPH_LOOKUP] = {
		.category = "ref-filter",
		.name = "materialized/sort-populate/graph-lookup",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_SORT_POPULATE_OBJECT_EXISTS] = {
		.category = "ref-filter",
		.name = "materialized/sort-populate/object-exists",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_SORT_POPULATE_OBJECT_INFO] = {
		.category = "ref-filter",
		.name = "materialized/sort-populate/object-info",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_FORMAT_OUTPUT] = {
		.category = "ref-filter",
		.name = "materialized/format-output",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_REF_FILTER_MATERIALIZED_CLEANUP] = {
		.category = "ref-filter",
		.name = "materialized/cleanup",
		.want_per_thread_events = 0,
	},
	/* Long/generic formatting includes object info, abbreviation, and stdio. */
	[TRACE2_TIMER_ID_LS_TREE_READ_TREE] = {
		.category = "ls-tree",
		.name = "read-tree",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_LS_TREE_FORMAT_OUTPUT] = {
		.category = "ls-tree",
		.name = "format-output",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_LS_TREE_OBJECT_INFO] = {
		.category = "ls-tree",
		.name = "format-output/object-info",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_LS_TREE_ABBREV] = {
		.category = "ls-tree",
		.name = "format-output/abbrev",
		.want_per_thread_events = 0,
	},
	/* Disjoint checkout-entry phases within unpack-trees queue_entries. */
	[TRACE2_TIMER_ID_UNPACK_TREES_PREPARE_ENTRY] = {
		.category = "unpack_trees",
		.name = "queue-entries/prepare-entry",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_UNPACK_TREES_ATTRS_AND_ENQUEUE] = {
		.category = "unpack_trees",
		.name = "queue-entries/attrs-and-enqueue",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_UNPACK_TREES_WRITE_ENTRY] = {
		.category = "unpack_trees",
		.name = "queue-entries/write-entry",
		.want_per_thread_events = 0,
	},
	/* Checkout item phases defer streaming content to the ODB timers. */
	[TRACE2_TIMER_ID_PCHECKOUT_ITEM_PREPARE] = {
		.category = "pcheckout",
		.name = "item/prepare",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_PCHECKOUT_ITEM_READ_BLOB] = {
		.category = "pcheckout",
		.name = "item/read-blob",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_PCHECKOUT_ITEM_CONVERT] = {
		.category = "pcheckout",
		.name = "item/convert",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_PCHECKOUT_ITEM_WRITE_BUFFER] = {
		.category = "pcheckout",
		.name = "item/write-buffer",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_PCHECKOUT_ITEM_FINALIZE] = {
		.category = "pcheckout",
		.name = "item/finalize",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_ODB_STREAM_TO_FD_OPEN] = {
		.category = "odb",
		.name = "stream-to-fd/open",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_ODB_STREAM_TO_FD_READ_FILTER] = {
		.category = "odb",
		.name = "stream-to-fd/read-filter",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_ODB_STREAM_TO_FD_WRITE] = {
		.category = "odb",
		.name = "stream-to-fd/write",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_ODB_STREAM_TO_FD_CLOSE] = {
		.category = "odb",
		.name = "stream-to-fd/close",
		.want_per_thread_events = 0,
	},
	/* Recovery preparation is included in the worktree-cache write timer. */
	[TRACE2_TIMER_ID_GREP_WORKTREE_CACHE_FINALIZE_IPC] = {
		.category = "grep",
		.name = "worktree-cache/finalize-ipc",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_WORKTREE_CACHE_WRITE] = {
		.category = "grep",
		.name = "worktree-cache/write",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_WORKTREE_CACHE_RECOVERY_PREPARE] = {
		.category = "grep",
		.name = "worktree-cache/recovery-prepare",
		.want_per_thread_events = 0,
	},
	/* These disjoint phases leave preparation preflight and cleanup unclassified. */
	[TRACE2_TIMER_ID_GREP_WORKTREE_CACHE_RECOVERY_COLLECT] = {
		.category = "grep",
		.name = "worktree-cache/recovery-collect",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_WORKTREE_CACHE_RECOVERY_SORT] = {
		.category = "grep",
		.name = "worktree-cache/recovery-sort",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_WORKTREE_CACHE_RECOVERY_SERIALIZE] = {
		.category = "grep",
		.name = "worktree-cache/recovery-serialize",
		.want_per_thread_events = 0,
	},
	/* Process includes reads and hashing; worker sums can exceed wall time. */
	[TRACE2_TIMER_ID_GREP_SOURCE_PROCESS] = {
		.category = "grep",
		.name = "source/process",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_SOURCE_FILE_READ] = {
		.category = "grep",
		.name = "source/file-read",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_SOURCE_FILE_HASH] = {
		.category = "grep",
		.name = "source/file-hash",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_SOURCE_OBJECT_READ] = {
		.category = "grep",
		.name = "source/object-read",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_PRODUCER_WAIT] = {
		.category = "grep",
		.name = "dispatch/producer-wait",
		.want_per_thread_events = 0,
	},
	[TRACE2_TIMER_ID_GREP_WORKER_DRAIN] = {
		.category = "grep",
		.name = "dispatch/worker-drain",
		.want_per_thread_events = 0,
	},

	/* Add additional metadata before here. */
};

void tr2_start_timer(enum trace2_timer_id tid)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	struct tr2_timer *t = &ctx->timer_block.timer[tid];

	t->recursion_count++;
	if (t->recursion_count > 1)
		return; /* ignore recursive starts */

	t->start_ns = getnanotime();
}

void tr2_stop_timer(enum trace2_timer_id tid)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	struct tr2_timer *t = &ctx->timer_block.timer[tid];
	uint64_t ns_now;
	uint64_t ns_interval;

	assert(t->recursion_count > 0);

	t->recursion_count--;
	if (t->recursion_count)
		return; /* still in recursive call(s) */

	ns_now = getnanotime();
	ns_interval = ns_now - t->start_ns;

	t->total_ns += ns_interval;

	/*
	 * min_ns was initialized to zero (in the xcalloc()) rather
	 * than UINT_MAX when the block of timers was allocated,
	 * so we should always set both the min_ns and max_ns values
	 * the first time that the timer is used.
	 */
	if (!t->interval_count) {
		t->min_ns = ns_interval;
		t->max_ns = ns_interval;
	} else {
		t->min_ns = MY_MIN(ns_interval, t->min_ns);
		t->max_ns = MY_MAX(ns_interval, t->max_ns);
	}

	t->interval_count++;

	ctx->used_any_timer = 1;
	if (tr2_timer_metadata[tid].want_per_thread_events)
		ctx->used_any_per_thread_timer = 1;
}

void tr2_update_final_timers(void)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	enum trace2_timer_id tid;

	if (!ctx->used_any_timer)
		return;

	/*
	 * Accessing `final_timer_block` requires holding `tr2tls_mutex`.
	 * We assume that our caller is holding the lock.
	 */

	for (tid = 0; tid < TRACE2_NUMBER_OF_TIMERS; tid++) {
		struct tr2_timer *t_final = &final_timer_block.timer[tid];
		struct tr2_timer *t = &ctx->timer_block.timer[tid];

		/*
		 * `t->recursion_count` could technically be non-zero, which
		 * would constitute a bug. Reporting the bug would potentially
		 * cause an infinite recursion, though, so let's ignore it.
		 */

		if (!t->interval_count)
			continue; /* this timer was not used by this thread */

		t_final->total_ns += t->total_ns;

		/*
		 * final_timer_block.timer[tid].min_ns was initialized to
		 * was initialized to zero rather than UINT_MAX, so we should
		 * always set both the min_ns and max_ns values the first time
		 * that we add a partial sum into it.
		 */
		if (!t_final->interval_count) {
			t_final->min_ns = t->min_ns;
			t_final->max_ns = t->max_ns;
		} else {
			t_final->min_ns = MY_MIN(t_final->min_ns, t->min_ns);
			t_final->max_ns = MY_MAX(t_final->max_ns, t->max_ns);
		}

		t_final->interval_count += t->interval_count;
	}
}

void tr2_emit_per_thread_timers(tr2_tgt_evt_timer_t *fn_apply)
{
	struct tr2tls_thread_ctx *ctx = tr2tls_get_self();
	enum trace2_timer_id tid;

	if (!ctx->used_any_per_thread_timer)
		return;

	/*
	 * For each timer, if the timer wants per-thread events and
	 * this thread used it, emit it.
	 */
	for (tid = 0; tid < TRACE2_NUMBER_OF_TIMERS; tid++)
		if (tr2_timer_metadata[tid].want_per_thread_events &&
		    ctx->timer_block.timer[tid].interval_count)
			fn_apply(&tr2_timer_metadata[tid],
				 &ctx->timer_block.timer[tid],
				 0);
}

void tr2_emit_final_timers(tr2_tgt_evt_timer_t *fn_apply)
{
	enum trace2_timer_id tid;

	/*
	 * Accessing `final_timer_block` requires holding `tr2tls_mutex`.
	 * We assume that our caller is holding the lock.
	 */

	for (tid = 0; tid < TRACE2_NUMBER_OF_TIMERS; tid++)
		if (final_timer_block.timer[tid].interval_count)
			fn_apply(&tr2_timer_metadata[tid],
				 &final_timer_block.timer[tid],
				 1);
}

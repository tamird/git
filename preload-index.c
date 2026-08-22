/*
 * Copyright (C) 2008 Linus Torvalds
 */

#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "pathspec.h"
#include "dir.h"
#include "environment.h"
#include "fsmonitor.h"
#include "gettext.h"
#include "json-writer.h"
#include "parse.h"
#include "preload-index.h"
#include "progress.h"
#include "read-cache.h"
#include "thread-utils.h"
#include "repository.h"
#include "symlinks.h"
#include "trace2.h"
#include "config.h"

/*
 * Mostly randomly chosen maximum thread counts: we
 * cap the parallelism to 20 threads, and we want
 * to have at least 500 lstat's per thread for it to
 * be worth starting a thread.
 */
#define MAX_PARALLEL (20)
#define THREAD_COST (500)

struct progress_data {
	unsigned long n;
	struct progress *progress;
	pthread_mutex_t mutex;
};

struct thread_data {
	pthread_t pthread;
	struct index_state *index;
	struct pathspec pathspec;
	struct progress_data *progress;
	int offset, nr;
	int t2_nr_lstat;
	int t2_enabled;
	int t2_nr_entries;
	int t2_nr_lstat_failures;
	int t2_nr_lstat_enoent;
	int t2_nr_stat_mismatch;
	int t2_elapsed_valid;
	uint64_t t2_elapsed_us;
};

static void *preload_thread(void *_data)
{
	int nr, last_nr;
	struct thread_data *p = _data;
	struct index_state *index = p->index;
	struct cache_entry **cep = index->cache + p->offset;
	struct cache_def cache = CACHE_DEF_INIT;
#if defined(HAVE_CLOCK_GETTIME) && defined(HAVE_CLOCK_MONOTONIC)
	struct timespec start, end;
	int timer_started = p->t2_enabled &&
		!clock_gettime(CLOCK_MONOTONIC, &start);
#endif

	nr = p->nr;
	if (nr + p->offset > index->cache_nr)
		nr = index->cache_nr - p->offset;
	last_nr = nr;
	p->t2_nr_entries = nr;

	do {
		struct cache_entry *ce = *cep++;
		struct stat st;

		if (ce_stage(ce))
			continue;
		if (S_ISGITLINK(ce->ce_mode))
			continue;
		if (ce_uptodate(ce))
			continue;
		if (ce_skip_worktree(ce))
			continue;
		if (ce->ce_flags & CE_FSMONITOR_VALID)
			continue;
		if (p->progress && !(nr & 31)) {
			struct progress_data *pd = p->progress;

			pthread_mutex_lock(&pd->mutex);
			pd->n += last_nr - nr;
			display_progress(pd->progress, pd->n);
			pthread_mutex_unlock(&pd->mutex);
			last_nr = nr;
		}
		if (!ce_path_match(index, ce, &p->pathspec, NULL))
			continue;
		if (threaded_has_symlink_leading_path(&cache, ce->name, ce_namelen(ce)))
			continue;
		p->t2_nr_lstat++;
		if (lstat(ce->name, &st)) {
			if (p->t2_enabled) {
				if (errno == ENOENT)
					p->t2_nr_lstat_enoent++;
				p->t2_nr_lstat_failures++;
			}
			continue;
		}
		if (ie_match_stat(index, ce, &st,
				  CE_MATCH_RACY_IS_DIRTY | CE_MATCH_IGNORE_FSMONITOR)) {
			if (p->t2_enabled)
				p->t2_nr_stat_mismatch++;
			continue;
		}
		ce_mark_uptodate(ce);
		mark_fsmonitor_valid(index, ce);
	} while (--nr > 0);
	if (p->progress) {
		struct progress_data *pd = p->progress;

		pthread_mutex_lock(&pd->mutex);
		display_progress(pd->progress, pd->n + last_nr);
		pthread_mutex_unlock(&pd->mutex);
	}
	cache_def_clear(&cache);
#if defined(HAVE_CLOCK_GETTIME) && defined(HAVE_CLOCK_MONOTONIC)
	if (timer_started && !clock_gettime(CLOCK_MONOTONIC, &end)) {
		uint64_t start_ns = (uint64_t)start.tv_sec * 1000000000 +
			start.tv_nsec;
		uint64_t end_ns = (uint64_t)end.tv_sec * 1000000000 +
			end.tv_nsec;

		if (end_ns >= start_ns) {
			p->t2_elapsed_us = (end_ns - start_ns) / 1000;
			p->t2_elapsed_valid = 1;
		}
	}
#endif
	return NULL;
}

static void trace_preload_workers(const struct thread_data *data, int threads)
{
	struct json_writer jw = JSON_WRITER_INIT;
	int i;

	jw_array_begin(&jw, 0);
	for (i = 0; i < threads; i++) {
		const struct thread_data *p = data + i;

		jw_array_inline_begin_object(&jw);
		jw_object_intmax(&jw, "entries", p->t2_nr_entries);
		jw_object_intmax(&jw, "lstat_attempts", p->t2_nr_lstat);
		jw_object_intmax(&jw, "lstat_enoent", p->t2_nr_lstat_enoent);
		jw_object_intmax(&jw, "lstat_other_error",
				p->t2_nr_lstat_failures - p->t2_nr_lstat_enoent);
		/* A policy stat match, not a content comparison. */
		jw_object_intmax(&jw, "stat_match",
				p->t2_nr_lstat - p->t2_nr_lstat_failures -
				p->t2_nr_stat_mismatch);
		jw_object_intmax(&jw, "stat_mismatch", p->t2_nr_stat_mismatch);
		if (p->t2_elapsed_valid)
			jw_object_intmax(&jw, "elapsed_us", p->t2_elapsed_us);
		else
			jw_object_null(&jw, "elapsed_us");
		jw_end(&jw);
	}
	jw_end(&jw);
	trace2_data_json("index", NULL, "preload/workers", &jw);
	jw_release(&jw);
}

void preload_index(struct index_state *index,
		   const struct pathspec *pathspec,
		   unsigned int refresh_flags)
{
	int threads, i, work, offset;
	struct thread_data data[MAX_PARALLEL];
	struct progress_data pd;
	int t2_sum_lstat = 0;
	int t2_enabled;
	int core_preload_index = 1;

	repo_config_get_bool(index->repo, "core.preloadindex", &core_preload_index);

	if (!HAVE_THREADS || !core_preload_index)
		return;

	threads = index->cache_nr / THREAD_COST;
	if ((index->cache_nr > 1) && (threads < 2) && git_env_bool("GIT_TEST_PRELOAD_INDEX", 0))
		threads = 2;
	if (threads < 2)
		return;

	t2_enabled = trace2_is_enabled();
	trace2_region_enter("index", "preload", NULL);

	trace_performance_enter();
	if (threads > MAX_PARALLEL)
		threads = MAX_PARALLEL;
	offset = 0;
	work = DIV_ROUND_UP(index->cache_nr, threads);
	memset(&data, 0, sizeof(data));

	memset(&pd, 0, sizeof(pd));
	if (refresh_flags & REFRESH_PROGRESS && isatty(2)) {
		pd.progress = start_delayed_progress(index->repo,
						     _("Refreshing index"),
						     index->cache_nr);
		pthread_mutex_init(&pd.mutex, NULL);
	}

	for (i = 0; i < threads; i++) {
		struct thread_data *p = data+i;
		int err;

		p->index = index;
		p->t2_enabled = t2_enabled;
		if (pathspec)
			copy_pathspec(&p->pathspec, pathspec);
		p->offset = offset;
		p->nr = work;
		if (pd.progress)
			p->progress = &pd;
		offset += work;
		err = pthread_create(&p->pthread, NULL, preload_thread, p);

		if (err)
			die(_("unable to create threaded lstat: %s"), strerror(err));
	}
	for (i = 0; i < threads; i++) {
		struct thread_data *p = data+i;
		if (pthread_join(p->pthread, NULL))
			die("unable to join threaded lstat");
		t2_sum_lstat += p->t2_nr_lstat;
	}
	stop_progress(&pd.progress);

	if (pathspec) {
		/* earlier we made deep copies for each thread to work with */
		for (i = 0; i < threads; i++)
			clear_pathspec(&data[i].pathspec);
	}

	trace_performance_leave("preload index");

	trace2_data_intmax("index", NULL, "preload/sum_lstat", t2_sum_lstat);
	trace2_region_leave("index", "preload", NULL);
	/* Keep worker data at the caller's Trace2 nesting depth. */
	if (t2_enabled)
		trace_preload_workers(data, threads);
}

int repo_read_index_preload(struct repository *repo,
			    const struct pathspec *pathspec,
			    unsigned int refresh_flags)
{
	int retval = repo_read_index(repo);

	preload_index(repo->index, pathspec, refresh_flags);
	return retval;
}

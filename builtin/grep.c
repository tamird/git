/*
 * Builtin "git grep"
 *
 * Copyright (c) 2006 Junio C Hamano
 */

#define USE_THE_REPOSITORY_VARIABLE
#define DISABLE_SIGN_COMPARE_WARNINGS

#include "builtin.h"
#include "abspath.h"
#include "environment.h"
#include "fsmonitor-settings.h"
#include "gettext.h"
#include "hex.h"
#include "config.h"
#include "tag.h"
#include "tree-walk.h"
#include "parse-options.h"
#include "string-list.h"
#include "run-command.h"
#include "grep.h"
#include "grep-index.h"
#include "grep-index-ipc.h"
#include "grep-worktree.h"
#include "quote.h"
#include "dir.h"
#include "pathspec.h"
#include "setup.h"
#include "submodule.h"
#include "submodule-config.h"
#include "object-file.h"
#include "object-name.h"
#include "odb.h"
#include "hashmap.h"
#include "oid-array.h"
#include "oidset.h"
#include "packfile.h"
#include "pager.h"
#include "path.h"
#include "promisor-remote.h"
#include "read-cache-ll.h"
#include "trace2.h"
#include "wrapper.h"
#include "write-or-die.h"

static const char *grep_prefix;

static char const * const grep_usage[] = {
	N_("git grep [<options>] [-e] <pattern> [<rev>...] [[--] <path>...]"),
	NULL
};

static int recurse_submodules;

enum worktree_blob_cache_mode {
	WORKTREE_BLOB_CACHE_AUTO,
	WORKTREE_BLOB_CACHE_ALWAYS,
	WORKTREE_BLOB_CACHE_NEVER,
};

static int num_threads;
static int threads_auto;
static int use_content_index = 1;
static struct grep_index *content_index;
static struct grep_index_prepared *content_index_prepared;
static struct grep_index_query *content_index_query;
static unsigned char *content_index_ipc_result;
static size_t content_index_ipc_nr;
static unsigned char *content_index_negative_result;
static size_t content_index_negative_nr;
static size_t content_index_negative_entries;
static struct object_id content_index_negative_identity;
static enum worktree_blob_cache_mode worktree_blob_cache_mode =
	WORKTREE_BLOB_CACHE_ALWAYS;
static struct grep_worktree_cache *worktree_cache;

static pthread_t *threads;
static int threads_started;
static pthread_t worker_lease_thread;
static int worker_lease_thread_started;
static int worker_lease_stop;
static int worker_thread_count;
static int worker_target;
static unsigned char *worker_busy;
static uint64_t worker_lease_id;
static struct grep_opt *worker_template;

#define GREP_RESULT_CACHE_MAX_ENTRIES (1U << 20)
#define GREP_MIN_FILES_FOR_THREADS 32
#define GREP_LITERAL_PATH_MAX_BYTES   (8 * 1024 * 1024)

struct grep_result_cache_entry {
	struct hashmap_entry ent;
	struct object_id oid;
	const char *gitdir;
	int binary;
};

static struct {
	struct hashmap map;
	size_t hits;
	/* Set before workers start and cleared after they join. */
	int initialized;
} grep_result_cache;

/* We use one producer thread and THREADS consumer
 * threads. The producer adds struct work_items to 'todo' and the
 * consumers pick work items from the same array.
 */
struct work_item {
	struct grep_source source;
	size_t worktree_blob_pos;
	char done;
	struct strbuf out;
};

struct grep_thread_data {
	struct grep_opt *opt;
	int id;
};

/* In the range [todo_done, todo_start) in 'todo' we have work_items
 * that have been or are processed by a consumer thread. We haven't
 * written the result for these to stdout yet.
 *
 * The work_items in [todo_start, todo_end) are waiting to be picked
 * up by a consumer thread.
 *
 * The ranges are modulo TODO_SIZE.
 */
#define TODO_SIZE 128
static struct work_item todo[TODO_SIZE];
static int todo_start;
static int todo_end;
static int todo_done;
static int status_only_hit;

/* Has all work items been added? */
static int all_work_added;

static struct repository **repos_to_free;
static size_t repos_to_free_nr, repos_to_free_alloc;

/* This lock protects all the variables above. */
static pthread_mutex_t grep_mutex;

static inline void grep_lock(void)
{
	pthread_mutex_lock(&grep_mutex);
}

static inline void grep_unlock(void)
{
	pthread_mutex_unlock(&grep_mutex);
}

/* Signalled when a new work_item is added to todo. */
static pthread_cond_t cond_add;

/* Signalled when the daemon changes the number of eligible workers. */
static pthread_cond_t cond_resize;

/* Signalled when the result from one work_item is written to
 * stdout.
 */
static pthread_cond_t cond_write;

/* Signalled when we are finished with everything. */
static pthread_cond_t cond_result;

static int skip_first_line;

static int grep_result_cache_cmp(const void *data UNUSED,
				 const struct hashmap_entry *eptr,
				 const struct hashmap_entry *entry_or_key,
				 const void *keydata UNUSED)
{
	const struct grep_result_cache_entry *a =
		container_of(eptr, const struct grep_result_cache_entry, ent);
	const struct grep_result_cache_entry *b =
		container_of(entry_or_key,
			     const struct grep_result_cache_entry, ent);

	return a->binary != b->binary ||
	       strcmp(a->gitdir, b->gitdir) ||
	       !oideq(&a->oid, &b->oid);
}

static void grep_result_cache_lock(void)
{
	if (threads_started)
		grep_lock();
}

static void grep_result_cache_unlock(void)
{
	if (threads_started)
		grep_unlock();
}

static void content_index_record_negative(struct grep_source *source,
					  size_t pos, int negative)
{
	unsigned char bit;

	/* File fallback bytes need not match the indexed object. */
	if (!content_index_negative_result || !negative || source->match_error ||
	    !grep_index_query_negative_is_cacheable(
		    content_index_query, source->buf, source->size) ||
	    (source->type != GREP_SOURCE_OID &&
	     (source->type != GREP_SOURCE_OID_OR_FILE ||
	      !source->worktree_blob_used)) ||
	    pos >= content_index_negative_nr)
		return;
	bit = 1u << (pos & 7);
	if (threads_started)
		grep_lock();
	if (!(content_index_negative_result[pos / 8] & bit)) {
		content_index_negative_result[pos / 8] |= bit;
		content_index_negative_entries++;
	}
	if (threads_started)
		grep_unlock();
}

static void grep_result_cache_key(struct grep_opt *opt,
				  struct grep_source *gs,
				  struct grep_result_cache_entry *key)
{
	const struct object_id *oid = gs->identifier;
	const char *gitdir = repo_get_git_dir(gs->repo);

	hashmap_entry_init(&key->ent, oidhash(oid) ^ strhash(gitdir));
	oidcpy(&key->oid, oid);
	key->gitdir = gitdir;
	if (opt->binary == GREP_BINARY_TEXT) {
		key->binary = 0;
	} else {
		grep_source_load_driver(gs, gs->repo->index);
		key->binary = gs->driver->binary;
	}
}

static int grep_result_cache_contains(struct grep_opt *opt,
				      struct grep_source *gs)
{
	struct grep_result_cache_entry key;
	struct grep_result_cache_entry *entry;

	if (!grep_result_cache.initialized)
		return 0;

	grep_result_cache_key(opt, gs, &key);
	grep_result_cache_lock();
	entry = hashmap_get_entry(&grep_result_cache.map, &key, ent, NULL);
	if (entry)
		grep_result_cache.hits++;
	grep_result_cache_unlock();
	return !!entry;
}

static void grep_result_cache_add(struct grep_opt *opt,
				  struct grep_source *gs)
{
	struct grep_result_cache_entry key;
	struct grep_result_cache_entry *entry;

	if (!grep_result_cache.initialized)
		return;

	grep_result_cache_key(opt, gs, &key);
	grep_result_cache_lock();
	entry = hashmap_get_entry(&grep_result_cache.map, &key, ent, NULL);
	if (!entry &&
	    hashmap_get_size(&grep_result_cache.map) <
		    GREP_RESULT_CACHE_MAX_ENTRIES) {
		CALLOC_ARRAY(entry, 1);
		hashmap_entry_init(&entry->ent, key.ent.hash);
		oidcpy(&entry->oid, &key.oid);
		entry->gitdir = key.gitdir;
		entry->binary = key.binary;
		hashmap_add(&grep_result_cache.map, &entry->ent);
	}
	grep_result_cache_unlock();
}

static int add_work(struct grep_opt *opt, struct grep_source *gs,
		    size_t worktree_blob_pos)
{
	if (opt->binary != GREP_BINARY_TEXT)
		grep_source_load_driver(gs, opt->repo->index);

	grep_lock();

	while (!status_only_hit &&
	       (todo_end + 1) % ARRAY_SIZE(todo) == todo_done)
		pthread_cond_wait(&cond_write, &grep_mutex);
	if (status_only_hit) {
		grep_unlock();
		grep_source_clear(gs);
		return 1;
	}

	todo[todo_end].source = *gs;
	todo[todo_end].worktree_blob_pos = worktree_blob_pos;
	todo[todo_end].done = 0;
	strbuf_reset(&todo[todo_end].out);
	todo_end = (todo_end + 1) % ARRAY_SIZE(todo);

	pthread_cond_signal(&cond_add);
	grep_unlock();
	return 0;
}

static struct work_item *get_work(int worker_id)
{
	struct work_item *ret;

	grep_lock();
	for (;;) {
		if (todo_start == todo_end && all_work_added)
			break;
		if (worker_id >= worker_target)
			pthread_cond_wait(&cond_resize, &grep_mutex);
		else if (todo_start == todo_end)
			pthread_cond_wait(&cond_add, &grep_mutex);
		else
			break;
	}

	if (todo_start == todo_end && all_work_added) {
		ret = NULL;
	} else {
		ret = &todo[todo_start];
		todo_start = (todo_start + 1) % ARRAY_SIZE(todo);
		worker_busy[worker_id] = 1;
	}
	grep_unlock();
	return ret;
}

static void work_done(struct work_item *w, int worker_id)
{
	int old_done;

	grep_lock();
	worker_busy[worker_id] = 0;
	w->done = 1;
	old_done = todo_done;
	for(; todo[todo_done].done && todo_done != todo_start;
	    todo_done = (todo_done+1) % ARRAY_SIZE(todo)) {
		w = &todo[todo_done];
		if (w->out.len) {
			const char *p = w->out.buf;
			size_t len = w->out.len;

			/* Skip the leading hunk mark of the first file. */
			if (skip_first_line) {
				while (len) {
					len--;
					if (*p++ == '\n')
						break;
				}
				skip_first_line = 0;
			}

			write_or_die(1, p, len);
		}
		if (w->source.worktree_blob_observed)
			grep_worktree_cache_record(
				worktree_cache, w->worktree_blob_pos,
				w->source.worktree_blob_match);
		if (w->source.worktree_blob_used)
			grep_worktree_cache_hit(worktree_cache);
		grep_source_clear(&w->source);
	}

	if (old_done != todo_done)
		pthread_cond_signal(&cond_write);

	if (all_work_added && todo_done == todo_end)
		pthread_cond_signal(&cond_result);

	grep_unlock();
}

static void free_repos(void)
{
	int i;

	for (i = 0; i < repos_to_free_nr; i++) {
		repo_clear(repos_to_free[i]);
		free(repos_to_free[i]);
	}
	FREE_AND_NULL(repos_to_free);
	repos_to_free_nr = 0;
	repos_to_free_alloc = 0;
}

static void *run(void *arg)
{
	struct grep_thread_data *thread = arg;
	int hit = 0;
	struct grep_opt *opt = thread->opt;
	int worker_id = thread->id;

	while (1) {
		struct work_item *w = get_work(worker_id);
		if (!w)
			break;

		opt->output_priv = w;
		if (grep_result_cache_contains(opt, &w->source)) {
			content_index_record_negative(
				&w->source, w->worktree_blob_pos, 1);
		} else {
			int source_hit = grep_source(opt, &w->source);

			content_index_record_negative(
				&w->source, w->worktree_blob_pos,
				!source_hit && w->source.buf);
			/*
			 * grep_source() also returns zero after a load
			 * failure. Only cache successfully loaded blobs.
			 */
			if (!source_hit && w->source.buf &&
			    !w->source.match_error)
				grep_result_cache_add(opt, &w->source);
			hit |= source_hit;
			if (source_hit && opt->status_only) {
				grep_lock();
				if (!status_only_hit) {
					int i;

					/*
					 * Retire pending items through work_done(),
					 * after earlier in-flight items finish.
					 */
					for (i = todo_start; i != todo_end;
					     i = (i + 1) % ARRAY_SIZE(todo))
						todo[i].done = 1;
					todo_start = todo_end;
					status_only_hit = 1;
				}
				pthread_cond_signal(&cond_write);
				grep_unlock();
			}
		}
		grep_source_clear_data(&w->source);
		work_done(w, worker_id);
	}
	free_grep_patterns(opt);
	free(opt);
	free(thread);

	return (void*) (intptr_t) hit;
}

static void strbuf_out(struct grep_opt *opt, const void *buf, size_t size)
{
	struct work_item *w = opt->output_priv;
	strbuf_add(&w->out, buf, size);
}

static int start_worker_thread(int id)
{
	struct grep_thread_data *thread;
	struct grep_opt *o = grep_opt_dup(worker_template);
	int err;

	CALLOC_ARRAY(thread, 1);
	thread->opt = o;
	thread->id = id;
	o->output = strbuf_out;
	compile_grep_patterns(o);
	err = pthread_create(&threads[id], NULL, run, thread);
	if (err) {
		free_grep_patterns(o);
		free(o);
		free(thread);
	}
	return err;
}

static void *renew_worker_lease(void *data UNUSED)
{
	trace2_thread_start("grep-lease");
	for (;;) {
		uint64_t lease_id;
		int held;
		int target;
		int err;

		for (int i = 0; i < 5; i++) {
			sleep_millisec(10);
			grep_lock();
			if (!worker_lease_stop) {
				grep_unlock();
				continue;
			}
			grep_unlock();
			goto done;
		}
		grep_lock();
		lease_id = worker_lease_id;
		target = held = worker_target;
		for (int i = worker_target; i < worker_thread_count; i++)
			if (worker_busy[i])
				held++;
		grep_unlock();

		if (lease_id)
			err = grep_index_ipc_update_workers(
				the_repository, lease_id, num_threads,
				held, &target);
		else
			err = grep_index_ipc_acquire_workers(
				the_repository, num_threads, held,
				&lease_id, &target);
		if (err == GREP_INDEX_IPC_WORKER_UPDATE_UNKNOWN) {
			worker_lease_id = 0;
			target = num_threads;
		} else if (err == GREP_INDEX_IPC_WORKER_UPDATE_NOT_SENT) {
			target = num_threads;
			grep_index_ipc_workers_are_available(the_repository);
		} else if (err < 0) {
			worker_lease_id = 0;
			target = num_threads;
		} else {
			worker_lease_id = lease_id;
		}
		if (target > num_threads)
			target = num_threads;
		while (worker_thread_count < target) {
			if (start_worker_thread(worker_thread_count))
				break;
			worker_thread_count++;
		}
		if (target > worker_thread_count)
			target = worker_thread_count;
		grep_lock();
		if (worker_target != target) {
			worker_target = target;
			pthread_cond_broadcast(&cond_add);
			pthread_cond_broadcast(&cond_resize);
			trace2_data_intmax(
				"grep", the_repository,
				"worker_lease/target", target);
		}
		grep_unlock();
	}
done:
	trace2_thread_exit();
	return NULL;
}

static void start_threads(struct grep_opt *opt)
{
	int initial_threads =
		!threads_auto || num_threads < 4 ? num_threads : 4;
	int i;

	worker_thread_count = num_threads;
	worker_target = num_threads;
	if (threads_auto && startup_info->have_repository &&
	    fsm_settings__get_mode(the_repository) == FSMONITOR_MODE_IPC &&
	    !grep_index_ipc_acquire_workers(
		    the_repository, initial_threads, 0, &worker_lease_id,
		    &worker_target)) {
		worker_thread_count = initial_threads;
		if (worker_target > worker_thread_count)
			worker_target = worker_thread_count;
	}
	worker_template = opt;

	if (!(opt->name_only || opt->unmatch_name_only || opt->count)
	    && (opt->pre_context || opt->post_context ||
		opt->file_break || opt->funcbody))
		skip_first_line = 1;

	if (recurse_submodules)
		repo_read_gitmodules(the_repository, 1);

	if (startup_info->have_repository) {
		struct odb_source *source;

		odb_prepare_alternates(the_repository->objects);
		for (source = the_repository->objects->sources; source;
		     source = source->next) {
			struct odb_source_files *files =
				odb_source_files_downcast(source);

			packfile_store_prepare(files->packed);
		}
	}

	pthread_mutex_init(&grep_mutex, NULL);
	pthread_mutex_init(&grep_attr_mutex, NULL);
	pthread_cond_init(&cond_add, NULL);
	pthread_cond_init(&cond_resize, NULL);
	pthread_cond_init(&cond_write, NULL);
	pthread_cond_init(&cond_result, NULL);
	grep_use_locks = 1;
	enable_obj_read_lock();
	status_only_hit = 0;
	threads_started = 1;
	worker_lease_stop = 0;

	for (i = 0; i < ARRAY_SIZE(todo); i++) {
		strbuf_init(&todo[i].out, 0);
	}

	CALLOC_ARRAY(threads, num_threads);
	CALLOC_ARRAY(worker_busy, num_threads);
	for (i = 0; i < worker_thread_count; i++) {
		int err = start_worker_thread(i);

		if (err) {
			if (worker_lease_id) {
				grep_index_ipc_release_workers(
					the_repository, worker_lease_id);
				worker_lease_id = 0;
			}
			die(_("grep: failed to create thread: %s"),
			    strerror(err));
		}
	}
	if (worker_lease_id) {
		int err = pthread_create(
			&worker_lease_thread, NULL, renew_worker_lease, NULL);

		if (err) {
			grep_index_ipc_release_workers(
				the_repository, worker_lease_id);
			worker_lease_id = 0;
			while (worker_thread_count < num_threads) {
				err = start_worker_thread(worker_thread_count);
				if (err)
					die(_("grep: failed to create thread: %s"),
					    strerror(err));
				worker_thread_count++;
			}
			grep_lock();
			worker_target = worker_thread_count;
			pthread_cond_broadcast(&cond_resize);
			grep_unlock();
		} else {
			worker_lease_thread_started = 1;
		}
	}
}

static int wait_all(void)
{
	int hit = 0;
	int i;

	if (!HAVE_THREADS)
		BUG("Never call this function unless you have started threads");

	grep_lock();
	all_work_added = 1;

	/* Wait until all work is done. */
	while (todo_done != todo_end)
		pthread_cond_wait(&cond_result, &grep_mutex);
	worker_lease_stop = 1;

	/* Wake up all the consumer threads so they can see that there
	 * is no more work to do.
	 */
	pthread_cond_broadcast(&cond_add);
	pthread_cond_broadcast(&cond_resize);
	grep_unlock();

	if (worker_lease_thread_started) {
		pthread_join(worker_lease_thread, NULL);
		worker_lease_thread_started = 0;
	}
	for (i = 0; i < worker_thread_count; i++) {
		void *h;
		pthread_join(threads[i], &h);
		hit |= (int) (intptr_t) h;
	}
	if (worker_lease_id) {
		grep_index_ipc_release_workers(
			the_repository, worker_lease_id);
		worker_lease_id = 0;
	}

	free(threads);
	FREE_AND_NULL(worker_busy);

	threads_started = 0;
	pthread_mutex_destroy(&grep_mutex);
	pthread_mutex_destroy(&grep_attr_mutex);
	pthread_cond_destroy(&cond_add);
	pthread_cond_destroy(&cond_resize);
	pthread_cond_destroy(&cond_write);
	pthread_cond_destroy(&cond_result);
	grep_use_locks = 0;
	disable_obj_read_lock();
	worker_thread_count = 0;
	worker_template = NULL;

	return hit;
}

static int grep_cmd_config(const char *var, const char *value,
			   const struct config_context *ctx, void *cb)
{
	int st = grep_config(var, value, ctx, cb);

	if (git_color_config(var, value, cb) < 0)
		st = -1;
	else if (git_default_config(var, value, ctx, cb) < 0)
		st = -1;

	if (!strcmp(var, "grep.threads")) {
		num_threads = git_config_int(var, value, ctx->kvi);
		if (num_threads < 0)
			die(_("invalid number of threads specified (%d) for %s"),
			    num_threads, var);
		else if (!HAVE_THREADS && num_threads > 1) {
			/*
			 * TRANSLATORS: %s is the configuration
			 * variable for tweaking threads, currently
			 * grep.threads
			 */
			warning(_("no threads support, ignoring %s"), var);
			num_threads = 1;
		}
	}

	if (!strcmp(var, "grep.worktreeblobcache")) {
		int value_bool;

		if (value && !strcasecmp(value, "auto")) {
			worktree_blob_cache_mode = WORKTREE_BLOB_CACHE_AUTO;
		} else if ((value_bool = git_parse_maybe_bool(value)) >= 0) {
			worktree_blob_cache_mode = value_bool ?
				WORKTREE_BLOB_CACHE_ALWAYS :
				WORKTREE_BLOB_CACHE_NEVER;
		} else {
			return error(_("invalid value for '%s': '%s'"),
				     var, value);
		}
	}

	if (!strcmp(var, "grep.usecontentindex"))
		use_content_index = git_config_bool(var, value);

	if (!strcmp(var, "submodule.recurse"))
		recurse_submodules = git_config_bool(var, value);

	return st;
}

static void grep_source_name(struct grep_opt *opt, const char *filename,
			     int tree_name_len, struct strbuf *out)
{
	strbuf_reset(out);

	if (opt->null_following_name) {
		if (opt->relative && grep_prefix) {
			struct strbuf rel_buf = STRBUF_INIT;
			const char *rel_name =
				relative_path(filename + tree_name_len,
					      grep_prefix, &rel_buf);

			if (tree_name_len)
				strbuf_add(out, filename, tree_name_len);

			strbuf_addstr(out, rel_name);
			strbuf_release(&rel_buf);
		} else {
			strbuf_addstr(out, filename);
		}
		return;
	}

	if (opt->relative && grep_prefix)
		quote_path(filename + tree_name_len, grep_prefix, out, 0);
	else
		quote_c_style(filename + tree_name_len, out, NULL, 0);

	if (tree_name_len)
		strbuf_insert(out, 0, filename, tree_name_len);
}

static int grep_oid(struct grep_opt *opt, const struct object_id *oid,
		    const char *filename, int tree_name_len,
		    const char *path, int fallback_to_file, size_t pos,
		    int content_index_checked)
{
	struct strbuf pathbuf = STRBUF_INIT;
	struct grep_source gs;

	if (!content_index_checked) {
		if (!content_index && content_index_query &&
		    opt->repo == the_repository) {
			content_index = grep_index_load(the_repository);
			if (!content_index) {
				grep_index_query_free(content_index_query);
				content_index_query = NULL;
			} else
				content_index_prepared = grep_index_prepare(
					content_index, content_index_query);
		}
		if (!(content_index_prepared ?
			      grep_index_prepared_maybe_contains(
				      content_index_prepared, opt->repo, oid) :
			      grep_index_maybe_contains(
				      content_index, opt->repo, oid,
				      content_index_query)))
			return 0;
	}
	if (num_threads > 1 && !threads_started)
		start_threads(opt);

	grep_source_name(opt, filename, tree_name_len, &pathbuf);
	grep_source_init_oid(&gs, pathbuf.buf, path, oid, opt->repo);
	if (fallback_to_file)
		gs.type = GREP_SOURCE_OID_OR_FILE;
	strbuf_release(&pathbuf);

	if (grep_result_cache_contains(opt, &gs)) {
		content_index_record_negative(&gs, pos, 1);
		grep_source_clear(&gs);
		return 0;
	}

	if (num_threads > 1) {
		/*
		 * add_work() consumes gs, so do not call
		 * grep_source_clear().
		 */
		return add_work(opt, &gs, pos);
	} else {
		int hit;

		hit = grep_source(opt, &gs);
		content_index_record_negative(&gs, pos, !hit && gs.buf);
		if (!hit && gs.buf && !gs.match_error)
			grep_result_cache_add(opt, &gs);
		if (gs.worktree_blob_used)
			grep_worktree_cache_hit(worktree_cache);

		grep_source_clear(&gs);
		return hit;
	}
}

static int grep_file(struct grep_opt *opt, const char *filename,
		     const struct cache_entry *ce, size_t pos)
{
	struct strbuf buf = STRBUF_INIT;
	struct grep_source gs;

	if (num_threads > 1 && !threads_started)
		start_threads(opt);
	grep_source_name(opt, filename, 0, &buf);
	grep_source_init_file(&gs, buf.buf, filename);
	if (ce) {
		gs.repo = opt->repo;
		oidcpy(&gs.worktree_blob_oid, &ce->oid);
		gs.worktree_blob_candidate = 1;
	}
	strbuf_release(&buf);

	if (num_threads > 1) {
		/*
		 * add_work() consumes gs, so do not call
		 * grep_source_clear().
		 */
		return add_work(opt, &gs, pos);
	} else {
		int hit;

		hit = grep_source(opt, &gs);
		if (gs.worktree_blob_observed)
			grep_worktree_cache_record(worktree_cache,
						   pos, gs.worktree_blob_match);

		grep_source_clear(&gs);
		return hit;
	}
}

static void append_path(struct grep_opt *opt, const void *data, size_t len)
{
	struct string_list *path_list = opt->output_priv;

	if (len == 1 && *(const char *)data == '\0')
		return;
	string_list_append_nodup(path_list, xstrndup(data, len));
}

static void run_pager(struct grep_opt *opt, const char *prefix)
{
	struct string_list *path_list = opt->output_priv;
	struct child_process child = CHILD_PROCESS_INIT;
	int i, status;

	for (i = 0; i < path_list->nr; i++)
		strvec_push(&child.args, path_list->items[i].string);
	child.dir = prefix;
	child.use_shell = 1;

	status = run_command(&child);
	if (status)
		exit(status);
}

static int grep_cache(struct grep_opt *opt,
		      const struct pathspec *pathspec, int cached);
static int grep_tree(struct grep_opt *opt, const struct pathspec *pathspec,
		     struct tree_desc *tree, struct strbuf *base, int tn_len,
		     int check_attr);

static int grep_submodule(struct grep_opt *opt,
			  const struct pathspec *pathspec,
			  const struct object_id *oid,
			  const char *filename, const char *path, int cached)
{
	struct repository *subrepo;
	struct repository *superproject = opt->repo;
	struct grep_opt subopt;
	int hit = 0;

	if (!is_submodule_active(superproject, path))
		return 0;

	subrepo = xmalloc(sizeof(*subrepo));
	if (repo_submodule_init(subrepo, superproject, path, null_oid(opt->repo->hash_algo))) {
		free(subrepo);
		return 0;
	}
	ALLOC_GROW(repos_to_free, repos_to_free_nr + 1, repos_to_free_alloc);
	repos_to_free[repos_to_free_nr++] = subrepo;

	/*
	 * NEEDSWORK: repo_read_gitmodules() might call
	 * odb_add_to_alternates_memory() via config_from_gitmodules(). This
	 * operation causes a race condition with concurrent object readings
	 * performed by the worker threads. That's why we need obj_read_lock()
	 * here. It should be removed once it's no longer necessary to add the
	 * subrepo's odbs to the in-memory alternates list.
	 */
	obj_read_lock();

	/*
	 * NEEDSWORK: when reading a submodule, the sparsity settings in the
	 * superproject are incorrectly forgotten or misused. For example:
	 *
	 * 1. "command_requires_full_index"
	 * 	When this setting is turned on for `grep`, only the superproject
	 *	knows it. All the submodules are read with their own configs
	 *	and get prepare_repo_settings()'d. Therefore, these submodules
	 *	"forget" the sparse-index feature switch. As a result, the index
	 *	of these submodules are expanded unexpectedly.
	 *
	 * 2. "config_values_private_.apply_sparse_checkout"
	 *	When running `grep` in the superproject, this setting is
	 *	populated using the superproject's configs. However, once
	 *	initialized, this config is globally accessible and is read by
	 *	prepare_repo_settings() for the submodules. For instance, if a
	 *	submodule is using a sparse-checkout, however, the superproject
	 *	is not, the result is that the config from the superproject will
	 *	dictate the behavior for the submodule, making it "forget" its
	 *	sparse-checkout state.
	 *
	 * 3. "core_sparse_checkout_cone"
	 *	ditto.
	 *
	 * Note that this list is not exhaustive.
	 */
	repo_read_gitmodules(subrepo, 0);

	/*
	 * All code paths tested by test code no longer need submodule ODBs to
	 * be added as alternates, but add it to the list just in case.
	 * Submodule ODBs added through add_submodule_odb_by_path() will be
	 * lazily registered as alternates when needed (and except in an
	 * unexpected code interaction, it won't be needed).
	 */
	odb_add_submodule_source_by_path(the_repository->objects,
					 subrepo->objects->sources->path);
	obj_read_unlock();

	memcpy(&subopt, opt, sizeof(subopt));
	subopt.repo = subrepo;

	if (oid) {
		enum object_type object_type;
		struct tree_desc tree;
		void *data;
		unsigned long size;
		struct strbuf base = STRBUF_INIT;

		obj_read_lock();
		object_type = odb_read_object_info(subrepo->objects, oid, NULL);
		obj_read_unlock();
		data = odb_read_object_peeled(subrepo->objects, oid, OBJ_TREE, &size, NULL);
		if (!data)
			die(_("unable to read tree (%s)"), oid_to_hex(oid));

		strbuf_addstr(&base, filename);
		strbuf_addch(&base, '/');

		init_tree_desc(&tree, oid, data, size);
		hit = grep_tree(&subopt, pathspec, &tree, &base, base.len,
				object_type == OBJ_COMMIT);
		strbuf_release(&base);
		free(data);
	} else {
		hit = grep_cache(&subopt, pathspec, cached);
	}

	return hit;
}

static int grep_cache_entry_uses_oid(struct repository *repo,
				     const struct pathspec *pathspec,
				     int cached, int literal_selected,
				     size_t pos)
{
	const struct cache_entry *ce = repo->index->cache[pos];
	int use_oid = cached || (ce->ce_flags & CE_VALID);

	if ((!cached && ce_skip_worktree(ce)) ||
	    !S_ISREG(ce->ce_mode) || ce_stage(ce) ||
	    ce_intent_to_add(ce) ||
	    (!literal_selected &&
	     !match_pathspec(repo->index, pathspec, ce->name,
			     ce_namelen(ce), 0, NULL, 0)))
		return 0;
	if (use_oid || !worktree_cache ||
	    !grep_worktree_cache_entry_eligible(ce))
		return use_oid;
	if (threads_started)
		grep_lock();
	use_oid = grep_worktree_cache_lookup(worktree_cache, pos) ==
		  GREP_WORKTREE_CACHE_EQUAL;
	if (threads_started)
		grep_unlock();
	return use_oid;
}

static int grep_cache(struct grep_opt *opt,
		      const struct pathspec *pathspec, int cached)
{
	struct repository *repo = opt->repo;
	int hit = 0;
	int nr;
	int *selected = NULL;
	size_t selected_nr = 0;
	size_t selected_alloc = 0;
	size_t selected_pos = 0;
	int use_selected = 0;
	int literal_selected = 0;
	int skip_cache_setup = 0;
	int used_index_ipc = 0;
	int worktree_sidecar_loaded = 0;
	const char *recursive_basename = NULL;
	size_t recursive_basename_len = 0;
	struct strbuf name = STRBUF_INIT;
	int name_base_len = 0;
	if (repo->submodule_prefix) {
		name_base_len = strlen(repo->submodule_prefix);
		strbuf_addstr(&name, repo->submodule_prefix);
	}

	repo->index->lazy_cache_tree = 1;
	if (repo_read_index(repo) < 0)
		die(_("index file corrupt"));
	if (pathspec->nr == 1) {
		const struct pathspec_item *item = &pathspec->items[0];
		const char *basename;

		if (!item->magic && !item->prefix &&
		    pathspec_item_get_recursive_basename(item, &basename)) {
			recursive_basename = basename;
			recursive_basename_len = strlen(basename);
		}
	}
	/*
	 * Whole-index pathspec walks cost more than resolving explicitly named
	 * worktree files directly.
	 */
	if (git_env_bool("GIT_TEST_GREP_LITERAL_PATHS", 1) && !cached &&
	    !recurse_submodules && !opt->allow_textconv && pathspec->nr &&
	    (recursive_basename ||
	     (!pathspec->has_wildcard &&
	      !(pathspec->magic & ~(PATHSPEC_FROMTOP | PATHSPEC_LITERAL))))) {
		struct strbuf dir = STRBUF_INIT;
		size_t selected_map_size =
			DIV_ROUND_UP(repo->index->cache_nr, 8);
		unsigned char *selected_map;
		int can_select = 1;

		CALLOC_ARRAY(selected_map, selected_map_size);
		for (size_t i = 0; i < pathspec->nr; i++) {
			const struct pathspec_item *item = &pathspec->items[i];
			const struct cache_entry *previous;
			int end;
			int dir_pos;

			if (!recursive_basename &&
			    (!item->len || item->match[item->len - 1] == '/' ||
			     item->nowildcard_len != item->len ||
			     item->magic &
				     ~(PATHSPEC_FROMTOP | PATHSPEC_LITERAL))) {
				can_select = 0;
				break;
			}

			if (recursive_basename) {
				nr = 0;
				end = repo->index->cache_nr;
			} else {
				nr = index_name_pos_sparse(repo->index, item->match,
							   item->len);
			}
			if (!recursive_basename && nr < 0) {
				nr = -nr - 1;
				if (nr < repo->index->cache_nr &&
				    !strcmp(repo->index->cache[nr]->name,
					    item->match)) {
					can_select = 0;
					break;
				}
				strbuf_reset(&dir);
				strbuf_add(&dir, item->match, item->len);
				strbuf_addch(&dir, '/');
				dir_pos = index_name_pos_sparse(
					repo->index, dir.buf, dir.len);
				if (dir_pos < 0)
					dir_pos = -dir_pos - 1;
				if (dir_pos < repo->index->cache_nr &&
				    starts_with(repo->index->cache[dir_pos]
							->name,
						dir.buf)) {
					int low = dir_pos;

					end = repo->index->cache_nr;
					while (low < end) {
						int mid = low + (end - low) / 2;

						if (starts_with(repo->index
									->cache[mid]
									->name,
								dir.buf))
							low = mid + 1;
						else
							end = mid;
					}
					nr = dir_pos;
					end = low;
				} else {
					previous =
						nr ? repo->index
								->cache[nr - 1] :
						     NULL;
					if (previous &&
					    S_ISSPARSEDIR(
						    previous->ce_mode) &&
					    ce_namelen(previous) <
						    item->len &&
					    !strncmp(previous->name,
						     item->match,
						     ce_namelen(
							     previous))) {
						can_select = 0;
						break;
					}
					continue;
				}
			} else if (!recursive_basename) {
				end = nr + 1;
			}

			for (; nr < end; nr++) {
				const struct cache_entry *ce =
					repo->index->cache[nr];
				size_t name_len = ce_namelen(ce);
				unsigned char bit = 1u << (nr & 7);

				if (recursive_basename &&
				    (name_len <= recursive_basename_len ||
				     ce->name[name_len - recursive_basename_len - 1] != '/' ||
				     memcmp(ce->name + name_len - recursive_basename_len,
					    recursive_basename,
					    recursive_basename_len)))
					continue;

				if (ce_stage(ce)) {
					can_select = 0;
					break;
				}
				if (ce_skip_worktree(ce))
					continue;
				if (S_ISSPARSEDIR(ce->ce_mode) ||
				    (ce->ce_flags & CE_VALID)) {
					can_select = 0;
					break;
				}
				if (!S_ISREG(ce->ce_mode))
					continue;

				if (selected_map[nr / 8] & bit)
					continue;
				selected_map[nr / 8] |= bit;
				selected_nr++;
			}
			if (!can_select)
				break;
		}
		if (can_select) {
			selected_alloc = selected_nr;
			ALLOC_ARRAY(selected, selected_alloc);
			selected_nr = 0;
			for (nr = 0; nr < repo->index->cache_nr; nr++)
				if (selected_map[nr / 8] &
				    (1u << (nr & 7)))
					selected[selected_nr++] = nr;
			use_selected = 1;
			literal_selected = 1;
			trace2_data_intmax("grep", repo,
					   recursive_basename ?
						   "recursive_basename_path_candidates" :
						   "literal_path_candidates",
					   selected_nr);
			if (selected_nr < GREP_MIN_FILES_FOR_THREADS) {
				uint64_t selected_bytes = 0;

				skip_cache_setup = 1;
				for (size_t i = 0; i < selected_nr; i++) {
					const struct cache_entry *ce =
						repo->index
							->cache[selected[i]];
					struct stat st;

					if (lstat(ce->name, &st) ||
					    !S_ISREG(st.st_mode) ||
					    (uintmax_t)st.st_size >
						    GREP_LITERAL_PATH_MAX_BYTES -
							    selected_bytes) {
						skip_cache_setup = 0;
						break;
					}
					selected_bytes += st.st_size;
				}
				if (skip_cache_setup && num_threads > 1 &&
				    threads_auto)
					num_threads = 1;
			}
		} else {
			FREE_AND_NULL(selected);
			selected_nr = 0;
			selected_alloc = 0;
		}
		free(selected_map);
		strbuf_release(&dir);
	}
	if (!skip_cache_setup && repo == the_repository && !cached &&
	    !opt->allow_textconv &&
	    worktree_blob_cache_mode != WORKTREE_BLOB_CACHE_NEVER &&
	    (worktree_blob_cache_mode == WORKTREE_BLOB_CACHE_ALWAYS ||
	     !opt->status_only)) {
		uint64_t min_bytes = worktree_blob_cache_mode ==
					     WORKTREE_BLOB_CACHE_ALWAYS ?
					     0 :
						     git_env_ulong(
							     "GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES",
							     GREP_WORKTREE_CACHE_MIN_BYTES);
		uint64_t worktree_bytes = 0;
		size_t pos;

		if (!literal_selected)
			use_selected = min_bytes && !recurse_submodules;
		for (pos = 0;
		     min_bytes &&
		     pos < (literal_selected ? selected_nr :
					       repo->index->cache_nr);
		     pos++) {
			const struct cache_entry *ce;

			nr = literal_selected ? selected[pos] : pos;
			ce = repo->index->cache[nr];
			if (!literal_selected &&
			    (ce_skip_worktree(ce) ||
			     !S_ISREG(ce->ce_mode) ||
			     !match_pathspec(repo->index, pathspec, ce->name,
					     ce_namelen(ce), 0, NULL, 0)))
				continue;
			if (!literal_selected && use_selected) {
				ALLOC_GROW(selected, selected_nr + 1,
					   selected_alloc);
				selected[selected_nr++] = nr;
			}
			if (grep_worktree_cache_entry_eligible(ce)) {
				if (UINT64_MAX - worktree_bytes <
				    ce->ce_stat_data.sd_size)
					worktree_bytes = UINT64_MAX;
				else
					worktree_bytes +=
						ce->ce_stat_data.sd_size;
			}
			if (!literal_selected && ce_stage(ce))
				while (nr + 1 < repo->index->cache_nr &&
				       !strcmp(ce->name,
					       repo->index->cache[nr + 1]->name))
					nr++;
		}
		if (worktree_bytes >= min_bytes)
			worktree_cache = grep_worktree_cache_load(
				repo, repo->index, &worktree_sidecar_loaded);
		if (worktree_cache && worktree_sidecar_loaded &&
		    worktree_blob_cache_mode == WORKTREE_BLOB_CACHE_ALWAYS &&
		    fsm_settings__get_mode(repo) == FSMONITOR_MODE_IPC) {
			size_t limit = literal_selected ? selected_nr :
							  repo->index->cache_nr;
			uint64_t refresh_min_bytes = git_env_ulong(
				"GIT_TEST_GREP_WORKTREE_CACHE_MIN_BYTES",
				GREP_WORKTREE_CACHE_MIN_BYTES);
			uint64_t refresh_bytes = 0;

			for (pos = 0; pos < limit; pos++) {
				const struct cache_entry *ce;

				nr = literal_selected ? selected[pos] : pos;
				ce = repo->index->cache[nr];
				if (!grep_worktree_cache_entry_refreshable(ce) ||
				    ce->ce_flags & CE_FSMONITOR_VALID ||
				    (!literal_selected &&
				     !match_pathspec(repo->index, pathspec, ce->name,
						     ce_namelen(ce), 0, NULL, 0)))
					continue;
				if (UINT64_MAX - refresh_bytes <
				    ce->ce_stat_data.sd_size)
					refresh_bytes = UINT64_MAX;
				else
					refresh_bytes += ce->ce_stat_data.sd_size;
				if (refresh_bytes >= refresh_min_bytes)
					break;
			}
			if (refresh_bytes >= refresh_min_bytes)
				refresh_index(repo->index,
					      REFRESH_QUIET | REFRESH_UNMERGED |
						      REFRESH_IGNORE_SUBMODULES |
						      REFRESH_IGNORE_SKIP_WORKTREE,
					      pathspec, NULL, NULL);
		}
	}
	if (!skip_cache_setup && (!use_selected || literal_selected) &&
	    repo == the_repository &&
	    content_index_query &&
	    !recurse_submodules &&
	    fsm_settings__get_mode(repo) == FSMONITOR_MODE_IPC &&
	    grep_index_ipc_is_available(repo)) {
		size_t bitmap_size =
			repo->index->cache_nr / 8 +
			!!(repo->index->cache_nr % 8);
		unsigned char *maybe;
		unsigned char *unresolved;
		int negative_cache_supported;

		CALLOC_ARRAY(maybe, bitmap_size);
		CALLOC_ARRAY(unresolved, bitmap_size);
		if (!grep_index_ipc_query_index(
			    repo, content_index_query, maybe, unresolved,
			    repo->index->cache_nr,
			    &content_index_negative_identity,
			    &negative_cache_supported)) {
			int have_unresolved = 0;

			used_index_ipc = 1;
			if (negative_cache_supported) {
				content_index_negative_nr =
					repo->index->cache_nr;
				CALLOC_ARRAY(content_index_negative_result,
					     bitmap_size);
			}
			for (size_t i = 0; i < bitmap_size; i++)
				if (unresolved[i]) {
					have_unresolved = 1;
					break;
				}
			if (have_unresolved) {
				struct object_id *oids = NULL;
				size_t *positions = NULL;
				unsigned char *results = NULL;
				size_t nr_oids = 0;
				size_t oids_alloc = 0;
				size_t positions_alloc = 0;
				size_t limit = literal_selected ? selected_nr :
								  repo->index->cache_nr;

				for (size_t pos = 0; pos < limit; pos++) {
					size_t i = literal_selected ? selected[pos] : pos;
					const struct cache_entry *ce =
						repo->index->cache[i];

					if (!(unresolved[i / 8] &
					      (1u << (i & 7))) ||
					    !grep_cache_entry_uses_oid(
						    repo, pathspec, cached,
						    literal_selected, i))
						continue;
					ALLOC_GROW(oids, nr_oids + 1, oids_alloc);
					ALLOC_GROW(positions, nr_oids + 1,
						   positions_alloc);
					oidcpy(&oids[nr_oids], &ce->oid);
					positions[nr_oids++] = i;
				}
				if (nr_oids) {
					ALLOC_ARRAY(results, nr_oids);
					if (!grep_index_ipc_query(
						    repo, content_index_query, oids,
						    nr_oids, results)) {
						uint64_t rejected = 0;

						for (size_t i = 0; i < nr_oids; i++) {
							size_t index_pos = positions[i];
							unsigned char bit =
								1u << (index_pos & 7);

							if (results[i] !=
							    GREP_INDEX_IPC_IMPOSSIBLE)
								continue;
							maybe[index_pos / 8] &= ~bit;
							if (content_index_negative_result &&
							    !(content_index_negative_result
								      [index_pos / 8] &
							      bit)) {
								content_index_negative_result
									[index_pos / 8] |= bit;
								content_index_negative_entries++;
							}
							rejected++;
						}
						trace2_data_intmax(
							"grep", repo,
							"content_index_overlay_objects",
							nr_oids);
						trace2_data_intmax(
							"grep", repo,
							"content_index_overlay_rejected",
							rejected);
					}
				}
				free(results);
				free(positions);
				free(oids);
			}
			if (cached &&
			    repo->index->sparse_index == INDEX_EXPANDED) {
				for (size_t i = 0;
				     i < repo->index->cache_nr; i++) {
					const struct cache_entry *ce =
						repo->index->cache[i];

					if (!(maybe[i / 8] &
					      (1u << (i & 7))) ||
					    !S_ISREG(ce->ce_mode) ||
					    ce_stage(ce) ||
					    ce_intent_to_add(ce) ||
					    !match_pathspec(
						    repo->index,
						    pathspec, ce->name,
						    ce_namelen(ce), 0,
						    NULL, 0))
						continue;
					ALLOC_GROW(
						selected,
						selected_nr + 1,
						selected_alloc);
					selected[selected_nr++] = i;
				}
				use_selected = 1;
				trace2_data_intmax(
					"grep", repo,
					"content_index_ipc_candidates",
					selected_nr);
				if (selected_nr &&
				    selected_nr <
					    GREP_MIN_FILES_FOR_THREADS &&
				    num_threads > 1 && threads_auto)
					num_threads = 1;
			} else if (!cached && worktree_cache &&
				   (!literal_selected ||
				    worktree_sidecar_loaded) &&
				   (literal_selected ||
				    repo->index->sparse_index ==
					    INDEX_EXPANDED)) {
				size_t positions_nr =
					literal_selected ?
						selected_nr :
						repo->index->cache_nr;
				uint64_t rejected = 0;

				if (literal_selected) {
					/*
					 * Literal positions are already ordered
					 * and pathspec-filtered. Compacting in
					 * place is safe because the write
					 * position cannot overtake the read
					 * position.
					 */
					selected_nr = 0;
				}
				for (size_t pos = 0; pos < positions_nr; pos++) {
					size_t i = literal_selected ?
							   selected[pos] :
							   pos;
					const struct cache_entry *ce =
						repo->index->cache[i];
					unsigned char bit =
						1u << (i & 7);
					int known_equal =
						!ce_stage(ce) &&
						!ce_intent_to_add(ce) &&
						(ce->ce_flags & CE_VALID);

					if (!literal_selected &&
					    (ce_skip_worktree(ce) ||
					     !S_ISREG(ce->ce_mode)))
						continue;
					if (!known_equal &&
					    grep_worktree_cache_entry_eligible(ce))
						known_equal =
							grep_worktree_cache_lookup(
								worktree_cache,
								i) ==
							GREP_WORKTREE_CACHE_EQUAL;
					/*
					 * A negative blob result excludes a
					 * worktree path only when its bytes
					 * match the indexed blob.
					 */
					if (known_equal &&
					    !(maybe[i / 8] & bit)) {
						rejected++;
						continue;
					}
					if (!literal_selected &&
					    !match_pathspec(
						    repo->index, pathspec,
						    ce->name,
						    ce_namelen(ce), 0,
						    NULL, 0))
						continue;
					ALLOC_GROW(
						selected,
						selected_nr + 1,
						selected_alloc);
					selected[selected_nr++] = i;
				}
				use_selected = 1;
				if (literal_selected) {
					trace2_data_intmax(
						"grep", repo,
						"content_index_literal_path_candidates",
						selected_nr);
					trace2_data_intmax(
						"grep", repo,
						"content_index_literal_path_rejected",
						rejected);
				} else {
					trace2_data_intmax(
						"grep", repo,
						"content_index_worktree_candidates",
						selected_nr);
					trace2_data_intmax(
						"grep", repo,
						"content_index_worktree_rejected_before_pathspec",
						rejected);
				}
				if (selected_nr &&
				    selected_nr <
					    GREP_MIN_FILES_FOR_THREADS &&
				    num_threads > 1 && threads_auto)
					num_threads = 1;
			} else {
				content_index_ipc_nr =
					repo->index->cache_nr;
				ALLOC_ARRAY(content_index_ipc_result,
					    content_index_ipc_nr);
				for (size_t i = 0;
				     i < content_index_ipc_nr; i++)
					content_index_ipc_result[i] =
						maybe[i / 8] &
								(1u <<
								 (i & 7)) ?
							GREP_INDEX_IPC_MAYBE :
							GREP_INDEX_IPC_IMPOSSIBLE;
			}
		}
		free(unresolved);
		free(maybe);
	}
	if (!skip_cache_setup && (!use_selected || literal_selected) &&
	    repo == the_repository &&
	    content_index_query &&
	    !used_index_ipc && !content_index) {
		trace2_region_enter("grep", "load_content_index", repo);
		content_index = grep_index_load(repo);
		trace2_region_leave("grep", "load_content_index", repo);
		trace2_region_enter("grep", "prepare_content_index", repo);
		if (content_index)
			content_index_prepared = grep_index_prepare(
				content_index, content_index_query);
		trace2_region_leave("grep", "prepare_content_index", repo);
	}
	if (!use_selected && cached && !recurse_submodules &&
	    content_index_prepared &&
	    repo->index->sparse_index == INDEX_EXPANDED) {
		trace2_region_enter("grep", "select_content_index", repo);
		for (size_t i = 0; i < repo->index->cache_nr; i++) {
			const struct cache_entry *ce = repo->index->cache[i];

			if (!S_ISREG(ce->ce_mode) || ce_stage(ce) ||
			    ce_intent_to_add(ce) ||
			    !match_pathspec(repo->index, pathspec, ce->name,
					    ce_namelen(ce), 0, NULL, 0))
				continue;
			if (!grep_index_prepared_maybe_contains(
				    content_index_prepared, repo, &ce->oid))
				continue;
			ALLOC_GROW(selected, selected_nr + 1,
				   selected_alloc);
			selected[selected_nr++] = i;
		}
		use_selected = 1;
		trace2_data_intmax("grep", repo,
				   "content_index_candidates", selected_nr);
		if (selected_nr &&
		    selected_nr < GREP_MIN_FILES_FOR_THREADS &&
		    num_threads > 1 && threads_auto)
			num_threads = 1;
		trace2_region_leave("grep", "select_content_index", repo);
	}
	if (!skip_cache_setup && (!use_selected || literal_selected) &&
	    repo == the_repository && content_index_query &&
	    !used_index_ipc && !content_index_prepared &&
	    !recurse_submodules &&
	    fsm_settings__get_mode(repo) == FSMONITOR_MODE_IPC &&
	    grep_index_ipc_is_available(repo)) {
		struct object_id *oids = NULL;
		size_t *positions = NULL;
		unsigned char *maybe = NULL;
		size_t nr_oids = 0;
		size_t oids_alloc = 0;
		size_t positions_alloc = 0;

		size_t limit = literal_selected ? selected_nr :
						  repo->index->cache_nr;

		for (size_t pos = 0; pos < limit; pos++) {
			size_t i = literal_selected ? selected[pos] : pos;
			const struct cache_entry *ce = repo->index->cache[i];

			if (!grep_cache_entry_uses_oid(
				    repo, pathspec, cached, literal_selected, i))
				continue;
			ALLOC_GROW(oids, nr_oids + 1, oids_alloc);
			ALLOC_GROW(positions, nr_oids + 1,
				   positions_alloc);
			oidcpy(&oids[nr_oids], &ce->oid);
			positions[nr_oids++] = i;
		}
		if (nr_oids) {
			ALLOC_ARRAY(maybe, nr_oids);
			content_index_ipc_nr = repo->index->cache_nr;
			CALLOC_ARRAY(content_index_ipc_result,
				     content_index_ipc_nr);
			if (!grep_index_ipc_query(
				    repo, content_index_query, oids,
				    nr_oids, maybe)) {
				for (size_t i = 0; i < nr_oids; i++) {
					content_index_ipc_result[positions[i]] =
						maybe[i];
					if (cached &&
					    repo->index->sparse_index ==
						    INDEX_EXPANDED &&
					    maybe[i] !=
						    GREP_INDEX_IPC_IMPOSSIBLE) {
						ALLOC_GROW(
							selected,
							selected_nr + 1,
							selected_alloc);
						selected[selected_nr++] =
							positions[i];
					}
				}
				if (cached &&
				    repo->index->sparse_index ==
					    INDEX_EXPANDED) {
					use_selected = 1;
					trace2_data_intmax(
						"grep", repo,
						"content_index_ipc_candidates",
						selected_nr);
					if (selected_nr &&
					    selected_nr <
						    GREP_MIN_FILES_FOR_THREADS &&
					    num_threads > 1 &&
					    threads_auto)
						num_threads = 1;
				}
			} else {
				FREE_AND_NULL(content_index_ipc_result);
				content_index_ipc_nr = 0;
			}
		}
		free(maybe);
		free(positions);
		free(oids);
	}

	for (nr = 0;
	     use_selected ? selected_pos < selected_nr :
			    nr < repo->index->cache_nr;
	     use_selected ? selected_pos++ : nr++) {
		const struct cache_entry *ce;

		if (use_selected)
			nr = selected[selected_pos];
		ce = repo->index->cache[nr];

		if (!use_selected && !cached && ce_skip_worktree(ce))
			continue;

		strbuf_setlen(&name, name_base_len);
		strbuf_addstr(&name, ce->name);
		if (S_ISSPARSEDIR(ce->ce_mode)) {
			enum object_type type;
			struct tree_desc tree;
			void *data;
			unsigned long size;

			data = odb_read_object(the_repository->objects, &ce->oid,
					       &type, &size);
			if (!data)
				die(_("unable to read tree %s"), oid_to_hex(&ce->oid));
			init_tree_desc(&tree, &ce->oid, data, size);

			hit |= grep_tree(opt, pathspec, &tree, &name, 0, 0);
			strbuf_setlen(&name, name_base_len);
			strbuf_addstr(&name, ce->name);
			free(data);
			/*
			 * Every producer of selected[] applies the pathspec while
			 * constructing it.
			 */
		} else if (S_ISREG(ce->ce_mode) &&
			   (use_selected ||
			    match_pathspec(repo->index, pathspec, name.buf,
					   name.len, 0, NULL,
					   S_ISDIR(ce->ce_mode) ||
						   S_ISGITLINK(
							   ce->ce_mode)))) {
			enum grep_worktree_cache_result cache_result =
				GREP_WORKTREE_CACHE_UNKNOWN;
			const struct cache_entry *cache_candidate = NULL;
			int can_cache =
				repo == the_repository && !cached &&
				!opt->allow_textconv &&
				grep_worktree_cache_entry_eligible(ce) &&
				worktree_cache;
			int use_worktree_blob;

			if (can_cache && threads_started)
				grep_lock();
			if (can_cache)
				cache_result = grep_worktree_cache_lookup(
					worktree_cache, nr);
			if (can_cache && threads_started)
				grep_unlock();
			use_worktree_blob =
				cache_result == GREP_WORKTREE_CACHE_EQUAL;
			if (cache_result == GREP_WORKTREE_CACHE_UNKNOWN)
				cache_candidate = ce;

			/*
			 * If CE_VALID is on, we assume worktree file and its
			 * cache entry are identical, even if worktree file has
			 * been modified, so use cache version instead. We can
			 * also use it when a previous scan observed identical
			 * worktree and blob bytes and fsmonitor reports no
			 * subsequent change.
			 */
			if (cached || (ce->ce_flags & CE_VALID) ||
			    use_worktree_blob) {
				if (ce_stage(ce) || ce_intent_to_add(ce))
					continue;
				if (content_index_ipc_result &&
				    nr < content_index_ipc_nr &&
				    content_index_ipc_result[nr] == 1)
					continue;
				hit |= grep_oid(opt, &ce->oid, name.buf,
						0, name.buf, use_worktree_blob, nr,
						used_index_ipc ||
							(content_index_ipc_result &&
							 nr <
								 content_index_ipc_nr &&
							 content_index_ipc_result
								 [nr]));
			} else {
				hit |= grep_file(opt, name.buf,
						 can_cache ? cache_candidate : NULL,
						 nr);
			}
		} else if (recurse_submodules && S_ISGITLINK(ce->ce_mode) &&
			   submodule_path_match(repo->index, pathspec, name.buf, NULL)) {
			hit |= grep_submodule(opt, pathspec, NULL, ce->name,
					      ce->name, cached);
		} else {
			continue;
		}

		if (!use_selected && ce_stage(ce)) {
			do {
				nr++;
			} while (nr < repo->index->cache_nr &&
				 !strcmp(ce->name, repo->index->cache[nr]->name));
			nr--; /* compensate for loop control */
		}
		if (hit && opt->status_only)
			break;
	}

	free(selected);
	strbuf_release(&name);
	return hit;
}

static int grep_tree(struct grep_opt *opt, const struct pathspec *pathspec,
		     struct tree_desc *tree, struct strbuf *base, int tn_len,
		     int check_attr)
{
	struct repository *repo = opt->repo;
	int hit = 0;
	enum interesting match = entry_not_interesting;
	struct name_entry entry;
	int old_baselen = base->len;
	struct strbuf name = STRBUF_INIT;
	int name_base_len = 0;
	if (repo->submodule_prefix) {
		strbuf_addstr(&name, repo->submodule_prefix);
		name_base_len = name.len;
	}

	while (tree_entry(tree, &entry)) {
		int te_len = tree_entry_len(&entry);

		if (match != all_entries_interesting) {
			strbuf_addstr(&name, base->buf + tn_len);
			match = tree_entry_interesting(repo->index,
						       &entry, &name,
						       pathspec);
			strbuf_setlen(&name, name_base_len);

			if (match == all_entries_not_interesting)
				break;
			if (match == entry_not_interesting)
				continue;
		}

		strbuf_add(base, entry.path, te_len);

		if (S_ISREG(entry.mode)) {
			/* Tree entries have no position in a sparse index. */
			hit |= grep_oid(opt, &entry.oid, base->buf, tn_len,
					check_attr ? base->buf + tn_len : NULL,
					0, SIZE_MAX, 0);
		} else if (S_ISDIR(entry.mode)) {
			enum object_type type;
			struct tree_desc sub;
			void *data;
			unsigned long size;

			data = odb_read_object(the_repository->objects,
					       &entry.oid, &type, &size);
			if (!data)
				die(_("unable to read tree (%s)"),
				    oid_to_hex(&entry.oid));

			strbuf_addch(base, '/');
			init_tree_desc(&sub, &entry.oid, data, size);
			hit |= grep_tree(opt, pathspec, &sub, base, tn_len,
					 check_attr);
			free(data);
		} else if (recurse_submodules && S_ISGITLINK(entry.mode)) {
			hit |= grep_submodule(opt, pathspec, &entry.oid,
					      base->buf, base->buf + tn_len,
					      1); /* ignored */
		}

		strbuf_setlen(base, old_baselen);

		if (hit && opt->status_only)
			break;
	}

	strbuf_release(&name);
	return hit;
}

static void collect_blob_oids_for_tree(struct repository *repo,
				       const struct pathspec *pathspec,
				       struct tree_desc *tree,
				       struct strbuf *base,
				       int tn_len,
				       struct oidset *blob_oids)
{
	struct name_entry entry;
	int old_baselen = base->len;
	struct strbuf name = STRBUF_INIT;
	enum interesting match = entry_not_interesting;

	while (tree_entry(tree, &entry)) {
		if (match != all_entries_interesting) {
			strbuf_addstr(&name, base->buf + tn_len);
			match = tree_entry_interesting(repo->index,
						       &entry, &name,
						       pathspec);
			strbuf_reset(&name);

			if (match == all_entries_not_interesting)
				break;
			if (match == entry_not_interesting)
				continue;
		}

		strbuf_add(base, entry.path, tree_entry_len(&entry));

		if (S_ISREG(entry.mode)) {
			if (!odb_has_object(repo->objects, &entry.oid, 0))
				oidset_insert(blob_oids, &entry.oid);
		} else if (S_ISDIR(entry.mode)) {
			enum object_type type;
			struct tree_desc sub_tree;
			void *data;
			unsigned long size;

			data = odb_read_object(repo->objects, &entry.oid,
					       &type, &size);
			if (!data)
				die(_("unable to read tree (%s)"),
				    oid_to_hex(&entry.oid));

			strbuf_addch(base, '/');
			init_tree_desc(&sub_tree, &entry.oid, data, size);
			collect_blob_oids_for_tree(repo, pathspec, &sub_tree,
						   base, tn_len, blob_oids);
			free(data);
		}
		/*
		 * ...no else clause for S_ISGITLINK: submodules have their
		 * own promisor configuration and would need separate fetches
		 * anyway.
		 */

		strbuf_setlen(base, old_baselen);
	}

	strbuf_release(&name);
}

static void collect_blob_oids_for_treeish(struct grep_opt *opt,
					  const struct pathspec *pathspec,
					  const struct object_id *tree_ish_oid,
					  const char *name,
					  struct oidset *blob_oids)
{
	struct tree_desc tree;
	void *data;
	unsigned long size;
	struct strbuf base = STRBUF_INIT;
	int len;

	data = odb_read_object_peeled(opt->repo->objects, tree_ish_oid,
				      OBJ_TREE, &size, NULL);

	if (!data)
		return;

	len = name ? strlen(name) : 0;
	if (len) {
		strbuf_add(&base, name, len);
		strbuf_addch(&base, ':');
	}
	init_tree_desc(&tree, tree_ish_oid, data, size);

	collect_blob_oids_for_tree(opt->repo, pathspec, &tree,
				   &base, base.len, blob_oids);

	strbuf_release(&base);
	free(data);
}

static void prefetch_grep_blobs(struct grep_opt *opt,
				const struct pathspec *pathspec,
				const struct object_array *list)
{
	struct oidset blob_oids = OIDSET_INIT;

	/* Exit if we're not in a partial clone */
	if (!repo_has_promisor_remote(opt->repo))
		return;

	/* For each tree, gather the blobs in it */
	for (int i = 0; i < list->nr; i++) {
		struct object *real_obj;

		obj_read_lock();
		real_obj = deref_tag(opt->repo, list->objects[i].item,
				     NULL, 0);
		obj_read_unlock();

		if (real_obj &&
		    (real_obj->type == OBJ_COMMIT ||
		     real_obj->type == OBJ_TREE))
			collect_blob_oids_for_treeish(opt, pathspec,
						      &real_obj->oid,
						      list->objects[i].name,
						      &blob_oids);
	}

	/* Prefetch the blobs we found */
	if (oidset_size(&blob_oids)) {
		struct oid_array to_fetch = OID_ARRAY_INIT;
		struct oidset_iter iter;
		const struct object_id *oid;

		oidset_iter_init(&blob_oids, &iter);
		while ((oid = oidset_iter_next(&iter)))
			oid_array_append(&to_fetch, oid);

		promisor_remote_get_direct(opt->repo, to_fetch.oid, to_fetch.nr);

		oid_array_clear(&to_fetch);
	}
	oidset_clear(&blob_oids);
}

static int grep_object(struct grep_opt *opt, const struct pathspec *pathspec,
		       struct object *obj, const char *name, const char *path)
{
	if (obj->type == OBJ_BLOB)
		return grep_oid(opt, &obj->oid, name, 0, path, 0, 0, 0);
	if (obj->type == OBJ_COMMIT || obj->type == OBJ_TREE) {
		struct tree_desc tree;
		void *data;
		unsigned long size;
		struct strbuf base;
		int hit, len;

		data = odb_read_object_peeled(opt->repo->objects, &obj->oid,
					      OBJ_TREE, &size, NULL);
		if (!data)
			die(_("unable to read tree (%s)"), oid_to_hex(&obj->oid));

		len = name ? strlen(name) : 0;
		strbuf_init(&base, PATH_MAX + len + 1);
		if (len) {
			strbuf_add(&base, name, len);
			strbuf_addch(&base, ':');
		}
		init_tree_desc(&tree, &obj->oid, data, size);
		hit = grep_tree(opt, pathspec, &tree, &base, base.len,
				obj->type == OBJ_COMMIT);
		strbuf_release(&base);
		free(data);
		return hit;
	}
	die(_("unable to grep from object of type %s"), type_name(obj->type));
}

static int grep_objects(struct grep_opt *opt, const struct pathspec *pathspec,
			const struct object_array *list)
{
	unsigned int i;
	int hit = 0;
	const unsigned int nr = list->nr;

	prefetch_grep_blobs(opt, pathspec, list);

	for (i = 0; i < nr; i++) {
		struct object *real_obj;

		obj_read_lock();
		real_obj = deref_tag(opt->repo, list->objects[i].item,
				     NULL, 0);
		obj_read_unlock();

		if (!real_obj) {
			char hex[GIT_MAX_HEXSZ + 1];
			const char *name = list->objects[i].name;

			if (!name) {
				oid_to_hex_r(hex, &list->objects[i].item->oid);
				name = hex;
			}
			die(_("invalid object '%s' given."), name);
		}

		/* load the gitmodules file for this rev */
		if (recurse_submodules) {
			submodule_free(opt->repo);
			obj_read_lock();
			gitmodules_config_oid(&real_obj->oid);
			obj_read_unlock();
		}
		if (grep_object(opt, pathspec, real_obj, list->objects[i].name,
				list->objects[i].path)) {
			hit = 1;
			if (opt->status_only)
				break;
		}
	}
	return hit;
}

static int grep_directory(struct grep_opt *opt, const struct pathspec *pathspec,
			  int exc_std, int use_index)
{
	struct dir_struct dir = DIR_INIT;
	int i, hit = 0;

	if (!use_index)
		dir.flags |= DIR_NO_GITLINKS;
	if (exc_std)
		setup_standard_excludes(&dir);

	fill_directory(&dir, opt->repo->index, pathspec);
	for (i = 0; i < dir.nr; i++) {
		hit |= grep_file(opt, dir.entries[i]->name, NULL, 0);
		if (hit && opt->status_only)
			break;
	}
	dir_clear(&dir);
	return hit;
}

static int context_callback(const struct option *opt, const char *arg,
			    int unset)
{
	struct grep_opt *grep_opt = opt->value;
	int value;
	const char *endp;

	if (unset) {
		grep_opt->pre_context = grep_opt->post_context = 0;
		return 0;
	}
	value = strtol(arg, (char **)&endp, 10);
	if (*endp) {
		return error(_("switch `%c' expects a numerical value"),
			     opt->short_name);
	}
	grep_opt->pre_context = grep_opt->post_context = value;
	return 0;
}

static int file_callback(const struct option *opt, const char *arg, int unset)
{
	struct grep_opt *grep_opt = opt->value;
	int from_stdin;
	const char *filename = arg;
	FILE *patterns;
	int lno = 0;
	struct strbuf sb = STRBUF_INIT;

	BUG_ON_OPT_NEG(unset);

	if (!*filename)
		; /* leave it as-is */
	else
		filename = prefix_filename_except_for_dash(grep_prefix, filename);

	from_stdin = !strcmp(filename, "-");
	patterns = from_stdin ? stdin : fopen(filename, "r");
	if (!patterns)
		die_errno(_("cannot open '%s'"), arg);
	while (strbuf_getline(&sb, patterns) == 0) {
		/* ignore empty line like grep does */
		if (sb.len == 0)
			continue;

		append_grep_pat(grep_opt, sb.buf, sb.len, arg, ++lno,
				GREP_PATTERN);
	}
	if (!from_stdin)
		fclose(patterns);
	strbuf_release(&sb);
	if (filename != arg)
		free((void *)filename);
	return 0;
}

static int not_callback(const struct option *opt, const char *arg, int unset)
{
	struct grep_opt *grep_opt = opt->value;
	BUG_ON_OPT_NEG(unset);
	BUG_ON_OPT_ARG(arg);
	append_grep_pattern(grep_opt, "--not", "command line", 0, GREP_NOT);
	return 0;
}

static int and_callback(const struct option *opt, const char *arg, int unset)
{
	struct grep_opt *grep_opt = opt->value;
	BUG_ON_OPT_NEG(unset);
	BUG_ON_OPT_ARG(arg);
	append_grep_pattern(grep_opt, "--and", "command line", 0, GREP_AND);
	return 0;
}

static int open_callback(const struct option *opt, const char *arg, int unset)
{
	struct grep_opt *grep_opt = opt->value;
	BUG_ON_OPT_NEG(unset);
	BUG_ON_OPT_ARG(arg);
	append_grep_pattern(grep_opt, "(", "command line", 0, GREP_OPEN_PAREN);
	return 0;
}

static int close_callback(const struct option *opt, const char *arg, int unset)
{
	struct grep_opt *grep_opt = opt->value;
	BUG_ON_OPT_NEG(unset);
	BUG_ON_OPT_ARG(arg);
	append_grep_pattern(grep_opt, ")", "command line", 0, GREP_CLOSE_PAREN);
	return 0;
}

static int pattern_callback(const struct option *opt, const char *arg,
			    int unset)
{
	struct grep_opt *grep_opt = opt->value;
	BUG_ON_OPT_NEG(unset);
	append_grep_pattern(grep_opt, arg, "-e option", 0, GREP_PATTERN);
	return 0;
}

int cmd_grep(int argc,
	     const char **argv,
	     const char *prefix,
	     struct repository *repo UNUSED)
{
	int hit = 0;
	int cached = 0, untracked = 0, opt_exclude = -1;
	int seen_dashdash = 0;
	int external_grep_allowed__ignored;
	const char *show_in_pager = NULL, *default_pager = "dummy";
	struct grep_opt opt;
	struct object_array list = OBJECT_ARRAY_INIT;
	struct pathspec pathspec;
	struct string_list path_list = STRING_LIST_INIT_DUP;
	int i;
	int dummy;
	int use_index = 1;
	int allow_revs;
	int ret;

	struct option options[] = {
		OPT_BOOL(0, "cached", &cached,
			N_("search in index instead of in the work tree")),
		OPT_BOOL(0, "content-index", &use_content_index,
			N_("use the shared content index when possible")),
		OPT_NEGBIT(0, "no-index", &use_index,
			 N_("find in contents not managed by git"), 1),
		OPT_BOOL(0, "untracked", &untracked,
			N_("search in both tracked and untracked files")),
		OPT_SET_INT(0, "exclude-standard", &opt_exclude,
			    N_("ignore files specified via '.gitignore'"), 1),
		OPT_BOOL(0, "recurse-submodules", &recurse_submodules,
			 N_("recursively search in each submodule")),
		OPT_GROUP(""),
		OPT_BOOL('v', "invert-match", &opt.invert,
			N_("show non-matching lines")),
		OPT_BOOL('i', "ignore-case", &opt.ignore_case,
			N_("case insensitive matching")),
		OPT_BOOL('w', "word-regexp", &opt.word_regexp,
			N_("match patterns only at word boundaries")),
		OPT_SET_INT('a', "text", &opt.binary,
			N_("process binary files as text"), GREP_BINARY_TEXT),
		OPT_SET_INT('I', NULL, &opt.binary,
			N_("don't match patterns in binary files"),
			GREP_BINARY_NOMATCH),
		OPT_BOOL(0, "textconv", &opt.allow_textconv,
			 N_("process binary files with textconv filters")),
		OPT_SET_INT('r', "recursive", &opt.max_depth,
			    N_("search in subdirectories (default)"), -1),
		OPT_INTEGER_F(0, "max-depth", &opt.max_depth,
			N_("descend at most <n> levels"), PARSE_OPT_NONEG),
		OPT_GROUP(""),
		OPT_SET_INT('E', "extended-regexp", &opt.pattern_type_option,
			    N_("use extended POSIX regular expressions"),
			    GREP_PATTERN_TYPE_ERE),
		OPT_SET_INT('G', "basic-regexp", &opt.pattern_type_option,
			    N_("use basic POSIX regular expressions (default)"),
			    GREP_PATTERN_TYPE_BRE),
		OPT_SET_INT('F', "fixed-strings", &opt.pattern_type_option,
			    N_("interpret patterns as fixed strings"),
			    GREP_PATTERN_TYPE_FIXED),
		OPT_SET_INT('P', "perl-regexp", &opt.pattern_type_option,
			    N_("use Perl-compatible regular expressions"),
			    GREP_PATTERN_TYPE_PCRE),
		OPT_GROUP(""),
		OPT_BOOL('n', "line-number", &opt.linenum, N_("show line numbers")),
		OPT_BOOL(0, "column", &opt.columnnum, N_("show column number of first match")),
		OPT_NEGBIT('h', NULL, &opt.pathname, N_("don't show filenames"), 1),
		OPT_BIT('H', NULL, &opt.pathname, N_("show filenames"), 1),
		OPT_NEGBIT(0, "full-name", &opt.relative,
			N_("show filenames relative to top directory"), 1),
		OPT_BOOL('l', "files-with-matches", &opt.name_only,
			N_("show only filenames instead of matching lines")),
		OPT_BOOL(0, "name-only", &opt.name_only,
			N_("synonym for --files-with-matches")),
		OPT_BOOL('L', "files-without-match",
			&opt.unmatch_name_only,
			N_("show only the names of files without match")),
		OPT_BOOL_F('z', "null", &opt.null_following_name,
			   N_("print NUL after filenames"),
			   PARSE_OPT_NOCOMPLETE),
		OPT_BOOL('o', "only-matching", &opt.only_matching,
			N_("show only matching parts of a line")),
		OPT_BOOL('c', "count", &opt.count,
			N_("show the number of matches instead of matching lines")),
		OPT__COLOR(&opt.color, N_("highlight matches")),
		OPT_BOOL(0, "break", &opt.file_break,
			N_("print empty line between matches from different files")),
		OPT_BOOL(0, "heading", &opt.heading,
			N_("show filename only once above matches from same file")),
		OPT_GROUP(""),
		OPT_CALLBACK('C', "context", &opt, N_("n"),
			N_("show <n> context lines before and after matches"),
			context_callback),
		OPT_UNSIGNED('B', "before-context", &opt.pre_context,
			N_("show <n> context lines before matches")),
		OPT_UNSIGNED('A', "after-context", &opt.post_context,
			N_("show <n> context lines after matches")),
		OPT_INTEGER(0, "threads", &num_threads,
			N_("use <n> worker threads")),
		OPT_NUMBER_CALLBACK(&opt, N_("shortcut for -C NUM"),
			context_callback),
		OPT_BOOL('p', "show-function", &opt.funcname,
			N_("show a line with the function name before matches")),
		OPT_BOOL('W', "function-context", &opt.funcbody,
			N_("show the surrounding function")),
		OPT_GROUP(""),
		OPT_CALLBACK('f', NULL, &opt, N_("file"),
			N_("read patterns from file"), file_callback),
		OPT_CALLBACK_F('e', NULL, &opt, N_("pattern"),
			N_("match <pattern>"), PARSE_OPT_NONEG, pattern_callback),
		OPT_CALLBACK_F(0, "and", &opt, NULL,
			N_("combine patterns specified with -e"),
			PARSE_OPT_NOARG | PARSE_OPT_NONEG, and_callback),
		OPT_BOOL_F(0, "or", &dummy, "", PARSE_OPT_NONEG),
		OPT_CALLBACK_F(0, "not", &opt, NULL, "",
			PARSE_OPT_NOARG | PARSE_OPT_NONEG, not_callback),
		OPT_CALLBACK_F('(', NULL, &opt, NULL, "",
			PARSE_OPT_NOARG | PARSE_OPT_NONEG | PARSE_OPT_NODASH,
			open_callback),
		OPT_CALLBACK_F(')', NULL, &opt, NULL, "",
			PARSE_OPT_NOARG | PARSE_OPT_NONEG | PARSE_OPT_NODASH,
			close_callback),
		OPT__QUIET(&opt.status_only,
			   N_("indicate hit with exit status without output")),
		OPT_BOOL(0, "all-match", &opt.all_match,
			N_("show only matches from files that match all patterns")),
		OPT_GROUP(""),
		{
			.type = OPTION_STRING,
			.short_name = 'O',
			.long_name = "open-files-in-pager",
			.value = &show_in_pager,
			.argh = N_("pager"),
			.help = N_("show matching files in the pager"),
			.flags = PARSE_OPT_OPTARG | PARSE_OPT_NOCOMPLETE,
			.defval = (intptr_t)default_pager,
		},
		OPT_BOOL_F(0, "ext-grep", &external_grep_allowed__ignored,
			   N_("allow calling of grep(1) (ignored by this build)"),
			   PARSE_OPT_NOCOMPLETE),
		OPT_INTEGER('m', "max-count", &opt.max_count,
			N_("maximum number of results per file")),
		OPT_END()
	};
	grep_prefix = prefix;

	grep_init(&opt, the_repository);
	repo_config(the_repository, grep_cmd_config, &opt);

	/*
	 * If there is no -- then the paths must exist in the working
	 * tree.  If there is no explicit pattern specified with -e or
	 * -f, we take the first unrecognized non option to be the
	 * pattern, but then what follows it must be zero or more
	 * valid refs up to the -- (if exists), and then existing
	 * paths.  If there is an explicit pattern, then the first
	 * unrecognized non option is the beginning of the refs list
	 * that continues up to the -- (if exists), and then paths.
	 */
	argc = parse_options(argc, argv, prefix, options, grep_usage,
			     PARSE_OPT_KEEP_DASHDASH |
			     PARSE_OPT_STOP_AT_NON_OPTION);

	if (the_repository->gitdir) {
		prepare_repo_settings(the_repository);
		the_repository->settings.command_requires_full_index = 0;
	}

	if (use_index && !startup_info->have_repository) {
		int fallback = 0;
		repo_config_get_bool(the_repository, "grep.fallbacktonoindex", &fallback);
		if (fallback)
			use_index = 0;
		else
			/* die the same way as if we did it at the beginning */
			setup_git_directory(the_repository);
	}
	/* Ignore --recurse-submodules if --no-index is given or implied */
	if (!use_index)
		recurse_submodules = 0;

	/*
	 * skip a -- separator; we know it cannot be
	 * separating revisions from pathnames if
	 * we haven't even had any patterns yet
	 */
	if (argc > 0 && !opt.pattern_list && !strcmp(argv[0], "--")) {
		argv++;
		argc--;
	}

	/* First unrecognized non-option token */
	if (argc > 0 && !opt.pattern_list) {
		append_grep_pattern(&opt, argv[0], "command line", 0,
				    GREP_PATTERN);
		argv++;
		argc--;
	}

	if (show_in_pager == default_pager)
		show_in_pager = git_pager(the_repository, 1);
	if (show_in_pager) {
		opt.color = GIT_COLOR_NEVER;
		opt.name_only = 1;
		opt.null_following_name = 1;
		opt.output_priv = &path_list;
		opt.output = append_path;
		string_list_append(&path_list, show_in_pager);
	}

	if (!opt.pattern_list)
		die(_("no pattern given"));

	/* --only-matching has no effect with --invert. */
	if (opt.invert)
		opt.only_matching = 0;

	/*
	 * We have to find "--" in a separate pass, because its presence
	 * influences how we will parse arguments that come before it.
	 */
	for (i = 0; i < argc; i++) {
		if (!strcmp(argv[i], "--")) {
			seen_dashdash = 1;
			break;
		}
	}

	/*
	 * Resolve any rev arguments. If we have a dashdash, then everything up
	 * to it must resolve as a rev. If not, then we stop at the first
	 * non-rev and assume everything else is a path.
	 */
	allow_revs = use_index && !untracked;
	for (i = 0; i < argc; i++) {
		const char *arg = argv[i];
		struct object_id oid;
		struct object_context oc = {0};
		struct object *object;

		if (!strcmp(arg, "--")) {
			i++;
			break;
		}

		if (!allow_revs) {
			if (seen_dashdash)
				die(_("--no-index or --untracked cannot be used with revs"));
			break;
		}

		if (get_oid_with_context(the_repository, arg,
					 GET_OID_RECORD_PATH,
					 &oid, &oc)) {
			if (seen_dashdash)
				die(_("unable to resolve revision: %s"), arg);
			object_context_release(&oc);
			break;
		}

		object = parse_object_or_die(the_repository, &oid, arg);
		if (!seen_dashdash)
			verify_non_filename(the_repository, prefix, arg);
		add_object_array_with_path(object, arg, &list, oc.mode, oc.path);
		object_context_release(&oc);
	}

	/*
	 * Anything left over is presumed to be a path. But in the non-dashdash
	 * "do what I mean" case, we verify and complain when that isn't true.
	 */
	if (!seen_dashdash) {
		int j;
		for (j = i; j < argc; j++)
			verify_filename(the_repository, prefix, argv[j], j == i && allow_revs);
	}

	parse_pathspec(&pathspec, 0,
		       PATHSPEC_PREFER_CWD |
		       (opt.max_depth != -1 ? PATHSPEC_MAXDEPTH_VALID : 0),
		       prefix, argv + i);
	pathspec.max_depth = opt.max_depth;
	pathspec.recursive = 1;
	pathspec.recurse_submodules = !!recurse_submodules;
	if (recurse_submodules && untracked)
		die(_("--untracked not supported with --recurse-submodules"));

	if (use_content_index && use_index && !untracked && !opt.allow_textconv)
		content_index_query = grep_index_query_create(&opt);

	/*
	 * Optimize out the case where the amount of matches is limited to zero.
	 * We do this to keep results consistent with GNU grep(1).
	 */
	if (opt.max_count == 0) {
		ret = 1;
		goto out;
	}

	threads_auto = num_threads == 0;
	if (show_in_pager) {
		if (num_threads > 1)
			warning(_("invalid option combination, ignoring --threads"));
		num_threads = 1;
	} else if (!HAVE_THREADS && num_threads > 1) {
		warning(_("no threads support, ignoring --threads"));
		num_threads = 1;
	} else if (num_threads < 0)
		die(_("invalid number of threads specified (%d)"), num_threads);
	else if (num_threads == 0)
		num_threads = HAVE_THREADS ? online_cpus() : 1;

	if (list.nr > 1 && !opt.allow_textconv) {
		hashmap_init(&grep_result_cache.map, grep_result_cache_cmp,
			     NULL, 0);
		grep_result_cache.initialized = 1;
	}

	if (num_threads > 1) {
		if (!HAVE_THREADS)
			BUG("Somebody got num_threads calculation wrong!");
	}
	compile_grep_patterns(&opt);
	if (num_threads > 1 && recurse_submodules)
		start_threads(&opt);

	if (show_in_pager && (cached || list.nr))
		die(_("--open-files-in-pager only works on the worktree"));

	if (show_in_pager && opt.pattern_list && !opt.pattern_list->next) {
		const char *pager = path_list.items[0].string;
		int len = strlen(pager);

		if (len > 4 && is_dir_sep(pager[len - 5]))
			pager += len - 4;

		if (opt.ignore_case && !strcmp("less", pager))
			string_list_append(&path_list, "-I");

		if (!strcmp("less", pager) || !strcmp("vi", pager)) {
			struct strbuf buf = STRBUF_INIT;
			strbuf_addf(&buf, "+/%s%s",
					strcmp("less", pager) ? "" : "*",
					opt.pattern_list->pattern);
			string_list_append_nodup(&path_list,
						 strbuf_detach(&buf, NULL));
		}
	}

	if (!show_in_pager && !opt.status_only)
		setup_pager(the_repository);

	die_for_incompatible_opt3(!use_index, "--no-index",
				  untracked, "--untracked",
				  cached, "--cached");

	if (!use_index || untracked) {
		int use_exclude = (opt_exclude < 0) ? use_index : !!opt_exclude;
		hit = grep_directory(&opt, &pathspec, use_exclude, use_index);
	} else if (0 <= opt_exclude) {
		die(_("--[no-]exclude-standard cannot be used for tracked contents"));
	} else if (!list.nr) {
		if (!cached)
			setup_work_tree(the_repository);

		hit = grep_cache(&opt, &pathspec, cached);
	} else {
		if (cached)
			die(_("both --cached and trees are given"));

		hit = grep_objects(&opt, &pathspec, &list);
	}

	if (threads_started)
		hit |= wait_all();
	if (content_index_negative_entries) {
		trace2_data_intmax("grep", the_repository,
				   "content_index_negative_cache_entries",
				   content_index_negative_entries);
		grep_index_ipc_report_negatives(
			the_repository, content_index_query,
			&content_index_negative_identity,
			content_index_negative_result, content_index_negative_nr);
	}
	if (hit && show_in_pager)
		run_pager(&opt, prefix);

	ret = !hit;

out:
	if (worker_lease_id) {
		grep_index_ipc_release_workers(
			the_repository, worker_lease_id);
		worker_lease_id = 0;
	}
	grep_worktree_cache_write(worktree_cache);
	grep_worktree_cache_free(worktree_cache);
	worktree_cache = NULL;
	clear_pathspec(&pathspec);
	string_list_clear(&path_list, 0);
	free_grep_patterns(&opt);
	object_array_clear(&list);
	if (grep_result_cache.initialized) {
		trace2_data_intmax("grep", the_repository,
				   "result_cache/entries",
				   hashmap_get_size(&grep_result_cache.map));
		trace2_data_intmax("grep", the_repository,
				   "result_cache/hits",
				   grep_result_cache.hits);
		hashmap_clear_and_free(&grep_result_cache.map,
				       struct grep_result_cache_entry, ent);
		grep_result_cache.hits = 0;
		grep_result_cache.initialized = 0;
	}
	grep_index_query_free(content_index_query);
	grep_index_prepared_free(content_index_prepared);
	grep_index_free(content_index);
	FREE_AND_NULL(content_index_ipc_result);
	content_index_ipc_nr = 0;
	FREE_AND_NULL(content_index_negative_result);
	content_index_negative_nr = 0;
	content_index_negative_entries = 0;
	free_repos();
	return ret;
}

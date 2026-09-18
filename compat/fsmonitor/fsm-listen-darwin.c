#ifndef __clang__
#include <dispatch/dispatch.h>
#include "fsm-darwin-gcc.h"
#else
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>

#ifndef AVAILABLE_MAC_OS_X_VERSION_10_13_AND_LATER
/*
 * This enum value was added in 10.13 to:
 *
 * /Applications/Xcode.app/Contents/Developer/Platforms/ \
 *    MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/ \
 *    Library/Frameworks/CoreServices.framework/Frameworks/ \
 *    FSEvents.framework/Versions/Current/Headers/FSEvents.h
 *
 * If we're compiling against an older SDK, this symbol won't be
 * present.  Silently define it here so that we don't have to ifdef
 * the logging or masking below.  This should be harmless since older
 * versions of macOS won't ever emit this FS event anyway.
 */
#define kFSEventStreamEventFlagItemCloned         0x00400000
#endif
#endif

#include "git-compat-util.h"
#include "dir.h"
#include "fsmonitor-ll.h"
#include "fsm-listen.h"
#include "fsmonitor--daemon.h"
#include "fsmonitor-path-utils.h"
#include "gettext.h"
#include "json-writer.h"
#include "simple-ipc.h"
#include "string-list.h"
#include "trace.h"
#include "trace2.h"

struct fsm_callback_stats {
	uint64_t callbacks;
	uint64_t input_events;
	uint64_t total_ns;
	uint64_t max_ns;
	/* Includes both the main_lock wait and publication work. */
	uint64_t publish_ns;
	uint64_t max_publish_ns;
};

struct fsm_listen_data
{
	CFStringRef cfsr_worktree_path;
	CFStringRef cfsr_gitdir_path;

	CFArrayRef cfar_paths_to_watch;
	int nr_paths_watching;

	FSEventStreamRef stream;

	dispatch_queue_t dq;
	pthread_cond_t dq_finished;
	pthread_mutex_t dq_lock;

	/* Owned by the serial callback queue until it is drained at stop. */
	struct fsm_callback_stats callback_stats;

	enum shutdown_style {
		WAITING = 0,
		SHUTDOWN_EVENT,
		FORCE_SHUTDOWN,
		FORCE_ERROR_STOP,
	} shutdown_style;

	unsigned int stream_scheduled:1;
	unsigned int stream_started:1;
};

static void fsm_listen__queue_marker(void *ctx UNUSED)
{
}

static uint64_t fsm_listen__trace_clock(void)
{
	int saved_errno = errno;
	uint64_t now = getnanotime();

	errno = saved_errno;
	return now;
}

/*
 * Emit only at resync or stop: writing Trace2 inside the watched tree on
 * every callback would itself generate an endless stream of events.
 */
static void fsm_listen__trace_stats(struct fsm_callback_stats *stats,
				    const char *key)
{
	struct json_writer jw = JSON_WRITER_INIT;
	int saved_errno = errno;

	if (!stats->callbacks)
		return;
	jw_object_begin(&jw, 0);
	jw_object_intmax(&jw, "callbacks", stats->callbacks);
	jw_object_intmax(&jw, "input_events", stats->input_events);
	jw_object_intmax(&jw, "total_ns", stats->total_ns);
	jw_object_intmax(&jw, "max_ns", stats->max_ns);
	jw_object_intmax(&jw, "publish_ns", stats->publish_ns);
	jw_object_intmax(&jw, "max_publish_ns", stats->max_publish_ns);
	jw_end(&jw);
	trace2_data_json("fsmonitor", NULL, key, &jw);
	jw_release(&jw);
	memset(stats, 0, sizeof(*stats));
	errno = saved_errno;
}

static void log_flags_set(const char *path, const FSEventStreamEventFlags flag)
{
	struct strbuf msg = STRBUF_INIT;

	if (flag & kFSEventStreamEventFlagMustScanSubDirs)
		strbuf_addstr(&msg, "MustScanSubDirs|");
	if (flag & kFSEventStreamEventFlagUserDropped)
		strbuf_addstr(&msg, "UserDropped|");
	if (flag & kFSEventStreamEventFlagKernelDropped)
		strbuf_addstr(&msg, "KernelDropped|");
	if (flag & kFSEventStreamEventFlagEventIdsWrapped)
		strbuf_addstr(&msg, "EventIdsWrapped|");
	if (flag & kFSEventStreamEventFlagHistoryDone)
		strbuf_addstr(&msg, "HistoryDone|");
	if (flag & kFSEventStreamEventFlagRootChanged)
		strbuf_addstr(&msg, "RootChanged|");
	if (flag & kFSEventStreamEventFlagMount)
		strbuf_addstr(&msg, "Mount|");
	if (flag & kFSEventStreamEventFlagUnmount)
		strbuf_addstr(&msg, "Unmount|");
	if (flag & kFSEventStreamEventFlagItemChangeOwner)
		strbuf_addstr(&msg, "ItemChangeOwner|");
	if (flag & kFSEventStreamEventFlagItemCreated)
		strbuf_addstr(&msg, "ItemCreated|");
	if (flag & kFSEventStreamEventFlagItemFinderInfoMod)
		strbuf_addstr(&msg, "ItemFinderInfoMod|");
	if (flag & kFSEventStreamEventFlagItemInodeMetaMod)
		strbuf_addstr(&msg, "ItemInodeMetaMod|");
	if (flag & kFSEventStreamEventFlagItemIsDir)
		strbuf_addstr(&msg, "ItemIsDir|");
	if (flag & kFSEventStreamEventFlagItemIsFile)
		strbuf_addstr(&msg, "ItemIsFile|");
	if (flag & kFSEventStreamEventFlagItemIsHardlink)
		strbuf_addstr(&msg, "ItemIsHardlink|");
	if (flag & kFSEventStreamEventFlagItemIsLastHardlink)
		strbuf_addstr(&msg, "ItemIsLastHardlink|");
	if (flag & kFSEventStreamEventFlagItemIsSymlink)
		strbuf_addstr(&msg, "ItemIsSymlink|");
	if (flag & kFSEventStreamEventFlagItemModified)
		strbuf_addstr(&msg, "ItemModified|");
	if (flag & kFSEventStreamEventFlagItemRemoved)
		strbuf_addstr(&msg, "ItemRemoved|");
	if (flag & kFSEventStreamEventFlagItemRenamed)
		strbuf_addstr(&msg, "ItemRenamed|");
	if (flag & kFSEventStreamEventFlagItemXattrMod)
		strbuf_addstr(&msg, "ItemXattrMod|");
	if (flag & kFSEventStreamEventFlagOwnEvent)
		strbuf_addstr(&msg, "OwnEvent|");
	if (flag & kFSEventStreamEventFlagItemCloned)
		strbuf_addstr(&msg, "ItemCloned|");

	trace_printf_key(&trace_fsmonitor, "fsevent: '%s', flags=0x%x %s",
			 path, flag, msg.buf);

	strbuf_release(&msg);
}

static int ef_is_root_changed(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagRootChanged);
}

static int ef_is_root_delete(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagItemIsDir &&
		ef & kFSEventStreamEventFlagItemRemoved);
}

static int ef_is_root_renamed(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagItemIsDir &&
		ef & kFSEventStreamEventFlagItemRenamed);
}

static int ef_is_dropped(const FSEventStreamEventFlags ef)
{
	return (ef & kFSEventStreamEventFlagKernelDropped ||
		ef & kFSEventStreamEventFlagUserDropped);
}

/*
 * If an `xattr` change is the only reason we received this event,
 * then silently ignore it.  Git doesn't care about xattr's.  We
 * have to be careful here because the kernel can combine multiple
 * events for a single path.  And because events always have certain
 * bits set, such as `ItemIsFile` or `ItemIsDir`.
 *
 * Return 1 if we should ignore it.
 */
static int ef_ignore_xattr(const FSEventStreamEventFlags ef)
{
	static const FSEventStreamEventFlags mask =
		kFSEventStreamEventFlagItemChangeOwner |
		kFSEventStreamEventFlagItemCreated |
		kFSEventStreamEventFlagItemFinderInfoMod |
		kFSEventStreamEventFlagItemInodeMetaMod |
		kFSEventStreamEventFlagItemModified |
		kFSEventStreamEventFlagItemRemoved |
		kFSEventStreamEventFlagItemRenamed |
		kFSEventStreamEventFlagItemXattrMod |
		kFSEventStreamEventFlagItemCloned;

	return ((ef & mask) == kFSEventStreamEventFlagItemXattrMod);
}

/*
 * On MacOS we have to adjust for Unicode composition insensitivity
 * (where NFC and NFD spellings are not respected).  The different
 * spellings are essentially aliases regardless of how the path is
 * actually stored on the disk.
 *
 * This is related to "core.precomposeUnicode" (which wants to try
 * to hide NFD completely and treat everything as NFC).  Here, we
 * don't know what the value the client has (or will have) for this
 * config setting when they make a query, so assume the worst and
 * emit both when the OS gives us an NFD path.
 */
static void my_add_path(struct fsmonitor_batch *batch, const char *path)
{
	char *composed;

	/* add the NFC or NFD path as received from the OS */
	fsmonitor_batch__add_path(batch, path);

	/* if NFD, also add the corresponding NFC spelling */
	composed = (char *)precompose_string_if_needed(path);
	if (!composed || composed == path)
		return;

	fsmonitor_batch__add_path(batch, composed);
	free(composed);
}


static void fsevent_callback(ConstFSEventStreamRef streamRef UNUSED,
			     void *ctx,
			     size_t num_of_events,
			     void *event_paths,
			     const FSEventStreamEventFlags event_flags[],
			     const FSEventStreamEventId event_ids[] UNUSED)
{
	struct fsmonitor_daemon_state *state = ctx;
	struct fsm_listen_data *data = state->listen_data;
	char **paths = (char **)event_paths;
	struct fsmonitor_batch *batch = NULL;
	struct string_list cookie_list = STRING_LIST_INIT_DUP;
	const char *path_k;
	const char *slash;
	char *resolved = NULL;
	struct strbuf tmp = STRBUF_INIT;
	enum fsmonitor_path_type path_type;
	const char *worktree_rel;
	uint64_t begin = trace2_is_enabled() ? fsm_listen__trace_clock() : 0;
	uint64_t publish_begin = 0, publish_ns = 0;
	int resynced = 0;

	/*
	 * Build a list of all filesystem changes into a private/local
	 * list and without holding any locks.
	 */
	for (size_t k = 0; k < num_of_events; k++) {
		/*
		 * On Mac, we receive an array of absolute paths.
		 */
		free(resolved);
		resolved = fsmonitor__resolve_alias(paths[k], &state->alias);
		if (resolved)
			path_k = resolved;
		else
			path_k = paths[k];

		path_type = fsmonitor_classify_path_absolute(state, path_k);
		worktree_rel = NULL;
		if (path_type == IS_WORKDIR_PATH) {
			worktree_rel = path_k + state->path_worktree_watch.len;
			if (*worktree_rel == '/')
				worktree_rel++;
		}

		/*
		 * If you want to debug FSEvents, log them to GIT_TRACE_FSMONITOR.
		 * Please don't log them to Trace2.
		 *
		 * trace_printf_key(&trace_fsmonitor, "Path: '%s'", path_k);
		 */

		/*
		 * If events were dropped, or a recursive scan is outside the
		 * worktree, at its root, or may include the cookie directory,
		 * flush our cached data.  A coalesced cookie event could leave
		 * clients waiting until timeout.  We need to:
		 *
		 * [1] Abort/wake any client threads waiting for a cookie and
		 *     flush the cached state data (the current token), and
		 *     create a new token.
		 *
		 * [2] Discard the batch that we were locally building (since
		 *     they are conceptually relative to the just flushed
		 *     token).
		 */
		if (ef_is_dropped(event_flags[k]) ||
		    (event_flags[k] & kFSEventStreamEventFlagMustScanSubDirs &&
		     (path_type == IS_OUTSIDE_CONE ||
		      (path_type == IS_WORKDIR_PATH && !*worktree_rel) ||
		      dir_inside_of(state->path_cookie_prefix.buf, path_k) >= 0))) {
			const char *reason;
			enum fsmonitor_generation_cause cause;

			if (trace_pass_fl(&trace_fsmonitor))
				log_flags_set(path_k, event_flags[k]);

			if (event_flags[k] & kFSEventStreamEventFlagKernelDropped) {
				reason = "kernel-dropped";
				cause = FSMONITOR_GENERATION_DARWIN_KERNEL_DROPPED;
			} else if (event_flags[k] & kFSEventStreamEventFlagUserDropped) {
				reason = "user-dropped";
				cause = FSMONITOR_GENERATION_DARWIN_USER_DROPPED;
			} else if (path_type == IS_OUTSIDE_CONE) {
				reason = "outside-cone";
				cause = FSMONITOR_GENERATION_DARWIN_OUTSIDE_CONE;
			} else if (path_type == IS_WORKDIR_PATH && !*worktree_rel) {
				reason = "worktree-root";
				cause = FSMONITOR_GENERATION_DARWIN_WORKTREE_ROOT;
			} else {
				reason = "cookie-prefix";
				cause = FSMONITOR_GENERATION_DARWIN_COOKIE_PREFIX;
			}
			resynced = 1;
			fsmonitor_force_resync(state, cause);
			trace2_data_string("fsmonitor", NULL, "resync/reason", reason);
			fsmonitor_batch__free_list(batch);
			string_list_clear(&cookie_list, 0);
			batch = NULL;

			/*
			 * We assume that any events that we received
			 * in this callback after this resync event
			 * may still be valid, so we continue rather
			 * than break.  (And just in case there is a
			 * delete of ".git" hiding in there.)
			 */
			continue;
		}

		/*
		 * Without a user or kernel drop, MustScanSubDirs means that
		 * FSEvents coalesced changes below this path.  Publish the path
		 * as a directory so clients invalidate that cone recursively.
		 */
		if (path_type == IS_WORKDIR_PATH &&
		    event_flags[k] & kFSEventStreamEventFlagMustScanSubDirs) {
			if (trace_pass_fl(&trace_fsmonitor))
				log_flags_set(path_k, event_flags[k]);

			strbuf_reset(&tmp);
			strbuf_addstr(&tmp, worktree_rel);
			strbuf_addch(&tmp, '/');

			if (!batch)
				batch = fsmonitor_batch__new();
			my_add_path(batch, tmp.buf);
			continue;
		}

		if (ef_is_root_changed(event_flags[k])) {
			/*
			 * The spelling of the pathname of the root directory
			 * has changed.  This includes the name of the root
			 * directory itself or of any parent directory in the
			 * path.
			 *
			 * (There may be other conditions that throw this,
			 * but I couldn't find any information on it.)
			 *
			 * Force a shutdown now and avoid things getting
			 * out of sync.  The Unix domain socket is inside
			 * the .git directory and a spelling change will make
			 * it hard for clients to rendezvous with us.
			 */
			trace_printf_key(&trace_fsmonitor,
					 "event: root changed");
			goto force_shutdown;
		}

		if (ef_ignore_xattr(event_flags[k])) {
			trace_printf_key(&trace_fsmonitor,
					 "ignore-xattr: '%s', flags=0x%x",
					 path_k, event_flags[k]);
			continue;
		}

		switch (path_type) {
		case IS_INSIDE_DOT_GIT_WITH_COOKIE_PREFIX:
		case IS_INSIDE_GITDIR_WITH_COOKIE_PREFIX:
			/* special case cookie files within .git or gitdir */

			/* Use just the filename of the cookie file. */
			slash = find_last_dir_sep(path_k);
			string_list_append(&cookie_list,
					   slash ? slash + 1 : path_k);
			break;

		case IS_INSIDE_DOT_GIT:
		case IS_INSIDE_GITDIR:
			/* ignore all other paths inside of .git or gitdir */
			break;

		case IS_DOT_GIT:
		case IS_GITDIR:
			/*
			 * If .git directory is deleted or renamed away,
			 * we have to quit.
			 */
			if (ef_is_root_delete(event_flags[k])) {
				trace_printf_key(&trace_fsmonitor,
						 "event: gitdir removed");
				goto force_shutdown;
			}
			if (ef_is_root_renamed(event_flags[k])) {
				trace_printf_key(&trace_fsmonitor,
						 "event: gitdir renamed");
				goto force_shutdown;
			}
			break;

		case IS_WORKDIR_PATH:
			/* try to queue normal pathnames */

			if (trace_pass_fl(&trace_fsmonitor))
				log_flags_set(path_k, event_flags[k]);

			/*
			 * Ordinary metadata changes to the worktree root do not
			 * name a tracked path. Recursive and root-change events
			 * were handled above; do not read past the root's NUL.
			 */
			if (!*worktree_rel)
				break;

			/*
			 * Because of the implicit "binning" (the
			 * kernel calls us at a given frequency) and
			 * de-duping (the kernel is free to combine
			 * multiple events for a given pathname), an
			 * individual fsevent could be marked as both
			 * a file and directory.  Add it to the queue
			 * with both spellings so that the client will
			 * know how much to invalidate/refresh.
			 */

			if (event_flags[k] & (kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink)) {
				if (!batch)
					batch = fsmonitor_batch__new();
				my_add_path(batch, worktree_rel);
			}

			if (event_flags[k] & kFSEventStreamEventFlagItemIsDir) {
				strbuf_reset(&tmp);
				strbuf_addstr(&tmp, worktree_rel);
				strbuf_addch(&tmp, '/');

				if (!batch)
					batch = fsmonitor_batch__new();
				my_add_path(batch, tmp.buf);
			}

			break;

		case IS_OUTSIDE_CONE:
		default:
			trace_printf_key(&trace_fsmonitor,
					 "ignoring '%s'", path_k);
			break;
		}
	}

	free(resolved);
	if (begin)
		publish_begin = fsm_listen__trace_clock();
	fsmonitor_publish(state, batch, &cookie_list);
	if (begin)
		publish_ns = fsm_listen__trace_clock() - publish_begin;
	string_list_clear(&cookie_list, 0);
	goto done;

force_shutdown:
	free(resolved);
	fsmonitor_batch__free_list(batch);
	string_list_clear(&cookie_list, 0);

	pthread_mutex_lock(&data->dq_lock);
	data->shutdown_style = FORCE_SHUTDOWN;
	pthread_cond_broadcast(&data->dq_finished);
	pthread_mutex_unlock(&data->dq_lock);

done:
	strbuf_release(&tmp);
	if (begin) {
		struct fsm_callback_stats *stats = &data->callback_stats;
		uint64_t elapsed = fsm_listen__trace_clock() - begin;

		/* Keep work before a resync separate from its recovery cost. */
		if (resynced)
			fsm_listen__trace_stats(stats, "listener/pre_resync");
		stats->callbacks++;
		stats->input_events += num_of_events;
		stats->total_ns += elapsed;
		if (elapsed > stats->max_ns)
			stats->max_ns = elapsed;
		stats->publish_ns += publish_ns;
		if (publish_ns > stats->max_publish_ns)
			stats->max_publish_ns = publish_ns;
		if (resynced)
			fsm_listen__trace_stats(stats, "listener/resync_callback");
	}
	return;
}

/*
 * In the call to `FSEventStreamCreate()` to setup our watch, the
 * `latency` argument determines the frequency of calls to our callback
 * with new FS events.  Too slow and events get dropped; too fast and
 * we burn CPU unnecessarily.  Since it is rather obscure, I don't
 * think this needs to be a config setting.  I've done extensive
 * testing on my systems and chosen the value below.  It gives good
 * results and I've not seen any dropped events.
 *
 * With a latency of 0.1, I was seeing lots of dropped events during
 * the "touch 100000" files test within t/perf/p7519, but with a
 * latency of 0.001 I did not see any dropped events.  So I'm going
 * to assume that this is the "correct" value.
 *
 * https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate
 */

int fsm_listen__ctor(struct fsmonitor_daemon_state *state)
{
	FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagNoDefer |
		kFSEventStreamCreateFlagWatchRoot |
		kFSEventStreamCreateFlagFileEvents;
	FSEventStreamContext ctx = {
		0,
		state,
		NULL,
		NULL,
		NULL
	};
	struct fsm_listen_data *data;
	const void *dir_array[2];

	CALLOC_ARRAY(data, 1);
	state->listen_data = data;

	data->cfsr_worktree_path = CFStringCreateWithCString(
		NULL, state->path_worktree_watch.buf, kCFStringEncodingUTF8);
	dir_array[data->nr_paths_watching++] = data->cfsr_worktree_path;

	if (state->nr_paths_watching > 1) {
		data->cfsr_gitdir_path = CFStringCreateWithCString(
			NULL, state->path_gitdir_watch.buf,
			kCFStringEncodingUTF8);
		dir_array[data->nr_paths_watching++] = data->cfsr_gitdir_path;
	}

	data->cfar_paths_to_watch = CFArrayCreate(NULL, dir_array,
						  data->nr_paths_watching,
						  NULL);
	data->stream = FSEventStreamCreate(NULL, fsevent_callback, &ctx,
					   data->cfar_paths_to_watch,
					   kFSEventStreamEventIdSinceNow,
					   0.001, flags);
	if (!data->stream)
		goto failed;

	return 0;

failed:
	error(_("Unable to create FSEventStream."));

	FREE_AND_NULL(state->listen_data);
	return -1;
}

void fsm_listen__dtor(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;

	if (!state || !state->listen_data)
		return;

	data = state->listen_data;

	if (data->stream) {
		if (data->stream_started)
			FSEventStreamStop(data->stream);
		if (data->stream_scheduled)
			FSEventStreamInvalidate(data->stream);
		FSEventStreamRelease(data->stream);
	}

	if (data->dq)
		dispatch_release(data->dq);
	pthread_cond_destroy(&data->dq_finished);
	pthread_mutex_destroy(&data->dq_lock);

	FREE_AND_NULL(state->listen_data);
}

void fsm_listen__stop_async(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;

	data = state->listen_data;

	pthread_mutex_lock(&data->dq_lock);
	data->shutdown_style = SHUTDOWN_EVENT;
	pthread_cond_broadcast(&data->dq_finished);
	pthread_mutex_unlock(&data->dq_lock);
}

void fsm_listen__loop(struct fsmonitor_daemon_state *state)
{
	struct fsm_listen_data *data;

	data = state->listen_data;

	pthread_mutex_init(&data->dq_lock, NULL);
	pthread_cond_init(&data->dq_finished, NULL);
	data->dq = dispatch_queue_create("FSMonitor", NULL);

	FSEventStreamSetDispatchQueue(data->stream, data->dq);
	data->stream_scheduled = 1;

	if (!FSEventStreamStart(data->stream)) {
		error(_("Failed to start the FSEventStream"));
		goto force_error_stop_without_loop;
	}
	data->stream_started = 1;

	/*
	 * Our fs event listener is now running, so it's safe to start
	 * serving client requests.
	 */
	fsmonitor_listener_ready(state, 0);

	pthread_mutex_lock(&data->dq_lock);
	while (data->shutdown_style == WAITING)
		pthread_cond_wait(&data->dq_finished, &data->dq_lock);
	pthread_mutex_unlock(&data->dq_lock);

	/*
	 * FSEventStreamStop() prevents callbacks while the stream is stopped,
	 * but does not guarantee that a queued or active callback has finished.
	 * Drain the serial queue before returning; the caller then clears
	 * current_token_data.
	 *
	 * This thread is not running on dq and no longer holds dq_lock, so a
	 * callback can finish even if it initiated shutdown.
	 */
	FSEventStreamStop(data->stream);
	data->stream_started = 0;
	dispatch_sync_f(data->dq, NULL, fsm_listen__queue_marker);
	fsm_listen__trace_stats(&data->callback_stats, "listener/stop");

	switch (data->shutdown_style) {
	case FORCE_ERROR_STOP:
		state->listen_error_code = -1;
		/* fall thru */
	case FORCE_SHUTDOWN:
		fsmonitor_listener_ready(state, -1);
		ipc_server_stop_async(state->ipc_server_data);
		/* fall thru */
	case SHUTDOWN_EVENT:
	case WAITING:
	default:
		break;
	}
	return;

force_error_stop_without_loop:
	state->listen_error_code = -1;
	if (fsmonitor_listener_ready(state, -1))
		ipc_server_stop_async(state->ipc_server_data);
	return;
}

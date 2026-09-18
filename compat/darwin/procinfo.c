#include "git-compat-util.h"
#include "strbuf.h"
#include "strvec.h"
#include "trace2.h"
#include <sys/resource.h>
#include <sys/sysctl.h>

#if defined(RUSAGE_INFO_V2) && defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && \
	__MAC_OS_X_VERSION_MIN_REQUIRED >= 1090
# include <libproc.h>
# define HAVE_DARWIN_DISK_USAGE
#endif

/*
 * An arbitrarily chosen value to limit the depth of the ancestor chain.
 */
#define NR_PIDS_LIMIT 10

/*
 * Get the process name and parent PID for a given PID using sysctl().
 * Returns 0 on success, -1 on failure.
 */
static int get_proc_info(pid_t pid, struct strbuf *name, pid_t *ppid)
{
	int mib[4];
	struct kinfo_proc proc;
	size_t size = sizeof(proc);

	mib[0] = CTL_KERN;
	mib[1] = KERN_PROC;
	mib[2] = KERN_PROC_PID;
	mib[3] = pid;

	if (sysctl(mib, 4, &proc, &size, NULL, 0) < 0)
		return -1;

	if (size == 0)
		return -1;

	strbuf_addstr(name, proc.kp_proc.p_comm);
	*ppid = proc.kp_eproc.e_ppid;

	return 0;
}

/*
 * Recursively push process names onto the ancestry array.
 * We guard against cycles by limiting the depth to NR_PIDS_LIMIT.
 */
static void push_ancestry_name(struct strvec *names, pid_t pid, int depth)
{
	struct strbuf name = STRBUF_INIT;
	pid_t ppid;

	if (depth >= NR_PIDS_LIMIT)
		return;

	if (pid <= 0)
		return;

	if (get_proc_info(pid, &name, &ppid) < 0)
		goto cleanup;

	strvec_push(names, name.buf);

	/*
	 * Recurse to the parent process. Stop if ppid not valid
	 * or if we've reached ourselves (cycle).
	 */
	if (ppid && ppid != pid)
		push_ancestry_name(names, ppid, depth + 1);

cleanup:
	strbuf_release(&name);
}

static void trace_resource_usage(void)
{
	struct rusage usage;
#ifdef HAVE_DARWIN_DISK_USAGE
	struct rusage_info_v2 disk_usage;
	int saved_errno = errno;

	/* Accounted I/O requests, not necessarily physical device transfers. */
	if (!proc_pid_rusage(getpid(), RUSAGE_INFO_V2,
			     (rusage_info_t *)&disk_usage)) {
		if (disk_usage.ri_diskio_bytesread <= INTMAX_MAX)
			trace2_data_intmax("process", NULL, "darwin/disk_read_bytes",
					   (intmax_t)disk_usage.ri_diskio_bytesread);
		if (disk_usage.ri_diskio_byteswritten <= INTMAX_MAX)
			trace2_data_intmax("process", NULL, "darwin/disk_write_bytes",
					   (intmax_t)disk_usage.ri_diskio_byteswritten);
	}
	errno = saved_errno;
#endif

	if (getrusage(RUSAGE_SELF, &usage))
		return;

	trace2_data_intmax("process", NULL, "darwin/user_cpu_us",
			   (intmax_t)usage.ru_utime.tv_sec * 1000000 +
				   usage.ru_utime.tv_usec);
	trace2_data_intmax("process", NULL, "darwin/system_cpu_us",
			   (intmax_t)usage.ru_stime.tv_sec * 1000000 +
				   usage.ru_stime.tv_usec);
	trace2_data_intmax("process", NULL, "darwin/minor_faults", usage.ru_minflt);
	trace2_data_intmax("process", NULL, "darwin/major_faults", usage.ru_majflt);
}

void trace2_collect_process_info(enum trace2_process_info_reason reason)
{
	struct strvec names = STRVEC_INIT;

	if (!trace2_is_enabled())
		return;

	switch (reason) {
	case TRACE2_PROCESS_INFO_STARTUP:
		push_ancestry_name(&names, getppid(), 0);
		if (names.nr)
			trace2_cmd_ancestry(names.v);

		strvec_clear(&names);
		break;

	case TRACE2_PROCESS_INFO_EXIT:
		trace_resource_usage();
		break;

	default:
		BUG("trace2_collect_process_info: unknown reason '%d'", reason);
	}
}

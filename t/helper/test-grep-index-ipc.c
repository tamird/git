#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "grep-index.h"
#include "grep-index-ipc.h"
#include "hash.h"
#include "hex.h"
#include "pkt-line.h"
#include "replace-object.h"
#include "repository.h"
#include "setup.h"
#include "simple-ipc.h"
#include "strbuf.h"
#include "thread-utils.h"
#include "trace2.h"
#include "wrapper.h"
#if defined(SUPPORTS_SIMPLE_IPC) && !defined(GIT_WINDOWS_NATIVE)
#include "unix-socket.h"
#include "unix-stream-server.h"
#endif

static int test_query_wire(void)
{
	static const unsigned char exact[] = {
		0x47, 0x49, 0x51, 0x58,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x12, 0x34, 0x56, 0x78,
		0x00, 0x00, 0x00, 0x00,
	};
	static const unsigned char folded[] = {
		0x47, 0x49, 0x51, 0x58,
		0x00, 0x00, 0x00, 0x02,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x00, 0x00, 0x00, 0x01,
		0x12, 0x34, 0x56, 0x78,
		0x00, 0x00, 0x00, 0x00,
	};
	unsigned char invalid[sizeof(folded)];
	struct grep_index_query *query;
	struct strbuf serialized = STRBUF_INIT;

	query = grep_index_query_deserialize((const char *)exact,
					     sizeof(exact));
	if (!query || grep_index_query_serialize(query, &serialized) ||
	    serialized.len != sizeof(exact) ||
	    memcmp(serialized.buf, exact, sizeof(exact)))
		return error("exact grep query wire format changed");
	grep_index_query_free(query);
	strbuf_reset(&serialized);

	query = grep_index_query_deserialize((const char *)folded,
					     sizeof(folded));
	if (!query || grep_index_query_serialize(query, &serialized) ||
	    serialized.len != sizeof(folded) ||
	    memcmp(serialized.buf, folded, sizeof(folded)))
		return error("folded grep query wire format changed");
	grep_index_query_free(query);
	strbuf_release(&serialized);

	memcpy(invalid, folded, sizeof(invalid));
	invalid[11] = 2;
	query = grep_index_query_deserialize((const char *)invalid,
					     sizeof(invalid));
	if (query) {
		grep_index_query_free(query);
		return error("invalid grep query flags accepted");
	}
	return 0;
}

#ifdef SUPPORTS_SIMPLE_IPC

static const unsigned char query_protocol_wire[] = {
	0x47, 0x49, 0x51, 0x58, 0, 0, 0, 1,
	0, 0, 0, 1, 0, 0, 0, 1,
	0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0,
};

enum query_protocol_signature {
	QUERY_LEGACY_REQUEST = 0x47495251,
	QUERY_LEGACY_RESPONSE = 0x47495250,
	QUERY_CAPABILITY_REQUEST = 0x47494351,
	QUERY_CAPABILITY_RESPONSE = 0x47494350,
	QUERY_DIAGNOSTIC_REQUEST = 0x47494451,
	QUERY_DIAGNOSTIC_RESPONSE = 0x47494450,
};

enum query_protocol_scenario {
	QUERY_LEGACY,
	QUERY_CAP_MAGIC,
	QUERY_CAP_VERSION,
	QUERY_CAP_SHORT,
	QUERY_CAP_LONG,
	QUERY_VALID,
	QUERY_EMPTY,
	QUERY_MAGIC,
	QUERY_VERSION,
	QUERY_COUNT,
	QUERY_SHORT,
	QUERY_LONG,
	QUERY_CLASS,
	QUERY_ORIGIN_COUNT,
	QUERY_ORIGIN_SUM,
	QUERY_ORIGIN_OVERFLOW,
	QUERY_WAIT,
	QUERY_OLD_DIAGNOSTIC,
	QUERY_CAP_V1,
	QUERY_TIMING_ZERO,
	QUERY_TIMING_INVALID,
	QUERY_TIMING_MIXED,
	QUERY_TIMING_SUM_MAX,
	QUERY_TIMING_OVERFLOW,
	QUERY_EOF,
};

struct query_protocol_test {
	const char *name;
	const char *path;
	const struct strbuf *request;
	enum query_protocol_scenario scenario;
	int capture;
	unsigned int capability_requests;
	unsigned int legacy_requests;
	unsigned int diagnostic_requests;
	int bad_request;
};

static void query_protocol_put_u32(struct strbuf *buf, uint32_t value)
{
	unsigned char data[4];

	put_be32(data, value);
	strbuf_add(buf, data, sizeof(data));
}

static void query_protocol_response(struct query_protocol_test *test,
				    const char *request, size_t request_len,
				    struct strbuf *response)
{
	unsigned char data[58] = { 0 };
	uint32_t signature = request_len >= 4 ? get_be32(request) : 0;
	uint32_t version = test->capture &&
		test->scenario != QUERY_OLD_DIAGNOSTIC &&
		test->scenario != QUERY_CAP_V1 ? 2 : 1;
	size_t response_len;

	if (signature == QUERY_CAPABILITY_REQUEST) {
		test->capability_requests++;
		if (request_len != 8 ||
		    get_be32(request + 4) !=
			    (test->capture && test->capability_requests == 1 ? 2 : 1)) {
			test->bad_request = 1;
			return;
		}
		if (test->scenario == QUERY_LEGACY ||
		    (test->scenario == QUERY_OLD_DIAGNOSTIC &&
		     get_be32(request + 4) == 2))
			return;
		put_be32(data, QUERY_CAPABILITY_RESPONSE);
		put_be32(data + 4, version);
		response_len = 8;
		switch (test->scenario) {
		case QUERY_CAP_MAGIC:
			put_be32(data, QUERY_LEGACY_RESPONSE);
			break;
		case QUERY_CAP_VERSION:
			put_be32(data + 4, test->capture ? 3 : 2);
			break;
		case QUERY_CAP_SHORT:
			response_len--;
			break;
		case QUERY_CAP_LONG:
			response_len++;
			break;
		default:
			break;
		}
		strbuf_add(response, data, response_len);
		return;
	}

	if (signature == QUERY_LEGACY_REQUEST)
		test->legacy_requests++;
	else if (signature == QUERY_DIAGNOSTIC_REQUEST)
		test->diagnostic_requests++;
	else {
		test->bad_request = 1;
		return;
	}
	if (signature == QUERY_LEGACY_REQUEST)
		version = 1;
	if (request_len != test->request->len ||
	    get_be32(request + 4) != version ||
	    memcmp(request + 8, test->request->buf + 8, request_len - 8)) {
		test->bad_request = 1;
		return;
	}
	if (signature == QUERY_LEGACY_REQUEST) {
		put_be32(data, QUERY_LEGACY_RESPONSE);
		put_be32(data + 4, 1);
		put_be32(data + 8, 1);
		data[12] = GREP_INDEX_IPC_MAYBE;
		strbuf_add(response, data, 13);
		return;
	}
	if (test->scenario == QUERY_EMPTY)
		return;

	put_be32(data, QUERY_DIAGNOSTIC_RESPONSE);
	put_be32(data + 4, version);
	put_be32(data + 8, 1);
	put_be32(data + 16, 1); /* ready_reused */
	data[32] = GREP_INDEX_IPC_MAYBE;
	response_len = 33;
	if (version == 2) {
		put_be64(data + 33, 1001);
		put_be64(data + 41, 2002);
		put_be64(data + 49, 3003);
		response_len += 24;
	}
	switch (test->scenario) {
	case QUERY_MAGIC:
		put_be32(data, QUERY_LEGACY_RESPONSE);
		break;
	case QUERY_VERSION:
		put_be32(data + 4, version + 1);
		break;
	case QUERY_COUNT:
		put_be32(data + 8, 2);
		break;
	case QUERY_SHORT:
		response_len--;
		break;
	case QUERY_LONG:
		response_len++;
		break;
	case QUERY_CLASS:
		data[32] = GREP_INDEX_IPC_MAYBE + 1;
		break;
	case QUERY_ORIGIN_COUNT:
		put_be32(data + 16, 2);
		break;
	case QUERY_ORIGIN_SUM:
		put_be32(data + 16, 0);
		break;
	case QUERY_ORIGIN_OVERFLOW:
		put_be32(data + 12, UINT32_MAX);
		put_be32(data + 16, 2);
		break;
	case QUERY_WAIT:
		put_be32(data + 12, 1);
		put_be32(data + 16, 0);
		put_be32(data + 28, 1);
		break;
	case QUERY_TIMING_ZERO:
		memset(data + 33, 0, 24);
		break;
	case QUERY_TIMING_INVALID:
		memset(data + 33, 0xff, 24);
		break;
	case QUERY_TIMING_MIXED:
		put_be64(data + 41, UINT64_MAX);
		break;
	case QUERY_TIMING_SUM_MAX:
	case QUERY_TIMING_OVERFLOW:
		put_be64(data + 33, UINT64_MAX - 10);
		put_be64(data + 41, 7);
		put_be64(data + 49, test->scenario == QUERY_TIMING_SUM_MAX ? 3 : 4);
		break;
	default:
		break;
	}
	strbuf_add(response, data, response_len);
}

static int query_protocol_reply(void *data, const char *request,
				size_t request_len, ipc_server_reply_cb *reply,
				struct ipc_server_reply_data *reply_data)
{
	struct query_protocol_test *test = data;
	struct strbuf response = STRBUF_INIT;
	int result = 0;

	query_protocol_response(test, request, request_len, &response);
	if (response.len)
		result = reply(reply_data, response.buf, response.len);
	strbuf_release(&response);
	return result;
}

static int query_protocol_check_path(const char *path)
{
	struct stat st;

	if (!lstat(path, &st) || errno != ENOENT)
		return error("query protocol endpoint must not exist: %s", path);
	return 0;
}

static int query_protocol_check(struct query_protocol_test *test,
				int result, unsigned char value,
				unsigned int capabilities,
				unsigned int legacy,
				unsigned int diagnostic, int success)
{
	if (test->capability_requests != capabilities)
		return error("%s: expected %u capability requests, got %u",
			     test->name, capabilities, test->capability_requests);
	if (test->bad_request || test->legacy_requests != legacy ||
	    test->diagnostic_requests != diagnostic)
		return error("%s: unexpected query request sequence (%u, %u, %u)",
			     test->name, test->capability_requests,
			     test->legacy_requests, test->diagnostic_requests);
	if (success ? result || value != GREP_INDEX_IPC_MAYBE :
		      result != -1 || value != 0xa5)
		return error("%s: unexpected query result %d/%u",
			     test->name, result, value);
	return 0;
}

static int query_protocol_query(const struct grep_index_query *query,
				const struct object_id *oid,
				unsigned char *value, int expected_backend,
				unsigned int expected_capability,
				struct grep_index_ipc_query_trace *trace)
{
	int result;

	/* Bound each call's records without joining results from old queries. */
	trace2_data_intmax("test-grep-index-ipc", the_repository,
			   "query-protocol/expected", expected_backend);
	trace2_data_intmax("test-grep-index-ipc", the_repository,
			   "query-protocol/capability", expected_capability);
	result = grep_index_ipc_query_with_max_parallel_requests(
		the_repository, query, oid, 1, value, 0, trace);
	trace2_data_intmax("test-grep-index-ipc", the_repository,
			   "query-protocol/end", 1);
	return result;
}

static int query_protocol_no_listener(const char *path,
				      const struct grep_index_query *query,
				      const struct object_id *oid, int capture)
{
	struct grep_index_ipc_query_trace trace;
	unsigned char value = 0xa5;
	int result;

	if (query_protocol_check_path(path))
		return -1;
	result = query_protocol_query(query, oid, &value, 0, 2,
				      capture ? &trace : NULL);
	if (result != -1 || value != 0xa5)
		return error("missing query endpoint changed result %d/%u",
			     result, value);
	if (capture && (trace.probe_attempts != 1 || trace.diagnostic_version ||
			trace.requests[0].server.available))
		return error("missing endpoint retained server timing");
	return 0;
}

static int query_protocol_run(struct query_protocol_test *test,
			      const struct grep_index_query *query,
			      const struct object_id *oid, int traced,
			      unsigned int expected_capability)
{
	struct ipc_server_opts opts = {
		.nr_threads = 1,
		.max_request_size = 64 * 1024 * 1024,
		.uds_disallow_chdir = 1,
	};
	struct ipc_server_data *server = NULL;
	struct grep_index_ipc_query_trace trace;
	unsigned char value = 0xa5;
	int legacy = !traced || test->scenario <= QUERY_CAP_LONG;
	int success = legacy || test->scenario == QUERY_VALID ||
		test->scenario == QUERY_OLD_DIAGNOSTIC ||
		test->scenario == QUERY_CAP_V1 ||
		(test->scenario >= QUERY_TIMING_ZERO &&
		 test->scenario <= QUERY_TIMING_OVERFLOW);
	unsigned int capabilities = !traced ? 0 :
		test->capture && (test->scenario == QUERY_LEGACY ||
				  test->scenario == QUERY_OLD_DIAGNOSTIC) ? 2 : 1;
	unsigned int version = legacy ? 0 :
		test->capture && test->scenario != QUERY_OLD_DIAGNOSTIC &&
		test->scenario != QUERY_CAP_V1 ? 2 : 1;
	int result;

	if (query_protocol_check_path(test->path) ||
	    ipc_server_init_async(&server, test->path, &opts,
				  query_protocol_reply, test))
		return error("could not create %s query endpoint", test->name);
	ipc_server_start_async(server);
	result = query_protocol_query(query, oid, &value,
				      legacy ? 0 : success ? 1 : 2,
				      expected_capability,
				      test->capture ? &trace : NULL);
	ipc_server_stop_async(server);
	ipc_server_await(server);
	ipc_server_free(server);
	if (query_protocol_check(test, result, value, capabilities,
				 legacy, !legacy, success))
		return -1;
	if (test->capture) {
		const struct grep_index_ipc_server_trace *server =
			&trace.requests[0].server;
		int available = traced && version == 2 && success;
		int invalid = available && test->scenario >= QUERY_TIMING_INVALID &&
			test->scenario <= QUERY_TIMING_OVERFLOW;
		int durations = available && !invalid &&
			test->scenario != QUERY_TIMING_ZERO;

		if (trace.probe_attempts != capabilities ||
		    trace.diagnostic_version != version ||
		    trace.probe_outcome != expected_capability ||
		    server->available != available ||
		    server->timing_invalid != invalid ||
		    server->pre_reply_ns != (durations ? 1001 : 0) ||
		    server->reply_write_ns != (durations ? 2002 : 0) ||
		    server->cleanup_ns != (durations ? 3003 : 0))
			return error("%s: incorrect captured server timing", test->name);
		if (traced && (trace.requests_planned != 1 ||
			       trace.requests_started != 1 ||
			       trace.requests_validated != success ||
			       trace.backend_available != !legacy ||
			       trace.ready_reused != (!legacy && success) ||
			       trace.persistent || trace.cold_attempt ||
			       trace.unavailable_prebuild || trace.waited))
			return error("%s: captured backend counts changed", test->name);
	}
	return 0;
}

static int query_protocol_send(const char *path, const struct strbuf *request,
			       struct strbuf *response)
{
	struct ipc_client_connect_options options =
		IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct ipc_client_connection *connection = NULL;
	int result = -1;

	options.wait_if_busy = 1;
	options.uds_disallow_chdir = 1;
	if (ipc_client_try_connect(path, &options, &connection) ==
	    IPC_STATE__LISTENING)
		result = ipc_client_send_command_to_connection_gently(
			connection, request->buf, request->len, response);
	ipc_client_close_connection(connection);
	return result;
}

static int query_protocol_server(const char *path,
				 const struct strbuf *request)
{
	struct grep_index_ipc_server *server = NULL;
	struct strbuf response = STRBUF_INIT;
	struct strbuf probe = STRBUF_INIT;
	struct strbuf diagnostic = STRBUF_INIT;
	unsigned char expected[33] = { 0 };
	const char *failure = "legacy query response changed";
	char *worker_path = grep_index_ipc_worker_path(the_repository);
	int result = -1;

	put_be32(expected, QUERY_LEGACY_RESPONSE);
	put_be32(expected + 4, 1);
	put_be32(expected + 8, 1);
	expected[12] = GREP_INDEX_IPC_UNKNOWN;
	if (query_protocol_check_path(path) ||
	    query_protocol_check_path(worker_path) ||
	    grep_index_ipc_server_init(&server, repo_get_git_dir(the_repository),
				      path, worker_path, 1))
		goto cleanup;
	grep_index_ipc_server_start(server);
	if (query_protocol_send(path, request, &response) ||
	    response.len != 13 || memcmp(response.buf, expected, 13))
		goto stop;

	strbuf_addbuf(&diagnostic, request);
	put_be32(diagnostic.buf, QUERY_DIAGNOSTIC_REQUEST);
	for (uint32_t version = 1; version <= 2; version++) {
		size_t reply_size = sizeof(expected) + (version == 2 ? 24 : 0);

		/* Old clients must retain their exact capability and reply. */
		strbuf_reset(&probe);
		query_protocol_put_u32(&probe, QUERY_CAPABILITY_REQUEST);
		query_protocol_put_u32(&probe, version);
		strbuf_reset(&response);
		failure = version == 1 ? "capability v1 response changed" :
					"missing capability v2 response";
		if (query_protocol_send(path, &probe, &response) ||
		    response.len != 8 ||
		    get_be32(response.buf) != QUERY_CAPABILITY_RESPONSE ||
		    get_be32(response.buf + 4) != version)
			goto stop;

		put_be32(diagnostic.buf + 4, version);
		memset(expected, 0, sizeof(expected));
		put_be32(expected, QUERY_DIAGNOSTIC_RESPONSE);
		put_be32(expected + 4, version);
		put_be32(expected + 8, 1);
		put_be32(expected + 24, 1); /* unavailable_prebuild */
		expected[32] = GREP_INDEX_IPC_UNKNOWN;
		strbuf_reset(&response);
		failure = version == 1 ? "diagnostic v1 response changed" :
					"missing diagnostic v2 timing footer";
		if (query_protocol_send(path, &diagnostic, &response) ||
		    response.len != reply_size ||
		    memcmp(response.buf, expected, sizeof(expected)))
			goto stop;
		if (version == 2) {
			uint64_t pre_reply = get_be64(response.buf + 33);
			uint64_t reply_write = get_be64(response.buf + 41);
			uint64_t cleanup = get_be64(response.buf + 49);

			failure = "invalid server timing footer";
			if (pre_reply == UINT64_MAX || reply_write == UINT64_MAX ||
			    cleanup == UINT64_MAX) {
				if (pre_reply != UINT64_MAX ||
				    reply_write != UINT64_MAX ||
				    cleanup != UINT64_MAX)
					goto stop;
			} else if (reply_write >= UINT64_MAX - pre_reply ||
				   cleanup >= UINT64_MAX - pre_reply - reply_write) {
				goto stop;
			}
		}
	}
	result = 0;

stop:
	grep_index_ipc_server_stop(server);
	grep_index_ipc_server_await(server);
	grep_index_ipc_server_free(server);
cleanup:
	strbuf_release(&diagnostic);
	strbuf_release(&probe);
	strbuf_release(&response);
	free(worker_path);
	return result ? error("%s", failure) : 0;
}

#ifndef GIT_WINDOWS_NATIVE
struct query_protocol_eof {
	struct query_protocol_test test;
	struct unix_ss_socket *socket;
	enum query_protocol_signature drop_signature;
	int abort_fd;
	int io_error;
};

static void *query_protocol_eof_thread(void *data)
{
	struct query_protocol_eof *eof = data;
	struct strbuf request = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;
	sigset_t sigpipe;

	/* Match simple-ipc's thread-local protection against peer hangups. */
	sigemptyset(&sigpipe);
	sigaddset(&sigpipe, SIGPIPE);
	if (pthread_sigmask(SIG_BLOCK, &sigpipe, NULL)) {
		eof->io_error = 1;
		goto cleanup;
	}

	for (;;) {
		struct pollfd pollfds[] = {
			{ .fd = eof->socket->fd_socket, .events = POLLIN },
			{ .fd = eof->abort_fd, .events = POLLIN },
		};
		int fd;
		int stop;

		if (poll(pollfds, ARRAY_SIZE(pollfds), -1) < 0) {
			if (errno == EINTR)
				continue;
			eof->io_error = 1;
			break;
		}
		if (pollfds[1].revents)
			break;
		if (!(pollfds[0].revents & POLLIN)) {
			eof->io_error = 1;
			break;
		}
		fd = accept(eof->socket->fd_socket, NULL, NULL);
		if (fd < 0) {
			if (errno == EINTR)
				continue;
			eof->io_error = 1;
			break;
		}
		strbuf_reset(&request);
		strbuf_reset(&response);
		if (read_packetized_to_strbuf_limit(
			    fd, &request,
			    PACKET_READ_GENTLE_ON_EOF |
				    PACKET_READ_GENTLE_ON_READ_ERROR,
			    64 * 1024 * 1024) < 0) {
			eof->io_error = 1;
			close(fd);
			continue;
		}
		stop = request.len == 4 && !memcmp(request.buf, "STOP", 4);
		if (!stop)
			query_protocol_response(&eof->test, request.buf,
						request.len, &response);
		if (!stop && request.len >= 4 &&
		    get_be32(request.buf) == eof->drop_signature) {
			/* The complete request arrived; omit the response flush. */
			close(fd);
			continue;
		}
		if (write_packetized_from_buf_no_flush(
			    response.buf, response.len, fd) < 0 ||
		    packet_flush_gently(fd) < 0)
			eof->io_error = 1;
		close(fd);
		if (stop)
			break;
	}

cleanup:
	/* A fatal worker error must also make subsequent connections fail. */
	unix_ss_free(eof->socket);
	strbuf_release(&response);
	strbuf_release(&request);
	return NULL;
}

static int query_protocol_eof(const char *path,
			      const struct strbuf *request,
			      const struct grep_index_query *query,
			      const struct object_id *oid,
			      enum query_protocol_signature drop_signature,
			      int capture)
{
	int capability_eof = drop_signature == QUERY_CAPABILITY_REQUEST;
	struct unix_stream_listen_opts opts = {
		.listen_backlog_size = 5,
		.disallow_chdir = 1,
	};
	struct query_protocol_eof eof = {
		.test = {
			.name = capability_eof ? "capability EOF" : "diagnostic EOF",
			.path = path,
			.request = request,
			.scenario = QUERY_EOF,
			.capture = capture,
		},
		.drop_signature = drop_signature,
		.abort_fd = -1,
	};
	struct unix_ss_socket *socket = NULL;
	struct grep_index_ipc_query_trace trace;
	struct strbuf stop = STRBUF_INIT;
	struct strbuf response = STRBUF_INIT;
	pthread_t thread;
	int abort_pipe[2];
	unsigned char value = 0xa5;
	int result, stop_result;

	if (query_protocol_check_path(path))
		return -1;
	if (unix_ss_create(path, &opts, 0, &socket))
		return error("could not create EOF query endpoint");
	if (pipe(abort_pipe)) {
		unix_ss_free(socket);
		return error("could not create EOF query shutdown pipe");
	}
	eof.socket = socket;
	eof.abort_fd = abort_pipe[0];
	if (pthread_create(&thread, NULL, query_protocol_eof_thread, &eof)) {
		close(abort_pipe[0]);
		close(abort_pipe[1]);
		unix_ss_free(socket);
		return error("could not start EOF query endpoint");
	}
	/* The worker now owns both the listener and its pathname. */
	result = query_protocol_query(query, oid, &value,
				      capability_eof ? 0 : 2,
				      capability_eof ? 3 : 1,
				      capture ? &trace : NULL);
	/* A replay must finish before this synchronous call returns. */
	strbuf_addstr(&stop, "STOP");
	stop_result = query_protocol_send(path, &stop, &response);
	if (stop_result)
		write_in_full(abort_pipe[1], "x", 1);
	pthread_join(thread, NULL);
	close(abort_pipe[0]);
	close(abort_pipe[1]);
	strbuf_release(&stop);
	if (stop_result || response.len || eof.io_error) {
		strbuf_release(&response);
		return error("EOF query endpoint did not stop cleanly");
	}
	strbuf_release(&response);
	if (query_protocol_check(&eof.test, result, value, 1,
				 capability_eof, !capability_eof, capability_eof))
		return -1;
	if (capture && (trace.probe_attempts != 1 ||
			trace.diagnostic_version != (capability_eof ? 0 : 2) ||
			trace.requests[0].server.available))
		return error("EOF query retained server timing or retried a probe");
	return 0;
}
#endif

static int test_query_protocol(int traced, int capture)
{
	/* Pin the numeric Trace2 contract independently of the private producer. */
	static const struct query_protocol_case {
		enum query_protocol_scenario scenario;
		const char *name;
		unsigned int expected_capability;
	} scenarios[] = {
		{ QUERY_LEGACY, "legacy capability fallback", 4 },
		{ QUERY_CAP_MAGIC, "capability magic", 6 },
		{ QUERY_CAP_VERSION, "capability version", 7 },
		{ QUERY_CAP_SHORT, "short capability", 5 },
		{ QUERY_CAP_LONG, "long capability", 5 },
		{ QUERY_VALID, "valid diagnostic", 1 },
		{ QUERY_EMPTY, "empty diagnostic", 1 },
		{ QUERY_MAGIC, "diagnostic magic", 1 },
		{ QUERY_VERSION, "diagnostic version", 1 },
		{ QUERY_COUNT, "diagnostic count", 1 },
		{ QUERY_SHORT, "short diagnostic", 1 },
		{ QUERY_LONG, "long diagnostic", 1 },
		{ QUERY_CLASS, "diagnostic class", 1 },
		{ QUERY_ORIGIN_COUNT, "diagnostic origin count", 1 },
		{ QUERY_ORIGIN_SUM, "diagnostic origin sum", 1 },
		{ QUERY_ORIGIN_OVERFLOW, "diagnostic origin overflow", 1 },
		{ QUERY_WAIT, "diagnostic wait count", 1 },
	}, captured_scenarios[] = {
		{ QUERY_LEGACY, "captured legacy fallback", 4 },
		{ QUERY_OLD_DIAGNOSTIC, "captured old diagnostic fallback", 1 },
		{ QUERY_CAP_V1, "direct diagnostic v1 advertisement", 1 },
		{ QUERY_CAP_MAGIC, "captured capability magic", 6 },
		{ QUERY_CAP_VERSION, "captured capability version", 7 },
		{ QUERY_CAP_SHORT, "captured short capability", 5 },
		{ QUERY_CAP_LONG, "captured long capability", 5 },
		{ QUERY_VALID, "valid timing footer", 1 },
		{ QUERY_MAGIC, "timing reply magic", 1 },
		{ QUERY_VERSION, "timing reply version", 1 },
		{ QUERY_COUNT, "timing reply count", 1 },
		{ QUERY_SHORT, "short timing footer", 1 },
		{ QUERY_LONG, "long timing footer", 1 },
		{ QUERY_CLASS, "invalid class with timing footer", 1 },
		{ QUERY_ORIGIN_SUM, "timing backend sum", 1 },
		{ QUERY_ORIGIN_OVERFLOW, "timing backend overflow", 1 },
		{ QUERY_WAIT, "timing backend wait count", 1 },
		{ QUERY_TIMING_ZERO, "zero server durations", 1 },
		{ QUERY_TIMING_INVALID, "unavailable server clock", 1 },
		{ QUERY_TIMING_MIXED, "mixed timing sentinels", 1 },
		{ QUERY_TIMING_SUM_MAX, "reserved timing sum", 1 },
		{ QUERY_TIMING_OVERFLOW, "overflowing timing sum", 1 },
	};
	const struct query_protocol_case *cases =
		capture ? captured_scenarios : scenarios;
	size_t cases_nr = capture ? ARRAY_SIZE(captured_scenarios) :
				    ARRAY_SIZE(scenarios);
	struct grep_index_query *query;
	struct strbuf request = STRBUF_INIT;
	struct object_id oid;
	char *path;
	int result = -1;

	setup_git_directory(the_repository);
	if (!!trace2_is_enabled() != traced)
		return error("query protocol tracing mode is not %d", traced);
	query = grep_index_query_deserialize(
		(const char *)query_protocol_wire, sizeof(query_protocol_wire));
	if (!query)
		return error("could not decode protocol test query");
	oidclr(&oid, the_repository->hash_algo);
	query_protocol_put_u32(&request, QUERY_LEGACY_REQUEST);
	query_protocol_put_u32(&request, 1);
	query_protocol_put_u32(&request, the_repository->hash_algo->format_id);
	query_protocol_put_u32(&request, sizeof(query_protocol_wire));
	query_protocol_put_u32(&request, 1);
	strbuf_add(&request, query_protocol_wire, sizeof(query_protocol_wire));
	strbuf_add(&request, oid.hash, the_repository->hash_algo->rawsz);
	path = grep_index_ipc_path(the_repository);
	if (!traced) {
		struct query_protocol_test test = {
			.name = "untraced legacy query",
			.capture = 1,
			.path = path,
			.request = &request,
			.scenario = QUERY_VALID,
		};

		if (query_protocol_run(&test, query, &oid, 0, 0) ||
		    query_protocol_server(path, &request))
			goto cleanup;
	} else {
		if (query_protocol_no_listener(path, query, &oid, capture))
			goto cleanup;
		for (size_t i = 0; i < cases_nr; i++) {
			struct query_protocol_test test = {
				.name = cases[i].name,
				.path = path,
				.request = &request,
				.scenario = cases[i].scenario,
				.capture = capture,
			};

			if (query_protocol_run(&test, query, &oid, 1,
					       cases[i].expected_capability))
				goto cleanup;
		}
#ifndef GIT_WINDOWS_NATIVE
		if (query_protocol_eof(path, &request, query, &oid,
				       QUERY_CAPABILITY_REQUEST, capture) ||
		    query_protocol_eof(path, &request, query, &oid,
				       QUERY_DIAGNOSTIC_REQUEST, capture))
			goto cleanup;
#endif
	}
	result = 0;

cleanup:
	free(path);
	strbuf_release(&request);
	grep_index_query_free(query);
	return result;
}

struct query_wait_test {
	pthread_mutex_t mutex;
	pthread_cond_t cond;
	struct timespec deadline;
	struct object_id oid;
	unsigned int claimed;
	unsigned int observed;
	int released;
	int bad_event;
	int wait_error;
};

struct query_wait_worker {
	struct query_wait_test *test;
	const struct grep_index_query *query;
	const char *name;
	unsigned char value;
	int result;
	int done;
};

static void query_wait_observer(enum grep_index_memory_build_event event,
				const struct object_id *oid, int ignore_case,
				void *data)
{
	struct query_wait_test *test = data;

	pthread_mutex_lock(&test->mutex);
	if (!oideq(oid, &test->oid) || ignore_case) {
		test->bad_event = 1;
		test->released = 1;
		pthread_cond_broadcast(&test->cond);
	} else if (event == GREP_INDEX_MEMORY_BUILD_CLAIMED) {
		if (++test->claimed != 1) {
			test->bad_event = 1;
			test->released = 1;
		}
		pthread_cond_broadcast(&test->cond);
		while (!test->released) {
			int err = pthread_cond_timedwait(
				&test->cond, &test->mutex, &test->deadline);

			if (err) {
				test->wait_error = err;
				test->released = 1;
				pthread_cond_broadcast(&test->cond);
			}
		}
	} else if (event == GREP_INDEX_MEMORY_WAIT_OBSERVED) {
		/* This callback holds the index mutex: signal, but never wait. */
		if (++test->observed != 1) {
			test->bad_event = 1;
			test->released = 1;
		}
		pthread_cond_broadcast(&test->cond);
	} else {
		test->bad_event = 1;
		test->released = 1;
		pthread_cond_broadcast(&test->cond);
	}
	pthread_mutex_unlock(&test->mutex);
}

static void *query_wait_worker(void *data)
{
	struct query_wait_worker *worker = data;

	trace2_thread_start(worker->name);
	worker->value = 0xa5;
	worker->result = grep_index_ipc_query(
		the_repository, worker->query, &worker->test->oid, 1,
		&worker->value);
	pthread_mutex_lock(&worker->test->mutex);
	worker->done = 1;
	pthread_cond_broadcast(&worker->test->cond);
	pthread_mutex_unlock(&worker->test->mutex);
	trace2_thread_exit();
	return NULL;
}

static int query_wait_for_event(struct query_wait_test *test,
				struct query_wait_worker *worker, int waiter)
{
	unsigned int *count = waiter ? &test->observed : &test->claimed;
	int result;

	pthread_mutex_lock(&test->mutex);
	while (!*count && !worker->done && !test->bad_event &&
	       !test->wait_error) {
		int err = pthread_cond_timedwait(
			&test->cond, &test->mutex, &test->deadline);

		if (err) {
			test->wait_error = err;
			test->released = 1;
			pthread_cond_broadcast(&test->cond);
		}
	}
	result = *count == 1 && !test->bad_event && !test->wait_error;
	pthread_mutex_unlock(&test->mutex);
	return result;
}

static void query_wait_release(struct query_wait_test *test)
{
	pthread_mutex_lock(&test->mutex);
	test->released = 1;
	pthread_cond_broadcast(&test->cond);
	pthread_mutex_unlock(&test->mutex);
}

static int test_query_wait(const char *hex)
{
	struct query_wait_test test = { 0 };
	struct grep_index_ipc_server *server = NULL;
	struct grep_index_query *query = NULL;
	struct query_wait_worker workers[2] = {
		{ .test = &test, .name = "grep-index-builder-client" },
		{ .test = &test, .name = "grep-index-waiter-client" },
	};
	pthread_t threads[2];
	struct timeval now;
	char *path = NULL, *worker_path = NULL;
	size_t started = 0;
	size_t joined = 0;
	int mutex_initialized = 0, cond_initialized = 0;
	int err;
	int observed = 0;
	int result = -1;

	setup_git_directory(the_repository);
	if (!trace2_is_enabled() ||
	    strlen(hex) != the_repository->hash_algo->hexsz ||
	    get_oid_hex_algop(hex, &test.oid, the_repository->hash_algo))
		return error("query-wait requires tracing and one object ID");
	query = grep_index_query_deserialize(
		(const char *)query_protocol_wire, sizeof(query_protocol_wire));
	if (!query)
		return error("could not decode wait test query");
	workers[0].query = workers[1].query = query;
	prepare_replace_object(the_repository);
	err = pthread_mutex_init(&test.mutex, NULL);
	if (err) {
		error("could not initialize wait mutex: %s", strerror(err));
		goto cleanup;
	}
	mutex_initialized = 1;
	err = pthread_cond_init(&test.cond, NULL);
	if (err) {
		error("could not initialize wait condition: %s", strerror(err));
		goto cleanup;
	}
	cond_initialized = 1;
	if (gettimeofday(&now, NULL)) {
		error_errno("could not initialize wait deadline");
		goto cleanup;
	}
	test.deadline.tv_sec = now.tv_sec + 30;
	test.deadline.tv_nsec = now.tv_usec * 1000;
	path = grep_index_ipc_path(the_repository);
	worker_path = grep_index_ipc_worker_path(the_repository);
	if (query_protocol_check_path(path) ||
	    query_protocol_check_path(worker_path) ||
	    grep_index_ipc_server_init(&server, repo_get_git_dir(the_repository),
				      path, worker_path, 2))
		goto cleanup;
	grep_index_ipc_server_set_build_observer_for_test(
		server, query_wait_observer, &test);
	grep_index_ipc_server_start(server);
	if (pthread_create(&threads[0], NULL, query_wait_worker, &workers[0]))
		goto join;
	started = 1;
	if (!query_wait_for_event(&test, &workers[0], 0))
		goto join;
	if (pthread_create(&threads[1], NULL, query_wait_worker, &workers[1]))
		goto join;
	started = 2;
	observed = query_wait_for_event(&test, &workers[1], 1);

join:
	query_wait_release(&test);
	for (size_t i = 0; i < started; i++) {
		err = pthread_join(threads[i], NULL);
		if (err)
			die("could not join wait client: %s", strerror(err));
		joined++;
	}
	grep_index_ipc_server_stop(server);
	grep_index_ipc_server_await(server);
	grep_index_ipc_server_set_build_observer_for_test(server, NULL, NULL);
	grep_index_ipc_server_free(server);
	if (observed && joined == 2 && test.claimed == 1 &&
	    test.observed == 1 && !test.bad_event && !test.wait_error &&
	    !workers[0].result && !workers[1].result &&
	    workers[0].value != GREP_INDEX_IPC_UNKNOWN &&
	    workers[0].value <= GREP_INDEX_IPC_MAYBE &&
	    workers[0].value == workers[1].value) {
		printf("build claimed: %u\n"
		       "wait observed: %u\n"
		       "workers joined: %"PRIuMAX"\n",
		       test.claimed, test.observed, (uintmax_t)joined);
		result = 0;
	}

cleanup:
	free(worker_path);
	free(path);
	if (cond_initialized)
		pthread_cond_destroy(&test.cond);
	if (mutex_initialized)
		pthread_mutex_destroy(&test.mutex);
	grep_index_query_free(query);
	return result ? error("query-wait did not complete the observed build") : 0;
}
#endif

int cmd__grep_index_ipc(int argc, const char **argv)
{
	uint64_t lease_id;
	int target;
	int requested;

	if (argc == 2 && !strcmp(argv[1], "query-wire"))
		return test_query_wire();
#ifdef SUPPORTS_SIMPLE_IPC
	if (argc == 3 && !strcmp(argv[1], "query-wait"))
		return test_query_wait(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "query-protocol") &&
	    (!strcmp(argv[2], "traced") || !strcmp(argv[2], "untraced") ||
	     !strcmp(argv[2], "captured")))
		return test_query_protocol(strcmp(argv[2], "untraced") != 0,
					   !strcmp(argv[2], "captured"));
#endif
	if (argc != 5 || strtol_i(argv[1], 10, &requested) ||
	    requested < 1)
		die("usage: test-tool grep-index-ipc query-wire\n"
		    "   or: test-tool grep-index-ipc query-protocol <traced|untraced|captured>\n"
		    "   or: test-tool grep-index-ipc query-wait <object-id>\n"
		    "   or: test-tool grep-index-ipc <workers> "
		    "<start> <acquired> <release>");

	setup_git_directory(the_repository);
	while (access(argv[2], F_OK))
		sleep_millisec(10);
	if (grep_index_ipc_acquire_workers(
		    the_repository, requested, 0, &lease_id, &target))
		die("could not acquire grep workers");
	while (access(argv[4], F_OK)) {
		write_file(argv[3], "%d\n", target);
		sleep_millisec(10);
		if (grep_index_ipc_update_workers(
			    the_repository, lease_id, requested,
			    target, &target))
			die("could not update grep workers");
	}
	grep_index_ipc_release_workers(the_repository, lease_id);
	return 0;
}

#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "grep-index.h"
#include "csum-file.h"
#include "environment.h"
#include "grep.h"
#include "hashmap.h"
#include "hash-lookup.h"
#include "hex.h"
#include "lockfile.h"
#include "odb.h"
#include "odb/source.h"
#include "oid-array.h"
#include "path.h"
#include "progress.h"
#include "read-cache-ll.h"
#include "replace-object.h"
#include "repository.h"
#include "sparse-index.h"
#include "strbuf.h"
#include "string-list.h"
#include "tempfile.h"
#include "thread-utils.h"
#include "worktree.h"
#include "write-or-die.h"
#include "wrapper.h"

#define GREP_INDEX_SIGNATURE 0x47494458
#define GREP_INDEX_VERSION 2
#define GREP_INDEX_TRANSPOSED_VERSION 3
#define GREP_INDEX_HEADER_SIZE 16
#define GREP_INDEX_TRANSPOSED_HEADER_SIZE 32
#define GREP_INDEX_FANOUT_SIZE (256 * sizeof(uint32_t))
#define GREP_INDEX_TRANSPOSED_LOCATOR_SIZE (2 * sizeof(uint32_t))
#define GREP_INDEX_TRANSPOSED_CLASS_SIZE \
	(2 * sizeof(uint32_t) + 2 * sizeof(uint64_t))
#define GREP_INDEX_TRANSPOSED_BLOCK_SIZE (64 * 1024)
#define GREP_INDEX_MIN_FILTER_SIZE 8
#define GREP_INDEX_MAX_FILTER_SIZE (1024 * 1024)
#define GREP_INDEX_MAX_QUERY_ALTERNATIVES 64
#define GREP_INDEX_MAX_QUERY_TRIGRAMS 4096
#define GREP_INDEX_MEMORY_MAX_BYTES	  (2ULL * 1024 * 1024 * 1024)
#define GREP_INDEX_MEMORY_MAX_ENTRIES	  (1024 * 1024)
#define GREP_INDEX_MEMORY_MAX_BLOB_SIZE	  (64 * 1024 * 1024)
#define GREP_INDEX_MEMORY_FILTER_CLASSES	  18

struct grep_index_segment {
	void *map;
	size_t map_size;
	const struct git_hash_algo *hash_algo;
	struct object_id checksum;
	size_t rawsz;
	uint32_t version;
	uint32_t nr;
	const unsigned char *fanout;
	const unsigned char *oids;
	const unsigned char *sizes;
	const unsigned char *offsets;
	const unsigned char *locators;
	const unsigned char *classes;
	const unsigned char *block_hashes;
	const unsigned char *data;
	size_t data_len;
	size_t block_size;
	size_t blocks_nr;
	unsigned char *blocks_valid;
	unsigned char *blocks_invalid;
	pthread_mutex_t verify_mutex;
	int verify_mutex_initialized;
};

struct grep_index {
	struct repository *repo;
	struct grep_index_segment *segments;
	size_t segments_nr;
	size_t segments_alloc;
};

enum grep_index_memory_entry_state {
	GREP_INDEX_MEMORY_BUILDING,
	GREP_INDEX_MEMORY_READY,
	GREP_INDEX_MEMORY_FAILED,
};

struct grep_index_memory_entry {
	struct hashmap_entry ent;
	struct object_id oid;
	pthread_cond_t cond;
	enum grep_index_memory_entry_state state;
	unsigned char *filter;
	size_t filter_size;
	int cond_initialized;
	int filter_owned;
};

struct grep_index_memory_filter_class {
	size_t filter_size;
	size_t nr;
	size_t filters_nr;
	size_t row_bytes;
	unsigned char *rows;
	const unsigned char **filters;
};

struct grep_index_memory {
	struct repository *repo;
	struct grep_index *persistent;
	struct hashmap entries;
	pthread_mutex_t mutex;
	size_t entries_nr;
	uint64_t filter_bytes;
};

static int grep_index_memory_entry_cmp(
	const void *data UNUSED,
	const struct hashmap_entry *eptr,
	const struct hashmap_entry *entry_or_key,
	const void *keydata UNUSED)
{
	const struct grep_index_memory_entry *a =
		container_of(eptr, const struct grep_index_memory_entry, ent);
	const struct grep_index_memory_entry *b =
		container_of(entry_or_key,
			     const struct grep_index_memory_entry, ent);

	return !oideq(&a->oid, &b->oid);
}

struct grep_index_query_clause {
	uint32_t *trigrams;
	size_t trigrams_nr;
	size_t trigrams_alloc;
};

struct grep_index_query_group {
	struct grep_index_query_clause *alternatives;
	size_t alternatives_nr;
	size_t alternatives_alloc;
};

struct grep_index_query_branch {
	struct grep_index_query_group *groups;
	size_t groups_nr;
	size_t groups_alloc;
};

struct grep_index_query {
	struct grep_index_query_clause *clauses;
	size_t clauses_nr;
	size_t clauses_alloc;
	struct grep_index_query_branch *branches;
	size_t branches_nr;
	size_t branches_alloc;
	size_t alternatives_nr;
	size_t trigrams_nr;
};

struct grep_index_prepared_segment {
	struct grep_index_segment *segment;
	unsigned char
		*candidates[GREP_INDEX_MEMORY_FILTER_CLASSES];
};

struct grep_index_prepared {
	struct grep_index *index;
	struct grep_index_prepared_segment *segments;
	size_t segments_nr;
};

static void grep_index_path(struct repository *repo, struct strbuf *buf,
			    const char *name)
{
	strbuf_addf(buf, "%s/info/grep-index/%s",
		    repo_get_object_directory(repo), name);
}

static int add_grep_index_segment(struct grep_index *index, const char *hex)
{
	struct grep_index_segment segment = { 0 };
	struct object_id checksum;
	struct strbuf path = STRBUF_INIT;
	const unsigned char *map;
	const unsigned char *end;
	size_t rawsz = index->repo->hash_algo->rawsz;
	size_t oid_bytes;
	size_t size_bytes;
	size_t offset_bytes;
	int fd;
	struct stat st;
	uint32_t previous = 0;

	if (strlen(hex) != index->repo->hash_algo->hexsz ||
	    get_oid_hex_algop(hex, &checksum, index->repo->hash_algo))
		return 0;

	grep_index_path(index->repo, &path, "");
	strbuf_addf(&path, "grep-%s.idx", hex);

	fd = git_open(path.buf);
	if (fd < 0)
		goto cleanup;
	if (fstat(fd, &st) || st.st_size < 0)
		goto close_fd;

	segment.map_size = xsize_t(st.st_size);
	segment.hash_algo = index->repo->hash_algo;
	oidcpy(&segment.checksum, &checksum);
	segment.rawsz = rawsz;
	if (segment.map_size < GREP_INDEX_HEADER_SIZE + GREP_INDEX_FANOUT_SIZE +
			       sizeof(uint64_t) + rawsz)
		goto close_fd;

	segment.map = xmmap_gently(NULL, segment.map_size, PROT_READ,
				  MAP_PRIVATE, fd, 0);
	if (segment.map == MAP_FAILED) {
		segment.map = NULL;
		goto close_fd;
	}
	close(fd);
	fd = -1;

	map = segment.map;
	end = map + segment.map_size - rawsz;
	if (get_be32(map) != GREP_INDEX_SIGNATURE ||
	    get_be32(map + 4) != GREP_INDEX_VERSION ||
	    get_be32(map + 8) != index->repo->hash_algo->format_id ||
	    !hashfile_checksum_valid(index->repo->hash_algo,
				     map, segment.map_size) ||
	    !hasheq(checksum.hash, end, index->repo->hash_algo))
		goto unmap;

	segment.version = GREP_INDEX_VERSION;
	segment.nr = get_be32(map + 12);
	if (!segment.nr || segment.nr == UINT32_MAX ||
	    segment.nr > (SIZE_MAX - GREP_INDEX_HEADER_SIZE -
			  GREP_INDEX_FANOUT_SIZE - sizeof(uint64_t) - rawsz) /
			 (rawsz + 2 * sizeof(uint64_t)))
		goto unmap;
	oid_bytes = segment.nr * rawsz;
	size_bytes = (size_t)segment.nr * sizeof(uint64_t);
	offset_bytes = ((size_t)segment.nr + 1) * sizeof(uint64_t);
	if ((size_t)(end - map) < GREP_INDEX_HEADER_SIZE +
					GREP_INDEX_FANOUT_SIZE ||
	    oid_bytes > (size_t)(end - map) - GREP_INDEX_HEADER_SIZE -
			GREP_INDEX_FANOUT_SIZE ||
	    size_bytes > (size_t)(end - map) - GREP_INDEX_HEADER_SIZE -
			 GREP_INDEX_FANOUT_SIZE - oid_bytes ||
	    offset_bytes > (size_t)(end - map) - GREP_INDEX_HEADER_SIZE -
			   GREP_INDEX_FANOUT_SIZE - oid_bytes - size_bytes)
		goto unmap;

	segment.fanout = map + GREP_INDEX_HEADER_SIZE;
	segment.oids = segment.fanout + GREP_INDEX_FANOUT_SIZE;
	segment.sizes = segment.oids + oid_bytes;
	segment.offsets = segment.sizes + size_bytes;
	segment.data = segment.offsets + offset_bytes;
	segment.data_len = end - segment.data;

	for (size_t i = 0; i < 256; i++) {
		uint32_t value = get_be32(segment.fanout +
					 i * sizeof(uint32_t));
		if (value < previous || value > segment.nr)
			goto unmap;
		previous = value;
	}
	if (previous != segment.nr ||
	    get_be64(segment.offsets) ||
	    get_be64(segment.offsets +
		     segment.nr * sizeof(uint64_t)) != segment.data_len)
		goto unmap;
	for (size_t i = 0; i < segment.nr; i++) {
		uint64_t start = get_be64(
			segment.offsets + i * sizeof(uint64_t));
		uint64_t end = get_be64(
			segment.offsets + (i + 1) * sizeof(uint64_t));
		uint64_t filter_size;

		if (start > end || end > segment.data_len)
			goto unmap;
		filter_size = end - start;
		if (filter_size < GREP_INDEX_MIN_FILTER_SIZE ||
		    filter_size > GREP_INDEX_MAX_FILTER_SIZE ||
		    (filter_size & (filter_size - 1)))
			goto unmap;
	}

	ALLOC_GROW(index->segments, index->segments_nr + 1,
		   index->segments_alloc);
	index->segments[index->segments_nr++] = segment;
	strbuf_release(&path);
	return 1;

unmap:
	munmap(segment.map, segment.map_size);
close_fd:
	if (fd >= 0)
		close(fd);
cleanup:
	strbuf_release(&path);
	return 0;
}

static int add_transposed_grep_index_segment(struct grep_index *index,
					      const char *hex)
{
	struct grep_index_segment segment = { 0 };
	struct object_id checksum;
	struct strbuf path = STRBUF_INIT;
	const unsigned char *map;
	const unsigned char *end;
	size_t rawsz = index->repo->hash_algo->rawsz;
	size_t oid_bytes;
	size_t locator_bytes;
	size_t block_hash_bytes;
	size_t class_bytes =
		GREP_INDEX_MEMORY_FILTER_CLASSES *
		GREP_INDEX_TRANSPOSED_CLASS_SIZE;
	size_t metadata_size;
	size_t class_base[GREP_INDEX_MEMORY_FILTER_CLASSES];
	unsigned char *seen = NULL;
	size_t seen_size;
	uint64_t data_len = 0;
	size_t classes_nr = 0;
	struct object_id metadata_checksum;
	struct git_hash_ctx hash_ctx;
	int fd;
	struct stat st;
	uint32_t previous = 0;

	if (strlen(hex) != index->repo->hash_algo->hexsz ||
	    get_oid_hex_algop(hex, &checksum, index->repo->hash_algo))
		return 0;

	grep_index_path(index->repo, &path, "");
	strbuf_addf(&path, "grep-%s.idx", hex);

	fd = git_open(path.buf);
	if (fd < 0)
		goto cleanup;
	if (fstat(fd, &st) || st.st_size < 0)
		goto close_fd;

	segment.map_size = xsize_t(st.st_size);
	segment.hash_algo = index->repo->hash_algo;
	oidcpy(&segment.checksum, &checksum);
	segment.rawsz = rawsz;
	if (segment.map_size <
	    GREP_INDEX_TRANSPOSED_HEADER_SIZE +
		    GREP_INDEX_FANOUT_SIZE + class_bytes + rawsz)
		goto close_fd;

	segment.map = xmmap_gently(NULL, segment.map_size, PROT_READ,
				  MAP_PRIVATE, fd, 0);
	if (segment.map == MAP_FAILED) {
		segment.map = NULL;
		goto close_fd;
	}
	close(fd);
	fd = -1;

	map = segment.map;
	end = map + segment.map_size - rawsz;
	if (get_be32(map) != GREP_INDEX_SIGNATURE ||
	    get_be32(map + 4) != GREP_INDEX_TRANSPOSED_VERSION ||
	    get_be32(map + 8) != index->repo->hash_algo->format_id ||
	    get_be32(map + 16) != GREP_INDEX_MEMORY_FILTER_CLASSES ||
	    get_be32(map + 20) != GREP_INDEX_TRANSPOSED_BLOCK_SIZE ||
	    get_be32(map + 28) ||
	    !hasheq(checksum.hash, end, index->repo->hash_algo))
		goto unmap;

	segment.version = GREP_INDEX_TRANSPOSED_VERSION;
	segment.nr = get_be32(map + 12);
	segment.block_size = get_be32(map + 20);
	segment.blocks_nr = get_be32(map + 24);
	if (segment.nr == UINT32_MAX ||
	    segment.nr >
		    (SIZE_MAX - GREP_INDEX_TRANSPOSED_HEADER_SIZE -
		     GREP_INDEX_FANOUT_SIZE - class_bytes - rawsz) /
			    (rawsz + GREP_INDEX_TRANSPOSED_LOCATOR_SIZE))
		goto unmap;
	oid_bytes = segment.nr * rawsz;
	locator_bytes = (size_t)segment.nr *
			GREP_INDEX_TRANSPOSED_LOCATOR_SIZE;
	if (segment.blocks_nr >
	    (SIZE_MAX - GREP_INDEX_TRANSPOSED_HEADER_SIZE -
	     GREP_INDEX_FANOUT_SIZE - oid_bytes - locator_bytes -
	     class_bytes) /
		    rawsz)
		goto unmap;
	block_hash_bytes = segment.blocks_nr * rawsz;
	metadata_size = GREP_INDEX_TRANSPOSED_HEADER_SIZE +
			GREP_INDEX_FANOUT_SIZE + oid_bytes +
			locator_bytes + class_bytes + block_hash_bytes;
	if (metadata_size > (size_t)(end - map))
		goto unmap;

	segment.fanout = map + GREP_INDEX_TRANSPOSED_HEADER_SIZE;
	segment.oids = segment.fanout + GREP_INDEX_FANOUT_SIZE;
	segment.locators = segment.oids + oid_bytes;
	segment.classes = segment.locators + locator_bytes;
	segment.block_hashes = segment.classes + class_bytes;
	segment.data = segment.block_hashes + block_hash_bytes;
	segment.data_len = end - segment.data;
	if (segment.blocks_nr !=
	    DIV_ROUND_UP(segment.data_len, segment.block_size))
		goto unmap;
	index->repo->hash_algo->init_fn(&hash_ctx);
	git_hash_update(&hash_ctx, map, metadata_size);
	git_hash_final_oid(&metadata_checksum, &hash_ctx);
	if (!oideq(&metadata_checksum, &checksum))
		goto unmap;

	for (size_t i = 0; i < 256; i++) {
		uint32_t value = get_be32(segment.fanout +
					 i * sizeof(uint32_t));
		if (value < previous || value > segment.nr)
			goto unmap;
		previous = value;
	}
	if (previous != segment.nr)
		goto unmap;

	for (size_t i = 0; i < GREP_INDEX_MEMORY_FILTER_CLASSES; i++) {
		const unsigned char *entry =
			segment.classes +
			i * GREP_INDEX_TRANSPOSED_CLASS_SIZE;
		uint32_t filter_size = get_be32(entry);
		uint32_t nr = get_be32(entry + sizeof(uint32_t));
		uint64_t offset =
			get_be64(entry + 2 * sizeof(uint32_t));
		uint64_t length =
			get_be64(entry + 2 * sizeof(uint32_t) +
				 sizeof(uint64_t));
		uint64_t row_bytes = (uint64_t)nr / 8 + !!(nr % 8);
		uint64_t bytes;

		if (filter_size !=
			    (uint32_t)GREP_INDEX_MIN_FILTER_SIZE << i ||
		    offset != data_len)
			goto unmap;
		class_base[i] = classes_nr;
		if (nr > segment.nr - classes_nr)
			goto unmap;
		classes_nr += nr;
		bytes = st_mult((uint64_t)filter_size * 8, row_bytes);
		if (length != bytes || bytes > segment.data_len - data_len)
			goto unmap;
		data_len += bytes;
	}
	if (classes_nr != segment.nr || data_len != segment.data_len)
		goto unmap;

	seen_size = (size_t)segment.nr / 8 + !!(segment.nr % 8);
	CALLOC_ARRAY(seen, seen_size);
	for (size_t i = 0; i < segment.nr; i++) {
		const unsigned char *locator =
			segment.locators +
			i * GREP_INDEX_TRANSPOSED_LOCATOR_SIZE;
		uint32_t class_nr = get_be32(locator);
		uint32_t pos =
			get_be32(locator + sizeof(uint32_t));
		uint32_t nr;
		size_t global_pos;
		unsigned char mask;

		if (class_nr >= GREP_INDEX_MEMORY_FILTER_CLASSES)
			goto unmap;
		nr = get_be32(
			segment.classes +
			class_nr * GREP_INDEX_TRANSPOSED_CLASS_SIZE +
			sizeof(uint32_t));
		if (pos >= nr)
			goto unmap;
		global_pos = class_base[class_nr] + pos;
		mask = 1u << (global_pos & 7);
		if (seen[global_pos >> 3] & mask)
			goto unmap;
		seen[global_pos >> 3] |= mask;
	}

	CALLOC_ARRAY(segment.blocks_valid,
		     DIV_ROUND_UP(segment.blocks_nr, 8));
	CALLOC_ARRAY(segment.blocks_invalid,
		     DIV_ROUND_UP(segment.blocks_nr, 8));
	pthread_mutex_init(&segment.verify_mutex, NULL);
	segment.verify_mutex_initialized = 1;
	ALLOC_GROW(index->segments, index->segments_nr + 1,
		   index->segments_alloc);
	index->segments[index->segments_nr++] = segment;
	free(seen);
	strbuf_release(&path);
	return 1;

unmap:
	free(seen);
	free(segment.blocks_valid);
	free(segment.blocks_invalid);
	if (segment.verify_mutex_initialized)
		pthread_mutex_destroy(&segment.verify_mutex);
	munmap(segment.map, segment.map_size);
close_fd:
	if (fd >= 0)
		close(fd);
cleanup:
	strbuf_release(&path);
	return 0;
}

static struct grep_index *grep_index_load_chain(
	struct repository *repo, const char *chain_name,
	int (*add_segment)(struct grep_index *, const char *))
{
	struct grep_index *index;
	struct strbuf chain_path = STRBUF_INIT;
	struct strbuf line = STRBUF_INIT;
	FILE *chain;

	if (!repo->gitdir)
		return NULL;

	if (replace_refs_enabled(repo)) {
		prepare_replace_object(repo);
		if (oidmap_get_size(&repo->objects->replace_map))
			return NULL;
	}

	CALLOC_ARRAY(index, 1);
	index->repo = repo;
	grep_index_path(repo, &chain_path, chain_name);
	chain = fopen(chain_path.buf, "r");
	if (!chain)
		goto done;

	while (strbuf_getline(&line, chain) != EOF)
		add_segment(index, line.buf);
	fclose(chain);

done:
	strbuf_release(&line);
	strbuf_release(&chain_path);
	if (!index->segments_nr) {
		grep_index_free(index);
		return NULL;
	}
	return index;
}

static struct grep_index *grep_index_load_legacy(struct repository *repo)
{
	return grep_index_load_chain(repo, "chain", add_grep_index_segment);
}

static int read_grep_index_chain(struct repository *repo, const char *name,
				 struct strbuf *chain)
{
	struct strbuf path = STRBUF_INIT;
	int result;

	grep_index_path(repo, &path, name);
	result = strbuf_read_file(chain, path.buf, 0);
	strbuf_release(&path);
	return result < 0 ? -1 : 0;
}

static struct grep_index *grep_index_load_transposed(struct repository *repo)
{
	struct grep_index *index = NULL;
	struct strbuf manifest = STRBUF_INIT;
	struct strbuf line = STRBUF_INIT;
	struct object_id oid;
	size_t pos = 0;
	size_t hexsz = repo->hash_algo->hexsz;

	if (!repo->gitdir ||
	    read_grep_index_chain(repo, "chain-transposed", &manifest))
		goto cleanup;
	CALLOC_ARRAY(index, 1);
	index->repo = repo;
	while (pos < manifest.len) {
		const char *end = memchr(manifest.buf + pos, '\n',
					 manifest.len - pos);
		size_t len = end ? (size_t)(end - manifest.buf - pos) :
				   manifest.len - pos;

		strbuf_reset(&line);
		strbuf_add(&line, manifest.buf + pos, len);
		if (line.len != 2 * hexsz + 1 ||
		    line.buf[hexsz] != ' ' ||
		    get_oid_hex_algop(line.buf, &oid, repo->hash_algo) ||
		    get_oid_hex_algop(line.buf + hexsz + 1, &oid,
				      repo->hash_algo) ||
		    !add_transposed_grep_index_segment(
			    index, line.buf + hexsz + 1))
			goto invalid;
		pos += len + !!end;
	}
	if (!index->segments_nr)
		goto invalid;
	goto cleanup;

invalid:
	grep_index_free(index);
	index = NULL;

cleanup:
	strbuf_release(&line);
	strbuf_release(&manifest);
	return index;
}

struct grep_index *grep_index_load(struct repository *repo)
{
	struct grep_index *index;

	if (replace_refs_enabled(repo)) {
		prepare_replace_object(repo);
		if (oidmap_get_size(&repo->objects->replace_map))
			return NULL;
	}
	index = grep_index_load_transposed(repo);

	return index ? index : grep_index_load_legacy(repo);
}

void grep_index_free(struct grep_index *index)
{
	if (!index)
		return;
	for (size_t i = 0; i < index->segments_nr; i++) {
		free(index->segments[i].blocks_valid);
		free(index->segments[i].blocks_invalid);
		if (index->segments[i].verify_mutex_initialized)
			pthread_mutex_destroy(
				&index->segments[i].verify_mutex);
		munmap(index->segments[i].map, index->segments[i].map_size);
	}
	free(index->segments);
	free(index);
}

static int segment_oid_pos(struct grep_index_segment *segment,
			   const struct object_id *oid, uint32_t *pos)
{
	return bsearch_hash(oid->hash, (const uint32_t *)segment->fanout,
			    segment->oids, segment->rawsz, pos);
}

static const unsigned char *segment_filter(struct grep_index_segment *segment,
					   const struct object_id *oid,
					   size_t *filter_size)
{
	uint64_t start, end;
	uint32_t pos;

	if (!segment_oid_pos(segment, oid, &pos))
		return NULL;

	start = get_be64(segment->offsets + pos * sizeof(uint64_t));
	end = get_be64(segment->offsets + ((size_t)pos + 1) * sizeof(uint64_t));
	if (start > end || end > segment->data_len)
		return NULL;
	*filter_size = end - start;
	if (!*filter_size || *filter_size > SIZE_MAX / 8 ||
	    (*filter_size & (*filter_size - 1)))
		return NULL;
	return segment->data + start;
}

static int grep_index_contains_oid(struct grep_index *index,
				   const struct object_id *oid)
{
	if (!index)
		return 0;

	for (size_t i = 0; i < index->segments_nr; i++) {
		size_t filter_size;
		uint32_t pos;

		if (index->segments[i].version ==
			    GREP_INDEX_TRANSPOSED_VERSION ?
			    segment_oid_pos(&index->segments[i], oid, &pos) :
			    !!segment_filter(&index->segments[i], oid,
					     &filter_size))
			return 1;
	}
	return 0;
}

static uint32_t trigram_hash(const unsigned char *data)
{
	uint32_t hash = ((uint32_t)data[0] << 16) |
			((uint32_t)data[1] << 8) |
			data[2];

	hash ^= hash >> 16;
	hash *= 0x7feb352d;
	hash ^= hash >> 15;
	hash *= 0x846ca68b;
	hash ^= hash >> 16;
	return hash;
}

static void grep_index_query_group_clear(struct grep_index_query_group *group)
{
	for (size_t i = 0; i < group->alternatives_nr; i++)
		free(group->alternatives[i].trigrams);
	free(group->alternatives);
}

static void grep_index_query_branch_clear(struct grep_index_query_branch *branch)
{
	for (size_t i = 0; i < branch->groups_nr; i++)
		grep_index_query_group_clear(&branch->groups[i]);
	free(branch->groups);
}

static int grep_index_query_clause_add_literal(
	struct grep_index_query_clause *clause,
	struct grep_index_query *query,
	const unsigned char *literal, size_t len)
{
	size_t trigrams_nr;

	if (len < 3)
		return 0;
	trigrams_nr = len - 2;
	if (trigrams_nr > GREP_INDEX_MAX_QUERY_TRIGRAMS - query->trigrams_nr)
		return -1;
	ALLOC_GROW(clause->trigrams, clause->trigrams_nr + trigrams_nr,
		   clause->trigrams_alloc);
	for (size_t i = 0; i < trigrams_nr; i++)
		clause->trigrams[clause->trigrams_nr++] =
			trigram_hash(literal + i);
	query->trigrams_nr += trigrams_nr;
	return 0;
}

static int grep_index_query_branch_add_clause(
	struct grep_index_query_branch *branch,
	struct grep_index_query *query,
	struct grep_index_query_clause *clause)
{
	struct grep_index_query_group group = { 0 };

	if (!clause->trigrams_nr)
		return 0;
	if (query->alternatives_nr == GREP_INDEX_MAX_QUERY_ALTERNATIVES)
		return -1;
	ALLOC_ARRAY(group.alternatives, 1);
	group.alternatives[0] = *clause;
	group.alternatives_nr = 1;
	group.alternatives_alloc = 1;
	ALLOC_GROW(branch->groups, branch->groups_nr + 1,
		   branch->groups_alloc);
	branch->groups[branch->groups_nr++] = group;
	query->alternatives_nr++;
	*clause = (struct grep_index_query_clause){ 0 };
	return 0;
}

void grep_index_query_free(struct grep_index_query *query)
{
	if (!query)
		return;
	for (size_t i = 0; i < query->clauses_nr; i++)
		free(query->clauses[i].trigrams);
	for (size_t i = 0; i < query->branches_nr; i++)
		grep_index_query_branch_clear(&query->branches[i]);
	free(query->clauses);
	free(query->branches);
	free(query);
}

#define GREP_INDEX_QUERY_SIGNATURE 0x47495158
#define GREP_INDEX_QUERY_VERSION   1

static void grep_index_query_put_u32(struct strbuf *buf, uint32_t value)
{
	char data[sizeof(uint32_t)];

	put_be32(data, value);
	strbuf_add(buf, data, sizeof(data));
}

static int grep_index_query_serialize_clause(
	const struct grep_index_query_clause *clause, struct strbuf *buf)
{
	if (clause->trigrams_nr > UINT32_MAX)
		return -1;
	grep_index_query_put_u32(buf, clause->trigrams_nr);
	for (size_t i = 0; i < clause->trigrams_nr; i++)
		grep_index_query_put_u32(buf, clause->trigrams[i]);
	return 0;
}

int grep_index_query_serialize(const struct grep_index_query *query,
			       struct strbuf *buf)
{
	if (!query || query->clauses_nr > UINT32_MAX ||
	    query->branches_nr > UINT32_MAX)
		return -1;

	grep_index_query_put_u32(buf, GREP_INDEX_QUERY_SIGNATURE);
	grep_index_query_put_u32(buf, GREP_INDEX_QUERY_VERSION);
	grep_index_query_put_u32(buf, query->clauses_nr);
	for (size_t i = 0; i < query->clauses_nr; i++)
		if (grep_index_query_serialize_clause(&query->clauses[i], buf))
			return -1;
	grep_index_query_put_u32(buf, query->branches_nr);
	for (size_t i = 0; i < query->branches_nr; i++) {
		const struct grep_index_query_branch *branch =
			&query->branches[i];

		if (branch->groups_nr > UINT32_MAX)
			return -1;
		grep_index_query_put_u32(buf, branch->groups_nr);
		for (size_t j = 0; j < branch->groups_nr; j++) {
			const struct grep_index_query_group *group =
				&branch->groups[j];

			if (group->alternatives_nr > UINT32_MAX)
				return -1;
			grep_index_query_put_u32(buf, group->alternatives_nr);
			for (size_t k = 0; k < group->alternatives_nr; k++)
				if (grep_index_query_serialize_clause(
					    &group->alternatives[k], buf))
					return -1;
		}
	}
	return 0;
}

struct grep_index_query_reader {
	const unsigned char *data;
	size_t len;
	size_t pos;
};

static int grep_index_query_get_u32(struct grep_index_query_reader *reader,
				    uint32_t *value)
{
	if (reader->len - reader->pos < sizeof(uint32_t))
		return -1;
	*value = get_be32(reader->data + reader->pos);
	reader->pos += sizeof(uint32_t);
	return 0;
}

static int grep_index_query_deserialize_clause(
	struct grep_index_query_reader *reader,
	struct grep_index_query_clause *clause,
	struct grep_index_query *query)
{
	uint32_t nr;

	if (grep_index_query_get_u32(reader, &nr) ||
	    !nr ||
	    nr > GREP_INDEX_MAX_QUERY_TRIGRAMS - query->trigrams_nr ||
	    nr > (reader->len - reader->pos) / sizeof(uint32_t))
		return -1;
	ALLOC_ARRAY(clause->trigrams, nr);
	for (size_t i = 0; i < nr; i++)
		if (grep_index_query_get_u32(reader, &clause->trigrams[i]))
			return -1;
	clause->trigrams_nr = nr;
	clause->trigrams_alloc = nr;
	query->trigrams_nr += nr;
	return 0;
}

struct grep_index_query *grep_index_query_deserialize(const char *data,
						      size_t len)
{
	struct grep_index_query_reader reader = {
		.data = (const unsigned char *)data,
		.len = len,
	};
	struct grep_index_query *query;
	uint32_t signature, version, nr;

	CALLOC_ARRAY(query, 1);
	if (grep_index_query_get_u32(&reader, &signature) ||
	    grep_index_query_get_u32(&reader, &version) ||
	    signature != GREP_INDEX_QUERY_SIGNATURE ||
	    version != GREP_INDEX_QUERY_VERSION ||
	    grep_index_query_get_u32(&reader, &nr) ||
	    nr > GREP_INDEX_MAX_QUERY_ALTERNATIVES)
		goto invalid;

	CALLOC_ARRAY(query->clauses, nr);
	query->clauses_nr = nr;
	query->clauses_alloc = nr;
	for (size_t i = 0; i < nr; i++)
		if (grep_index_query_deserialize_clause(
			    &reader, &query->clauses[i], query))
			goto invalid;

	if (grep_index_query_get_u32(&reader, &nr) ||
	    nr > GREP_INDEX_MAX_QUERY_ALTERNATIVES)
		goto invalid;
	CALLOC_ARRAY(query->branches, nr);
	query->branches_nr = nr;
	query->branches_alloc = nr;
	for (size_t i = 0; i < nr; i++) {
		struct grep_index_query_branch *branch = &query->branches[i];
		uint32_t groups_nr;

		if (grep_index_query_get_u32(&reader, &groups_nr) ||
		    !groups_nr ||
		    groups_nr > GREP_INDEX_MAX_QUERY_ALTERNATIVES)
			goto invalid;
		CALLOC_ARRAY(branch->groups, groups_nr);
		branch->groups_nr = groups_nr;
		branch->groups_alloc = groups_nr;
		for (size_t j = 0; j < groups_nr; j++) {
			struct grep_index_query_group *group =
				&branch->groups[j];
			uint32_t alternatives_nr;

			if (grep_index_query_get_u32(
				    &reader, &alternatives_nr) ||
			    !alternatives_nr ||
			    alternatives_nr >
				    GREP_INDEX_MAX_QUERY_ALTERNATIVES -
					    query->alternatives_nr)
				goto invalid;
			CALLOC_ARRAY(group->alternatives, alternatives_nr);
			group->alternatives_nr = alternatives_nr;
			group->alternatives_alloc = alternatives_nr;
			for (size_t k = 0; k < alternatives_nr; k++) {
				if (grep_index_query_deserialize_clause(
					    &reader,
					    &group->alternatives[k], query))
					goto invalid;
				query->alternatives_nr++;
			}
		}
	}
	if ((!query->clauses_nr && !query->branches_nr) ||
	    reader.pos != reader.len)
		goto invalid;
	return query;

invalid:
	grep_index_query_free(query);
	return NULL;
}

struct grep_index_query *grep_index_query_create(const struct grep_opt *opt)
{
	struct grep_index_query_clause clause = { 0 };
	struct grep_index_query *query;
	enum grep_pattern_type pattern_type = opt->pattern_type_option;

	if (opt->ignore_case || opt->invert || opt->unmatch_name_only ||
	    opt->allow_textconv || !opt->pattern_list)
		return NULL;
	if (pattern_type == GREP_PATTERN_TYPE_UNSPECIFIED)
		pattern_type = opt->extended_regexp_option ?
			GREP_PATTERN_TYPE_ERE : GREP_PATTERN_TYPE_BRE;

	CALLOC_ARRAY(query, 1);
	for (const struct grep_pat *p = opt->pattern_list; p; p = p->next) {
		size_t scan_start = 0;
		size_t scan_end = p->patternlen;
		size_t term_start;

		if (p->token != GREP_PATTERN)
			goto unsupported;
#ifdef USE_LIBPCRE2
		if (pattern_type == GREP_PATTERN_TYPE_FIXED &&
		    memmem(p->pattern, p->patternlen, "\\E", 2))
			goto unsupported;
#endif

		if (pattern_type == GREP_PATTERN_TYPE_ERE) {
			struct grep_index_query_branch branch = { 0 };
			struct grep_index_query_clause top_clause = { 0 };
			struct grep_index_query *group_query;
			size_t candidate_start = 0;
			size_t top_literal_run = 0;
			size_t top_literal_start = 0;
			int branch_has_group = 0;
			int candidate = 0;
			int candidate_simple = 0;
			int depth = 0;
			int valid = 1;

			CALLOC_ARRAY(group_query, 1);
			for (size_t i = 0; i < p->patternlen; i++) {
				unsigned char ch = p->pattern[i];

				if (!depth && !is_regex_special(ch) && ch != '}') {
					if (!top_literal_run)
						top_literal_start = i;
					top_literal_run++;
				} else if (!depth) {
					if (ch == '{' ||
					    (top_literal_run &&
					     (ch == '*' || ch == '?'))) {
						valid = 0;
						break;
					}
					if (grep_index_query_clause_add_literal(
						    &top_clause, group_query,
						    (const unsigned char *)
							    p->pattern +
							    top_literal_start,
						    top_literal_run)) {
						valid = 0;
						break;
					}
					top_literal_run = 0;
				}
				if (ch == '\\') {
					if (++i == p->patternlen) {
						valid = 0;
						break;
					}
					if (candidate &&
					    (depth != 1 ||
					     !is_regex_special(p->pattern[i])))
						candidate_simple = 0;
					continue;
				}
				if (ch == '[') {
					size_t j = i + 1;

					if (j < p->patternlen &&
					    p->pattern[j] == '^')
						j++;
					if (j < p->patternlen &&
					    p->pattern[j] == ']')
						j++;
					for (; j < p->patternlen &&
					       p->pattern[j] != ']';
					     j++) {
						if (p->pattern[j] == '[' &&
						    j + 1 < p->patternlen &&
						    strchr(".:=",
							   p->pattern[j + 1])) {
							unsigned char marker =
								p->pattern[j + 1];

							for (j += 2;
							     j + 1 < p->patternlen &&
							     !(p->pattern[j] == marker &&
							       p->pattern[j + 1] == ']');
							     j++) {
								if (p->pattern[j] == '\\' ||
								    p->pattern[j] == '[') {
									valid = 0;
									break;
								}
							}
							if (!valid ||
							    j + 1 == p->patternlen) {
								valid = 0;
								break;
							}
							j++;
						} else if (p->pattern[j] == '\\' ||
							   p->pattern[j] == '[') {
							valid = 0;
							break;
						}
					}
					if (!valid || j == p->patternlen) {
						valid = 0;
						break;
					}
					if (candidate &&
					    (depth != 1 || j != i + 2 ||
					     (!isalnum(p->pattern[i + 1]) &&
					      p->pattern[i + 1] != '_')))
						candidate_simple = 0;
					i = j;
					continue;
				}
				if (ch == '(') {
					if (!depth) {
						candidate = 1;
						candidate_simple = 1;
						candidate_start = i + 1;
					} else if (candidate) {
						candidate_simple = 0;
					}
					depth++;
					continue;
				}
				if (ch == ')') {
					if (!depth) {
						valid = 0;
						break;
					}
					depth--;
					if (!depth && candidate) {
						struct grep_index_query_group group = {
							0
						};
						struct strbuf literal = STRBUF_INIT;
						size_t alternatives_left =
							GREP_INDEX_MAX_QUERY_ALTERNATIVES -
							group_query->alternatives_nr;
						size_t trigrams_left =
							GREP_INDEX_MAX_QUERY_TRIGRAMS -
							group_query->trigrams_nr;
						size_t trigrams_nr = 0;

						if (candidate_simple &&
						    (i + 1 == p->patternlen ||
						     !strchr("*?{",
							     p->pattern[i + 1]))) {
							for (size_t j = candidate_start;
							     j <= i; j++) {
								struct grep_index_query_clause
									alternative = { 0 };

								if (j != i &&
								    p->pattern[j] != '|') {
									if (p->pattern[j] ==
									    '[') {
										strbuf_addch(
											&literal,
											p->pattern
												[j + 1]);
										j += 2;
										continue;
									}
									if (p->pattern[j] ==
									    '\\')
										j++;
									strbuf_addch(
										&literal,
										p->pattern[j]);
									continue;
								}
								if (literal.len < 3 ||
								    group.alternatives_nr ==
									    alternatives_left ||
								    literal.len - 2 >
									    trigrams_left -
										    trigrams_nr) {
									candidate_simple = 0;
									break;
								}
								alternative.trigrams_nr =
									literal.len - 2;
								alternative.trigrams_alloc =
									literal.len - 2;
								ALLOC_ARRAY(
									alternative.trigrams,
									literal.len - 2);
								for (size_t k = 0;
								     k < literal.len - 2;
								     k++)
									alternative.trigrams[k] =
										trigram_hash(
											(const unsigned char *)
												literal.buf +
											k);
								ALLOC_GROW(
									group.alternatives,
									group.alternatives_nr +
										1,
									group.alternatives_alloc);
								group.alternatives
									[group.alternatives_nr++] =
									alternative;
								trigrams_nr +=
									literal.len - 2;
								strbuf_reset(&literal);
							}
						} else {
							candidate_simple = 0;
						}
						strbuf_release(&literal);
						if (candidate_simple) {
							ALLOC_GROW(branch.groups,
								   branch.groups_nr + 1,
								   branch.groups_alloc);
							branch.groups[branch.groups_nr++] =
								group;
							group_query->alternatives_nr +=
								group.alternatives_nr;
							group_query->trigrams_nr +=
								trigrams_nr;
							branch_has_group = 1;
						} else {
							grep_index_query_group_clear(
								&group);
						}
						candidate = 0;
					}
					continue;
				}
				if (ch == '|' && !depth) {
					if (!branch_has_group) {
						valid = 0;
						break;
					}
					if (grep_index_query_branch_add_clause(
						    &branch, group_query,
						    &top_clause)) {
						valid = 0;
						break;
					}
					ALLOC_GROW(group_query->branches,
						   group_query->branches_nr + 1,
						   group_query->branches_alloc);
					group_query->branches
						[group_query->branches_nr++] = branch;
					branch =
						(struct grep_index_query_branch){ 0 };
					branch_has_group = 0;
					continue;
				}
				if (candidate && depth == 1 && ch != '|' &&
				    (is_regex_special(ch) || ch == '}'))
					candidate_simple = 0;
			}
			if (valid &&
			    grep_index_query_clause_add_literal(
				    &top_clause, group_query,
				    (const unsigned char *)p->pattern +
					    top_literal_start,
				    top_literal_run))
				valid = 0;
			if (depth || !branch_has_group)
				valid = 0;
			if (valid &&
			    grep_index_query_branch_add_clause(
				    &branch, group_query, &top_clause))
				valid = 0;
			free(top_clause.trigrams);
			if (valid) {
				ALLOC_GROW(group_query->branches,
					   group_query->branches_nr + 1,
					   group_query->branches_alloc);
				group_query->branches[group_query->branches_nr++] =
					branch;
				branch =
					(struct grep_index_query_branch){ 0 };
				if (query->clauses_nr +
						    query->alternatives_nr >
					    GREP_INDEX_MAX_QUERY_ALTERNATIVES -
						    group_query->alternatives_nr ||
				    group_query->trigrams_nr >
					    GREP_INDEX_MAX_QUERY_TRIGRAMS -
						    query->trigrams_nr) {
					grep_index_query_free(group_query);
					goto unsupported;
				}
				ALLOC_GROW(query->branches,
					   query->branches_nr +
						   group_query->branches_nr,
					   query->branches_alloc);
				memcpy(query->branches + query->branches_nr,
				       group_query->branches,
				       group_query->branches_nr *
					       sizeof(*group_query->branches));
				query->branches_nr +=
					group_query->branches_nr;
				query->alternatives_nr +=
					group_query->alternatives_nr;
				query->trigrams_nr += group_query->trigrams_nr;
				free(group_query->branches);
				free(group_query);
				continue;
			} else {
				grep_index_query_branch_clear(&branch);
				grep_index_query_free(group_query);
			}
		}

		if (pattern_type == GREP_PATTERN_TYPE_ERE) {
			size_t outer_start = 0;
			size_t outer_end = p->patternlen;

			if (outer_start < outer_end &&
			    p->pattern[outer_start] == '^')
				outer_start++;
			if (outer_start < outer_end &&
			    p->pattern[outer_end - 1] == '$') {
				size_t backslashes = 0;

				for (size_t i = outer_end - 1;
				     i > outer_start &&
				     p->pattern[i - 1] == '\\';
				     i--)
					backslashes++;
				if (!(backslashes & 1))
					outer_end--;
			}
			if (outer_end > outer_start + 1 &&
			    p->pattern[outer_start] == '(') {
				size_t i;
				int depth = 1;
				int valid = 1;

				for (i = outer_start + 1; i < outer_end; i++) {
					unsigned char ch = p->pattern[i];

					if (ch == '\\') {
						if (++i == outer_end) {
							valid = 0;
							break;
						}
					} else if (ch == '[') {
						if (++i < outer_end &&
						    p->pattern[i] == '^')
							i++;
						if (i < outer_end &&
						    p->pattern[i] == ']')
							i++;
						for (; i < outer_end &&
						       p->pattern[i] != ']';
						     i++) {
							if (p->pattern[i] == '[' &&
							    i + 1 < outer_end &&
							    strchr(".:=",
								   p->pattern[i + 1])) {
								unsigned char marker =
									p->pattern[i + 1];

								for (i += 2;
								     i + 1 < outer_end &&
								     !(p->pattern[i] == marker &&
								       p->pattern[i + 1] == ']');
								     i++) {
									if (p->pattern[i] == '\\' ||
									    p->pattern[i] == '[') {
										valid = 0;
										break;
									}
								}
								if (!valid ||
								    i + 1 == outer_end) {
									valid = 0;
									break;
								}
								i++;
							} else if (p->pattern[i] == '\\' ||
								   p->pattern[i] == '[') {
								valid = 0;
								break;
							}
						}
						if (!valid || i == outer_end) {
							valid = 0;
							break;
						}
					} else if (ch == '(') {
						depth++;
					} else if (ch == ')' && !--depth) {
						break;
					}
				}
				if (valid && !depth && i + 1 == outer_end) {
					scan_start = outer_start + 1;
					scan_end = i;
				}
			}
		}

		term_start = scan_start;
		for (size_t i = scan_start; i < scan_end;) {
			unsigned char ch = p->pattern[i];
			size_t separator_len = 0;
			int alternation = 0;
			int escaped_dot = 0;

			if (pattern_type == GREP_PATTERN_TYPE_FIXED) {
				i++;
				continue;
			} else if (pattern_type == GREP_PATTERN_TYPE_BRE &&
			    ch == '\\' && i + 1 < scan_end &&
			    p->pattern[i + 1] == '|') {
				separator_len = 2;
				alternation = 1;
			} else if (pattern_type == GREP_PATTERN_TYPE_ERE &&
				   ch == '|') {
				separator_len = 1;
				alternation = 1;
			} else if (pattern_type == GREP_PATTERN_TYPE_ERE &&
				   ch == '(') {
				size_t j;
				int depth = 1;

				for (j = i + 1; j < scan_end; j++) {
					unsigned char group_ch = p->pattern[j];

					if (group_ch == '\\') {
						if (++j == scan_end)
							goto unsupported;
					} else if (group_ch == '[') {
						if (++j < scan_end &&
						    p->pattern[j] == '^')
							j++;
						if (j < scan_end &&
						    p->pattern[j] == ']')
							j++;
						for (; j < scan_end &&
						       p->pattern[j] != ']';
						     j++) {
							if (p->pattern[j] == '[' &&
							    j + 1 < scan_end &&
							    strchr(".:=",
								   p->pattern[j + 1])) {
								unsigned char marker =
									p->pattern[j + 1];

								for (j += 2;
								     j + 1 < scan_end &&
								     !(p->pattern[j] == marker &&
								       p->pattern[j + 1] == ']');
								     j++) {
									if (p->pattern[j] == '\\' ||
									    p->pattern[j] == '[')
										goto unsupported;
								}
								if (j + 1 == scan_end)
									goto unsupported;
								j++;
							} else if (p->pattern[j] == '\\' ||
								   p->pattern[j] == '[') {
								goto unsupported;
							}
						}
						if (j == scan_end)
							goto unsupported;
					} else if (group_ch == '(') {
						depth++;
					} else if (group_ch == ')' &&
						   !--depth) {
						break;
					}
				}
				if (j == scan_end)
					goto unsupported;
				separator_len = j - i + 1;
				if (j + 1 < scan_end &&
				    strchr("*+?", p->pattern[j + 1]))
					separator_len++;
			} else if ((pattern_type == GREP_PATTERN_TYPE_BRE ||
				    pattern_type == GREP_PATTERN_TYPE_ERE) &&
				   ch == '[') {
				size_t j = i + 1;

				if (j < scan_end && p->pattern[j] == '^')
					j++;
				if (j < scan_end && p->pattern[j] == ']')
					j++;
				for (; j < scan_end && p->pattern[j] != ']';
				     j++) {
					if (p->pattern[j] == '[' &&
					    j + 1 < scan_end &&
					    strchr(".:=", p->pattern[j + 1])) {
						unsigned char marker =
							p->pattern[j + 1];

						for (j += 2;
						     j + 1 < scan_end &&
						     !(p->pattern[j] == marker &&
						       p->pattern[j + 1] == ']');
						     j++) {
							if (p->pattern[j] == '\\' ||
							    p->pattern[j] == '[')
								goto unsupported;
						}
						if (j + 1 == scan_end)
							goto unsupported;
						j++;
					} else if (p->pattern[j] == '\\' ||
						   p->pattern[j] == '[') {
						goto unsupported;
					}
				}
				if (j == scan_end)
					goto unsupported;
				separator_len = j - i + 1;
				if (j + 1 < scan_end &&
				    (p->pattern[j + 1] == '*' ||
				     (pattern_type == GREP_PATTERN_TYPE_ERE &&
				      strchr("+?", p->pattern[j + 1]))))
					separator_len++;
			} else if (ch == '^' || ch == '$') {
				separator_len = 1;
			} else if (ch == '\\' && i + 1 < scan_end &&
				   ((pattern_type == GREP_PATTERN_TYPE_BRE &&
				     strchr(".[\\*^$", p->pattern[i + 1])) ||
				    pattern_type == GREP_PATTERN_TYPE_ERE ||
				    (pattern_type == GREP_PATTERN_TYPE_PCRE &&
				     (is_regex_special(p->pattern[i + 1]) ||
				      p->pattern[i + 1] == '}')))) {
				separator_len = 2;
				if (pattern_type == GREP_PATTERN_TYPE_ERE &&
				    i + 2 < scan_end &&
				    strchr("*+?", p->pattern[i + 2]))
					separator_len++;
				escaped_dot =
					(pattern_type == GREP_PATTERN_TYPE_BRE ||
					 pattern_type == GREP_PATTERN_TYPE_ERE) &&
					p->pattern[i + 1] == '.';
			} else if (ch == '.' && i + 1 < scan_end &&
				   (p->pattern[i + 1] == '*' ||
				    (pattern_type != GREP_PATTERN_TYPE_BRE &&
				     strchr("+?", p->pattern[i + 1])))) {
				separator_len = 2;
			} else if (ch == '.') {
				separator_len = 1;
			} else if (pattern_type == GREP_PATTERN_TYPE_PCRE) {
				if (is_regex_special(ch) || ch == '}')
					goto unsupported;
				i++;
				continue;
			}
			if (separator_len) {
				size_t termlen = i - term_start;

				if (termlen >= 3) {
					size_t trigrams_nr = termlen - 2;

					if (trigrams_nr >
					    GREP_INDEX_MAX_QUERY_TRIGRAMS -
						    query->trigrams_nr)
						goto unsupported;
					ALLOC_GROW(clause.trigrams,
						   clause.trigrams_nr +
							   trigrams_nr,
						   clause.trigrams_alloc);
					for (size_t j = 0; j < trigrams_nr; j++)
						clause.trigrams
							[clause.trigrams_nr++] =
							trigram_hash(
								(const unsigned char *)
									p->pattern +
								term_start + j);
					query->trigrams_nr += trigrams_nr;
				}
				if (escaped_dot && i + 3 < scan_end &&
				    (isalnum(p->pattern[i + 2]) ||
				     p->pattern[i + 2] == '_') &&
				    (isalnum(p->pattern[i + 3]) ||
				     p->pattern[i + 3] == '_')) {
					unsigned char trigram[3] = {
						'.',
						p->pattern[i + 2],
						p->pattern[i + 3]
					};
					size_t after = i + 4;
					int quantified = 0;

					if (after < scan_end) {
						unsigned char next =
							p->pattern[after];

						if (pattern_type ==
						    GREP_PATTERN_TYPE_BRE) {
							quantified =
								next == '*' ||
								(next == '\\' &&
								 after + 1 <
									 scan_end &&
								 strchr(
									 "+?{",
									 p->pattern
										 [after + 1]));
						} else {
							quantified = !!strchr(
								"*+?{", next);
						}
					}
					if (!quantified) {
						if (query->trigrams_nr ==
						    GREP_INDEX_MAX_QUERY_TRIGRAMS)
							goto unsupported;
						ALLOC_GROW(
							clause.trigrams,
							clause.trigrams_nr + 1,
							clause.trigrams_alloc);
						clause.trigrams
							[clause.trigrams_nr++] =
							trigram_hash(trigram);
						query->trigrams_nr++;
					}
				}
				if (alternation) {
					if (!clause.trigrams_nr ||
					    query->clauses_nr +
							    query->alternatives_nr >=
						    GREP_INDEX_MAX_QUERY_ALTERNATIVES)
						goto unsupported;
					ALLOC_GROW(query->clauses,
						   query->clauses_nr + 1,
						   query->clauses_alloc);
					query->clauses[query->clauses_nr++] =
						clause;
					clause =
						(struct grep_index_query_clause){
							0
						};
				}
				i += separator_len;
				term_start = i;
				continue;
			}
			if ((pattern_type == GREP_PATTERN_TYPE_BRE &&
			     (ch == '[' || ch == '\\' || ch == '*' ||
			      ch == '^' || ch == '$')) ||
			    (pattern_type == GREP_PATTERN_TYPE_ERE &&
			     (is_regex_special(ch) || ch == '}')))
				goto unsupported;
			i++;
		}
		if (scan_end - term_start >= 3) {
			size_t trigrams_nr = scan_end - term_start - 2;

			if (trigrams_nr > GREP_INDEX_MAX_QUERY_TRIGRAMS -
						  query->trigrams_nr)
				goto unsupported;
			ALLOC_GROW(clause.trigrams,
				   clause.trigrams_nr + trigrams_nr,
				   clause.trigrams_alloc);
			for (size_t j = 0; j < trigrams_nr; j++)
				clause.trigrams[clause.trigrams_nr++] =
					trigram_hash((const unsigned char *)
							     p->pattern +
						     term_start + j);
			query->trigrams_nr += trigrams_nr;
		}
		if (!clause.trigrams_nr ||
		    query->clauses_nr + query->alternatives_nr >=
			    GREP_INDEX_MAX_QUERY_ALTERNATIVES)
			goto unsupported;
		ALLOC_GROW(query->clauses, query->clauses_nr + 1,
			   query->clauses_alloc);
		query->clauses[query->clauses_nr++] = clause;
		clause = (struct grep_index_query_clause){ 0 };
	}
	return query;

unsupported:
	free(clause.trigrams);
	grep_index_query_free(query);
	return NULL;
}

static int grep_index_query_clause_maybe_contains(
	const struct grep_index_query_clause *clause,
	const unsigned char *filter, size_t filter_size)
{
	for (size_t i = 0; i < clause->trigrams_nr; i++) {
		uint32_t bit = clause->trigrams[i] & (filter_size * 8 - 1);

		if (!(filter[bit / 8] & (1u << (bit & 7))))
			return 0;
	}
	return 1;
}

typedef int grep_index_clause_maybe_contains_fn(
	const struct grep_index_query_clause *clause, const void *data);

struct grep_index_filter_query {
	const unsigned char *filter;
	size_t filter_size;
};

static int grep_index_filter_clause_maybe_contains(
	const struct grep_index_query_clause *clause, const void *data)
{
	const struct grep_index_filter_query *filter = data;

	return grep_index_query_clause_maybe_contains(
		clause, filter->filter, filter->filter_size);
}

static int grep_index_query_maybe_contains(
	const struct grep_index_query *query,
	grep_index_clause_maybe_contains_fn *clause_maybe_contains,
	const void *data)
{
	for (size_t i = 0; i < query->clauses_nr; i++) {
		const struct grep_index_query_clause *clause =
			&query->clauses[i];

		if (clause_maybe_contains(clause, data))
			return 1;
	}
	for (size_t i = 0; i < query->branches_nr; i++) {
		const struct grep_index_query_branch *branch =
			&query->branches[i];
		int branch_maybe_contains = 1;

		for (size_t j = 0; j < branch->groups_nr; j++) {
			const struct grep_index_query_group *group =
				&branch->groups[j];
			int group_maybe_contains = 0;

			for (size_t k = 0; k < group->alternatives_nr; k++) {
				if (clause_maybe_contains(
					    &group->alternatives[k], data)) {
					group_maybe_contains = 1;
					break;
				}
			}
			if (!group_maybe_contains) {
				branch_maybe_contains = 0;
				break;
			}
		}
		if (branch_maybe_contains)
			return 1;
	}
	return 0;
}

static int grep_index_filter_maybe_contains(
	const unsigned char *filter, size_t filter_size,
	const struct grep_index_query *query)
{
	struct grep_index_filter_query data = {
		.filter = filter,
		.filter_size = filter_size,
	};

	return grep_index_query_maybe_contains(
		query, grep_index_filter_clause_maybe_contains, &data);
}

struct grep_index_transposed_query {
	const struct grep_index_memory_filter_class *filter_class;
	struct grep_index_segment *segment;
	uint64_t rows_offset;
	size_t pos;
	int verification_failed;
};

static int grep_index_transposed_verify_range(
	struct grep_index_segment *segment, uint64_t offset, size_t len)
{
	size_t first_block;
	size_t last_block;
	int result = 1;

	if (!len || offset > segment->data_len ||
	    len > segment->data_len - offset)
		return 0;
	first_block = offset / segment->block_size;
	last_block = (offset + len - 1) / segment->block_size;
	pthread_mutex_lock(&segment->verify_mutex);
	for (size_t block = first_block; block <= last_block; block++) {
		unsigned char mask = 1u << (block & 7);
		size_t pos = block * segment->block_size;
		size_t block_len = segment->data_len - pos;
		struct object_id checksum;
		struct git_hash_ctx ctx;

		if (segment->blocks_invalid[block >> 3] & mask) {
			result = 0;
			break;
		}
		if (segment->blocks_valid[block >> 3] & mask)
			continue;
		if (block_len > segment->block_size)
			block_len = segment->block_size;
		segment->hash_algo->init_fn(&ctx);
		git_hash_update(&ctx, segment->data + pos, block_len);
		git_hash_final_oid(&checksum, &ctx);
		if (!hasheq(checksum.hash,
			    segment->block_hashes + block * segment->rawsz,
			    segment->hash_algo)) {
			segment->blocks_invalid[block >> 3] |= mask;
			result = 0;
			break;
		}
		segment->blocks_valid[block >> 3] |= mask;
	}
	pthread_mutex_unlock(&segment->verify_mutex);
	return result;
}

static int grep_index_transposed_clause_maybe_contains(
	const struct grep_index_query_clause *clause, const void *data)
{
	struct grep_index_transposed_query *transposed = (void *)data;
	const struct grep_index_memory_filter_class *filter_class =
		transposed->filter_class;

	for (size_t i = 0; i < clause->trigrams_nr; i++) {
		uint32_t bit = clause->trigrams[i] &
			       (filter_class->filter_size * 8 - 1);
		const unsigned char *row =
			filter_class->rows + bit * filter_class->row_bytes;

		if (transposed->segment &&
		    !grep_index_transposed_verify_range(
			    transposed->segment,
			    transposed->rows_offset +
				    (uint64_t)bit *
					    filter_class->row_bytes,
			    filter_class->row_bytes)) {
			transposed->verification_failed = 1;
			return 1;
		}
		if (!(row[transposed->pos / 8] &
		      (1u << (transposed->pos & 7))))
			return 0;
	}
	return 1;
}

static int grep_index_transposed_maybe_contains(
	struct grep_index_segment *segment, const struct object_id *oid,
	const struct grep_index_query *query)
{
	struct grep_index_memory_filter_class filter_class;
	struct grep_index_transposed_query transposed;
	const unsigned char *locator;
	const unsigned char *class_entry;
	uint64_t offset;
	uint32_t class_nr;
	uint32_t pos;
	uint32_t nr;
	uint32_t oid_pos;
	int result;

	if (!segment_oid_pos(segment, oid, &oid_pos))
		return -1;
	locator = segment->locators +
		  (size_t)oid_pos * GREP_INDEX_TRANSPOSED_LOCATOR_SIZE;
	class_nr = get_be32(locator);
	pos = get_be32(locator + sizeof(uint32_t));
	class_entry = segment->classes +
		      (size_t)class_nr * GREP_INDEX_TRANSPOSED_CLASS_SIZE;
	nr = get_be32(class_entry + sizeof(uint32_t));
	offset = get_be64(class_entry + 2 * sizeof(uint32_t));
	filter_class.filter_size = get_be32(class_entry);
	filter_class.nr = nr;
	filter_class.filters_nr = nr;
	filter_class.row_bytes = DIV_ROUND_UP(nr, 8);
	filter_class.rows = (unsigned char *)segment->data + offset;
	filter_class.filters = NULL;
	transposed.filter_class = &filter_class;
	transposed.segment = segment;
	transposed.rows_offset = offset;
	transposed.pos = pos;
	transposed.verification_failed = 0;
	result = grep_index_query_maybe_contains(
		query, grep_index_transposed_clause_maybe_contains,
		&transposed);
	return transposed.verification_failed ? 1 : result;
}

static void grep_index_bitmap_fill(unsigned char *bitmap, size_t nr)
{
	size_t bytes = DIV_ROUND_UP(nr, 8);

	memset(bitmap, 0xff, bytes);
	if (nr & 7)
		bitmap[bytes - 1] &= (1u << (nr & 7)) - 1;
}

static void grep_index_bitmap_and(unsigned char *dst,
				  const unsigned char *src,
				  size_t bytes)
{
	for (size_t i = 0; i < bytes; i++)
		dst[i] &= src[i];
}

static void grep_index_bitmap_or(unsigned char *dst,
				 const unsigned char *src,
				 size_t bytes)
{
	for (size_t i = 0; i < bytes; i++)
		dst[i] |= src[i];
}

static int grep_index_prepare_clause(
	struct grep_index_segment *segment, uint64_t rows_offset,
	size_t filter_size, size_t nr,
	const struct grep_index_query_clause *clause,
	unsigned char *result)
{
	size_t row_bytes = DIV_ROUND_UP(nr, 8);

	grep_index_bitmap_fill(result, nr);
	for (size_t i = 0; i < clause->trigrams_nr; i++) {
		uint32_t bit = clause->trigrams[i] &
			       (filter_size * 8 - 1);
		uint64_t row_offset =
			rows_offset + (uint64_t)bit * row_bytes;
		const unsigned char *row = segment->data + row_offset;

		if (!grep_index_transposed_verify_range(
			    segment, row_offset, row_bytes))
			return -1;
		grep_index_bitmap_and(result, row, row_bytes);
	}
	return 0;
}

static unsigned char *grep_index_prepare_class(
	struct grep_index_segment *segment,
	const struct grep_index_query *query,
	size_t class_nr)
{
	const unsigned char *entry =
		segment->classes +
		class_nr * GREP_INDEX_TRANSPOSED_CLASS_SIZE;
	size_t filter_size = get_be32(entry);
	size_t nr = get_be32(entry + sizeof(uint32_t));
	uint64_t rows_offset =
		get_be64(entry + 2 * sizeof(uint32_t));
	size_t bytes = DIV_ROUND_UP(nr, 8);
	unsigned char *result;
	unsigned char *branch;
	unsigned char *group;
	unsigned char *clause;

	if (!nr)
		return NULL;
	CALLOC_ARRAY(result, bytes);
	ALLOC_ARRAY(branch, bytes);
	ALLOC_ARRAY(group, bytes);
	ALLOC_ARRAY(clause, bytes);
	for (size_t i = 0; i < query->clauses_nr; i++) {
		if (grep_index_prepare_clause(
			    segment, rows_offset, filter_size, nr,
			    &query->clauses[i], clause))
			goto unknown;
		grep_index_bitmap_or(result, clause, bytes);
	}
	for (size_t i = 0; i < query->branches_nr; i++) {
		const struct grep_index_query_branch *query_branch =
			&query->branches[i];

		grep_index_bitmap_fill(branch, nr);
		for (size_t j = 0; j < query_branch->groups_nr; j++) {
			const struct grep_index_query_group *query_group =
				&query_branch->groups[j];

			memset(group, 0, bytes);
			for (size_t k = 0;
			     k < query_group->alternatives_nr; k++) {
				if (grep_index_prepare_clause(
					    segment, rows_offset,
					    filter_size, nr,
					    &query_group->alternatives[k],
					    clause))
					goto unknown;
				grep_index_bitmap_or(group, clause, bytes);
			}
			grep_index_bitmap_and(branch, group, bytes);
		}
		grep_index_bitmap_or(result, branch, bytes);
	}
	goto cleanup;

unknown:
	grep_index_bitmap_fill(result, nr);

cleanup:
	free(clause);
	free(group);
	free(branch);
	return result;
}

int grep_index_is_transposed(struct grep_index *index)
{
	if (!index || !index->segments_nr)
		return 0;
	for (size_t i = 0; i < index->segments_nr; i++)
		if (index->segments[i].version !=
		    GREP_INDEX_TRANSPOSED_VERSION)
			return 0;
	return 1;
}

struct grep_index_prepared *grep_index_prepare(
	struct grep_index *index,
	const struct grep_index_query *query)
{
	struct grep_index_prepared *prepared;

	if (!grep_index_is_transposed(index) || !query)
		return NULL;
	CALLOC_ARRAY(prepared, 1);
	prepared->index = index;
	prepared->segments_nr = index->segments_nr;
	CALLOC_ARRAY(prepared->segments, prepared->segments_nr);
	for (size_t i = 0; i < prepared->segments_nr; i++) {
		struct grep_index_prepared_segment *prepared_segment =
			&prepared->segments[i];

		prepared_segment->segment = &index->segments[i];
		for (size_t class_nr = 0;
		     class_nr < GREP_INDEX_MEMORY_FILTER_CLASSES;
		     class_nr++)
			prepared_segment->candidates[class_nr] =
				grep_index_prepare_class(
					prepared_segment->segment,
					query, class_nr);
	}
	return prepared;
}

int grep_index_prepared_maybe_contains(
	struct grep_index_prepared *prepared,
	struct repository *repo,
	const struct object_id *oid)
{
	struct grep_index_location location = { 0 };

	if (!prepared || prepared->index->repo != repo)
		return 1;
	grep_index_resolve_location(prepared->index, oid, &location);
	return grep_index_prepared_location_maybe_contains(
		prepared, &location);
}

int grep_index_resolve_location(
	struct grep_index *index,
	const struct object_id *oid,
	struct grep_index_location *location)
{
	memset(location, 0, sizeof(*location));
	if (!grep_index_is_transposed(index))
		return -1;
	for (size_t i = 0; i < index->segments_nr; i++) {
		struct grep_index_segment *segment = &index->segments[i];
		const unsigned char *locator;
		uint32_t oid_pos;

		if (!segment_oid_pos(segment, oid, &oid_pos))
			continue;
		locator = segment->locators +
			  (size_t)oid_pos *
				  GREP_INDEX_TRANSPOSED_LOCATOR_SIZE;
		location->segment = i;
		location->filter_class = get_be32(locator);
		location->position =
			get_be32(locator + sizeof(uint32_t));
		location->valid = 1;
		return 0;
	}
	return -1;
}

int grep_index_prepared_location_maybe_contains(
	struct grep_index_prepared *prepared,
	const struct grep_index_location *location)
{
	struct grep_index_prepared_segment *segment;

	if (!prepared || !location || !location->valid)
		return 1;
	if (location->segment >= prepared->segments_nr ||
	    location->filter_class >=
		    GREP_INDEX_MEMORY_FILTER_CLASSES)
		BUG("invalid grep index location");
	segment = &prepared->segments[location->segment];
	return !!(segment->candidates[location->filter_class]
				  [location->position / 8] &
		  (1u << (location->position & 7)));
}

void grep_index_prepared_free(struct grep_index_prepared *prepared)
{
	if (!prepared)
		return;
	for (size_t i = 0; i < prepared->segments_nr; i++)
		for (size_t class_nr = 0;
		     class_nr < GREP_INDEX_MEMORY_FILTER_CLASSES;
		     class_nr++)
			free(prepared->segments[i].candidates[class_nr]);
	free(prepared->segments);
	free(prepared);
}

static const unsigned char *grep_index_find_filter(
	struct grep_index *index, struct repository *repo,
	const struct object_id *oid, size_t *filter_size)
{
	if (!index || index->repo != repo)
		return NULL;

	for (size_t i = 0; i < index->segments_nr; i++) {
		const unsigned char *filter =
			index->segments[i].version ==
					GREP_INDEX_TRANSPOSED_VERSION ?
				NULL :
				segment_filter(&index->segments[i], oid,
					       filter_size);

		if (filter)
			return filter;
	}
	return NULL;
}

int grep_index_maybe_contains(struct grep_index *index,
			      struct repository *repo,
			      const struct object_id *oid,
			      const struct grep_index_query *query)
{
	const unsigned char *filter;
	size_t filter_size;

	if (!query)
		return 1;
	if (index && index->repo == repo) {
		for (size_t i = 0; i < index->segments_nr; i++) {
			int result;

			if (index->segments[i].version !=
			    GREP_INDEX_TRANSPOSED_VERSION)
				continue;
			result = grep_index_transposed_maybe_contains(
				&index->segments[i], oid, query);
			if (result >= 0)
				return result;
		}
	}
	filter = grep_index_find_filter(index, repo, oid, &filter_size);
	return !filter || grep_index_filter_maybe_contains(
				  filter, filter_size, query);
}

static uint32_t filter_size_for_blob(unsigned long blob_size)
{
	uint64_t target = ((uint64_t)blob_size + 7) / 8;
	uint32_t size = GREP_INDEX_MIN_FILTER_SIZE;

	while (size < target && size < GREP_INDEX_MAX_FILTER_SIZE)
		size *= 2;
	return size;
}

static void fill_filter(unsigned char *filter, uint32_t filter_size,
			const void *content, unsigned long size)
{
	memset(filter, 0, filter_size);
	for (size_t i = 0; i + 2 < size; i++) {
		uint32_t bit = trigram_hash(
				       (const unsigned char *)content + i) &
			       (filter_size * 8 - 1);

		filter[bit / 8] |= 1u << (bit & 7);
	}
}

struct grep_index_memory *grep_index_memory_new(
	struct repository *repo, struct grep_index *persistent)
{
	struct grep_index_memory *index;

	CALLOC_ARRAY(index, 1);
	index->repo = repo;
	index->persistent = persistent;
	hashmap_init(&index->entries, grep_index_memory_entry_cmp, NULL, 0);
	pthread_mutex_init(&index->mutex, NULL);
	enable_obj_read_lock();
	return index;
}

void grep_index_memory_free(struct grep_index_memory *index)
{
	struct hashmap_iter iter;
	struct grep_index_memory_entry *entry;

	if (!index)
		return;
	hashmap_for_each_entry(&index->entries, &iter, entry, ent) {
		if (entry->cond_initialized)
			pthread_cond_destroy(&entry->cond);
		if (entry->filter_owned)
			free(entry->filter);
		free(entry);
	}
	hashmap_clear(&index->entries);
	pthread_mutex_destroy(&index->mutex);
	free(index);
}

void grep_index_memory_release_object_store(struct grep_index_memory *index)
{
	struct odb_source *source;

	obj_read_lock();
	for (source = index->repo->objects->sources; source;
	     source = source->next)
		odb_source_close(source);
	obj_read_unlock();
}

int grep_index_memory_maybe_contains(struct grep_index_memory *index,
				     const struct object_id *oid,
				     const struct grep_index_query *query)
{
	struct grep_index_memory_entry key = { 0 };
	struct grep_index_memory_entry *entry;
	struct object_info oi = OBJECT_INFO_INIT;
	enum object_type type;
	unsigned long size;
	unsigned char *filter = NULL;
	void *content = NULL;
	uint32_t filter_size;
	int result;

	if (!index || !query)
		return -1;

	if (grep_index_contains_oid(index->persistent, oid))
		return grep_index_maybe_contains(
			index->persistent, index->repo, oid, query);

	hashmap_entry_init(&key.ent, oidhash(oid));
	oidcpy(&key.oid, oid);
	pthread_mutex_lock(&index->mutex);
	entry = hashmap_get_entry(&index->entries, &key, ent, NULL);
	if (entry) {
		while (entry->state == GREP_INDEX_MEMORY_BUILDING)
			pthread_cond_wait(&entry->cond, &index->mutex);
		if (entry->state == GREP_INDEX_MEMORY_FAILED) {
			pthread_mutex_unlock(&index->mutex);
			return -1;
		}
		filter = entry->filter;
		filter_size = entry->filter_size;
		pthread_mutex_unlock(&index->mutex);
		return grep_index_filter_maybe_contains(
			filter, filter_size, query);
	}
	pthread_mutex_unlock(&index->mutex);

	pthread_mutex_lock(&index->mutex);
	entry = hashmap_get_entry(&index->entries, &key, ent, NULL);
	if (entry) {
		while (entry->state == GREP_INDEX_MEMORY_BUILDING)
			pthread_cond_wait(&entry->cond, &index->mutex);
		if (entry->state == GREP_INDEX_MEMORY_FAILED) {
			pthread_mutex_unlock(&index->mutex);
			return -1;
		}
		filter = entry->filter;
		filter_size = entry->filter_size;
		pthread_mutex_unlock(&index->mutex);
		return grep_index_filter_maybe_contains(
			filter, filter_size, query);
	}
	if (index->entries_nr >= GREP_INDEX_MEMORY_MAX_ENTRIES ||
	    index->filter_bytes >= GREP_INDEX_MEMORY_MAX_BYTES) {
		pthread_mutex_unlock(&index->mutex);
		return -1;
	}

	CALLOC_ARRAY(entry, 1);
	hashmap_entry_init(&entry->ent, key.ent.hash);
	oidcpy(&entry->oid, oid);
	pthread_cond_init(&entry->cond, NULL);
	entry->cond_initialized = 1;
	entry->state = GREP_INDEX_MEMORY_BUILDING;
	hashmap_add(&index->entries, &entry->ent);
	index->entries_nr++;
	pthread_mutex_unlock(&index->mutex);

	oi.typep = &type;
	oi.sizep = &size;
	result = odb_read_object_info_extended(
		index->repo->objects, oid, &oi,
		OBJECT_INFO_SKIP_FETCH_OBJECT | OBJECT_INFO_QUICK);
	if (!result && type == OBJ_BLOB &&
	    size <= GREP_INDEX_MEMORY_MAX_BLOB_SIZE) {
		oi.contentp = &content;
		result = odb_read_object_info_extended(
			index->repo->objects, oid, &oi,
			OBJECT_INFO_SKIP_FETCH_OBJECT | OBJECT_INFO_QUICK);
	}
	if (!result && content) {
		filter_size = filter_size_for_blob(size);
		CALLOC_ARRAY(filter, filter_size);
		fill_filter(filter, filter_size, content, size);
	}
	free(content);

	pthread_mutex_lock(&index->mutex);
	if (filter &&
	    filter_size <= GREP_INDEX_MEMORY_MAX_BYTES -
				   index->filter_bytes) {
		entry->filter = filter;
		entry->filter_size = filter_size;
		entry->filter_owned = 1;
		entry->state = GREP_INDEX_MEMORY_READY;
		index->filter_bytes += filter_size;
	} else {
		FREE_AND_NULL(filter);
		entry->state = GREP_INDEX_MEMORY_FAILED;
	}
	pthread_cond_broadcast(&entry->cond);
	pthread_mutex_unlock(&index->mutex);
	return filter ? grep_index_filter_maybe_contains(
				filter, filter_size, query) :
			-1;
}

static void collect_worktree_oids(struct repository *repo,
				  struct oid_array *oids)
{
	struct worktree **worktrees = get_worktrees_without_reading_head();

	for (struct worktree **p = worktrees; *p; p++) {
		struct index_state istate = INDEX_STATE_INIT(repo);
		char *gitdir = get_worktree_git_dir(*p);

		istate.lazy_cache_tree = 1;
		if (read_index_from(&istate, worktree_git_path(*p, "index"),
				    gitdir) > 0) {
			ensure_full_index(&istate);
			for (size_t i = 0; i < istate.cache_nr; i++) {
				const struct cache_entry *ce = istate.cache[i];

				if (S_ISREG(ce->ce_mode) && !ce_stage(ce) &&
				    !ce_intent_to_add(ce))
					oid_array_append(oids, &ce->oid);
			}
		}
		discard_index(&istate);
		free(gitdir);
	}
	free_worktrees(worktrees);
}

static int update_grep_index_chain(struct repository *repo,
				   const char *chain_name,
				   const char *hex)
{
	struct lock_file lock = LOCK_INIT;
	struct strbuf chain = STRBUF_INIT;
	struct strbuf chain_path = STRBUF_INIT;
	struct string_list entries = STRING_LIST_INIT_DUP;
	FILE *out;
	int result = -1;

	grep_index_path(repo, &chain_path, chain_name);
	hold_lock_file_for_update_mode(&lock, chain_path.buf,
				       LOCK_DIE_ON_ERROR, 0444);
	if (strbuf_read_file(&chain, chain_path.buf, 0) < 0 && errno != ENOENT)
		goto cleanup;
	if (chain.len) {
		string_list_split(&entries, chain.buf, "\n", -1);
		if (unsorted_string_list_has_string(&entries, hex)) {
			result = 0;
			goto cleanup;
		}
	}
	out = fdopen_lock_file(&lock, "w");
	if (!out)
		goto cleanup;
	if (chain.len) {
		if (fwrite(chain.buf, 1, chain.len, out) != chain.len)
			goto cleanup;
		if (chain.buf[chain.len - 1] != '\n' && fputc('\n', out) == EOF)
			goto cleanup;
	}
	if (fprintf(out, "%s\n", hex) < 0)
		goto cleanup;
	if (commit_lock_file(&lock) < 0)
		goto cleanup;
	result = 0;

cleanup:
	rollback_lock_file(&lock);
	string_list_clear(&entries, 0);
	strbuf_release(&chain);
	strbuf_release(&chain_path);
	return result;
}

static int replace_grep_index_chain(struct repository *repo,
				    const char *chain_name,
				    const struct strbuf *chain)
{
	struct lock_file lock = LOCK_INIT;
	struct strbuf path = STRBUF_INIT;
	int result = -1;

	grep_index_path(repo, &path, chain_name);
	hold_lock_file_for_update_mode(&lock, path.buf,
				       LOCK_DIE_ON_ERROR, 0444);
	if (write_in_full(get_lock_file_fd(&lock), chain->buf,
			  chain->len) < 0)
		goto cleanup;
	if (commit_lock_file(&lock) < 0)
		goto cleanup;
	result = 0;

cleanup:
	rollback_lock_file(&lock);
	strbuf_release(&path);
	return result;
}

int write_transposed_grep_index(struct repository *repo)
{
	struct grep_index *index = grep_index_load_legacy(repo);
	struct string_list mappings = STRING_LIST_INIT_DUP;
	struct strbuf existing_manifest = STRBUF_INIT;
	struct strbuf manifest = STRBUF_INIT;
	size_t manifest_pos = 0;
	size_t hexsz = repo->hash_algo->hexsz;
	int result = 0;

	if (!index)
		return 0;
	if (!read_grep_index_chain(
		    repo, "chain-transposed", &existing_manifest)) {
		while (manifest_pos < existing_manifest.len) {
			const char *line =
				existing_manifest.buf + manifest_pos;
			const char *end = memchr(
				line, '\n',
				existing_manifest.len - manifest_pos);
			size_t len = end ? (size_t)(end - line) :
					   existing_manifest.len -
						   manifest_pos;

			if (len == 2 * hexsz + 1 &&
			    line[hexsz] == ' ') {
				struct string_list_item *item;
				struct strbuf legacy = STRBUF_INIT;

				strbuf_add(&legacy, line, hexsz);
				item = string_list_insert(
					&mappings, legacy.buf);
				free(item->util);
				item->util = xmemdupz(
					line + hexsz + 1, hexsz);
				strbuf_release(&legacy);
			}
			manifest_pos += len + !!end;
		}
	}
	for (size_t segment_nr = 0;
	     segment_nr < index->segments_nr; segment_nr++) {
		struct grep_index_segment *segment =
			&index->segments[segment_nr];
		struct string_list_item *mapping;
		struct tempfile *data_temp = NULL;
		struct tempfile *temp = NULL;
		struct strbuf data_temp_path = STRBUF_INIT;
		struct strbuf temp_path = STRBUF_INIT;
		struct strbuf final_path = STRBUF_INIT;
		struct strbuf metadata = STRBUF_INIT;
		size_t class_counts[GREP_INDEX_MEMORY_FILTER_CLASSES] = { 0 };
		size_t class_base[GREP_INDEX_MEMORY_FILTER_CLASSES] = { 0 };
		size_t class_cursor[GREP_INDEX_MEMORY_FILTER_CLASSES] = { 0 };
		uint64_t class_offsets[GREP_INDEX_MEMORY_FILTER_CLASSES] = { 0 };
		uint64_t class_lengths[GREP_INDEX_MEMORY_FILTER_CLASSES] = { 0 };
		unsigned char *class_ids = NULL;
		uint32_t *members = NULL;
		unsigned char *output = NULL;
		unsigned char *block_hashes = NULL;
		unsigned char *block = NULL;
		uint64_t transpose_byte[8][256] = { 0 };
		uint64_t data_len = 0;
		size_t output_alloc = 8 * 1024 * 1024;
		size_t blocks_nr;
		struct object_id metadata_checksum;
		struct git_hash_ctx hash_ctx;
		char hex[GIT_MAX_HEXSZ + 1];
		char legacy_hex[GIT_MAX_HEXSZ + 1];
		int data_fd;
		int temp_fd;

		if (segment->version != GREP_INDEX_VERSION)
			BUG("legacy grep index contains non-legacy segment");
		hash_to_hex_algop_r(legacy_hex, segment->checksum.hash,
				    repo->hash_algo);
		mapping = string_list_lookup(&mappings, legacy_hex);
		if (mapping) {
			strbuf_addf(&manifest, "%s %s\n", legacy_hex,
				    (char *)mapping->util);
			continue;
		}
		ALLOC_ARRAY(class_ids, segment->nr);
		ALLOC_ARRAY(members, segment->nr);
		ALLOC_ARRAY(output, output_alloc);
		for (size_t i = 0; i < segment->nr; i++) {
			uint64_t start = get_be64(
				segment->offsets + i * sizeof(uint64_t));
			uint64_t end = get_be64(
				segment->offsets +
				(i + 1) * sizeof(uint64_t));
			size_t filter_size = end - start;
			size_t class_nr;

			for (class_nr = 0;
			     class_nr < GREP_INDEX_MEMORY_FILTER_CLASSES;
			     class_nr++)
				if (((size_t)GREP_INDEX_MIN_FILTER_SIZE <<
				     class_nr) == filter_size)
					break;
			if (class_nr == GREP_INDEX_MEMORY_FILTER_CLASSES)
				BUG("invalid filter size in loaded grep index");
			class_ids[i] = class_nr;
			class_counts[class_nr]++;
		}
		for (size_t i = 0, pos = 0;
		     i < GREP_INDEX_MEMORY_FILTER_CLASSES; i++) {
			uint64_t row_bytes =
				DIV_ROUND_UP(class_counts[i], 8);

			class_base[i] = pos;
			pos += class_counts[i];
			class_offsets[i] = data_len;
			class_lengths[i] = st_mult(
				(uint64_t)GREP_INDEX_MIN_FILTER_SIZE *
					(1ULL << i) * 8,
				row_bytes);
			if (class_lengths[i] > UINT64_MAX - data_len)
				die(_("grep index is too large"));
			data_len += class_lengths[i];
		}
		for (size_t i = 0; i < segment->nr; i++) {
			size_t class_nr = class_ids[i];

			members[class_base[class_nr] +
				class_cursor[class_nr]++] = i;
		}

		grep_index_path(repo, &data_temp_path,
				"tmp_grep_transposed_data_XXXXXX");
		data_temp = mks_tempfile_m(data_temp_path.buf, 0600);
		if (!data_temp)
			die_errno(_("unable to create temporary grep data"));
		data_fd = get_tempfile_fd(data_temp);
		for (size_t i = 0; i < 8; i++) {
			for (size_t value = 0; value < 256; value++) {
				unsigned char *bytes =
					(unsigned char *)
						&transpose_byte[i][value];

				for (size_t bit = 0; bit < 8; bit++)
					bytes[bit] =
						((value >> bit) & 1) << i;
			}
		}
		for (size_t class_nr = 0;
		     class_nr < GREP_INDEX_MEMORY_FILTER_CLASSES;
		     class_nr++) {
			size_t count = class_counts[class_nr];
			size_t filter_size =
				GREP_INDEX_MIN_FILTER_SIZE << class_nr;
			size_t row_bytes = DIV_ROUND_UP(count, 8);
			size_t block_bytes;

			if (!count)
				continue;
			block_bytes =
				(8 * 1024 * 1024) / (8 * row_bytes);
			if (!block_bytes)
				block_bytes = 1;
			for (size_t byte_start = 0;
			     byte_start < filter_size;
			     byte_start += block_bytes) {
				size_t byte_end = byte_start + block_bytes;
				size_t output_size;

				if (byte_end > filter_size)
					byte_end = filter_size;
				output_size = st_mult(
					st_mult(byte_end - byte_start, 8),
					row_bytes);
				if (output_size > output_alloc) {
					REALLOC_ARRAY(output, output_size);
					output_alloc = output_size;
				}
				memset(output, 0, output_size);
				for (size_t group = 0; group < count;
				     group += 8) {
					for (size_t byte = byte_start;
					     byte < byte_end; byte++) {
						uint64_t transposed = 0;
						unsigned char *bytes =
							(unsigned char *)
								&transposed;

						for (size_t lane = 0;
						     lane < 8 &&
						     group + lane < count;
						     lane++) {
							size_t pos =
								members
									[class_base
										 [class_nr] +
									 group +
									 lane];
							uint64_t start =
								get_be64(
									segment
										->offsets +
									pos *
										sizeof(
											uint64_t));

							transposed |=
								transpose_byte
									[lane]
									[segment
										 ->data
										 [start +
										  byte]];
						}
						for (size_t bit = 0;
						     bit < 8; bit++)
							output
								[((byte -
								   byte_start) *
									  8 +
								  bit) *
									 row_bytes +
								 group / 8] =
								bytes[bit];
					}
				}
				if (write_in_full(data_fd, output,
						  output_size) < 0)
					die_errno(
						_("unable to write temporary grep data"));
			}
		}
		if ((uint64_t)lseek(data_fd, 0, SEEK_CUR) != data_len)
			die_errno(_("invalid temporary grep data size"));

		blocks_nr = DIV_ROUND_UP(
			data_len, GREP_INDEX_TRANSPOSED_BLOCK_SIZE);
		ALLOC_ARRAY(block_hashes,
			    st_mult(blocks_nr, repo->hash_algo->rawsz));
		ALLOC_ARRAY(block, GREP_INDEX_TRANSPOSED_BLOCK_SIZE);
		if (lseek(data_fd, 0, SEEK_SET) < 0)
			die_errno(_("unable to rewind temporary grep data"));
		for (size_t i = 0; i < blocks_nr; i++) {
			size_t want = GREP_INDEX_TRANSPOSED_BLOCK_SIZE;
			ssize_t got;

			if (data_len -
				    (uint64_t)i *
					    GREP_INDEX_TRANSPOSED_BLOCK_SIZE <
			    want)
				want = data_len -
				       (uint64_t)i *
					       GREP_INDEX_TRANSPOSED_BLOCK_SIZE;
			got = read_in_full(data_fd, block, want);
			if (got < 0 || (size_t)got != want)
				die_errno(_("unable to read temporary grep data"));
			repo->hash_algo->init_fn(&hash_ctx);
			git_hash_update(&hash_ctx, block, want);
			git_hash_final(
				block_hashes +
					i * repo->hash_algo->rawsz,
				&hash_ctx);
		}

		{
			char value[sizeof(uint64_t)];

			put_be32(value, GREP_INDEX_SIGNATURE);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value, GREP_INDEX_TRANSPOSED_VERSION);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value, repo->hash_algo->format_id);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value, segment->nr);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value,
				 GREP_INDEX_MEMORY_FILTER_CLASSES);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value,
				 GREP_INDEX_TRANSPOSED_BLOCK_SIZE);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value, blocks_nr);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			put_be32(value, 0);
			strbuf_add(&metadata, value, sizeof(uint32_t));
			strbuf_add(&metadata, segment->fanout,
				   GREP_INDEX_FANOUT_SIZE);
			strbuf_add(&metadata, segment->oids,
				   (size_t)segment->nr *
					   repo->hash_algo->rawsz);
			memset(class_cursor, 0, sizeof(class_cursor));
			for (size_t i = 0; i < segment->nr; i++) {
				size_t class_nr = class_ids[i];

				put_be32(value, class_nr);
				strbuf_add(&metadata, value,
					   sizeof(uint32_t));
				put_be32(value,
					 class_cursor[class_nr]++);
				strbuf_add(&metadata, value,
					   sizeof(uint32_t));
			}
			for (size_t i = 0;
			     i < GREP_INDEX_MEMORY_FILTER_CLASSES; i++) {
				put_be32(value,
					 GREP_INDEX_MIN_FILTER_SIZE << i);
				strbuf_add(&metadata, value,
					   sizeof(uint32_t));
				put_be32(value, class_counts[i]);
				strbuf_add(&metadata, value,
					   sizeof(uint32_t));
				put_be64(value, class_offsets[i]);
				strbuf_add(&metadata, value,
					   sizeof(uint64_t));
				put_be64(value, class_lengths[i]);
				strbuf_add(&metadata, value,
					   sizeof(uint64_t));
			}
		}
		strbuf_add(&metadata, block_hashes,
			   blocks_nr * repo->hash_algo->rawsz);
		repo->hash_algo->init_fn(&hash_ctx);
		git_hash_update(&hash_ctx, metadata.buf, metadata.len);
		git_hash_final_oid(&metadata_checksum, &hash_ctx);
		hash_to_hex_algop_r(hex, metadata_checksum.hash,
				    repo->hash_algo);

		grep_index_path(repo, &temp_path,
				"tmp_grep_index_XXXXXX");
		temp = mks_tempfile_m(temp_path.buf, 0444);
		if (!temp)
			die_errno(_("unable to create temporary grep index"));
		temp_fd = get_tempfile_fd(temp);
		if (adjust_shared_perm(repo, get_tempfile_path(temp)))
			die_errno(_("unable to adjust shared permissions for grep index"));
		if (write_in_full(temp_fd, metadata.buf, metadata.len) < 0)
			die_errno(_("unable to write grep index metadata"));
		if (lseek(data_fd, 0, SEEK_SET) < 0)
			die_errno(_("unable to rewind temporary grep data"));
		for (;;) {
			ssize_t bytes = xread(
				data_fd, block,
				GREP_INDEX_TRANSPOSED_BLOCK_SIZE);

			if (bytes < 0)
				die_errno(_("unable to read temporary grep data"));
			if (!bytes)
				break;
			if (write_in_full(temp_fd, block, bytes) < 0)
				die_errno(_("unable to write grep index data"));
		}
		if (write_in_full(temp_fd, metadata_checksum.hash,
				  repo->hash_algo->rawsz) < 0)
			die_errno(_("unable to write grep index checksum"));
		fsync_component_or_die(FSYNC_COMPONENT_PACK_METADATA, temp_fd,
				       get_tempfile_path(temp));
		grep_index_path(repo, &final_path, "");
		strbuf_addf(&final_path, "grep-%s.idx", hex);
		if (rename_tempfile(&temp, final_path.buf) < 0 &&
		    errno != EEXIST)
			die_errno(_("unable to rename new grep index"));
		strbuf_addf(&manifest, "%s %s\n", legacy_hex, hex);

		delete_tempfile(&temp);
		delete_tempfile(&data_temp);
		free(block);
		free(block_hashes);
		free(output);
		free(members);
		free(class_ids);
		strbuf_release(&metadata);
		strbuf_release(&data_temp_path);
		strbuf_release(&temp_path);
		strbuf_release(&final_path);
	}
	if (replace_grep_index_chain(repo, "chain-transposed",
				     &manifest))
		die_errno(_("unable to update grep index chain"));
	grep_index_free(index);
	string_list_clear(&mappings, 1);
	strbuf_release(&existing_manifest);
	strbuf_release(&manifest);
	return result;
}

int write_grep_index(struct repository *repo, int show_progress)
{
	struct grep_index *existing = grep_index_load(repo);
	struct oid_array oids = OID_ARRAY_INIT;
	struct progress *progress = NULL;
	struct tempfile *temp = NULL;
	struct tempfile *filter_temp = NULL;
	struct hashfile *hashfile = NULL;
	struct strbuf temp_path = STRBUF_INIT;
	struct strbuf filter_temp_path = STRBUF_INIT;
	struct strbuf final_path = STRBUF_INIT;
	uint32_t *filter_sizes = NULL;
	unsigned long *blob_sizes = NULL;
	unsigned char *filter = NULL;
	unsigned char file_hash[GIT_MAX_RAWSZ];
	char hex[GIT_MAX_HEXSZ + 1];
	uint64_t offset = 0;
	size_t dst = 0;
	int result = -1;

	collect_worktree_oids(repo, &oids);
	oid_array_sort(&oids);
	CALLOC_ARRAY(filter_sizes, oids.nr);
	CALLOC_ARRAY(blob_sizes, oids.nr);
	ALLOC_ARRAY(filter, GREP_INDEX_MAX_FILTER_SIZE);

	grep_index_path(repo, &filter_temp_path,
			"tmp_grep_filters_XXXXXX");
	if (safe_create_leading_directories(repo, filter_temp_path.buf))
		die_errno(_("unable to create grep index directory"));
	filter_temp = mks_tempfile_m(filter_temp_path.buf, 0600);
	if (!filter_temp)
		die_errno(_("unable to create temporary grep filters"));

	if (show_progress)
		progress = start_delayed_progress(repo, _("Scanning blob objects"),
						  oids.nr);
	for (size_t i = 0; i < oids.nr; i = oid_array_next_unique(&oids, i)) {
		struct object_info oi = OBJECT_INFO_INIT;
		enum object_type type;
		unsigned long size;
		void *content = NULL;
		uint32_t filter_size;

		display_progress(progress, i + 1);
		if (grep_index_contains_oid(existing, &oids.oid[i]))
			continue;
		oi.typep = &type;
		oi.sizep = &size;
		oi.contentp = &content;
		if (odb_read_object_info_extended(
			    repo->objects, &oids.oid[i], &oi,
			    OBJECT_INFO_SKIP_FETCH_OBJECT | OBJECT_INFO_QUICK) ||
		    type != OBJ_BLOB) {
			free(content);
			continue;
		}
		filter_size = filter_size_for_blob(size);
		fill_filter(filter, filter_size, content, size);
		free(content);
		if (write_in_full(get_tempfile_fd(filter_temp), filter,
				  filter_size) < 0)
			die_errno(_("unable to write temporary grep filters"));
		oidcpy(&oids.oid[dst], &oids.oid[i]);
		blob_sizes[dst] = size;
		filter_sizes[dst] = filter_size;
		dst++;
	}
	stop_progress(&progress);
	oids.nr = dst;
	if (!oids.nr) {
		result = write_transposed_grep_index(repo);
		goto cleanup;
	}
	if (oids.nr > UINT32_MAX)
		die(_("too many blobs to write grep index"));

	grep_index_path(repo, &temp_path, "tmp_grep_index_XXXXXX");
	temp = mks_tempfile_m(temp_path.buf, 0444);
	if (!temp)
		die_errno(_("unable to create temporary grep index"));
	if (adjust_shared_perm(repo, get_tempfile_path(temp)))
		die_errno(_("unable to adjust shared permissions for grep index"));
	hashfile = hashfd(repo->hash_algo, get_tempfile_fd(temp),
			  get_tempfile_path(temp));

	hashwrite_be32(hashfile, GREP_INDEX_SIGNATURE);
	hashwrite_be32(hashfile, GREP_INDEX_VERSION);
	hashwrite_be32(hashfile, repo->hash_algo->format_id);
	hashwrite_be32(hashfile, oids.nr);
	for (size_t i = 0, pos = 0; i < 256; i++) {
		while (pos < oids.nr && oids.oid[pos].hash[0] <= i)
			pos++;
		hashwrite_be32(hashfile, pos);
	}
	for (size_t i = 0; i < oids.nr; i++)
		hashwrite(hashfile, oids.oid[i].hash, repo->hash_algo->rawsz);
	for (size_t i = 0; i < oids.nr; i++)
		hashwrite_be64(hashfile, blob_sizes[i]);
	hashwrite_be64(hashfile, 0);
	for (size_t i = 0; i < oids.nr; i++) {
		if (UINT64_MAX - offset < filter_sizes[i])
			die(_("grep index is too large"));
		offset += filter_sizes[i];
		hashwrite_be64(hashfile, offset);
	}

	if (lseek(get_tempfile_fd(filter_temp), 0, SEEK_SET) < 0)
		die_errno(_("unable to rewind temporary grep filters"));
	for (;;) {
		ssize_t bytes = xread(get_tempfile_fd(filter_temp), filter,
				      GREP_INDEX_MAX_FILTER_SIZE);

		if (bytes < 0)
			die_errno(_("unable to read temporary grep filters"));
		if (!bytes)
			break;
		hashwrite(hashfile, filter, bytes);
	}

	finalize_hashfile(hashfile, file_hash, FSYNC_COMPONENT_PACK_METADATA,
			  CSUM_HASH_IN_STREAM | CSUM_FSYNC);
	hashfile = NULL;
	hash_to_hex_algop_r(hex, file_hash, repo->hash_algo);
	grep_index_path(repo, &final_path, "");
	strbuf_addf(&final_path, "grep-%s.idx", hex);
	if (rename_tempfile(&temp, final_path.buf) < 0)
		die_errno(_("unable to rename new grep index"));
	if (update_grep_index_chain(repo, "chain", hex))
		die_errno(_("unable to update grep index chain"));
	result = write_transposed_grep_index(repo);

cleanup:
	stop_progress(&progress);
	if (hashfile)
		discard_hashfile(hashfile);
	delete_tempfile(&temp);
	delete_tempfile(&filter_temp);
	free(filter);
	free(blob_sizes);
	free(filter_sizes);
	oid_array_clear(&oids);
	grep_index_free(existing);
	strbuf_release(&temp_path);
	strbuf_release(&filter_temp_path);
	strbuf_release(&final_path);
	return result;
}

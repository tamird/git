#include "git-compat-util.h"
#include "grep-commit-index.h"
#include "commit.h"
#include "csum-file.h"
#include "diff.h"
#include "diffcore.h"
#include "environment.h"
#include "hex.h"
#include "lockfile.h"
#include "oid-array.h"
#include "oidset.h"
#include "path.h"
#include "progress.h"
#include "replace-object.h"
#include "repository.h"
#include "revision.h"
#include "strbuf.h"
#include "tree.h"

#define GREP_COMMIT_INDEX_SIGNATURE	   0x47434945 /* "GCIE" */
#define GREP_COMMIT_INDEX_VERSION	   2
#define GREP_COMMIT_INDEX_HEADER_SIZE	   (4 * sizeof(uint32_t))
#define GREP_COMMIT_INDEX_FANOUT_SIZE	   (256 * sizeof(uint32_t))
#define GREP_COMMIT_INDEX_EDGE_HEADER_SIZE (3 * sizeof(uint32_t))
#define GREP_COMMIT_INDEX_EDGE_COMPLETE	   1

/*
 * File layout:
 *
 *   header: signature, version, hash format, commit count
 *   256-entry commit OID fanout table
 *   sorted commit OIDs
 *   commit count + 1 uint64_t byte offsets into the record data
 *   variable commit records, each with a repository-hash checksum
 *   trailing checksum of the header and fixed-size metadata
 *
 * Each commit record starts with its edge count. Each edge contains its parent
 * OID, flags, raw changed-filepair count, endpoint OID count, and sorted unique
 * endpoint OIDs. The all-zero parent identifies a root-versus-empty edge.
 */
struct grep_commit_index {
	void *map;
	size_t map_size;
	const struct git_hash_algo *hash_algo;
	uint32_t nr;
	const unsigned char *fanout;
	const unsigned char *commits;
	const unsigned char *offsets;
	const unsigned char *data;
	size_t data_len;
};

struct grep_commit_edge_record {
	struct object_id parent_oid;
	struct oid_array oids;
	uint32_t changed_pairs;
	int complete;
};

struct grep_commit_record {
	struct object_id commit_oid;
	struct grep_commit_edge_record *edges;
	size_t edges_nr;
};

static void grep_commit_index_path(struct repository *repo, struct strbuf *path)
{
	strbuf_addf(path, "%s/info/grep-index/commit-edges",
		    repo_get_object_directory(repo));
}

static int grep_commit_edge_record_cmp(const void *va, const void *vb)
{
	const struct grep_commit_edge_record *a = va;
	const struct grep_commit_edge_record *b = vb;

	return oidcmp(&a->parent_oid, &b->parent_oid);
}

static int grep_commit_record_cmp(const void *va, const void *vb)
{
	const struct grep_commit_record *a = va;
	const struct grep_commit_record *b = vb;

	return oidcmp(&a->commit_oid, &b->commit_oid);
}

/*
 * Validate one variable-length commit record. When parent_oid is non-NULL,
 * return one only for a matching complete edge and populate result.
 */
static int parse_commit_record(struct grep_commit_index *index,
			       const unsigned char *record,
			       const unsigned char *record_end,
			       const struct object_id *parent_oid,
			       struct grep_commit_index_edge *result)
{
	const unsigned char *p = record;
	const unsigned char *previous_parent = NULL;
	size_t rawsz = index->hash_algo->rawsz;
	uint32_t edges_nr;
	int found = 0;

	if ((size_t)(record_end - p) < sizeof(uint32_t))
		return -1;
	edges_nr = get_be32(p);
	p += sizeof(uint32_t);
	if (!edges_nr ||
	    edges_nr > (size_t)(record_end - p) /
			       (rawsz + GREP_COMMIT_INDEX_EDGE_HEADER_SIZE))
		return -1;

	for (uint32_t i = 0; i < edges_nr; i++) {
		const unsigned char *parent;
		const unsigned char *oids;
		uint32_t flags;
		uint32_t changed_pairs;
		uint32_t oids_nr;
		size_t oids_size;

		if ((size_t)(record_end - p) <
		    rawsz + GREP_COMMIT_INDEX_EDGE_HEADER_SIZE)
			return -1;
		parent = p;
		p += rawsz;
		if (previous_parent &&
		    hashcmp(previous_parent, parent, index->hash_algo) >= 0)
			return -1;
		previous_parent = parent;

		flags = get_be32(p);
		p += sizeof(uint32_t);
		changed_pairs = get_be32(p);
		p += sizeof(uint32_t);
		oids_nr = get_be32(p);
		p += sizeof(uint32_t);
		if (flags & ~GREP_COMMIT_INDEX_EDGE_COMPLETE ||
		    oids_nr > (size_t)(record_end - p) / rawsz)
			return -1;
		oids_size = (size_t)oids_nr * rawsz;
		oids = p;
		p += oids_size;

		for (uint32_t j = 1; j < oids_nr; j++)
			if (hashcmp(oids + (size_t)(j - 1) * rawsz,
				    oids + (size_t)j * rawsz,
				    index->hash_algo) >= 0)
				return -1;

		if (parent_oid &&
		    !hashcmp(parent, parent_oid->hash, index->hash_algo) &&
		    flags & GREP_COMMIT_INDEX_EDGE_COMPLETE) {
			result->oids = oids;
			result->nr = oids_nr;
			result->oid_size = rawsz;
			result->changed_pairs = changed_pairs;
			found = 1;
		}
	}

	return p == record_end ? found : -1;
}

struct grep_commit_index *grep_commit_index_load(struct repository *repo)
{
	struct grep_commit_index *index = NULL;
	struct strbuf path = STRBUF_INIT;
	const unsigned char *map;
	const unsigned char *payload_end;
	struct git_hash_ctx metadata_ctx;
	struct object_id metadata_checksum;
	size_t rawsz;
	size_t payload_size;
	size_t oid_bytes;
	size_t offset_bytes;
	size_t metadata_size;
	uint32_t previous_fanout = 0;
	int fd = -1;
	struct stat st;

	if (!repo || !repo->gitdir)
		return NULL;
	if (replace_refs_enabled(repo)) {
		prepare_replace_object(repo);
		if (oidmap_get_size(&repo->objects->replace_map))
			return NULL;
	}
	rawsz = repo->hash_algo->rawsz;
	grep_commit_index_path(repo, &path);
	fd = git_open(path.buf);
	if (fd < 0 || fstat(fd, &st) || st.st_size < 0)
		goto cleanup;

	CALLOC_ARRAY(index, 1);
	index->map_size = xsize_t(st.st_size);
	if (index->map_size < GREP_COMMIT_INDEX_HEADER_SIZE +
				      GREP_COMMIT_INDEX_FANOUT_SIZE +
				      sizeof(uint64_t) + rawsz)
		goto invalid;
	index->map = xmmap_gently(NULL, index->map_size, PROT_READ,
				  MAP_PRIVATE, fd, 0);
	if (index->map == MAP_FAILED) {
		index->map = NULL;
		goto invalid;
	}
	close(fd);
	fd = -1;

	map = index->map;
	payload_size = index->map_size - rawsz;
	payload_end = map + payload_size;
	if (get_be32(map) != GREP_COMMIT_INDEX_SIGNATURE ||
	    get_be32(map + 4) != GREP_COMMIT_INDEX_VERSION ||
	    get_be32(map + 8) != repo->hash_algo->format_id)
		goto invalid;

	index->hash_algo = repo->hash_algo;
	index->nr = get_be32(map + 12);
	if (payload_size < GREP_COMMIT_INDEX_HEADER_SIZE +
				   GREP_COMMIT_INDEX_FANOUT_SIZE + sizeof(uint64_t) ||
	    index->nr >
		    (payload_size - GREP_COMMIT_INDEX_HEADER_SIZE -
		     GREP_COMMIT_INDEX_FANOUT_SIZE - sizeof(uint64_t)) /
			    (rawsz + sizeof(uint64_t)))
		goto invalid;
	oid_bytes = (size_t)index->nr * rawsz;
	offset_bytes = ((size_t)index->nr + 1) * sizeof(uint64_t);
	metadata_size = GREP_COMMIT_INDEX_HEADER_SIZE +
			GREP_COMMIT_INDEX_FANOUT_SIZE + oid_bytes +
			offset_bytes;
	if (metadata_size > payload_size)
		goto invalid;
	repo->hash_algo->init_fn(&metadata_ctx);
	git_hash_update(&metadata_ctx, map, metadata_size);
	git_hash_final_oid(&metadata_checksum, &metadata_ctx);
	if (!hasheq(metadata_checksum.hash, payload_end, repo->hash_algo))
		goto invalid;

	index->fanout = map + GREP_COMMIT_INDEX_HEADER_SIZE;
	index->commits = index->fanout + GREP_COMMIT_INDEX_FANOUT_SIZE;
	index->offsets = index->commits + oid_bytes;
	index->data = index->offsets + offset_bytes;
	index->data_len = payload_end - index->data;

	for (size_t i = 0, pos = 0; i < 256; i++) {
		uint32_t value = get_be32(index->fanout +
					  i * sizeof(uint32_t));

		while (pos < index->nr &&
		       index->commits[pos * rawsz] <= i)
			pos++;
		if (value < previous_fanout || value > index->nr ||
		    value != pos)
			goto invalid;
		previous_fanout = value;
	}
	if (previous_fanout != index->nr)
		goto invalid;
	for (size_t i = 1; i < index->nr; i++)
		if (hashcmp(index->commits + (i - 1) * rawsz,
			    index->commits + i * rawsz,
			    index->hash_algo) >= 0)
			goto invalid;

	for (size_t i = 0; i <= index->nr; i++) {
		uint64_t offset = get_be64(index->offsets +
					   i * sizeof(uint64_t));
		uint64_t previous = i ?
					    get_be64(index->offsets +
						     (i - 1) * sizeof(uint64_t)) :
					    0;

		if ((!i && offset) || offset < previous ||
		    offset > index->data_len)
			goto invalid;
	}
	if (get_be64(index->offsets +
		     (size_t)index->nr * sizeof(uint64_t)) != index->data_len)
		goto invalid;

	strbuf_release(&path);
	return index;

invalid:
	grep_commit_index_free(index);
	index = NULL;
cleanup:
	if (fd >= 0)
		close(fd);
	strbuf_release(&path);
	return index;
}

int grep_commit_index_lookup(struct grep_commit_index *index,
			     const struct object_id *commit_oid,
			     const struct object_id *parent_oid,
			     struct grep_commit_index_edge *edge)
{
	struct git_hash_ctx record_ctx;
	struct object_id record_checksum;
	uint32_t hi;
	uint32_t lo;
	uint32_t pos = UINT32_MAX;
	uint64_t start;
	uint64_t end;
	size_t record_size;

	if (edge)
		memset(edge, 0, sizeof(*edge));
	if (!index || !commit_oid || !parent_oid || !edge)
		return -1;
	hi = get_be32(index->fanout +
		      (size_t)commit_oid->hash[0] * sizeof(uint32_t));
	lo = commit_oid->hash[0] ?
		     get_be32(index->fanout +
			      ((size_t)commit_oid->hash[0] - 1) * sizeof(uint32_t)) :
		     0;
	while (lo < hi) {
		uint32_t mid = lo + (hi - lo) / 2;
		int cmp = hashcmp(index->commits +
					  (size_t)mid * index->hash_algo->rawsz,
				  commit_oid->hash, index->hash_algo);

		if (!cmp) {
			pos = mid;
			break;
		}
		if (cmp > 0)
			hi = mid;
		else
			lo = mid + 1;
	}
	if (pos == UINT32_MAX)
		return -1;
	start = get_be64(index->offsets + (size_t)pos * sizeof(uint64_t));
	end = get_be64(index->offsets +
		       ((size_t)pos + 1) * sizeof(uint64_t));
	if (start > end || end > index->data_len ||
	    end - start < index->hash_algo->rawsz)
		return -1;
	record_size = end - start - index->hash_algo->rawsz;
	index->hash_algo->init_fn(&record_ctx);
	git_hash_update(&record_ctx, commit_oid->hash,
			index->hash_algo->rawsz);
	git_hash_update(&record_ctx, index->data + start, record_size);
	git_hash_final_oid(&record_checksum, &record_ctx);
	if (!hasheq(record_checksum.hash,
		    index->data + start + record_size, index->hash_algo))
		return -1;
	if (parse_commit_record(index, index->data + start,
				index->data + start + record_size,
				parent_oid, edge) != 1)
		return -1;
	return 0;
}

void grep_commit_index_free(struct grep_commit_index *index)
{
	if (!index)
		return;
	if (index->map)
		munmap(index->map, index->map_size);
	free(index);
}

static int collect_parent_edge(struct repository *repo,
			       struct diff_options *diffopt,
			       struct commit *commit,
			       struct commit *parent,
			       struct grep_commit_edge_record *edge)
{
	struct tree *commit_tree;
	struct tree *parent_tree = NULL;
	size_t dst = 0;

	memset(edge, 0, sizeof(*edge));
	edge->complete = 1;
	if (parent)
		oidcpy(&edge->parent_oid, &parent->object.oid);
	else
		oidclr(&edge->parent_oid, repo->hash_algo);

	commit_tree = repo_get_commit_tree(repo, commit);
	if (!commit_tree)
		return error("unable to read tree for commit %s",
			     oid_to_hex(&commit->object.oid));
	if (parent) {
		if (repo_parse_commit(repo, parent))
			return error("unable to parse parent commit %s",
				     oid_to_hex(&parent->object.oid));
		parent_tree = repo_get_commit_tree(repo, parent);
		if (!parent_tree)
			return error("unable to read tree for parent commit %s",
				     oid_to_hex(&parent->object.oid));
		diff_tree_oid(&parent_tree->object.oid, &commit_tree->object.oid,
			      "", diffopt);
	} else {
		diff_root_tree_oid(&commit_tree->object.oid, "", diffopt);
	}
	diffcore_std(diffopt);
	edge->changed_pairs = diff_queued_diff.nr;

	for (int i = 0; i < diff_queued_diff.nr; i++) {
		struct diff_filepair *pair = diff_queued_diff.queue[i];
		struct diff_filespec *specs[] = { pair->one, pair->two };

		for (size_t j = 0; j < ARRAY_SIZE(specs); j++) {
			struct diff_filespec *spec = specs[j];

			/* A missing side of an addition or deletion is not an endpoint. */
			if (!DIFF_FILE_VALID(spec))
				continue;
			if (!spec->oid_valid || is_null_oid(&spec->oid) ||
			    (!S_ISREG(spec->mode) && !S_ISLNK(spec->mode))) {
				edge->complete = 0;
				continue;
			}
			oid_array_append(&edge->oids, &spec->oid);
		}
	}
	diff_queue_clear(&diff_queued_diff);

	oid_array_sort(&edge->oids);
	for (size_t i = 0; i < edge->oids.nr;
	     i = oid_array_next_unique(&edge->oids, i)) {
		if (dst != i)
			oidcpy(&edge->oids.oid[dst], &edge->oids.oid[i]);
		dst++;
	}
	edge->oids.nr = dst;
	if (dst) {
		REALLOC_ARRAY(edge->oids.oid, dst);
		edge->oids.alloc = dst;
	} else {
		oid_array_clear(&edge->oids);
	}
	return 0;
}

int write_grep_commit_index(struct repository *repo, struct rev_info *revs,
			    struct progress *progress)
{
	struct grep_commit_record *records = NULL;
	struct oidset seen_commits = OIDSET_INIT;
	struct diff_options diffopt;
	struct lock_file lock = LOCK_INIT;
	struct hashfile *hashfile = NULL;
	struct hashfile_checkpoint metadata_checkpoint;
	struct object_id metadata_checksum;
	struct strbuf path = STRBUF_INIT;
	struct strbuf record_buf = STRBUF_INIT;
	uint64_t *offsets = NULL;
	size_t records_nr = 0;
	size_t records_alloc = 0;
	uint64_t progress_nr = 0;
	int result = -1;
	int fd;

	if (!repo || !revs)
		return -1;
	if (replace_refs_enabled(repo))
		return error("commit edge index requires replacement refs disabled");
	repo_diff_setup(repo, &diffopt);
	diffopt.flags.recursive = 1;
	diffopt.detect_rename = 0;
	diff_setup_done(&diffopt);

	/* Preserve original parents before history simplification rewrites them. */
	revs->full_diff = 1;
	if (prepare_revision_walk(revs))
		goto cleanup;

	for (;;) {
		struct commit *commit = get_revision(revs);
		struct grep_commit_record *record;
		struct commit_list *parents;

		if (!commit)
			break;
		display_progress(progress, ++progress_nr);
		if (oidset_insert(&seen_commits, &commit->object.oid))
			continue;
		if (repo_parse_commit(repo, commit))
			goto cleanup;

		ALLOC_GROW(records, records_nr + 1, records_alloc);
		record = &records[records_nr++];
		memset(record, 0, sizeof(*record));
		oidcpy(&record->commit_oid, &commit->object.oid);
		parents = get_saved_parents(revs, commit);
		record->edges_nr = parents ? commit_list_count(parents) : 1;
		CALLOC_ARRAY(record->edges, record->edges_nr);
		if (!parents) {
			if (collect_parent_edge(repo, &diffopt, commit, NULL,
						&record->edges[0]))
				goto cleanup;
		} else {
			size_t i = 0;

			for (struct commit_list *p = parents; p; p = p->next) {
				struct grep_commit_edge_record *edge =
					&record->edges[i++];

				if (collect_parent_edge(repo, &diffopt, commit,
							p->item, edge))
					goto cleanup;
			}
		}
		QSORT(record->edges, record->edges_nr,
		      grep_commit_edge_record_cmp);
		for (size_t i = 1; i < record->edges_nr; i++)
			if (oideq(&record->edges[i - 1].parent_oid,
				  &record->edges[i].parent_oid))
				goto cleanup;
	}

	if (records_nr > UINT32_MAX)
		goto cleanup;
	QSORT(records, records_nr, grep_commit_record_cmp);
	for (size_t i = 1; i < records_nr; i++)
		if (oideq(&records[i - 1].commit_oid,
			  &records[i].commit_oid))
			goto cleanup;

	CALLOC_ARRAY(offsets, records_nr + 1);
	for (size_t i = 0; i < records_nr; i++) {
		uint64_t size = sizeof(uint32_t) + repo->hash_algo->rawsz;

		if (records[i].edges_nr > UINT32_MAX)
			goto cleanup;
		for (size_t j = 0; j < records[i].edges_nr; j++) {
			struct grep_commit_edge_record *edge =
				&records[i].edges[j];
			uint64_t fixed = repo->hash_algo->rawsz +
					 GREP_COMMIT_INDEX_EDGE_HEADER_SIZE;
			uint64_t oid_bytes;

			if (edge->oids.nr > UINT32_MAX ||
			    edge->oids.nr > UINT64_MAX / repo->hash_algo->rawsz)
				goto cleanup;
			oid_bytes = edge->oids.nr * repo->hash_algo->rawsz;
			if (fixed > UINT64_MAX - size ||
			    oid_bytes > UINT64_MAX - size - fixed)
				goto cleanup;
			size += fixed + oid_bytes;
		}
		if (size > UINT64_MAX - offsets[i])
			goto cleanup;
		offsets[i + 1] = offsets[i] + size;
	}

	grep_commit_index_path(repo, &path);
	if (safe_create_leading_directories(repo, path.buf))
		goto cleanup;
	fd = hold_lock_file_for_update_mode(&lock, path.buf, 0, 0444);
	if (fd < 0)
		goto cleanup;
	hashfile = hashfd(repo->hash_algo, fd, get_lock_file_path(&lock));
	hashwrite_be32(hashfile, GREP_COMMIT_INDEX_SIGNATURE);
	hashwrite_be32(hashfile, GREP_COMMIT_INDEX_VERSION);
	hashwrite_be32(hashfile, repo->hash_algo->format_id);
	hashwrite_be32(hashfile, records_nr);
	for (size_t i = 0, pos = 0; i < 256; i++) {
		while (pos < records_nr && records[pos].commit_oid.hash[0] <= i)
			pos++;
		hashwrite_be32(hashfile, pos);
	}
	for (size_t i = 0; i < records_nr; i++)
		hashwrite(hashfile, records[i].commit_oid.hash,
			  repo->hash_algo->rawsz);
	for (size_t i = 0; i <= records_nr; i++)
		hashwrite_be64(hashfile, offsets[i]);
	hashfile_checkpoint_init(hashfile, &metadata_checkpoint);
	hashfile_checkpoint(hashfile, &metadata_checkpoint);
	git_hash_final_oid(&metadata_checksum, &metadata_checkpoint.ctx);
	hashfile->skip_hash = 1;
	for (size_t i = 0; i < records_nr; i++) {
		struct git_hash_ctx record_ctx;
		struct object_id record_checksum;
		uint32_t value;
		size_t written = 0;

		strbuf_reset(&record_buf);
		value = htonl(records[i].edges_nr);
		strbuf_add(&record_buf, &value, sizeof(value));
		for (size_t j = 0; j < records[i].edges_nr; j++) {
			struct grep_commit_edge_record *edge =
				&records[i].edges[j];

			strbuf_add(&record_buf, edge->parent_oid.hash,
				   repo->hash_algo->rawsz);
			value = htonl(edge->complete ?
					      GREP_COMMIT_INDEX_EDGE_COMPLETE :
					      0);
			strbuf_add(&record_buf, &value, sizeof(value));
			value = htonl(edge->changed_pairs);
			strbuf_add(&record_buf, &value, sizeof(value));
			value = htonl(edge->oids.nr);
			strbuf_add(&record_buf, &value, sizeof(value));
			for (size_t k = 0; k < edge->oids.nr; k++)
				strbuf_add(&record_buf, edge->oids.oid[k].hash,
					   repo->hash_algo->rawsz);
		}
		if (record_buf.len + repo->hash_algo->rawsz !=
		    offsets[i + 1] - offsets[i])
			BUG("commit edge record size mismatch");
		repo->hash_algo->init_fn(&record_ctx);
		git_hash_update(&record_ctx, records[i].commit_oid.hash,
				repo->hash_algo->rawsz);
		git_hash_update(&record_ctx, record_buf.buf, record_buf.len);
		git_hash_final_oid(&record_checksum, &record_ctx);
		while (written < record_buf.len) {
			size_t remaining = record_buf.len - written;
			uint32_t chunk = remaining > UINT32_MAX ?
						 UINT32_MAX :
						 remaining;

			hashwrite(hashfile, record_buf.buf + written, chunk);
			written += chunk;
		}
		hashwrite(hashfile, record_checksum.hash,
			  repo->hash_algo->rawsz);
	}
	hashwrite(hashfile, metadata_checksum.hash, repo->hash_algo->rawsz);
	finalize_hashfile(hashfile, NULL, FSYNC_COMPONENT_PACK_METADATA,
			  CSUM_FSYNC);
	hashfile = NULL;
	if (commit_lock_file(&lock))
		goto cleanup;
	result = 0;

cleanup:
	if (hashfile)
		discard_hashfile(hashfile);
	rollback_lock_file(&lock);
	diff_queue_clear(&diff_queued_diff);
	diff_free(&diffopt);
	for (size_t i = 0; i < records_nr; i++) {
		for (size_t j = 0; j < records[i].edges_nr; j++)
			oid_array_clear(&records[i].edges[j].oids);
		free(records[i].edges);
	}
	free(records);
	free(offsets);
	oidset_clear(&seen_commits);
	strbuf_release(&path);
	strbuf_release(&record_buf);
	return result;
}

#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "grep-index.h"
#include "csum-file.h"
#include "environment.h"
#include "grep.h"
#include "hash-lookup.h"
#include "hex.h"
#include "lockfile.h"
#include "odb.h"
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
#include "worktree.h"
#include "wrapper.h"

#define GREP_INDEX_SIGNATURE 0x47494458
#define GREP_INDEX_VERSION 2
#define GREP_INDEX_HEADER_SIZE 16
#define GREP_INDEX_FANOUT_SIZE (256 * sizeof(uint32_t))
#define GREP_INDEX_MIN_FILTER_SIZE 8
#define GREP_INDEX_MAX_FILTER_SIZE (1024 * 1024)
#define GREP_INDEX_MAX_QUERY_ALTERNATIVES 64
#define GREP_INDEX_MAX_QUERY_TRIGRAMS 4096

struct grep_index_segment {
	void *map;
	size_t map_size;
	size_t rawsz;
	uint32_t nr;
	const unsigned char *fanout;
	const unsigned char *oids;
	const unsigned char *sizes;
	const unsigned char *offsets;
	const unsigned char *data;
	size_t data_len;
};

struct grep_index {
	struct repository *repo;
	struct grep_index_segment *segments;
	size_t segments_nr;
	size_t segments_alloc;
};

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
	    !hasheq(checksum.hash, end, index->repo->hash_algo))
		goto unmap;

	segment.nr = get_be32(map + 12);
	if (segment.nr == UINT32_MAX ||
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

struct grep_index *grep_index_load(struct repository *repo)
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
	grep_index_path(repo, &chain_path, "chain");
	chain = fopen(chain_path.buf, "r");
	if (!chain)
		goto done;

	while (strbuf_getline(&line, chain) != EOF)
		add_grep_index_segment(index, line.buf);
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

void grep_index_free(struct grep_index *index)
{
	if (!index)
		return;
	for (size_t i = 0; i < index->segments_nr; i++)
		munmap(index->segments[i].map, index->segments[i].map_size);
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

		if (segment_filter(&index->segments[i], oid, &filter_size))
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
#ifdef USE_ENHANCED_BASIC_REGULAR_EXPRESSIONS
				separator_len = 2;
				alternation = 1;
#else
				goto unsupported;
#endif
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

int grep_index_maybe_contains(struct grep_index *index,
			      struct repository *repo,
			      const struct object_id *oid,
			      const struct grep_index_query *query)
{
	if (!index || index->repo != repo || !query)
		return 1;

	for (size_t i = 0; i < index->segments_nr; i++) {
		const unsigned char *filter;
		size_t filter_size;

		filter = segment_filter(&index->segments[i], oid, &filter_size);
		if (!filter)
			continue;

		for (size_t j = 0; j < query->clauses_nr; j++) {
			const struct grep_index_query_clause *clause =
				&query->clauses[j];

			if (grep_index_query_clause_maybe_contains(
				    clause, filter, filter_size))
				return 1;
		}
		for (size_t j = 0; j < query->branches_nr; j++) {
			const struct grep_index_query_branch *branch =
				&query->branches[j];
			int branch_maybe_contains = 1;

			for (size_t k = 0; k < branch->groups_nr; k++) {
				const struct grep_index_query_group *group =
					&branch->groups[k];
				int group_maybe_contains = 0;

				for (size_t l = 0;
				     l < group->alternatives_nr; l++) {
					if (grep_index_query_clause_maybe_contains(
						    &group->alternatives[l],
						    filter, filter_size)) {
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
	return 1;
}

static uint32_t filter_size_for_blob(unsigned long blob_size)
{
	uint64_t target = ((uint64_t)blob_size + 7) / 8;
	uint32_t size = GREP_INDEX_MIN_FILTER_SIZE;

	while (size < target && size < GREP_INDEX_MAX_FILTER_SIZE)
		size *= 2;
	return size;
}

static void collect_worktree_oids(struct repository *repo,
				  struct oid_array *oids)
{
	struct worktree **worktrees = get_worktrees_without_reading_head();

	for (struct worktree **p = worktrees; *p; p++) {
		struct index_state istate = INDEX_STATE_INIT(repo);
		char *gitdir = get_worktree_git_dir(*p);

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
				   const char *hex)
{
	struct lock_file lock = LOCK_INIT;
	struct strbuf chain = STRBUF_INIT;
	struct strbuf chain_path = STRBUF_INIT;
	struct string_list entries = STRING_LIST_INIT_DUP;
	FILE *out;
	int result = -1;

	grep_index_path(repo, &chain_path, "chain");
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
		memset(filter, 0, filter_size);
		for (size_t j = 0; j + 2 < size; j++) {
			uint32_t bit = trigram_hash(
				(const unsigned char *)content + j) &
				(filter_size * 8 - 1);
			filter[bit / 8] |= 1u << (bit & 7);
		}
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
		result = 0;
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
	if (update_grep_index_chain(repo, hex))
		die_errno(_("unable to update grep index chain"));
	result = 0;

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

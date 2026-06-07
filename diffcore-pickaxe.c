/*
 * Copyright (C) 2005 Junio C Hamano
 * Copyright (C) 2010 Google Inc.
 */

#define DISABLE_SIGN_COMPARE_WARNINGS

#include "git-compat-util.h"
#include "diff.h"
#include "diffcore.h"
#include "grep.h"
#include "grep-index.h"
#include "grep-index-ipc.h"
#include "xdiff-interface.h"
#include "kwset.h"
#include "oidmap.h"
#include "oidset.h"
#include "parse.h"
#include "pretty.h"
#include "quote.h"
#include "trace2.h"

#define PICKAXE_INDEX_MAX_ENTRIES (1U << 20)
#define PICKAXE_INDEX_MIN_PAIRS	  4096
#define PICKAXE_INDEX_DIRECT_MAX_OIDS 64

struct diff_pickaxe_index_entry {
	struct oidmap_entry entry;
	int maybe;
};

struct diff_pickaxe_index {
	struct repository *repo;
	struct grep_index *index;
	struct grep_index_query *query;
	struct grep_index_prepared *prepared;
	struct oidmap results;
	char *needle;
	size_t pairs;
	size_t results_nr;
	unsigned pickaxe_opts;
	int direct_tried;
	int ipc;
	int persistent_only;
	int text;
	int tried;
	uint64_t cache_hits;
	uint64_t tested;
	uint64_t impossible_pairs;
	uint64_t direct_batches;
	uint64_t ipc_batches;
	uint64_t ipc_failures;
};

typedef int (*pickaxe_fn)(mmfile_t *one, mmfile_t *two,
			  struct diff_options *o,
			  regex_t *regexp, kwset_t kws);

struct diffgrep_cb {
	regex_t *regexp;
	int hit;
};

static int diffgrep_consume(void *priv, char *line, unsigned long len)
{
	struct diffgrep_cb *data = priv;
	regmatch_t regmatch;

	if (line[0] != '+' && line[0] != '-')
		return 0;
	if (data->hit)
		BUG("Already matched in diffgrep_consume! Broken xdiff_emit_line_fn?");
	if (!regexec_buf(data->regexp, line + 1, len - 1, 1,
			 &regmatch, 0)) {
		data->hit = 1;
		return 1;
	}
	return 0;
}

static int diff_grep(mmfile_t *one, mmfile_t *two,
		     struct diff_options *o,
		     regex_t *regexp, kwset_t kws UNUSED)
{
	struct diffgrep_cb ecbdata;
	xpparam_t xpp;
	xdemitconf_t xecfg;
	int ret;

	/*
	 * We have both sides; need to run textual diff and see if
	 * the pattern appears on added/deleted lines.
	 */
	memset(&xpp, 0, sizeof(xpp));
	memset(&xecfg, 0, sizeof(xecfg));
	ecbdata.regexp = regexp;
	ecbdata.hit = 0;
	xecfg.flags = XDL_EMIT_NO_HUNK_HDR;
	xecfg.ctxlen = o->context;
	xecfg.interhunkctxlen = o->interhunkcontext;

	/*
	 * An xdiff error might be our "data->hit" from above. See the
	 * comment for xdiff_emit_line_fn in xdiff-interface.h
	 */
	ret = xdi_diff_outf(one, two, NULL, diffgrep_consume,
			    &ecbdata, &xpp, &xecfg);
	if (ecbdata.hit)
		return 1;
	if (ret)
		return ret;
	return 0;
}

static unsigned int contains(mmfile_t *mf, regex_t *regexp, kwset_t kws,
			     unsigned int limit)
{
	unsigned int cnt = 0;
	unsigned long sz = mf->size;
	const char *data = mf->ptr;

	if (regexp) {
		regmatch_t regmatch;
		int flags = 0;

		while (sz &&
		       !regexec_buf(regexp, data, sz, 1, &regmatch, flags)) {
			flags |= REG_NOTBOL;
			data += regmatch.rm_eo;
			sz -= regmatch.rm_eo;
			if (sz && regmatch.rm_so == regmatch.rm_eo) {
				data++;
				sz--;
			}
			cnt++;

			if (limit && cnt == limit)
				return cnt;
		}

	} else { /* Classic exact string match */
		while (sz) {
			struct kwsmatch kwsm;
			size_t offset = kwsexec(kws, data, sz, &kwsm);
			if (offset == -1)
				break;
			sz -= offset + kwsm.size[0];
			data += offset + kwsm.size[0];
			cnt++;

			if (limit && cnt == limit)
				return cnt;
		}
	}
	return cnt;
}

static int has_changes(mmfile_t *one, mmfile_t *two,
		       struct diff_options *o UNUSED,
		       regex_t *regexp, kwset_t kws)
{
	unsigned int c1 = one ? contains(one, regexp, kws, 0) : 0;
	unsigned int c2 = two ? contains(two, regexp, kws, c1 + 1) : 0;
	return c1 != c2;
}

static int pickaxe_index_maybe_contains(
	struct diff_pickaxe_index *index,
	struct repository *repo,
	const struct diff_filespec *spec)
{
	struct diff_pickaxe_index_entry *entry;
	struct grep_index_location location;
	int maybe;

	if (!DIFF_FILE_VALID(spec))
		return 0;
	if (!index || !spec->oid_valid || !S_ISREG(spec->mode))
		return 1;
	entry = oidmap_get(&index->results, &spec->oid);
	if (entry) {
		index->cache_hits++;
		return entry->maybe;
	}
	if (!index->index)
		return 1;
	if (index->persistent_only && !index->prepared) {
		if (!grep_index_is_transposed(index->index)) {
			maybe = grep_index_maybe_contains(
				index->index, repo, &spec->oid, index->query);
		} else if (grep_index_resolve_location(
				   index->index, &spec->oid, &location)) {
			maybe = 1;
		} else {
			index->prepared =
				grep_index_prepare(index->index, index->query);
			maybe = !index->prepared ||
				grep_index_prepared_location_maybe_contains(
					index->prepared, &location);
		}
	} else {
		maybe = index->prepared ?
				grep_index_prepared_maybe_contains(
					index->prepared, repo, &spec->oid) :
				grep_index_maybe_contains(
					index->index, repo, &spec->oid,
					index->query);
	}
	index->tested++;
	if (index->results_nr < PICKAXE_INDEX_MAX_ENTRIES) {
		CALLOC_ARRAY(entry, 1);
		oidcpy(&entry->entry.oid, &spec->oid);
		entry->maybe = maybe;
		oidmap_put(&index->results, entry);
		index->results_nr++;
	}
	return maybe;
}

static int pickaxe_match(struct diff_filepair *p, struct diff_options *o,
			 regex_t *regexp, kwset_t kws, pickaxe_fn fn)
{
	struct userdiff_driver *textconv_one = NULL;
	struct userdiff_driver *textconv_two = NULL;
	struct diff_pickaxe_index *index =
		o->pickaxe_index_state ? *o->pickaxe_index_state : NULL;
	mmfile_t mf1, mf2;
	int ret;

	/* ignore unmerged */
	if (!DIFF_FILE_VALID(p->one) && !DIFF_FILE_VALID(p->two))
		return 0;

	if (o->objfind) {
		return  (DIFF_FILE_VALID(p->one) &&
			 oidset_contains(o->objfind, &p->one->oid)) ||
			(DIFF_FILE_VALID(p->two) &&
			 oidset_contains(o->objfind, &p->two->oid));
	}

	if (o->flags.allow_textconv) {
		textconv_one = get_textconv(o->repo, p->one);
		textconv_two = get_textconv(o->repo, p->two);
	}

	/*
	 * If we have an unmodified pair, we know that the count will be the
	 * same and don't even have to load the blobs. Unless textconv is in
	 * play, _and_ we are using two different textconv filters (e.g.,
	 * because a pair is an exact rename with different textconv attributes
	 * for each side, which might generate different content).
	 */
	if (textconv_one == textconv_two && diff_unmodified_pair(p))
		return 0;

	if (index && index->query &&
	    !textconv_one && !textconv_two &&
	    !pickaxe_index_maybe_contains(
		    index, o->repo, p->one) &&
	    !pickaxe_index_maybe_contains(
		    index, o->repo, p->two)) {
		index->impossible_pairs++;
		return 0;
	}

	if ((o->pickaxe_opts & DIFF_PICKAXE_KIND_G) &&
	    !o->flags.text &&
	    ((!textconv_one && diff_filespec_is_binary(o->repo, p->one)) ||
	     (!textconv_two && diff_filespec_is_binary(o->repo, p->two))))
		return 0;

	mf1.size = fill_textconv(o->repo, textconv_one, p->one, &mf1.ptr);
	mf2.size = fill_textconv(o->repo, textconv_two, p->two, &mf2.ptr);

	ret = fn(&mf1, &mf2, o, regexp, kws);

	if (textconv_one)
		free(mf1.ptr);
	if (textconv_two)
		free(mf2.ptr);
	diff_free_filespec_data(p->one);
	diff_free_filespec_data(p->two);

	return ret;
}

static void pickaxe(struct diff_queue_struct *q, struct diff_options *o,
		    regex_t *regexp, kwset_t kws, pickaxe_fn fn)
{
	int i;
	struct diff_queue_struct outq = DIFF_QUEUE_INIT;

	if (o->pickaxe_opts & DIFF_PICKAXE_ALL) {
		/* Showing the whole changeset if needle exists */
		for (i = 0; i < q->nr; i++) {
			struct diff_filepair *p = q->queue[i];
			if (pickaxe_match(p, o, regexp, kws, fn))
				return; /* do not munge the queue */
		}

		/*
		 * Otherwise we will clear the whole queue by copying
		 * the empty outq at the end of this function, but
		 * first clear the current entries in the queue.
		 */
		for (i = 0; i < q->nr; i++)
			diff_free_filepair(q->queue[i]);
	} else {
		/* Showing only the filepairs that has the needle */
		for (i = 0; i < q->nr; i++) {
			struct diff_filepair *p = q->queue[i];
			if (pickaxe_match(p, o, regexp, kws, fn))
				diff_q(&outq, p);
			else
				diff_free_filepair(p);
		}
	}

	free(q->queue);
	*q = outq;
}

static void regcomp_or_die(regex_t *regex, const char *needle, int cflags)
{
	int err = regcomp(regex, needle, cflags);
	if (err) {
		/* The POSIX.2 people are surely sick */
		char errbuf[1024];
		regerror(err, regex, errbuf, 1024);
		die("invalid regex: %s", errbuf);
	}
}

void diffcore_pickaxe(struct diff_options *o)
{
	const char *needle = o->pickaxe;
	int opts = o->pickaxe_opts;
	size_t min_index_pairs = git_env_ulong(
		"GIT_TEST_PICKAXE_CONTENT_INDEX_MIN_PAIRS",
		PICKAXE_INDEX_MIN_PAIRS);
	size_t max_direct_oids = git_env_ulong(
		"GIT_TEST_PICKAXE_CONTENT_INDEX_DIRECT_MAX_OIDS",
		PICKAXE_INDEX_DIRECT_MAX_OIDS);
	unsigned query_opts =
		opts & (DIFF_PICKAXE_KINDS_G_REGEX_MASK |
			DIFF_PICKAXE_IGNORE_CASE);
	int indexable_ere =
		!(query_opts & DIFF_PICKAXE_KINDS_G_REGEX_MASK) ||
		!(query_opts & DIFF_PICKAXE_IGNORE_CASE);
	struct diff_pickaxe_index *index =
		o->pickaxe_index_state ? *o->pickaxe_index_state : NULL;
	regex_t regex, *regexp = NULL;
	kwset_t kws = NULL;
	pickaxe_fn fn;

	if (opts & ~DIFF_PICKAXE_KIND_OBJFIND &&
	    (!needle || !*needle))
		BUG("should have needle under -G or -S");
	if (opts & (DIFF_PICKAXE_REGEX | DIFF_PICKAXE_KIND_G)) {
		int cflags = REG_EXTENDED | REG_NEWLINE;
		if (o->pickaxe_opts & DIFF_PICKAXE_IGNORE_CASE)
			cflags |= REG_ICASE;
		regcomp_or_die(&regex, needle, cflags);
		regexp = &regex;

		if (opts & DIFF_PICKAXE_KIND_G)
			fn = diff_grep;
		else if (opts & DIFF_PICKAXE_REGEX)
			fn = has_changes;
		else
			/*
			 * We don't need to check the combination of
			 * -G and --pickaxe-regex, by the time we get
			 * here diff.c has already died if they're
			 * combined. See the usage tests in
			 * t4209-log-pickaxe.sh.
			 */
			BUG("unreachable");
	} else if (opts & DIFF_PICKAXE_KIND_S) {
		if (o->pickaxe_opts & DIFF_PICKAXE_IGNORE_CASE &&
		    has_non_ascii(needle)) {
			struct strbuf sb = STRBUF_INIT;
			int cflags = REG_NEWLINE | REG_ICASE;

			basic_regex_quote_buf(&sb, needle);
			regcomp_or_die(&regex, sb.buf, cflags);
			strbuf_release(&sb);
			regexp = &regex;
		} else {
			kws = kwsalloc(o->pickaxe_opts & DIFF_PICKAXE_IGNORE_CASE
				       ? tolower_trans_tbl : NULL);
			kwsincr(kws, needle, strlen(needle));
			kwsprep(kws);
		}
		fn = has_changes;
	} else if (opts & DIFF_PICKAXE_KIND_OBJFIND) {
		fn = NULL;
	} else {
		BUG("unknown pickaxe_opts flag");
	}

	if ((opts & (DIFF_PICKAXE_KIND_S | DIFF_PICKAXE_KIND_G)) &&
	    o->pickaxe_index_state) {
		if (index &&
		    (strcmp(index->needle, needle) ||
		     index->pickaxe_opts != query_opts ||
		     index->text != o->flags.text)) {
			diff_pickaxe_index_clear(o->pickaxe_index_state);
			index = NULL;
		}
		if (!index) {
			CALLOC_ARRAY(index, 1);
			index->repo = o->repo;
			index->needle = xstrdup(needle);
			index->pickaxe_opts = query_opts;
			index->text = o->flags.text;
			oidmap_init(&index->results, 0);
			*o->pickaxe_index_state = index;
		}
		if (index->pairs < min_index_pairs) {
			size_t remaining = min_index_pairs - index->pairs;

			index->pairs +=
				MIN((size_t)diff_queued_diff.nr, remaining);
		}
		if (!index->tried && index->pairs == min_index_pairs) {
			struct grep_opt opt;

			index->tried = 1;
			/*
			 * Pickaxe EREs use the platform REG_ICASE rules,
			 * which need not match the case-folding contract
			 * used by grep index queries.
			 */
			if (indexable_ere &&
			    git_env_bool(
				    "GIT_TEST_PICKAXE_CONTENT_INDEX", 1)) {
				grep_init(&opt, o->repo);
				opt.pattern_type_option =
					(query_opts &
					 DIFF_PICKAXE_KINDS_G_REGEX_MASK) ?
						GREP_PATTERN_TYPE_ERE :
						GREP_PATTERN_TYPE_FIXED;
				opt.ignore_case =
					!!(opts & DIFF_PICKAXE_IGNORE_CASE);
				append_grep_pattern(
					&opt, needle, "pickaxe", 0,
					GREP_PATTERN);
				compile_grep_patterns(&opt);
				index->query =
					grep_index_query_create(&opt);
				free_grep_patterns(&opt);
				if (index->query &&
				    (opts & DIFF_PICKAXE_KIND_G) &&
				    !o->flags.text)
					index->persistent_only = 1;
				else if (index->query)
					index->ipc =
						grep_index_ipc_is_available(
							o->repo);
			}
		}
	}

	if (index && index->ipc &&
	    index->results_nr < PICKAXE_INDEX_MAX_ENTRIES) {
		struct oidset pending = OIDSET_INIT;
		struct grep_index_location *locations = NULL;
		struct object_id *oids = NULL;
		unsigned char *maybe = NULL;
		size_t oids_nr = 0;
		size_t oids_alloc = 0;
		size_t remaining = PICKAXE_INDEX_MAX_ENTRIES -
				   index->results_nr;
		int queried = 0;

		for (int i = 0; i < diff_queued_diff.nr; i++) {
			struct diff_filepair *p =
				diff_queued_diff.queue[i];
			struct diff_filespec *specs[] = {
				p->one, p->two
			};

			if (o->flags.allow_textconv &&
			    (get_textconv(o->repo, p->one) ||
			     get_textconv(o->repo, p->two)))
				continue;
			for (size_t j = 0; j < ARRAY_SIZE(specs); j++) {
				struct diff_filespec *spec = specs[j];

				if (!DIFF_FILE_VALID(spec) ||
				    !spec->oid_valid ||
				    !S_ISREG(spec->mode) ||
				    oidmap_get(
					    &index->results,
					    &spec->oid) ||
				    oidset_insert(&pending, &spec->oid))
					continue;
				ALLOC_GROW(oids, oids_nr + 1,
					   oids_alloc);
				oidcpy(&oids[oids_nr++], &spec->oid);
				if (oids_nr == remaining)
					goto query;
			}
		}

	query:
		if (oids_nr && oids_nr <= max_direct_oids) {
			/*
			 * Small history diffs would otherwise pay for one
			 * IPC connection and client thread per commit. Prepare
			 * the local transposed index once when it covers every
			 * object in this batch. The daemon remains responsible
			 * for historical objects missing from the persistent
			 * index and for larger batches.
			 */
			if (!index->direct_tried) {
				index->direct_tried = 1;
				index->index = grep_index_load(o->repo);
			}
			if (index->index) {
				int covered = 1;

				ALLOC_ARRAY(locations, oids_nr);
				for (size_t i = 0; i < oids_nr; i++)
					if (grep_index_resolve_location(
						    index->index, &oids[i],
						    &locations[i])) {
						covered = 0;
						break;
					}
				if (covered && !index->prepared)
					index->prepared =
						grep_index_prepare(
							index->index,
							index->query);
				if (covered && index->prepared) {
					ALLOC_ARRAY(maybe, oids_nr);
					for (size_t i = 0; i < oids_nr; i++) {
						int contains =
							grep_index_prepared_location_maybe_contains(
								index->prepared,
								&locations[i]);

						maybe[i] = contains ?
							GREP_INDEX_IPC_MAYBE :
							GREP_INDEX_IPC_IMPOSSIBLE;
					}
					index->direct_batches++;
					queried = 1;
				}
			}
		}
		if (oids_nr && !queried) {
			if (!maybe)
				ALLOC_ARRAY(maybe, oids_nr);
			if (!grep_index_ipc_query(
				    o->repo,
				    index->query,
				    oids, oids_nr, maybe)) {
				index->ipc_batches++;
				queried = 1;
			} else {
				index->ipc = 0;
				index->ipc_failures++;
			}
		}
		if (queried) {
			for (size_t i = 0; i < oids_nr; i++) {
				struct diff_pickaxe_index_entry *entry;

				CALLOC_ARRAY(entry, 1);
				oidcpy(&entry->entry.oid, &oids[i]);
				entry->maybe =
					maybe[i] !=
					GREP_INDEX_IPC_IMPOSSIBLE;
				oidmap_put(&index->results, entry);
				index->results_nr++;
			}
			index->tested += oids_nr;
		}
		free(locations);
		free(maybe);
		free(oids);
		oidset_clear(&pending);
	}
	if (index && index->query && !index->ipc &&
	    !index->direct_tried) {
		index->direct_tried = 1;
		index->index = grep_index_load(o->repo);
		if (index->index && !index->persistent_only)
			index->prepared =
				grep_index_prepare(index->index, index->query);
	}

	pickaxe(&diff_queued_diff, o, regexp, kws, fn);

	if (regexp)
		regfree(regexp);
	if (kws)
		kwsfree(kws);
	return;
}

void diff_pickaxe_index_clear(struct diff_pickaxe_index **state)
{
	struct diff_pickaxe_index *index = *state;

	if (!index)
		return;
	trace2_data_intmax("pickaxe", index->repo, "content_index/tested",
			   index->tested);
	trace2_data_intmax("pickaxe", index->repo, "content_index/prepared",
			   !!index->prepared);
	trace2_data_intmax("pickaxe", index->repo, "content_index/query",
			   !!index->query);
	trace2_data_intmax("pickaxe", index->repo, "content_index/index",
			   !!index->index);
	trace2_data_intmax("pickaxe", index->repo, "content_index/ipc",
			   index->ipc);
	trace2_data_intmax("pickaxe", index->repo,
			   "content_index/persistent_only",
			   index->persistent_only);
	trace2_data_intmax("pickaxe", index->repo,
			   "content_index/direct_batches",
			   index->direct_batches);
	trace2_data_intmax("pickaxe", index->repo, "content_index/ipc_batches",
			   index->ipc_batches);
	trace2_data_intmax("pickaxe", index->repo,
			   "content_index/ipc_failures",
			   index->ipc_failures);
	trace2_data_intmax("pickaxe", index->repo, "content_index/cache_hits",
			   index->cache_hits);
	trace2_data_intmax("pickaxe", index->repo,
			   "content_index/impossible_pairs",
			   index->impossible_pairs);
	oidmap_clear(&index->results, 1);
	grep_index_prepared_free(index->prepared);
	grep_index_query_free(index->query);
	grep_index_free(index->index);
	free(index->needle);
	free(index);
	*state = NULL;
}

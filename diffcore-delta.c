#include "git-compat-util.h"
#include "diffcore.h"
#include "list.h"
#include "repository.h"
#include "trace2.h"
#include "xdiff-interface.h"

/*
 * Idea here is very simple.
 *
 * Almost all data we are interested in are text, but sometimes we have
 * to deal with binary data.  So we cut them into chunks delimited by
 * LF byte, or 64-byte sequence, whichever comes first, and hash them.
 *
 * For those chunks, if the source buffer has more instances of it
 * than the destination buffer, that means the difference are the
 * number of bytes not copied from source to destination.  If the
 * counts are the same, everything was copied from source to
 * destination.  If the destination has more, everything was copied,
 * and destination added more.
 *
 * We are doing an approximation so we do not really have to waste
 * memory by actually storing the sequence.  We just hash them into
 * somewhere around 2^16 hashbuckets and count the occurrences.
 */

/* Wild guess at the initial hash size */
#define INITIAL_HASH_SIZE 9

/* We leave more room in smaller hash but do not let it
 * grow to have unused hole too much.
 */
#define INITIAL_FREE(sz_log2) ((1<<(sz_log2))*(sz_log2-3)/(sz_log2))

/* A prime rather carefully chosen between 2^16..2^17, so that
 * HASHBASE < INITIAL_FREE(17).  We want to keep the maximum hashtable
 * size under the current 2<<17 maximum, which can hold this many
 * different values before overflowing to hashtable of size 2<<18.
 */
#define HASHBASE 107927

struct spanhash {
	unsigned int hashval;
	unsigned int cnt;
};
struct spanhash_top {
	int alloc_log2;
	int free;
	struct spanhash data[FLEX_ARRAY];
};

/* Retained cache memory is limited per repository, including the buckets. */
#define SPANHASH_CACHE_LIMIT (32u * 1024u * 1024u)
#define SPANHASH_CACHE_BUCKETS (1u << 13)
#define SPAN_SAMPLE_MODULUS 64
#define SPAN_SAMPLE_MAX_KEYS (1u << 16)
#define SPAN_SAMPLE_MAX_SELECTED (1u << 18)

enum span_hash_mode {
	SPAN_HASH_BINARY,
	SPAN_HASH_TEXT,
	SPAN_HASH_NO_CRLF,
};

struct span_cache_entry {
	struct span_cache_entry *next;
	struct list_head lru;
	struct object_id oid;
	struct spanhash_top *value;
	size_t value_bytes;
	enum span_hash_mode mode;
	unsigned char auto_binary;
};

struct diff_spanhash_cache {
	struct span_cache_entry **buckets;
	struct list_head lru;
	size_t entry_bytes;
};

struct span_sample_entry {
	struct span_sample_entry *next;
	struct repository *repo;
	struct object_id oid;
	uint64_t last_build;
	enum span_hash_mode mode;
};

struct span_sample_state {
	struct span_sample_entry **buckets;
	uint64_t build, selected, first, repeat_hit, repeat_miss;
	uint64_t miss_gap_le_4096, miss_gap_le_65536, miss_gap_gt_65536;
	size_t keys;
	int invalid, truncated, registered;
};

static pthread_mutex_t span_cache_mutex = PTHREAD_MUTEX_INITIALIZER;
static uintmax_t span_cache_hits, span_cache_misses, span_cache_evictions;
static uintmax_t span_cache_bypassed, span_cache_retained, span_cache_peak;
static int span_cache_report_registered;
static struct span_sample_state span_sample;

static size_t spanhash_bytes(const struct spanhash_top *value)
{
	size_t nr = 0;

	/* Cached tables only need the finalized prefix and its terminator. */
	while (value->data[nr].cnt)
		nr++;
	return st_add(sizeof(*value),
		      st_mult(sizeof(value->data[0]), st_add(nr, 1)));
}

static size_t span_cache_bucket(const struct object_id *oid,
				enum span_hash_mode mode)
{
	return (oidhash(oid) ^ (mode * 0x9e3779b9u)) &
	       (SPANHASH_CACHE_BUCKETS - 1);
}

static void span_sample_report(void)
{
	int saved_errno = errno;

	trace2_data_intmax("diff", NULL, "spanhash/build-sample/valid",
			   !span_sample.invalid);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/truncated",
			   span_sample.truncated);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/selected",
			   span_sample.selected);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/first",
			   span_sample.first);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/repeat-hit",
			   span_sample.repeat_hit);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/repeat-miss",
			   span_sample.repeat_miss);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/miss-gap-le-4096",
			   span_sample.miss_gap_le_4096);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/miss-gap-le-65536",
			   span_sample.miss_gap_le_65536);
	trace2_data_intmax("diff", NULL, "spanhash/build-sample/miss-gap-gt-65536",
			   span_sample.miss_gap_gt_65536);
	errno = saved_errno;
}

/* Called under span_cache_mutex; gaps count build lookups, not time or bytes. */
static uint64_t span_sample_probe(struct repository *r,
				  const struct object_id *oid,
				  enum span_hash_mode mode)
{
	struct span_sample_entry *entry;
	size_t bucket;
	uint64_t gap = 0;

	if (!trace2_is_enabled() || !oid->algo || span_sample.invalid)
		return 0;
	if (!span_sample.buckets) {
		if (oid->hash[0] & (SPAN_SAMPLE_MODULUS - 1))
			return 0;
		if (!span_sample.registered) {
			if (atexit(span_sample_report)) {
				span_sample.invalid = 1;
				return 0;
			}
			span_sample.registered = 1;
		}
		span_sample.buckets = calloc(SPANHASH_CACHE_BUCKETS,
					    sizeof(*span_sample.buckets));
		if (!span_sample.buckets) {
			span_sample.invalid = 1;
			return 0;
		}
	}
	if (span_sample.build == UINT64_MAX) {
		span_sample.invalid = 1;
		return 0;
	}
	span_sample.build++;
	if (oid->hash[0] & (SPAN_SAMPLE_MODULUS - 1))
		return 0;
	if (span_sample.selected == SPAN_SAMPLE_MAX_SELECTED) {
		span_sample.invalid = span_sample.truncated = 1;
		return 0;
	}
	bucket = span_cache_bucket(oid, mode);
	for (entry = span_sample.buckets[bucket]; entry; entry = entry->next)
		if (entry->repo == r && entry->mode == mode &&
		    entry->oid.algo == oid->algo && oideq(&entry->oid, oid))
			break;
	if (!entry) {
		if (span_sample.keys == SPAN_SAMPLE_MAX_KEYS) {
			span_sample.invalid = span_sample.truncated = 1;
			return 0;
		}
		entry = malloc(sizeof(*entry));
		if (!entry) {
			span_sample.invalid = 1;
			return 0;
		}
		entry->repo = r;
		oidcpy(&entry->oid, oid);
		entry->mode = mode;
		entry->next = span_sample.buckets[bucket];
		span_sample.buckets[bucket] = entry;
		span_sample.keys++;
		span_sample.first++;
	} else {
		gap = span_sample.build - entry->last_build;
	}
	entry->last_build = span_sample.build;
	span_sample.selected++;
	return gap;
}

/* A cleared repository can be reallocated at the same address. */
static void span_sample_clear_repo(struct repository *r)
{
	size_t i;

	if (!span_sample.buckets)
		return;
	for (i = 0; i < SPANHASH_CACHE_BUCKETS; i++) {
		struct span_sample_entry **slot = &span_sample.buckets[i];

		while (*slot) {
			struct span_sample_entry *entry = *slot;

			if (entry->repo != r) {
				slot = &entry->next;
				continue;
			}
			*slot = entry->next;
			free(entry);
			span_sample.keys--;
		}
	}
}

static struct span_cache_entry *span_cache_find(struct diff_spanhash_cache *cache,
						const struct object_id *oid,
						enum span_hash_mode mode)
{
	struct span_cache_entry *entry;

	for (entry = cache->buckets[span_cache_bucket(oid, mode)]; entry;
	     entry = entry->next)
		if (entry->mode == mode && entry->oid.algo == oid->algo &&
		    oideq(&entry->oid, oid))
			return entry;
	return NULL;
}

static size_t span_cache_bytes(const struct diff_spanhash_cache *cache)
{
	return st_add(st_add(sizeof(*cache), cache->entry_bytes),
		      sizeof(cache->buckets[0]) * SPANHASH_CACHE_BUCKETS);
}

static void span_cache_update_retained(size_t before, size_t after)
{
	if (after >= before)
		span_cache_retained += after - before;
	else
		span_cache_retained -= before - after;
	if (span_cache_retained > span_cache_peak)
		span_cache_peak = span_cache_retained;
}

static void span_cache_report(void)
{
	int saved_errno = errno;

	/* This callback runs before Trace2's earlier-registered exit callback. */
	trace2_data_intmax("diff", NULL, "spanhash/cache/hits", span_cache_hits);
	trace2_data_intmax("diff", NULL, "spanhash/cache/misses", span_cache_misses);
	trace2_data_intmax("diff", NULL, "spanhash/cache/evictions",
			   span_cache_evictions);
	trace2_data_intmax("diff", NULL, "spanhash/cache/bypassed",
			   span_cache_bypassed);
	trace2_data_intmax("diff", NULL, "spanhash/cache/peak_bytes",
			   span_cache_peak);
	errno = saved_errno;
}

static struct diff_spanhash_cache *span_cache_init(struct repository *r)
{
	struct diff_spanhash_cache *cache = malloc(sizeof(*cache));

	if (!cache)
		return NULL;
	cache->buckets = calloc(SPANHASH_CACHE_BUCKETS,
					sizeof(cache->buckets[0]));
	if (!cache->buckets) {
		free(cache);
		return NULL;
	}

	INIT_LIST_HEAD(&cache->lru);
	cache->entry_bytes = 0;
	r->spanhash_cache = cache;
	span_cache_update_retained(0, span_cache_bytes(cache));
	if (!span_cache_report_registered && !atexit(span_cache_report))
		span_cache_report_registered = 1;
	return cache;
}

static void span_cache_clear_locked(struct repository *r)
{
	struct diff_spanhash_cache *cache = r->spanhash_cache;
	size_t before;

	if (!cache)
		return;
	before = span_cache_bytes(cache);
	while (cache->lru.next != &cache->lru) {
		struct span_cache_entry *entry =
			list_first_entry(&cache->lru, struct span_cache_entry, lru);

		list_del(&entry->lru);
		free(entry->value);
		free(entry);
	}
	free(cache->buckets);
	FREE_AND_NULL(r->spanhash_cache);
	span_cache_update_retained(before, 0);
}

static struct spanhash_top *span_cache_lookup(struct repository *r,
					      struct diff_filespec *one,
					      enum span_hash_mode *mode)
{
	struct diff_spanhash_cache *cache;
	struct span_cache_entry *entry;
	struct spanhash_top *copy = NULL;
	int driver_loaded = 0, is_binary = -1;
	int saved_errno = errno;

retry:
	pthread_mutex_lock(&span_cache_mutex);
	cache = r->spanhash_cache;
	if (!cache)
		goto done;
	entry = span_cache_find(cache, &one->oid, SPAN_HASH_NO_CRLF);
	if (!entry) {
		struct span_cache_entry *text =
			span_cache_find(cache, &one->oid, SPAN_HASH_TEXT);
		struct span_cache_entry *binary =
			span_cache_find(cache, &one->oid, SPAN_HASH_BINARY);

		if (!text && !binary)
			goto done;
		/* Resolve attributes only when a cached table depends on them. */
		if (!driver_loaded) {
			pthread_mutex_unlock(&span_cache_mutex);
			is_binary = diff_filespec_binary_driver(r, one);
			driver_loaded = 1;
			goto retry;
		}
		if (is_binary >= 0)
			entry = is_binary ? binary : text;
		else if (text && !text->auto_binary)
			entry = text;
		else if (binary && binary->auto_binary)
			entry = binary;
	}
	if (entry) {
		copy = malloc(entry->value_bytes);
		if (copy) {
			memcpy(copy, entry->value, entry->value_bytes);
			*mode = entry->mode;
			/* A no-CRLF table does not identify this path's driver. */
			if (*mode != SPAN_HASH_NO_CRLF)
				one->is_binary = *mode == SPAN_HASH_BINARY;
			list_move(&entry->lru, &cache->lru);
			span_cache_hits++;
		} else {
			/* Reclaim optional memory before building the usual table. */
			span_cache_clear_locked(r);
			span_cache_bypassed++;
		}
	}
done:
	pthread_mutex_unlock(&span_cache_mutex);
	errno = saved_errno;
	return copy;
}

static void span_sample_record(struct repository *r, const struct object_id *oid,
			       enum span_hash_mode mode, int hit)
{
	uint64_t sample_gap;

	/* The mode is known only after lookup or hashing. */
	pthread_mutex_lock(&span_cache_mutex);
	sample_gap = span_sample_probe(r, oid, mode);
	if (sample_gap) {
		if (hit)
			span_sample.repeat_hit++;
		else {
			span_sample.repeat_miss++;
			if (sample_gap <= 4096)
				span_sample.miss_gap_le_4096++;
			else if (sample_gap <= 65536)
				span_sample.miss_gap_le_65536++;
			else
				span_sample.miss_gap_gt_65536++;
		}
	}
	if (!hit)
		span_cache_misses++;
	pthread_mutex_unlock(&span_cache_mutex);
}

static void span_cache_insert(struct repository *r,
			      const struct diff_filespec *one,
			      enum span_hash_mode mode,
			      const struct spanhash_top *value)
{
	const struct object_id *oid = &one->oid;
	struct diff_spanhash_cache *cache;
	struct span_cache_entry *entry;
	size_t bucket;
	size_t bytes = spanhash_bytes(value), before;

	/* A single oversized table is used normally, but not retained. */
	if (bytes > SPANHASH_CACHE_LIMIT - sizeof(*entry) -
		    sizeof(*cache) - SPANHASH_CACHE_BUCKETS * sizeof(void *)) {
		pthread_mutex_lock(&span_cache_mutex);
		span_cache_bypassed++;
		pthread_mutex_unlock(&span_cache_mutex);
		return;
	}
	pthread_mutex_lock(&span_cache_mutex);
	cache = r->spanhash_cache;
	if (!cache)
		cache = span_cache_init(r);
	if (!cache) {
		span_cache_bypassed++;
		goto done;
	}
	if (span_cache_find(cache, oid, mode))
		goto done; /* Another caller filled this key while we built it. */
	before = span_cache_bytes(cache);
	/* Leave room before allocating the new value, including its entry. */
	while (span_cache_bytes(cache) >
	       SPANHASH_CACHE_LIMIT - sizeof(*entry) - bytes) {
		struct span_cache_entry *oldest =
			list_entry(cache->lru.prev, struct span_cache_entry, lru);
		struct span_cache_entry **slot =
			&cache->buckets[span_cache_bucket(&oldest->oid,
							  oldest->mode)];

		while (*slot && *slot != oldest)
			slot = &(*slot)->next;
		assert(*slot == oldest);
		*slot = oldest->next;
		list_del(&oldest->lru);
		cache->entry_bytes -= sizeof(*oldest) + oldest->value_bytes;
		free(oldest->value);
		free(oldest);
		span_cache_evictions++;
	}
	entry = malloc(sizeof(*entry));
	if (!entry) {
		span_cache_bypassed++;
		goto updated;
	}
	oidcpy(&entry->oid, oid);
	entry->mode = mode;
	entry->auto_binary = mode != SPAN_HASH_NO_CRLF && one->size &&
			     buffer_is_binary(one->data, one->size);
	entry->value_bytes = bytes;
	entry->value = malloc(bytes);
	if (!entry->value) {
		free(entry);
		span_cache_bypassed++;
		goto updated;
	}
	memcpy(entry->value, value, bytes);
	bucket = span_cache_bucket(oid, mode);
	entry->next = cache->buckets[bucket];
	cache->buckets[bucket] = entry;
	list_add(&entry->lru, &cache->lru);
	cache->entry_bytes += sizeof(*entry) + bytes;
updated:
	span_cache_update_retained(before, span_cache_bytes(cache));
done:
	pthread_mutex_unlock(&span_cache_mutex);
}

void diffcore_delta_cache_clear(struct repository *r)
{
	pthread_mutex_lock(&span_cache_mutex);
	span_cache_clear_locked(r);
	span_sample_clear_repo(r);
	pthread_mutex_unlock(&span_cache_mutex);
}

static struct spanhash_top *spanhash_rehash(struct spanhash_top *orig)
{
	struct spanhash_top *new_spanhash;
	int i;
	int osz = 1 << orig->alloc_log2;
	int sz = osz << 1;

	new_spanhash = xmalloc(st_add(sizeof(*orig),
			     st_mult(sizeof(struct spanhash), sz)));
	new_spanhash->alloc_log2 = orig->alloc_log2 + 1;
	new_spanhash->free = INITIAL_FREE(new_spanhash->alloc_log2);
	MEMZERO_ARRAY(new_spanhash->data, sz);
	for (i = 0; i < osz; i++) {
		struct spanhash *o = &(orig->data[i]);
		int bucket;
		if (!o->cnt)
			continue;
		bucket = o->hashval & (sz - 1);
		while (1) {
			struct spanhash *h = &(new_spanhash->data[bucket++]);
			if (!h->cnt) {
				h->hashval = o->hashval;
				h->cnt = o->cnt;
				new_spanhash->free--;
				break;
			}
			if (sz <= bucket)
				bucket = 0;
		}
	}
	free(orig);
	return new_spanhash;
}

static struct spanhash_top *add_spanhash(struct spanhash_top *top,
					 unsigned int hashval, int cnt)
{
	int bucket, lim;
	struct spanhash *h;

	lim = (1 << top->alloc_log2);
	bucket = hashval & (lim - 1);
	while (1) {
		h = &(top->data[bucket++]);
		if (!h->cnt) {
			h->hashval = hashval;
			h->cnt = cnt;
			top->free--;
			if (top->free < 0)
				return spanhash_rehash(top);
			return top;
		}
		if (h->hashval == hashval) {
			h->cnt += cnt;
			return top;
		}
		if (lim <= bucket)
			bucket = 0;
	}
}

static int spanhash_cmp(const void *a_, const void *b_)
{
	const struct spanhash *a = a_;
	const struct spanhash *b = b_;

	/* Empty buckets have been removed before sorting. */
	return a->hashval < b->hashval ? -1 :
		a->hashval > b->hashval ? 1 : 0;
}

static struct spanhash_top *hash_chars(struct repository *r,
				       struct diff_filespec *one,
				       enum span_hash_mode *mode)
{
	int i, n;
	unsigned int accum1, accum2, hashval;
	size_t buckets, occupied = 0;
	struct spanhash_top *hash;
	unsigned char *buf = one->data;
	unsigned int sz = one->size;

	*mode = SPAN_HASH_NO_CRLF;

	i = INITIAL_HASH_SIZE;
	hash = xmalloc(st_add(sizeof(*hash),
			      st_mult(sizeof(struct spanhash), (size_t)1 << i)));
	hash->alloc_log2 = i;
	hash->free = INITIAL_FREE(i);
	MEMZERO_ARRAY(hash->data, (size_t)1 << i);

	n = 0;
	accum1 = accum2 = 0;
	while (sz) {
		unsigned int c = *buf++;
		unsigned int old_1 = accum1;
		sz--;

		/* Text and binary hashes differ only for CRLF sequences. */
		if (c == '\r' && sz && *buf == '\n') {
			if (*mode == SPAN_HASH_NO_CRLF)
				*mode = diff_filespec_is_binary(r, one) ?
						SPAN_HASH_BINARY :
						SPAN_HASH_TEXT;
			if (*mode == SPAN_HASH_TEXT)
				continue;
		}

		accum1 = (accum1 << 7) ^ (accum2 >> 25);
		accum2 = (accum2 << 7) ^ (old_1 >> 25);
		accum1 += c;
		if (++n < 64 && c != '\n')
			continue;
		hashval = (accum1 + accum2 * 0x61) % HASHBASE;
		hash = add_spanhash(hash, hashval, n);
		n = 0;
		accum1 = accum2 = 0;
	}
	if (n > 0) {
		hashval = (accum1 + accum2 * 0x61) % HASHBASE;
		hash = add_spanhash(hash, hashval, n);
	}
	/* The similarity comparison reads only the sorted, occupied prefix. */
	buckets = (size_t)1ul << hash->alloc_log2;
	for (size_t j = 0; j < buckets; j++) {
		if (!hash->data[j].cnt)
			continue;
		if (j != occupied) {
			hash->data[occupied] = hash->data[j];
			hash->data[j].cnt = 0;
		}
		occupied++;
	}
	hash->data[occupied].cnt = 0;
	QSORT(hash->data, occupied, spanhash_cmp);
	return hash;
}

static struct spanhash_top *get_spanhash(struct repository *r,
					struct diff_filespec *one,
					void **count_p)
{
	struct spanhash_top *count = count_p ? *count_p : NULL;

	if (!count) {
		int saved_errno = errno;
		enum span_hash_mode mode;
		int hit;

		if (one->oid_data_unreplaced)
			count = span_cache_lookup(r, one, &mode);
		hit = !!count;

		if (!count) {
			trace2_timer_start(TRACE2_TIMER_ID_DIFF_SPANHASH_BUILD);
			errno = saved_errno;
			count = hash_chars(r, one, &mode);
			saved_errno = errno;
			trace2_timer_stop(TRACE2_TIMER_ID_DIFF_SPANHASH_BUILD);
			if (one->oid_data_unreplaced)
				span_cache_insert(r, one, mode, count);
		}
		/* Prepopulation probes do not necessarily lead to a build lookup. */
		if (one->oid_data_unreplaced)
			span_sample_record(r, &one->oid, mode, hit);
		errno = saved_errno;
		if (count_p)
			*count_p = count;
	}
	return count;
}

void diffcore_reuse_cached_spanhash(struct repository *r,
				    struct diff_filespec *one)
{
	int saved_errno;
	enum span_hash_mode mode;
	struct spanhash_top *count;

	if (one->cnt_data || !diff_filespec_can_reuse_spanhash(r, one))
		return;

	saved_errno = errno;
	count = span_cache_lookup(r, one, &mode);
	if (count)
		one->cnt_data = count;
	errno = saved_errno;
}

void diffcore_prepare_count_changes(struct repository *r,
				    struct diff_filespec *src,
				    struct diff_filespec *dst)
{
	get_spanhash(r, src, &src->cnt_data);
	get_spanhash(r, dst, &dst->cnt_data);
}

int diffcore_count_changes(struct repository *r,
			   struct diff_filespec *src,
			   struct diff_filespec *dst,
			   void **src_count_p,
			   void **dst_count_p,
			   unsigned long *src_copied,
			   unsigned long *literal_added)
{
	struct spanhash *s, *d;
	struct spanhash_top *src_count, *dst_count;
	unsigned long sc, la;
	int saved_errno;

	src_count = get_spanhash(r, src, src_count_p);
	dst_count = get_spanhash(r, dst, dst_count_p);

	saved_errno = errno;
	trace2_timer_start(TRACE2_TIMER_ID_DIFF_SPANHASH_COMPARE);
	errno = saved_errno;
	sc = la = 0;

	s = src_count->data;
	d = dst_count->data;
	for (;;) {
		unsigned dst_cnt, src_cnt;
		if (!s->cnt || !d->cnt)
			break; /* either input is exhausted */
		while (d->cnt) {
			if (d->hashval >= s->hashval)
				break;
			la += d->cnt;
			d++;
		}
		src_cnt = s->cnt;
		dst_cnt = 0;
		if (d->cnt && d->hashval == s->hashval) {
			dst_cnt = d->cnt;
			d++;
		}
		if (src_cnt < dst_cnt) {
			la += dst_cnt - src_cnt;
			sc += src_cnt;
		}
		else
			sc += dst_cnt;
		s++;
	}
	while (d->cnt) {
		la += d->cnt;
		d++;
	}

	saved_errno = errno;
	trace2_timer_stop(TRACE2_TIMER_ID_DIFF_SPANHASH_COMPARE);
	errno = saved_errno;

	if (!src_count_p)
		free(src_count);
	if (!dst_count_p)
		free(dst_count);
	*src_copied = sc;
	*literal_added = la;
	return 0;
}

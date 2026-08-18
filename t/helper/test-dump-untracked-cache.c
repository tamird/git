#define USE_THE_REPOSITORY_VARIABLE

#include "test-tool.h"
#include "dir.h"
#include "hash.h"
#include "hex.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "setup.h"
#include "wrapper.h"

#define UNTR_SIGNATURE 0x554e5452
#define UNRV_SIGNATURE 0x554e5256

struct cache_index {
	struct strbuf data;
	size_t end;
	size_t cache_offset;
	size_t cache_size;
	uint32_t cache_signature;
};

static void index_hash(unsigned char *hash, const void *data, size_t len)
{
	struct git_hash_ctx ctx;

	git_hash_init(&ctx, the_hash_algo);
	git_hash_update(&ctx, data, len);
	git_hash_final(hash, &ctx);
}

/* Deliberately support only the simple, production-written test fixture. */
static void read_cache_index(struct cache_index *index, const char *path,
			     int inventory)
{
	const unsigned char *data;
	unsigned char hash[GIT_MAX_RAWSZ];
	size_t pos = 12, fixed = 42 + the_hash_algo->rawsz;
	uint32_t nr;

	memset(index, 0, sizeof(*index));
	strbuf_init(&index->data, 0);
	if (strbuf_read_file(&index->data, path, 0) < 0)
		die_errno("cannot read index %s", path);
	data = (const unsigned char *)index->data.buf;
	if (index->data.len < 12 + the_hash_algo->rawsz ||
	    memcmp(data, "DIRC", 4) || get_be32(data + 4) != 2)
		die("expected a version-2 index");
	index->end = index->data.len - the_hash_algo->rawsz;
	index_hash(hash, data, index->end);
	if (memcmp(hash, data + index->end, the_hash_algo->rawsz))
		die("incorrect index checksum");
	nr = get_be32(data + 8);
	for (uint32_t i = 0; i < nr; i++) {
		const unsigned char *nul;
		size_t len, padded;
		unsigned flags;

		if (pos > index->end || fixed > index->end - pos)
			die("truncated index entry");
		flags = get_be16(data + pos + fixed - 2);
		if (flags & CE_EXTENDED)
			die("extended index entries are not supported");
		nul = memchr(data + pos + fixed, 0,
			     index->end - pos - fixed);
		if (!nul)
			die("unterminated index entry");
		len = nul - (data + pos);
		if ((flags & 0xfff) != 0xfff &&
		    (flags & 0xfff) != len - fixed)
			die("incorrect index entry name length");
		padded = st_add(len, 8) & ~(size_t)7;
		if (padded > index->end - pos)
			die("truncated index entry padding");
		for (size_t j = len; j < padded; j++)
			if (data[pos + j])
				die("nonzero index entry padding");
		pos += padded;
	}
	while (pos < index->end) {
		uint32_t signature, size;

		if (index->end - pos < 8)
			die("truncated index extension");
		signature = get_be32(data + pos);
		size = get_be32(data + pos + 4);
		if (size > index->end - pos - 8)
			die("truncated index extension body");
		if (!memcmp(data + pos, "link", 4) ||
		    !memcmp(data + pos, "EOIE", 4) ||
		    !memcmp(data + pos, "IEOT", 4))
			die("split-index, EOIE and IEOT are not supported");
		if (inventory) {
			printf("%.4s %u\n", (const char *)data + pos, size);
			if (signature == UNRV_SIGNATURE && size >= 22)
				printf("pending version=%u cutoff=%u.%09u body=%u\n",
				       get_be32(data + pos + 13),
				       get_be32(data + pos + 17),
				       get_be32(data + pos + 21),
				       get_be32(data + pos + 25));
		}
		if (signature == UNTR_SIGNATURE || signature == UNRV_SIGNATURE) {
			if (index->cache_signature && !inventory)
				die("expected exactly one untracked-cache extension");
			index->cache_offset = pos;
			index->cache_size = size;
			index->cache_signature = signature;
		}
		pos += 8 + (size_t)size;
	}
}

static void add_extension(struct strbuf *out, uint32_t signature,
			  const struct strbuf *body)
{
	unsigned char header[8];

	if (body->len > UINT32_MAX)
		die("untracked-cache extension too large");
	put_be32(header, signature);
	put_be32(header + 4, body->len);
	strbuf_add(out, header, sizeof(header));
	strbuf_addbuf(out, body);
}

static uint32_t parse_number(const char *value)
{
	char *end;
	uintmax_t number;

	errno = 0;
	number = strtoumax(value, &end, 10);
	if (errno || !*value || *end || number > UINT32_MAX)
		die("invalid number: %s", value);
	return number;
}

static struct untracked_cache_dir **find_node(
	struct untracked_cache_dir **slot, uint32_t *number)
{
	struct untracked_cache_dir **found;

	if (!*slot)
		return NULL;
	if (!*number)
		return slot;
	(*number)--;
	for (size_t i = 0; i < (*slot)->dirs_nr; i++) {
		found = find_node(&(*slot)->dirs[i], number);
		if (found)
			return found;
	}
	return NULL;
}

static void rename_node(struct untracked_cache_dir **slot, const char *name)
{
	struct untracked_cache_dir *old = *slot, *replacement;

	replacement = xmalloc(st_add3(sizeof(*replacement), strlen(name), 1));
	memcpy(replacement, old, sizeof(*replacement));
	memcpy(replacement->name, name, strlen(name) + 1);
	*slot = replacement;
	free(old);
}

static void mutate_node(struct strbuf *body, const char *arg, int siblings)
{
	struct untracked_cache *uc;
	struct untracked_cache_dir **slot;
	const char *colon = strchr(arg, ':');
	char *number;
	uint32_t index;

	if (!colon)
		die("node mutation requires an index and value");
	number = xmemdupz(arg, colon - arg);
	index = parse_number(number);
	free(number);
	uc = read_pending_untracked_extension(body->buf, body->len);
	if (!uc || !uc->root)
		die("node mutation requires a valid pending cache");
	slot = find_node(&uc->root, &index);
	if (!slot)
		die("untracked-cache node does not exist");
	if (!siblings) {
		rename_node(slot, colon + 1);
	} else {
		struct untracked_cache_dir *parent = *slot;

		if (parent->dirs_nr < 2)
			die("sibling mutation requires two children");
		if (!strcmp(colon + 1, "duplicate"))
			rename_node(&parent->dirs[1], parent->dirs[0]->name);
		else if (!strcmp(colon + 1, "reverse")) {
			struct untracked_cache_dir *first = parent->dirs[0];

			parent->dirs[0] = parent->dirs[1];
			parent->dirs[1] = first;
		} else {
			die("unknown sibling mutation: %s", colon + 1);
		}
	}
	strbuf_reset(body);
	if (write_untracked_extension(body, uc) !=
	    UNTRACKED_CACHE_ENCODING_PENDING)
		die("failed to encode mutated pending cache");
	free_untracked_cache(uc);
}

static void rewrite_index(const char *input, const char *output,
			  int argc, const char **argv)
{
	struct cache_index index;
	struct strbuf body = STRBUF_INIT, legacy = STRBUF_INIT;
	struct strbuf rewritten = STRBUF_INIT;
	unsigned char hash[GIT_MAX_RAWSZ];
	uint32_t signature = UNRV_SIGNATURE;
	int duplicate = 0, legacy_order = 0;

	read_cache_index(&index, input, 0);
	if (!index.cache_signature)
		die("index has no untracked cache");
	if (argc && !strcmp(argv[0], "--mark-pending")) {
		struct untracked_cache *uc;

		if (index.cache_signature != UNTR_SIGNATURE ||
		    repo_read_index(the_repository) < 0)
			die("mark-pending requires a trusted legacy index");
		uc = the_repository->index->untracked;
		if (!uc || !uc->root || !uc->root->valid ||
		    uc->fsmonitor_resync ||
		    !the_repository->index->timestamp.sec)
			die("mark-pending requires a trusted root and timestamp");
		untracked_cache_invalidate_all(the_repository->index);
		if (write_untracked_extension(&body, uc) !=
		    UNTRACKED_CACHE_ENCODING_PENDING)
			die("mark-pending did not produce a pending cache");
		argc--;
		argv++;
	} else {
		struct untracked_cache *uc;

		if (index.cache_signature != UNRV_SIGNATURE)
			die("mutation requires a pending index");
		strbuf_add(&body, index.data.buf + index.cache_offset + 8,
			   index.cache_size);
		uc = read_pending_untracked_extension(body.buf, body.len);
		if (!uc)
			die("mutation requires a valid pending cache");
		free_untracked_cache(uc);
	}
	strbuf_add(&legacy, body.buf + 21, get_be32(body.buf + 17));
	for (int i = 0; i < argc; i++) {
		const char *arg = argv[i], *value;

		if (skip_prefix(arg, "--node-name=", &value)) {
			mutate_node(&body, value, 0);
			strbuf_reset(&legacy);
			strbuf_add(&legacy, body.buf + 21, get_be32(body.buf + 17));
		} else if (skip_prefix(arg, "--siblings=", &value)) {
			mutate_node(&body, value, 1);
			strbuf_reset(&legacy);
			strbuf_add(&legacy, body.buf + 21, get_be32(body.buf + 17));
		} else if (!strcmp(arg, "--rename-pending=UXRV")) {
			signature = 0x55585256;
		} else if (skip_prefix(arg, "--set-pending=", &value)) {
			const char *number = strchr(value, ':');
			size_t offset;

			if (!number || body.len < 22)
				die("invalid pending field mutation");
			if (starts_with(value, "version:"))
				offset = 5;
			else if (starts_with(value, "sec:"))
				offset = 9;
			else if (starts_with(value, "nsec:"))
				offset = 13;
			else if (starts_with(value, "body-length:"))
				offset = 17;
			else if (starts_with(value, "magic:") ||
				 starts_with(value, "sentinel:")) {
				uint32_t byte = parse_number(number + 1);

				if (byte > 255)
					die("pending field is not a byte");
				body.buf[starts_with(value, "magic:") ?
					 0 : body.len - 1] = byte;
				continue;
			} else {
				die("unknown pending field: %s", value);
			}
			put_be32(body.buf + offset, parse_number(number + 1));
		} else if (skip_prefix(arg, "--truncate-pending=", &value)) {
			uint32_t len = parse_number(value);

			if (len > body.len)
				die("cannot extend pending cache by truncating it");
			strbuf_setlen(&body, len);
		} else if (!strcmp(arg, "--empty-body")) {
			if (body.len < 22)
				die("pending header is truncated");
			strbuf_setlen(&body, 21);
			put_be32(body.buf + 17, 0);
			strbuf_addch(&body, 0xa5);
		} else if (!strcmp(arg, "--duplicate-pending")) {
			duplicate = 1;
		} else if (!strcmp(arg, "--legacy=before")) {
			legacy_order = -1;
		} else if (!strcmp(arg, "--legacy=after")) {
			legacy_order = 1;
		} else if (!strcmp(arg, "--legacy=only")) {
			/* Construct an untrusted legacy fixture, never a fallback. */
			legacy_order = 2;
		} else {
			die("unknown pending-index mutation: %s", arg);
		}
	}
	strbuf_add(&rewritten, index.data.buf, index.cache_offset);
	if (legacy_order < 0)
		add_extension(&rewritten, UNTR_SIGNATURE, &legacy);
	if (legacy_order != 2) {
		add_extension(&rewritten, signature, &body);
		if (duplicate)
			add_extension(&rewritten, signature, &body);
	}
	if (legacy_order > 0)
		add_extension(&rewritten, UNTR_SIGNATURE, &legacy);
	strbuf_add(&rewritten,
		   index.data.buf + index.cache_offset + 8 + index.cache_size,
		   index.end - index.cache_offset - 8 - index.cache_size);
	index_hash(hash, rewritten.buf, rewritten.len);
	strbuf_add(&rewritten, hash, the_hash_algo->rawsz);
	write_file_buf(output, rewritten.buf, rewritten.len);
	strbuf_release(&rewritten);
	strbuf_release(&legacy);
	strbuf_release(&body);
	strbuf_release(&index.data);
}

static int compare_untracked(const void *a_, const void *b_)
{
	const char *const *a = a_;
	const char *const *b = b_;
	return strcmp(*a, *b);
}

static int compare_dir(const void *a_, const void *b_)
{
	const struct untracked_cache_dir *const *a = a_;
	const struct untracked_cache_dir *const *b = b_;
	return strcmp((*a)->name, (*b)->name);
}

static void dump(struct untracked_cache_dir *ucd, struct strbuf *base)
{
	int len;
	QSORT(ucd->untracked, ucd->untracked_nr, compare_untracked);
	QSORT(ucd->dirs, ucd->dirs_nr, compare_dir);
	len = base->len;
	strbuf_addf(base, "%s/", ucd->name);
	printf("%s %s", base->buf,
	       oid_to_hex(&ucd->exclude_oid));
	if (ucd->recurse)
		fputs(" recurse", stdout);
	if (ucd->check_only)
		fputs(" check_only", stdout);
	if (ucd->valid)
		fputs(" valid", stdout);
	printf("\n");
	for (size_t i = 0; i < ucd->untracked_nr; i++)
		printf("%s\n", ucd->untracked[i]);
	for (size_t i = 0; i < ucd->dirs_nr; i++)
		dump(ucd->dirs[i], base);
	strbuf_setlen(base, len);
}

int cmd__dump_untracked_cache(int ac, const char **av)
{
	struct untracked_cache *uc;
	struct strbuf base = STRBUF_INIT;

	/* Set core.untrackedCache=keep before setup_git_directory() */
	xsetenv("GIT_CONFIG_COUNT", "1", 1);
	xsetenv("GIT_CONFIG_KEY_0", "core.untrackedCache", 1);
	xsetenv("GIT_CONFIG_VALUE_0", "keep", 1);

	if (ac >= 4 && !strcmp(av[1], "rewrite-index"))
		xsetenv("GIT_INDEX_FILE", av[2], 1);
	setup_git_directory(the_repository);
	if (ac == 3 && !strcmp(av[1], "inspect-index")) {
		struct cache_index index;

		read_cache_index(&index, av[2], 1);
		strbuf_release(&index.data);
		return 0;
	}
	if (ac >= 4 && !strcmp(av[1], "rewrite-index")) {
		rewrite_index(av[2], av[3], ac - 4, av + 4);
		return 0;
	}
	if (ac != 1 && (ac != 2 || strcmp(av[1], "state")))
		die("usage: dump-untracked-cache [state | inspect-index <index> | "
		    "rewrite-index <input> <output> <mutations>...]");
	if (repo_read_index(the_repository) < 0)
		die("unable to read index file");
	uc = the_repository->index->untracked;
	if (ac == 2) {
		if (!uc)
			puts("absent");
		else if (!uc->fsmonitor_resync)
			puts("trusted");
		else
			printf("pending %u.%09u\n",
			       uc->fsmonitor_resync_cutoff.sec,
			       uc->fsmonitor_resync_cutoff.nsec);
		return 0;
	}
	if (!uc) {
		printf("no untracked cache\n");
		return 0;
	}
	printf("info/exclude %s\n", oid_to_hex(&uc->ss_info_exclude.oid));
	printf("core.excludesfile %s\n", oid_to_hex(&uc->ss_excludes_file.oid));
	printf("exclude_per_dir %s\n", uc->exclude_per_dir);
	printf("flags %08x\n", uc->dir_flags);
	if (uc->root)
		dump(uc->root, &base);

	strbuf_release(&base);
	return 0;
}

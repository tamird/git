#include "git-compat-util.h"
#include "object-file.h"
#include "odb/source-files.h"
#include "odb/source.h"
#include "packfile.h"

/*
 * Only leaf attempts count. The files source composes packed and loose
 * lookups, so recording it again would duplicate both attempts and winners.
 * This bookkeeping must not perform another lookup or change errno.
 */
void odb_source_record_read_result(struct odb_source *source,
				   struct odb_read_result *result, int ret)
{
	uint64_t *nonzero;

	switch (source->type) {
	case ODB_SOURCE_FILES:
		return;
	case ODB_SOURCE_INMEMORY:
		nonzero = &result->inmemory_nonzero;
		if (!ret)
			result->kind = ODB_READ_RESULT_INMEMORY;
		break;
	case ODB_SOURCE_LOOSE:
		nonzero = &result->loose_nonzero;
		if (!ret)
			result->kind = ODB_READ_RESULT_LOOSE;
		break;
	case ODB_SOURCE_PACKED:
		nonzero = &result->packed_nonzero;
		if (!ret && result->kind != ODB_READ_RESULT_PACKED_CACHE_COPY &&
		    result->kind != ODB_READ_RESULT_PACKED_UNPACK)
			result->invalid = 1;
		break;
	default:
		result->invalid = 1;
		return;
	}
	if (ret) {
		result->kind = ODB_READ_RESULT_UNKNOWN;
		if (*nonzero == (uint64_t)INTMAX_MAX)
			result->invalid = 1;
		else
			(*nonzero)++;
	}
}

struct odb_source *odb_source_new(struct object_database *odb,
				  const char *path,
				  bool local)
{
	return &odb_source_files_new(odb, path, local)->base;
}

void odb_source_init(struct odb_source *source,
		     struct object_database *odb,
		     enum odb_source_type type,
		     const char *path,
		     bool local)
{
	source->odb = odb;
	source->type = type;
	source->local = local;
	source->path = xstrdup(path);
}

void odb_source_free(struct odb_source *source)
{
	if (!source)
		return;
	source->free(source);
}

void odb_source_release(struct odb_source *source)
{
	if (!source)
		return;
	free(source->path);
}

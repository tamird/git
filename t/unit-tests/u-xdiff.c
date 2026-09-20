#include "unit-test.h"
#include "xdiff/xdiff.h"
#include "xdiff/xtypes.h"
#include "xdiff/xutils.h"

static void check_hash_record(const uint8_t *data, size_t len)
{
	const uint8_t *actual_end = data, *expected_end = data;
	uint64_t expected = 5381;

	/* The unbatched additive djb2 recurrence, including uint64_t wrap. */
	while (expected_end < data + len && *expected_end != '\n')
		expected = expected * 33 + *expected_end++;
	if (expected_end < data + len)
		expected_end++;
	cl_assert_equal_u(xdl_hash_record_verbatim(&actual_end, data + len),
			  expected);
	cl_assert_equal_p(actual_end, expected_end);
}

void test_xdiff__hash_record(void)
{
	uint8_t buffer[264];

	for (size_t offset = 0; offset < 8; offset++) {
		uint8_t *data = buffer + offset;

		/* Include NUL and high bytes without an incidental newline. */
		for (size_t i = 0; i < 256; i++)
			data[i] = i == '\n' ? 0 : i;
		for (size_t len = 0; len <= 256; len++) {
			check_hash_record(data, len);
			for (size_t newline = 0; newline < len; newline++) {
				uint8_t saved = data[newline];

				data[newline] = '\n';
				check_hash_record(data, len);
				data[newline] = saved;
			}
		}
	}
}

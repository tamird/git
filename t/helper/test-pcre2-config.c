#include "test-tool.h"
#include "grep.h"

#ifdef USE_LIBPCRE2
static int pcre2_jit_is_functional(void)
{
	uint32_t jit = 0;
	pcre2_code *code;
	pcre2_match_data *match_data = NULL;
	PCRE2_SIZE offset;
	size_t jit_size = 0;
	int error;
	int ret = 1;

	if (pcre2_config(PCRE2_CONFIG_JIT, &jit) || !jit)
		return 1;

	code = pcre2_compile((PCRE2_SPTR)".", 1, 0, &error, &offset, NULL);
	if (!code)
		return 1;

	if (pcre2_jit_compile(code, PCRE2_JIT_COMPLETE))
		goto out;
	if (pcre2_pattern_info(code, PCRE2_INFO_JITSIZE, &jit_size) ||
	    !jit_size)
		goto out;

	match_data = pcre2_match_data_create_from_pattern(code, NULL);
	if (!match_data)
		goto out;
	ret = pcre2_jit_match(code, (PCRE2_SPTR)"x", 1, 0, 0,
			      match_data, NULL) <= 0;

out:
	if (match_data)
		pcre2_match_data_free(match_data);
	pcre2_code_free(code);
	return ret;
}
#endif

int cmd__pcre2_config(int argc, const char **argv)
{
	if (argc == 2 && !strcmp(argv[1], "has-PCRE2_MATCH_INVALID_UTF")) {
		int value = PCRE2_MATCH_INVALID_UTF;
		return !value;
	}
#ifdef USE_LIBPCRE2
	if (argc == 2 && !strcmp(argv[1], "has-jit")) {
		uint32_t value = 0;

		return pcre2_config(PCRE2_CONFIG_JIT, &value) || !value;
	}
	if (argc == 2 && !strcmp(argv[1], "jit-functional"))
		return pcre2_jit_is_functional();
#endif
	return 1;
}

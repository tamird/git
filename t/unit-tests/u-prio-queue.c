#include "unit-test.h"
#include "prio-queue.h"

static int intcmp(const void *va, const void *vb, void *data UNUSED)
{
	const int *a = va, *b = vb;
	return *a - *b;
}


#define MISSING  -1
#define DUMP	 -2
#define STACK	 -3
#define GET	 -4
#define REVERSE  -5
#define REPLACE  -6

static int show(int *v)
{
	return v ? *v : MISSING;
}

static void test_prio_queue(int *input, size_t input_size,
			    int *result, size_t result_size)
{
	struct prio_queue pq = { intcmp };
	size_t j = 0;

	for (size_t i = 0; i < input_size; i++) {
		void *peek, *get;
		switch(input[i]) {
		case GET:
			peek = prio_queue_peek(&pq);
			get = prio_queue_get(&pq);
			cl_assert(peek == get);
			cl_assert(j < result_size);
			cl_assert_equal_i(result[j], show(get));
			j++;
			break;
		case DUMP:
			while ((peek = prio_queue_peek(&pq))) {
				get = prio_queue_get(&pq);
				cl_assert(peek == get);
				cl_assert(j < result_size);
				cl_assert_equal_i(result[j], show(get));
				j++;
			}
			break;
		case STACK:
			pq.compare = NULL;
			break;
		case REVERSE:
			prio_queue_reverse(&pq);
			break;
		case REPLACE:
			get = prio_queue_get(&pq);
			cl_assert(i + 1 < input_size);
			cl_assert(input[i + 1] >= 0);
			cl_assert(j < result_size);
			cl_assert_equal_i(result[j], show(get));
			j++;
			prio_queue_put(&pq, &input[++i]);
			break;
		default:
			prio_queue_put(&pq, &input[i]);
			break;
		}
	}
	cl_assert_equal_i(j, result_size);
	clear_prio_queue(&pq);
}

#define TEST_INPUT(input, result) \
	test_prio_queue(input, ARRAY_SIZE(input), result, ARRAY_SIZE(result))

void test_prio_queue__basic(void)
{
	TEST_INPUT(((int []){ 2, 6, 3, 10, 9, 5, 7, 4, 5, 8, 1, DUMP }),
		   ((int []){ 1, 2, 3, 4, 5, 5, 6, 7, 8, 9, 10 }));
}

void test_prio_queue__mixed(void)
{
	TEST_INPUT(((int []){ 6, 2, 4, GET, 5, 3, GET, GET, 1, DUMP }),
		   ((int []){ 2, 3, 4, 1, 5, 6 }));
}

void test_prio_queue__deferred_get_state(void)
{
	struct prio_queue pq = { intcmp };
	int input[] = { 3, 1, 4, 2 };
	int *item;
	int count = 0, sum = 0;

	for (size_t i = 0; i < ARRAY_SIZE(input); i++)
		prio_queue_put(&pq, &input[i]);

	item = prio_queue_get(&pq);
	cl_assert_equal_i(1, *item);
	cl_assert_equal_i(3, prio_queue_size(&pq));
	prio_queue_for_each(&pq, item) {
		count++;
		sum += *item;
	}
	cl_assert_equal_i(3, count);
	cl_assert_equal_i(9, sum);

	clear_prio_queue(&pq);
	cl_assert_equal_i(0, prio_queue_size(&pq));
	prio_queue_put(&pq, &input[2]);
	prio_queue_put(&pq, &input[3]);
	item = prio_queue_get(&pq);
	cl_assert_equal_i(2, *item);
	cl_assert_equal_i(1, prio_queue_size(&pq));
	clear_prio_queue(&pq);
}

void test_prio_queue__empty(void)
{
	TEST_INPUT(((int []){ 1, 2, GET, GET, GET, 1, 2, GET, GET, GET }),
		   ((int []){ 1, 2, MISSING, 1, 2, MISSING }));
}

void test_prio_queue__replace(void)
{
	TEST_INPUT(((int []){ REPLACE, 6, 2, 4, REPLACE, 5, 7, GET,
			      REPLACE, 1, DUMP }),
		   ((int []){ MISSING, 2, 4, 5, 1, 6, 7 }));
}

void test_prio_queue__stack(void)
{
	TEST_INPUT(((int []){ STACK, 8, 1, 5, 4, 6, 2, 3, DUMP }),
		   ((int []){ 3, 2, 6, 4, 5, 1, 8 }));
}

void test_prio_queue__reverse_stack(void)
{
	TEST_INPUT(((int []){ STACK, 1, 2, 3, 4, 5, 6, REVERSE, DUMP }),
		   ((int []){ 1, 2, 3, 4, 5, 6 }));
}

void test_prio_queue__replace_stack(void)
{
	TEST_INPUT(((int []){ STACK, 8, 1, 5, REPLACE, 4, 6, 2, 3, DUMP }),
		   ((int []){ 5, 3, 2, 6, 4, 1, 8 }));
}

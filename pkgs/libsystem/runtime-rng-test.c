/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <corecrypto/ccrng.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
static int calls, fail_call;
int md_test_getentropy(void *output, size_t count) {
    assert(count <= 256);
    if (++calls == fail_call) { errno = EIO; return -1; }
    memset(output, calls, count);
    return 0;
}
static uint64_t draws[] = { 0, 1, UINT64_MAX };
static unsigned draw_index;
static int draw(struct ccrng_state *rng, size_t count, void *out) {
    (void)rng; assert(count == sizeof(uint64_t)); assert(draw_index < 3);
    memcpy(out, &draws[draw_index++], count); return 0;
}
static int fail(struct ccrng_state *rng, size_t count, void *out) {
    (void)rng; (void)count; (void)out; return EIO;
}
int main(void) {
    int error = -1;
    struct ccrng_state *rng = ccrng(&error);
    assert(rng && !error && rng == ccrng(NULL));
    unsigned char bytes[600];
    assert(!ccrng_generate(rng, sizeof(bytes), bytes));
    assert(calls == 3 && bytes[0] == 1 && bytes[255] == 1 && bytes[256] == 2 && bytes[599] == 3);
    assert(!ccrng_generate(rng, 0, NULL));
    assert(ccrng_generate(rng, 1, NULL) == EINVAL);
    assert(ccrng_generate(rng, SIZE_MAX, bytes) == EINVAL);
    calls = 0; fail_call = 2; memset(bytes, 99, sizeof(bytes));
    assert(ccrng_generate(rng, sizeof(bytes), bytes) == EIO);
    for (size_t i = 0; i < sizeof(bytes); ++i) assert(!bytes[i]);
    struct ccrng_state scripted = { .generate = draw };
    uint64_t result = 99;
    assert(!ccrng_uniform(&scripted, 3, &result) && result == 1 && draw_index == 2);
    assert(!ccrng_uniform(&scripted, UINT64_MAX, &result) && result == 0);
    assert(ccrng_uniform(&scripted, 0, &result) == EINVAL);
    assert(ccrng_uniform(NULL, 3, &result) == EINVAL);
    assert(ccrng_uniform(&scripted, 3, NULL) == EINVAL);
    scripted.generate = fail; result = 99;
    assert(ccrng_uniform(&scripted, 3, &result) == EIO && result == 99);
    return 0;
}

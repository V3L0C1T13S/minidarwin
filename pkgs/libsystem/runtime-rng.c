/* SPDX-License-Identifier: MIT
 * The public ccrng interface, drawing directly from XNU's getentropy syscall.
 * No process-global seed, heap allocation, or inherited PRNG state is needed.
 */
#include <corecrypto/ccrng.h>
#include <errno.h>
#include <stdint.h>
#include <sys/random.h>
#include <unistd.h>
extern void cc_clear(size_t, void *);
static int generate(struct ccrng_state *rng, size_t count, void *output) {
    (void)rng;
    if ((count && !output) || count > PTRDIFF_MAX) return EINVAL;
    unsigned char *bytes = output;
    size_t offset = 0;
    while (offset < count) {
        size_t chunk = count - offset;
        if (chunk > 256) chunk = 256;
        if (getentropy(bytes + offset, chunk) != 0) {
            int error = errno ? errno : EIO;
            cc_clear(count, output);
            return error;
        }
        offset += chunk;
    }
    return 0;
}
static struct ccrng_state system_rng = { .generate = generate };
struct ccrng_state *ccrng(int *error) {
    if (error) *error = 0;
    return &system_rng;
}
int ccrng_uniform(struct ccrng_state *rng, uint64_t bound, uint64_t *result) {
    if (!rng || !rng->generate || !bound || !result) return EINVAL;
    /* Discard the incomplete bucket; every accepted residue is equiprobable. */
    uint64_t threshold = -bound % bound;
    uint64_t value;
    do {
        int error = ccrng_generate(rng, sizeof(value), &value);
        if (error) return error;
    } while (value < threshold);
    *result = value % bound;
    return 0;
}

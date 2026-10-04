/* SPDX-License-Identifier: MIT
 * Caller-supplied entropy and synchronization; no hidden sources or locks.
 */
#include "kernel-rng.h"
#include <string.h>

int md_rng_init(struct md_rng *s, size_t n, const void *seed,
                size_t nonce_n, const void *nonce) {
    if (!s) return CCERR_PARAMETER;
    memset(s, 0, sizeof(*s));
    s->custom.di = ccsha512_di();
    s->custom.strictFIPS = 1;
    ccdrbg_factory_nisthmac(&s->info, &s->custom);
    if (s->info.size > sizeof(s->state)) return CCERR_INTERNAL;
    int rc = ccdrbg_init(&s->info, (void *)s->state, n, seed,
                        nonce_n, nonce, 0, NULL);
    s->initialized = rc == 0;
    return rc;
}
int md_rng_reseed(struct md_rng *s, size_t n, const void *seed) {
    if (!s || !s->initialized) return CCERR_PARAMETER;
    return ccdrbg_reseed(&s->info, (void *)s->state, n, seed, 0, NULL);
}
int md_rng_generate(struct md_rng *s, size_t n, void *out) {
    if (!s || !s->initialized || (n && !out) || n > 65536)
        return CCERR_PARAMETER;
    return ccdrbg_generate(&s->info, (void *)s->state, n, out, 0, NULL);
}
int md_rng_uniform(struct md_rng *s, uint64_t bound, uint64_t *out) {
    if (!out || !bound) return CCERR_PARAMETER;
    /* Rejection sampling removes modulo bias, including non-power-of-two
     * bounds and bounds above INT64_MAX. */
    uint64_t threshold = (uint64_t)(-bound) % bound, value;
    int rc;
    do {
        rc = md_rng_generate(s, sizeof(value), &value);
        if (rc) return rc;
    } while (value < threshold);
    *out = value % bound;
    return 0;
}

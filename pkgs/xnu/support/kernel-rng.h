/* SPDX-License-Identifier: MIT */
#pragma once
#include "crypto-namespace.h"
#include <corecrypto/ccdrbg.h>
#include <corecrypto/ccsha2.h>
#include <corecrypto/cc_error.h>
#include <stddef.h>
#include <stdint.h>

/* HMAC_DRBG SHA-512 state is 144 bytes. The complete handle fits XNU's
 * 256-byte kmem RNG contract, including the descriptor and custom options. */
struct md_rng {
    struct ccdrbg_info info;
    struct ccdrbg_nisthmac_custom custom;
    uint64_t state[18];
    bool initialized;
};
_Static_assert(sizeof(struct md_rng) <= 256, "kmem RNG context limit");
int md_rng_init(struct md_rng *, size_t, const void *, size_t, const void *);
int md_rng_reseed(struct md_rng *, size_t, const void *);
int md_rng_generate(struct md_rng *, size_t, void *);
int md_rng_uniform(struct md_rng *, uint64_t, uint64_t *);

/* SPDX-License-Identifier: MIT
 * MiniDarwin's source-built SHA/HMAC and HMAC_DRBG provider. The shared PRNG
 * serializes all CPU streams; kmem contexts have caller-owned synchronization.
 * Cipher and public-key providers are not supplied by this module.
 */
#include "kernel-rng.h"
#include <corecrypto/ccsha1.h>
#include <corecrypto/cchmac.h>
#include <corecrypto/cckprng.h>
#include <libkern/crypto/register_crypto.h>
#include <libkern/libkern.h>
#include <kern/locks.h>
#include <kern/startup.h>
#include <i386/machine_cpu.h>
#include <limits.h>
#include <prng/random.h>

static struct cckprng_ctx kprng;
static struct md_rng shared_rng;
static cckprng_getentropy entropy_source;
static void *entropy_arg;
static unsigned generator_count;
static bool generators[MAX_CPUS];
LCK_GRP_DECLARE(md_random_group, "minidarwin random");
LCK_SPIN_DECLARE(md_random_lock, &md_random_group);

static void checked(int rc) {
    if (rc) panic("MiniDarwin random provider error %d", rc);
}
static void check_ctx(struct cckprng_ctx *ctx) {
    if (ctx != &kprng || !shared_rng.initialized)
        panic("MiniDarwin random provider context");
}
static void prng_init(struct cckprng_ctx *ctx, unsigned count,
                     size_t n, const void *seed, size_t nn, const void *nonce,
                     cckprng_getentropy source, void *arg) {
    if (ctx != &kprng || shared_rng.initialized || !count || count > MAX_CPUS || !source)
        panic("MiniDarwin random provider initialization");
    checked(md_rng_init(&shared_rng, n, seed, nn, nonce));
    generator_count = count;
    entropy_source = source;
    entropy_arg = arg;
}
static void prng_init_legacy(struct cckprng_ctx *ctx,
                            size_t n, const void *seed, size_t nn, const void *nonce,
                            cckprng_getentropy source, void *arg) {
    prng_init(ctx, MAX_CPUS, n, seed, nn, nonce, source, arg);
}
static void prng_initgen(struct cckprng_ctx *ctx, unsigned gen) {
    check_ctx(ctx);
    lck_spin_lock(&md_random_lock);
    if (gen >= generator_count || generators[gen])
        panic("MiniDarwin random provider generator %u", gen);
    generators[gen] = true;
    lck_spin_unlock(&md_random_lock);
}
static void prng_reseed(struct cckprng_ctx *ctx, size_t n, const void *seed) {
    check_ctx(ctx);
    /* The public random device may supply attacker-controlled material. Hash
     * it to bound time under the spinlock; DRBG Update retains the old secret.
     * This mixes input without claiming it has any entropy. */
    if (!seed || !n) panic("MiniDarwin random provider empty reseed");
    unsigned char digest[64];
    ccdigest(ccsha512_di(), n, seed, digest);
    lck_spin_lock(&md_random_lock);
    checked(md_rng_reseed(&shared_rng, sizeof(digest), digest));
    lck_spin_unlock(&md_random_lock);
    cc_clear(sizeof(digest), digest);
}
static void prng_refresh(struct cckprng_ctx *ctx) {
    check_ctx(ctx);
    unsigned char seed[CCKPRNG_ENTROPY_SIZE];
    size_t n = sizeof(seed);
    /* entropy_provide uses its own mutex: never call it with the PRNG spinlock
     * held. It rejects simultaneous consumers without blocking. */
    int32_t samples = entropy_source(&n, seed, entropy_arg);
    if (samples < 0) panic("MiniDarwin entropy source health failure");
    if (samples > 0) {
        if (n != sizeof(seed)) panic("MiniDarwin entropy source payload size");
        lck_spin_lock(&md_random_lock);
        checked(md_rng_reseed(&shared_rng, n, seed));
        lck_spin_unlock(&md_random_lock);
    }
    cc_clear(sizeof(seed), seed);
}
static void prng_generate(struct cckprng_ctx *ctx, unsigned gen, size_t n, void *out) {
    check_ctx(ctx);
    lck_spin_lock(&md_random_lock);
    if (gen >= generator_count || !generators[gen] || n > CCKPRNG_GENERATE_MAX_NBYTES)
        panic("MiniDarwin random provider request");
    checked(md_rng_generate(&shared_rng, n, out));
    lck_spin_unlock(&md_random_lock);
}
static const struct cckprng_funcs prng = {
    .init = prng_init_legacy, .init_with_getentropy = prng_init,
    .initgen = prng_initgen, .reseed = prng_reseed,
    .refresh = prng_refresh, .generate = prng_generate,
};
static int rng_generate(struct ccrng_state *ctx, size_t n, void *out) {
    (void)ctx;
    if (n && !out) return CCERR_PARAMETER;
    unsigned char *p = out;
    while (n) {
        unsigned chunk = n > UINT_MAX ? UINT_MAX : (unsigned)n;
        read_random(p, chunk);
        p += chunk; n -= chunk;
    }
    return 0;
}
static struct ccrng_state rng = {.generate = rng_generate};
static struct ccrng_state *rng_get(int *error) {
    if (error) *error = 0;
    return &rng;
}
static size_t kmem_size(void) { return sizeof(struct md_rng); }
static void kmem_init(void *ctx) {
    unsigned char seed[64];
    read_random(seed, sizeof(seed));
    /* A fresh 512-bit seed already meets the combined entropy/nonce strength
     * requirement; no timestamp is treated as entropy. */
    checked(md_rng_init(ctx, sizeof(seed), seed, 0, NULL));
    cc_clear(sizeof(seed), seed);
}
static void random_generate(void *ctx, void *out, size_t n) {
    unsigned char *p = out;
    while (n) {
        size_t chunk = n > 65536 ? 65536 : n;
        checked(md_rng_generate(ctx, chunk, p));
        p += chunk; n -= chunk;
    }
}
static void random_uniform(void *ctx, uint64_t bound, uint64_t *out) {
    checked(md_rng_uniform(ctx, bound, out));
}
extern struct crypto_functions md_crypto_functions;
static void provider_init(void) {
    md_crypto_functions.ccrng_fn = rng_get;
    md_crypto_functions.random_generate_fn = random_generate;
    md_crypto_functions.random_uniform_fn = random_uniform;
    md_crypto_functions.random_kmem_ctx_size_fn = kmem_size;
    md_crypto_functions.random_kmem_init_fn = kmem_init;
    /* entropy_init calls XNU SHA wrappers, so the digest table must be
     * published before installing the PRNG. */
    if (register_crypto_functions(&md_crypto_functions)) panic("MiniDarwin duplicate crypto provider");
    register_and_init_prng(&kprng,&prng);
    printf("MiniDarwin: SHA/HMAC and HMAC_DRBG provider initialized\n");
}
STARTUP(EARLY_BOOT, STARTUP_RANK_FIRST, provider_init);

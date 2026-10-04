/* SPDX-License-Identifier: MIT
 * Kernel digest/HMAC bridge. Unlike dyld's narrow adapter, this preserves the
 * published digest state, byte count and buffer layout used by XNU's wrappers.
 * Compression and final padding are supplied by pinned LibreSSL sources.
 */
#include <corecrypto/ccdigest.h>
#include <corecrypto/cchmac.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>
#include <openssl/sha.h>
#include <string.h>

void cc_clear(size_t n, void *p) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}
void explicit_bzero(void *p, size_t n) { cc_clear(n, p); }

static void compress1(ccdigest_state_t state, size_t n, const void *data) {
    SHA_CTX c = {0};
    memcpy(&c.h0, state, 20);
    const unsigned char *p = data;
    while (n--) { SHA1_Transform(&c, p); p += 64; }
    memcpy(state, &c.h0, 20);
    cc_clear(sizeof(c), &c);
}
static void compress256(ccdigest_state_t state, size_t n, const void *data) {
    SHA256_CTX c = {0};
    memcpy(c.h, state, 32);
    const unsigned char *p = data;
    while (n--) { SHA256_Transform(&c, p); p += 64; }
    memcpy(state, c.h, 32);
    cc_clear(sizeof(c), &c);
}
static void compress512(ccdigest_state_t state, size_t n, const void *data) {
    SHA512_CTX c = {0};
    memcpy(c.h, state, 64);
    const unsigned char *p = data;
    while (n--) { SHA512_Transform(&c, p); p += 128; }
    memcpy(state, c.h, 64);
    cc_clear(sizeof(c), &c);
}
static void final(const struct ccdigest_info *di, ccdigest_ctx_t ctx, unsigned char *out) {
    uint64_t bits = ccdigest_nbits(di, ctx) + (uint64_t)ccdigest_num(di, ctx) * 8;
    if (di->output_size == 20) {
        SHA_CTX c = {0};
        memcpy(&c.h0, ccdigest_state(di, ctx), 20);
        c.Nl = (uint32_t)bits; c.Nh = bits >> 32;
        c.num = ccdigest_num(di, ctx);
        memcpy(c.data, ccdigest_data(di, ctx), 64);
        SHA1_Final(out, &c); cc_clear(sizeof(c), &c);
    } else if (di->output_size == 32) {
        SHA256_CTX c = {0};
        memcpy(c.h, ccdigest_state(di, ctx), 32);
        c.Nl = (uint32_t)bits; c.Nh = bits >> 32;
        c.num = ccdigest_num(di, ctx); c.md_len = 32;
        memcpy(c.data, ccdigest_data(di, ctx), 64);
        SHA256_Final(out, &c); cc_clear(sizeof(c), &c);
    } else {
        SHA512_CTX c = {0};
        memcpy(c.h, ccdigest_state(di, ctx), 64);
        c.Nl = bits; c.num = ccdigest_num(di, ctx); c.md_len = di->output_size;
        memcpy(c.u.p, ccdigest_data(di, ctx), 128);
        SHA512_Final(out, &c); cc_clear(sizeof(c), &c);
    }
}
static const uint32_t initial1[] = {0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0};
static const uint32_t initial256[] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
static const uint64_t initial384[] = {0xcbbb9d5dc1059ed8ULL,0x629a292a367cd507ULL,
    0x9159015a3070dd17ULL,0x152fecd8f70e5939ULL,0x67332667ffc00b31ULL,
    0x8eb44a8768581511ULL,0xdb0c2e0d64f98fa7ULL,0x47b5481dbefa4fa4ULL};
static const uint64_t initial512[] = {0x6a09e667f3bcc908ULL,0xbb67ae8584caa73bULL,
    0x3c6ef372fe94f82bULL,0xa54ff53a5f1d36f1ULL,0x510e527fade682d1ULL,
    0x9b05688c2b3e6c1fULL,0x1f83d9abfb41bd6bULL,0x5be0cd19137e2179ULL};
#define DESCRIPTOR(name, output, block, initial, compressfn, oidvalue, oidsize) \
    const struct ccdigest_info name = {.output_size=output, .state_size=sizeof(initial), \
        .block_size=block, .initial_state=initial, .compress=compressfn, .final=final, \
        .oid=oidvalue, .oid_size=oidsize}
DESCRIPTOR(ccsha1_ltc_di,20,64,initial1,compress1,CC_DIGEST_OID_SHA1,7);
DESCRIPTOR(ccsha256_ltc_di,32,64,initial256,compress256,CC_DIGEST_OID_SHA256,11);
DESCRIPTOR(ccsha384_ltc_di,48,128,initial384,compress512,CC_DIGEST_OID_SHA384,11);
DESCRIPTOR(ccsha512_ltc_di,64,128,initial512,compress512,CC_DIGEST_OID_SHA512,11);
const struct ccdigest_info *ccsha1_di(void) { return &ccsha1_ltc_di; }
const struct ccdigest_info *ccsha256_di(void) { return &ccsha256_ltc_di; }
const struct ccdigest_info *ccsha384_di(void) { return &ccsha384_ltc_di; }
const struct ccdigest_info *ccsha512_di(void) { return &ccsha512_ltc_di; }
void ccdigest_init(const struct ccdigest_info *di, ccdigest_ctx_t ctx) {
    cc_clear(ccdigest_di_size(di), ctx);
    memcpy(ccdigest_state(di, ctx), di->initial_state, di->state_size);
}
void ccdigest_update(const struct ccdigest_info *di, ccdigest_ctx_t ctx, size_t n, const void *data) {
    const unsigned char *p = data;
    while (n) {
        size_t count = di->block_size - ccdigest_num(di, ctx);
        if (count > n) count = n;
        memcpy(ccdigest_data(di, ctx) + ccdigest_num(di, ctx), p, count);
        ccdigest_num(di, ctx) += count; p += count; n -= count;
        if (ccdigest_num(di, ctx) == di->block_size) {
            di->compress(ccdigest_state(di, ctx), 1, ccdigest_data(di, ctx));
            ccdigest_nbits(di, ctx) += di->block_size * 8;
            ccdigest_num(di, ctx) = 0;
        }
    }
}
void ccdigest(const struct ccdigest_info *di, size_t n, const void *data, void *out) {
    ccdigest_di_decl(di, ctx);
    ccdigest_init(di, ctx); ccdigest_update(di, ctx, n, data); ccdigest_final(di, ctx, out);
    ccdigest_di_clear(di, ctx);
}
void ccdigest_parallel(const struct ccdigest_info *di, size_t n,
    const void *a, void *outa, const void *b, void *outb) {
    ccdigest(di, n, a, outa); ccdigest(di, n, b, outb);
}
void cchmac_init(const struct ccdigest_info *di, cchmac_ctx_t ctx, size_t n, const void *key) {
    unsigned char pad[di->block_size];
    cc_clear(sizeof(pad), pad);
    if (n > sizeof(pad)) ccdigest(di, n, key, pad);
    else if (n) memcpy(pad, key, n);
    for (size_t i=0; i<sizeof(pad); i++) pad[i] ^= 0x5c;
    ccdigest_init(di, cchmac_digest_ctx(di, ctx));
    ccdigest_update(di, cchmac_digest_ctx(di, ctx), sizeof(pad), pad);
    memcpy(cchmac_ostate(di, ctx), cchmac_istate(di, ctx), di->state_size);
    for (size_t i=0; i<sizeof(pad); i++) pad[i] ^= 0x5c ^ 0x36;
    ccdigest_init(di, cchmac_digest_ctx(di, ctx));
    ccdigest_update(di, cchmac_digest_ctx(di, ctx), sizeof(pad), pad);
    cc_clear(sizeof(pad), pad);
}
void cchmac_update(const struct ccdigest_info *di, cchmac_ctx_t ctx, size_t n, const void *data) {
    ccdigest_update(di, cchmac_digest_ctx(di, ctx), n, data);
}
void cchmac_final(const struct ccdigest_info *di, cchmac_ctx_t ctx, unsigned char *out) {
    unsigned char inner[di->output_size];
    ccdigest_ctx_t digest = cchmac_digest_ctx(di, ctx);
    ccdigest_final(di, digest, inner);
    memcpy(cchmac_istate(di, ctx), cchmac_ostate(di, ctx), di->state_size);
    ccdigest_nbits(di, digest) = di->block_size * 8; ccdigest_num(di, digest) = 0;
    ccdigest_update(di, digest, sizeof(inner), inner); ccdigest_final(di, digest, out);
    cc_clear(sizeof(inner), inner);
}
void cchmac(const struct ccdigest_info *di, size_t n, const void *key,
    size_t len, const void *data, unsigned char *out) {
    cchmac_di_decl(di, ctx);
    cchmac_init(di, ctx, n, key); cchmac_update(di, ctx, len, data); cchmac_final(di, ctx, out);
    cchmac_di_clear(di, ctx);
}

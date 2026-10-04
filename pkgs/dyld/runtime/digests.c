// SPDX-License-Identifier: MIT
// Narrow digest interface for the published dyld sources, backed by LibreSSL.
// The descriptor reserves room for LibreSSL's context; callers use only
// init/update/final/clear, never the private CoreCrypto compression layout.
#include <corecrypto/ccdigest.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>
#include <openssl/sha.h>
#include <stdlib.h>

void cc_clear(size_t n, void *p) {
    volatile unsigned char *v = p;
    while (n--) *v++ = 0;
}
void explicit_bzero(void *p, size_t n) { cc_clear(n, p); }
static void final1(const struct ccdigest_info *di, ccdigest_ctx_t ctx, unsigned char *out) {
    (void)di; SHA1_Final(out, (SHA_CTX *)ctx);
}
static void final256(const struct ccdigest_info *di, ccdigest_ctx_t ctx, unsigned char *out) {
    (void)di; SHA256_Final(out, (SHA256_CTX *)ctx);
}
static void final384(const struct ccdigest_info *di, ccdigest_ctx_t ctx, unsigned char *out) {
    (void)di; SHA384_Final(out, (SHA512_CTX *)ctx);
}
static const struct ccdigest_info sha1 = {
    .output_size = 20, .state_size = sizeof(SHA_CTX), .block_size = 64, .final = final1
};
static const struct ccdigest_info sha256 = {
    .output_size = 32, .state_size = sizeof(SHA256_CTX), .block_size = 64, .final = final256
};
static const struct ccdigest_info sha384 = {
    .output_size = 48, .state_size = sizeof(SHA512_CTX), .block_size = 128, .final = final384
};
const struct ccdigest_info *ccsha1_di(void) { return &sha1; }
const struct ccdigest_info *ccsha256_di(void) { return &sha256; }
const struct ccdigest_info *ccsha384_di(void) { return &sha384; }
void ccdigest_init(const struct ccdigest_info *di, ccdigest_ctx_t ctx) {
    cc_clear(ccdigest_di_size(di), ctx);
    if (di == &sha1) SHA1_Init((SHA_CTX *)ctx);
    else if (di == &sha256) SHA256_Init((SHA256_CTX *)ctx);
    else if (di == &sha384) SHA384_Init((SHA512_CTX *)ctx);
    else abort();
}
void ccdigest_update(const struct ccdigest_info *di, ccdigest_ctx_t ctx, size_t n, const void *data) {
    if (di == &sha1) SHA1_Update((SHA_CTX *)ctx, data, n);
    else if (di == &sha256) SHA256_Update((SHA256_CTX *)ctx, data, n);
    else if (di == &sha384) SHA384_Update((SHA512_CTX *)ctx, data, n);
    else abort();
}

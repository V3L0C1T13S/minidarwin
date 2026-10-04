/* SPDX-License-Identifier: MIT
 * XNU digest/HMAC function-table ABI, shared by kernel and host validation.
 */
#include "crypto-namespace.h"
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>
#include <corecrypto/cchmac.h>
#include <libkern/crypto/register_crypto.h>
#include <string.h>
extern void panic(const char *, ...) __attribute__((noreturn));
extern const struct ccmode_ecb md_aes_ecb_encrypt, md_aes_ecb_decrypt;
extern const struct ccmode_cbc md_aes_cbc_encrypt, md_aes_cbc_decrypt;
static const struct ccdigest_info *digest_info(crypto_digest_alg_t alg) {
    switch (alg) {
    case CRYPTO_DIGEST_ALG_SHA1: return ccsha1_di();
    case CRYPTO_DIGEST_ALG_SHA256: return ccsha256_di();
    case CRYPTO_DIGEST_ALG_SHA384: return ccsha384_di();
    case CRYPTO_DIGEST_ALG_SHA512: return ccsha512_di();
    default: panic("MiniDarwin unsupported digest algorithm %u", alg);
    }
}
static void check_buffer(const void *p, size_t n, size_t need) {
    if (!p || n < need) panic("MiniDarwin crypto buffer size");
}
static size_t digest_size(crypto_digest_alg_t alg) { return ccdigest_di_size(digest_info(alg)); }
static void digest_init(crypto_digest_alg_t alg, void *ctx, size_t n) {
    const struct ccdigest_info *di = digest_info(alg);
    check_buffer(ctx,n,ccdigest_di_size(di)); ccdigest_init(di,ctx);
}
static void digest_update(crypto_digest_alg_t alg, void *ctx, size_t n, const void *data, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    check_buffer(ctx,n,ccdigest_di_size(di));
    if (len && !data) panic("MiniDarwin digest input");
    ccdigest_update(di,ctx,len,data);
}
static void digest_final(crypto_digest_alg_t alg, void *ctx, size_t n, void *out, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    check_buffer(ctx,n,ccdigest_di_size(di)); check_buffer(out,len,di->output_size);
    ccdigest_final(di,ctx,out); cc_clear(ccdigest_di_size(di),ctx);
}
static void digest_once(crypto_digest_alg_t alg, const void *data, size_t n, void *out, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    check_buffer(out,len,di->output_size);
    if (n && !data) panic("MiniDarwin digest input");
    ccdigest(di,n,data,out);
}
static size_t hmac_size(crypto_digest_alg_t alg) { return cchmac_di_size(digest_info(alg)); }
static void hmac_init(crypto_digest_alg_t alg, void *ctx, size_t n, const void *key, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    check_buffer(ctx,n,cchmac_di_size(di));
    if (len && !key) panic("MiniDarwin HMAC key");
    cchmac_init(di,ctx,len,key);
}
static void hmac_update(crypto_digest_alg_t alg, void *ctx, size_t n, const void *data, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    check_buffer(ctx,n,cchmac_di_size(di));
    if (len && !data) panic("MiniDarwin HMAC input");
    cchmac_update(di,ctx,len,data);
}
static void hmac_final(crypto_digest_alg_t alg, void *ctx, size_t n, void *tag, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    if (!tag || !len || len > di->output_size) panic("MiniDarwin HMAC tag size");
    check_buffer(ctx,n,cchmac_di_size(di));
    unsigned char full[64]; cchmac_final(di,ctx,full);
    memcpy(tag,full,len); cc_clear(sizeof(full),full); cc_clear(cchmac_di_size(di),ctx);
}
static bool hmac_verify_final(crypto_digest_alg_t alg, void *ctx, size_t n, const void *tag, size_t len) {
    unsigned char full[64];
    if (!tag || !len || len > digest_info(alg)->output_size) {
        check_buffer(ctx,n,cchmac_di_size(digest_info(alg)));
        cc_clear(cchmac_di_size(digest_info(alg)),ctx);
        return false;
    }
    hmac_final(alg,ctx,n,full,len);
    const unsigned char *p = tag; unsigned diff = 0;
    for (size_t i=0;i<len;i++) diff |= full[i] ^ p[i];
    cc_clear(sizeof(full),full); return diff == 0;
}
static void hmac_once(crypto_digest_alg_t alg, const void *key, size_t kn,
                      const void *data, size_t n, void *tag, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    cchmac_di_decl(di,ctx); hmac_init(alg,ctx,cchmac_di_size(di),key,kn);
    hmac_update(alg,ctx,cchmac_di_size(di),data,n); hmac_final(alg,ctx,cchmac_di_size(di),tag,len);
}
static bool hmac_verify_once(crypto_digest_alg_t alg, const void *key, size_t kn,
                             const void *data, size_t n, const void *tag, size_t len) {
    const struct ccdigest_info *di = digest_info(alg);
    cchmac_di_decl(di,ctx); hmac_init(alg,ctx,cchmac_di_size(di),key,kn);
    hmac_update(alg,ctx,cchmac_di_size(di),data,n);
    return hmac_verify_final(alg,ctx,cchmac_di_size(di),tag,len);
}
static void legacy_digest_final(const struct ccdigest_info *di, ccdigest_ctx_t ctx, void *out) {
    ccdigest_final(di,ctx,out);
}
struct crypto_functions md_crypto_functions = {
    .ccaes_ecb_encrypt=&md_aes_ecb_encrypt, .ccaes_ecb_decrypt=&md_aes_ecb_decrypt,
    .ccaes_cbc_encrypt=&md_aes_cbc_encrypt, .ccaes_cbc_decrypt=&md_aes_cbc_decrypt,
    .ccdigest_init_fn=ccdigest_init, .ccdigest_update_fn=ccdigest_update,
    .ccdigest_final_fn=legacy_digest_final, .ccdigest_fn=ccdigest,
    .ccsha1_di=&ccsha1_ltc_di, .ccsha256_di=&ccsha256_ltc_di,
    .ccsha384_di=&ccsha384_ltc_di, .ccsha512_di=&ccsha512_ltc_di,
    .cchmac_init_fn=cchmac_init, .cchmac_update_fn=cchmac_update,
    .cchmac_final_fn=cchmac_final, .cchmac_fn=cchmac,
    .digest_ctx_size_fn=digest_size, .digest_init_fn=digest_init,
    .digest_update_fn=digest_update, .digest_final_fn=digest_final, .digest_fn=digest_once,
    .hmac_ctx_size_fn=hmac_size, .hmac_init_fn=hmac_init, .hmac_update_fn=hmac_update,
    .hmac_final_generate_fn=hmac_final, .hmac_final_verify_fn=hmac_verify_final,
    .hmac_generate_fn=hmac_once, .hmac_verify_fn=hmac_verify_once,
};

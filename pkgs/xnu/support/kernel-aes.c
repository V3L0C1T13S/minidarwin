/* SPDX-License-Identifier: MIT
 * XNU ECB/CBC adapters for pinned LibreSSL's allocation-free generic AES.
 * This software implementation uses lookup tables; it is not constant-time.
 */
#include <corecrypto/ccmode.h>
#include <openssl/aes.h>
#include <stdint.h>
#include <string.h>

extern int aes_set_encrypt_key_generic(const unsigned char *, int, AES_KEY *);
extern int aes_set_decrypt_key_generic(const unsigned char *, int, AES_KEY *);
extern void aes_encrypt_generic(const unsigned char *, unsigned char *, const AES_KEY *);
extern void aes_decrypt_generic(const unsigned char *, unsigned char *, const AES_KEY *);
struct aes_context { AES_KEY key; uint32_t valid; };
enum { ENCRYPT = 0x4d444145, DECRYPT = 0x4d444144 };

static int init(void *context, size_t length, const void *key, uint32_t direction) {
    if (!context) return -1;
    struct aes_context *c = context;
    cc_clear(sizeof(*c), c);
    if (!key || (length != 16 && length != 24 && length != 32)) return -1;
    c->key.rounds = (int)(length / 4 + 6);
    int error = direction == ENCRYPT ? aes_set_encrypt_key_generic(key, (int)length * 8, &c->key) :
                                      aes_set_decrypt_key_generic(key, (int)length * 8, &c->key);
    if (error) { cc_clear(sizeof(*c), c); return error; }
    c->valid = direction;
    return 0;
}
static int check(const void *ctx, uint32_t direction, size_t blocks, const void *in, void *out) {
    const struct aes_context *c = ctx;
    return c && c->valid == direction && blocks <= SIZE_MAX / 16 &&
        (!blocks || (in && out)) ? 0 : -1;
}
static int encrypt_ecb(const ccecb_ctx *ctx, size_t n, const void *input, void *output) {
    if (check(ctx, ENCRYPT, n, input, output)) return -1;
    const struct aes_context *c = (const void *)ctx;
    const unsigned char *in = input; unsigned char *out = output;
    for (size_t i = 0; i < n; ++i) aes_encrypt_generic(in + i * 16, out + i * 16, &c->key);
    return 0;
}
static int decrypt_ecb(const ccecb_ctx *ctx, size_t n, const void *input, void *output) {
    if (check(ctx, DECRYPT, n, input, output)) return -1;
    const struct aes_context *c = (const void *)ctx;
    const unsigned char *in = input; unsigned char *out = output;
    for (size_t i = 0; i < n; ++i) aes_decrypt_generic(in + i * 16, out + i * 16, &c->key);
    return 0;
}
static int encrypt_cbc(const cccbc_ctx *ctx, cccbc_iv *iv, size_t n, const void *input, void *output) {
    if (!iv || check(ctx, ENCRYPT, n, input, output)) return -1;
    const struct aes_context *c = (const void *)ctx;
    const unsigned char *in = input; unsigned char *out = output, *chain = (void *)iv;
    unsigned char block[16];
    for (size_t i = 0; i < n; ++i) {
        for (unsigned j = 0; j < 16; ++j) block[j] = in[i * 16 + j] ^ chain[j];
        aes_encrypt_generic(block, out + i * 16, &c->key);
        memcpy(chain, out + i * 16, 16);
    }
    cc_clear(sizeof(block), block);
    return 0;
}
static int decrypt_cbc(const cccbc_ctx *ctx, cccbc_iv *iv, size_t n, const void *input, void *output) {
    if (!iv || check(ctx, DECRYPT, n, input, output)) return -1;
    const struct aes_context *c = (const void *)ctx;
    const unsigned char *in = input; unsigned char *out = output, *chain = (void *)iv;
    unsigned char saved[16], block[16];
    for (size_t i = 0; i < n; ++i) {
        memcpy(saved, in + i * 16, 16);
        aes_decrypt_generic(saved, block, &c->key);
        for (unsigned j = 0; j < 16; ++j) out[i * 16 + j] = block[j] ^ chain[j];
        memcpy(chain, saved, 16);
    }
    cc_clear(sizeof(block), block); cc_clear(sizeof(saved), saved);
    return 0;
}
static int init_ecb_encrypt(const struct ccmode_ecb *mode, ccecb_ctx *ctx, size_t n, const void *key) {
    (void)mode; return init(ctx, n, key, ENCRYPT);
}
static int init_ecb_decrypt(const struct ccmode_ecb *mode, ccecb_ctx *ctx, size_t n, const void *key) {
    (void)mode; return init(ctx, n, key, DECRYPT);
}
static int init_cbc_encrypt(const struct ccmode_cbc *mode, cccbc_ctx *ctx, size_t n, const void *key) {
    (void)mode; return init(ctx, n, key, ENCRYPT);
}
static int init_cbc_decrypt(const struct ccmode_cbc *mode, cccbc_ctx *ctx, size_t n, const void *key) {
    (void)mode; return init(ctx, n, key, DECRYPT);
}
const struct ccmode_ecb md_aes_ecb_encrypt = {
    .size = sizeof(struct aes_context), .block_size = 16, .init = init_ecb_encrypt, .ecb = encrypt_ecb,
};
const struct ccmode_ecb md_aes_ecb_decrypt = {
    .size = sizeof(struct aes_context), .block_size = 16, .init = init_ecb_decrypt, .ecb = decrypt_ecb,
};
const struct ccmode_cbc md_aes_cbc_encrypt = {
    .size = sizeof(struct aes_context), .block_size = 16, .init = init_cbc_encrypt, .cbc = encrypt_cbc,
};
const struct ccmode_cbc md_aes_cbc_decrypt = {
    .size = sizeof(struct aes_context), .block_size = 16, .init = init_cbc_decrypt, .cbc = decrypt_cbc,
};

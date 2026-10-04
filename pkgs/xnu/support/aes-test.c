/* SPDX-License-Identifier: MIT
 * FIPS 197 block vectors and SP 800-38A F.2 CBC vectors through XNU's table.
 */
#include <libkern/crypto/register_crypto.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
extern struct crypto_functions md_crypto_functions;
static void hex(const char *text, unsigned char *out) {
    for (size_t i = 0; text[i * 2]; ++i) {
        unsigned value; assert(sscanf(text + i * 2, "%2x", &value) == 1); out[i] = value;
    }
}
void test_aes(void) {
    const char *block_cipher[] = {
        "69c4e0d86a7b0430d8cdb78070b4c55a", "dda97ca4864cdfe06eaf70a0ec0d7191",
        "8ea2b7ca516745bfeafc49904b496089",
    };
    const char *keys[] = {
        "2b7e151628aed2a6abf7158809cf4f3c", "8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b",
        "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4",
    };
    const char *cbc_cipher[] = {
        "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7",
        "4f021db243bc633d7178183a9fa071e8b4d9ada9ad7dedf4e5e738763f69145a571b242012fb7ae07fa9baac3df102e008b0e27988598881d920a9e64f5615cd",
        "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b",
    };
    unsigned char plain[64], expected[64], key[32], block[64], iv[16], original_iv[16];
    hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710", plain);
    hex("000102030405060708090a0b0c0d0e0f", original_iv);
    const struct ccmode_ecb *enc = md_crypto_functions.ccaes_ecb_encrypt, *dec = md_crypto_functions.ccaes_ecb_decrypt;
    const struct ccmode_cbc *ce = md_crypto_functions.ccaes_cbc_encrypt, *cd = md_crypto_functions.ccaes_cbc_decrypt;
    assert(enc && dec && ce && cd && enc->size <= 512 && ce->size <= 512 && ce->block_size == 16);
    ccecb_ctx_decl(enc->size, ectx); ccecb_ctx_decl(dec->size, dctx);
    cccbc_ctx_decl(ce->size, cctx); cccbc_ctx_decl(cd->size, rctx);
    for (unsigned v = 0; v < 3; ++v) {
        size_t length = 16 + v * 8;
        for (size_t j = 0; j < length; ++j) key[j] = (unsigned char)j;
        hex("00112233445566778899aabbccddeeff", block); hex(block_cipher[v], expected);
        assert(!enc->init(enc, ectx, length, key) && !dec->init(dec, dctx, length, key));
        assert(!enc->ecb(ectx, 1, block, block) && !memcmp(block, expected, 16));
        assert(!dec->ecb(dctx, 1, block, block));
        hex("00112233445566778899aabbccddeeff", expected); assert(!memcmp(block, expected, 16));
        hex(keys[v], key); hex(cbc_cipher[v], expected);
        assert(!ce->init(ce, cctx, length, key) && !cd->init(cd, rctx, length, key));
        memcpy(iv, original_iv, 16);
        assert(!ce->cbc(cctx, (void *)iv, 4, plain, block) && !memcmp(block, expected, 64));
        assert(!memcmp(iv, expected + 48, 16));
        memcpy(iv, original_iv, 16);
        assert(!cd->cbc(rctx, (void *)iv, 4, block, block) && !memcmp(block, plain, 64));
        assert(!memcmp(iv, expected + 48, 16));
        memcpy(iv, original_iv, 16); memcpy(block, plain, 64);
        assert(!ce->cbc(cctx, (void *)iv, 2, block, block));
        assert(!ce->cbc(cctx, (void *)iv, 2, block + 32, block + 32));
        assert(!memcmp(block, expected, 64));
        memcpy(iv, original_iv, 16);
        assert(!cd->cbc(rctx, (void *)iv, 3, block, block));
        assert(!cd->cbc(rctx, (void *)iv, 1, block + 48, block + 48));
        assert(!memcmp(block, plain, 64));
        memcpy(iv, original_iv, 16);
        assert(!ce->cbc(cctx, (void *)iv, 0, NULL, NULL) && !memcmp(iv, original_iv, 16));
        assert(ce->cbc(cctx, (void *)iv, SIZE_MAX / 16 + 1, plain, block));
        assert(!memcmp(iv, original_iv, 16) && !memcmp(block, plain, 64));
        assert(enc->ecb(dctx, 1, plain, block));
    }
    for (size_t n = 0; n <= 40; ++n) {
        if (n == 16 || n == 24 || n == 32) continue;
        memset(cctx, 0xff, ce->size);
        assert(ce->init(ce, cctx, n, key));
        for (size_t i = 0; i < ce->size; ++i) assert(((unsigned char *)cctx)[i] == 0);
        assert(ce->cbc(cctx, (void *)iv, 1, plain, block));
    }
    assert(ce->init(ce, cctx, 16, NULL));
    cc_clear(enc->size, ectx); cc_clear(dec->size, dctx);
    cc_clear(ce->size, cctx); cc_clear(cd->size, rctx);
    puts("AES-128/192/256 ECB/CBC known answers, in-place/split updates and invalid inputs passed");
}

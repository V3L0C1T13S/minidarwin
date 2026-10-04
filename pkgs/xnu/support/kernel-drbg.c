/* SPDX-License-Identifier: MIT
 * HMAC_DRBG, NIST SP 800-90A Rev.1 section 10.1.2. No allocation or entropy
 * source is hidden here: callers must supply entropy and serialize each state.
 * https://doi.org/10.6028/NIST.SP.800-90Ar1
 */
#include <corecrypto/ccdrbg.h>
#include <corecrypto/cc_error.h>
#include <corecrypto/cchmac.h>
#include <corecrypto/ccsha2.h>
#include <string.h>

struct hmac_drbg {
    const struct ccdigest_info *di;
    uint64_t reseed_counter;
    unsigned char key[64], value[64];
};
_Static_assert(sizeof(struct hmac_drbg) <= 264, "XNU early DRBG storage");
struct input { size_t size; const void *bytes; };
static bool valid_input(size_t n, const void *p, size_t maximum) {
    return n <= maximum && (!n || p);
}
static void update(struct hmac_drbg *s, const struct input *inputs, size_t count) {
    size_t provided = 0;
    for (size_t i=0; i<count; i++) provided |= inputs[i].size;
    for (unsigned char separator=0; separator < (provided ? 2 : 1); separator++) {
        cchmac_di_decl(s->di, ctx);
        cchmac_init(s->di, ctx, s->di->output_size, s->key);
        cchmac_update(s->di, ctx, s->di->output_size, s->value);
        cchmac_update(s->di, ctx, 1, &separator);
        for (size_t i=0; i<count; i++)
            cchmac_update(s->di, ctx, inputs[i].size, inputs[i].bytes);
        cchmac_final(s->di, ctx, s->key);
        cchmac_di_clear(s->di, ctx);
        cchmac(s->di, s->di->output_size, s->key, s->di->output_size, s->value, s->value);
    }
}
static int instantiate(const struct ccdrbg_info *info, struct ccdrbg_state *opaque,
    size_t entropy_size, const void *entropy, size_t nonce_size, const void *nonce,
    size_t personal_size, const void *personal) {
    const struct ccdrbg_nisthmac_custom *custom = info->custom;
    if (!opaque || !custom || (custom->di != &ccsha256_ltc_di && custom->di != &ccsha512_ltc_di) ||
        !valid_input(entropy_size, entropy, CCDRBG_MAX_ENTROPY_SIZE) ||
        !valid_input(nonce_size, nonce, CCDRBG_MAX_ENTROPY_SIZE) ||
        !valid_input(personal_size, personal, CCDRBG_MAX_PSINPUT_SIZE) ||
        entropy_size < 32 || entropy_size + nonce_size < 48)
        return CCDRBG_STATUS_PARAM_ERROR;
    struct hmac_drbg *s = (void *)opaque;
    cc_clear(sizeof(*s), s); s->di = custom->di;
    memset(s->value, 1, s->di->output_size);
    const struct input inputs[] = {{entropy_size,entropy}, {nonce_size,nonce}, {personal_size,personal}};
    update(s, inputs, 3); s->reseed_counter = 1;
    return 0;
}
static int reseed(struct ccdrbg_state *opaque, size_t n, const void *entropy,
    size_t extra_size, const void *extra) {
    struct hmac_drbg *s = (void *)opaque;
    if (!s || !s->di || !s->reseed_counter || n < 32 ||
        !valid_input(n, entropy, CCDRBG_MAX_ENTROPY_SIZE) ||
        !valid_input(extra_size, extra, CCDRBG_MAX_ADDITIONALINPUT_SIZE))
        return CCDRBG_STATUS_PARAM_ERROR;
    const struct input inputs[] = {{n,entropy}, {extra_size,extra}};
    update(s, inputs, 2); s->reseed_counter = 1;
    return 0;
}
static bool must_reseed(const struct ccdrbg_state *opaque) {
    const struct hmac_drbg *s = (const void *)opaque;
    return !s || !s->di || !s->reseed_counter || s->reseed_counter > CCDRBG_RESEED_INTERVAL;
}
static int generate(struct ccdrbg_state *opaque, size_t n, void *out,
    size_t extra_size, const void *extra) {
    if (!valid_input(n, out, CCDRBG_MAX_REQUEST_SIZE) ||
        !valid_input(extra_size, extra, CCDRBG_MAX_ADDITIONALINPUT_SIZE))
        return CCDRBG_STATUS_PARAM_ERROR;
    if (must_reseed(opaque)) return CCDRBG_STATUS_NEED_RESEED;
    struct hmac_drbg *s = (void *)opaque;
    const struct input input = {extra_size, extra};
    if (extra_size) update(s, &input, 1);
    unsigned char *p = out;
    while (n) {
        cchmac(s->di, s->di->output_size, s->key, s->di->output_size, s->value, s->value);
        size_t count = n < s->di->output_size ? n : s->di->output_size;
        memcpy(p, s->value, count); p += count; n -= count;
    }
    update(s, &input, 1); s->reseed_counter++;
    return 0;
}
static void done(struct ccdrbg_state *opaque) {
    if (opaque) cc_clear(sizeof(struct hmac_drbg), opaque);
}
void ccdrbg_factory_nisthmac(struct ccdrbg_info *info, const struct ccdrbg_nisthmac_custom *custom) {
    *info = (struct ccdrbg_info){.size=sizeof(struct hmac_drbg), .init=instantiate,
        .reseed=reseed, .generate=generate, .done=done, .custom=custom, .must_reseed=must_reseed};
}
int ccdrbg_init(const struct ccdrbg_info *info, struct ccdrbg_state *s,
    size_t en, const void *e, size_t nn, const void *n, size_t pn, const void *p) {
    return info->init(info, s, en, e, nn, n, pn, p);
}
int ccdrbg_reseed(const struct ccdrbg_info *info, struct ccdrbg_state *s,
    size_t en, const void *e, size_t an, const void *a) {
    return info->reseed(s, en, e, an, a);
}
int ccdrbg_generate(const struct ccdrbg_info *info, struct ccdrbg_state *s,
    size_t n, void *out, size_t an, const void *a) {
    return info->generate(s, n, out, an, a);
}
void ccdrbg_done(const struct ccdrbg_info *info, struct ccdrbg_state *s) { info->done(s); }
size_t ccdrbg_context_size(const struct ccdrbg_info *info) { return info->size; }
bool ccdrbg_must_reseed(const struct ccdrbg_info *info, const struct ccdrbg_state *s) { return info->must_reseed(s); }

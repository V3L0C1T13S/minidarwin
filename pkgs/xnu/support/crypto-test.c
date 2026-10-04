/* SPDX-License-Identifier: MIT */
#include <corecrypto/ccdigest.h>
#include <corecrypto/cchmac.h>
#include <corecrypto/ccdrbg.h>
#include <corecrypto/cc_error.h>
#include <corecrypto/ccsha1.h>
#include <corecrypto/ccsha2.h>
#include "kernel-rng.h"
#include <libkern/crypto/register_crypto.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern struct crypto_functions md_crypto_functions;
extern void test_aes(void);
void panic(const char *format, ...) { (void)format; abort(); }
static unsigned char *hex(const char *text, size_t *size) {
    *size=strlen(text)/2;
    assert(strlen(text)%2==0);
    unsigned char *p=malloc(*size+1);
    for(size_t i=0;i<*size;i++) { unsigned x; assert(sscanf(text+i*2,"%2x",&x)==1); p[i]=x; }
    return p;
}
int main(int argc, char **argv) {
    assert(argc>=4);
    if (!strcmp(argv[1], "aes")) { test_aes(); return 0; }
    const struct ccdigest_info *di = NULL;
    if(!strcmp(argv[2],"sha1")) di=ccsha1_di();
    if(!strcmp(argv[2],"sha256")) di=ccsha256_di();
    if(!strcmp(argv[2],"sha384")) di=ccsha384_di();
    if(!strcmp(argv[2],"sha512")) di=ccsha512_di();
    assert(di);
    unsigned char result[65536]; size_t result_size=di->output_size;
    if(!strcmp(argv[1],"api-digest") || !strcmp(argv[1],"api-hmac")) {
        struct crypto_functions *f=&md_crypto_functions;
        crypto_digest_alg_t alg=di==ccsha1_di()?CRYPTO_DIGEST_ALG_SHA1:
            di==ccsha256_di()?CRYPTO_DIGEST_ALG_SHA256:
            di==ccsha384_di()?CRYPTO_DIGEST_ALG_SHA384:CRYPTO_DIGEST_ALG_SHA512;
        unsigned char ctx[512] __attribute__((aligned(16))), once[64], verified[512];
        if(!strcmp(argv[1],"api-digest")) {
            size_t n; unsigned char *data=hex(argv[3],&n);
            size_t size=f->digest_ctx_size_fn(alg); assert(size<=sizeof(ctx));
            f->digest_init_fn(alg,ctx,size);
            f->digest_update_fn(alg,ctx,size,data,n/2);
            f->digest_update_fn(alg,ctx,size,data+n/2,n-n/2);
            f->digest_final_fn(alg,ctx,size,result,result_size);
            f->digest_fn(alg,data,n,once,result_size);
            assert(!memcmp(once,result,result_size)); free(data);
            for(size_t i=0;i<size;i++) assert(!ctx[i]);
        } else {
            assert(argc==5); size_t kn,n;
            unsigned char *key=hex(argv[3],&kn), *data=hex(argv[4],&n);
            size_t size=f->hmac_ctx_size_fn(alg); assert(size<=sizeof(ctx));
            f->hmac_init_fn(alg,ctx,size,key,kn);
            f->hmac_update_fn(alg,ctx,size,data,n);
            memcpy(verified,ctx,size);
            f->hmac_final_generate_fn(alg,ctx,size,result,result_size);
            assert(f->hmac_final_verify_fn(alg,verified,size,result,result_size));
            for(size_t i=0;i<size;i++) assert(!ctx[i] && !verified[i]);
            f->hmac_generate_fn(alg,key,kn,data,n,once,result_size);
            assert(!memcmp(once,result,result_size));
            assert(f->hmac_verify_fn(alg,key,kn,data,n,result,result_size));
            assert(f->hmac_verify_fn(alg,key,kn,data,n,result,result_size/2));
            for(size_t i=0;i<result_size;i++) {
                result[i]^=1; assert(!f->hmac_verify_fn(alg,key,kn,data,n,result,result_size)); result[i]^=1;
            }
            assert(!f->hmac_verify_fn(alg,key,kn,data,n,result,0));
            assert(!f->hmac_verify_fn(alg,key,kn,data,n,result,result_size+1));
            free(key);free(data);
        }
    } else if(!strcmp(argv[1],"digest")) {
        size_t n; unsigned char *p=hex(argv[3],&n);
        ccdigest_di_decl(di,ctx);
        ccdigest_init(di,ctx);
        /* Check the externally observed byte count and granule layout. */
        assert(!memcmp(ccdigest_state(di,ctx),di->initial_state,di->state_size));
        for(size_t i=0;i<n;i+=17) ccdigest_update(di,ctx,n-i<17?n-i:17,p+i);
        ccdigest_update(di,ctx,0,NULL);
        assert(ccdigest_num(di,ctx)==n%di->block_size);
        assert(ccdigest_nbits(di,ctx)==(n-n%di->block_size)*8);
        ccdigest_final(di,ctx,result); free(p);
    } else if(!strcmp(argv[1],"hmac")) {
        assert(argc==5); size_t kn,n;
        unsigned char *key=hex(argv[3],&kn), *p=hex(argv[4],&n);
        cchmac_di_decl(di,ctx);
        cchmac_init(di,ctx,kn,key);
        cchmac_update(di,ctx,n/2,p); cchmac_update(di,ctx,n-n/2,p+n/2);
        cchmac_final(di,ctx,result); free(key);free(p);
    } else if(!strcmp(argv[1],"rng")) {
        assert(argc==7 && di==ccsha512_di());
        size_t en,nn,rn;
        unsigned char *e=hex(argv[3],&en), *nonce=hex(argv[4],&nn), *r=hex(argv[5],&rn);
        struct md_rng ctx={0}, saved;
        assert(md_rng_generate(&ctx,1,result)!=0);
        assert(md_rng_init(&ctx,31,e,nn,nonce)!=0);
        assert(md_rng_init(&ctx,en,e,nn,nonce)==0);
        saved=ctx;
        assert(md_rng_generate(&ctx,65537,result)!=0);
        assert(md_rng_generate(&ctx,1,NULL)!=0);
        assert(md_rng_reseed(&ctx,31,e)!=0);
        uint64_t value;
        assert(md_rng_uniform(&ctx,0,&value)!=0);
        assert(!memcmp(&saved,&ctx,sizeof(ctx)));
        if(rn) assert(md_rng_reseed(&ctx,rn,r)==0);
        result_size=strtoul(argv[6],NULL,10); assert(result_size<=sizeof(result));
        assert(md_rng_generate(&ctx,result_size,result)==0);
        assert(md_rng_generate(&ctx,result_size,result)==0);
        saved=ctx;
        for(size_t i=0;i<100;i++) {
            assert(md_rng_uniform(&ctx,1,&value)==0 && value==0);
            assert(md_rng_uniform(&ctx,7,&value)==0 && value<7);
            assert(md_rng_uniform(&ctx,UINT64_MAX,&value)==0 && value<UINT64_MAX);
        }
        assert(memcmp(&saved,&ctx,sizeof(ctx)));
        free(e); free(nonce); free(r);
    } else {
        assert(!strcmp(argv[1],"drbg") && argc==11);
        unsigned char state[264] __attribute__((aligned(8)))={0};
        struct ccdrbg_info info;
        struct ccdrbg_nisthmac_custom custom={.di=di,.strictFIPS=1};
        ccdrbg_factory_nisthmac(&info,&custom);
        assert(info.size<=sizeof(state));
        struct ccdrbg_state *ctx=(void*)state;
        size_t lengths[7]; unsigned char *data[7];
        for(size_t i=0;i<7;i++) data[i]=hex(argv[i+3],&lengths[i]);
        assert(ccdrbg_init(&info,ctx,31,data[0],0,NULL,0,NULL)==CCDRBG_STATUS_PARAM_ERROR);
        assert(ccdrbg_init(&info,ctx,lengths[0],data[0],lengths[1],data[1],lengths[2],data[2])==0);
        if(lengths[3]) assert(ccdrbg_reseed(&info,ctx,lengths[3],data[3],lengths[4],data[4])==0);
        result_size=strtoul(argv[10],NULL,10); assert(result_size<=sizeof(result));
        unsigned char saved[264]; memcpy(saved,state,sizeof(state));
        assert(ccdrbg_generate(&info,ctx,65537,result,0,NULL)==CCDRBG_STATUS_PARAM_ERROR);
        assert(!memcmp(saved,state,sizeof(state)));
        for(size_t i=5;i<7;i++) assert(ccdrbg_generate(&info,ctx,result_size,result,lengths[i],data[i])==0);
        for(size_t i=0;i<7;i++) free(data[i]);
        ccdrbg_done(&info,ctx);
        for(size_t i=0;i<info.size;i++) assert(!state[i]);
        assert(ccdrbg_generate(&info,ctx,1,result,0,NULL)==CCDRBG_STATUS_NEED_RESEED);
    }
    for(size_t i=0;i<result_size;i++) printf("%02x",result[i]);
    puts("");
}

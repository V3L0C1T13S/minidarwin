/* SPDX-License-Identifier: MIT */
#include "TrustCache/API.h"
#include "trust-cache-signed.h"
#include <assert.h>
#include <string.h>

static void put32(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (uint8_t)(v >> (8 * i));
}
static void module(uint8_t *p, unsigned version, uint8_t uuid) {
    memset(p, 0, 72);
    put32(p, version); p[4] = uuid; put32(p + 20, 2);
    unsigned step = version == 0 ? 20 : version == 1 ? 22 : 24;
    memset(p + 24, 1, 20); memset(p + 24 + step, 2, 20);
    if (version) {
        p[44] = 2; p[45] = 1;
        p[24 + step + 20] = 4; p[24 + step + 21] = 2;
    }
    if (version == 2) { p[46] = 3; p[70] = 5; }
}
int main(void) {
    _Static_assert(sizeof(TCReturn_t) == 4, "return word layout");
    TrustCacheRuntime_t runtime;
    TrustCacheMutableRuntime_t mutable;
    TrustCache_t caches[6] = {0};
    uint8_t buffers[6][72], hash[20], uuid[16];
    TrustCacheQueryToken_t token;
    trustCacheInitializeRuntime(&runtime, &mutable, true, false, true, NULL);
    for (unsigned v = 0; v < 3; ++v) module(buffers[v], v, v + 1);
    assert(trustCacheLoadModule(&runtime, kTCTypeStatic, &caches[0], (uintptr_t)buffers[0], 72).error == 0);
    assert(caches[0].moduleSize == 64);
    assert(trustCacheLoadModule(&runtime, kTCTypeStatic, &caches[0], (uintptr_t)buffers[1], 72).error == kTCReturnInvalidArguments);
    assert(trustCacheLoadModule(&runtime, kTCTypeStatic, &caches[1], (uintptr_t)buffers[1], 72).error == 0);
    assert(caches[1].moduleSize == 68 && caches[0].prev == &caches[1]);
    assert(trustCacheLoadModule(&runtime, kTCTypeStatic, &caches[2], (uintptr_t)buffers[2], 72).error == kTCReturnNotPermitted);
    assert(trustCacheLoadModule(&runtime, kTCTypeEngineering, &caches[2], (uintptr_t)buffers[2], 72).error == kTCReturnNotPermitted);
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[2], (uintptr_t)buffers[2], 72).error == 0);
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], (uintptr_t)buffers[2], 72).error == kTCReturnDuplicate);
    assert(trustCacheLoadModule(&runtime, kTCTypeLTRS, &caches[3], (uintptr_t)buffers[2], 72).error == kTCReturnUnsupported);
    for (TCType_t type = kTCTypeDTRS; type < kTCTypeTotal; type++) {
        assert(TCTypeConfig[type].entitlementValue && *TCTypeConfig[type].entitlementValue);
        assert(trustCacheLoadModule(&runtime, type, &caches[3], (uintptr_t)buffers[2], 72).error == kTCReturnUnsupported);
    }
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], UINTPTR_MAX - 1, 72).error == kTCReturnOverflow);

    memset(hash, 2, sizeof(hash));
    assert(trustCacheQuery(&runtime, kTCQueryTypeLoadable, hash, &token).error == 0);
    assert(token.trustCache == &caches[2]);
    uint8_t byte = 0; uint64_t flags = 0; TCCapabilities_t capabilities = 0;
    assert(trustCacheQueryGetHashType(&token, &byte).error == 0 && byte == 4);
    assert(trustCacheQueryGetFlags(&token, &flags).error == 0 && flags == 2);
    assert(trustCacheQueryGetConstraintCategory(&token, &byte).error == 0 && byte == 5);
    assert(trustCacheQueryGetCapabilities(&token, &capabilities).error == 0 && capabilities == 7);
    assert(trustCacheQueryGetUUID(&token, uuid).error == 0 && uuid[0] == 3);
    token.trustCacheEntry = buffers[2] + 25;
    assert(trustCacheQueryGetFlags(&token, &flags).error == kTCReturnInvalidArguments);
    assert(trustCacheQuery(&runtime, kTCQueryTypeStatic, hash, &token).error == 0 && token.trustCache == &caches[1]);
    assert(trustCacheQueryGetConstraintCategory(&token, &byte).error == kTCReturnUnsupported);
    memset(hash, 3, sizeof(hash));
    assert(trustCacheQuery(&runtime, kTCQueryTypeAll, hash, &token).error == kTCReturnNotFound);
    assert(token.trustCache == NULL && token.trustCacheEntry == NULL);
    /* Even a well-formed raw module with a manifest must not grant trust. */
    TrustCacheRuntime_t before = runtime;
    TrustCacheMutableRuntime_t mutableBefore = mutable;
    TrustCache_t cacheBefore = caches[3];
    for (TCType_t type = 0; type < kTCTypeTotal; ++type) {
        assert(trustCacheLoadSigned(&runtime, type, &caches[3],
            (uintptr_t)buffers[2], 72, (uintptr_t)buffers[2], 72).error == kTCReturnUnsupported);
        assert(memcmp(&runtime, &before, sizeof(runtime)) == 0);
        assert(memcmp(&mutable, &mutableBefore, sizeof(mutable)) == 0);
        assert(memcmp(&caches[3], &cacheBefore, sizeof(cacheBefore)) == 0);
    }
    assert(trustCacheLoadSigned(NULL, kTCTypeStatic, NULL, 0, 0, 0, 0).error == kTCReturnUnsupported);

    /* Every truncation, including a partial entry, must be rejected. */
    module(buffers[3], 2, 4);
    for (size_t size = 0; size < 72; ++size)
        assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], (uintptr_t)buffers[3], size).error == kTCReturnInsufficientLength);
    put32(buffers[3] + 20, UINT32_MAX);
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], (uintptr_t)buffers[3], 72).error == kTCReturnInsufficientLength);
    module(buffers[3], 2, 4); buffers[3][47] = 1;
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], (uintptr_t)buffers[3], 72).error == kTCReturnInvalidModule);
    module(buffers[3], 2, 4); memset(buffers[3] + 48, 1, 20);
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], (uintptr_t)buffers[3], 72).error == kTCReturnInvalidModule);
    module(buffers[3], 2, 4); put32(buffers[3], 3);
    assert(trustCacheLoadModule(&runtime, kTCTypeLegacy, &caches[3], (uintptr_t)buffers[3], 72).error == kTCReturnUnsupported);

    trustCacheInitializeRuntime(&runtime, &mutable, false, true, false, NULL);
    module(buffers[4], 0, 5);
    assert(trustCacheLoadModule(&runtime, kTCTypeEngineering, &caches[4], (uintptr_t)buffers[4], 72).error == 0);
    memset(hash, 1, sizeof(hash));
    assert(trustCacheQuery(&runtime, kTCQueryTypeStatic, hash, &token).error == 0);
    assert(trustCacheQueryGetHashType(&token, &byte).error == kTCReturnUnsupported);
    assert(trustCacheQueryGetCapabilities(&token, &capabilities).error == 0 && capabilities == 0);
    return 0;
}

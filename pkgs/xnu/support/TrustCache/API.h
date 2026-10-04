/* SPDX-License-Identifier: MIT
 * MiniDarwin's source-level TrustCache contract. This is compiled together
 * with XNU and is not an ABI promise for Apple's proprietary AMFI kext.
 * Wire constants follow Apple's published xnu-8796.101.5 headers.
 */
#ifndef MINIDARWIN_TRUST_CACHE_API_H
#define MINIDARWIN_TRUST_CACHE_API_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct _img4_runtime img4_runtime_t;

#define kTCEntryHashSize 20
#define kUUIDSize 16
typedef uint8_t TCType_t;
enum {
    kTCTypeStatic = 0, kTCTypeEngineering = 1, kTCTypeLegacy = 2,
    kTCTypeDTRS = 3, kTCTypeLTRS = 4,
    kTCTypeCryptex1BootOS = 13, kTCTypeCryptex1BootApp = 14,
    kTCTypeTotal = 24, kTCTypeInvalid = 255
};
typedef uint8_t TCQueryType_t;
/* Signed loadable types are unsupported until a manifest verifier exists.
 * Their entitlement requirement must never be represented as an empty gate.
 */
typedef struct { const char *entitlementValue; } TCTypeConfig_t;
extern const TCTypeConfig_t TCTypeConfig[kTCTypeTotal];
enum {
    kTCQueryTypeAll = 0, kTCQueryTypeStatic = 1,
    kTCQueryTypeLoadable = 2, kTCQueryTypeTotal = 3
};
typedef uint64_t TCCapabilities_t;
enum {
    kTCCapabilityNone = 0, kTCCapabilityHashType = 1,
    kTCCapabilityFlags = 2, kTCCapabilityConstraintsCategory = 4
};
enum {
    kTCReturnSuccess = 0, kTCReturnError = 1,
    kTCReturnOverflow = 0x20, kTCReturnUnsupported = 0x21,
    kTCReturnInvalidModule = 0x22, kTCReturnDuplicate = 0x23,
    kTCReturnNotFound = 0x24, kTCReturnInvalidArguments = 0x25,
    kTCReturnInsufficientLength = 0x26, kTCReturnNotPermitted = 0x27
};
typedef union {
    uint32_t rawValue;
    struct { uint8_t component, error; uint16_t uniqueError; };
} TCReturn_t;

typedef struct TrustCache {
    struct TrustCache *next, *prev;
    TCType_t type;
    size_t moduleSize;
    const uint8_t *module;
} TrustCache_t;
typedef struct {
    const TrustCache_t *trustCache;
    const void *trustCacheEntry;
} TrustCacheQueryToken_t;
typedef struct { TrustCache_t *loadableTCHead; } TrustCacheMutableRuntime_t;
typedef struct {
    const img4_runtime_t *image4RT;
    bool allowSecondStaticTC, allowEngineeringTC, allowLegacyTC;
    TrustCache_t *staticTCHead, *engineeringTCHead;
    TrustCacheMutableRuntime_t *mutableRT;
} TrustCacheRuntime_t;

static inline void trustCacheInitializeRuntime(
    TrustCacheRuntime_t *r, TrustCacheMutableRuntime_t *m,
    bool second, bool engineering, bool legacy, const img4_runtime_t *image4)
{
    r->image4RT = image4;
    r->allowSecondStaticTC = second;
    r->allowEngineeringTC = engineering;
    r->allowLegacyTC = legacy;
    r->staticTCHead = r->engineeringTCHead = NULL;
    r->mutableRT = m;
    m->loadableTCHead = NULL;
}

#ifdef __cplusplus
extern "C" {
#endif
TCReturn_t trustCacheLoadModule(TrustCacheRuntime_t *, TCType_t, TrustCache_t *, uintptr_t, size_t);
TCReturn_t trustCacheQuery(const TrustCacheRuntime_t *, TCQueryType_t, const uint8_t *, TrustCacheQueryToken_t *);
TCReturn_t trustCacheCheckRuntimeForUUID(const TrustCacheRuntime_t *, const uint8_t *, const TrustCache_t **);
TCReturn_t trustCacheGetUUID(const TrustCache_t *, uint8_t *);
TCReturn_t trustCacheGetModule(const TrustCache_t *, const uint8_t **, size_t *);
TCReturn_t trustCacheGetCapabilities(const TrustCache_t *, TCCapabilities_t *);
TCReturn_t trustCacheQueryGetTCType(const TrustCacheQueryToken_t *, TCType_t *);
TCReturn_t trustCacheQueryGetCapabilities(const TrustCacheQueryToken_t *, TCCapabilities_t *);
TCReturn_t trustCacheQueryGetHashType(const TrustCacheQueryToken_t *, uint8_t *);
TCReturn_t trustCacheQueryGetFlags(const TrustCacheQueryToken_t *, uint64_t *);
TCReturn_t trustCacheQueryGetConstraintCategory(const TrustCacheQueryToken_t *, uint8_t *);
TCReturn_t trustCacheQueryGetUUID(const TrustCacheQueryToken_t *, uint8_t *);
#ifdef __cplusplus
}
#endif
#endif

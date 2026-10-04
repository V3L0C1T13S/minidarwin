/* SPDX-License-Identifier: MIT
 * Trust-cache modules supplied by a trusted caller. Caller serializes runtime
 * access and keeps module bytes immutable for the lifetime of the runtime.
 * Image4 manifests require separate verification; this module never accepts
 * them as authenticated loadable caches.
 */
#include "TrustCache/API.h"
#if KERNEL
#include <libkern/libkern.h>
#else
#include <string.h>
#endif

/* No authenticated loadable type is supported by this implementation. */
#define UNSUPPORTED { "minidarwin.unsupported-signed-trust-cache" }
const TCTypeConfig_t TCTypeConfig[kTCTypeTotal] = {
    UNSUPPORTED, UNSUPPORTED, UNSUPPORTED, UNSUPPORTED,
    UNSUPPORTED, UNSUPPORTED, UNSUPPORTED, UNSUPPORTED,
    UNSUPPORTED, UNSUPPORTED, UNSUPPORTED, UNSUPPORTED,
    UNSUPPORTED, UNSUPPORTED, UNSUPPORTED, UNSUPPORTED,
    UNSUPPORTED, UNSUPPORTED, UNSUPPORTED, UNSUPPORTED,
    UNSUPPORTED, UNSUPPORTED, UNSUPPORTED, UNSUPPORTED
};
#undef UNSUPPORTED

static TCReturn_t result(uint8_t error) {
    TCReturn_t r = { .component = 0, .error = error, .uniqueError = 0 };
    return r;
}
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
           (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static size_t stride(uint32_t version) {
    return version == 0 ? 20 : version == 1 ? 22 : version == 2 ? 24 : 0;
}
static uint8_t validate(const uint8_t *p, size_t length, size_t *actual) {
    if (!p) return kTCReturnInvalidArguments;
    if (length < 24) return kTCReturnInsufficientLength;
    size_t step = stride(le32(p));
    if (!step) return kTCReturnUnsupported;
    uint32_t count = le32(p + 20);
    if (count > (length - 24) / step) return kTCReturnInsufficientLength;
    for (uint32_t i = 0; i < count; ++i) {
        const uint8_t *entry = p + 24 + (size_t)i * step;
        if (step == 24 && entry[23]) return kTCReturnInvalidModule;
        if (i && memcmp(entry - step, entry, kTCEntryHashSize) >= 0)
            return kTCReturnInvalidModule;
    }
    *actual = 24 + (size_t)count * step;
    return kTCReturnSuccess;
}

TCReturn_t trustCacheCheckRuntimeForUUID(const TrustCacheRuntime_t *r,
                                       const uint8_t *uuid, const TrustCache_t **out) {
    if (out) *out = NULL;
    if (!r || !r->mutableRT || !uuid) return result(kTCReturnInvalidArguments);
    const TrustCache_t *heads[] = { r->staticTCHead, r->engineeringTCHead, r->mutableRT->loadableTCHead };
    for (size_t i = 0; i < 3; ++i)
        for (const TrustCache_t *tc = heads[i]; tc; tc = tc->next)
            if (memcmp(tc->module + 4, uuid, kUUIDSize) == 0) {
                if (out) *out = tc;
                return result(kTCReturnSuccess);
            }
    return result(kTCReturnNotFound);
}

TCReturn_t trustCacheLoadModule(TrustCacheRuntime_t *r, TCType_t type,
                              TrustCache_t *tc, uintptr_t address, size_t length) {
    if (!r || !r->mutableRT || !tc || !address)
        return result(kTCReturnInvalidArguments);
    const TrustCache_t *heads[] = { r->staticTCHead, r->engineeringTCHead, r->mutableRT->loadableTCHead };
    for (size_t i = 0; i < 3; ++i)
        for (const TrustCache_t *existing = heads[i]; existing; existing = existing->next)
            if (existing == tc) return result(kTCReturnInvalidArguments);
    if (address > UINTPTR_MAX - length) return result(kTCReturnOverflow);
    if (type != kTCTypeStatic && type != kTCTypeEngineering && type != kTCTypeLegacy)
        return result(kTCReturnUnsupported);
    if ((type == kTCTypeEngineering && !r->allowEngineeringTC) ||
        (type == kTCTypeLegacy && !r->allowLegacyTC)) return result(kTCReturnNotPermitted);
    size_t actual = 0;
    const uint8_t *p = (const uint8_t *)address;
    uint8_t error = validate(p, length, &actual);
    if (error) return result(error);
    if (!trustCacheCheckRuntimeForUUID(r, p + 4, NULL).error)
        return result(kTCReturnDuplicate);
    TrustCache_t **head = type == kTCTypeStatic ? &r->staticTCHead :
                         type == kTCTypeEngineering ? &r->engineeringTCHead :
                         &r->mutableRT->loadableTCHead;
    if (type == kTCTypeStatic && *head && (!r->allowSecondStaticTC || (*head)->next))
        return result(kTCReturnNotPermitted);
    tc->type = type;
    tc->module = p;
    tc->moduleSize = actual;
    tc->prev = NULL;
    tc->next = *head;
    if (*head) (*head)->prev = tc;
    *head = tc;
    return result(kTCReturnSuccess);
}

TCReturn_t trustCacheQuery(const TrustCacheRuntime_t *r, TCQueryType_t type,
                         const uint8_t *hash, TrustCacheQueryToken_t *out) {
    if (out) { out->trustCache = NULL; out->trustCacheEntry = NULL; }
    if (!r || !r->mutableRT || !hash || !out || type >= kTCQueryTypeTotal)
        return result(kTCReturnInvalidArguments);
    const TrustCache_t *heads[] = { r->staticTCHead, r->engineeringTCHead, r->mutableRT->loadableTCHead };
    for (size_t i = 0; i < 3; ++i) {
        if ((type == kTCQueryTypeStatic && i == 2) || (type == kTCQueryTypeLoadable && i != 2)) continue;
        for (const TrustCache_t *tc = heads[i]; tc; tc = tc->next) {
            size_t step = stride(le32(tc->module));
            size_t first = 0, end = le32(tc->module + 20);
            while (first < end) {
                size_t middle = first + (end - first) / 2;
                const uint8_t *entry = tc->module + 24 + middle * step;
                int cmp = memcmp(hash, entry, kTCEntryHashSize);
                if (!cmp) {
                    out->trustCache = tc;
                    out->trustCacheEntry = entry;
                    return result(kTCReturnSuccess);
                }
                if (cmp < 0) end = middle; else first = middle + 1;
            }
        }
    }
    return result(kTCReturnNotFound);
}

TCReturn_t trustCacheGetUUID(const TrustCache_t *tc, uint8_t *out) {
    if (!tc || !tc->module || tc->moduleSize < 24 || !out) return result(kTCReturnInvalidArguments);
    memcpy(out, tc->module + 4, kUUIDSize);
    return result(kTCReturnSuccess);
}
TCReturn_t trustCacheGetModule(const TrustCache_t *tc, const uint8_t **out, size_t *size) {
    if (!tc || !out || !size) return result(kTCReturnInvalidArguments);
    *out = tc->module; *size = tc->moduleSize;
    return result(kTCReturnSuccess);
}
TCReturn_t trustCacheGetCapabilities(const TrustCache_t *tc, TCCapabilities_t *out) {
    if (!tc || !tc->module || tc->moduleSize < 24 || !out) return result(kTCReturnInvalidArguments);
    uint32_t v = le32(tc->module);
    if (!stride(v)) return result(kTCReturnUnsupported);
    *out = v == 0 ? 0 : v == 1 ? 3 : 7;
    return result(kTCReturnSuccess);
}
static bool tokenValid(const TrustCacheQueryToken_t *t) {
    if (!t || !t->trustCache || !t->trustCache->module || !t->trustCacheEntry ||
        t->trustCache->moduleSize < 24) return false;
    uintptr_t start = (uintptr_t)t->trustCache->module;
    uintptr_t entry = (uintptr_t)t->trustCacheEntry;
    size_t step = stride(le32(t->trustCache->module));
    size_t length = t->trustCache->moduleSize;
    return step && length >= 24 + step && entry >= start && entry - start >= 24 &&
           entry - start <= length - step && (entry - start - 24) % step == 0;
}
TCReturn_t trustCacheQueryGetTCType(const TrustCacheQueryToken_t *t, TCType_t *out) {
    if (!tokenValid(t) || !out) return result(kTCReturnInvalidArguments);
    *out = t->trustCache->type;
    return result(kTCReturnSuccess);
}
TCReturn_t trustCacheQueryGetCapabilities(const TrustCacheQueryToken_t *t, TCCapabilities_t *out) {
    if (!tokenValid(t)) return result(kTCReturnInvalidArguments);
    return trustCacheGetCapabilities(t->trustCache, out);
}
static TCReturn_t field(const TrustCacheQueryToken_t *t, size_t offset, uint8_t *out) {
    if (!tokenValid(t) || !out) return result(kTCReturnInvalidArguments);
    if (stride(le32(t->trustCache->module)) <= offset) return result(kTCReturnUnsupported);
    *out = ((const uint8_t *)t->trustCacheEntry)[offset];
    return result(kTCReturnSuccess);
}
TCReturn_t trustCacheQueryGetHashType(const TrustCacheQueryToken_t *t, uint8_t *out) { return field(t, 20, out); }
TCReturn_t trustCacheQueryGetFlags(const TrustCacheQueryToken_t *t, uint64_t *out) {
    if (!out) return result(kTCReturnInvalidArguments);
    uint8_t value = 0;
    TCReturn_t r = field(t, 21, &value);
    if (!r.error) *out = value;
    return r;
}
TCReturn_t trustCacheQueryGetConstraintCategory(const TrustCacheQueryToken_t *t, uint8_t *out) { return field(t, 22, out); }
TCReturn_t trustCacheQueryGetUUID(const TrustCacheQueryToken_t *t, uint8_t *out) {
    if (!tokenValid(t)) return result(kTCReturnInvalidArguments);
    return trustCacheGetUUID(t->trustCache, out);
}

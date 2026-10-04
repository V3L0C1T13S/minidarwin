/* SPDX-License-Identifier: MIT
 * Image4 authentication is not implemented. No manifest or payload, including
 * a valid raw module, may be promoted to authenticated trust by this API.
 */
#include "trust-cache-signed.h"
TCReturn_t trustCacheLoadSigned(TrustCacheRuntime_t *runtime, TCType_t type,
    TrustCache_t *cache, uintptr_t payload, size_t payloadSize,
    uintptr_t manifest, size_t manifestSize)
{
    (void)runtime; (void)type; (void)cache; (void)payload; (void)payloadSize;
    (void)manifest; (void)manifestSize;
    return (TCReturn_t){ .error = kTCReturnUnsupported };
}

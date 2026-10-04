/* SPDX-License-Identifier: MIT */
#ifndef MINIDARWIN_TRUST_CACHE_SIGNED_H
#define MINIDARWIN_TRUST_CACHE_SIGNED_H
#include "TrustCache/API.h"
TCReturn_t trustCacheLoadSigned(TrustCacheRuntime_t *, TCType_t, TrustCache_t *,
    uintptr_t, size_t, uintptr_t, size_t);
#endif

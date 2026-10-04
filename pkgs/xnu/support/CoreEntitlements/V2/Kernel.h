/* SPDX-License-Identifier: MIT
 * Source contract for the bridge referenced by XNU's ubc_subr.c.
 * A provider must be built with this header and registered explicitly.
 * Declaring the interface does not authorize or validate entitlements.
 */
#ifndef MINIDARWIN_CORE_ENTITLEMENTS_V2_KERNEL_H
#define MINIDARWIN_CORE_ENTITLEMENTS_V2_KERNEL_H
#include <CoreEntitlements/V2/API.h>
typedef struct {
    CEError_t (*contextGetLegacyContext)(const CEContext_t *, const void **);
} CEKernelAPI_t;
#endif

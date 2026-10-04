// SPDX-License-Identifier: MIT
#include <stdint.h>
#include <errno.h>
// MiniDarwin has no Apple AMFI service. Grant no optional loader privileges.
// Dyld's documented failure path uses the same zero policy. This is not
// code-signature validation or a substitute for the kernel's MAC framework.
int amfi_check_dyld_policy_self(uint64_t inputs, uint64_t *outputs) {
    (void)inputs;
    if (!outputs) return EINVAL;
    *outputs = 0;
    return 0;
}

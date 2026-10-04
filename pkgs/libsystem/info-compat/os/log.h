/* SPDX-License-Identifier: MIT
 * libsystem_trace is closed source. Libinfo's os_log calls are diagnostics
 * only, so they compile to nothing instead of importing _os_log_default (data,
 * bound at load) and _os_log_internal.
 */
#include_next <os/log.h>
#undef OS_LOG_DEFAULT
#define OS_LOG_DEFAULT OS_LOG_DISABLED
#define os_log_create(subsystem, category) ((void)(subsystem), (void)(category), OS_LOG_DISABLED)
#undef os_log_with_type
#define os_log_with_type(log, type, format, ...) ((void)(log))

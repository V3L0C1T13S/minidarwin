/* os/thread_self_restrict.h - shim. xnu ships an empty stub; libpthread needs
 * 3 W^X functions. Stubbed as unsupported (Intel-Mac config); no special-register
 * impl. Delete if Apple ships the real header. */

#ifndef OS_THREAD_SELF_RESTRICT_H
#define OS_THREAD_SELF_RESTRICT_H

#include <stdbool.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

static inline bool
os_thread_self_restrict_rwx_is_supported(void)
{
	return false;
}

static inline void
os_thread_self_restrict_rwx_to_rw(void)
{
}

static inline void
os_thread_self_restrict_rwx_to_rx(void)
{
}

__END_DECLS

#endif /* OS_THREAD_SELF_RESTRICT_H */

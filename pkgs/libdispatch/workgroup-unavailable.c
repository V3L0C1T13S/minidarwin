/* The pinned XNU Libsyscall lacks the work_interval_instance API required by
 * Apple's workgroup.c. Core dispatch can run without a workgroup, but its
 * workloop path retains calls to these hooks. Fail explicitly if reached. */
#include <errno.h>
#include <stdlib.h>

__attribute__((visibility("hidden"))) void
_os_workgroup_tsd_cleanup(void *context)
{
  if (context) abort();
}

__attribute__((visibility("hidden"))) void
_os_workgroup_join_token_tsd_cleanup(void *context)
{
  if (context) abort();
}

__attribute__((visibility("hidden"))) void
_os_workgroup_join_update_wg(void *workgroup, void *token)
{
  (void)workgroup;
  (void)token;
  abort();
}

__attribute__((visibility("hidden"))) int
os_workgroup_join(void *workgroup, void *token)
{
  (void)workgroup;
  (void)token;
  return EINVAL;
}

__attribute__((visibility("hidden"))) void
os_workgroup_leave(void *workgroup, void *token)
{
  (void)workgroup;
  (void)token;
  abort();
}

__attribute__((visibility("hidden"))) unsigned int
_os_workgroup_get_backing_workinterval(void *workgroup)
{
  (void)workgroup;
  abort();
}

__attribute__((visibility("hidden"))) void
_workgroup_init(void)
{
}

/*
 * MiniDarwin compatibility implementation for the one-time initializer used
 * by copyfile's xattr flag table. libdispatch is not built in this SDK yet.
 */
#include <dispatch/dispatch.h>

__attribute__((visibility("hidden")))
void
dispatch_once(dispatch_once_t *predicate, dispatch_block_t block)
{
  long expected = 0;

  if (__atomic_compare_exchange_n(predicate, &expected, 1, 0,
                                  __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
    block();
    __atomic_store_n(predicate, 2, __ATOMIC_RELEASE);
  } else {
    while (__atomic_load_n(predicate, __ATOMIC_ACQUIRE) != 2) {
      __asm__ __volatile__("" ::: "memory");
    }
  }
}

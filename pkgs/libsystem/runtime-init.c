/* SPDX-License-Identifier: MIT
 * Initialize the open MiniDarwin members in Libsystem-1356's dependency order.
 * Callback layouts come from the pinned SDK; absent members supply no hooks.
 */
#include <stddef.h>
#include <stdlib.h>
#include <errno.h>
#include <dlfcn.h>
#include <pthread.h>
#include <pthread/private.h>
#include <malloc/malloc.h>
#include <malloc_implementation.h>
#include <_libc_init.h>
#include <_libkernel_init.h>
extern void __libplatform_init(void *, const char *[], const char *[], const struct ProgramVars *);
extern void __pthread_init(const struct _libpthread_functions *, const char *[], const char *[], const struct ProgramVars *);
extern void __pthread_late_init(const char *[], const char *[], const struct ProgramVars *);
extern void _dyld_initializer(void);
extern void libdispatch_init(void);
extern void _pthread_exit_if_canceled(int);
extern void _pthread_clear_qos_tsd(mach_port_t);
#define FORK_HOOK(name) extern void name(void)
FORK_HOOK(_pthread_atfork_prepare); FORK_HOOK(_pthread_atfork_parent); FORK_HOOK(_pthread_atfork_child);
FORK_HOOK(_pthread_atfork_prepare_handlers); FORK_HOOK(_pthread_atfork_parent_handlers); FORK_HOOK(_pthread_atfork_child_handlers);
FORK_HOOK(dispatch_atfork_prepare); FORK_HOOK(dispatch_atfork_parent); FORK_HOOK(dispatch_atfork_child);
FORK_HOOK(_malloc_fork_prepare); FORK_HOOK(_malloc_fork_parent); FORK_HOOK(_malloc_fork_child);
FORK_HOOK(_mach_fork_child); FORK_HOOK(_dyld_atfork_prepare); FORK_HOOK(_dyld_atfork_parent); FORK_HOOK(_dyld_fork_child);
FORK_HOOK(_dyld_dlopen_atfork_prepare); FORK_HOOK(_dyld_dlopen_atfork_parent); FORK_HOOK(_dyld_dlopen_atfork_child);
static void prepare(unsigned flags, ...) {
    _dyld_dlopen_atfork_prepare();
    if (!(flags & LIBSYSTEM_ATFORK_HANDLERS_ONLY_FLAG)) _pthread_atfork_prepare_handlers();
    dispatch_atfork_prepare(); _dyld_atfork_prepare(); _malloc_fork_prepare();
    _libc_fork_prepare(); _pthread_atfork_prepare();
}
static void parent(unsigned flags, ...) {
    _pthread_atfork_parent(); _malloc_fork_parent(); _libc_fork_parent();
    _dyld_atfork_parent(); dispatch_atfork_parent(); _dyld_dlopen_atfork_parent();
    if (!(flags & LIBSYSTEM_ATFORK_HANDLERS_ONLY_FLAG)) _pthread_atfork_parent_handlers();
}
static void child(unsigned flags, ...) {
    _mach_fork_child(); _pthread_atfork_child(); _malloc_fork_child(); _libc_fork_child();
    _dyld_fork_child(); dispatch_atfork_child(); _dyld_dlopen_atfork_child();
    if (!(flags & LIBSYSTEM_ATFORK_HANDLERS_ONLY_FLAG)) _pthread_atfork_child_handlers();
}
__attribute__((constructor))
static void initialize(int argc, const char *argv[], const char *envp[],
                       const char *apple[], const struct ProgramVars *vars) {
    (void)argc; (void)argv;
    static const struct _libkernel_functions kernel = {
        .version = 5, .dlsym = dlsym, .malloc = malloc, .free = free, .realloc = realloc,
        ._pthread_exit_if_canceled = _pthread_exit_if_canceled,
        .pthread_clear_qos_tsd = _pthread_clear_qos_tsd,
        .pthread_current_stack_contains_np = pthread_current_stack_contains_np,
        .malloc_type_malloc = malloc_type_malloc, .malloc_type_free = malloc_type_free,
        .malloc_type_realloc = malloc_type_realloc,
    };
    static const struct _libpthread_functions pthread = {
        .version = 2, .exit = exit, .malloc = malloc, .free = free,
    };
    static const struct _libc_functions libc = {
        .version = 2, .atfork_prepare_v2 = prepare, .atfork_parent_v2 = parent, .atfork_child_v2 = child,
    };
    __libkernel_init(&kernel, envp, apple, vars);
    __libplatform_init(NULL, envp, apple, vars);
    __pthread_init(&pthread, envp, apple, vars);
    _libc_initializer(&libc, envp, apple, vars);
    __malloc_init(apple);
    _dyld_initializer();
    __pthread_late_init(envp, apple, vars);
    libdispatch_init();
    const struct _malloc_late_init late = { .version = 2, .dlopen = dlopen, .dlsym = dlsym };
    __malloc_late_init(&late);
    errno = 0;
}

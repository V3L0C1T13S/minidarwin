/* The two SoftLinking macros used by su. Keep optional EndpointSecurity
 * notification calls through dyld, without Apple's unreleased header. */
#include <stdbool.h>
#include <dlfcn.h>
#define SOFT_LINK_DYLIB(lib) \
    static void *lib##_handle;
#define SOFT_LINK_FUNCTION(lib, name, alias, result, params, args) \
    static result (*alias##_ptr) params; \
    static bool is##lib##name##Available(void) { \
        static bool tried; \
        if (!tried) { \
            tried = true; \
            lib##_handle = dlopen("/usr/lib/" #lib ".dylib", RTLD_LAZY | RTLD_LOCAL); \
            if (lib##_handle) alias##_ptr = dlsym(lib##_handle, #name); \
        } \
        return alias##_ptr != NULL; \
    } \
    static result alias params { alias##_ptr args; }

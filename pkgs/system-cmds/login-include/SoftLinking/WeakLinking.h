/* The one SoftLinking macro login uses, and the two EndpointSecurity calls it
 * names, whose header (<EndpointSecuritySystem/ESSubmitSPI.h>) is unreleased.
 * Declarations only, shaped by login_audit.c's calls: they stay weak imports
 * of an absent library, as Apple's login has them (the frameworks phase links
 * libEndpointSecuritySystem Weak), so login skips them when they resolve to
 * NULL. */
#ifndef MINIDARWIN_WEAKLINKING_H
#define MINIDARWIN_WEAKLINKING_H
#include <stdbool.h>
#include <sys/types.h>
void ess_notify_login_login(bool success, const char *failure_message,
    const char *username, uid_t *uid);
void ess_notify_login_logout(const char *username, uid_t uid);
#define WEAK_LINK_FORCE_IMPORT(sym) \
    extern __typeof__(sym) sym __attribute__((weak_import))
#endif

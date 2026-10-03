/* Minimal ABI declarations for arch's directory search. The implementation
 * belongs to the unreleased libsystem_coreservices; no host SDK is used. */
#ifndef MINIDARWIN_ARCH_SYSDIR_H
#define MINIDARWIN_ARCH_SYSDIR_H

typedef unsigned int sysdir_search_path_enumeration_state;

#define SYSDIR_DIRECTORY_LIBRARY 5U
#define SYSDIR_DOMAIN_MASK_ALL 0xffffU

sysdir_search_path_enumeration_state
sysdir_start_search_path_enumeration(unsigned int directory, unsigned int domains);
sysdir_search_path_enumeration_state
sysdir_get_next_search_path_enumeration(sysdir_search_path_enumeration_state state,
                                      char *path);

#endif

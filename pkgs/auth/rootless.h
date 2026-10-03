/* Unreleased libsystem_darwin SPI used by Apple's su and sudo.
 * Declarations only: the imports remain explicitly absent. */
#ifndef MINIDARWIN_ROOTLESS_H
#define MINIDARWIN_ROOTLESS_H
int rootless_restricted_environment(void);
int rootless_check_trusted_fd(int);
#endif

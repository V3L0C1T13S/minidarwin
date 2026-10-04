/* SPDX-License-Identifier: MIT
 * Open storage drivers must defer device-node creation until devfs_sinit.
 */
#ifndef MINIDARWIN_DEVFS_READY_H
#define MINIDARWIN_DEVFS_READY_H
#ifdef __cplusplus
extern "C" {
#endif
int devfs_is_ready(void);
#ifdef __cplusplus
}
#endif
#endif

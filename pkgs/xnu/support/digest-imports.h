/* SPDX-License-Identifier: MIT */
#include <stddef.h>
void explicit_bzero(void *, size_t);
/* LibreSSL normally supplies these through its configured build environment.
 * The freestanding provider uses explicit symbol prefixes instead of ELF
 * visibility directives, and exposes only its registered XNU callbacks.
 */
#ifndef __BEGIN_HIDDEN_DECLS
#define __BEGIN_HIDDEN_DECLS
#define __END_HIDDEN_DECLS
#endif

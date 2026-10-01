#include <stdio.h>

#if defined DEBUG
#define	ASSERT(e, m)		do { if (!(e)) { printf ("assert failed: %s: %d", __FILE__, __LINE__); printf m; puts ("\n"); } } while (0)
#else
#define	ASSERT(e, m)
#endif
/* Build-local fixed-buffer subset of Apple's unreleased usbuf interface.
 * w(1) uses it only to format the human-readable uptime line. */
#ifndef MINIDARWIN_USBUF_H
#define MINIDARWIN_USBUF_H

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

#define SBUF_FIXEDLEN 0

struct sbuf {
    char *data;
    size_t size;
    size_t used;
    int error;
};

static inline struct sbuf *
sbuf_new(struct sbuf *s, char *buffer, size_t size, int flags)
{
    (void)flags;
    s->data = buffer;
    s->size = size;
    s->used = 0;
    s->error = size == 0;
    if (size != 0)
        buffer[0] = '\0';
    return s;
}

static inline int __attribute__((format(printf, 2, 3)))
sbuf_printf(struct sbuf *s, const char *format, ...)
{
    va_list args;
    int written;
    if (s->error)
        return -1;
    va_start(args, format);
    written = vsnprintf(s->data + s->used, s->size - s->used, format, args);
    va_end(args);
    if (written < 0 || (size_t)written >= s->size - s->used) {
        s->error = 1;
        return -1;
    }
    s->used += (size_t)written;
    return 0;
}

static inline int sbuf_finish(struct sbuf *s) { return s->error ? -1 : 0; }
static inline char *sbuf_data(struct sbuf *s) { return s->data; }
static inline void sbuf_delete(struct sbuf *s) { (void)s; }

#endif

// SPDX-License-Identifier: MIT
// Standalone dyld cannot call libSystem's allocator before library startup.
#include "Allocator.h"
#include <cstdlib>
#include <cstring>
#include <new>
#include <errno.h>

extern "C" void *malloc(size_t n) {
    return lsl::MemoryManager::defaultAllocator().malloc(n ? n : 1);
}
extern "C" void free(void *p) {
    if (p) lsl::MemoryManager::defaultAllocator().free(p);
}
extern "C" void *calloc(size_t n, size_t size) {
    if (size && n > SIZE_MAX / size) { errno = ENOMEM; return nullptr; }
    void *p = malloc(n * size);
    if (p) memset(p, 0, n * size);
    return p;
}
extern "C" void *realloc(void *p, size_t n) {
    if (!p) return malloc(n);
    void *q = malloc(n);
    if (!q) return nullptr;
    size_t old = lsl::Allocator::size(p);
    memcpy(q, p, old < n ? old : n);
    free(p);
    return q;
}
extern "C" void *reallocf(void *p, size_t n) {
    void *q = realloc(p, n);
    if (!q) free(p);
    return q;
}
void *operator new(size_t n) {
    void *p = malloc(n);
    if (!p) abort();
    return p;
}
void *operator new[](size_t n) { return ::operator new(n); }
void operator delete(void *p) noexcept { free(p); }
void operator delete[](void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }
void operator delete[](void *p, size_t) noexcept { free(p); }

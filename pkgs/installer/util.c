/* Allocation, paths, files, decompression and digests. Everything here fails
 * by calling die(); callers never see a partial result. */
#include "mdpkg.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/evp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

void (*die_hook)(void);

_Noreturn void die(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fputs("mdpkg: ", stderr);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  /* The hook (transaction rollback) runs once and must not call die(). */
  void (*hook)(void) = die_hook;
  die_hook = NULL;
  if (hook)
    hook();
  exit(1);
}

void *xcalloc(size_t count, size_t size) {
  void *p = calloc(count ? count : 1, size ? size : 1);
  if (!p)
    die("out of memory");
  return p;
}

void *xrealloc(void *p, size_t count, size_t size) {
  if (size && count > SIZE_MAX / size)
    die("out of memory");
  p = realloc(p, count * size ? count * size : 1);
  if (!p)
    die("out of memory");
  return p;
}

char *xstrdup(const char *s) {
  char *p = strdup(s);
  if (!p)
    die("out of memory");
  return p;
}

char *xstrndup(const char *s, size_t n) {
  char *p = xcalloc(n + 1, 1);
  memcpy(p, s, n);
  return p;
}

char *path_join(const char *a, const char *b) {
  if (!*a)
    return xstrdup(b);
  if (!*b)
    return xstrdup(a);
  size_t n = strlen(a) + strlen(b) + 2;
  if (n > PATH_MAX)
    die("path too long: %s/%s", a, b);
  char *s = xcalloc(n, 1);
  snprintf(s, n, "%s%s%s", a, a[strlen(a) - 1] == '/' ? "" : "/", b);
  return s;
}

/* "a/b" -> "a", "a" -> "", "/a" -> "/". */
char *path_parent(const char *path) {
  const char *slash = strrchr(path, '/');
  if (!slash)
    return xstrdup("");
  if (slash == path)
    return xstrdup("/");
  return xstrndup(path, (size_t)(slash - path));
}

/* True if PATH is PREFIX or lies beneath it. */
int path_has_prefix(const char *path, const char *prefix) {
  size_t n = strlen(prefix);
  return !strncmp(path, prefix, n) && (path[n] == 0 || path[n] == '/');
}

/* Normalizes a package path to root-relative form: drops "." and empty
 * components (CPIO names are "./usr/..."), refuses "..", control characters
 * and backslashes. An install-location is absolute; archive names never are. */
char *path_normalize(const char *path, int absolute) {
  const char *s = path;
  if (absolute) {
    if (*s != '/')
      die("install location must be absolute: %s", s);
    while (*s == '/')
      s++;
  } else if (*s == '/')
    die("absolute archive path: %s", s);
  size_t len = strlen(s), used = 0, depth = 0;
  char *out = xcalloc(len + 1, 1);
  while (*s) {
    const char *end = strchr(s, '/');
    size_t n = end ? (size_t)(end - s) : strlen(s);
    if (n && !(n == 1 && *s == '.')) {
      if ((n == 2 && !memcmp(s, "..", 2)) || n > NAME_MAX)
        die("unsafe path: %s", path);
      if (++depth > LIMIT_DEPTH)
        die("path nesting limit");
      for (size_t i = 0; i < n; i++)
        if ((unsigned char)s[i] < 32 || s[i] == '\\')
          die("unsupported character in path: %s", path);
      if (used)
        out[used++] = '/';
      memcpy(out + used, s, n);
      used += n;
    }
    if (!end)
      break;
    s = end + 1;
  }
  if (used >= PATH_MAX - NAME_MAX)
    die("path too long");
  return out;
}

int path_exists(const char *path) {
  struct stat st;
  if (!lstat(path, &st))
    return 1;
  if (errno != ENOENT)
    die("stat %s: %s", path, strerror(errno));
  return 0;
}

/* Checks, and with CREATE makes, every directory above REL beneath BASE.
 * A symlink or file in the way is an error: the installer never writes
 * through a link it did not resolve itself. */
void path_parents(const char *base, const char *rel, int create) {
  char *s = xstrdup(rel);
  for (char *p = s; *p; p++) {
    if (*p != '/')
      continue;
    *p = 0;
    char *host = path_join(base, s);
    struct stat st;
    if (!lstat(host, &st)) {
      if (!S_ISDIR(st.st_mode))
        die("not a directory: %s", host);
    } else if (errno != ENOENT)
      die("stat %s: %s", host, strerror(errno));
    else if (create && mkdir(host, 0755))
      die("mkdir %s: %s", host, strerror(errno));
    free(host);
    *p = '/';
  }
  free(s);
}

uint64_t parse_uint(const char *s, int base) {
  if (!s || !*s || *s == '-' || *s == '+' || *s == ' ')
    die("missing or invalid integer");
  errno = 0;
  char *end;
  unsigned long long v = strtoull(s, &end, base);
  if (errno || *end)
    die("invalid integer: %s", s);
  return v;
}

Bytes file_read(const char *path, size_t limit) {
  int fd = open(path, O_RDONLY | O_NOFOLLOW);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode))
    die("cannot read regular file %s", path);
  if ((uint64_t)st.st_size > limit)
    die("file too large: %s", path);
  Bytes b = {xcalloc((size_t)st.st_size, 1), (size_t)st.st_size};
  for (size_t pos = 0; pos < b.len;) {
    ssize_t n = read(fd, b.data + pos, b.len - pos);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      die("short read: %s", path);
    pos += (size_t)n;
  }
  close(fd);
  return b;
}

static void write_all(int fd, const unsigned char *p, size_t len,
                      const char *path) {
  while (len) {
    ssize_t n = write(fd, p, len);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      die("write %s: %s", path, strerror(errno));
    p += n;
    len -= (size_t)n;
  }
}

/* Creates PATH (never replacing or following anything) and syncs it: a root
 * is published by rename, so its contents must be durable first. */
static int file_create(const char *path) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
  if (fd < 0)
    die("create %s: %s", path, strerror(errno));
  return fd;
}

static void file_finish(int fd, const char *path, mode_t mode) {
  if (fchmod(fd, mode & 07777) || fsync(fd) || close(fd))
    die("flush %s: %s", path, strerror(errno));
}

void file_write(const char *path, Bytes contents, mode_t mode) {
  int fd = file_create(path);
  write_all(fd, contents.data, contents.len, path);
  file_finish(fd, path, mode);
}

void file_copy(const char *from, const char *to, mode_t mode) {
  int in = open(from, O_RDONLY | O_NOFOLLOW);
  if (in < 0)
    die("open %s: %s", from, strerror(errno));
  int out = file_create(to);
  unsigned char buf[1 << 16];
  for (;;) {
    ssize_t n = read(in, buf, sizeof(buf));
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0)
      die("read %s: %s", from, strerror(errno));
    if (!n)
      break;
    write_all(out, buf, (size_t)n, to);
  }
  close(in);
  file_finish(out, to, mode);
}

static size_t decoded_total;

/* Bounds the sum of everything decompressed from one package. */
void decoded_account(size_t n) {
  if (n > LIMIT_DECODED - decoded_total)
    die("total decompression limit");
  decoded_total += n;
}

/* window_bits: 15 for zlib (XAR's "application/x-gzip"), 31 for gzip. When
 * EXPECTED is nonzero, the output must be exactly that long. */
Bytes inflate_limited(Bytes in, int window_bits, size_t expected,
                      size_t limit) {
  z_stream z = {0};
  if (in.len > UINT_MAX || inflateInit2(&z, window_bits) != Z_OK)
    die("invalid compressed stream");
  size_t cap = expected ? expected : 65536;
  if (cap > limit)
    die("decompression limit");
  Bytes out = {xcalloc(cap, 1), 0};
  z.next_in = in.data;
  z.avail_in = (uInt)in.len;
  int status;
  do {
    if (out.len == cap) {
      if (cap == limit)
        die("decompression limit");
      cap = cap > limit / 2 ? limit : cap * 2;
      out.data = xrealloc(out.data, cap, 1);
    }
    size_t room = cap - out.len;
    z.next_out = out.data + out.len;
    z.avail_out = room > UINT_MAX ? UINT_MAX : (uInt)room;
    status = inflate(&z, Z_NO_FLUSH);
    out.len = (size_t)z.total_out;
    if (status != Z_OK && status != Z_STREAM_END)
      die("corrupt compressed stream");
    if (status != Z_STREAM_END && !z.avail_in && z.avail_out)
      die("truncated compressed stream");
  } while (status != Z_STREAM_END);
  if (z.avail_in || (expected && out.len != expected))
    die("compressed stream size mismatch");
  inflateEnd(&z);
  decoded_account(out.len);
  return out;
}

Bytes digest(Bytes in, const char *algorithm) {
  const EVP_MD *md = !strcmp(algorithm, "sha1")     ? EVP_sha1()
                     : !strcmp(algorithm, "md5")    ? EVP_md5()
                     : !strcmp(algorithm, "sha256") ? EVP_sha256()
                     : !strcmp(algorithm, "sha512") ? EVP_sha512()
                                                    : NULL;
  if (!md)
    die("unsupported checksum algorithm: %s", algorithm);
  Bytes out = {xcalloc(EVP_MAX_MD_SIZE, 1), 0};
  unsigned int n;
  if (!EVP_Digest(in.data, in.len, out.data, &n, md, NULL))
    die("checksum failure");
  out.len = n;
  return out;
}

Bytes file_sha256(const char *path) {
  int fd = open(path, O_RDONLY | O_NOFOLLOW);
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  if (fd < 0 || !ctx || !EVP_DigestInit_ex(ctx, EVP_sha256(), NULL))
    die("hash %s: %s", path, strerror(errno));
  unsigned char buf[1 << 16];
  for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n < 0 && errno == EINTR)
      continue;
    if (n < 0)
      die("read %s: %s", path, strerror(errno));
    if (!n)
      break;
    if (!EVP_DigestUpdate(ctx, buf, (size_t)n))
      die("hash %s", path);
  }
  close(fd);
  Bytes out = {xcalloc(EVP_MAX_MD_SIZE, 1), 0};
  unsigned int len;
  if (!EVP_DigestFinal_ex(ctx, out.data, &len))
    die("hash %s", path);
  EVP_MD_CTX_free(ctx);
  out.len = len;
  return out;
}

char *hex_encode(Bytes b) {
  static const char digits[] = "0123456789abcdef";
  char *s = xcalloc(b.len * 2 + 1, 1);
  for (size_t i = 0; i < b.len; i++) {
    s[2 * i] = digits[b.data[i] >> 4];
    s[2 * i + 1] = digits[b.data[i] & 15];
  }
  return s;
}

void entries_append(EntryList *list, Entry e) {
  if (list->count >= LIMIT_ENTRIES)
    die("entry limit");
  list->items = xrealloc(list->items, list->count + 1, sizeof(Entry));
  list->items[list->count++] = e;
}

void entries_free(EntryList *list) {
  for (size_t i = 0; i < list->count; i++) {
    free(list->items[i].path);
    free(list->items[i].package_path);
    free(list->items[i].link);
    free(list->items[i].data.data);
  }
  free(list->items);
  *list = (EntryList){0};
}

Entry *entries_find(EntryList *list, const char *path) {
  for (size_t i = 0; i < list->count; i++)
    if (!strcmp(list->items[i].path, path))
      return &list->items[i];
  return NULL;
}

/* Path order in which '/' sorts first, so "a/b" directly follows "a". */
static int path_compare(const char *a, const char *b) {
  for (;; a++, b++) {
    unsigned char x = *a == '/' ? 1 : (unsigned char)*a;
    unsigned char y = *b == '/' ? 1 : (unsigned char)*b;
    if (x != y || !x)
      return x - y;
  }
}

static int entry_ptr_compare(const void *a, const void *b) {
  return path_compare((*(Entry *const *)a)->path, (*(Entry *const *)b)->path);
}

/* Refuses duplicate paths and entries beneath a non-directory entry (such as
 * a file written through a packaged symlink). Directories may repeat across
 * components when ALLOW_REPEATED_DIRECTORIES is set. */
void entries_check_paths(EntryList *list, int allow_repeated_directories) {
  Entry **sorted = xcalloc(list->count, sizeof(Entry *));
  for (size_t i = 0; i < list->count; i++)
    sorted[i] = &list->items[i];
  qsort(sorted, list->count, sizeof(Entry *), entry_ptr_compare);
  for (size_t i = 1; i < list->count; i++)
    if (!strcmp(sorted[i - 1]->path, sorted[i]->path) &&
        !(allow_repeated_directories && S_ISDIR(sorted[i - 1]->mode) &&
          S_ISDIR(sorted[i]->mode)))
      die("duplicate path in payload: %s", sorted[i]->path);
  for (size_t i = 0; i < list->count; i++) {
    char *path = xstrdup(sorted[i]->path);
    for (char *p = path; *p; p++) {
      if (*p != '/')
        continue;
      *p = 0;
      Entry key = {.path = path}, *keyp = &key;
      Entry **parent = bsearch(&keyp, sorted, list->count, sizeof(Entry *),
                               entry_ptr_compare);
      if (parent && !S_ISDIR((*parent)->mode))
        die("payload entry beneath a non-directory: %s", sorted[i]->path);
      *p = '/';
    }
    free(path);
  }
  free(sorted);
}

/* Cheap early refusal of symlinks whose target leaves the root on its own
 * terms. Chains through other symlinks are resolved against the staged tree
 * later (install.c), before anything is published. */
void symlink_check_lexical(const char *path, const char *target) {
  if (!*target || *target == '/')
    die("absolute or empty symlink: %s", path);
  long depth = 0;
  for (const char *p = path; *p; p++)
    depth += *p == '/';
  char *copy = xstrdup(target), *save = NULL;
  for (char *c = strtok_r(copy, "/", &save); c; c = strtok_r(NULL, "/", &save))
    if (!strcmp(c, "..")) {
      if (--depth < 0)
        die("symlink escapes root: %s -> %s", path, target);
    } else if (strcmp(c, "."))
      depth++;
  free(copy);
}

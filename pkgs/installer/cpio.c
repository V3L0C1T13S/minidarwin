/* Payload and Scripts archives: raw or gzip-compressed CPIO in the odc
 * (070707), newc (070701) or crc (070702) formats. pbzx and other
 * compressions are refused. */
#include "mdpkg.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static uint64_t header_field(const unsigned char *p, size_t n, int base) {
  char buf[24];
  if (n >= sizeof(buf))
    die("CPIO header field too long");
  memcpy(buf, p, n);
  buf[n] = 0;
  return parse_uint(buf, base);
}

typedef struct {
  uint64_t mode, uid, gid, nlink, mtime, namesize, filesize, check;
  size_t header_len;
  int aligned; /* newc/crc pad the name and data to 4 bytes */
  int has_crc;
} Header;

static void read_header(const unsigned char *h, size_t avail, Header *out) {
  if (avail < 6)
    die("truncated CPIO header");
  int odc = !memcmp(h, "070707", 6), newc = !memcmp(h, "070701", 6),
      crc = !memcmp(h, "070702", 6);
  if (!odc && !newc && !crc)
    die("unsupported payload format or compression");
  *out = (Header){.header_len = odc ? 76 : 110, .aligned = !odc,
                  .has_crc = crc};
  if (avail < out->header_len)
    die("truncated CPIO header");
  if (odc) {
    out->mode = header_field(h + 18, 6, 8);
    out->uid = header_field(h + 24, 6, 8);
    out->gid = header_field(h + 30, 6, 8);
    out->nlink = header_field(h + 36, 6, 8);
    out->mtime = header_field(h + 48, 11, 8);
    out->namesize = header_field(h + 59, 6, 8);
    out->filesize = header_field(h + 65, 11, 8);
  } else {
    out->mode = header_field(h + 14, 8, 16);
    out->uid = header_field(h + 22, 8, 16);
    out->gid = header_field(h + 30, 8, 16);
    out->nlink = header_field(h + 38, 8, 16);
    out->mtime = header_field(h + 46, 8, 16);
    out->filesize = header_field(h + 54, 8, 16);
    out->namesize = header_field(h + 94, 8, 16);
    out->check = header_field(h + 102, 8, 16);
  }
}

/* True if any component is "__MACOSX" or an AppleDouble "._name". */
static int is_appledouble(const char *path) {
  for (const char *c = path; *c; c = strchr(c, '/') ? strchr(c, '/') + 1 : "") {
    size_t n = strcspn(c, "/");
    if (!strncmp(c, "._", 2) || (n == 8 && !strncmp(c, "__MACOSX", 8)))
      return 1;
  }
  return 0;
}

static Entry make_entry(const Header *h, const char *name, Bytes data) {
  char *path = path_normalize(name, 0);
  mode_t type = (mode_t)h->mode & S_IFMT;
  if (is_appledouble(path))
    die("AppleDouble metadata is not supported: %s", path);
  if (type != S_IFREG && type != S_IFDIR && type != S_IFLNK)
    die("unsupported file type: %s", path);
  if (!*path && type != S_IFDIR)
    die("payload root is not a directory");
  if (h->mode > 0177777 || h->uid > UINT32_MAX || h->gid > UINT32_MAX ||
      h->mtime > (uint64_t)INT64_MAX)
    die("CPIO metadata out of range: %s", path);
  if (type == S_IFREG && h->nlink > 1)
    die("hardlinks are not supported: %s", path);
  if (h->mode & (S_ISUID | S_ISGID))
    die("set-id payloads are not supported: %s", path);
  if (type == S_IFDIR && data.len)
    die("directory with data: %s", path);
  if (h->has_crc) {
    uint32_t sum = 0;
    for (size_t i = 0; i < data.len; i++)
      sum += data.data[i];
    if (sum != h->check)
      die("CPIO checksum mismatch: %s", path);
  }
  Entry e = {.path = path, .mode = (mode_t)h->mode, .uid = (uid_t)h->uid,
             .gid = (gid_t)h->gid, .mtime = (time_t)h->mtime};
  if (type == S_IFLNK) {
    if (!data.len || memchr(data.data, 0, data.len) || data.len >= PATH_MAX)
      die("invalid symlink: %s", path);
    e.link = xstrndup((const char *)data.data, data.len);
    symlink_check_lexical(path, e.link);
  } else if (type == S_IFREG) {
    e.data = (Bytes){xcalloc(data.len, 1), data.len};
    memcpy(e.data.data, data.data, data.len);
  }
  return e;
}

void cpio_parse(Bytes archive, EntryList *out) {
  int gzipped = archive.len >= 2 && archive.data[0] == 0x1f &&
                archive.data[1] == 0x8b;
  Bytes b = gzipped ? inflate_limited(archive, 31, 0, LIMIT_MEMBER) : archive;
  size_t pos = 0;
  int trailer = 0;
  while (pos < b.len && !trailer) {
    Header h;
    read_header(b.data + pos, b.len - pos, &h);
    size_t name_at = pos + h.header_len;
    if (!h.namesize || h.namesize >= PATH_MAX ||
        h.namesize > b.len - name_at)
      die("CPIO name out of bounds");
    const char *name = (const char *)b.data + name_at;
    if (name[h.namesize - 1] || memchr(name, 0, (size_t)h.namesize - 1))
      die("invalid CPIO name");
    size_t data_at = name_at + (size_t)h.namesize;
    if (h.aligned)
      data_at = (data_at + 3) & ~(size_t)3;
    if (data_at > b.len || h.filesize > b.len - data_at)
      die("CPIO data out of bounds");
    pos = data_at + (size_t)h.filesize;
    if (h.aligned)
      pos = (pos + 3) & ~(size_t)3;
    if (pos > b.len)
      die("truncated CPIO padding");
    if (!strcmp(name, "TRAILER!!!")) {
      if (h.filesize)
        die("invalid CPIO trailer");
      trailer = 1;
    } else
      entries_append(out, make_entry(&h, name,
                                     (Bytes){b.data + data_at, h.filesize}));
  }
  if (!trailer)
    die("missing CPIO trailer");
  for (; pos < b.len; pos++)
    if (b.data[pos])
      die("data after CPIO trailer");
  if (gzipped)
    free(b.data);
  entries_check_paths(out, 0);
}

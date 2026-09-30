/* XAR, the container of a flat package. Layout: a big-endian header, a
 * zlib-compressed XML table of contents, then a heap. The TOC names each
 * member's heap range and checksums; the TOC's own checksum is in the heap. */
#include "mdpkg.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define XAR_HEADER_MIN 28
#define XAR_HEADER_NAMED 64 /* with the 36-byte checksum name */

static uint64_t big_endian(const unsigned char *p, size_t n) {
  uint64_t v = 0;
  while (n--)
    v = (v << 8) | *p++;
  return v;
}

static void verify_checksum(xmlNode *checksum, Bytes data) {
  if (!checksum)
    die("missing XAR checksum");
  char *style = xml_attr(checksum, "style", NULL), *want = xml_text(checksum);
  Bytes hash = digest(data, style);
  char *got = hex_encode(hash);
  if (strcasecmp(want, got))
    die("XAR checksum mismatch");
  free(style);
  free(want);
  free(got);
  free(hash.data);
}

static Bytes read_member(xmlNode *data, Bytes heap) {
  uint64_t offset = xml_child_uint(data, "offset"),
           length = xml_child_uint(data, "length"),
           size = xml_child_uint(data, "size");
  if (offset > heap.len || length > heap.len - offset || size > LIMIT_MEMBER)
    die("XAR member out of bounds");
  Bytes encoded = {heap.data + offset, (size_t)length};
  verify_checksum(xml_child(data, "archived-checksum"), encoded);
  char *encoding = xml_attr(xml_child(data, "encoding"), "style", NULL);
  Bytes out;
  if (!strcmp(encoding, "application/x-gzip"))
    out = inflate_limited(encoded, 15, (size_t)size, LIMIT_MEMBER);
  else if (!strcmp(encoding, "application/octet-stream")) {
    if (length != size)
      die("XAR member size mismatch");
    decoded_account(encoded.len);
    out = (Bytes){xcalloc(encoded.len, 1), encoded.len};
    memcpy(out.data, encoded.data, out.len);
  } else
    die("unsupported XAR encoding: %s", encoding);
  free(encoding);
  verify_checksum(xml_child(data, "extracted-checksum"), out);
  return out;
}

/* Collects every file with data. Directories only contribute a prefix;
 * member metadata (modes, xattrs) is ignored because members are never
 * written to disk as themselves. */
static void walk_toc(Xar *xar, xmlNode *parent, const char *prefix,
                     Bytes heap, int depth) {
  if (depth > LIMIT_DEPTH)
    die("XAR nesting limit");
  for (xmlNode *n = xml_elements(parent); n;
       n = xml_next_element(n)) {
    if (!xml_is(n, "file"))
      continue;
    char *name = xml_text(xml_child(n, "name"));
    if (!*name || strchr(name, '/') || !strcmp(name, ".") ||
        !strcmp(name, ".."))
      die("unsafe XAR member name");
    char *joined = path_join(prefix, name);
    char *path = path_normalize(joined, 0);
    free(joined);
    free(name);
    char *type = xml_text(xml_child(n, "type"));
    xmlNode *data = xml_child(n, "data");
    if (!strcmp(type, "directory") && !data)
      walk_toc(xar, n, path, heap, depth + 1);
    else if (!strcmp(type, "file") && data) {
      if (xar->count >= LIMIT_ENTRIES)
        die("XAR member limit");
      xar->members = xrealloc(xar->members, xar->count + 1, sizeof(XarMember));
      xar->members[xar->count++] = (XarMember){path, read_member(data, heap)};
      path = NULL;
    } else
      die("unsupported XAR member: %s (%s)", path, type);
    free(type);
    free(path);
  }
}

static int member_compare(const void *a, const void *b) {
  return strcmp(((const XarMember *)a)->name, ((const XarMember *)b)->name);
}

void xar_open(Xar *xar, const char *path) {
  Bytes file = file_read(path, LIMIT_DECODED);
  if (file.len < XAR_HEADER_MIN || memcmp(file.data, "xar!", 4) ||
      big_endian(file.data + 6, 2) != 1)
    die("not a flat package (XAR version 1)");
  uint64_t header = big_endian(file.data + 4, 2),
           toc_packed = big_endian(file.data + 8, 8),
           toc_size = big_endian(file.data + 16, 8),
           algorithm = big_endian(file.data + 24, 4);
  if (header < XAR_HEADER_MIN || header > file.len ||
      toc_packed > file.len - header || !toc_size || toc_size > LIMIT_XML)
    die("invalid XAR header");
  Bytes packed = {file.data + header, (size_t)toc_packed};
  Bytes heap = {packed.data + packed.len, file.len - header - toc_packed};
  Bytes toc_xml = inflate_limited(packed, 15, (size_t)toc_size, LIMIT_XML);
  xmlDoc *doc = xml_parse(toc_xml);
  xmlNode *toc = xml_child(xml_root(doc, "xar"), "toc");
  xmlNode *checksum = xml_child(toc, "checksum");
  if (!toc || !checksum)
    die("XAR without a TOC checksum");

  /* 1 and 2 are fixed; 3 ("other") names the algorithm in the header when it
   * is long enough to hold one, and otherwise leaves it to the TOC. */
  char *style = xml_attr(checksum, "style", NULL);
  const char *expected = algorithm == 1 ? "sha1" : algorithm == 2 ? "md5" : NULL;
  char named[37] = {0};
  if (algorithm == 3 && header >= XAR_HEADER_NAMED) {
    memcpy(named, file.data + 28, 36);
    expected = named;
  } else if (algorithm == 3)
    expected = style;
  if (!expected || strcmp(style, expected))
    die("unsupported or inconsistent XAR TOC checksum");
  uint64_t offset = xml_child_uint(checksum, "offset"),
           size = xml_child_uint(checksum, "size");
  Bytes hash = digest(packed, style);
  if (offset > heap.len || size > heap.len - offset || size != hash.len ||
      memcmp(hash.data, heap.data + offset, hash.len))
    die("XAR TOC checksum mismatch");
  free(hash.data);
  free(style);

  walk_toc(xar, toc, "", heap, 0);
  qsort(xar->members, xar->count, sizeof(XarMember), member_compare);
  for (size_t i = 1; i < xar->count; i++)
    if (!strcmp(xar->members[i - 1].name, xar->members[i].name))
      die("duplicate XAR member: %s", xar->members[i].name);
  xml_free(doc);
  free(toc_xml.data);
  free(file.data);
}

Bytes xar_member(Xar *xar, const char *name, int required) {
  XarMember key = {.name = (char *)name};
  XarMember *m = bsearch(&key, xar->members, xar->count, sizeof(XarMember),
                         member_compare);
  if (m)
    return m->data;
  if (required)
    die("missing package member: %s", name);
  return (Bytes){NULL, 0};
}

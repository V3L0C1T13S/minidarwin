/* Receipts and inventory.
 *
 *   private/var/db/receipts/ID.plist  Apple's receipt keys
 *   private/var/db/receipts/ID.bom    the package's BOM, byte for byte
 *   private/var/db/mdpkg/ID.inventory.plist
 *       every payload entry as installed (with the ownership it asked for),
 *       and every entry the package's scripts created, modified or removed */
#include "mdpkg.h"

#include <errno.h>
#include <dirent.h>
#include <libxml/tree.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

Entry snapshot_entry(const char *base, const char *rel) {
  char *path = path_join(base, rel);
  struct stat st;
  if (lstat(path, &st))
    die("stat %s: %s", path, strerror(errno));
  Entry e = {.path = xstrdup(rel), .mode = st.st_mode, .uid = st.st_uid,
             .gid = st.st_gid, .mtime = st.st_mtime};
  if (S_ISREG(st.st_mode)) {
    e.data = file_sha256(path);
  } else if (S_ISLNK(st.st_mode)) {
    char target[PATH_MAX];
    ssize_t n = readlink(path, target, sizeof(target) - 1);
    if (n < 0)
      die("readlink %s: %s", path, strerror(errno));
    e.link = xstrndup(target, (size_t)n);
  } else if (!S_ISDIR(st.st_mode))
    die("unsupported file type (made by a script?): /%s", rel);
  free(path);
  return e;
}

static void snapshot_walk(EntryList *out, const char *base, const char *rel,
                          int depth) {
  if (depth > LIMIT_DEPTH)
    die("root nesting limit");
  Entry e = snapshot_entry(base, rel);
  int is_dir = S_ISDIR(e.mode);
  entries_append(out, e);
  if (!is_dir)
    return;
  char *path = path_join(base, rel);
  DIR *d = opendir(path);
  if (!d)
    die("opendir %s: %s", path, strerror(errno));
  for (struct dirent *item; (item = readdir(d));) {
    if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..") ||
        (!*rel && !strcmp(item->d_name, SCRIPTS_DIR)))
      continue;
    char *child = path_join(rel, item->d_name);
    snapshot_walk(out, base, child, depth + 1);
    free(child);
  }
  closedir(d);
  free(path);
}

/* The whole tree beneath BASE, minus the scripts' own working directory. */
void snapshot_tree(EntryList *out, const char *base) {
  snapshot_walk(out, base, "", 0);
}

static int same_entry(const Entry *a, const Entry *b) {
  if (a->mode != b->mode || a->uid != b->uid || a->gid != b->gid)
    return 0;
  if (a->link || b->link)
    return a->link && b->link && !strcmp(a->link, b->link);
  return a->data.len == b->data.len &&
         !memcmp(a->data.data, b->data.data, a->data.len);
}

static Entry copy_entry(const Entry *e, const char *change) {
  Entry c = *e;
  c.path = xstrdup(e->path);
  c.change = change;
  c.link = e->link ? xstrdup(e->link) : NULL;
  c.data = (Bytes){xcalloc(e->data.len, 1), e->data.len};
  memcpy(c.data.data, e->data.data, e->data.len);
  return c;
}

/* Appends to OUT what differs between two snapshots. */
void script_changes(EntryList *out, EntryList *before, EntryList *after) {
  for (size_t i = 0; i < after->count; i++) {
    Entry *now = &after->items[i], *was = entries_find(before, now->path);
    if (!was || !same_entry(now, was))
      entries_append(out, copy_entry(now, was ? "modified" : "created"));
  }
  for (size_t i = 0; i < before->count; i++)
    if (!entries_find(after, before->items[i].path))
      entries_append(out, copy_entry(&before->items[i], "removed"));
}

static xmlNode *add(xmlNode *parent, const char *name, const char *value) {
  return xmlNewTextChild(parent, NULL, BAD_CAST name, BAD_CAST value);
}

static void add_string(xmlNode *dict, const char *key, const char *value) {
  add(dict, "key", key);
  add(dict, "string", value);
}

static void add_integer(xmlNode *dict, const char *key, uint64_t value) {
  char buf[32];
  snprintf(buf, sizeof(buf), "%llu", (unsigned long long)value);
  add(dict, "key", key);
  add(dict, "integer", buf);
}

static xmlDoc *new_plist(xmlNode **dict) {
  xmlDoc *doc = xmlNewDoc(BAD_CAST "1.0");
  xmlCreateIntSubset(doc, BAD_CAST "plist",
                     BAD_CAST "-//Apple//DTD PLIST 1.0//EN",
                     BAD_CAST "http://www.apple.com/DTDs/PropertyList-1.0.dtd");
  xmlNode *plist = xmlNewNode(NULL, BAD_CAST "plist");
  xmlNewProp(plist, BAD_CAST "version", BAD_CAST "1.0");
  xmlDocSetRootElement(doc, plist);
  *dict = xmlNewChild(plist, NULL, BAD_CAST "dict", NULL);
  return doc;
}

static void write_plist(const char *stage, const char *rel, xmlDoc *doc) {
  path_parents(stage, rel, 1);
  char *path = path_join(stage, rel);
  xmlChar *buf;
  int size;
  xmlDocDumpFormatMemoryEnc(doc, &buf, &size, "UTF-8", 1);
  if (!buf || size < 0)
    die("cannot serialize %s", rel);
  file_write(path, (Bytes){buf, (size_t)size}, 0644);
  xmlFree(buf);
  xmlFreeDoc(doc);
  free(path);
}

static void add_record(xmlNode *array, const Entry *e, const char *origin,
                       const char *change, const char *package_path) {
  xmlNode *d = xmlNewChild(array, NULL, BAD_CAST "dict", NULL);
  add_string(d, "path", e->path);
  if (package_path)
    add_string(d, "package-path", package_path);
  add_string(d, "origin", origin);
  add_string(d, "change", change);
  add_string(d, "type", S_ISDIR(e->mode)   ? "directory"
                        : S_ISLNK(e->mode) ? "symlink"
                                           : "file");
  add_integer(d, "mode", e->mode & 07777);
  add_integer(d, "uid", e->uid);
  add_integer(d, "gid", e->gid);
  if (e->link)
    add_string(d, "target", e->link);
  if (e->data.len) {
    char *hex = hex_encode(e->data);
    add_string(d, "sha256", hex);
    free(hex);
  }
}

/* SOURCE_DATE_EPOCH, if set, so an install can be reproducible. */
static time_t install_time(void) {
  const char *epoch = getenv("SOURCE_DATE_EPOCH");
  return epoch && *epoch ? (time_t)parse_uint(epoch, 10) : time(NULL);
}

void receipts_write(const char *stage, const Package *pkg, const Component *c,
                    EntryList *changes) {
  char rel[PATH_MAX], date[32];
  time_t now = install_time();
  struct tm utc;
  strftime(date, sizeof(date), "%Y-%m-%dT%H:%M:%SZ", gmtime_r(&now, &utc));
  const char *file_name = strrchr(pkg->path, '/');
  char *prefix = path_join("/", c->location);

  xmlNode *dict;
  xmlDoc *doc = new_plist(&dict);
  add(dict, "key", "InstallDate");
  add(dict, "date", date);
  add_string(dict, "InstallPrefixPath", prefix);
  add_string(dict, "InstallProcessName", "mdpkg");
  add_string(dict, "PackageFileName", file_name ? file_name + 1 : pkg->path);
  add_string(dict, "PackageIdentifier", c->identifier);
  add_string(dict, "PackageVersion", c->version);
  snprintf(rel, sizeof(rel), "%s/%s.plist", RECEIPTS_DIR, c->identifier);
  write_plist(stage, rel, doc);
  free(prefix);

  snprintf(rel, sizeof(rel), "%s/%s.bom", RECEIPTS_DIR, c->identifier);
  char *bom = path_join(stage, rel);
  file_write(bom, c->bom, 0644);
  free(bom);

  doc = new_plist(&dict);
  add_string(dict, "PackageIdentifier", c->identifier);
  add_integer(dict, "InventoryVersion", 1);
  add(dict, "key", "Entries");
  xmlNode *array = xmlNewChild(dict, NULL, BAD_CAST "array", NULL);
  for (size_t i = 0; i < c->payload.count; i++) {
    const Entry *wanted = &c->payload.items[i];
    char *host = path_join(stage, wanted->path);
    struct stat st;
    if (lstat(host, &st))
      die("a script removed payload entry /%s", wanted->path);
    free(host);
    Entry installed = snapshot_entry(stage, wanted->path);
    installed.uid = wanted->uid;
    installed.gid = wanted->gid;
    add_record(array, &installed, "payload", "installed",
               wanted->package_path);
    free(installed.path);
    free(installed.link);
    free(installed.data.data);
  }
  for (size_t i = 0; i < changes->count; i++)
    add_record(array, &changes->items[i], "script",
               changes->items[i].change, NULL);
  snprintf(rel, sizeof(rel), "%s/%s.inventory.plist", INVENTORY_DIR,
           c->identifier);
  write_plist(stage, rel, doc);
}
